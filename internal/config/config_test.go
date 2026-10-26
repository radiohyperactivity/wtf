package config

import (
	"flag"
	"testing"
)

func TestQuote(t *testing.T) {
	tests := map[string]string{
		"plain":       "'plain'",
		"it's":        `'it\'s'`,
		`back\slash`:  `'back\\slash'`,
		"with spaces": "'with spaces'",
	}
	for in, want := range tests {
		if got := quote(in); got != want {
			t.Errorf("quote(%q) = %s, want %s", in, got, want)
		}
	}
}

func TestEnvironmentAndFlags(t *testing.T) {
	t.Setenv("WTFD_DATABASE_HOST", "db.example")
	t.Setenv("WTFD_DATABASE_PORT", "6543")

	fs := flag.NewFlagSet("test", flag.ContinueOnError)
	d := RegisterDatabase(fs)
	if err := fs.Parse([]string{"--database-port", "7654"}); err != nil {
		t.Fatal(err)
	}
	if err := d.Validate(); err != nil {
		t.Fatal(err)
	}
	if d.Host != "db.example" {
		t.Errorf("host = %q, want the environment value", d.Host)
	}
	if d.Port != 7654 {
		t.Errorf("port = %d, want the flag value", d.Port)
	}

	cfg, err := d.ConnConfig("wtf_dba", "pa ss'word", "test")
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Host != "db.example" || cfg.Port != 7654 || cfg.User != "wtf_dba" || cfg.Password != "pa ss'word" {
		t.Errorf("unexpected config: host=%q port=%d user=%q password=%q", cfg.Host, cfg.Port, cfg.User, cfg.Password)
	}
}

func TestInvalidEnvironment(t *testing.T) {
	t.Setenv("WTFD_DATABASE_PORT", "abc")
	d := RegisterDatabase(flag.NewFlagSet("test", flag.ContinueOnError))
	if err := d.Validate(); err == nil {
		t.Error("expected an error for a non-numeric port")
	}
}
