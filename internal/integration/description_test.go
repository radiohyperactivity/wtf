package integration

import (
	"testing"
)

// Descriptions of classes, items, locations and stock rows: given when made
// or changed, stored without blank space at the ends and with "\n" line
// ends, null for none; in an item's search text; carried along when stock
// is split off, and a difference a merge must resolve; in model files.
func TestDescriptions(t *testing.T) {
	e := setup(t)
	e.reset(t)

	description := func(body any) any {
		t.Helper()
		return get(t, body, "description")
	}

	// A class, made with one and changed.
	class := e.expect(t, 201, "POST", "/classes", obj("name", "Sensors", "description", "  Boards with a sensor.\r\n\r\n")).body
	classID := str(t, class, "id")
	if d := description(class); d != "Boards with a sensor." {
		t.Fatalf("class description: %q", d)
	}
	if d := description(e.expect(t, 200, "PATCH", "/classes/"+classID, obj("description", "I2C\r\nand SPI")).body); d != "I2C\nand SPI" {
		t.Errorf("class description changed: %q", d)
	}
	// Made without one, and blank is none.
	other := e.expect(t, 201, "POST", "/classes", obj("name", "Cables")).body
	if d := description(other); d != nil {
		t.Errorf("no description: %v", d)
	}
	if d := description(e.expect(t, 200, "PATCH", "/classes/"+str(t, other, "id"), obj("description", " \n ")).body); d != nil {
		t.Errorf("blank description: %v", d)
	}
	e.expect(t, 400, "PATCH", "/classes/"+classID, obj("description", 12))

	// An item: in its search text, also after a change.
	item := e.expect(t, 201, "POST", "/items", obj("class", classID, "name", "BMP280",
		"values", obj(), "description", "Pressure and temperature.\nOn a purple board.")).body
	itemID := str(t, item, "id")
	if d := description(item); d != "Pressure and temperature.\nOn a purple board." {
		t.Fatalf("item description: %q", d)
	}
	found := func(words string) int {
		t.Helper()
		return len(get(t, e.expect(t, 200, "GET", "/items?search="+words, nil).body, "rows").([]any))
	}
	if n := found("purple"); n != 1 {
		t.Errorf("search for a word of the description: %d rows", n)
	}
	e.expect(t, 200, "PATCH", "/items/"+itemID, obj("description", "Blue board."))
	if found("purple") != 0 || found("blue") != 1 {
		t.Errorf("search after the change: purple %d, blue %d", found("purple"), found("blue"))
	}
	if d := description(e.expect(t, 200, "PATCH", "/items/"+itemID, obj("description", nil)).body); d != nil {
		t.Errorf("item description removed: %v", d)
	}
	if found("blue") != 0 {
		t.Errorf("search after removing it: %d", found("blue"))
	}
	// Lists leave descriptions out.
	if _, ok := get(t, e.expect(t, 200, "GET", "/items", nil).body, "rows", 0).(map[string]any)["description"]; ok {
		t.Errorf("an item list has descriptions")
	}

	// A location.
	box := e.expect(t, 201, "POST", "/locations", obj("name", "Box 001", "parent", nil, "container", false,
		"grid", nil, "description", "The grey one.")).body
	boxID := str(t, box, "id")
	if d := description(box); d != "The grey one." {
		t.Errorf("location description: %q", d)
	}
	if d := description(e.expect(t, 200, "PATCH", "/locations/"+boxID, obj("description", "The grey one, on the left.")).body); d != "The grey one, on the left." {
		t.Errorf("location description changed: %q", d)
	}
	shelf := str(t, e.expect(t, 201, "POST", "/locations", obj("name", "Shelf", "parent", nil, "container", false, "grid", nil)).body, "id")

	// A stock row: split off with it; merging rows with different ones
	// must say which to keep.
	row := e.expect(t, 201, "POST", "/stock", obj("item", itemID, "location", boxID, "amount", 10,
		"values", obj(), "description", "From the first order.")).body
	rowID := str(t, row, "id")
	if d := description(row); d != "From the first order." {
		t.Fatalf("stock description: %q", d)
	}
	split := e.expect(t, 200, "POST", "/stock/"+rowID+"/move", obj("location", shelf, "amount", 4)).body
	if d := description(split); d != "From the first order." {
		t.Errorf("split row's description: %v", d)
	}
	splitID := str(t, split, "id")
	e.expect(t, 200, "PATCH", "/stock/"+splitID, obj("description", "Tested."))
	e.expect(t, 422, "POST", "/stock/"+splitID+"/merge", obj("into", rowID))
	merged := e.expect(t, 200, "POST", "/stock/"+splitID+"/merge",
		obj("into", rowID, "resolve", obj("description", "from"))).body
	if d := description(merged); d != "Tested." || num(t, merged, "amount") != 10 {
		t.Errorf("merged: %v", merged)
	}

	// Model files have a class's description, and an import gives it to the
	// classes it adds.
	model := e.expect(t, 200, "GET", "/classes/"+classID+"/model", nil).body
	if num(t, model, "version") != 4 || get(t, model, "classes", 0, "description") != "I2C\nand SPI" {
		t.Fatalf("model file: %v", model)
	}
	file := map[string]any{"format": "wtf-model", "version": 4, "classes": []any{
		obj("name", "Displays", "description", "OLED and e-paper."),
	}}
	e.expect(t, 200, "POST", "/model/import", file)
	tree := e.expect(t, 200, "GET", "/classes", nil).body
	// The class named Displays, wherever it is in the tree.
	var displays string
	var find func(v any)
	find = func(v any) {
		switch v := v.(type) {
		case map[string]any:
			if v["name"] == "Displays" {
				displays, _ = v["id"].(string)
			}
			for _, w := range v {
				find(w)
			}
		case []any:
			for _, w := range v {
				find(w)
			}
		}
	}
	find(tree)
	if displays == "" {
		t.Fatalf("Displays not imported: %v", tree)
	}
	if d := description(e.expect(t, 200, "GET", "/classes/"+displays, nil).body); d != "OLED and e-paper." {
		t.Errorf("imported description: %v", d)
	}
	file["classes"] = []any{obj("name", "Displays", "description", 3)}
	e.expect(t, 400, "POST", "/model/import", file)
}
