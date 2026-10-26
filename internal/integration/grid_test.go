package integration

import (
	"strings"
	"testing"
)

// TestGrid covers locations created with a grid of compartments named like
// spreadsheet cells, and the natural order of the trees.
func TestGrid(t *testing.T) {
	e := setup(t)
	e.reset(t)

	box := e.expect(t, 201, "POST", "/locations", obj("name", "Box 3", "grid", obj("columns", 8, "rows", 5))).body
	if get(t, box, "container") != true {
		t.Errorf("a box with a grid must be a container: %v", box)
	}
	tree := e.expect(t, 200, "GET", "/locations", nil).body
	cells := get(t, tree, "tree", 0, "children").([]any)
	if len(cells) != 40 {
		t.Fatalf("%d compartments, want 40", len(cells))
	}
	var names []string
	for _, c := range cells {
		names = append(names, str(t, c, "name"))
		if str(t, c, "code") == "" || get(t, c, "container") != false {
			t.Errorf("compartment: %v", c)
		}
	}
	if names[0] != "A1" || names[1] != "A2" || names[5] != "B1" || names[39] != "H5" {
		t.Errorf("names: %v", names)
	}

	// Natural order: A2 before A10, and columns past Z continue with AA.
	e.expect(t, 201, "POST", "/locations", obj("name", "Tall", "grid", obj("columns", 27, "rows", 12)))
	tree = e.expect(t, 200, "GET", "/locations", nil).body
	var tall []any
	for _, n := range get(t, tree, "tree").([]any) {
		if str(t, n, "name") == "Tall" {
			tall = get(t, n, "children").([]any)
		}
	}
	if len(tall) != 27*12 || str(t, tall[1], "name") != "A2" || str(t, tall[9], "name") != "A10" ||
		str(t, tall[12], "name") != "AA1" || str(t, tall[len(tall)-1], "name") != "Z12" {
		t.Errorf("order: %v %v %v %v", get(t, tall[1], "name"), get(t, tall[9], "name"), get(t, tall[12], "name"), get(t, tall[len(tall)-1], "name"))
	}

	// Bad grids, and nothing created by them.
	for _, grid := range []any{
		obj("columns", 0, "rows", 5),
		obj("columns", 50, "rows", 21), // 1051 locations, not confirmed
		obj("columns", 50, "rows", 21, "confirm", "yes"),
		obj("columns", 8),
		obj("columns", 8, "rows", 5, "depth", 2),
		obj("columns", "8", "rows", 5),
		"8x5",
	} {
		r := e.expect(t, 400, "POST", "/locations", obj("name", "Bad", "grid", grid))
		if !strings.Contains(str(t, r.body, "detail"), "grid") {
			t.Errorf("grid %v: detail %q", grid, str(t, r.body, "detail"))
		}
	}
	for _, n := range get(t, e.expect(t, 200, "GET", "/locations", nil).body, "tree").([]any) {
		if str(t, n, "name") == "Bad" {
			t.Error("a bad grid created a location")
		}
	}

	// Exactly 1000 locations need no confirmation; more do.
	e.expect(t, 201, "POST", "/locations", obj("name", "Thousand", "grid", obj("columns", 37, "rows", 27))) // 999 + 1
	big := str(t, e.expect(t, 201, "POST", "/locations",
		obj("name", "Big", "grid", obj("columns", 50, "rows", 21, "confirm", true))).body, "id")
	for _, n := range get(t, e.expect(t, 200, "GET", "/locations", nil).body, "tree").([]any) {
		if str(t, n, "id") == big && len(get(t, n, "children").([]any)) != 1050 {
			t.Errorf("Big has %d compartments", len(get(t, n, "children").([]any)))
		}
	}

	// Classes have no grids.
	e.expect(t, 400, "POST", "/classes", obj("name", "Gridded", "grid", obj("columns", 2, "rows", 2)))
}
