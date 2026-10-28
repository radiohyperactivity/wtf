package integration

import (
	"context"
	"strings"
	"testing"

	"github.com/radiohyperactivity/wtf/internal/admin"
)

// isDeleted checks that the object at path is still there, marked deleted.
func isDeleted(t *testing.T, e *environment, path string) {
	t.Helper()
	if body := e.expect(t, 200, "GET", path, nil).body; get(t, body, "deleted") != true {
		t.Errorf("%s isn't marked deleted: %v", path, body)
	}
}

// purgeDeleted removes everything deleted, however recently.
func purgeDeleted(t *testing.T, e *environment) map[string]int64 {
	t.Helper()
	conn, err := admin.Connect(context.Background(), e.dbaConfig)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(context.Background())
	counts, err := admin.PurgeDeleted(context.Background(), conn, 0, false)
	if err != nil {
		t.Fatal(err)
	}
	return counts
}

// refused checks a 409 because something is deleted, with a message that
// contains want.
func refused(t *testing.T, r response, want string) {
	t.Helper()
	if str(t, r.body, "type") != "/problems/deleted" || !strings.Contains(str(t, r.body, "detail"), want) {
		t.Errorf("want a deleted problem with %q, got %v", want, r.body)
	}
}

// treeNames returns the names in a tree, depth first.
func treeNames(t *testing.T, e *environment, path string) []string {
	t.Helper()
	var names []string
	var walk func(nodes any)
	walk = func(nodes any) {
		for _, n := range nodes.([]any) {
			names = append(names, str(t, n, "name"))
			walk(get(t, n, "children"))
		}
	}
	walk(get(t, e.expect(t, 200, "GET", path, nil).body, "tree"))
	return names
}

func TestDeleted(t *testing.T) {
	e := setup(t)
	e.reset(t)
	location := func(name string, parent any) string {
		return str(t, e.expect(t, 201, "POST", "/locations", obj("name", name, "parent", parent)).body, "id")
	}

	tools := str(t, e.expect(t, 201, "POST", "/classes", obj("name", "Tools")).body, "id")
	drill := e.expect(t, 201, "POST", "/items", obj("class", tools, "name", "Drill")).body
	drillID := str(t, drill, "id")
	shelf := location("Shelf", nil)
	row := e.expect(t, 201, "POST", "/stock", obj("item", drillID, "location", shelf, "quantity", 2)).body
	rowID := str(t, row, "id")

	// Deleting a stock row marks it: it is still there, but lists leave it out.
	e.expect(t, 204, "DELETE", "/stock/"+rowID, nil)
	isDeleted(t, e, "/stock/"+rowID)
	if n := num(t, e.expect(t, 200, "GET", "/stock?item="+drillID, nil).body, "total"); n != 0 {
		t.Errorf("stock list shows a deleted row")
	}
	if n := num(t, e.expect(t, 200, "GET", "/items?search=drill", nil).body, "rows", 0, "stock", "total"); n != 0 {
		t.Errorf("item list counts deleted stock")
	}
	if len(get(t, e.expect(t, 200, "GET", "/items/"+drillID, nil).body, "stock").([]any)) != 0 {
		t.Error("a live item lists a deleted stock row")
	}
	// Its label code still answers.
	if r := e.expect(t, 200, "GET", "/codes/"+str(t, row, "code"), nil).body; get(t, r, "object", "deleted") != true {
		t.Errorf("code of a deleted row: %v", r)
	}

	// Deleted rows are frozen, and live rows can't use them.
	refused(t, e.expect(t, 409, "PATCH", "/stock/"+rowID, obj("quantity", 3)), "is deleted")
	refused(t, e.expect(t, 409, "POST", "/stock/"+rowID+"/move", obj("location", shelf)), "is deleted")
	e.expect(t, 200, "POST", "/stock/"+rowID+"/restore", nil)
	if get(t, e.expect(t, 200, "GET", "/stock/"+rowID, nil).body, "deleted") != false {
		t.Error("restored row is still deleted")
	}
	refused(t, e.expect(t, 409, "POST", "/stock/"+rowID+"/restore", nil), "is not deleted")

	// Something live depends on it: refused, as before.
	e.expect(t, 409, "DELETE", "/items/"+drillID, nil)
	e.expect(t, 409, "DELETE", "/locations/"+shelf, nil)

	// A deleted name is free again; restoring it then needs a new name.
	box := location("Box", shelf)
	e.expect(t, 204, "DELETE", "/locations/"+box, nil)
	refused(t, e.expect(t, 409, "POST", "/stock", obj("item", drillID, "location", box)), `Location "Box" is deleted`)
	newBox := location("Box", shelf)
	e.expect(t, 409, "POST", "/locations/"+box+"/restore", nil) // duplicate name
	restored := e.expect(t, 200, "POST", "/locations/"+box+"/restore", obj("name", "Old box")).body
	if str(t, restored, "name") != "Old box" || get(t, restored, "deleted") != false {
		t.Errorf("restored box: %v", restored)
	}
	_ = newBox

	// A tree comes back with what was deleted together with it: here the
	// compartment A1 and its stock, but not B1, deleted on its own before.
	grid := str(t, e.expect(t, 201, "POST", "/locations", obj("name", "Case", "parent", shelf,
		"grid", obj("columns", 2, "rows", 1))).body, "id")
	compartment := map[string]string{}
	var find func(nodes any)
	find = func(nodes any) {
		for _, n := range nodes.([]any) {
			if get(t, n, "parent") == grid {
				compartment[str(t, n, "name")] = str(t, n, "id")
			}
			find(get(t, n, "children"))
		}
	}
	find(get(t, e.expect(t, 200, "GET", "/locations", nil).body, "tree"))
	inA1 := str(t, e.expect(t, 201, "POST", "/stock", obj("item", drillID, "location", compartment["A1"], "quantity", 1)).body, "id")
	e.expect(t, 204, "DELETE", "/locations/"+compartment["B1"], nil)
	e.expect(t, 200, "DELETE", "/locations/"+grid+"?recursive=true&force=true", nil)
	if names := strings.Join(treeNames(t, e, "/locations"), ","); strings.Contains(names, "Case") || strings.Contains(names, "A1") {
		t.Errorf("tree after delete: %s", names)
	}
	e.expect(t, 200, "POST", "/locations/"+grid+"/restore", nil)
	if names := strings.Join(treeNames(t, e, "/locations"), ","); !strings.Contains(names, "Case,A1") || strings.Contains(names, "B1") {
		t.Errorf("tree after restore: %s", names)
	}
	if get(t, e.expect(t, 200, "GET", "/stock/"+inA1, nil).body, "deleted") != false {
		t.Error("the stock in A1 wasn't restored")
	}

	// Restoring into something deleted: refused, or with its parents, or
	// somewhere else.
	room := location("Room", nil)
	cupboard := location("Cupboard", room)
	e.expect(t, 204, "DELETE", "/locations/"+cupboard, nil)
	e.expect(t, 204, "DELETE", "/locations/"+room, nil)
	r := e.expect(t, 409, "POST", "/locations/"+cupboard+"/restore", nil)
	refused(t, r, `is in "Room", which is deleted`)
	if !strings.Contains(str(t, r.body, "hint"), "with_parents") {
		t.Errorf("hint: %v", r.body)
	}
	refused(t, e.expect(t, 409, "POST", "/locations/"+cupboard+"/restore", obj("parent", room)), `"Room" is deleted`)
	e.expect(t, 200, "POST", "/locations/"+cupboard+"/restore", obj("with_parents", true))
	if get(t, e.expect(t, 200, "GET", "/locations/"+room, nil).body, "deleted") != false {
		t.Error("with_parents didn't restore the room")
	}
	e.expect(t, 204, "DELETE", "/locations/"+cupboard, nil)
	e.expect(t, 204, "DELETE", "/locations/"+room, nil)
	moved := e.expect(t, 200, "POST", "/locations/"+cupboard+"/restore", obj("parent", nil)).body
	if get(t, moved, "parent") != nil || get(t, e.expect(t, 200, "GET", "/locations/"+room, nil).body, "deleted") != true {
		t.Errorf("restored at the top: %v", moved)
	}

	// A stock row at a deleted location, the same way.
	bin := location("Bin", nil)
	inBin := str(t, e.expect(t, 201, "POST", "/stock", obj("item", drillID, "location", bin, "quantity", 1)).body, "id")
	e.expect(t, 200, "DELETE", "/locations/"+bin+"?recursive=true&force=true", nil)
	e.expect(t, 204, "DELETE", "/stock/"+rowID, nil)
	refused(t, e.expect(t, 409, "POST", "/stock/"+inBin+"/restore", nil), `which is deleted`)
	if l := str(t, e.expect(t, 200, "POST", "/stock/"+inBin+"/restore", obj("location", shelf)).body, "location"); l != shelf {
		t.Errorf("restored somewhere else: %s", l)
	}

	// A row merged into another by a move can't be restored.
	e.expect(t, 200, "POST", "/stock/"+inBin+"/move", obj("location", compartment["A1"]))
	r = e.expect(t, 409, "POST", "/stock/"+inBin+"/restore", nil)
	refused(t, r, "was merged into")

	// An item comes back with the stock deleted together with it, also when
	// its class was deleted with it.
	e.expect(t, 200, "DELETE", "/classes/"+tools+"?recursive=true&force=true", nil)
	isDeleted(t, e, "/items/"+drillID)
	isDeleted(t, e, "/stock/"+inA1)
	if deletedItem := e.expect(t, 200, "GET", "/items/"+drillID, nil).body; len(get(t, deletedItem, "stock").([]any)) != 1 {
		t.Errorf("a deleted item lists its deleted stock: %v", get(t, deletedItem, "stock"))
	}
	refused(t, e.expect(t, 409, "POST", "/items/"+drillID+"/restore", nil), `class "Tools"`)
	r = e.expect(t, 409, "POST", "/stock/"+inA1+"/restore", nil)
	refused(t, r, `belongs to Item "Drill", which is deleted`)
	if !strings.Contains(str(t, r.body, "hint"), "Restore the item") {
		t.Errorf("hint: %v", r.body)
	}
	e.expect(t, 200, "POST", "/classes/"+tools+"/restore", nil)
	if get(t, e.expect(t, 200, "GET", "/items/"+drillID, nil).body, "deleted") != false ||
		get(t, e.expect(t, 200, "GET", "/stock/"+inA1, nil).body, "deleted") != false {
		t.Error("restoring the class didn't restore its item and stock")
	}

	// Attributes and options.
	size := str(t, e.expect(t, 201, "POST", "/attributes", obj("name", "Size", "datatype", "choice")).body, "id")
	small := str(t, e.expect(t, 201, "POST", "/attributes/"+size+"/options", obj("name", "Small")).body, "id")
	e.expect(t, 201, "POST", "/attributes/"+size+"/options", obj("name", "Large"))
	e.expect(t, 200, "PUT", "/classes/"+tools+"/attributes/"+size, nil)
	e.expect(t, 200, "PUT", "/items/"+drillID+"/values/"+size, obj("value", "Small"))
	e.expect(t, 409, "DELETE", "/options/"+small, nil) // in use
	e.expect(t, 409, "DELETE", "/attributes/"+size, nil)
	e.expect(t, 200, "PUT", "/items/"+drillID+"/values/"+size, obj("value", "Large"))
	e.expect(t, 204, "DELETE", "/options/"+small, nil)
	e.expect(t, 400, "PUT", "/items/"+drillID+"/values/"+size, obj("value", "Small")) // not an option any more
	if opts := get(t, e.expect(t, 200, "GET", "/attributes/"+size, nil).body, "options").([]any); len(opts) != 1 {
		t.Errorf("options: %v", opts)
	}
	e.expect(t, 200, "POST", "/options/"+small+"/restore", nil)
	e.expect(t, 200, "PUT", "/items/"+drillID+"/values/"+size, obj("value", "Small"))

	// History: a delete is an update of deleted.
	h := e.expect(t, 200, "GET", "/options/"+small, nil).body
	_ = h
	rows := get(t, e.expect(t, 200, "GET", "/attributes/"+size+"/history", nil).body, "rows").([]any)
	if str(t, rows[0], "operation") != "update" || get(t, rows[0], "changes", "deleted", "new") != false {
		t.Errorf("history of a restore: %v", rows[0])
	}

	// Purging removes deleted rows for good, and then their codes are unknown.
	e.expect(t, 204, "DELETE", "/stock/"+inA1, nil)
	counts := purgeDeleted(t, e)
	if counts["stock"] < 2 || counts["location"] < 3 {
		t.Errorf("purged: %v", counts)
	}
	e.expect(t, 404, "GET", "/stock/"+inA1, nil)
	e.expect(t, 404, "GET", "/locations/"+room, nil)
	e.expect(t, 200, "GET", "/locations/"+cupboard, nil)
}

func TestDeletedRules(t *testing.T) {
	e := setup(t)
	e.reset(t)
	class := func(name string, parent any) string {
		return str(t, e.expect(t, 201, "POST", "/classes", obj("name", name, "parent", parent)).body, "id")
	}

	// A class restored with the classes it is in.
	tools := class("Tools", nil)
	drills := class("Drills", tools)
	cordless := class("Cordless", drills)
	e.expect(t, 204, "DELETE", "/classes/"+cordless, nil)
	e.expect(t, 200, "DELETE", "/classes/"+tools+"?recursive=true", nil)
	e.expect(t, 200, "POST", "/classes/"+cordless+"/restore", obj("with_parents", true))
	for _, id := range []string{tools, drills, cordless} {
		if get(t, e.expect(t, 200, "GET", "/classes/"+id, nil).body, "deleted") != false {
			t.Errorf("class %s still deleted", id)
		}
	}

	// An item restored in another class.
	other := class("Other", nil)
	item := str(t, e.expect(t, 201, "POST", "/items", obj("class", cordless, "name", "Drill")).body, "id")
	e.expect(t, 204, "DELETE", "/items/"+item, nil)
	e.expect(t, 204, "DELETE", "/classes/"+cordless, nil)
	if c := str(t, e.expect(t, 200, "POST", "/items/"+item+"/restore", obj("class", other)).body, "class", "id"); c != other {
		t.Errorf("restored in class %s", c)
	}

	// Values of a deleted item don't block changes to the model, and the
	// item can't be changed; restoring it checks its values again.
	colour := str(t, e.expect(t, 201, "POST", "/attributes", obj("name", "Colour", "datatype", "text")).body, "id")
	e.expect(t, 200, "PUT", "/classes/"+other+"/attributes/"+colour, nil)
	e.expect(t, 200, "PUT", "/items/"+item+"/values/"+colour, obj("value", "red"))
	e.expect(t, 204, "DELETE", "/items/"+item, nil)
	refused(t, e.expect(t, 409, "PUT", "/items/"+item+"/values/"+colour, obj("value", "blue")), `Item "Drill" is deleted`)
	refused(t, e.expect(t, 409, "DELETE", "/items/"+item+"/values/"+colour, nil), `Item "Drill" is deleted`)
	e.expect(t, 200, "DELETE", "/classes/"+other+"/attributes/"+colour, nil)
	e.expect(t, 422, "POST", "/items/"+item+"/restore", nil) // its value no longer applies
	e.expect(t, 200, "PUT", "/classes/"+other+"/attributes/"+colour, nil)
	e.expect(t, 200, "POST", "/items/"+item+"/restore", nil)

	// Required values are checked again on restore: here the attribute
	// became required while the item, without a value, was deleted.
	size := str(t, e.expect(t, 201, "POST", "/attributes", obj("name", "Size", "datatype", "text")).body, "id")
	e.expect(t, 200, "PUT", "/classes/"+other+"/attributes/"+size, nil)
	e.expect(t, 204, "DELETE", "/items/"+item, nil)
	e.expect(t, 200, "PUT", "/classes/"+other+"/attributes/"+size, obj("required", true))
	e.expect(t, 422, "POST", "/items/"+item+"/restore", nil)
	e.expect(t, 200, "PUT", "/classes/"+other+"/attributes/"+size, obj("required", true, "default", "M"))
	e.expect(t, 200, "POST", "/items/"+item+"/restore", nil)

	// Nothing moves into a deleted location.
	shed := str(t, e.expect(t, 201, "POST", "/locations", obj("name", "Shed")).body, "id")
	van := str(t, e.expect(t, 201, "POST", "/locations", obj("name", "Van")).body, "id")
	e.expect(t, 204, "DELETE", "/locations/"+van, nil)
	refused(t, e.expect(t, 409, "PATCH", "/locations/"+shed, obj("parent", van)), `Location "Van" is deleted`)

	// A deleted location can be found in the history of the one it was in,
	// and a deleted item in its class's; renaming them isn't shown there.
	box := str(t, e.expect(t, 201, "POST", "/locations", obj("name", "Box", "parent", shed)).body, "id")
	e.expect(t, 200, "PATCH", "/locations/"+box, obj("name", "Crate"))
	e.expect(t, 204, "DELETE", "/locations/"+box, nil)
	kinds, rows := historyOf(t, e, "/locations/"+shed+"/history")
	if strings.Join(kinds, ",") != "location.update,location.insert,location.insert" ||
		get(t, rows[0], "changes", "deleted", "new") != true || str(t, rows[0], "data", "id") != box {
		t.Errorf("shed history: %v", kinds)
	}
	e.expect(t, 204, "DELETE", "/items/"+item, nil)
	if kinds, rows := historyOf(t, e, "/classes/"+other+"/history"); kinds[0] != "item.update" || str(t, rows[0], "data", "id") != item {
		t.Errorf("class history: %v", kinds)
	}
	e.expect(t, 200, "POST", "/items/"+item+"/restore", nil)

	// Attachments stay with a deleted item, photo included, and come back
	// with it; purging it removes them for good.
	photo := str(t, e.upload(t, 201, "/items/"+item+"/attachments", "a.png", "image/png", pngBytes,
		"photo", "true").body, "id")
	e.expect(t, 204, "DELETE", "/items/"+item, nil)
	e.expect(t, 409, "DELETE", "/items/"+item+"/attachments/"+photo, nil)
	e.expect(t, 200, "POST", "/items/"+item+"/restore", nil)
	if str(t, e.expect(t, 200, "GET", "/items/"+item, nil).body, "photo", "id") != photo {
		t.Error("the restored item lost its photo")
	}
	e.expect(t, 204, "DELETE", "/items/"+item, nil)
	purgeDeleted(t, e)
	e.expect(t, 404, "GET", "/items/"+item+"/attachments/"+photo, nil)
}

// The top level of the trees and the list of attributes have a history of
// their own, so that a deleted top-level location, top-level class or
// attribute can be found.
func TestListHistory(t *testing.T) {
	e := setup(t)
	e.reset(t)
	ids := func(rows []any) string {
		var s []string
		for _, r := range rows {
			s = append(s, str(t, r, "data", "name"))
		}
		return strings.Join(s, ",")
	}

	garage := str(t, e.expect(t, 201, "POST", "/locations", obj("name", "Garage")).body, "id")
	shed := str(t, e.expect(t, 201, "POST", "/locations", obj("name", "Shed")).body, "id")
	box := str(t, e.expect(t, 201, "POST", "/locations", obj("name", "Box", "parent", garage)).body, "id")
	e.expect(t, 200, "PATCH", "/locations/"+garage, obj("name", "Car port")) // not a change of the top level
	e.expect(t, 200, "PATCH", "/locations/"+box, obj("parent", nil))         // to the top
	e.expect(t, 200, "PATCH", "/locations/"+box, obj("parent", shed))        // and away again
	e.expect(t, 200, "DELETE", "/locations/"+shed+"?recursive=true", nil)    // Box goes with it, inside
	kinds, rows := historyOf(t, e, "/locations/history")
	if got := strings.Join(kinds, ","); got != "location.update,location.update,location.update,location.insert,location.insert" ||
		ids(rows) != "Shed,Box,Box,Shed,Garage" || get(t, rows[0], "changes", "deleted", "new") != true {
		t.Errorf("top-level locations: %s %s", got, ids(rows))
	}

	tools := str(t, e.expect(t, 201, "POST", "/classes", obj("name", "Tools")).body, "id")
	e.expect(t, 201, "POST", "/classes", obj("name", "Drills", "parent", tools))
	e.expect(t, 200, "DELETE", "/classes/"+tools+"?recursive=true", nil)
	e.expect(t, 200, "POST", "/classes/"+tools+"/restore", nil)
	if kinds, rows := historyOf(t, e, "/classes/history"); strings.Join(kinds, ",") != "class.update,class.update,class.insert" ||
		ids(rows) != "Tools,Tools,Tools" {
		t.Errorf("top-level classes: %v %s", kinds, ids(rows))
	}

	size := str(t, e.expect(t, 201, "POST", "/attributes", obj("name", "Size", "datatype", "text")).body, "id")
	e.expect(t, 200, "PATCH", "/attributes/"+size, obj("name", "Length"))
	e.expect(t, 204, "DELETE", "/attributes/"+size, nil)
	if kinds, rows := historyOf(t, e, "/attributes/history"); strings.Join(kinds, ",") != "attribute.update,attribute.insert" ||
		ids(rows) != "Length,Size" {
		t.Errorf("attributes: %v %s", kinds, ids(rows))
	}
}
