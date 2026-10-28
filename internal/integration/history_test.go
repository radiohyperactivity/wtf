package integration

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/radiohyperactivity/wtf/internal/admin"
)

// historyOf returns the entries of a history endpoint as (table, operation)
// pairs, newest first.
func historyOf(t *testing.T, e *environment, path string, headers ...string) ([]string, []any) {
	t.Helper()
	page := e.expect(t, 200, "GET", path, nil, headers...).body
	rows := get(t, page, "rows").([]any)
	var kinds []string
	for _, r := range rows {
		kinds = append(kinds, str(t, r, "table")+"."+str(t, r, "operation"))
	}
	return kinds, rows
}

func TestHistory(t *testing.T) {
	e := setup(t)
	e.reset(t)

	classID := str(t, e.expect(t, 201, "POST", "/classes", obj("name", "Tools")).body, "id")
	attr := str(t, e.expect(t, 201, "POST", "/attributes", obj("name", "Brand", "datatype", "text")).body, "id")
	e.expect(t, 200, "PUT", "/classes/"+classID+"/attributes/"+attr, nil)
	itemID := str(t, e.expect(t, 201, "POST", "/items",
		obj("class", classID, "name", "Drill", "values", obj(attr, "Makita"))).body, "id")
	shed := str(t, e.expect(t, 201, "POST", "/locations", obj("name", "Shed")).body, "id")
	van := str(t, e.expect(t, 201, "POST", "/locations", obj("name", "Van")).body, "id")
	stockID := str(t, e.expect(t, 201, "POST", "/stock", obj("item", itemID, "location", shed, "quantity", 5)).body, "id")

	e.expect(t, 200, "PUT", "/items/"+itemID+"/values/"+attr, obj("value", "Bosch"))
	e.expect(t, 200, "POST", "/stock/"+stockID+"/move", obj("location", van, "quantity", 2))
	e.expect(t, 200, "PATCH", "/items/"+itemID, obj("name", "Cordless drill"))

	// The item's history includes its values and stock rows, newest first.
	kinds, rows := historyOf(t, e, "/items/"+itemID+"/history")
	want := []string{"item.update", "stock.insert", "stock.update", "value.update", "stock.insert", "value.insert", "item.insert"}
	if strings.Join(kinds, ",") != strings.Join(want, ",") {
		t.Fatalf("item history: %v\nwant %v", kinds, want)
	}
	if str(t, rows[0], "account", "email") != "admin@test.local" {
		t.Errorf("who: %v", get(t, rows[0], "account"))
	}
	if get(t, rows[0], "changes", "name", "old") != "Drill" || get(t, rows[0], "changes", "name", "new") != "Cordless drill" {
		t.Errorf("changes: %v", get(t, rows[0], "changes"))
	}
	// Both rows changed by the move share one transaction.
	if str(t, rows[1], "transaction") != str(t, rows[2], "transaction") {
		t.Error("the split's two stock entries have different transactions")
	}

	// Moving the rest away shows up at the shed, as stock leaving.
	e.expect(t, 200, "POST", "/stock/"+stockID+"/move", obj("location", van))
	kinds, rows = historyOf(t, e, "/locations/"+shed+"/history")
	if kinds[0] != "stock.update" && kinds[0] != "stock.delete" {
		t.Errorf("shed history: %v", kinds)
	}
	_ = rows

	// Paging.
	page := e.expect(t, 200, "GET", "/items/"+itemID+"/history?limit=2&offset=1", nil).body
	if num(t, page, "limit") != 2 || len(get(t, page, "rows").([]any)) != 2 || num(t, page, "total") < 8 {
		t.Errorf("paging: %v", page)
	}

	// Deleted accounts: their history stays, they can't log in, and the email can be reused.
	worker := str(t, e.expect(t, 201, "POST", "/accounts", obj("email", "worker@test.local",
		"password", "worker-password", "data_privilege", "read_write")).body, "id")
	workerToken := session(t, e.loginAs(t, 200, "worker@test.local", "worker-password"))
	attic := str(t, e.expect(t, 201, "POST", "/locations", obj("name", "Attic"), as(workerToken)...).body, "id")
	e.expect(t, 403, "GET", "/locations/"+attic+"/history", nil, as(workerToken)...) // no history privilege

	e.loginAs(t, 401, "worker@test.local", "wrong-password") // lockout counter: not logged
	before, _ := historyOf(t, e, "/accounts/"+worker+"/history")
	e.expect(t, 200, "PATCH", "/accounts/"+worker, obj("password", "another-password"))
	e.expect(t, 204, "DELETE", "/accounts/"+worker, nil)
	after, rows := historyOf(t, e, "/accounts/"+worker+"/history")
	if len(before) != 1 || len(after) != 3 {
		t.Errorf("account history before %v, after %v", before, after)
	}
	if get(t, rows[1], "changes", "password") != "changed" {
		t.Errorf("password change entry: %v", get(t, rows[1], "changes"))
	}
	raw, _ := json.Marshal(rows)
	if strings.Contains(string(raw), "$2a$") || strings.Contains(string(raw), "password_hash") {
		t.Error("a password hash leaked into history")
	}

	e.expect(t, 401, "GET", "/me", nil, as(workerToken)...)
	e.loginAs(t, 401, "worker@test.local", "another-password")
	if get(t, e.expect(t, 200, "GET", "/accounts/"+worker, nil).body, "deleted") != true {
		t.Error("account_get should show the deleted account")
	}
	for _, a := range e.expect(t, 200, "GET", "/accounts", nil).body.([]any) {
		if str(t, a, "id") == worker {
			t.Error("account_list shows a deleted account")
		}
	}
	e.expect(t, 201, "POST", "/accounts", obj("email", "worker@test.local"))
	_, rows = historyOf(t, e, "/locations/"+attic+"/history")
	if get(t, rows[0], "account", "email") != "worker@test.local" || get(t, rows[0], "account", "deleted") != true {
		t.Errorf("who created the attic: %v", get(t, rows[0], "account"))
	}

	// Purge.
	conn, err := admin.Connect(context.Background(), e.dbaConfig)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(context.Background())
	if n, err := admin.PurgeHistory(context.Background(), conn, "", 0, true); err != nil || n == 0 {
		t.Errorf("dry-run purge: %d, %v", n, err)
	}
	if n, err := admin.PurgeHistory(context.Background(), conn, "", 24*time.Hour, false); err != nil || n != 0 {
		t.Errorf("purge of entries older than a day: %d, %v", n, err)
	}
}

func TestParseAge(t *testing.T) {
	for in, want := range map[string]time.Duration{"730d": 730 * 24 * time.Hour, "36h": 36 * time.Hour, "0d": 0} {
		if got, err := admin.ParseAge(in); err != nil || got != want {
			t.Errorf("ParseAge(%q) = %v, %v", in, got, err)
		}
	}
	for _, in := range []string{"", "x", "-1d", "1y"} {
		if _, err := admin.ParseAge(in); err == nil {
			t.Errorf("ParseAge(%q) should fail", in)
		}
	}
}
