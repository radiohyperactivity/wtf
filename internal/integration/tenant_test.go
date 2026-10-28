package integration

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"mime/multipart"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/radiohyperactivity/wtf/internal/admin"
)

// otherTenant creates a second tenant next to the test tenant, with a host
// of its own for this run, and returns its hostname and its admin's
// session.
func (e *environment) otherTenant(t *testing.T) (host, hostname, token string) {
	t.Helper()
	host = fmt.Sprintf("other%d", time.Now().UnixNano()%1_000_000_000)
	conn, err := admin.Connect(context.Background(), e.dbaConfig)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(context.Background())
	password, err := admin.CreateTenant(context.Background(), conn, host, adminEmail)
	if err != nil {
		t.Fatal(err)
	}
	hostname = host + ".example.org"
	token, err = e.loginTo(hostname, adminEmail, password)
	if err != nil {
		t.Fatal(err)
	}
	return host, hostname, token
}

// at returns the headers for a request at hostname, with session token.
func at(hostname, token string) []string {
	return []string{"Host", hostname, "Cookie", "wtf_session=" + token}
}

// TestTenants checks what TENANTS.md promises: the hostname picks the
// tenant, and one tenant can't see, find, change or delete the other's
// things.
func TestTenants(t *testing.T) {
	e := setup(t)
	e.reset(t)
	t.Cleanup(func() { e.dropTenantUnits(t) })
	host, hostname, token := e.otherTenant(t)
	b := at(hostname, token)

	// Hostnames: the first label picks the tenant, in any case and with a
	// port; one that picks none gets 404, except for health.
	e.expect(t, 200, "GET", "/me", nil, "Host", "TEST.other-domain.example:8443")
	for _, unknown := range []string{"nobody.wtf.example", "192.168.1.10:8080", "[::1]:8080", "localhost"} {
		if rec := e.raw("GET", "/items", "Host", unknown); rec.Code != 404 {
			t.Errorf("%s: %d, want 404", unknown, rec.Code)
		}
	}
	if rec := e.raw("GET", "/api/health", "Host", "192.168.1.10:8080"); rec.Code != 200 {
		t.Errorf("health by IP: %d", rec.Code)
	}
	// A session belongs to its tenant.
	e.expect(t, 401, "GET", "/me", nil, "Host", hostname)
	e.expect(t, 401, "GET", "/me", nil, "Cookie", "wtf_session="+token)
	if me := e.expect(t, 200, "GET", "/me", nil, b...).body; str(t, me, "email") != adminEmail {
		t.Errorf("the other tenant's admin: %v", me)
	}

	// The test tenant's things.
	class := str(t, e.expect(t, 201, "POST", "/classes", obj("name", "Tools")).body, "id")
	garage := e.expect(t, 201, "POST", "/locations", obj("name", "Garage")).body
	item := e.expect(t, 201, "POST", "/items", obj("class", class, "name", "Drill")).body
	itemID := str(t, item, "id")
	stock := str(t, e.expect(t, 201, "POST", "/stock",
		obj("item", itemID, "location", str(t, garage, "id"), "quantity", 1)).body, "id")
	attr := str(t, e.expect(t, 201, "POST", "/attributes", obj("name", "Colour", "datatype", "text")).body, "id")

	// The other tenant sees none of them, by id, code, list, search or tree…
	for _, path := range []string{"/items/" + itemID, "/stock/" + stock, "/classes/" + class,
		"/locations/" + str(t, garage, "id"), "/attributes/" + attr, "/codes/" + str(t, item, "code")} {
		e.expect(t, 404, "GET", path, nil, b...)
	}
	if n := num(t, e.expect(t, 200, "GET", "/items?search=drill", nil, b...).body, "total"); n != 0 {
		t.Errorf("the other tenant finds %v items", n)
	}
	if tree := get(t, e.expect(t, 200, "GET", "/classes", nil, b...).body, "tree").([]any); len(tree) != 0 {
		t.Errorf("the other tenant's class tree: %v", tree)
	}
	if n := num(t, e.expect(t, 200, "GET", "/items/"+itemID+"/history", nil, b...).body, "total"); n != 0 {
		t.Errorf("the other tenant sees %v history entries", n)
	}
	if list := e.expect(t, 200, "GET", "/accounts", nil, b...).body.([]any); len(list) != 1 {
		t.Errorf("the other tenant's accounts: %v", list)
	}
	// … and can't change, delete or use them.
	e.expect(t, 404, "PATCH", "/items/"+itemID, obj("name", "Mine"), b...)
	e.expect(t, 404, "DELETE", "/classes/"+class, nil, b...)
	e.expect(t, 404, "PUT", "/items/"+itemID+"/values/"+attr, obj("value", "red"), b...)
	e.expect(t, 404, "POST", "/stock/"+stock+"/move", obj("location", str(t, garage, "id")), b...)
	e.expect(t, 422, "POST", "/items", obj("class", class, "name", "Borrowed"), b...)

	// Its own things: names and codes of its own.
	bClass := str(t, e.expect(t, 201, "POST", "/classes", obj("name", "Tools"), b...).body, "id")
	e.expect(t, 201, "POST", "/attributes", obj("name", "Colour", "datatype", "text"), b...)
	bGarage := e.expect(t, 201, "POST", "/locations", obj("name", "Garage"), b...).body
	if code := str(t, bGarage, "code"); code != "1000" {
		t.Errorf("a new tenant's first code: %s, want 1000", code)
	}
	bItem := e.expect(t, 201, "POST", "/items", obj("class", bClass, "name", "Saw"), b...).body
	if str(t, e.expect(t, 200, "GET", "/codes/1000", nil, b...).body, "type") != "location" {
		t.Error("code 1000 is the other tenant's garage")
	}
	// Its stock row can't be at the test tenant's location.
	e.expect(t, 422, "POST", "/stock", obj("item", str(t, bItem, "id"), "location", str(t, garage, "id")), b...)

	// Files: in the tenant's own directory, and only reachable there.
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	part, _ := mw.CreateFormFile("file", "note.txt")
	part.Write([]byte("the other tenant's note"))
	mw.Close()
	att := e.expect(t, 201, "POST", "/items/"+str(t, bItem, "id")+"/attachments", buf.String(),
		append(b, "Content-Type", mw.FormDataContentType())...).body
	hash := str(t, att, "hash")
	other, err := e.files.Tenant(host)
	if err != nil {
		t.Fatal(err)
	}
	if f, err := other.OpenFile(hash); err != nil {
		t.Errorf("the file isn't in %s's directory: %v", host, err)
	} else {
		f.Close()
	}
	if _, err := os.Stat(filepath.Join(e.tenantStore(t).Dir(), hash[:2], hash)); err == nil {
		t.Error("the file is in the test tenant's directory too")
	}
	e.expect(t, 404, "GET", "/items/"+str(t, bItem, "id")+"/attachments/"+str(t, att, "id"), nil)

	// Units: a tenant's own are its own.
	r := e.expect(t, 200, "POST", "/units/import", obj("format", "wtf-units", "version", 1, "quantities", []any{
		obj("name", "Length", "base_unit", obj("symbol", "m", "name", "metre"), "families", []any{
			obj("name", "Imperial length", "units", []any{obj("symbol", "hh", "name", "hand", "factor", "0.1016")}),
		}),
	}), b...).body
	if get(t, r, "applied") != true {
		t.Fatalf("import: %v", r)
	}
	var hand string
	for _, f := range e.expect(t, 200, "GET", "/unit-families", nil, b...).body.([]any) {
		for _, u := range get(t, f, "units").([]any) {
			if str(t, u, "symbol") == "hh" {
				hand = str(t, u, "id")
			}
		}
	}
	e.expect(t, 200, "GET", "/units/"+hand, nil, b...)
	e.expect(t, 404, "GET", "/units/"+hand, nil)
	e.expect(t, 422, "POST", "/attributes", obj("name", "Span", "datatype", "float", "unit", hand))

	// Turning units off: one tenant's choice, refused while something uses them.
	var imperial, length string
	for _, f := range e.expect(t, 200, "GET", "/unit-families", nil).body.([]any) {
		if str(t, f, "name") == "Imperial length" {
			imperial, length = str(t, f, "id"), str(t, f, "quantity", "id")
		}
	}
	inch := e.unit(t, "Imperial length", "in")
	width := str(t, e.expect(t, 201, "POST", "/attributes", obj("name", "Width", "datatype", "float", "unit", inch), b...).body, "id")
	if r := e.expect(t, 409, "PATCH", "/unit-families/"+imperial, obj("available", false), b...).body; !bytes.Contains(must(json.Marshal(r)), []byte("Width")) {
		t.Errorf("the refusal names what uses it: %v", r)
	}
	e.expect(t, 204, "DELETE", "/attributes/"+width, nil, b...)
	f := e.expect(t, 200, "PATCH", "/unit-families/"+imperial, obj("available", false), b...).body
	if get(t, f, "available") != false || get(t, f, "choice") != false || get(t, f, "standard") != true {
		t.Errorf("turned off: %v", f)
	}
	e.expect(t, 409, "POST", "/attributes", obj("name", "Width", "datatype", "float", "unit", inch), b...)
	if get(t, e.expect(t, 200, "GET", "/unit-families/"+imperial, nil).body, "available") != true {
		t.Error("the test tenant's Imperial length was turned off too")
	}
	// Turned on again, it follows the standard: no choice is kept.
	if f := e.expect(t, 200, "PATCH", "/unit-families/"+imperial, obj("available", true), b...).body; get(t, f, "choice") != nil {
		t.Errorf("a choice that is the standard is kept: %v", f)
	}
	// A quantity turned off turns its families off.
	e.expect(t, 200, "PATCH", "/quantities/"+length, obj("available", false), b...)
	for _, f := range e.expect(t, 200, "GET", "/unit-families?quantity="+length, nil, b...).body.([]any) {
		if get(t, f, "available") != false {
			t.Errorf("%s is still available", str(t, f, "name"))
		}
	}
	e.expect(t, 200, "PATCH", "/quantities/"+length, obj("available", nil), b...)
	e.expect(t, 401, "PATCH", "/quantities/"+length, obj("available", false), "Cookie", "")

	// Global units: every tenant sees them; a name a tenant has is a conflict.
	conn, err := admin.Connect(context.Background(), e.dbaConfig)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(context.Background())
	file := func(family string) []byte {
		return must(json.Marshal(obj("format", "wtf-units", "version", 1, "quantities", []any{
			obj("name", "Length", "base_unit", obj("symbol", "m", "name", "metre"), "families", []any{
				obj("name", family, "units", []any{obj("symbol", "ftm", "name", "fathom", "factor", "1.8288")}),
			}),
		})))
	}
	report, err := admin.ImportGlobalUnits(context.Background(), conn, file("Nautical length"), false)
	if err != nil || !bytes.Contains(report, []byte(`"applied": true`)) {
		t.Fatalf("global import: %s %v", report, err)
	}
	if e.unit(t, "Nautical length", "ftm") == "" {
		t.Error("the test tenant doesn't see the global unit")
	}
	for _, f := range e.expect(t, 200, "GET", "/unit-families", nil, b...).body.([]any) {
		if str(t, f, "name") == "Nautical length" && get(t, f, "global") != true {
			t.Errorf("Nautical length: %v", f)
		}
	}
	e.expect(t, 200, "POST", "/units/import", obj("format", "wtf-units", "version", 1, "quantities", []any{
		obj("name", "Length", "base_unit", obj("symbol", "m", "name", "metre"), "families", []any{obj("name", "Rope length")}),
	}), b...)
	report, err = admin.ImportGlobalUnits(context.Background(), conn, file("Rope length"), false)
	if err != nil || !bytes.Contains(report, []byte(host)) {
		t.Errorf("a global family named like a tenant's: %s %v", report, err)
	}
	if err := admin.SetUnitStandard(context.Background(), conn, "family", "Nautical length", false); err != nil {
		t.Fatal(err)
	}
	for _, f := range e.expect(t, 200, "GET", "/unit-families", nil).body.([]any) {
		if str(t, f, "name") == "Nautical length" && get(t, f, "available") != false {
			t.Errorf("not available by default any more: %v", f)
		}
	}

	// Renaming: the new host reaches the tenant, the old one nothing, and
	// the files moved along.
	newHost := host + "x"
	if err := admin.RenameTenant(context.Background(), conn, e.files, host, newHost); err != nil {
		t.Fatal(err)
	}
	e.expect(t, 404, "GET", "/me", nil, b...)
	e.expect(t, 200, "GET", "/me", nil, at(newHost+".example.org", token)...)
	moved, _ := e.files.Tenant(newHost)
	if f, err := moved.OpenFile(hash); err != nil {
		t.Errorf("the file didn't move with the tenant: %v", err)
	} else {
		f.Close()
	}
	if err := admin.RenameTenant(context.Background(), conn, e.files, newHost, testHost); err == nil {
		t.Error("renamed to a host that is taken")
	}
	if err := admin.RenameTenant(context.Background(), conn, e.files, newHost, "9lives"); err == nil {
		t.Error("renamed to a host that isn't a DNS label starting with a letter")
	}
}

func must(data []byte, err error) []byte {
	if err != nil {
		panic(err)
	}
	return data
}
