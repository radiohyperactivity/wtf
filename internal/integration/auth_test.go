package integration

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/radiohyperactivity/wtf/internal/admin"
	"github.com/radiohyperactivity/wtf/internal/serve"
)

// login logs in via the API, failing the test unless the status matches.
func (e *environment) loginAs(t *testing.T, status int, email, password string) response {
	t.Helper()
	return e.expect(t, status, "POST", "/login", obj("email", email, "password", password), "Cookie", "")
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

	me := e.expect(t, 200, "GET", "/me", nil).body
	if str(t, me, "email") != adminEmail || get(t, me, "tenant") != nil ||
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

	login := e.loginAs(t, 200, "reader@test.local", "first-password")
	if _, ok := login.body.(map[string]any)["token"]; ok {
		t.Error("the token must only be in the cookie, not in the body")
	}
	if c := login.header.Get("Set-Cookie"); !strings.Contains(c, "HttpOnly") || !strings.Contains(c, "SameSite=Strict") || !strings.Contains(c, "Path=/api") {
		t.Errorf("session cookie: %q", c)
	}
	readerToken := session(t, login)
	reader := as(readerToken)
	e.expect(t, 400, "PUT", "/me/password", obj("current", "wrong-password", "new", "second-password"), reader...)
	e.expect(t, 204, "PUT", "/me/password", obj("current", "first-password", "new", "second-password"), reader...)
	e.loginAs(t, 401, "reader@test.local", "first-password")
	e.loginAs(t, 200, "reader@test.local", "second-password")

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
	e.loginAs(t, 401, "reader@test.local", "second-password")
	e.expect(t, 204, "DELETE", "/accounts/"+acctID, nil)
}

func TestLockout(t *testing.T) {
	e := setup(t)
	e.expect(t, 201, "POST", "/accounts", obj("email", "lockme@test.local", "password", "right-password",
		"data_privilege", "read_only"))

	for i := 0; i < 5; i++ {
		e.loginAs(t, 401, "lockme@test.local", "wrong-password")
	}
	// Locked: even the right password is refused within the minute.
	r := e.loginAs(t, 429, "lockme@test.local", "right-password")
	if r.header.Get("Retry-After") != "60" {
		t.Errorf("Retry-After = %q", r.header.Get("Retry-After"))
	}

	// "wtfd account password" lifts the lockout with a new password.
	conn, err := admin.Connect(context.Background(), e.dbaConfig)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(context.Background())
	password, err := admin.SetPassword(context.Background(), conn, "LockMe@test.local")
	if err != nil {
		t.Fatal(err)
	}
	e.loginAs(t, 401, "lockme@test.local", "right-password")
	e.loginAs(t, 200, "lockme@test.local", password)
	if _, err := admin.SetPassword(context.Background(), conn, "nobody@test.local"); err == nil {
		t.Error("a new password for an unknown account")
	}
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
		`level=WARN msg="login failed" email=` + email + " remote=",
		"reason=invalid",
		`level=INFO msg=login email=` + email + " remote=",
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
