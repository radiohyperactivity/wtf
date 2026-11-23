package integration

import (
	"fmt"
	"net/http/httptest"
	"testing"
	"time"
)

// An account's preferences: the defaults until changed, one at a time, a
// null putting one back; unknown ones and wrong types refused; every
// session of the account told of a change, and no other account's.
func TestPreferences(t *testing.T) {
	e := setup(t)
	server := httptest.NewServer(e.handler)
	t.Cleanup(server.Close)

	login := func(email, client string) string {
		return session(t, e.expect(t, 200, "POST", "/login",
			obj("email", email, "password", "secret-password", "client", client, "max_idle", nil), "Cookie", ""))
	}
	email := fmt.Sprintf("preferences-%d@test.local", time.Now().UnixNano())
	other := fmt.Sprintf("preferences-other-%d@test.local", time.Now().UnixNano())
	// A viewer has preferences too.
	e.expect(t, 201, "POST", "/accounts", obj("email", email, "password", "secret-password", "role", "viewer"))
	e.expect(t, 201, "POST", "/accounts", obj("email", other, "password", "secret-password", "role", "viewer"))
	pc, phone, elsewhere := login(email, "WtF on Windows"), login(email, "WtF on iPhone"), login(other, "WtF on Mac")

	check := func(body any, addStock string, last bool) {
		t.Helper()
		if get(t, body, "add_stock") != addStock || get(t, body, "add_stock_last") != last {
			t.Fatalf("preferences: %v, want add_stock %s and add_stock_last %v", body, addStock, last)
		}
	}
	check(e.expect(t, 200, "GET", "/me/preferences", nil, as(pc)...).body, "last", true)

	pcEvents := events(t, server.URL, pc)
	phoneEvents := events(t, server.URL, phone)
	otherEvents := events(t, server.URL, elsewhere)

	// One preference changes; the other stays as it was, and both
	// devices are told, the one that changed it too.
	check(e.expect(t, 200, "PATCH", "/me/preferences", obj("add_stock", "off"), as(phone)...).body, "off", true)
	expectEvent(t, pcEvents, "preferences {}")
	expectEvent(t, phoneEvents, "preferences {}")
	expectNoEvent(t, otherEvents)
	check(e.expect(t, 200, "PATCH", "/me/preferences", obj("add_stock_last", false), as(pc)...).body, "off", false)
	check(e.expect(t, 200, "GET", "/me/preferences", nil, as(phone)...).body, "off", false)
	check(e.expect(t, 200, "GET", "/me/preferences", nil, as(elsewhere)...).body, "last", true)
	expectEvent(t, pcEvents, "preferences {}")
	expectEvent(t, phoneEvents, "preferences {}")

	// Null puts one back to its default.
	check(e.expect(t, 200, "PATCH", "/me/preferences", obj("add_stock", nil), as(pc)...).body, "last", false)
	expectEvent(t, pcEvents, "preferences {}")
	expectEvent(t, phoneEvents, "preferences {}")

	// Refused: unknown preferences, wrong types and values, and no session.
	e.expect(t, 400, "PATCH", "/me/preferences", obj("colour", "blue"), as(pc)...)
	e.expect(t, 400, "PATCH", "/me/preferences", obj("add_stock", true), as(pc)...)
	e.expect(t, 400, "PATCH", "/me/preferences", obj("add_stock", "sometimes"), as(pc)...)
	e.expect(t, 400, "PATCH", "/me/preferences", obj("add_stock_last", "yes"), as(pc)...)
	e.expect(t, 401, "GET", "/me/preferences", nil, "Cookie", "wtf_session=not-a-token")
	check(e.expect(t, 200, "GET", "/me/preferences", nil, as(pc)...).body, "last", false)
	expectNoEvent(t, pcEvents)
}

// A preference an account stores but that is no longer one is not shown;
// one never stored has its default.
func TestPreferencesOf(t *testing.T) {
	d := setup(t).dba
	var got string
	err := d.QueryRow(t.Context(),
		`SELECT account.preferences_of('{"add_stock": "on", "retired": 1}')::text`).Scan(&got)
	if err != nil {
		t.Fatal(err)
	}
	if got != `{"add_stock": "on", "add_stock_last": true}` {
		t.Fatalf("preferences_of: %s", got)
	}
}
