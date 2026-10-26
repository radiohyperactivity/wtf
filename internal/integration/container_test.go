package integration

import (
	"strings"
	"testing"
)

// TestContainers: a container class holds no items, a container location no
// stock, and a node only becomes a container while it holds none.
func TestContainers(t *testing.T) {
	e := setup(t)
	e.reset(t)

	hw := e.expect(t, 201, "POST", "/classes", obj("name", "Hardware", "container", true)).body
	if get(t, hw, "container") != true {
		t.Errorf("created class: %v", hw)
	}
	hwID := str(t, hw, "id")
	screws := str(t, e.expect(t, 201, "POST", "/classes", obj("name", "Screws", "parent", hwID)).body, "id")

	r := e.expect(t, 422, "POST", "/items", obj("class", hwID, "name", "Loose"))
	if d := str(t, r.body, "detail"); !strings.Contains(d, `Class "Hardware" is a container`) {
		t.Errorf("detail: %s", d)
	}
	item := str(t, e.expect(t, 201, "POST", "/items", obj("class", screws, "name", "M3")).body, "id")
	e.expect(t, 422, "PATCH", "/items/"+item, obj("class", hwID))
	r = e.expect(t, 422, "PATCH", "/classes/"+screws, obj("container", true))
	if d := str(t, r.body, "detail"); !strings.Contains(d, "has 1 item") {
		t.Errorf("detail: %s", d)
	}
	e.expect(t, 400, "PATCH", "/classes/"+screws, obj("container", nil))
	tree := e.expect(t, 200, "GET", "/classes", nil).body
	if get(t, tree, "tree", 0, "container") != true || get(t, tree, "tree", 0, "children", 0, "container") != false {
		t.Errorf("class tree: %v", tree)
	}

	garage := str(t, e.expect(t, 201, "POST", "/locations", obj("name", "Garage", "container", true)).body, "id")
	shelf := str(t, e.expect(t, 201, "POST", "/locations", obj("name", "Shelf", "parent", garage)).body, "id")
	r = e.expect(t, 422, "POST", "/stock", obj("item", item, "location", garage, "quantity", 1))
	if d := str(t, r.body, "detail"); !strings.Contains(d, `Location "Garage" is a container`) {
		t.Errorf("detail: %s", d)
	}
	stock := str(t, e.expect(t, 201, "POST", "/stock", obj("item", item, "location", shelf, "quantity", 5)).body, "id")
	e.expect(t, 422, "POST", "/stock/"+stock+"/move", obj("location", garage, "quantity", 2))
	e.expect(t, 422, "PATCH", "/stock/"+stock, obj("location", garage))
	e.expect(t, 422, "PATCH", "/locations/"+shelf, obj("container", true))

	// Unmarking always works; then the node takes items and stock again.
	e.expect(t, 200, "PATCH", "/locations/"+garage, obj("container", false))
	e.expect(t, 200, "POST", "/stock/"+stock+"/move", obj("location", garage, "quantity", 2))
	loc := e.expect(t, 200, "GET", "/locations/"+garage, nil).body
	if get(t, loc, "container") != false {
		t.Errorf("location: %v", loc)
	}
}
