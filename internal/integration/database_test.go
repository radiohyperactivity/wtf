package integration

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"strconv"
	"strings"
	"sync"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/radiohyperactivity/wtf/db"
	"github.com/radiohyperactivity/wtf/internal/config"
	"github.com/radiohyperactivity/wtf/internal/schema"
)

// testDatabase is the test database with its schema built from nothing, for
// every test: the tests of the accessors call the database directly, and
// the others go through the API (setup).
type testDatabase struct {
	dba       *pgxpool.Pool // the schema owner
	api       *pgxpool.Pool // the API role, as wtfd serve connects
	dbaConfig *pgx.ConnConfig
	apiUser   string
}

var (
	databaseOnce    sync.Once
	sharedDatabase  *testDatabase
	databaseErr     error
	databaseSkipMsg string
)

// database connects to the test database once per test run and builds its
// schema from nothing, as on a new installation. It skips the test when no
// test database is configured.
func database(t *testing.T) *testDatabase {
	t.Helper()
	databaseOnce.Do(func() { sharedDatabase, databaseSkipMsg, databaseErr = openDatabase() })
	if databaseSkipMsg != "" {
		t.Skip(databaseSkipMsg)
	}
	if databaseErr != nil {
		t.Fatal(databaseErr)
	}
	return sharedDatabase
}

func openDatabase() (*testDatabase, string, error) {
	name := os.Getenv("WTFD_TEST_DATABASE_NAME")
	if name == "" {
		return nil, "WTFD_TEST_DATABASE_NAME is not set", nil
	}
	if !strings.HasSuffix(name, "_test") {
		return nil, "", fmt.Errorf("WTFD_TEST_DATABASE_NAME %q must end in _test: the tests delete all its data", name)
	}
	port, err := strconv.Atoi(getenv("WTFD_TEST_DATABASE_PORT", "5432"))
	if err != nil {
		return nil, "", fmt.Errorf("WTFD_TEST_DATABASE_PORT: %w", err)
	}
	settings := &config.Database{
		Host:    getenv("WTFD_TEST_DATABASE_HOST", "localhost"),
		Port:    port,
		Name:    name,
		SSLMode: getenv("WTFD_TEST_DATABASE_SSLMODE", "prefer"),
		DBAUser: getenv("WTFD_DBA_DATABASE_USER", "wtf_dba"),
		APIUser: getenv("WTFD_API_DATABASE_USER", "wtf_api"),
	}
	ctx := context.Background()
	quiet := slog.New(slog.NewTextHandler(io.Discard, nil))

	dbaConfig, err := settings.ConnConfig(settings.DBAUser, os.Getenv(config.DBAPasswordEnv), "wtfd integration test")
	if err != nil {
		return nil, "", err
	}
	if err := dropEverything(ctx, dbaConfig); err != nil {
		return nil, "", err
	}
	if _, err := schema.Run(ctx, schema.Options{
		ConnConfig: dbaConfig,
		APIUser:    settings.APIUser,
		Scripts:    db.Scripts,
		Logger:     quiet,
	}); err != nil {
		return nil, "", fmt.Errorf("wtfd schema: %w", err)
	}

	dba, err := pgxpool.New(ctx, settings.ConnString(settings.DBAUser, os.Getenv(config.DBAPasswordEnv), "wtfd integration test"))
	if err != nil {
		return nil, "", err
	}
	apiConfig, err := pgxpool.ParseConfig(settings.ConnString(settings.APIUser, os.Getenv(config.APIPasswordEnv), "wtfd integration test"))
	if err != nil {
		return nil, "", err
	}
	apiConfig.ConnConfig.RuntimeParams["search_path"] = "public"
	api, err := pgxpool.NewWithConfig(ctx, apiConfig)
	if err != nil {
		return nil, "", err
	}
	return &testDatabase{dba: dba, api: api, dbaConfig: dbaConfig, apiUser: settings.APIUser}, "", nil
}

// sqlState returns the SQLSTATE of a database error, or "" for none.
func sqlState(err error) string {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) {
		return pgErr.Code
	}
	return ""
}

// wantState fails the test unless err is a database error with SQLSTATE
// state whose message contains text.
func wantState(t *testing.T, err error, state, text string) {
	t.Helper()
	if err == nil {
		t.Fatalf("no error, want %s (%q)", state, text)
	}
	if got := sqlState(err); got != state {
		t.Fatalf("SQLSTATE %s, want %s: %v", got, state, err)
	}
	if !strings.Contains(err.Error(), text) {
		t.Fatalf("error %q does not contain %q", err.Error(), text)
	}
}

// inTx runs f in a transaction of the DBA role. The transaction commits
// when f returns nil, so that the rules that run at commit run too, and
// rolls back otherwise. It returns f's error, or the commit's.
func (d *testDatabase) inTx(t *testing.T, f func(tx pgx.Tx) error) error {
	t.Helper()
	ctx := context.Background()
	tx, err := d.dba.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	if err := f(tx); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// exec runs one statement in a transaction of its own, and returns its
// error.
func (d *testDatabase) exec(t *testing.T, sql string, args ...any) error {
	t.Helper()
	return d.inTx(t, func(tx pgx.Tx) error {
		_, err := tx.Exec(context.Background(), sql, args...)
		return err
	})
}

// mustExec runs one statement in a transaction of its own, and fails the
// test if it fails.
func (d *testDatabase) mustExec(t *testing.T, sql string, args ...any) {
	t.Helper()
	if err := d.exec(t, sql, args...); err != nil {
		t.Fatalf("%s: %v", sql, err)
	}
}

// id runs a query in a transaction of its own that returns one id (an
// INSERT … RETURNING id), and returns it.
func (d *testDatabase) id(t *testing.T, sql string, args ...any) string {
	t.Helper()
	var id string
	if err := d.inTx(t, func(tx pgx.Tx) error {
		return tx.QueryRow(context.Background(), sql, args...).Scan(&id)
	}); err != nil {
		t.Fatalf("%s: %v", sql, err)
	}
	return id
}

// value reads one value as the DBA role.
func (d *testDatabase) value(t *testing.T, sql string, args ...any) any {
	t.Helper()
	var v any
	if err := d.dba.QueryRow(context.Background(), sql, args...).Scan(&v); err != nil {
		t.Fatalf("%s: %v", sql, err)
	}
	return v
}

// reset empties the data: the stock, items, classes and locations. The
// accounts stay, and so does the meta row, with the label code counter (so
// that codes are never handed out twice) and the trees' versions.
func (d *testDatabase) reset(t *testing.T) {
	t.Helper()
	if _, err := d.dba.Exec(context.Background(),
		"TRUNCATE public.stock, public.item, public.class, public.location"); err != nil {
		t.Fatal(err)
	}
}
