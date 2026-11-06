package config

import (
	"flag"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseFile(t *testing.T) {
	settings, err := ParseFile("# comment\r\n\r\ndatabase-host = db.example \r\nfiles-directory=C:\\Data\\files\n")
	if err != nil {
		t.Fatal(err)
	}
	want := []Setting{{"database-host", "db.example", 3}, {"files-directory", `C:\Data\files`, 4}}
	if len(settings) != len(want) {
		t.Fatalf("settings %v, want %v", settings, want)
	}
	for i := range want {
		if settings[i] != want[i] {
			t.Errorf("setting %d: %v, want %v", i, settings[i], want[i])
		}
	}
	for _, bad := range []string{"just words", "= value", "listen = a\nlisten = b"} {
		if _, err := ParseFile(bad); err == nil {
			t.Errorf("ParseFile(%q) took it", bad)
		}
	}
}

func TestUpdateFile(t *testing.T) {
	old := "# mine\r\nlisten = 0.0.0.0:8080\r\n# web-root = old\r\nweb-root = /srv/web\r\n"
	got := UpdateFile(old, "# header\n", []Setting{{Key: "listen", Value: "127.0.0.1:8080"}, {Key: "database-host", Value: "db"}})
	want := "# mine\nlisten = 127.0.0.1:8080\n# web-root = old\nweb-root = /srv/web\ndatabase-host = db\n"
	if got != want {
		t.Errorf("UpdateFile =\n%s\nwant\n%s", got, want)
	}
	if got := UpdateFile("", "# header\n", []Setting{{Key: "listen", Value: "x"}}); got != "# header\nlisten = x\n" {
		t.Errorf("a new file: %q", got)
	}
}

// Each flag's help names the environment variable EnvName gives it.
func TestEnvName(t *testing.T) {
	fs := flag.NewFlagSet("settings", flag.ContinueOnError)
	RegisterDatabase(fs)
	RegisterFiles(fs)
	RegisterGC(fs)
	RegisterServe(fs)
	fs.VisitAll(func(f *flag.Flag) {
		if want := "(env " + EnvName(f.Name) + ")"; !strings.Contains(f.Usage, want) {
			t.Errorf("--%s: help %q doesn't say %s", f.Name, f.Usage, want)
		}
	})
}

func TestApply(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, FileName)
	os.WriteFile(path, []byte("database-host = from-file\ndatabase-port = 6000\ndatabase-name = from-file\nmin-age = 2h\n"), 0o600)
	os.WriteFile(filepath.Join(dir, PasswordFile), nil, 0o600)
	t.Setenv(ConfigEnv, path)
	t.Setenv("WTFD_DATABASE_NAME", "from-env")
	t.Setenv(passFileEnv, "")
	os.Unsetenv(passFileEnv)
	os.Unsetenv("WTFD_DATABASE_HOST")
	os.Unsetenv("WTFD_DATABASE_PORT")

	fs := flag.NewFlagSet("wtfd schema", flag.ContinueOnError)
	d := RegisterDatabase(fs)
	file := RegisterFile(fs)
	if err := fs.Parse([]string{"--database-port", "7000"}); err != nil {
		t.Fatal(err)
	}
	if err := file.Apply(fs, func(s string) { t.Error(s) }); err != nil {
		t.Fatal(err)
	}
	// The flag wins, then the environment, then the file; min-age isn't
	// schema's, and is passed over.
	if d.Host != "from-file" || d.Port != 7000 || d.Name != "from-env" || !file.Read {
		t.Errorf("host %q, port %d, name %q, read %v", d.Host, d.Port, d.Name, file.Read)
	}
	if got := os.Getenv(passFileEnv); got != filepath.Join(dir, PasswordFile) {
		t.Errorf("PGPASSFILE %q, want the one beside the config file", got)
	}

	os.WriteFile(path, []byte("databse-host = typo\n"), 0o600)
	fs = flag.NewFlagSet("wtfd schema", flag.ContinueOnError)
	RegisterDatabase(fs)
	file = RegisterFile(fs)
	fs.Parse(nil)
	if err := file.Apply(fs, func(string) {}); err == nil || !strings.Contains(err.Error(), "databse-host") {
		t.Errorf("an unknown key: %v", err)
	}

	// A file named outright must be there; one at the default place needn't.
	missing := filepath.Join(dir, "missing.conf")
	t.Setenv(ConfigEnv, missing)
	fs = flag.NewFlagSet("wtfd schema", flag.ContinueOnError)
	file = RegisterFile(fs)
	fs.Parse(nil)
	if err := file.Apply(fs, func(string) {}); err == nil {
		t.Error("a missing file named by WTFD_CONFIG was taken")
	}
	os.Unsetenv(ConfigEnv)
	fs = flag.NewFlagSet("wtfd schema", flag.ContinueOnError)
	file = RegisterFile(fs)
	file.Path = missing // as if it were the default place
	if err := file.Apply(fs, func(string) {}); err != nil {
		t.Errorf("a missing file at the default place: %v", err)
	}
}
