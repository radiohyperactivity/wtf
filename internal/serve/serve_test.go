package serve

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"

	"github.com/radiohyperactivity/wtf/openapi"
)

func testServer() *server {
	return &server{
		log:         slog.New(slog.NewTextHandler(io.Discard, nil)),
		maxBody:     1 << 20,
		tenantKnown: func(context.Context, string) (bool, error) { return true, nil },
	}
}

// Every route must be documented in openapi.yaml, and vice versa.
func TestRoutesMatchOpenAPI(t *testing.T) {
	pathLine := regexp.MustCompile(`^  (/\S*):\s*$`)
	methodLine := regexp.MustCompile(`^    (get|post|put|patch|delete):\s*$`)

	var documented []string
	current := ""
	scanner := bufio.NewScanner(bytes.NewReader(openapi.Spec))
	for scanner.Scan() {
		line := scanner.Text()
		if m := pathLine.FindStringSubmatch(line); m != nil {
			current = m[1]
		} else if m := methodLine.FindStringSubmatch(line); m != nil && current != "" {
			documented = append(documented, strings.ToUpper(m[1])+" "+current)
		} else if strings.HasPrefix(line, "components:") {
			break
		}
	}

	var routed []string
	for _, rt := range append(testServer().routes(), testServer().uploadRoutes()...) {
		routed = append(routed, rt.pattern)
	}

	slices.Sort(documented)
	slices.Sort(routed)
	for _, r := range routed {
		if !slices.Contains(documented, r) {
			t.Errorf("route %s is not in openapi.yaml", r)
		}
	}
	for _, d := range documented {
		if !slices.Contains(routed, d) {
			t.Errorf("openapi.yaml documents %s, which has no route", d)
		}
	}
}

func TestCallSQL(t *testing.T) {
	sql, values := callSQL("item_list", []arg{
		{name: "p_class", typ: "uuid", optional: true},
		{name: "p_search", typ: "text", value: "drill", optional: true},
		{name: "p_name", typ: "text"},
	})
	want := "SELECT item_list(p_search => $1::text, p_name => $2::text)"
	if sql != want {
		t.Errorf("sql = %q, want %q", sql, want)
	}
	if len(values) != 2 || values[0] != "drill" || values[1] != nil {
		t.Errorf("values = %#v", values)
	}
}

func TestParseETag(t *testing.T) {
	tests := map[string]int64{`"17"`: 17, `W/"5"`: 5, `"x", "9"`: 9}
	for header, want := range tests {
		if got, ok := parseETag(header); !ok || got != want {
			t.Errorf("parseETag(%s) = %d, %v; want %d", header, got, ok, want)
		}
	}
	for _, header := range []string{"", "*", `"abc"`} {
		if _, ok := parseETag(header); ok {
			t.Errorf("parseETag(%q) should find nothing", header)
		}
	}
}

func TestProblemFor(t *testing.T) {
	tests := []struct {
		code   string
		method string
		status int
	}{
		{"P0002", http.MethodGet, 404},
		{"22023", http.MethodPost, 400},
		{"22P02", http.MethodPost, 400},
		{"23514", http.MethodPatch, 422},
		{"23505", http.MethodPost, 409},
		{"23503", http.MethodDelete, 409},
		{"23001", http.MethodDelete, 409},
		{"23503", http.MethodPost, 422},
		{"57014", http.MethodGet, 503},
		{"42883", http.MethodGet, 500},
	}
	for _, tt := range tests {
		p, _ := problemFor(&pgconn.PgError{Code: tt.code, Message: "m"}, tt.method)
		if p.Status != tt.status {
			t.Errorf("%s on %s: status %d, want %d", tt.code, tt.method, p.Status, tt.status)
		}
	}
	if p, ok := problemFor(errors.New("boom"), http.MethodGet); ok || p.Status != 500 {
		t.Errorf("unexpected error mapped to %d, %v", p.Status, ok)
	}
}

func TestBody(t *testing.T) {
	params := body(
		field{key: "name", name: "p_name", typ: "text"},
		field{key: "parent", name: "p_parent", typ: "uuid"},
		field{key: "quantity", name: "p_quantity", typ: "numeric"},
		field{key: "values", name: "p_values", typ: "jsonb"},
	)
	request := func(s string) *http.Request {
		return httptest.NewRequest(http.MethodPost, "/", strings.NewReader(s))
	}

	args, err := params(request(`{"name": "Drill", "parent": null, "quantity": 2.5, "values": {"a": 1}}`))
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]any{}
	for _, a := range args {
		got[a.name] = a.value
	}
	if got["p_name"] != "Drill" || got["p_parent"] != nil || got["p_quantity"] != "2.5" || got["p_values"] != `{"a": 1}` {
		t.Errorf("unexpected args: %#v", got)
	}

	for _, bad := range []string{`{"nmae": "x"}`, `{"name": 5}`, `{"quantity": "5"}`, `[1]`, `not json`} {
		if _, err := params(request(bad)); err == nil {
			t.Errorf("body %s should be rejected", bad)
		}
	}
}

func TestUnknownRouteAndMethod(t *testing.T) {
	h := testServer().handler()

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/v1/nothing", nil))
	if rec.Code != 404 || rec.Header().Get("Content-Type") != "application/problem+json" {
		t.Errorf("unknown route: %d %s", rec.Code, rec.Header().Get("Content-Type"))
	}
	if rec.Header().Get("API-Revision") == "" {
		t.Error("no API-Revision header")
	}

	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodPut, "/api/v1/quantities", nil))
	if rec.Code != 405 || rec.Header().Get("Allow") != "GET" {
		t.Errorf("wrong method: %d, Allow %q", rec.Code, rec.Header().Get("Allow"))
	}
	var p problem
	if err := json.Unmarshal(rec.Body.Bytes(), &p); err != nil || p.Type != "/problems/method-not-allowed" {
		t.Errorf("405 body: %s", rec.Body.String())
	}

	// The path is checked before the database (and so the session) is involved.
	rec = httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/api/v1/items/not-a-uuid", nil)
	req.AddCookie(&http.Cookie{Name: sessionCookie, Value: "any"})
	h.ServeHTTP(rec, req)
	if rec.Code != 400 {
		t.Errorf("bad uuid: status %d, want 400", rec.Code)
	}

	// Without a session, nothing but health, openapi and login.
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/v1/items", nil))
	if rec.Code != 401 || !strings.HasPrefix(rec.Header().Get("WWW-Authenticate"), "Cookie") {
		t.Errorf("no session: status %d, WWW-Authenticate %q", rec.Code, rec.Header().Get("WWW-Authenticate"))
	}

	// The old paths, without /api/v1, are gone.
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/items", nil))
	if rec.Code != 404 {
		t.Errorf("/items: status %d, want 404", rec.Code)
	}
}

// A version this server doesn't serve gets a problem that names the one it does.
func TestUnsupportedVersion(t *testing.T) {
	h := testServer().handler()
	for _, path := range []string{"/api/v2/items", "/api/v0", "/api/v12/"} {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
		var p problem
		if err := json.Unmarshal(rec.Body.Bytes(), &p); err != nil || rec.Code != 404 ||
			p.Type != "/problems/unsupported-api-version" || !slices.Equal(p.Supported, []int{1}) {
			t.Errorf("%s: %d %s", path, rec.Code, rec.Body.String())
		}
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/version", nil))
	if rec.Code != 404 || strings.Contains(rec.Body.String(), "unsupported-api-version") {
		t.Errorf("/api/version: %d %s", rec.Code, rec.Body.String())
	}
}

// Requests that change something are refused when a browser says another
// site sent them; requests without Origin (CLI, apps) pass.
func TestCrossSite(t *testing.T) {
	for _, c := range []struct {
		method, origin string
		refused        bool
	}{
		{http.MethodPost, "", false},
		{http.MethodPost, "https://wtf.example.com", false},
		{http.MethodPost, "https://evil.example.org", true},
		{http.MethodDelete, "null", true},
		{http.MethodGet, "https://evil.example.org", false},
	} {
		r := httptest.NewRequest(c.method, "https://wtf.example.com/api/v1/login", nil)
		if c.origin != "" {
			r.Header.Set("Origin", c.origin)
		}
		if got := crossSite(r); got != c.refused {
			t.Errorf("%s from %q: refused %v, want %v", c.method, c.origin, got, c.refused)
		}
	}
	rec := httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodPost, "https://wtf.example.com/api/v1/login", strings.NewReader(`{}`))
	r.Header.Set("Origin", "https://evil.example.org")
	testServer().handler().ServeHTTP(rec, r)
	if rec.Code != 403 || !strings.Contains(rec.Body.String(), "/problems/cross-site") {
		t.Errorf("cross-site login: %d %s", rec.Code, rec.Body.String())
	}
}

func TestSessionCookie(t *testing.T) {
	rec := httptest.NewRecorder()
	setSessionCookie(rec, httptest.NewRequest(http.MethodPost, "http://wtf.lan/api/v1/login", nil), "tok", sessionMaxAge)
	c := rec.Header().Get("Set-Cookie")
	for _, want := range []string{"wtf_session=tok", "Path=/api", "Max-Age=2592000", "HttpOnly", "SameSite=Strict"} {
		if !strings.Contains(c, want) {
			t.Errorf("cookie %q lacks %q", c, want)
		}
	}
	if strings.Contains(c, "Secure") {
		t.Errorf("Secure over plain HTTP: %q", c)
	}
	rec = httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodPost, "http://wtf.lan/api/v1/login", nil)
	r.Header.Set("X-Forwarded-Proto", "https")
	setSessionCookie(rec, r, "tok", sessionMaxAge)
	if !strings.Contains(rec.Header().Get("Set-Cookie"), "Secure") {
		t.Errorf("not Secure behind an HTTPS proxy: %q", rec.Header().Get("Set-Cookie"))
	}
	rec = httptest.NewRecorder()
	setSessionCookie(rec, r, "", 0)
	if !strings.Contains(rec.Header().Get("Set-Cookie"), "Max-Age=0") {
		t.Errorf("deleting: %q", rec.Header().Get("Set-Cookie"))
	}
}

// The web app: files, index.html for the app's own URLs, no hidden files, the
// security headers, and nothing of it under /api.
func TestWebApp(t *testing.T) {
	dir := t.TempDir()
	for name, content := range map[string]string{
		"index.html":   "<html>app</html>",
		"main.dart.js": "code",
		"version.json": `{"version": "1.0.0"}`,
		".secret":      "hidden",
	} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	s := testServer()
	s.webRoot = dir
	h := s.handler()
	get := func(method, path string) *httptest.ResponseRecorder {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(method, path, nil))
		return rec
	}
	for path, want := range map[string]string{
		"/":                 "<html>app</html>",
		"/main.dart.js":     "code",
		"/version.json":     `{"version": "1.0.0"}`,
		"/locations/1A7K":   "<html>app</html>",
		"/items/123/photos": "<html>app</html>",
	} {
		rec := get(http.MethodGet, path)
		if rec.Code != 200 || rec.Body.String() != want {
			t.Errorf("%s: %d %q", path, rec.Code, rec.Body.String())
		}
		if rec.Header().Get("Cache-Control") != "no-cache" || !strings.Contains(rec.Header().Get("Content-Security-Policy"), "frame-ancestors 'none'") {
			t.Errorf("%s: headers %v", path, rec.Header())
		}
	}
	for _, path := range []string{"/.secret", "/missing.js", "/api/v1/nothing"} {
		if rec := get(http.MethodGet, path); rec.Code != 404 {
			t.Errorf("%s: %d, want 404", path, rec.Code)
		}
	}
	if rec := get(http.MethodPost, "/"); rec.Code != 405 {
		t.Errorf("POST /: %d, want 405", rec.Code)
	}
	// Without a web root, everything outside /api is a 404.
	if rec := testServer().handler(); rec != nil {
		r := httptest.NewRecorder()
		rec.ServeHTTP(r, httptest.NewRequest(http.MethodGet, "/", nil))
		if r.Code != 404 {
			t.Errorf("no web root: %d, want 404", r.Code)
		}
	}
}

// The first label of the hostname, without the port, picks the tenant; an
// IP address never does (TENANTS.md).
func TestHostLabel(t *testing.T) {
	for host, want := range map[string]string{
		"bob.wtf.example":         "bob",
		"Bob.WTF.example:8443":    "bob",
		"bob.192.168.1.10.nip.io": "bob",
		"localhost:8080":          "localhost",
		"192.168.1.10:8080":       "192",
		"[::1]:8080":              "::1",
	} {
		r := httptest.NewRequest(http.MethodGet, "/", nil)
		r.Host = host
		if got := hostLabel(r); got != want {
			t.Errorf("%s: %q, want %q", host, got, want)
		}
	}
	for _, label := range []string{"192", "::1", "", "-bob", "bob-", "b_b"} {
		if hostPattern.MatchString(label) {
			t.Errorf("%q can be a tenant's host", label)
		}
	}
}
