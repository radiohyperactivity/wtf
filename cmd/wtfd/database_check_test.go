package main

import (
	"bytes"
	"context"
	"os"
	"strings"
	"testing"

	"github.com/radiohyperactivity/wtf/internal/config"
)

// TestDatabaseCheck runs "wtfd database check" against the test database of
// the integration tests (internal/integration), which it only reads. It is
// skipped when none is configured.
func TestDatabaseCheck(t *testing.T) {
	name := os.Getenv("WTFD_TEST_DATABASE_NAME")
	if name == "" {
		t.Skip("WTFD_TEST_DATABASE_NAME is not set")
	}
	host := os.Getenv("WTFD_TEST_DATABASE_HOST")
	if host == "" {
		host = "localhost"
	}
	check := func(args ...string) (int, string, string) {
		var stdout, stderr bytes.Buffer
		args = append([]string{"database", "check", "--database-host", host, "--database-name", name}, args...)
		code := run(context.Background(), args, &stdout, &stderr)
		return code, stdout.String(), stderr.String()
	}

	code, out, errs := check()
	if code != exitOK {
		t.Fatalf("exit %d: %s", code, errs)
	}
	for _, want := range []string{"PostgreSQL: ", "Schema: ", "Accounts: "} {
		if !strings.Contains(out, want) {
			t.Errorf("no %q in %q", want, out)
		}
	}

	t.Run("wrong password", func(t *testing.T) {
		t.Setenv(config.DBAPasswordEnv, "not the password")
		t.Setenv("PGPASSFILE", os.DevNull)
		code, _, errs := check()
		if code != exitFailure || !strings.Contains(errs, "the password for wtf_dba is wrong") {
			t.Errorf("exit %d: %q", code, errs)
		}
	})

	// A server whose pg_hba.conf names its databases says that it has no
	// line for one that isn't there.
	t.Run("no such database", func(t *testing.T) {
		code, _, errs := check("--database-name", "wtf_not_there_test")
		if code != exitFailure || !strings.Contains(errs, "wtf_not_there_test") ||
			!(strings.Contains(errs, "there is no database") || strings.Contains(errs, "is the database's name right?")) {
			t.Errorf("exit %d: %q", code, errs)
		}
	})

	t.Run("unreachable", func(t *testing.T) {
		code, _, errs := check("--database-host", "127.0.0.1", "--database-port", "1")
		if code != exitFailure || !strings.Contains(errs, "can't reach PostgreSQL on 127.0.0.1, port 1") {
			t.Errorf("exit %d: %q", code, errs)
		}
	})
}
