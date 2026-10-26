package integration

import (
	"bytes"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/radiohyperactivity/wtf/internal/serve"
)

// login logs in via the API, failing the test unless the status matches.
func (e *environment) loginAs(t *testing.T, status int, host, email, password string) response {
	t.Helper()
	return e.expect(t, status, "POST", "/login", obj("email", email, "password", password),
		"Host", host, "Cookie", "")
}

// session returns the session token a login response sets as its cookie.
func session(t *testing.T, r response) string {
	t.Helper()
	token := sessionCookie(&http.Response{Header: r.header})
	if token == "" {
		t.Fatalf("no session cookie in %v", r.header)
	}
	return token
}

func TestAuthentication(t *testing.T) {
	e := setup(t)

	// Anonymous requests: only health, openapi and login.
	e.expect(t, 200, "GET", "/api/health", nil, "Cookie", "")
	spec := httptest.NewRecorder()
	e.handler.ServeHTTP(spec, e.newRequest("GET", "/openapi.yaml", nil, "Cookie", ""))
	if spec.Code != 200 || !strings.HasPrefix(spec.Body.String(), "openapi:") {
		t.Errorf("GET /api/v1/openapi.yaml: %d", spec.Code)
	}
	r := e.expect(t, 401, "GET", "/items", nil, "Cookie", "")
	if !strings.HasPrefix(r.header.Get("WWW-Authenticate"), "Cookie") {
		t.Errorf("WWW-Authenticate = %q", r.header.Get("WWW-Authenticate"))
	}
	r = e.expect(t, 401, "GET", "/items", nil, "Cookie", "wtf_session=not-a-token")
	if c := r.header.Get("Set-Cookie"); !strings.Contains(c, "Max-Age=0") {
		t.Errorf("an ended session's cookie should be dropped: %q", c)
	}
	// The old Bearer header no longer logs in.
	e.expect(t, 401, "GET", "/items", nil, "Cookie", "", "Authorization", "Bearer "+e.token)

	// A token only works on its own tenant's hostname.
	e.expect(t, 401, "GET", "/items", nil, "Host", e.otherHost)

	me := e.expect(t, 200, "GET", "/me", nil).body
	if str(t, me, "email") != "admin@test.local" || str(t, me, "tenant", "hostname") != testHost ||
		str(t, me, "data_privilege") != "read_write" {
		t.Errorf("me: %v", me)
	}

	// Accounts: create one with a password, log in, change the password.
	acct := e.expect(t, 201, "POST", "/accounts", obj(
		"email", "Reader@Test.local", "password", "first-password", "data_privilege", "read_only")).body
	acctID := str(t, acct, "id")
	if get(t, acct, "model_privilege") != "none" || get(t, acct, "has_password") != true {
		t.Errorf("new account: %v", acct)
	}
	e.expect(t, 409, "POST", "/accounts", obj("email", "reader@test.local")) // emails are case-insensitive
	e.expect(t, 400, "POST", "/accounts", obj("email", "not-an-email"))      // must look like an email
	e.expect(t, 400, "POST", "/accounts", obj("email", "x@y.z", "password", "short"))

	login := e.loginAs(t, 200, testHost, "reader@test.local", "first-password")
	if _, ok := login.body.(map[string]any)["token"]; ok {
		t.Error("the token must only be in the cookie, not in the body")
	}
	if c := login.header.Get("Set-Cookie"); !strings.Contains(c, "HttpOnly") || !strings.Contains(c, "SameSite=Strict") || !strings.Contains(c, "Path=/api") {
		t.Errorf("session cookie: %q", c)
	}
	readerToken := session(t, login)
	reader := as(testHost, readerToken)
	e.expect(t, 400, "PUT", "/me/password", obj("current", "wrong-password", "new", "second-password"), reader...)
	e.expect(t, 204, "PUT", "/me/password", obj("current", "first-password", "new", "second-password"), reader...)
	e.loginAs(t, 401, testHost, "reader@test.local", "first-password")
	e.loginAs(t, 200, testHost, "reader@test.local", "second-password")

	// The same email in another tenant is another account.
	e.loginAs(t, 401, otherHost, "reader@test.local", "second-password")

	// Privileges: read-only data, no model, no accounts.
	e.reset(t)
	e.expect(t, 200, "GET", "/items", nil, reader...)
	e.expect(t, 200, "GET", "/classes", nil, reader...) // reading the model is allowed with data read
	e.expect(t, 403, "POST", "/locations", obj("name", "Shed"), reader...)
	e.expect(t, 403, "POST", "/classes", obj("name", "Tools"), reader...)
	e.expect(t, 403, "GET", "/accounts", nil, reader...)
	e.expect(t, 200, "PATCH", "/accounts/"+acctID, obj("data_privilege", "none"))
	e.expect(t, 403, "GET", "/items", nil, reader...)
	e.expect(t, 200, "GET", "/quantities", nil, reader...) // system data: any login

	// You can't lock yourself out.
	self := str(t, e.expect(t, 200, "GET", "/me", nil).body, "id")
	e.expect(t, 422, "PATCH", "/accounts/"+self, obj("account_privilege", "read_only"))
	e.expect(t, 422, "DELETE", "/accounts/"+self, nil)

	// Using the session renews its cookie; logout ends the session and
	// deletes the cookie.
	if c := e.expect(t, 200, "GET", "/me", nil, reader...).header.Get("Set-Cookie"); !strings.Contains(c, "Max-Age=2592000") {
		t.Errorf("renewed cookie: %q", c)
	}
	if c := e.expect(t, 204, "POST", "/logout", nil, reader...).header.Get("Set-Cookie"); !strings.Contains(c, "Max-Age=0") {
		t.Errorf("logout cookie: %q", c)
	}
	e.expect(t, 401, "GET", "/me", nil, reader...)

	// An account without a password can't log in.
	e.expect(t, 200, "PATCH", "/accounts/"+acctID, obj("password", nil))
	e.loginAs(t, 401, testHost, "reader@test.local", "second-password")
	e.expect(t, 204, "DELETE", "/accounts/"+acctID, nil)
}

func TestLockout(t *testing.T) {
	e := setup(t)
	e.expect(t, 201, "POST", "/accounts", obj("email", "lockme@test.local", "password", "right-password",
		"data_privilege", "read_only"))

	for i := 0; i < 5; i++ {
		e.loginAs(t, 401, testHost, "lockme@test.local", "wrong-password")
	}
	// Locked: even the right password is refused within the minute.
	r := e.loginAs(t, 429, testHost, "lockme@test.local", "right-password")
	if r.header.Get("Retry-After") != "60" {
		t.Errorf("Retry-After = %q", r.header.Get("Retry-After"))
	}
}

func TestTenantIsolation(t *testing.T) {
	e := setup(t)
	e.reset(t)
	other := as(otherHost, e.otherToken)

	// The same names in both tenants are fine.
	mine := str(t, e.expect(t, 201, "POST", "/classes", obj("name", "Tools")).body, "id")
	theirs := str(t, e.expect(t, 201, "POST", "/classes", obj("name", "Tools"), other...).body, "id")
	theirLoc := str(t, e.expect(t, 201, "POST", "/locations", obj("name", "Garage"), other...).body, "id")
	theirItem := e.expect(t, 201, "POST", "/items", obj("class", theirs, "name", "Their drill"), other...).body

	// The other tenant's objects don't exist for me.
	e.expect(t, 404, "GET", "/classes/"+theirs, nil)
	e.expect(t, 404, "GET", "/items/"+str(t, theirItem, "id"), nil)
	e.expect(t, 404, "GET", "/codes/"+str(t, theirItem, "code"), nil)
	e.expect(t, 404, "DELETE", "/locations/"+theirLoc, nil)
	e.expect(t, 404, "PATCH", "/classes/"+theirs, obj("name", "Mine now"))

	// Lists and trees only show my own.
	tree := e.expect(t, 200, "GET", "/classes", nil).body
	if n := len(get(t, tree, "tree").([]any)); n != 1 || str(t, tree, "tree", 0, "id") != mine {
		t.Errorf("class tree: %v", get(t, tree, "tree"))
	}
	if n := num(t, e.expect(t, 200, "GET", "/items", nil).body, "total"); n != 0 {
		t.Errorf("item_list shows %v items of the other tenant", n)
	}

	// References across tenants are refused.
	e.expect(t, 422, "POST", "/items", obj("class", theirs, "name", "Sneaky"))
	e.expect(t, 422, "POST", "/locations", obj("name", "Sneaky", "parent", theirLoc))

	// Tree versions are per tenant: my change doesn't touch their ETag.
	theirTag := e.expect(t, 200, "GET", "/classes", nil, other...).header.Get("ETag")
	e.expect(t, 201, "POST", "/classes", obj("name", "Parts"))
	e.expect(t, 304, "GET", "/classes", nil, append(other, "If-None-Match", theirTag)...)
}

// TestLoginLog checks that wtfd logs login attempts, without passwords.
func TestLoginLog(t *testing.T) {
	e := setup(t)
	email := fmt.Sprintf("logged-%d@test.local", time.Now().UnixNano())
	e.expect(t, 201, "POST", "/accounts", obj("email", email, "password", "secret-password"))

	var buf bytes.Buffer
	handler := serve.NewHandler(e.api, slog.New(slog.NewTextHandler(&buf, nil)), 1<<20, e.files, testMaxAttachment, "")
	login := func(password string) int {
		data, _ := json.Marshal(map[string]string{"email": email, "password": password})
		req := httptest.NewRequest("POST", "/api/v1/login", bytes.NewReader(data))
		req.Host = e.host
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		return rec.Code
	}
	if code := login("wrong-password"); code != 401 {
		t.Fatalf("wrong password: %d", code)
	}
	if code := login("secret-password"); code != 200 {
		t.Fatalf("right password: %d", code)
	}
	log := buf.String()
	for _, want := range []string{
		`level=WARN msg="login failed" email=` + email + " host=" + e.host,
		"reason=invalid",
		`level=INFO msg=login email=` + email + " host=" + e.host,
		"account=",
		"remote=",
	} {
		if !strings.Contains(log, want) {
			t.Errorf("log lacks %q:\n%s", want, log)
		}
	}
	if strings.Contains(log, "password") {
		t.Errorf("log mentions a password:\n%s", log)
	}
}
