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
	"github.com/radiohyperactivity/wtf/internal/admin"
	"github.com/radiohyperactivity/wtf/internal/config"
	"github.com/radiohyperactivity/wtf/internal/files"
	"github.com/radiohyperactivity/wtf/internal/schema"
	"github.com/radiohyperactivity/wtf/internal/serve"
)

type environment struct {
	dba       *pgxpool.Pool // the schema owner, for resetting data
	api       *pgxpool.Pool // the API role, as wtfd serve connects
	handler   http.Handler
	dbaConfig *pgx.ConnConfig
	apiUser   string
	files     *files.Store

	// The session of the account all requests are sent as by default, which
	// has every privilege.
	token string
}

// The tenant of every test run, and its first account. Requests reach it
// by testHostname, whose first label is its host.
const (
	testHost     = "test"
	testHostname = "test.wtf.example"
	adminEmail   = "admin@test.local"
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
	// The test database is disposable: every run builds its schema from
	// nothing, as on a new installation.
	if err := dropEverything(ctx, dbaConfig); err != nil {
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

	// The tenant and its first account, as "wtfd tenant create" makes
	// them, logged in.
	conn, err := admin.Connect(ctx, dbaConfig)
	if err != nil {
		return nil, "", err
	}
	defer conn.Close(ctx)
	password, err := admin.CreateTenant(ctx, conn, testHost, adminEmail)
	if err != nil {
		return nil, "", err
	}
	if e.token, err = e.login(adminEmail, password); err != nil {
		return nil, "", err
	}
	return e, "", nil
}

// login logs in to the test tenant through the API and returns the session
// token, which the API sends as the session cookie.
func (e *environment) login(email, password string) (string, error) {
	return e.loginTo(testHostname, email, password)
}

// loginTo logs in at hostname (and so to its tenant).
func (e *environment) loginTo(hostname, email, password string) (string, error) {
	data, _ := json.Marshal(map[string]string{"email": email, "password": password})
	req := httptest.NewRequest("POST", "/api/v1/login", bytes.NewReader(data))
	req.Host = hostname
	rec := httptest.NewRecorder()
	e.handler.ServeHTTP(rec, req)
	token := sessionCookie(rec.Result())
	if rec.Code != 200 || token == "" {
		return "", fmt.Errorf("login %s: %d %s", email, rec.Code, rec.Body.String())
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

// newRequest builds a request to the test tenant, logged in as the admin.
// headers override that: "Cookie" another login ("" sends none), "Host"
// another hostname. path is relative to /api/v1 unless it starts with
// /api/.
func (e *environment) newRequest(method, path string, body io.Reader, headers ...string) *http.Request {
	req := httptest.NewRequest(method, apiPath(path), body)
	req.Host = testHostname
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

// as returns the headers for a request as another login.
func as(token string) []string {
	return []string{"Cookie", "wtf_session=" + token}
}

// dropEverything drops all that the DBA role owns in the test database: the
// schema, its data and wtfd's bookkeeping.
func dropEverything(ctx context.Context, cfg *pgx.ConnConfig) error {
	conn, err := admin.Connect(ctx, cfg)
	if err != nil {
		return err
	}
	defer conn.Close(ctx)
	_, err = conn.Exec(ctx, "DROP OWNED BY CURRENT_USER CASCADE")
	return err
}

func getenv(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

// reset deletes all user data, of every tenant, and the tenants' choices
// of units. Tenants, units and accounts stay.
func (e *environment) reset(t *testing.T) {
	t.Helper()
	_, err := e.dba.Exec(context.Background(),
		"TRUNCATE history, item_attachment, stock_attachment, location_attachment, class_attachment, stock_value, stock, value, item, class_attribute, attribute_option, attribute, class, location, tenant_quantity, tenant_unit_family")
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

// unit returns the id of a unit the test tenant sees, by family name and
// symbol.
func (e *environment) unit(t *testing.T, family, symbol string) string {
	t.Helper()
	for _, f := range e.expect(t, 200, "GET", "/unit-families", nil).body.([]any) {
		if str(t, f, "name") != family {
			continue
		}
		for _, u := range get(t, f, "units").([]any) {
			if str(t, u, "symbol") == symbol {
				return str(t, u, "id")
			}
		}
	}
	t.Fatalf("unit %s of %s not found", symbol, family)
	return ""
}

// tenantStore is the test tenant's directory in the files directory.
func (e *environment) tenantStore(t *testing.T) *files.Store {
	t.Helper()
	store, err := e.files.Tenant(testHost)
	if err != nil {
		t.Fatal(err)
	}
	return store
}

// dropTenantUnits removes the units, families and quantities tenants have
// imported, and the attributes and items that use them, so other tests see
// only the global ones.
func (e *environment) dropTenantUnits(t *testing.T) {
	t.Helper()
	for _, sql := range []string{
		"DELETE FROM value v USING attribute a, unit u WHERE v.attribute = a.id AND a.unit = u.id AND u.tenant IS NOT NULL",
		"DELETE FROM stock_value v USING attribute a, unit u WHERE v.attribute = a.id AND a.unit = u.id AND u.tenant IS NOT NULL",
		"DELETE FROM class_attribute ca USING attribute a, unit u WHERE ca.attribute = a.id AND a.unit = u.id AND u.tenant IS NOT NULL",
		"DELETE FROM attribute a USING unit u WHERE a.unit = u.id AND u.tenant IS NOT NULL",
		"DELETE FROM item i USING unit u WHERE i.unit = u.id AND u.tenant IS NOT NULL",
		"DELETE FROM unit WHERE tenant IS NOT NULL",
		"DELETE FROM unit_family WHERE tenant IS NOT NULL",
		"DELETE FROM quantity WHERE tenant IS NOT NULL",
	} {
		if _, err := e.dba.Exec(context.Background(), sql); err != nil {
			t.Error(err)
		}
	}
}
