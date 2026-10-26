// Package integration tests the whole stack against a real PostgreSQL test
// database: the schema scripts (applied with the code of "wtfd schema"), the
// database functions and triggers, and the HTTP layer of "wtfd serve".
//
// The tests are skipped unless WTFD_TEST_DATABASE_NAME is set. Its value must
// end in "_test": the tests delete all data in it. See README.md, "Tests".
package integration

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"strings"
	"sync"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/radiohyperactivity/wtf/db"
	"github.com/radiohyperactivity/wtf/internal/config"
	"github.com/radiohyperactivity/wtf/internal/files"
	"github.com/radiohyperactivity/wtf/internal/schema"
	"github.com/radiohyperactivity/wtf/internal/serve"
	"github.com/radiohyperactivity/wtf/internal/tenant"
)

type environment struct {
	dba       *pgxpool.Pool // the schema owner, for resetting data
	api       *pgxpool.Pool // the API role, as wtfd serve connects
	handler   http.Handler
	dbaConfig *pgx.ConnConfig
	apiUser   string
	files     *files.Store

	// The tenant all requests go to by default, and its admin's token.
	host, token string
	// A second tenant, for isolation tests.
	otherHost, otherToken string
}

// The two tenants of every test run; each admin has every privilege.
const (
	testHost  = "test.wtf.local"
	otherHost = "other.wtf.local"
)

// Attachments in tests are limited to 1 MiB.
const testMaxAttachment = 1 << 20

var filesDir string // temporary files directory, removed by TestMain

func TestMain(m *testing.M) {
	code := m.Run()
	if filesDir != "" {
		_ = os.RemoveAll(filesDir)
	}
	os.Exit(code)
}

var (
	setupOnce sync.Once
	shared    *environment
	setupErr  error
	skipMsg   string
)

// setup connects to the test database once per test run and brings its
// schema up to date. It skips the test when no test database is configured.
func setup(t *testing.T) *environment {
	t.Helper()
	setupOnce.Do(func() { shared, skipMsg, setupErr = connect() })
	if skipMsg != "" {
		t.Skip(skipMsg)
	}
	if setupErr != nil {
		t.Fatal(setupErr)
	}
	return shared
}

func connect() (*environment, string, error) {
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
	database := &config.Database{
		Host:    getenv("WTFD_TEST_DATABASE_HOST", "localhost"),
		Port:    port,
		Name:    name,
		SSLMode: getenv("WTFD_TEST_DATABASE_SSLMODE", "prefer"),
		DBAUser: getenv("WTFD_DBA_DATABASE_USER", "wtf_dba"),
		APIUser: getenv("WTFD_API_DATABASE_USER", "wtf_api"),
	}
	ctx := context.Background()
	quiet := slog.New(slog.NewTextHandler(io.Discard, nil))

	dbaConfig, err := database.ConnConfig(database.DBAUser, os.Getenv(config.DBAPasswordEnv), "wtfd integration test")
	if err != nil {
		return nil, "", err
	}
	// The test database's data is disposable. Empty it before migrating,
	// because some migrations (0006) only run on a database without data.
	if err := emptyTestData(ctx, dbaConfig); err != nil {
		return nil, "", err
	}
	if _, err := schema.Run(ctx, schema.Options{
		ConnConfig: dbaConfig,
		APIUser:    database.APIUser,
		Scripts:    db.Scripts,
		Logger:     quiet,
	}); err != nil {
		return nil, "", fmt.Errorf("wtfd schema: %w", err)
	}

	dba, err := pgxpool.New(ctx, database.ConnString(database.DBAUser, os.Getenv(config.DBAPasswordEnv), "wtfd integration test"))
	if err != nil {
		return nil, "", err
	}
	apiConfig, err := pgxpool.ParseConfig(database.ConnString(database.APIUser, os.Getenv(config.APIPasswordEnv), "wtfd integration test"))
	if err != nil {
		return nil, "", err
	}
	apiConfig.ConnConfig.RuntimeParams["search_path"] = "public"
	api, err := pgxpool.NewWithConfig(ctx, apiConfig)
	if err != nil {
		return nil, "", err
	}
	if err := serve.CheckSchema(ctx, api, db.Scripts); err != nil {
		return nil, "", err
	}
	if filesDir, err = os.MkdirTemp("", "wtfd-files-*"); err != nil {
		return nil, "", err
	}
	store, err := files.Open(filesDir)
	if err != nil {
		return nil, "", err
	}

	e := &environment{
		dba:       dba,
		api:       api,
		handler:   serve.NewHandler(api, quiet, 1<<20, store, testMaxAttachment, ""),
		dbaConfig: dbaConfig,
		apiUser:   database.APIUser,
		files:     store,
	}

	// Start from nothing: no tenants, accounts or data.
	if _, err := dba.Exec(ctx, "TRUNCATE tenant, file CASCADE"); err != nil {
		return nil, "", err
	}
	conn, err := tenant.Connect(ctx, dbaConfig)
	if err != nil {
		return nil, "", err
	}
	defer conn.Close(ctx)
	if e.host, e.token, err = e.newTenant(ctx, conn, "test", testHost, "admin@test.local"); err != nil {
		return nil, "", err
	}
	if e.otherHost, e.otherToken, err = e.newTenant(ctx, conn, "other", otherHost, "admin@other.local"); err != nil {
		return nil, "", err
	}
	return e, "", nil
}

// newTenant creates a tenant as "wtfd tenant create" does, and logs its
// first account in.
func (e *environment) newTenant(ctx context.Context, conn *pgx.Conn, name, host, email string) (string, string, error) {
	password, err := tenant.Create(ctx, conn, name, host, email)
	if err != nil {
		return "", "", err
	}
	token, err := e.login(host, email, password)
	return host, token, err
}

// login logs in through the API and returns the session token, which the
// API sends as the session cookie.
func (e *environment) login(host, email, password string) (string, error) {
	data, _ := json.Marshal(map[string]string{"email": email, "password": password})
	req := httptest.NewRequest("POST", "/api/v1/login", bytes.NewReader(data))
	req.Host = host
	rec := httptest.NewRecorder()
	e.handler.ServeHTTP(rec, req)
	token := sessionCookie(rec.Result())
	if rec.Code != 200 || token == "" {
		return "", fmt.Errorf("login %s at %s: %d %s", email, host, rec.Code, rec.Body.String())
	}
	return token, nil
}

// sessionCookie returns the value of the session cookie a response sets.
func sessionCookie(resp *http.Response) string {
	for _, c := range resp.Cookies() {
		if c.Name == "wtf_session" {
			return c.Value
		}
	}
	return ""
}

// apiPath puts API paths under /api/v1; paths that already start with
// /api/ (health, other versions) and the web app's are left alone.
func apiPath(path string) string {
	if strings.HasPrefix(path, "/api/") || path == "/api" {
		return path
	}
	return "/api/v1" + path
}

// newRequest builds a request to the default tenant, logged in as its admin.
// headers override that: "Host" picks another tenant, "Cookie" another login
// ("" sends none). path is relative to /api/v1 unless it starts with /api/.
func (e *environment) newRequest(method, path string, body io.Reader, headers ...string) *http.Request {
	req := httptest.NewRequest(method, apiPath(path), body)
	req.Host = e.host
	req.Header.Set("Cookie", "wtf_session="+e.token)
	for i := 0; i+1 < len(headers); i += 2 {
		switch {
		case headers[i] == "Host":
			req.Host = headers[i+1]
		case headers[i+1] == "":
			req.Header.Del(headers[i])
		default:
			req.Header.Set(headers[i], headers[i+1])
		}
	}
	return req
}

// as returns the headers for a request as another login: its tenant's host
// and its session.
func as(host, token string) []string {
	return []string{"Host", host, "Cookie", "wtf_session=" + token}
}

// emptyTestData deletes all data from a test database at any schema version
// (or none yet).
func emptyTestData(ctx context.Context, cfg *pgx.ConnConfig) error {
	conn, err := tenant.Connect(ctx, cfg)
	if err != nil {
		return err
	}
	defer conn.Close(ctx)
	var hasData bool
	if err := conn.QueryRow(ctx, "SELECT to_regclass('public.item') IS NOT NULL").Scan(&hasData); err != nil || !hasData {
		return err
	}
	_, err = conn.Exec(ctx, "TRUNCATE item, class, attribute, location, stock, attachment CASCADE")
	return err
}

func getenv(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

// reset deletes all user data. System data (quantities, units, unit groups)
// stays.
func (e *environment) reset(t *testing.T) {
	t.Helper()
	_, err := e.dba.Exec(context.Background(),
		"TRUNCATE history, attachment, file, stock_value, stock, value, item, class_attribute, attribute_option, attribute, class, location")
	if err != nil {
		t.Fatal(err)
	}
}

// response is the result of an API request.
type response struct {
	status int
	header http.Header
	body   any // decoded JSON, nil when there is no body
}

// call sends a request to the API handler. body is encoded as JSON unless it
// is a string, which is sent as is.
func (e *environment) call(t *testing.T, method, path string, body any, headers ...string) response {
	t.Helper()
	var reader io.Reader
	switch b := body.(type) {
	case nil:
	case string:
		reader = strings.NewReader(b)
	default:
		data, err := json.Marshal(b)
		if err != nil {
			t.Fatal(err)
		}
		reader = bytes.NewReader(data)
	}
	req := e.newRequest(method, path, reader, headers...)
	rec := httptest.NewRecorder()
	e.handler.ServeHTTP(rec, req)

	r := response{status: rec.Code, header: rec.Header()}
	if rec.Body.Len() > 0 {
		if err := json.Unmarshal(rec.Body.Bytes(), &r.body); err != nil {
			t.Fatalf("%s %s: response is not JSON: %s", method, path, rec.Body.String())
		}
	}
	return r
}

// expect calls the API and fails the test unless the status matches.
func (e *environment) expect(t *testing.T, status int, method, path string, body any, headers ...string) response {
	t.Helper()
	r := e.call(t, method, path, body, headers...)
	if r.status != status {
		t.Fatalf("%s %s: status %d, want %d; body: %v", method, path, r.status, status, r.body)
	}
	return r
}

// get walks decoded JSON: get(t, v, "values", 0, "display", "value").
func get(t *testing.T, v any, path ...any) any {
	t.Helper()
	for _, step := range path {
		switch s := step.(type) {
		case string:
			m, ok := v.(map[string]any)
			if !ok {
				t.Fatalf("get %v: %v is not an object", path, v)
			}
			v = m[s]
		case int:
			a, ok := v.([]any)
			if !ok || s >= len(a) {
				t.Fatalf("get %v: %v has no element %d", path, v, s)
			}
			v = a[s]
		}
	}
	return v
}

func str(t *testing.T, v any, path ...any) string {
	t.Helper()
	s, ok := get(t, v, path...).(string)
	if !ok {
		t.Fatalf("get %v: not a string", path)
	}
	return s
}

func num(t *testing.T, v any, path ...any) float64 {
	t.Helper()
	n, ok := get(t, v, path...).(float64)
	if !ok {
		t.Fatalf("get %v: not a number: %v", path, get(t, v, path...))
	}
	return n
}

// unitGroup returns the id of a seeded unit group by name.
func (e *environment) unitGroup(t *testing.T, name string) string {
	t.Helper()
	r := e.expect(t, 200, "GET", "/unit-groups", nil)
	for _, g := range r.body.([]any) {
		if str(t, g, "name") == name {
			return str(t, g, "id")
		}
	}
	t.Fatalf("unit group %q not found", name)
	return ""
}
