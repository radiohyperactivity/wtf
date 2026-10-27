package integration

import (
	"context"
	"encoding/json"
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
		"SELECT util.raise_invalid('x')",
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
	_, err := e.api.Exec(context.Background(), "SELECT item_list()")
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) || pgErr.Code != "28000" {
		t.Errorf("item_list() without a session: got %v, want 28000", err)
	}
	_, err = e.api.Exec(context.Background(), "SELECT set_config('wtf.token', 'guessed', false), item_list()")
	if !errors.As(err, &pgErr) || pgErr.Code != "28000" {
		t.Errorf("item_list() with a made-up token: got %v, want 28000", err)
	}
}

func TestUnitsAndDefaults(t *testing.T) {
	e := setup(t)
	e.reset(t)

	class := e.expect(t, 201, "POST", "/classes", obj("name", "Tools"))
	classID := str(t, class.body, "id")
	if loc := class.header.Get("Location"); loc != "/api/v1/classes/"+classID {
		t.Errorf("Location = %q", loc)
	}
	attr := e.expect(t, 201, "POST", "/attributes",
		obj("name", "Length", "datatype", "float", "unit", e.unit(t, "Metric length", "mm"))).body
	attrID := str(t, attr, "id")
	if str(t, attr, "unit", "family", "name") != "Metric length" || str(t, attr, "unit", "quantity", "name") != "Length" ||
		get(t, attr, "unit_lock") != false {
		t.Errorf("attribute: %v", attr)
	}

	c := e.expect(t, 200, "PUT", "/classes/"+classID+"/attributes/"+attrID, obj("default", 0.025)).body
	if v, u := num(t, c, "attributes", 0, "default_display", "value"), str(t, c, "attributes", 0, "default_display", "unit", "symbol"); v != 2.5 || u != "cm" {
		t.Errorf("default 0.025 m displays as %v %s, want 2.5 cm", v, u)
	}

	drill := e.expect(t, 201, "POST", "/items",
		obj("class", classID, "name", "Drill", "values", obj(attrID, 0.0012))).body
	if v, u := num(t, drill, "values", 0, "display", "value"), str(t, drill, "values", 0, "display", "unit", "symbol"); v != 1.2 || u != "mm" {
		t.Errorf("0.0012 m displays as %v %s, want 1.2 mm", v, u)
	}
	if get(t, drill, "values", 0, "is_default") != false {
		t.Error("an own value is marked as default")
	}

	saw := e.expect(t, 201, "POST", "/items", obj("class", classID, "name", "Saw")).body
	sawID := str(t, saw, "id")
	if get(t, saw, "values", 0, "is_default") != true || num(t, saw, "values", 0, "value") != 0.025 {
		t.Errorf("item without a value should show the default: %v", get(t, saw, "values"))
	}

	// Defaults are fallbacks: changing the default changes the item.
	e.expect(t, 200, "PUT", "/classes/"+classID+"/attributes/"+attrID, obj("default", 0.5))
	saw = e.expect(t, 200, "GET", "/items/"+sawID, nil).body
	if v, u := num(t, saw, "values", 0, "display", "value"), str(t, saw, "values", 0, "display", "unit", "symbol"); v != 50 || u != "cm" {
		t.Errorf("after changing the default: %v %s, want 50 cm", v, u)
	}

	// Zero is shown in the attribute's unit.
	drill = e.expect(t, 200, "PUT", "/items/"+str(t, drill, "id")+"/values/"+attrID, obj("value", 0)).body
	if u := str(t, drill, "values", 0, "display", "unit", "symbol"); u != "mm" {
		t.Errorf("zero displays in %s, want mm", u)
	}

	// With the unit locked, every number is shown in it.
	e.expect(t, 200, "PATCH", "/attributes/"+attrID, obj("unit_lock", true))
	saw = e.expect(t, 200, "GET", "/items/"+sawID, nil).body
	if v, u := num(t, saw, "values", 0, "display", "value"), str(t, saw, "values", 0, "display", "unit", "symbol"); v != 500 || u != "mm" {
		t.Errorf("locked to mm: %v %s, want 500 mm", v, u)
	}

	// The same for stock: an item counted in grams, locked.
	parts := str(t, e.expect(t, 201, "POST", "/classes", obj("name", "Parts")).body, "id")
	solder := e.expect(t, 201, "POST", "/items", obj("class", parts, "name", "Solder",
		"unit", e.unit(t, "Metric weight", "g"), "unit_lock", true)).body
	shelf := str(t, e.expect(t, 201, "POST", "/locations", obj("name", "Shelf")).body, "id")
	row := e.expect(t, 201, "POST", "/stock", obj("item", str(t, solder, "id"), "location", shelf, "quantity", 2.5)).body
	if v, u := num(t, row, "display", "value"), str(t, row, "display", "unit", "symbol"); v != 2500 || u != "g" {
		t.Errorf("2.5 kg of solder locked to g: %v %s", v, u)
	}
}

func TestWholeNumbers(t *testing.T) {
	e := setup(t)
	e.reset(t)

	r := e.expect(t, 422, "POST", "/attributes",
		obj("name", "Bad count", "datatype", "float", "unit", e.unit(t, "Pieces", "pcs")))
	if str(t, r.body, "type") != "/problems/rule-violation" {
		t.Errorf("type = %v", get(t, r.body, "type"))
	}

	classID := str(t, e.expect(t, 201, "POST", "/classes", obj("name", "Parts")).body, "id")
	itemID := str(t, e.expect(t, 201, "POST", "/items", obj("class", classID, "name", "Screw")).body, "id")
	locID := str(t, e.expect(t, 201, "POST", "/locations", obj("name", "Drawer")).body, "id")

	e.expect(t, 422, "POST", "/stock", obj("item", itemID, "location", locID, "quantity", 2.5))
	e.expect(t, 201, "POST", "/stock", obj("item", itemID, "location", locID, "quantity", 3))
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
	itemID := str(t, e.expect(t, 201, "POST", "/items", obj("class", classID, "name", "Screw")).body, "id")
	source := str(t, e.expect(t, 201, "POST", "/stock", obj("item", itemID, "location", shelfID, "quantity", 10)).body, "id")

	// Partial move to a location without stock: split.
	moved := e.expect(t, 200, "POST", "/stock/"+source+"/move", obj("location", attic, "quantity", 4)).body
	atticRow := str(t, moved, "id")
	if atticRow == source || num(t, moved, "quantity") != 4 {
		t.Fatalf("split: %v", moved)
	}

	// Partial move to a location with exactly one counted row: merge.
	moved = e.expect(t, 200, "POST", "/stock/"+source+"/move", obj("location", attic, "quantity", 2)).body
	if str(t, moved, "id") != atticRow || num(t, moved, "quantity") != 6 {
		t.Fatalf("merge: %v", moved)
	}

	// Whole move into it: merged, and the source row is marked deleted, merged into the other.
	moved = e.expect(t, 200, "POST", "/stock/"+source+"/move", obj("location", attic)).body
	if str(t, moved, "id") != atticRow || num(t, moved, "quantity") != 10 {
		t.Fatalf("whole merge: %v", moved)
	}
	if gone := e.expect(t, 200, "GET", "/stock/"+source, nil).body; get(t, gone, "deleted") != true || str(t, gone, "merged_into", "id") != atticRow {
		t.Errorf("merged row: %v", gone)
	}

	// Moving more than there is.
	e.expect(t, 400, "POST", "/stock/"+atticRow+"/move", obj("location", garage, "quantity", 11))

	// An uncounted row in the garage.
	e.expect(t, 201, "POST", "/stock", obj("item", itemID, "location", garage))

	list := e.expect(t, 200, "GET", "/items?search=scr", nil).body
	if num(t, list, "total") != 1 || num(t, list, "rows", 0, "stock", "total") != 10 || get(t, list, "rows", 0, "stock", "uncounted") != true {
		t.Errorf("item_list stock total: %v", get(t, list, "rows", 0, "stock"))
	}
	if n := num(t, e.expect(t, 200, "GET", "/stock?location="+garage, nil).body, "total"); n != 1 {
		t.Errorf("stock in the garage (and below): %v rows, want 1", n)
	}
	item := e.expect(t, 200, "GET", "/items/"+itemID, nil).body
	if n := len(get(t, item, "stock").([]any)); n != 2 {
		t.Errorf("item_get has %d stock rows, want 2", n)
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

func TestUnitChange(t *testing.T) {
	e := setup(t)
	e.reset(t)

	attr := str(t, e.expect(t, 201, "POST", "/attributes",
		obj("name", "Length", "datatype", "float", "unit", e.unit(t, "Metric length", "mm"))).body, "id")
	// Another unit of the same quantity, in another family too.
	e.expect(t, 200, "PATCH", "/attributes/"+attr, obj("unit", e.unit(t, "Metric length", "cm")))
	if f := str(t, e.expect(t, 200, "PATCH", "/attributes/"+attr, obj("unit", e.unit(t, "Imperial length", "in"))).body,
		"unit", "family", "name"); f != "Imperial length" {
		t.Errorf("family after the change: %s", f)
	}
	e.expect(t, 422, "PATCH", "/attributes/"+attr, obj("unit", e.unit(t, "Metric weight", "g")))
	e.expect(t, 422, "PATCH", "/attributes/"+attr, obj("unit", nil))
	e.expect(t, 400, "PATCH", "/attributes/"+attr, obj("unit", "in"))
	// Unit lock needs a unit.
	e.expect(t, 422, "POST", "/attributes", obj("name", "Colour", "datatype", "text", "unit_lock", true))
}

func TestUnitFamilies(t *testing.T) {
	e := setup(t)

	// The bootstrap set, with integer ids from 1000.
	families := e.expect(t, 200, "GET", "/unit-families", nil).body.([]any)
	byName := map[string]any{}
	for _, f := range families {
		byName[str(t, f, "name")] = f
	}
	binary := byName["Binary bytes"]
	if binary == nil || str(t, binary, "quantity", "name") != "Bytes" || num(t, binary, "id") < 1000 {
		t.Fatalf("Binary bytes: %v", binary)
	}
	var symbols []string
	for _, u := range get(t, binary, "units").([]any) {
		symbols = append(symbols, str(t, u, "symbol"))
	}
	if strings.Join(symbols, " ") != "B KiB MiB GiB TiB PiB" {
		t.Errorf("binary bytes, smallest first: %v", symbols)
	}
	// B is in both byte families, with the same conversion.
	if e.unit(t, "Decimal bytes", "B") == e.unit(t, "Binary bytes", "B") {
		t.Error("each family has its own B")
	}
	if byName["Bits"] == nil || str(t, byName["Bits"], "quantity", "name") != "Bits" {
		t.Errorf("bits are a quantity of their own: %v", byName["Bits"])
	}

	length := int(num(t, byName["Metric length"], "quantity", "id"))
	q := e.expect(t, 200, "GET", fmt.Sprintf("/quantities/%d", length), nil).body
	if n := len(get(t, q, "families").([]any)); n != 2 || str(t, q, "families", 0, "name") != "Metric length" {
		t.Errorf("Length families: %v", get(t, q, "families"))
	}
	units := e.expect(t, 200, "GET", fmt.Sprintf("/units?quantity=%d", length), nil).body.([]any)
	if len(units) != 10 || str(t, units[0], "symbol") != "nm" {
		t.Errorf("length units: %d, first %v", len(units), units[0])
	}
	mm := e.expect(t, 200, "GET", fmt.Sprintf("/units/%d", e.unit(t, "Metric length", "mm")), nil).body
	if str(t, mm, "family", "name") != "Metric length" || num(t, mm, "base_factor") != 0.001 {
		t.Errorf("mm: %v", mm)
	}
	e.expect(t, 404, "GET", "/units/1", nil)
	e.expect(t, 400, "GET", "/units/mm", nil)
	e.expect(t, 404, "GET", "/unit-families?quantity=1", nil)

	// Within a quantity, a symbol means one unit.
	_, err := e.dba.Exec(context.Background(),
		"INSERT INTO unit (family, name, symbol, base_factor) VALUES ($1, 'bit', 'B', 0.125)",
		int(num(t, binary, "id")))
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) || pgErr.Code != "23514" {
		t.Errorf("a second meaning of B: %v", err)
	}
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
		{"invalid datatype", "POST", "/attributes", obj("name", "X", "datatype", "colour"), 400, "/problems/invalid-input"},
		{"missing required field", "POST", "/classes", obj(), 400, "/problems/invalid-input"},
		{"reference to a missing object", "POST", "/classes", obj("name", "X", "parent", missing), 422, "/problems/invalid-reference"},
		{"delete while in use", "DELETE", "/locations/" + garage, nil, 409, "/problems/in-use"},
		{"cycle", "PATCH", "/locations/" + garage, obj("parent", shelf), 422, "/problems/rule-violation"},
		{"bad paging", "GET", "/items?limit=0", nil, 400, "/problems/invalid-input"},
		{"body too large", "POST", "/classes", `{"name":"` + strings.Repeat("x", 2<<20) + `"}`, 413, "/problems/body-too-large"},
		{"wrong method", "PUT", "/quantities", nil, 405, "/problems/method-not-allowed"},
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

func TestSearch(t *testing.T) {
	e := setup(t)
	e.reset(t)

	resistors := str(t, e.expect(t, 201, "POST", "/classes", obj("name", "Resistors")).body, "id")
	smd := str(t, e.expect(t, 201, "POST", "/classes", obj("name", "SMD", "parent", resistors)).body, "id")
	tools := str(t, e.expect(t, 201, "POST", "/classes", obj("name", "Tools")).body, "id")

	pkg := str(t, e.expect(t, 201, "POST", "/attributes", obj("name", "Package", "datatype", "choice")).body, "id")
	e.expect(t, 201, "POST", "/attributes/"+pkg+"/options", obj("name", "0805"))
	e.expect(t, 201, "POST", "/attributes/"+pkg+"/options", obj("name", "0603"))
	part := str(t, e.expect(t, 201, "POST", "/attributes", obj("name", "Part number", "datatype", "text")).body, "id")
	e.expect(t, 200, "PUT", "/classes/"+smd+"/attributes/"+pkg, obj("default", "0805"))
	e.expect(t, 200, "PUT", "/classes/"+resistors+"/attributes/"+part, nil)

	e.expect(t, 201, "POST", "/items", obj("class", smd, "name", "10k")) // Package from the default
	r4k7 := str(t, e.expect(t, 201, "POST", "/items", obj("class", smd, "name", "4k7")).body, "id")
	e.expect(t, 200, "PUT", "/items/"+r4k7+"/values/"+pkg, obj("value", "0603"))
	e.expect(t, 201, "POST", "/items", obj("class", resistors, "name", "100R", "values", obj(part, "PN-1234")))
	e.expect(t, 201, "POST", "/items", obj("class", tools, "name", "Drill"))

	tests := []struct {
		query string
		want  []string
	}{
		{"search=0805", []string{"10k"}},                    // class default
		{"search=0603", []string{"4k7"}},                    // own value overrides the default
		{"search=resistor+0805", []string{"10k"}},           // words match in different places
		{"search=smd", []string{"10k", "4k7"}},              // class name
		{"search=resistor", []string{"100R", "10k", "4k7"}}, // ancestor class
		{"search=pn-12", []string{"100R"}},                  // text value, substring
		{"search=++DRILL++", []string{"Drill"}},             // case and extra spaces
		{"search=drill+0805", nil},                          // all words must match
		{"search=resistor&class=" + smd, []string{"10k", "4k7"}},
		{"class=" + tools, []string{"Drill"}},
	}
	for _, tt := range tests {
		t.Run(tt.query, func(t *testing.T) {
			r := e.expect(t, 200, "GET", "/items?"+tt.query, nil)
			var got []string
			for _, row := range get(t, r.body, "rows").([]any) {
				got = append(got, str(t, row, "name"))
			}
			if strings.Join(got, ",") != strings.Join(tt.want, ",") {
				t.Errorf("got %v, want %v", got, tt.want)
			}
		})
	}
}

func TestSearchWhere(t *testing.T) {
	e := setup(t)
	e.reset(t)

	resistors := str(t, e.expect(t, 201, "POST", "/classes", obj("name", "Resistors")).body, "id")
	attribute := func(name, datatype string, more ...any) string {
		return str(t, e.expect(t, 201, "POST", "/attributes",
			obj(append([]any{"name", name, "datatype", datatype}, more...)...)).body, "id")
	}
	ohms := attribute("Resistance", "float", "unit", e.unit(t, "Resistance", "Ω"))
	pkg := attribute("Package", "choice")
	e.expect(t, 201, "POST", "/attributes/"+pkg+"/options", obj("name", "0805"))
	e.expect(t, 201, "POST", "/attributes/"+pkg+"/options", obj("name", "0603"))
	notes := attribute("Notes", "text")
	leadFree := attribute("Lead-free", "boolean")
	bought := attribute("Purchased", "date")
	e.expect(t, 200, "PUT", "/classes/"+resistors+"/attributes/"+ohms, nil)
	e.expect(t, 200, "PUT", "/classes/"+resistors+"/attributes/"+pkg, obj("default", "0805"))
	e.expect(t, 200, "PUT", "/classes/"+resistors+"/attributes/"+notes, nil)
	e.expect(t, 200, "PUT", "/classes/"+resistors+"/attributes/"+leadFree, nil)
	e.expect(t, 200, "PUT", "/classes/"+resistors+"/attributes/"+bought, obj("per_unit", true))
	shelf := str(t, e.expect(t, 201, "POST", "/locations", obj("name", "Shelf")).body, "id")

	item := func(name string, values map[string]any) string {
		return str(t, e.expect(t, 201, "POST", "/items",
			obj("class", resistors, "name", name, "values", values)).body, "id")
	}
	r10k := item("10k", obj(ohms, 10000))
	r4k7 := item("4k7", obj(ohms, 4700, pkg, "0603"))
	item("47k", obj(ohms, 47000, notes, "Metal film"))
	item("100R", obj(ohms, 100, leadFree, true))
	e.expect(t, 201, "POST", "/stock", obj("item", r10k, "location", shelf, "quantity", 5, "values", obj(bought, "2026-01-10")))
	e.expect(t, 201, "POST", "/stock", obj("item", r10k, "location", shelf, "quantity", 5, "values", obj(bought, "2025-05-01")))
	e.expect(t, 201, "POST", "/stock", obj("item", r4k7, "location", shelf, "quantity", 5))

	where := func(filters ...map[string]any) string {
		b, err := json.Marshal(append([]map[string]any{}, filters...))
		if err != nil {
			t.Fatal(err)
		}
		return "where=" + url.QueryEscape(string(b))
	}
	f := func(attribute, op string, value any) map[string]any {
		return obj("attribute", attribute, "op", op, "value", value)
	}
	tests := []struct {
		name  string
		query string
		want  []string
	}{
		{"greater or equal", where(f(ohms, ">=", 32000)), []string{"47k"}},
		{"less than", where(f(ohms, "<", 4700)), []string{"100R"}},
		{"exact number", where(f(ohms, "=", 4700)), []string{"4k7"}},
		{"range, inclusive", where(f(ohms, "between", []any{1000, 10000})), []string{"10k", "4k7"}},
		{"choice by name, defaults included", where(f(pkg, "=", "0805")), []string{"100R", "10k", "47k"}},
		{"any of several options", where(f(pkg, "in", []any{"0603", "0805"})), []string{"100R", "10k", "47k", "4k7"}},
		{"text contains, ignoring case", where(f(notes, "contains", "METAL")), []string{"47k"}},
		{"text exactly", where(f(notes, "=", "metal film")), []string{"47k"}},
		{"yes", where(f(leadFree, "=", true)), []string{"100R"}},
		{"per unit: any stock row", where(f(bought, ">=", "2026-01-01")), []string{"10k"}},
		{"per unit: no rows match", where(f(bought, "<", "2025-01-01")), nil},
		{"all filters must match", where(f(ohms, ">", 1000), f(pkg, "=", "0805")), []string{"10k", "47k"}},
		{"with search words", "search=4&" + where(f(ohms, ">", 1000)), []string{"47k", "4k7"}},
		{"no filters", where(), []string{"100R", "10k", "47k", "4k7"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := e.expect(t, 200, "GET", "/items?"+tt.query, nil)
			var got []string
			for _, row := range get(t, r.body, "rows").([]any) {
				got = append(got, str(t, row, "name"))
			}
			if strings.Join(got, ",") != strings.Join(tt.want, ",") {
				t.Errorf("got %v, want %v", got, tt.want)
			}
		})
	}

	for _, bad := range []string{
		"where=" + url.QueryEscape("{"),                             // not JSON
		"where=" + url.QueryEscape(`{"attribute": "x"}`),            // not a list
		where(f(ohms, "contains", 1)),                               // not for numbers
		where(f(ohms, ">", "1k")),                                   // numbers are numbers, in the base unit
		where(f(ohms, "between", []any{1})),                         // a range needs two ends
		where(f(pkg, "=", "1206")),                                  // no such option
		where(f(bought, ">", "2026-02-30")),                         // no such date
		where(f(leadFree, "=", "yes")),                              // true or false
		where(obj("attribute", ohms, "op", ">")),                    // no value
		where(obj("attribute", "not-an-id", "op", "=", "value", 1)), // no attribute id
	} {
		e.expect(t, 400, "GET", "/items?"+bad, nil)
	}
	e.expect(t, 404, "GET", "/items?"+where(f("00000000-0000-0000-0000-000000000000", "=", 1)), nil)
}

func TestCodes(t *testing.T) {
	e := setup(t)
	e.reset(t)
	crockford := regexp.MustCompile(`^[0-9A-HJKMNP-TV-Z]{4,}$`)

	loc := e.expect(t, 201, "POST", "/locations", obj("name", "Bin 4")).body
	classID := str(t, e.expect(t, 201, "POST", "/classes", obj("name", "Parts")).body, "id")
	item := e.expect(t, 201, "POST", "/items", obj("class", classID, "name", "Screw")).body
	stock := e.expect(t, 201, "POST", "/stock",
		obj("item", str(t, item, "id"), "location", str(t, loc, "id"), "quantity", 5)).body

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
		t.Errorf("item_list code: %v", get(t, list, "rows", 0))
	}

	e.expect(t, 404, "GET", "/codes/ZZZZZZ", nil)
	e.expect(t, 400, "GET", "/codes/1IL0", nil) // I and L are excluded letters
}

func TestUnitValuesAndRequired(t *testing.T) {
	e := setup(t)
	e.reset(t)

	tools := str(t, e.expect(t, 201, "POST", "/classes", obj("name", "Power tools")).body, "id")
	voltage := str(t, e.expect(t, 201, "POST", "/attributes",
		obj("name", "Voltage", "datatype", "float", "unit", e.unit(t, "Voltage", "V"))).body, "id")
	serial := str(t, e.expect(t, 201, "POST", "/attributes", obj("name", "Serial number", "datatype", "text")).body, "id")
	bought := str(t, e.expect(t, 201, "POST", "/attributes", obj("name", "Purchase date", "datatype", "date")).body, "id")
	condition := str(t, e.expect(t, 201, "POST", "/attributes", obj("name", "Condition", "datatype", "choice")).body, "id")
	e.expect(t, 201, "POST", "/attributes/"+condition+"/options", obj("name", "Good"))
	e.expect(t, 201, "POST", "/attributes/"+condition+"/options", obj("name", "Worn"))

	base := "/classes/" + tools + "/attributes/"
	e.expect(t, 200, "PUT", base+voltage, obj("required", true))
	e.expect(t, 200, "PUT", base+serial, obj("per_unit", true, "required", true))
	e.expect(t, 200, "PUT", base+bought, obj("per_unit", true))
	c := e.expect(t, 200, "PUT", base+condition, obj("per_unit", true, "default", "Good")).body
	for _, a := range get(t, c, "attributes").([]any) {
		if str(t, a, "attribute", "id") == serial && (get(t, a, "per_unit") != true || get(t, a, "required") != true) {
			t.Errorf("serial number assignment: %v", a)
		}
	}

	// Required per-kind value on create.
	e.expect(t, 422, "POST", "/items", obj("class", tools, "name", "Drill"))
	drill := e.expect(t, 201, "POST", "/items", obj("class", tools, "name", "Drill", "values", obj(voltage, 18))).body
	drillID := str(t, drill, "id")
	if n := len(get(t, drill, "missing").([]any)); n != 0 {
		t.Errorf("missing: %v", get(t, drill, "missing"))
	}

	shelf := str(t, e.expect(t, 201, "POST", "/locations", obj("name", "Shelf")).body, "id")
	van := str(t, e.expect(t, 201, "POST", "/locations", obj("name", "Van")).body, "id")
	site := str(t, e.expect(t, 201, "POST", "/locations", obj("name", "Site")).body, "id")

	// Required per-unit value on create.
	e.expect(t, 422, "POST", "/stock", obj("item", drillID, "location", shelf, "quantity", 4))
	row := e.expect(t, 201, "POST", "/stock", obj("item", drillID, "location", shelf, "quantity", 4,
		"values", obj(serial, "BATCH-7", bought, "2026-10-01"))).body
	rowID := str(t, row, "id")
	defaults := map[string]any{}
	for _, v := range get(t, row, "values").([]any) {
		defaults[str(t, v, "attribute", "name")] = get(t, v, "is_default")
	}
	if defaults["Serial number"] != false || defaults["Condition"] != true {
		t.Errorf("stock values: %v", get(t, row, "values"))
	}

	// Values go where their scope says.
	e.expect(t, 422, "PUT", "/items/"+drillID+"/values/"+serial, obj("value", "X"))
	e.expect(t, 422, "PUT", "/stock/"+rowID+"/values/"+voltage, obj("value", 12))
	e.expect(t, 422, "DELETE", "/stock/"+rowID+"/values/"+serial, nil) // required
	e.expect(t, 200, "PUT", "/stock/"+rowID+"/values/"+condition, obj("value", "Worn"))

	// Split copies the values; merging requires identical values.
	split := e.expect(t, 200, "POST", "/stock/"+rowID+"/move", obj("location", van, "quantity", 1)).body
	if str(t, split, "id") == rowID || len(get(t, split, "values").([]any)) != 3 {
		t.Fatalf("split: %v", split)
	}
	merged := e.expect(t, 200, "POST", "/stock/"+rowID+"/move", obj("location", van, "quantity", 1)).body
	if str(t, merged, "id") != str(t, split, "id") || num(t, merged, "quantity") != 2 {
		t.Errorf("merge into the identical row: %v", merged)
	}
	e.expect(t, 201, "POST", "/stock", obj("item", drillID, "location", site, "quantity", 1,
		"values", obj(serial, "OTHER")))
	moved := e.expect(t, 200, "POST", "/stock/"+rowID+"/move", obj("location", site, "quantity", 1)).body
	if num(t, moved, "quantity") != 1 || str(t, get(t, moved, "values").([]any)[2], "value") != "BATCH-7" {
		t.Errorf("rows with different values must not merge: %v", moved)
	}

	// Search finds per-unit values; item_get shows them on its stock rows.
	list := e.expect(t, 200, "GET", "/items?search=batch-7", nil).body
	if num(t, list, "total") != 1 || get(t, list, "rows", 0, "incomplete") != false {
		t.Errorf("search by serial number: %v", list)
	}
	item := e.expect(t, 200, "GET", "/items/"+drillID, nil).body
	if len(get(t, item, "stock", 0, "values").([]any)) != 3 {
		t.Errorf("item_get stock row values: %v", get(t, item, "stock", 0))
	}

	// A requirement added later doesn't block anything; it's reported.
	e.expect(t, 200, "PUT", base+bought, obj("per_unit", true, "required", true))
	other := e.expect(t, 200, "GET", "/items?search=drill", nil).body
	if get(t, other, "rows", 0, "incomplete") != true {
		t.Errorf("item with a stock row lacking a newly required value should be incomplete: %v", get(t, other, "rows", 0))
	}

	// The scope can't change while values exist.
	e.expect(t, 422, "PUT", base+serial, obj("per_unit", false, "required", true))
}
