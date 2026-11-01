package integration

import (
	"fmt"
	"strings"
	"testing"
	"time"
)

// Deleting removes for good: what is in the way is named, what is gone
// answers 404, and a deleted thing's label answers 410.
func TestDeleting(t *testing.T) {
	e := setup(t)
	e.reset(t)

	tools := str(t, e.expect(t, 201, "POST", "/classes", obj("name", "Tools")).body, "id")
	shed := str(t, e.expect(t, 201, "POST", "/locations", obj("name", "Shed")).body, "id")
	drill := str(t, e.expect(t, 201, "POST", "/items", obj("class", tools, "name", "Drill")).body, "id")
	row := e.expect(t, 201, "POST", "/stock", obj("item", drill, "location", shed, "amount", 1)).body
	rowID, rowCode := str(t, row, "id"), str(t, row, "code")

	// What is in the way is named.
	for _, c := range []struct{ path, want string }{
		{"/items/" + drill, `Item "Drill" still has stock`},
		{"/locations/" + shed, `Location "Shed" still has stock`},
		{"/classes/" + tools, `Class "Tools" still has items`},
	} {
		r := e.expect(t, 409, "DELETE", c.path, nil)
		if str(t, r.body, "type") != "/problems/in-use" || !strings.Contains(str(t, r.body, "detail"), c.want) {
			t.Errorf("DELETE %s: %v", c.path, r.body)
		}
	}

	// Deleted, it is gone; its label answers 410, a code never handed out 404.
	e.expect(t, 204, "DELETE", "/stock/"+rowID, nil)
	e.expect(t, 404, "GET", "/stock/"+rowID, nil)
	e.expect(t, 404, "DELETE", "/stock/"+rowID, nil)
	if r := e.expect(t, 410, "GET", "/codes/"+rowCode, nil); str(t, r.body, "type") != "/problems/gone" ||
		!strings.Contains(str(t, r.body, "detail"), "has been deleted") {
		t.Errorf("code of a deleted row: %v", r.body)
	}
	e.expect(t, 404, "GET", "/codes/ZZZZ", nil)
	e.expect(t, 204, "DELETE", "/items/"+drill, nil)
	e.expect(t, 404, "GET", "/items/"+drill, nil)

	// An attribute in use is named, and goes with its options once it isn't.
	colour := str(t, e.expect(t, 201, "POST", "/attributes", obj("name", "Colour", "datatype", "choice")).body, "id")
	red := str(t, e.expect(t, 201, "POST", "/attributes/"+colour+"/options", obj("name", "Red")).body, "id")
	e.expect(t, 200, "PUT", "/classes/"+tools+"/attributes/"+colour, nil)
	r := e.expect(t, 409, "DELETE", "/attributes/"+colour, nil)
	if !strings.Contains(str(t, r.body, "detail"), `Attribute "Colour" is still in use: class "Tools" has it`) {
		t.Errorf("attribute in use: %v", r.body)
	}
	e.expect(t, 200, "DELETE", "/classes/"+tools+"/attributes/"+colour, nil)
	e.expect(t, 204, "DELETE", "/attributes/"+colour, nil)
	e.expect(t, 404, "GET", "/options/"+red, nil)

	// An account is deleted for good, and its email address can be used again.
	email := fmt.Sprintf("leaver-%d@test.local", time.Now().UnixNano())
	account := str(t, e.expect(t, 201, "POST", "/accounts", obj("email", email, "password", "secret-password")).body, "id")
	token := session(t, e.loginAs(t, 200, email, "secret-password"))
	e.expect(t, 204, "DELETE", "/accounts/"+account, nil)
	e.expect(t, 404, "GET", "/accounts/"+account, nil)
	e.expect(t, 401, "GET", "/me", nil, as(token)...)
	e.expect(t, 201, "POST", "/accounts", obj("email", email))
}

// Moving and merging stock are two actions.
func TestMerge(t *testing.T) {
	e := setup(t)
	e.reset(t)

	parts := str(t, e.expect(t, 201, "POST", "/classes", obj("name", "Parts")).body, "id")
	shelf := str(t, e.expect(t, 201, "POST", "/locations", obj("name", "Shelf")).body, "id")
	bin := str(t, e.expect(t, 201, "POST", "/locations", obj("name", "Bin")).body, "id")
	screw := str(t, e.expect(t, 201, "POST", "/items", obj("class", parts, "name", "Screw")).body, "id")
	nut := str(t, e.expect(t, 201, "POST", "/items", obj("class", parts, "name", "Nut")).body, "id")
	stock := func(item, location string, amount int) map[string]any {
		return e.expect(t, 201, "POST", "/stock", obj("item", item, "location", location, "amount", amount)).body.(map[string]any)
	}

	from, into := stock(screw, shelf, 10), stock(screw, bin, 5)
	// A move into the same location never merges.
	moved := e.expect(t, 200, "POST", "/stock/"+str(t, from, "id")+"/move", obj("location", bin)).body
	if str(t, moved, "id") != str(t, from, "id") {
		t.Errorf("the move merged: %v", moved)
	}

	merged := e.expect(t, 200, "POST", "/stock/"+str(t, from, "id")+"/merge", obj("into", str(t, into, "id"), "amount", 4)).body
	if str(t, merged, "id") != str(t, into, "id") || num(t, merged, "amount") != 9 {
		t.Errorf("merging 4: %v", merged)
	}
	merged = e.expect(t, 200, "POST", "/stock/"+str(t, from, "id")+"/merge", obj("into", str(t, into, "id"))).body
	if num(t, merged, "amount") != 15 {
		t.Errorf("merging the rest: %v", merged)
	}
	e.expect(t, 404, "GET", "/stock/"+str(t, from, "id"), nil)
	e.expect(t, 410, "GET", "/codes/"+str(t, from, "code"), nil)

	other := stock(nut, bin, 1)
	r := e.expect(t, 422, "POST", "/stock/"+str(t, into, "id")+"/merge", obj("into", str(t, other, "id")))
	if !strings.Contains(str(t, r.body, "detail"), "are of different items") {
		t.Errorf("different items: %v", r.body)
	}
	e.expect(t, 400, "POST", "/stock/"+str(t, into, "id")+"/merge", `{"amount": 1}`)
}

// The CLI merges, says what a deleted thing's label was, and asks before
// deleting on a terminal.
func TestCLIDeleting(t *testing.T) {
	e := setup(t)
	e.reset(t)
	c := e.cli(t)

	c.ok("class", "add", "Parts")
	c.ok("location", "add", "Shelf")
	c.ok("location", "add", "Bin")
	c.ok("item", "add", "Screw", "--class", "Parts")
	var from, into struct{ ID, Code string }
	c.json(&from, "stock", "add", "Screw", "Shelf", "10")
	c.json(&into, "stock", "add", "Screw", "Bin", "5")

	contains(t, c.ok("stock", "merge", from.Code, into.Code, "4"), "Amount:    9")
	contains(t, c.ok("stock", "merge", from.Code, into.Code), "Amount:    15")
	_, stderr := c.run(1, "", "code", from.Code)
	contains(t, stderr, "has been deleted")

	// On a terminal, a delete asks first; "no" deletes nothing.
	_, prompts := c.interactExit(1, []string{"n\r"}, false, "stock", "delete", into.Code)
	contains(t, prompts, "Delete stock "+into.Code+"? This can't be undone. [y/N]")
	c.ok("stock", "get", into.Code)
	c.interact([]string{"y\r"}, false, "stock", "delete", into.Code)
	c.run(1, "", "stock", "get", into.Code)
	c.ok("item", "delete", "Screw", "--yes")
}
