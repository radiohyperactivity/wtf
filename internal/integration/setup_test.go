// Package integration tests the whole stack against a real PostgreSQL test
// database: the schema scripts (applied with the code of "wtfd schema"), the
// database functions, and the HTTP layer of "wtfd serve".
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
	"regexp"
	"strings"
	"sync"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/radiohyperactivity/wtf/db"
	"github.com/radiohyperactivity/wtf/internal/admin"
	"github.com/radiohyperactivity/wtf/internal/files"
	"github.com/radiohyperactivity/wtf/internal/serve"
)

type environment struct {
	dba       *pgxpool.Pool // the schema owner, for resetting data
	api       *pgxpool.Pool // the API role, as wtfd serve connects
	handler   http.Handler
	dbaConfig *pgx.ConnConfig
	apiUser   string
	files     *files.Store

	// The session of the account all requests are sent as by default, an
	// admin.
	token string
}

// The first account of every test run.
const adminEmail = "admin@test.local"

// Files in tests are limited to 1 MiB.
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
)

// setup gives a test the API on the test database (database, which builds
// the schema once per test run), with the first account, an admin, logged
// in. It skips the test when no test database is configured.
func setup(t *testing.T) *environment {
	t.Helper()
	d := database(t)
	setupOnce.Do(func() { shared, setupErr = connect(d) })
	if setupErr != nil {
		t.Fatal(setupErr)
	}
	return shared
}

func connect(d *testDatabase) (*environment, error) {
	ctx := context.Background()
	quiet := slog.New(slog.NewTextHandler(io.Discard, nil))
	if err := serve.CheckSchema(ctx, d.api, db.Scripts); err != nil {
		return nil, err
	}
	var err error
	if filesDir, err = os.MkdirTemp("", "wtfd-files-*"); err != nil {
		return nil, err
	}
	store, err := files.Open(filesDir)
	if err != nil {
		return nil, err
	}
	e := &environment{
		dba:       d.dba,
		api:       d.api,
		handler:   serve.NewHandler(d.api, quiet, 1<<20, store, testMaxAttachment, "", nil),
		dbaConfig: d.dbaConfig,
		apiUser:   d.apiUser,
		files:     store,
	}

	// The first account, as "wtfd account create" makes it, logged in.
	conn, err := admin.Connect(ctx, d.dbaConfig)
	if err != nil {
		return nil, err
	}
	defer conn.Close(ctx)
	if _, err := conn.Exec(ctx, "DELETE FROM public.account WHERE email = $1", adminEmail); err != nil {
		return nil, err
	}
	password, err := admin.CreateAccount(ctx, conn, adminEmail, "admin")
	if err != nil {
		return nil, err
	}
	if e.token, err = e.login(adminEmail, password); err != nil {
		return nil, err
	}
	return e, nil
}

// login logs in through the API and returns the session token, which the
// API sends as the session cookie.
func (e *environment) login(email, password string) (string, error) {
	data, _ := json.Marshal(map[string]any{"email": email, "password": password, "client": "integration test", "max_idle": nil})
	req := httptest.NewRequest("POST", "/api/v1/login", bytes.NewReader(data))
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

// newRequest builds a request, logged in as the admin. headers override
// that: "Cookie" another login ("" sends none). path is relative to /api/v1
// unless it starts with /api/.
func (e *environment) newRequest(method, path string, body io.Reader, headers ...string) *http.Request {
	req := httptest.NewRequest(method, apiPath(path), body)
	req.Header.Set("Cookie", "wtf_session="+e.token)
	for i := 0; i+1 < len(headers); i += 2 {
		switch {
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

// reset empties the data (testDatabase.reset).
func (e *environment) reset(t *testing.T) {
	t.Helper()
	database(t).reset(t)
}

// response is the result of an API request.
type response struct {
	status int
	header http.Header
	body   any // decoded JSON, nil when there is no body
}

// requiredFields are the fields that creating (and a few other requests)
// require, with the value a test gets when it leaves one out: most tests
// only say what they test. A test of a missing field sends its body as a
// string, which call sends as is.
var requiredFields = []struct {
	method string
	path   *regexp.Regexp
	fields map[string]any
}{
	{"POST", regexp.MustCompile(`^/classes$`), map[string]any{"parent": nil, "container": false}},
	{"POST", regexp.MustCompile(`^/locations$`), map[string]any{"parent": nil, "container": false, "grid": nil}},
	{"POST", regexp.MustCompile(`^/items$`), map[string]any{"unit": nil, "values": map[string]any{}}},
	{"POST", regexp.MustCompile(`^/stock$`), map[string]any{"amount": nil, "reference": nil, "serial": nil, "values": map[string]any{}}},
	{"POST", regexp.MustCompile(`^/stock/[^/]+/move$`), map[string]any{"amount": nil}},
	{"POST", regexp.MustCompile(`^/stock/[^/]+/merge$`), map[string]any{"amount": nil, "resolve": nil}},
	{"POST", regexp.MustCompile(`^/accounts$`), map[string]any{"password": nil, "role": "viewer"}},
	{"POST", regexp.MustCompile(`^/login$`), map[string]any{"client": nil, "max_idle": nil}},
	{"PUT", regexp.MustCompile(`^/me/password$`), map[string]any{"end_other_sessions": true}},
}

// withRequired adds the required fields a body leaves out (requiredFields),
// and with a password in an account's patch, end_sessions true.
func withRequired(method, path string, body map[string]any) map[string]any {
	path, _, _ = strings.Cut(path, "?")
	filled := map[string]any{}
	for _, r := range requiredFields {
		if r.method == method && r.path.MatchString(path) {
			for k, v := range r.fields {
				filled[k] = v
			}
		}
	}
	if _, ok := body["password"]; ok && method == "PATCH" && strings.HasPrefix(path, "/accounts/") {
		filled["end_sessions"] = true
	}
	for k, v := range body {
		filled[k] = v
	}
	return filled
}

// call sends a request to the API handler. body is encoded as JSON unless it
// is a string, which is sent as is; a map, or no body, gets the fields the
// request requires and it leaves out (withRequired).
func (e *environment) call(t *testing.T, method, path string, body any, headers ...string) response {
	t.Helper()
	var reader io.Reader
	if m, ok := body.(map[string]any); ok || body == nil {
		if filled := withRequired(method, path, m); body != nil || len(filled) > 0 {
			body = filled
		}
	}
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
