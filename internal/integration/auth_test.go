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
		str(t, me, "role") != "admin" {
		t.Errorf("me: %v", me)
	}

	// Accounts: create one with a password, log in, change the password.
	acct := e.expect(t, 201, "POST", "/accounts", obj(
		"email", "Reader@Test.local", "password", "first-password")).body
	acctID := str(t, acct, "id")
	// A new account is a viewer unless told otherwise.
	if get(t, acct, "role") != "viewer" || get(t, acct, "has_password") != true {
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

	e.expect(t, 400, "PATCH", "/accounts/"+acctID, obj("role", "owner"))
	e.expect(t, 400, "PATCH", "/accounts/"+acctID, obj("role", nil))

	// You can't lock yourself out.
	self := str(t, e.expect(t, 200, "GET", "/me", nil).body, "id")
	e.expect(t, 422, "PATCH", "/accounts/"+self, obj("role", "user"))
	e.expect(t, 200, "PATCH", "/accounts/"+self, obj("role", "admin"))
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
	e.expect(t, 201, "POST", "/accounts", obj("email", "lockme@test.local", "password", "right-password"))

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
	password, err := admin.SetPassword(context.Background(), conn, testHost, "LockMe@test.local")
	if err != nil {
		t.Fatal(err)
	}
	e.loginAs(t, 401, "lockme@test.local", "right-password")
	e.loginAs(t, 200, "lockme@test.local", password)
	if _, err := admin.SetPassword(context.Background(), conn, testHost, "nobody@test.local"); err == nil {
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
		req.Host = testHostname
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
		`level=WARN msg="login failed" host=test email=` + email + " remote=",
		"reason=invalid",
		`level=INFO msg=login host=test email=` + email + " remote=",
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

// TestRoles: a viewer looks, a user changes items and stock, an admin
// everything (ACCOUNTS.md).
func TestRoles(t *testing.T) {
	e := setup(t)
	e.reset(t)
	// Accounts outlive reset(), so the emails are new on every run.
	login := func(role string) []string {
		email := fmt.Sprintf("%s-%d@test.local", role, time.Now().UnixNano())
		e.expect(t, 201, "POST", "/accounts", obj("email", email, "password", "secret-password", "role", role))
		return as(session(t, e.loginAs(t, 200, email, "secret-password")))
	}
	viewer, user := login("viewer"), login("user")

	shelf := str(t, e.expect(t, 201, "POST", "/locations", obj("name", "Shelf")).body, "id")
	tools := str(t, e.expect(t, 201, "POST", "/classes", obj("name", "Tools")).body, "id")

	// Looking: everyone.
	for _, who := range [][]string{viewer, user} {
		e.expect(t, 200, "GET", "/items", nil, who...)
		e.expect(t, 200, "GET", "/classes", nil, who...)
		e.expect(t, 200, "GET", "/attributes", nil, who...)
		e.expect(t, 200, "GET", "/locations/"+shelf, nil, who...)
		e.expect(t, 200, "GET", "/quantities", nil, who...)
		e.expect(t, 403, "GET", "/accounts", nil, who...)
		e.expect(t, 403, "GET", "/classes/"+tools+"/model", nil, who...)
		e.expect(t, 403, "GET", "/locations/"+shelf+"/history", nil, who...)
		e.expect(t, 403, "GET", "/classes/history", nil, who...)
	}

	// Items and stock: users.
	e.expect(t, 403, "POST", "/items", obj("name", "Hammer", "class", tools), viewer...)
	item := str(t, e.expect(t, 201, "POST", "/items", obj("name", "Hammer", "class", tools), user...).body, "id")
	e.expect(t, 403, "POST", "/stock", obj("item", item, "location", shelf, "quantity", 1), viewer...)
	stock := str(t, e.expect(t, 201, "POST", "/stock", obj("item", item, "location", shelf, "quantity", 1), user...).body, "id")
	e.expect(t, 200, "PATCH", "/stock/"+stock, obj("quantity", 2), user...)
	e.expect(t, 403, "PATCH", "/stock/"+stock, obj("quantity", 3), viewer...)
	for _, who := range [][]string{viewer, user} {
		e.expect(t, 200, "GET", "/items/"+item+"/history", nil, who...)
		e.expect(t, 200, "GET", "/stock/"+stock+"/history", nil, who...)
	}

	// Setting up: admins.
	e.expect(t, 403, "POST", "/locations", obj("name", "Shed"), user...)
	e.expect(t, 403, "PATCH", "/locations/"+shelf, obj("name", "Top shelf"), user...)
	e.expect(t, 403, "POST", "/classes", obj("name", "Parts"), user...)
	e.expect(t, 403, "POST", "/attributes", obj("name", "Length", "datatype", "text"), user...)
	e.expect(t, 403, "POST", "/model/import?dry_run=true", obj("format", "wtf-model", "version", 1), user...)
	e.expect(t, 403, "POST", "/accounts", obj("email", "x@test.local"), user...)
	e.expect(t, 200, "GET", "/classes/"+tools+"/model", nil)
	e.expect(t, 200, "GET", "/locations/"+shelf+"/history", nil)
}
