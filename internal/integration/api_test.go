package integration

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/url"
	"regexp"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"

	"github.com/radiohyperactivity/wtf/db"
	"github.com/radiohyperactivity/wtf/internal/schema"
)

const missing = "00000000-0000-0000-0000-000000000000"

func obj(kv ...any) map[string]any {
	m := map[string]any{}
	for i := 0; i+1 < len(kv); i += 2 {
		m[kv[i].(string)] = kv[i+1]
	}
	return m
}

func TestSchemaIsUpToDate(t *testing.T) {
	e := setup(t)
	result, err := schema.Run(context.Background(), schema.Options{
		ConnConfig: e.dbaConfig,
		APIUser:    e.apiUser,
		Scripts:    db.Scripts,
		DryRun:     true,
		Logger:     slog.New(slog.NewTextHandler(io.Discard, nil)),
	})
	if err != nil {
		t.Fatal(err)
	}
	if result.Pending {
		t.Error("a second wtfd schema run still finds changes")
	}
}

func TestAPIRoleIsRestricted(t *testing.T) {
	e := setup(t)
	for _, sql := range []string{
		"SELECT count(*) FROM item",
		"SELECT error.invalid('x')",
		"SELECT count(*) FROM wtfd.migration",
		"CREATE TABLE intruder (id int)",
	} {
		_, err := e.api.Exec(context.Background(), sql)
		var pgErr *pgconn.PgError
		if !errors.As(err, &pgErr) || pgErr.Code != "42501" {
			t.Errorf("%s as the API role: got %v, want permission denied (42501)", sql, err)
		}
	}

	// Without a session, the API functions refuse to work, even for the API role.
	_, err := e.api.Exec(context.Background(), "SELECT item.list(ROW(NULL, NULL)::public.request)")
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) || pgErr.Code != "28000" {
		t.Errorf("item.list without a session: got %v, want 28000", err)
	}
	_, err = e.api.Exec(context.Background(), "SELECT item.list(ROW('guessed', NULL)::public.request)")
	if !errors.As(err, &pgErr) || pgErr.Code != "28000" {
		t.Errorf("item.list with a made-up token: got %v, want 28000", err)
	}
}

func TestAttributesThroughTheAPI(t *testing.T) {
	e := setup(t)
	e.reset(t)

	tools := str(t, e.expect(t, 201, "POST", "/classes", obj("name", "Tools")).body, "id")
	add := func(name string, def map[string]any, query string) response {
		return e.expect(t, 200, "POST", "/classes/"+tools+"/attributes"+query, obj("name", name, "definition", def))
	}
	add("Supply voltage", obj("scope", "item", "type", "decimal", "unit", "V", "default", 18), "")
	add("Colour", obj("scope", "item", "type", "choice", "choices", []string{"Red", "Blue"}), "")
	dry := add("Lot", obj("scope", "stock", "type", "text"), "?dry_run=true").body
	if get(t, dry, "dry_run") != true || len(get(t, dry, "class", "attributes").([]any)) != 3 {
		t.Fatalf("dry run: %v", dry)
	}
	if n := len(get(t, e.expect(t, 200, "GET", "/classes/"+tools, nil).body, "attributes").([]any)); n != 2 {
		t.Fatalf("after the dry run: %d attributes", n)
	}

	drill := e.expect(t, 201, "POST", "/items", obj("class", tools, "name", "Drill", "values", obj("Colour", "Red"))).body
	id := str(t, drill, "id")
	if num(t, drill, "values", "Supply voltage") != 18 {
		t.Fatalf("default: %v", get(t, drill, "values"))
	}

	// A name with a space, in the path.
	path := "/classes/" + tools + "/attributes/" + url.PathEscape("Supply voltage")
	r := e.expect(t, 200, "PATCH", path, obj("default", 24)).body
	if num(t, r, "items") != 1 {
		t.Fatalf("default changed: %v", r)
	}
	if num(t, e.expect(t, 200, "GET", "/items/"+id, nil).body, "values", "Supply voltage") != 24 {
		t.Fatal("the item didn't follow the default")
	}
	e.expect(t, 200, "POST", path+"/rename", obj("name", "Voltage"))
	e.expect(t, 200, "PATCH", "/items/"+id, obj("values", obj("Voltage", 12, "Colour", nil)))
	item := e.expect(t, 200, "GET", "/items/"+id, nil).body
	if num(t, item, "values", "Voltage") != 12 || get(t, item, "values", "Colour") != nil {
		t.Fatalf("patched values: %v", get(t, item, "values"))
	}
	e.expect(t, 422, "PATCH", "/items/"+id, obj("values", obj("Voltage", "high")))
	e.expect(t, 400, "POST", "/classes/"+tools+"/attributes", obj("name", "Name", "definition", obj("scope", "item", "type", "text")))

	choices := "/classes/" + tools + "/attributes/Colour/choices"
	e.expect(t, 200, "POST", choices, obj("choice", "Green"))
	e.expect(t, 200, "POST", choices+"/Green/rename", obj("choice", "Lime"))
	e.expect(t, 200, "DELETE", choices+"/Lime", nil)
	e.expect(t, 200, "DELETE", "/classes/"+tools+"/attributes/Colour", nil)

	// Model files round trip.
	file := e.expect(t, 200, "GET", "/classes/"+tools+"/model", nil).body
	report := e.expect(t, 200, "POST", "/model/import?dry_run=true", file).body
	if num(t, report, "classes", "existing") != 1 || get(t, report, "dry_run") != true {
		t.Fatalf("import report: %v", report)
	}
}

func TestListsAndPaging(t *testing.T) {
	e := setup(t)
	e.reset(t)

	parts := str(t, e.expect(t, 201, "POST", "/classes", obj("name", "Parts")).body, "id")
	e.expect(t, 200, "POST", "/classes/"+parts+"/attributes", obj("name", "Size", "definition", obj("scope", "item", "type", "integer")))
	for _, n := range []int{1, 2, 3, 4, 5} {
		e.expect(t, 201, "POST", "/items", obj("class", parts, "name", "Part "+string(rune('0'+n)), "values", obj("Size", n)))
	}
	page := e.expect(t, 200, "GET", "/items?limit=2", nil).body
	if get(t, page, "more") != true || len(get(t, page, "rows").([]any)) != 2 {
		t.Fatalf("first page: %v", page)
	}
	page = e.expect(t, 200, "GET", "/items?limit=2&after="+str(t, page, "next"), nil).body
	if str(t, page, "rows", 0, "name") != "Part 3" {
		t.Fatalf("second page: %v", page)
	}
	where := url.QueryEscape(`[{"attribute": "Size", "op": ">=", "value": 4}]`)
	page = e.expect(t, 200, "GET", "/items?where="+where, nil).body
	if len(get(t, page, "rows").([]any)) != 2 || get(t, page, "more") != false {
		t.Fatalf("filtered: %v", page)
	}
	if n := len(get(t, e.expect(t, 200, "GET", "/items?search=art%204", nil).body, "rows").([]any)); n != 1 {
		t.Fatalf("search: %d rows", n)
	}
}

func TestStock(t *testing.T) {
	e := setup(t)
	e.reset(t)

	garage := str(t, e.expect(t, 201, "POST", "/locations", obj("name", "Garage")).body, "id")
	shelf := e.expect(t, 201, "POST", "/locations", obj("name", "Shelf", "parent", garage)).body
	if n := len(get(t, shelf, "path").([]any)); n != 2 {
		t.Errorf("path has %d entries, want 2", n)
	}
	shelfID := str(t, shelf, "id")
	attic := str(t, e.expect(t, 201, "POST", "/locations", obj("name", "Attic")).body, "id")

	classID := str(t, e.expect(t, 201, "POST", "/classes", obj("name", "Parts")).body, "id")
	e.expect(t, 200, "POST", "/classes/"+classID+"/attributes",
		obj("name", "Serial", "definition", obj("scope", "stock", "type", "text")))
	itemID := str(t, e.expect(t, 201, "POST", "/items", obj("class", classID, "name", "Screw")).body, "id")
	source := str(t, e.expect(t, 201, "POST", "/stock", obj("item", itemID, "location", shelfID, "amount", 10)).body, "id")

	// Partial move to a location without stock: split.
	moved := e.expect(t, 200, "POST", "/stock/"+source+"/move", obj("location", attic, "amount", 4)).body
	atticRow := str(t, moved, "id")
	if atticRow == source || num(t, moved, "amount") != 4 {
		t.Fatalf("split: %v", moved)
	}

	// A move never merges, also where there is a row of the item already;
	// merging is its own action.
	moved = e.expect(t, 200, "POST", "/stock/"+source+"/move", obj("location", attic, "amount", 2)).body
	if str(t, moved, "id") == atticRow || num(t, moved, "amount") != 2 {
		t.Fatalf("second split: %v", moved)
	}
	e.expect(t, 200, "POST", "/stock/"+str(t, moved, "id")+"/merge", obj("into", atticRow))

	// Moving more than there is, and a part of a piece.
	e.expect(t, 400, "POST", "/stock/"+atticRow+"/move", obj("location", garage, "amount", 11))
	e.expect(t, 422, "POST", "/stock", obj("item", itemID, "location", garage, "amount", 1.5))

	// An uncounted row in the garage.
	e.expect(t, 201, "POST", "/stock", obj("item", itemID, "location", garage, "values", obj("Serial", "SN-1")))

	list := e.expect(t, 200, "GET", "/items?search=scr", nil).body
	if len(get(t, list, "rows").([]any)) != 1 || num(t, list, "rows", 0, "stock", "total") != 10 ||
		get(t, list, "rows", 0, "stock", "uncounted") != true {
		t.Errorf("item list stock total: %v", get(t, list, "rows", 0, "stock"))
	}
	// The shelf's row (in the garage) and the garage's own; the attic's.
	if n := len(get(t, e.expect(t, 200, "GET", "/stock?location="+garage, nil).body, "rows").([]any)); n != 2 {
		t.Errorf("stock in the garage (and below): %v rows, want 2", n)
	}
	if n := len(get(t, e.expect(t, 200, "GET", "/stock?search=sn-1", nil).body, "rows").([]any)); n != 1 {
		t.Errorf("stock by a value: %v rows, want 1", n)
	}
	item := e.expect(t, 200, "GET", "/items/"+itemID, nil).body
	if n := len(get(t, item, "stock").([]any)); n != 3 {
		t.Errorf("item get has %d stock rows, want 3", n)
	}

	// An item made with its first stock row, in one request: the answer is
	// the item with it.
	made := e.expect(t, 201, "POST", "/items", obj("class", classID, "name", "Bolt",
		"stock", obj("location", garage, "amount", 5, "values", obj("Serial", "SN-9")))).body
	if rows := get(t, made, "stock").([]any); len(rows) != 1 || num(t, rows[0], "amount") != 5 ||
		str(t, rows[0], "values", "Serial") != "SN-9" || str(t, rows[0], "location") != garage {
		t.Errorf("an item with its stock: %v", get(t, made, "stock"))
	}
	// Uncounted, and without stock (null, as leaving it out).
	made = e.expect(t, 201, "POST", "/items", obj("class", classID, "name", "Nut",
		"stock", obj("location", attic, "amount", nil, "values", obj()))).body
	if rows := get(t, made, "stock").([]any); len(rows) != 1 || get(t, rows[0], "amount") != nil {
		t.Errorf("an item with uncounted stock: %v", get(t, made, "stock"))
	}
	made = e.expect(t, 201, "POST", "/items", obj("class", classID, "name", "Washer", "stock", nil)).body
	if rows := get(t, made, "stock").([]any); len(rows) != 0 {
		t.Errorf("an item with stock null: %v", rows)
	}

	// Refused stock refuses the item too: nothing is made.
	e.expect(t, 422, "POST", "/items", obj("class", classID, "name", "Rivet",
		"stock", obj("location", garage, "amount", 1.5, "values", obj())))
	e.expect(t, 422, "POST", "/items", obj("class", classID, "name", "Rivet",
		"stock", obj("location", "00000000-0000-0000-0000-000000000000", "amount", 1, "values", obj())))
	for _, bad := range []map[string]any{
		obj("location", garage, "amount", 1),                              // no values
		obj("location", nil, "amount", 1, "values", obj()),                // no location
		obj("location", garage, "amount", "1", "values", obj()),           // not a number
		obj("location", garage, "amount", 1, "values", obj(), "count", 1), // unknown
	} {
		e.expect(t, 400, "POST", "/items", obj("class", classID, "name", "Rivet", "stock", bad))
	}
	e.expect(t, 400, "POST", "/items", obj("class", classID, "name", "Rivet", "stock", "garage"))
	if rows := get(t, e.expect(t, 200, "GET", "/items?search=rivet", nil).body, "rows").([]any); len(rows) != 0 {
		t.Errorf("a refused item was made: %v", rows)
	}
}

// How a class's items' stock is counted: the class's rule, inherited down
// the tree, checked against every stock row, and refusing what would
// relabel counted stock without saying so (2026-11-22-stock-rules-on-classes.md).
func TestStockRules(t *testing.T) {
	e := setup(t)
	e.reset(t)
	rule := func(class string) map[string]any {
		t.Helper()
		return get(t, e.expect(t, 200, "GET", "/classes/"+class, nil).body, "stock").(map[string]any)
	}
	// refused expects a refusal with status, whose answer says each of want.
	refused := func(status int, method, path string, body any, want ...string) {
		t.Helper()
		contains(t, fmt.Sprint(e.expect(t, status, method, path, body).body), want...)
	}
	shelf := str(t, e.expect(t, 201, "POST", "/locations", obj("name", "Shelf")).body, "id")

	// The default, for a class without a rule of its own: counted, optional,
	// in pieces.
	tools := str(t, e.expect(t, 201, "POST", "/classes", obj("name", "Tools")).body, "id")
	sameJSON(t, "the default", rule(tools), obj("counting", "optional", "unit", nil, "from", nil))

	// A rule of its own, inherited by a class made below it, and by its items.
	r := e.expect(t, 200, "PUT", "/classes/"+tools+"/stock", obj("counting", "optional", "unit", "m")).body
	if num(t, r, "relabelled") != 0 || str(t, r, "class", "stock", "unit") != "m" {
		t.Errorf("a rule of its own: %v", r)
	}
	cables := str(t, e.expect(t, 201, "POST", "/classes", obj("name", "Cables", "parent", tools)).body, "id")
	sameJSON(t, "inherited", rule(cables), obj("counting", "optional", "unit", "m", "from", tools))
	e.expect(t, 400, "POST", "/items", obj("class", cables, "name", "Cable", "unit", "m"))
	cable := e.expect(t, 201, "POST", "/items", obj("class", cables, "name", "Cable",
		"stock", obj("location", shelf, "amount", 2.5, "values", obj()))).body
	if str(t, cable, "unit") != "m" || str(t, cable, "counting") != "optional" {
		t.Errorf("an item has its class's rule: %v", cable)
	}
	cableID := str(t, cable, "id")
	counted := str(t, get(t, cable, "stock").([]any)[0], "id")
	e.expect(t, 201, "POST", "/stock", obj("item", cableID, "location", shelf)) // uncounted

	// Another unit relabels counted stock: a dry run says how many rows,
	// and changes nothing.
	r = e.expect(t, 200, "PUT", "/classes/"+tools+"/stock?dry_run=true", obj("counting", "optional", "unit", "cm")).body
	if num(t, r, "relabelled") != 1 || get(t, r, "dry_run") != true {
		t.Errorf("a dry run of another unit: %v", r)
	}
	if rule(cables)["unit"] != "m" {
		t.Error("the dry run changed the unit")
	}
	r = e.expect(t, 200, "PUT", "/classes/"+tools+"/stock", obj("counting", "optional", "unit", "cm")).body
	if num(t, r, "relabelled") != 1 || rule(cables)["unit"] != "cm" {
		t.Errorf("another unit: %v", r)
	}

	// Rules the stock doesn't fit are refused, saying how many rows.
	refused(422, "PUT", "/classes/"+cables+"/stock", obj("counting", "required", "unit", "cm"), "1 stock row(s) wouldn't fit", "has no amount")
	refused(422, "PUT", "/classes/"+cables+"/stock", obj("counting", "none", "unit", nil), "doesn't count its stock")
	e.expect(t, 400, "PUT", "/classes/"+cables+"/stock", obj("counting", "none", "unit", "cm"))
	e.expect(t, 400, "PUT", "/classes/"+cables+"/stock", obj("counting", "lots", "unit", nil))
	// Inheriting the default, pieces: 2.5 isn't whole.
	refused(422, "DELETE", "/classes/"+tools+"/stock", nil, "a part of a piece")

	// Moving the class elsewhere would count its stock in another unit.
	e.expect(t, 200, "PATCH", "/stock/"+counted, obj("amount", 3))
	refused(422, "PATCH", "/classes/"+cables, obj("parent", nil), "in another unit")
	// With a rule of its own, it keeps its unit wherever it goes.
	e.expect(t, 200, "PUT", "/classes/"+cables+"/stock", obj("counting", "optional", "unit", "cm"))
	e.expect(t, 200, "PATCH", "/classes/"+cables, obj("parent", nil))
	sameJSON(t, "its own, moved", rule(cables), obj("counting", "optional", "unit", "cm", "from", cables))

	// An item moves to a class with another unit only without counted stock,
	// and to a class requiring amounts only with them all counted.
	plugs := str(t, e.expect(t, 201, "POST", "/classes", obj("name", "Plugs")).body, "id")
	refused(422, "PATCH", "/items/"+cableID, obj("class", plugs), "counted in cm", "counts in pieces")
	e.expect(t, 200, "PATCH", "/stock/"+counted, obj("amount", nil))
	e.expect(t, 200, "PATCH", "/items/"+cableID, obj("class", plugs))
	consumables := str(t, e.expect(t, 201, "POST", "/classes", obj("name", "Consumables")).body, "id")
	e.expect(t, 200, "PUT", "/classes/"+consumables+"/stock", obj("counting", "required", "unit", nil))
	refused(422, "PATCH", "/items/"+cableID, obj("class", consumables), "requires an amount")

	// A stock row given to an item counted in another unit keeps its amount
	// only when the change gives it too.
	glue := str(t, e.expect(t, 201, "POST", "/items", obj("class", consumables, "name", "Glue",
		"stock", obj("location", shelf, "amount", 4, "values", obj()))).body, "id")
	metres := str(t, e.expect(t, 201, "POST", "/items", obj("class", tools, "name", "Rope")).body, "id")
	glueRow := str(t, get(t, e.expect(t, 200, "GET", "/items/"+glue, nil).body, "stock").([]any)[0], "id")
	refused(422, "PATCH", "/stock/"+glueRow, obj("item", metres), "nothing converts")
	e.expect(t, 200, "PATCH", "/stock/"+glueRow, obj("item", metres, "amount", 400))

	// Required: every row has an amount. Not counted: none has.
	e.expect(t, 422, "POST", "/stock", obj("item", glue, "location", shelf))
	e.expect(t, 422, "POST", "/items", obj("class", consumables, "name", "Tape",
		"stock", obj("location", shelf, "amount", nil, "values", obj())))
	furniture := str(t, e.expect(t, 201, "POST", "/classes", obj("name", "Furniture")).body, "id")
	e.expect(t, 200, "PUT", "/classes/"+furniture+"/stock", obj("counting", "none", "unit", nil))
	chair := str(t, e.expect(t, 201, "POST", "/items", obj("class", furniture, "name", "Chair")).body, "id")
	e.expect(t, 422, "POST", "/stock", obj("item", chair, "location", shelf, "amount", 1))
	e.expect(t, 201, "POST", "/stock", obj("item", chair, "location", shelf))

	// Inheriting again: Cables, at the top now, takes the default.
	e.expect(t, 200, "DELETE", "/classes/"+cables+"/stock", nil)
	sameJSON(t, "inheriting again", rule(cables), obj("counting", "optional", "unit", nil, "from", nil))

	// Model files: version 4, with the rules; read back where they are, they
	// change nothing.
	model := e.expect(t, 200, "GET", "/classes/"+furniture+"/model", nil).body
	if num(t, model, "version") != 4 {
		t.Errorf("model version: %v", get(t, model, "version"))
	}
	sameJSON(t, "a rule in a model file", get(t, model, "classes", 0, "stock"), obj("counting", "none"))
	r = e.expect(t, 200, "POST", "/model/import", model).body
	if num(t, r, "classes", "added") != 0 {
		t.Errorf("importing it again: %v", r)
	}
	// A class there already with another rule is refused; a new one gets it.
	other := map[string]any{"format": "wtf-model", "version": 3, "classes": []any{
		obj("name", "Furniture", "stock", obj("counting", "optional", "unit", nil)),
		obj("name", "Fabric", "stock", obj("counting", "required", "unit", "m")),
	}}
	refused(409, "POST", "/model/import", other, "not counted already")
	other["classes"] = other["classes"].([]any)[1:]
	e.expect(t, 200, "POST", "/model/import", other)
	classes := get(t, e.expect(t, 200, "GET", "/classes", nil).body, "tree").([]any)
	found := false
	for _, c := range classes {
		if str(t, c, "name") == "Fabric" {
			found = true
			sameJSON(t, "an imported rule", rule(str(t, c, "id")),
				obj("counting", "required", "unit", "m", "from", str(t, c, "id")))
		}
	}
	if !found {
		t.Error("Fabric wasn't imported")
	}
}

func TestTreeVersions(t *testing.T) {
	e := setup(t)
	e.reset(t)

	parent := str(t, e.expect(t, 201, "POST", "/classes", obj("name", "Tools")).body, "id")
	e.expect(t, 201, "POST", "/classes", obj("name", "Drills", "parent", parent))

	r := e.expect(t, 200, "GET", "/classes", nil)
	etag := r.header.Get("ETag")
	if etag == "" || r.header.Get("Cache-Control") != "no-cache" {
		t.Fatalf("headers: %v", r.header)
	}
	if str(t, r.body, "tree", 0, "children", 0, "name") != "Drills" {
		t.Errorf("tree: %v", get(t, r.body, "tree"))
	}

	e.expect(t, 304, "GET", "/classes", nil, "If-None-Match", etag)
	e.expect(t, 200, "PATCH", "/classes/"+parent, obj("name", "Hand tools"))
	r = e.expect(t, 200, "GET", "/classes", nil, "If-None-Match", etag)
	if r.header.Get("ETag") == etag {
		t.Error("the ETag did not change after a rename")
	}
	etag = r.header.Get("ETag")
	e.expect(t, 200, "POST", "/classes/"+parent+"/attributes", obj("name", "Brand", "definition", obj("scope", "item", "type", "text")))
	if e.expect(t, 200, "GET", "/classes", nil).header.Get("ETag") == etag {
		t.Error("the ETag did not change after a new attribute")
	}
}

func TestPatch(t *testing.T) {
	e := setup(t)
	e.reset(t)

	a := str(t, e.expect(t, 201, "POST", "/classes", obj("name", "A")).body, "id")
	b := str(t, e.expect(t, 201, "POST", "/classes", obj("name", "B")).body, "id")

	if p := str(t, e.expect(t, 200, "PATCH", "/classes/"+b, obj("parent", a)).body, "parent"); p != a {
		t.Errorf("parent = %s, want %s", p, a)
	}
	if p := get(t, e.expect(t, 200, "PATCH", "/classes/"+b, obj("parent", nil)).body, "parent"); p != nil {
		t.Errorf("parent = %v, want null", p)
	}
	if n := str(t, e.expect(t, 200, "PATCH", "/classes/"+b, obj()).body, "name"); n != "B" {
		t.Errorf("empty patch changed the name to %q", n)
	}
	e.expect(t, 400, "PATCH", "/classes/"+b, obj("name", nil))
	e.expect(t, 400, "PATCH", "/classes/"+b, obj("colour", "red"))
}

func TestErrors(t *testing.T) {
	e := setup(t)
	e.reset(t)

	e.expect(t, 201, "POST", "/classes", obj("name", "Tools"))
	garage := str(t, e.expect(t, 201, "POST", "/locations", obj("name", "Garage")).body, "id")
	shelf := str(t, e.expect(t, 201, "POST", "/locations", obj("name", "Shelf", "parent", garage)).body, "id")

	tests := []struct {
		name         string
		method, path string
		body         any
		status       int
		problem      string
	}{
		{"duplicate name, other case", "POST", "/classes", obj("name", "tools"), 409, "/problems/unique-violation"},
		{"unknown object", "GET", "/items/" + missing, nil, 404, "/problems/not-found"},
		{"bad UUID in path", "GET", "/items/nope", nil, 400, "/problems/invalid-input"},
		{"bad UUID in query", "GET", "/items?class=nope", nil, 400, "/problems/invalid-input"},
		{"malformed JSON", "POST", "/classes", "{name:", 400, "/problems/invalid-input"},
		{"missing required field", "POST", "/classes", obj(), 400, "/problems/invalid-input"},
		{"reference to a missing object", "POST", "/classes", obj("name", "X", "parent", missing), 422, "/problems/invalid-reference"},
		{"delete while in use", "DELETE", "/locations/" + garage, nil, 409, "/problems/in-use"},
		{"cycle", "PATCH", "/locations/" + garage, obj("parent", shelf), 422, "/problems/rule-violation"},
		{"bad paging", "GET", "/items?limit=0", nil, 400, "/problems/invalid-input"},
		{"body too large", "POST", "/classes", `{"name":"` + strings.Repeat("x", 2<<20) + `"}`, 413, "/problems/body-too-large"},
		{"wrong method", "PUT", "/me", nil, 405, "/problems/method-not-allowed"},
		{"unknown route", "GET", "/nothing", nil, 404, "/problems/not-found"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := e.expect(t, tt.status, tt.method, tt.path, tt.body)
			if r.header.Get("Content-Type") != "application/problem+json" {
				t.Errorf("Content-Type = %q", r.header.Get("Content-Type"))
			}
			if got := str(t, r.body, "type"); got != tt.problem {
				t.Errorf("type = %q, want %q", got, tt.problem)
			}
		})
	}
}

func TestCodes(t *testing.T) {
	e := setup(t)
	e.reset(t)
	crockford := regexp.MustCompile(`^[0-9A-HJKMNP-TV-Z]{4,}$`)

	loc := e.expect(t, 201, "POST", "/locations", obj("name", "Bin 4")).body
	classID := str(t, e.expect(t, 201, "POST", "/classes", obj("name", "Parts")).body, "id")
	item := e.expect(t, 201, "POST", "/items", obj("class", classID, "name", "Screw")).body
	stock := e.expect(t, 201, "POST", "/stock",
		obj("item", str(t, item, "id"), "location", str(t, loc, "id"), "amount", 5)).body

	codes := map[string]string{}
	for typ, o := range map[string]any{"location": loc, "item": item, "stock": stock} {
		code := str(t, o, "code")
		if !crockford.MatchString(code) {
			t.Errorf("%s code %q is not a 4+ character Crockford code", typ, code)
		}
		if other, dup := codes[code]; dup {
			t.Errorf("%s and %s share code %s", typ, other, code)
		}
		codes[code] = typ

		r := e.expect(t, 200, "GET", "/codes/"+code, nil).body
		if str(t, r, "type") != typ || str(t, r, "object", "id") != str(t, o, "id") {
			t.Errorf("code %s resolved to %v", code, r)
		}
	}

	// Lower case and hyphens are accepted.
	code := str(t, loc, "code")
	e.expect(t, 200, "GET", "/codes/"+strings.ToLower(code[:2])+"-"+code[2:], nil)

	// Codes appear in the location tree and in item lists.
	tree := e.expect(t, 200, "GET", "/locations", nil).body
	if str(t, tree, "tree", 0, "code") != code {
		t.Errorf("location tree code: %v", get(t, tree, "tree", 0))
	}
	list := e.expect(t, 200, "GET", "/items", nil).body
	if str(t, list, "rows", 0, "code") != str(t, item, "code") {
		t.Errorf("item list code: %v", get(t, list, "rows", 0))
	}

	e.expect(t, 404, "GET", "/codes/ZZZZZZ", nil)
	e.expect(t, 400, "GET", "/codes/1IL0", nil) // I and L are excluded letters
}
