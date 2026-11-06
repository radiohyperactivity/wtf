package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/eventlog"
	"golang.org/x/sys/windows/svc/mgr"

	"github.com/radiohyperactivity/wtf/internal/config"
)

const serviceUsage = `Usage:
  wtfd service install     run wtfd serve as a Windows service, and start it
  wtfd service uninstall   stop the service and remove it

install sets up the service "wtfd" for the wtfd.exe that "wtfd install" put
in Program Files\WtF\bin: started at boot, as its own account
(NT SERVICE\wtfd), restarted when it fails, logging to the Event Log. It gives the
service access to its settings, its passwords and the files directory, asks
before opening the firewall when wtfd listens beyond this machine, and starts
the service and checks that it answers. Run again, it brings the service up
to date. uninstall leaves the programs, the settings and the data. Both must
run as an administrator.
`

const (
	serviceDisplayName = "WtF server"
	serviceDescription = "The WtF REST API and web app (wtfd serve)."
	serviceAccount     = `NT SERVICE\` + installedService
	firewallRule       = "WtF server"
)

func runServiceCommand(args []string, stdin *os.File, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprint(stderr, serviceUsage)
		return exitUsage
	}
	command := args[0]
	switch command {
	case "install", "uninstall":
	case "help", "-h", "-help", "--help":
		fmt.Fprint(stderr, serviceUsage)
		return exitOK
	default:
		fmt.Fprintf(stderr, "wtfd service: unknown command %q\n\n%s", command, serviceUsage)
		return exitUsage
	}
	name := "wtfd service " + command
	flags := flag.NewFlagSet(name, flag.ContinueOnError)
	flags.SetOutput(stderr)
	if code, ok := parse(flags, args[1:], stderr); !ok {
		return code
	}
	if !requireAdmin(name, stderr) {
		return exitFailure
	}
	q := openQuestions(stdin, stdout)
	var err error
	if command == "install" {
		err = installService(q, stdout)
	} else {
		err = uninstallService(q, stdout)
	}
	if errors.Is(err, errCancelled) {
		fmt.Fprintln(stderr, "Cancelled.")
		return exitFailure
	}
	if err != nil {
		fmt.Fprintf(stderr, "%s: %v\n", name, err)
		return exitFailure
	}
	return exitOK
}

// requireAdmin reports, and says how to do better, when this isn't an
// administrator's window.
func requireAdmin(action string, stderr io.Writer) bool {
	if windows.GetCurrentProcessToken().IsElevated() {
		return true
	}
	fmt.Fprintf(stderr, `%s must run as an administrator.

Open PowerShell or Windows Terminal as an administrator (right-click it and
choose "Run as administrator", or press Ctrl+Shift+Enter on it in the Start
menu), and run it again from there.
`, action)
	return false
}

// layout is where "wtfd install" puts things.
type layout struct {
	binDir, program               string // Program Files\WtF\bin, and wtfd.exe in it
	dataDir, configPath, passPath string // ProgramData\WtF, and wtfd.conf and pgpass.conf in it
}

func installLayout() (layout, error) {
	programFiles, err := windows.KnownFolderPath(windows.FOLDERID_ProgramFiles, 0)
	if err != nil {
		return layout{}, fmt.Errorf("finding Program Files: %w", err)
	}
	dataDir, err := config.DefaultDir()
	if err != nil {
		return layout{}, fmt.Errorf("finding ProgramData: %w", err)
	}
	binDir := filepath.Join(programFiles, "WtF", "bin")
	return layout{
		binDir:     binDir,
		program:    filepath.Join(binDir, "wtfd.exe"),
		dataDir:    dataDir,
		configPath: filepath.Join(dataDir, config.FileName),
		passPath:   filepath.Join(dataDir, config.PasswordFile),
	}, nil
}

// serviceExists reports whether the service is set up.
func serviceExists() bool {
	m, err := mgr.Connect()
	if err != nil {
		return false
	}
	defer m.Disconnect()
	s, err := m.OpenService(installedService)
	if err != nil {
		return false
	}
	s.Close()
	return true
}

// installService sets the service up, or brings it up to date, and starts
// it.
func installService(q *questions, stdout io.Writer) error {
	l, err := installLayout()
	if err != nil {
		return err
	}
	if _, err := os.Stat(l.program); err != nil {
		return fmt.Errorf("%s isn't there; run wtfd install first", l.program)
	}
	settings, err := config.ReadFile(l.configPath)
	if errors.Is(err, fs.ErrNotExist) {
		return fmt.Errorf("%s isn't there; run wtfd install first", l.configPath)
	}
	if err != nil {
		return err
	}
	setting := func(key, def string) string {
		for _, s := range settings {
			if s.Key == key {
				return s.Value
			}
		}
		return def
	}
	filesDir := setting("files-directory", "")
	if filesDir == "" {
		return fmt.Errorf("%s has no files-directory; run wtfd install again", l.configPath)
	}
	listen := setting("listen", "127.0.0.1:8080")

	fmt.Fprintf(stdout, "The %s service, running %s serve:\n", installedService, l.program)

	// The Event Log source, which lets Event Viewer show wtfd's entries as
	// they are.
	err = eventlog.InstallAsEventCreate(eventSource, eventlog.Error|eventlog.Warning|eventlog.Info)
	if err != nil && !strings.Contains(err.Error(), "already exists") {
		return fmt.Errorf("registering the Event Log source %s: %w", eventSource, err)
	}

	// The service: started at boot once the rest is up, as its own virtual
	// account, which needs no password and may do only what it is given.
	m, err := mgr.Connect()
	if err != nil {
		return err
	}
	defer m.Disconnect()
	cfg := mgr.Config{
		ServiceType:      windows.SERVICE_WIN32_OWN_PROCESS,
		StartType:        mgr.StartAutomatic,
		DelayedAutoStart: true,
		ErrorControl:     mgr.ErrorNormal,
		DisplayName:      serviceDisplayName,
		Description:      serviceDescription,
		ServiceStartName: serviceAccount,
		SidType:          windows.SERVICE_SID_TYPE_UNRESTRICTED,
	}
	s, err := m.OpenService(installedService)
	if err == nil {
		if _, err := stopService(installedService); err != nil {
			s.Close()
			return err
		}
		cfg.BinaryPathName = syscall.EscapeArg(l.program) + " serve"
		if err := s.UpdateConfig(cfg); err != nil {
			s.Close()
			return fmt.Errorf("updating the service: %w", err)
		}
		fmt.Fprintln(stdout, "  Brought the service up to date.")
	} else {
		if s, err = m.CreateService(installedService, l.program, cfg, "serve"); err != nil {
			return fmt.Errorf("creating the service: %w", err)
		}
		fmt.Fprintln(stdout, "  Created the service: started at boot (delayed), as "+serviceAccount+".")
	}
	defer s.Close()

	// Restarted when it fails, also when serve stops with an error of its
	// own, such as a database that isn't up yet; counted afresh after a day.
	restarts := []mgr.RecoveryAction{
		{Type: mgr.ServiceRestart, Delay: 5 * time.Second},
		{Type: mgr.ServiceRestart, Delay: 5 * time.Second},
		{Type: mgr.ServiceRestart, Delay: time.Minute},
	}
	if err := s.SetRecoveryActions(restarts, uint32((24 * time.Hour).Seconds())); err != nil {
		return fmt.Errorf("setting the service's restarts: %w", err)
	}
	if err := s.SetRecoveryActionsOnNonCrashFailures(true); err != nil {
		return fmt.Errorf("setting the service's restarts: %w", err)
	}

	// Its access: ProgramData\WtF is for administrators, so the service is
	// let through it to its settings and passwords, and into the files.
	sid, _, _, err := windows.LookupSID("", serviceAccount)
	if err != nil {
		return fmt.Errorf("finding the account %s: %w", serviceAccount, err)
	}
	for _, a := range serviceAccess(l, filesDir) {
		if _, err := os.Stat(a.path); errors.Is(err, fs.ErrNotExist) && a.optional {
			continue
		}
		if err := setAccess(a.path, sid, a.mask, a.inherit, windows.SET_ACCESS); err != nil {
			return fmt.Errorf("giving the service access to %s: %w", a.path, err)
		}
	}
	fmt.Fprintf(stdout, "  Gave it access to %s, %s and %s.\n", l.configPath, l.passPath, filesDir)
	if _, err := os.Stat(l.passPath); err != nil {
		fmt.Fprintf(stdout, "  %s isn't there, so it has no password for the database; run wtfd install again to set one.\n", l.passPath)
	}

	if err := openFirewall(q, listen, l.program, stdout); err != nil {
		return err
	}

	// Started, and asked whether it answers.
	if err := s.Start(); err != nil {
		return fmt.Errorf("starting the service: %w", err)
	}
	if err := checkService(s, listen, stdout); err != nil {
		showServiceLog(stdout)
		return err
	}
	return nil
}

// access is what the service may do with a file or directory.
type access struct {
	path     string
	mask     uint32
	inherit  uint32
	optional bool // may be missing
}

func serviceAccess(l layout, filesDir string) []access {
	const (
		traverse = windows.FILE_TRAVERSE | windows.FILE_READ_ATTRIBUTES | windows.SYNCHRONIZE
		read     = windows.FILE_GENERIC_READ
		modify   = windows.FILE_GENERIC_READ | windows.FILE_GENERIC_WRITE | windows.FILE_GENERIC_EXECUTE | windows.DELETE
	)
	return []access{
		{path: l.dataDir, mask: traverse, inherit: windows.NO_INHERITANCE},
		{path: l.configPath, mask: read, inherit: windows.NO_INHERITANCE},
		{path: l.passPath, mask: read, inherit: windows.NO_INHERITANCE, optional: true},
		{path: filesDir, mask: modify, inherit: windows.SUB_CONTAINERS_AND_OBJECTS_INHERIT},
	}
}

// setAccess gives sid access mask to path (mode SET_ACCESS, in place of any
// it had), or takes all its access away (REVOKE_ACCESS). A DACL that is
// protected from what its parent passes on stays so; one that isn't still
// takes it.
func setAccess(path string, sid *windows.SID, mask, inherit uint32, mode windows.ACCESS_MODE) error {
	sd, err := windows.GetNamedSecurityInfo(path, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION)
	if err != nil {
		return err
	}
	dacl, _, err := sd.DACL()
	if err != nil {
		return err
	}
	control, _, err := sd.Control()
	if err != nil {
		return err
	}
	protection := windows.SECURITY_INFORMATION(windows.UNPROTECTED_DACL_SECURITY_INFORMATION)
	if control&windows.SE_DACL_PROTECTED != 0 {
		protection = windows.PROTECTED_DACL_SECURITY_INFORMATION
	}
	entry := windows.EXPLICIT_ACCESS{
		AccessPermissions: windows.ACCESS_MASK(mask),
		AccessMode:        mode,
		Inheritance:       inherit,
		Trustee: windows.TRUSTEE{
			TrusteeForm:  windows.TRUSTEE_IS_SID,
			TrusteeType:  windows.TRUSTEE_IS_UNKNOWN,
			TrusteeValue: windows.TrusteeValueFromSID(sid),
		},
	}
	acl, err := windows.ACLFromEntries([]windows.EXPLICIT_ACCESS{entry}, dacl)
	if err != nil {
		return err
	}
	return windows.SetNamedSecurityInfo(path, windows.SE_FILE_OBJECT,
		windows.DACL_SECURITY_INFORMATION|protection, nil, nil, acl, nil)
}

// openFirewall asks, when wtfd listens beyond this machine, whether to let
// other machines through Windows Firewall to it, and adds the rule. Without
// a terminal it only says how.
func openFirewall(q *questions, listen, program string, stdout io.Writer) error {
	host, port, err := net.SplitHostPort(listen)
	if err != nil {
		return fmt.Errorf("listen %q: %w", listen, err)
	}
	if ip := net.ParseIP(host); host == "localhost" || (ip != nil && ip.IsLoopback()) {
		return nil
	}
	add := fmt.Sprintf(`netsh advfirewall firewall add rule name="%s" dir=in action=allow protocol=TCP localport=%s program="%s"`,
		firewallRule, port, program)
	if q == nil {
		fmt.Fprintf(stdout, "  wtfd listens on %s, which Windows Firewall may block. To let other machines in:\n    %s\n", listen, add)
		return nil
	}
	fmt.Fprintf(stdout, "\nwtfd listens on %s, which other machines can reach, unless Windows Firewall blocks them.\n", listen)
	ok, err := q.yes(fmt.Sprintf("  Add the firewall rule %q, letting them in on TCP port %s?", firewallRule, port), true)
	if err != nil || !ok {
		return err
	}
	netsh(`netsh advfirewall firewall delete rule name="` + firewallRule + `"`) // one from an earlier run
	if out, err := netsh(add); err != nil {
		return fmt.Errorf("adding the firewall rule: %v: %s", err, out)
	}
	fmt.Fprintf(stdout, "  Added the firewall rule %q.\n", firewallRule)
	return nil
}

// netsh runs a netsh command line as it is written: netsh reads its own
// command line, with quotes inside the arguments (name="WtF server").
func netsh(commandLine string) (string, error) {
	cmd := exec.Command("netsh")
	cmd.SysProcAttr = &syscall.SysProcAttr{CmdLine: commandLine}
	out, err := cmd.CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

// checkService waits for the service to run, and for wtfd to answer on
// /api/health.
func checkService(s *mgr.Service, listen string, stdout io.Writer) error {
	deadline := time.Now().Add(30 * time.Second)
	for {
		status, err := s.Query()
		if err != nil {
			return err
		}
		if status.State == svc.Running {
			break
		}
		if status.State == svc.Stopped || time.Now().After(deadline) {
			return errors.New("the service didn't start")
		}
		time.Sleep(250 * time.Millisecond)
	}
	fmt.Fprintln(stdout, "  Started the service.")

	host, port, _ := net.SplitHostPort(listen)
	if ip := net.ParseIP(host); host == "" || (ip != nil && ip.IsUnspecified()) {
		host = "127.0.0.1"
	}
	url := "http://" + net.JoinHostPort(host, port) + "/api/health"
	client := &http.Client{Timeout: 2 * time.Second}
	for deadline = time.Now().Add(20 * time.Second); ; time.Sleep(500 * time.Millisecond) {
		resp, err := client.Get(url)
		if err == nil {
			resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				fmt.Fprintf(stdout, "  It answers on %s.\n", url)
				return nil
			}
			err = fmt.Errorf("%s answers %s", url, resp.Status)
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("the service runs, but doesn't answer: %w", err)
		}
	}
}

// showServiceLog shows wtfd's last entries in the Event Log.
func showServiceLog(stdout io.Writer) {
	out, err := exec.Command("wevtutil", "qe", "Application",
		"/q:*[System[Provider[@Name='"+eventSource+"']]]", "/c:5", "/rd:true", "/f:text").Output()
	if err != nil || len(out) == 0 {
		return
	}
	fmt.Fprintf(stdout, "\nwtfd's last entries in the Event Log, newest first:\n%s\n", strings.TrimSpace(string(out)))
}

// uninstallService stops the service and removes it, its access, its
// firewall rule and its Event Log source.
func uninstallService(q *questions, stdout io.Writer) error {
	l, err := installLayout()
	if err != nil {
		return err
	}
	if !serviceExists() {
		fmt.Fprintf(stdout, "There is no %s service.\n", installedService)
		return nil
	}
	if q != nil {
		ok, err := q.yes(fmt.Sprintf("Stop the %s service and remove it? The programs, settings and data stay.", installedService), false)
		if err != nil || !ok {
			return errCancelled
		}
	}
	if _, err := stopService(installedService); err != nil {
		return err
	}
	fmt.Fprintf(stdout, "Stopped the %s service.\n", installedService)

	// The access goes first, while the account is there to be named.
	if sid, _, _, err := windows.LookupSID("", serviceAccount); err == nil {
		filesDir := filepath.Join(l.dataDir, "files")
		if settings, err := config.ReadFile(l.configPath); err == nil {
			for _, s := range settings {
				if s.Key == "files-directory" {
					filesDir = s.Value
				}
			}
		}
		for _, a := range serviceAccess(l, filesDir) {
			if _, err := os.Stat(a.path); err == nil {
				if err := setAccess(a.path, sid, 0, windows.NO_INHERITANCE, windows.REVOKE_ACCESS); err != nil {
					fmt.Fprintf(stdout, "  Couldn't take the service's access to %s away: %v\n", a.path, err)
				}
			}
		}
		fmt.Fprintln(stdout, "Took its access away.")
	}

	m, err := mgr.Connect()
	if err != nil {
		return err
	}
	defer m.Disconnect()
	s, err := m.OpenService(installedService)
	if err != nil {
		return err
	}
	err = s.Delete()
	s.Close()
	if err != nil {
		return fmt.Errorf("removing the service: %w", err)
	}
	fmt.Fprintf(stdout, "Removed the %s service.\n", installedService)

	if _, err := netsh(`netsh advfirewall firewall delete rule name="` + firewallRule + `"`); err == nil {
		fmt.Fprintf(stdout, "Removed the firewall rule %q.\n", firewallRule)
	}
	if err := eventlog.Remove(eventSource); err == nil {
		fmt.Fprintf(stdout, "Removed the Event Log source %s; its entries stay in the log.\n", eventSource)
	}
	return nil
}
