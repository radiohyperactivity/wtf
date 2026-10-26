package integration

import (
	"fmt"
	"strings"
	"testing"
	"time"
)

// TestDeleteTree covers DELETE /classes/{id}?recursive=true and the same for
// locations: all or nothing, blocked by items or stock unless forced.
func TestDeleteTree(t *testing.T) {
	e := setup(t)
	e.reset(t)

	class := func(name string, parent any) string {
		return str(t, e.expect(t, 201, "POST", "/classes", obj("name", name, "parent", parent)).body, "id")
	}
	location := func(name string, parent any) string {
		return str(t, e.expect(t, 201, "POST", "/locations", obj("name", name, "parent", parent)).body, "id")
	}
	a := class("A", nil)
	b := class("B", a)
	c := class("C", b)
	shelf := location("Shelf", nil)
	box := location("Box", shelf)
	item := str(t, e.expect(t, 201, "POST", "/items", obj("class", c, "name", "Widget")).body, "id")
	stock := str(t, e.expect(t, 201, "POST", "/stock", obj("item", item, "location", box, "quantity", 3)).body, "id")

	// Without recursive, a class with subclasses is still refused.
	e.expect(t, 409, "DELETE", "/classes/"+a, nil)
	e.expect(t, 400, "DELETE", "/classes/"+a+"?recursive=maybe", nil)
	e.expect(t, 400, "DELETE", "/classes/"+a+"?recursive=true&force=yes", nil)

	// Items block a recursive delete, and the message names where they are.
	r := e.expect(t, 409, "DELETE", "/classes/"+a+"?recursive=true", nil)
	if d := str(t, r.body, "detail"); !strings.Contains(d, "A/B/C (1 item)") {
		t.Errorf("detail: %s", d)
	}
	e.expect(t, 200, "GET", "/classes/"+c, nil) // nothing deleted

	// The preview reports and deletes nothing; without force it reports the
	// items instead of failing.
	r = e.expect(t, 200, "GET", "/classes/"+a+"/deletion", nil)
	if str(t, r.body, "items", 0, "name") != "Widget" {
		t.Errorf("preview without force: %v", r.body)
	}
	e.expect(t, 400, "GET", "/classes/"+a+"/deletion?force=yes", nil)
	r = e.expect(t, 200, "GET", "/classes/"+a+"/deletion?force=true", nil)
	if n := len(get(t, r.body, "classes").([]any)); n != 3 {
		t.Errorf("dry run: %d classes", n)
	}
	if str(t, r.body, "classes", 0, "path") != "A/B/C" || str(t, r.body, "classes", 2, "path") != "A" {
		t.Errorf("classes not deepest first: %v", get(t, r.body, "classes"))
	}
	if str(t, r.body, "items", 0, "name") != "Widget" || num(t, r.body, "stock") != 1 {
		t.Errorf("dry run: %v", r.body)
	}
	e.expect(t, 200, "GET", "/items/"+item, nil)

	// Forcing a class delete needs data write as well as model write.
	email := fmt.Sprintf("modeller-%d@test.local", time.Now().UnixNano())
	e.expect(t, 201, "POST", "/accounts", obj("email", email, "password", "secret-password",
		"model_privilege", "read_write", "data_privilege", "read_only"))
	token := session(t, e.loginAs(t, 200, e.host, email, "secret-password"))
	e.expect(t, 403, "DELETE", "/classes/"+a+"?recursive=true&force=true", nil, as(e.host, token)...)
	e.expect(t, 200, "GET", "/classes/"+a, nil)

	// Stock blocks a location delete; forced, the stock goes, the item stays.
	r = e.expect(t, 409, "DELETE", "/locations/"+shelf+"?recursive=true", nil)
	if d := str(t, r.body, "detail"); !strings.Contains(d, "Shelf/Box (1 stock row)") {
		t.Errorf("detail: %s", d)
	}
	r = e.expect(t, 200, "DELETE", "/locations/"+shelf+"?recursive=true&force=true", nil)
	if n := len(get(t, r.body, "locations").([]any)); n != 2 || str(t, r.body, "stock", 0, "item", "name") != "Widget" {
		t.Errorf("location delete: %v", r.body)
	}
	e.expect(t, 404, "GET", "/locations/"+box, nil)
	e.expect(t, 404, "GET", "/stock/"+stock, nil)
	e.expect(t, 200, "GET", "/items/"+item, nil)

	// Forced, the classes go with their items.
	e.expect(t, 200, "DELETE", "/classes/"+a+"?recursive=true&force=true", nil)
	for _, path := range []string{"/classes/" + a, "/classes/" + b, "/classes/" + c, "/items/" + item} {
		e.expect(t, 404, "GET", path, nil)
	}

	// An unused tree needs no force, and the deletes are in the history.
	x := class("X", nil)
	class("Y", x)
	e.expect(t, 200, "DELETE", "/classes/"+x+"?recursive=true", nil)
	h := e.expect(t, 200, "GET", "/classes/"+x+"/history", nil)
	if str(t, h.body, "rows", 0, "operation") != "delete" {
		t.Errorf("history: %v", get(t, h.body, "rows", 0))
	}
}
