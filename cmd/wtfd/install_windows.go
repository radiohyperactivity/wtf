package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"

	"github.com/radiohyperactivity/wtf/db"
	"github.com/radiohyperactivity/wtf/internal/config"
	"github.com/radiohyperactivity/wtf/internal/schema"
	"github.com/radiohyperactivity/wtf/internal/webapp"
)

const installUsage = `Usage:
  wtfd install [flags]

install sets WtF up on this Windows machine. It puts wtfd.exe, and wtf.exe
from the same folder, in Program Files\WtF\bin, and adds that folder to the
PATH. It makes ProgramData\WtF, which only administrators can open, with the
files directory in it. Then it connects to WtF's database: one that exists,
or a new one, made as "wtfd database create" does. Both roles' passwords go
in ProgramData\WtF\pgpass.conf.

Run again with a newer wtfd, it upgrades: it stops the wtfd service while it
replaces the programs, brings the database's schema up to date, and starts
the service again. It takes the settings from ProgramData\WtF\wtfd.conf and
the passwords from pgpass.conf, and asks only for what they don't have;
--reconfigure asks for everything again, with theirs as the defaults. It must run as an administrator. Run
"wtfd install -h" for the flags.
`

// configHeader starts the config file install writes.
const configHeader = `# wtfd's settings, written by wtfd install, which keeps what else is here.
# Each key is one of wtfd's flags (wtfd serve -h); a flag, or its
# environment variable, overrides the value here. The passwords are in
# pgpass.conf, beside this file.
`

// installedService is the Windows service's name.
const installedService = "wtfd"

func runInstall(args []string, stdin *os.File, stdout, stderr io.Writer) int {
	const name = "wtfd install"
	l, err := installLayout()
	if err != nil {
		fmt.Fprintf(stderr, "%s: %v\n", name, err)
		return exitFailure
	}
	binDir, dataDir, configPath, pgpassPath := l.binDir, l.dataDir, l.configPath, l.passPath

	flags := flag.NewFlagSet(name, flag.ContinueOnError)
	flags.SetOutput(stderr)
	flags.Usage = func() {
		fmt.Fprint(stderr, installUsage+"\nFlags (the database ones are for an existing database, or a new one):\n")
		flags.PrintDefaults()
	}
	filesDir := flags.String("files-directory", filepath.Join(dataDir, "files"), "where wtfd keeps the files (photos and attachments); may be on another drive")
	listen := flags.String("listen", "127.0.0.1:8080", "the address and port wtfd serve listens on")
	reconfigure := flags.Bool("reconfigure", false, "ask for every setting again, with wtfd.conf's as the defaults, rather than take them from it")
	c := registerDatabaseCreation(flags, name)
	if code, ok := parse(flags, args, stderr); !ok {
		return code
	}
	c.given(flags)

	if !requireAdmin(name, stderr) {
		return exitFailure
	}
	q := openQuestions(stdin, stdout)
	var wasRunning bool // the service ran, and was stopped
	stillStopped := func() {
		if wasRunning {
			fmt.Fprintf(stderr, "The %s service is stopped; once this is sorted out, run wtfd install again, or Start-Service %s.\n", installedService, installedService)
		}
	}
	fail := func(err error) int {
		if errors.Is(err, errCancelled) {
			fmt.Fprintln(stderr, "Cancelled.")
		} else {
			fmt.Fprintf(stderr, "%s: %v\n", name, err)
		}
		stillStopped()
		return exitFailure
	}

	// A config file from an earlier run gives the settings, which aren't
	// asked for again, so that an upgrade asks nothing it knows; with
	// --reconfigure they are only the defaults of the questions. The
	// environment is ignored, as by "wtfd database create".
	previous, err := config.ReadFile(configPath)
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		return fail(err)
	}
	if err := config.SetFrom(flags, previous); err != nil {
		return fail(fmt.Errorf("%s: %w", configPath, err))
	}
	known := map[string]bool{}
	for _, s := range previous {
		known[s.Key] = true
		if !*reconfigure {
			c.set[s.Key] = true
		}
	}
	// An upgrade: the database's settings are all in the file already.
	upgrade := !*reconfigure
	for _, key := range []string{"database-host", "database-port", "database-name", "dba-database-user", "api-database-user"} {
		upgrade = upgrade && known[key]
	}

	// The programs. A running service holds wtfd.exe, so it is stopped
	// while the programs are replaced, and started again at the end. Run
	// from the installed copy, there is nothing to replace, which is said
	// first, as it is an easy mistake when upgrading.
	fmt.Fprintf(stdout, "The programs, in %s:\n", binDir)
	if installedCopy(binDir) {
		fmt.Fprintf(stdout, "  This is the installed wtfd.exe, so there is nothing new to install. To upgrade,\n"+
			"  run the new wtfd.exe install from where you unpacked it. Going on with the rest.\n")
	} else {
		wasRunning, err = stopService(installedService)
		if err != nil {
			return fail(err)
		}
		if wasRunning {
			fmt.Fprintf(stdout, "  Stopped the %s service while replacing them.\n", installedService)
		}
		if err := installPrograms(binDir, stdout); err != nil {
			return fail(err)
		}
	}
	if webapp.Files == nil {
		fmt.Fprintln(stdout, "  This wtfd.exe has no web app built in (scripts/build.sh builds one that has), so wtfd serve offers the API only, unless web-root names a web build.")
	}
	added, err := addToPath(binDir)
	if err != nil {
		return fail(fmt.Errorf("adding %s to the PATH: %w", binDir, err))
	}
	if added {
		fmt.Fprintf(stdout, "  Added %s to the PATH; windows opened from now on have it.\n", binDir)
	}

	// The data: administrators only; the service gets its access when it is
	// set up.
	for _, dir := range []string{dataDir, *filesDir} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return fail(err)
		}
	}
	if err := adminsOnly(dataDir); err != nil {
		return fail(fmt.Errorf("limiting %s to administrators: %w", dataDir, err))
	}
	if !strings.HasPrefix(strings.ToLower(*filesDir), strings.ToLower(dataDir)+`\`) {
		if err := adminsOnly(*filesDir); err != nil {
			return fail(fmt.Errorf("limiting %s to administrators: %w", *filesDir, err))
		}
	}
	fmt.Fprintf(stdout, "\nThe data, in %s (for administrators only):\n  Files in %s.\n", dataDir, *filesDir)

	// The database. The password file the service will use is read first,
	// so that a second run needn't ask for what it has.
	os.Setenv("PGPASSFILE", pgpassPath)
	var lines []string // the password file's new lines
	databaseCode := exitOK
	databaseKnown := false // the database's settings are known, for the config file
	switch {
	case upgrade:
		d := c.database
		fmt.Fprintf(stdout, "\nThe database: %s on %s:%d, as %s and %s (from %s):\n",
			d.Name, d.Host, d.Port, d.DBAUser, d.APIUser, configPath)
		lines, err = connectExisting(q, c.database, c.set, stdout, stderr)
		if err != nil {
			return fail(err)
		}
		databaseKnown = true
	case q == nil:
		fmt.Fprintln(stdout, "\nNot on a terminal, so the database is left as it is; run wtfd install in a terminal to set it up.")
	default:
		_, statErr := os.Stat(pgpassPath)
		fmt.Fprintln(stdout)
		exists, err := q.yes("Is WtF's database there already?", statErr == nil)
		if err != nil {
			return fail(err)
		}
		fmt.Fprintln(stdout)
		if exists {
			lines, err = connectExisting(q, c.database, c.set, stdout, stderr)
			if err != nil {
				return fail(err)
			}
			databaseKnown = true
		} else {
			// A database that was made has its passwords written even when
			// a later step failed, as the roles exist with them.
			databaseCode = c.run(q, stdout, stderr)
			if c.created {
				lines = c.pgpassLines()
				databaseKnown = true
			} else if databaseCode != exitOK {
				stillStopped()
				return databaseCode
			}
		}
	}
	if len(lines) > 0 {
		old, err := os.ReadFile(pgpassPath)
		if err != nil && !errors.Is(err, fs.ErrNotExist) {
			return fail(err)
		}
		if err := writeFileAtomic(pgpassPath, []byte(mergePgpass(string(old), lines))); err != nil {
			return fail(err)
		}
		fmt.Fprintf(stdout, "\nWrote the roles' passwords to %s.\n", pgpassPath)
	}

	// The config file: what install knows, so that wtfd serve, schema, gc
	// and account need no flags here.
	if q != nil && !c.set["listen"] {
		fmt.Fprintln(stdout, "\nThe REST API (wtfd serve):")
		for {
			if *listen, err = q.text(`  Listen on ("127.0.0.1:8080": this machine only; "0.0.0.0:8080": the network)`, *listen); err != nil {
				return fail(err)
			}
			if _, _, err := net.SplitHostPort(*listen); err == nil {
				break
			}
			fmt.Fprintln(stdout, "  Give an address and a port, such as 127.0.0.1:8080.")
		}
	}
	settings := []config.Setting{{Key: "files-directory", Value: *filesDir}, {Key: "listen", Value: *listen}}
	if databaseKnown {
		d := c.database
		settings = append(settings,
			config.Setting{Key: "database-host", Value: d.Host},
			config.Setting{Key: "database-port", Value: strconv.Itoa(d.Port)},
			config.Setting{Key: "database-name", Value: d.Name},
			config.Setting{Key: "database-sslmode", Value: d.SSLMode},
			config.Setting{Key: "dba-database-user", Value: d.DBAUser},
			config.Setting{Key: "api-database-user", Value: d.APIUser},
		)
	}
	old, err := os.ReadFile(configPath)
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		return fail(err)
	}
	if err := writeFileAtomic(configPath, []byte(config.UpdateFile(string(old), configHeader, settings))); err != nil {
		return fail(err)
	}
	fmt.Fprintf(stdout, "\nWrote the settings to %s.\n", configPath)

	if databaseCode != exitOK {
		stillStopped()
		return databaseCode
	}
	if wasRunning {
		if err := startService(installedService); err != nil {
			return fail(fmt.Errorf("starting the %s service again: %w", installedService, err))
		}
		fmt.Fprintf(stdout, "Started the %s service again.\n", installedService)
	}
	fmt.Fprintln(stdout, "\nWtF is installed.")

	// The service, when there is none yet.
	if serviceExists() {
		return exitOK
	}
	if q == nil {
		fmt.Fprintln(stdout, "To run wtfd as a Windows service: wtfd service install")
		return exitOK
	}
	fmt.Fprintln(stdout)
	ok, err := q.yes("Set up the Windows service now, which runs wtfd serve from boot on?", true)
	if err != nil {
		return fail(err)
	}
	if !ok {
		fmt.Fprintln(stdout, "Later, then: wtfd service install")
		return exitOK
	}
	fmt.Fprintln(stdout)
	if err := installService(q, stdout); err != nil {
		return fail(err)
	}
	return exitOK
}

// connectExisting asks for an existing database's server, names and
// passwords, checks that both roles can connect, and brings its schema up
// to date. What set has, or the password file has, isn't asked for; with
// all of it known, q may be nil. It returns the password file's lines for
// the passwords typed in.
func connectExisting(q *questions, database *config.Database, set map[string]bool, stdout, stderr io.Writer) ([]string, error) {
	ctx := context.Background()
	var err error
	if !(set["database-host"] && set["database-port"] && set["database-name"] && set["dba-database-user"] && set["api-database-user"]) {
		fmt.Fprintln(stdout, "WtF's database:")
	}
	ask := func(flag, question string, value *string) {
		if err == nil && !set[flag] {
			*value, err = q.text(question, *value)
		}
	}
	ask("database-host", "  Host", &database.Host)
	if err == nil && !set["database-port"] {
		database.Port, err = q.number("  Port", database.Port)
	}
	ask("database-name", "  Database", &database.Name)
	ask("dba-database-user", "  Its owner (DBA role)", &database.DBAUser)
	ask("api-database-user", "  The REST API's role", &database.APIUser)
	if err != nil {
		return nil, err
	}
	if err := database.Validate(); err != nil {
		return nil, err
	}

	var lines []string
	passwords := map[string]string{}
	for _, role := range []string{database.DBAUser, database.APIUser} {
		password := "" // from the password file, if it has it
		for tries := 0; ; tries++ {
			conn, err := connectTo(ctx, database, role, password, database.Name, "wtfd install")
			if err == nil {
				conn.Close(ctx)
				break
			}
			if q == nil && needsPassword(err) {
				return nil, fmt.Errorf("connecting as %s: %w\nThe password file has no password for %s that works; run wtfd install in a terminal to give it one", role, err, role)
			}
			if !needsPassword(err) || tries == 3 {
				if strings.Contains(err.Error(), "pg_hba.conf") {
					err = fmt.Errorf("%w\nThe server's pg_hba.conf has no line that lets %s connect to %s from here; add one (README.md, step 5), and reload it", err, role, database.Name)
				}
				return nil, fmt.Errorf("connecting as %s: %w", role, err)
			}
			if tries > 0 {
				fmt.Fprintln(stdout, "  That password didn't work.")
			}
			if password, err = q.password(fmt.Sprintf("  Password for %s", role)); err != nil {
				return nil, err
			}
		}
		if password != "" {
			lines = append(lines, pgpassLine(database.Host, database.Port, database.Name, role, password))
		}
		passwords[role] = password
		fmt.Fprintf(stdout, "  %s can connect.\n", role)
	}

	dbaConfig, err := database.ConnConfig(database.DBAUser, passwords[database.DBAUser], "wtfd schema")
	if err != nil {
		return nil, err
	}
	result, err := schema.Run(ctx, schema.Options{
		ConnConfig: dbaConfig,
		APIUser:    database.APIUser,
		Scripts:    db.Scripts,
		Logger:     slog.New(slog.NewTextHandler(stderr, &slog.HandlerOptions{Level: slog.LevelWarn})),
	})
	if err != nil {
		return lines, fmt.Errorf("bringing the schema up to date: %w", err)
	}
	if result.Pending {
		fmt.Fprintln(stdout, "  Brought the schema up to date.")
	} else {
		fmt.Fprintln(stdout, "  The schema is up to date.")
	}
	return lines, nil
}

// installPrograms copies wtfd.exe, and wtf.exe beside it, into binDir. A
// program in the way is renamed first, as Windows lets a running program be
// renamed but not overwritten; the renamed ones are removed on the next
// run.
func installPrograms(binDir string, stdout io.Writer) error {
	self, err := os.Executable()
	if err != nil {
		return err
	}
	if self, err = filepath.EvalSymlinks(self); err != nil {
		return err
	}
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		return err
	}
	if old, _ := filepath.Glob(filepath.Join(binDir, "*.old*")); len(old) > 0 {
		for _, f := range old {
			os.Remove(f) // one still running stays, until next time
		}
	}
	for _, program := range []string{"wtfd.exe", "wtf.exe"} {
		src := filepath.Join(filepath.Dir(self), program)
		dst := filepath.Join(binDir, program)
		srcInfo, err := os.Stat(src)
		if errors.Is(err, fs.ErrNotExist) && program != "wtfd.exe" {
			fmt.Fprintf(stdout, "  %s: not beside wtfd.exe (%s), so not installed.\n", program, filepath.Dir(self))
			continue
		}
		if err != nil {
			return err
		}
		if dstInfo, err := os.Stat(dst); err == nil {
			if os.SameFile(srcInfo, dstInfo) {
				fmt.Fprintf(stdout, "  %s: in place already.\n", program)
				continue
			}
			aside := fmt.Sprintf("%s.old-%d", dst, time.Now().UnixNano())
			if err := os.Rename(dst, aside); err != nil {
				return fmt.Errorf("moving the old %s aside: %w", program, err)
			}
		}
		data, err := os.ReadFile(src)
		if err != nil {
			return err
		}
		if err := writeFileAtomic(dst, data); err != nil {
			return err
		}
		fmt.Fprintf(stdout, "  %s: installed.\n", program)
	}
	return nil
}

// installedCopy reports whether this program is the wtfd.exe in binDir.
func installedCopy(binDir string) bool {
	self, err := os.Executable()
	if err != nil {
		return false
	}
	selfInfo, err := os.Stat(self)
	if err != nil {
		return false
	}
	installedInfo, err := os.Stat(filepath.Join(binDir, "wtfd.exe"))
	return err == nil && os.SameFile(selfInfo, installedInfo)
}

// writeFileAtomic writes data to a new file beside name, and then puts it
// in name's place.
func writeFileAtomic(name string, data []byte) error {
	tmp := name + ".new"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, name)
}

// addToPath adds dir to the machine's PATH, unless it is there already, and
// tells the running programs that listen (Explorer, so new windows) of the
// change. It reports whether it added it.
func addToPath(dir string) (bool, error) {
	key, err := registry.OpenKey(registry.LOCAL_MACHINE,
		`SYSTEM\CurrentControlSet\Control\Session Manager\Environment`, registry.QUERY_VALUE|registry.SET_VALUE)
	if err != nil {
		return false, err
	}
	defer key.Close()
	path, _, err := key.GetStringValue("Path")
	if err != nil {
		return false, err
	}
	for _, p := range strings.Split(path, ";") {
		if strings.EqualFold(strings.TrimRight(p, `\`), strings.TrimRight(dir, `\`)) {
			return false, nil
		}
	}
	if path != "" && !strings.HasSuffix(path, ";") {
		path += ";"
	}
	if err := key.SetExpandStringValue("Path", path+dir); err != nil {
		return false, err
	}
	broadcastEnvironmentChange()
	return true, nil
}

// broadcastEnvironmentChange tells the top-level windows that the
// environment changed. The broadcast waits for each window in turn, so one
// that is slow to answer can hold it up for long; install waits a few
// seconds at most, and the broadcast goes on without it until wtfd exits.
func broadcastEnvironmentChange() {
	const (
		hwndBroadcast    = 0xffff
		wmSettingChange  = 0x001a
		smtoAbortIfHung  = 0x0002
		timeoutMillisecs = 1000 // for each window
	)
	done := make(chan struct{})
	go func() {
		defer close(done)
		env, _ := windows.UTF16PtrFromString("Environment")
		var result uintptr
		windows.NewLazySystemDLL("user32.dll").NewProc("SendMessageTimeoutW").Call(
			hwndBroadcast, wmSettingChange, 0, uintptr(unsafe.Pointer(env)),
			smtoAbortIfHung, timeoutMillisecs, uintptr(unsafe.Pointer(&result)))
	}()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
	}
}

// adminsOnly makes dir open to Administrators and SYSTEM only, in place of
// what it inherits (ProgramData lets every user create files), for it and
// all in it.
func adminsOnly(dir string) error {
	sd, err := windows.SecurityDescriptorFromString("D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)")
	if err != nil {
		return err
	}
	dacl, _, err := sd.DACL()
	if err != nil {
		return err
	}
	return windows.SetNamedSecurityInfo(dir, windows.SE_FILE_OBJECT,
		windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION, nil, nil, dacl, nil)
}

// stopService stops the service name if it is running, and reports whether
// it was. A service that doesn't exist isn't running.
func stopService(name string) (bool, error) {
	m, err := mgr.Connect()
	if err != nil {
		return false, err
	}
	defer m.Disconnect()
	s, err := m.OpenService(name)
	if err != nil {
		return false, nil
	}
	defer s.Close()
	status, err := s.Query()
	if err != nil {
		return false, err
	}
	if status.State == svc.Stopped {
		return false, nil
	}
	if _, err := s.Control(svc.Stop); err != nil {
		return false, fmt.Errorf("stopping the %s service: %w", name, err)
	}
	// wtfd waits up to 30 seconds for requests to finish.
	for deadline := time.Now().Add(40 * time.Second); time.Now().Before(deadline); time.Sleep(250 * time.Millisecond) {
		if status, err = s.Query(); err != nil {
			return true, err
		}
		if status.State == svc.Stopped {
			return true, nil
		}
	}
	return true, fmt.Errorf("the %s service didn't stop within 40 seconds", name)
}

func startService(name string) error {
	m, err := mgr.Connect()
	if err != nil {
		return err
	}
	defer m.Disconnect()
	s, err := m.OpenService(name)
	if err != nil {
		return err
	}
	defer s.Close()
	return s.Start()
}
