package integration

import (
	"bytes"
	"encoding/json"
	"os"
	"strings"
	"testing"
)

// TestModelImport checks model files (seed/model-format.md): what isn't
// there is added, what is there and the same is used, what differs is a
// conflict, and with a conflict nothing is kept.
func TestModelImport(t *testing.T) {
	e := setup(t)
	e.reset(t)
	count := func(report any, kind, which string) int {
		return len(get(t, report, kind, which).([]any))
	}
	mcu, err := os.ReadFile("../../seed/models/mcu.json")
	if err != nil {
		t.Fatal(err)
	}

	// A dry run tells, and keeps nothing.
	r := e.expect(t, 200, "POST", "/model/import?dry_run=true", string(mcu)).body
	if get(t, r, "applied") != false || get(t, r, "dry_run") != true ||
		count(r, "attributes", "added") != 11 || count(r, "classes", "added") != 5 ||
		count(r, "assignments", "added") != 13 || count(r, "options", "added") != 15 ||
		len(get(t, r, "conflicts").([]any)) != 0 {
		t.Fatalf("dry run: %v", r)
	}
	if n := len(e.expect(t, 200, "GET", "/attributes", nil).body.([]any)); n != 0 {
		t.Fatalf("a dry run added %d attributes", n)
	}

	// The import.
	r = e.expect(t, 200, "POST", "/model/import", string(mcu)).body
	if get(t, r, "applied") != true || count(r, "classes", "added") != 5 {
		t.Fatalf("import: %v", r)
	}
	classes := e.expect(t, 200, "GET", "/classes", nil).body
	mcuClass := get(t, classes, "tree", 0)
	if str(t, mcuClass, "name") != "MCU" || get(t, mcuClass, "container") != true ||
		len(get(t, mcuClass, "children").([]any)) != 4 {
		t.Fatalf("the class tree: %v", classes)
	}
	var avr string
	for _, c := range get(t, mcuClass, "children").([]any) {
		if str(t, c, "name") == "AVR" {
			avr = str(t, c, "id")
		}
	}
	// AVR inherits MCU's attributes, and has its own Core with a default.
	attrs := e.expect(t, 200, "GET", "/classes/"+avr, nil).body
	var core any
	for _, a := range get(t, attrs, "attributes").([]any) {
		if str(t, a, "attribute", "name") == "Core" {
			core = a
		}
	}
	if len(get(t, attrs, "attributes").([]any)) != 11 || core == nil ||
		get(t, core, "inherited") != false || str(t, core, "default", "name") != "AVR" {
		t.Errorf("AVR's attributes: %v", get(t, attrs, "attributes"))
	}

	// Importing again changes nothing.
	r = e.expect(t, 200, "POST", "/model/import", string(mcu)).body
	if get(t, r, "applied") != true ||
		count(r, "attributes", "added")+count(r, "classes", "added")+count(r, "assignments", "added")+count(r, "options", "added") != 0 ||
		count(r, "attributes", "existing") != 11 || count(r, "classes", "existing") != 5 || count(r, "assignments", "existing") != 13 {
		t.Errorf("a second import: %v", r)
	}

	// A file that extends: a new option, a new class below an existing one,
	// an attribute the file doesn't define, and a default in the file's unit.
	// PIC's Package is what it inherits from MCU, so it is there already.
	more := `{"format": "wtf-model", "version": 1,
		"attributes": [{"name": "Package", "datatype": "choice", "options": ["DIP", "PLCC"]}],
		"classes": [{"name": "MCU", "classes": [
			{"name": "PIC", "attributes": [{"attribute": "Clock", "default": 20}, {"attribute": "Package"}]}]}]}`
	r = e.expect(t, 200, "POST", "/model/import", more).body
	if get(t, r, "applied") != true || count(r, "options", "added") != 1 || count(r, "classes", "added") != 1 ||
		count(r, "classes", "existing") != 1 || count(r, "assignments", "added") != 1 || count(r, "assignments", "existing") != 1 {
		t.Fatalf("an extending file: %v", r)
	}
	var defaultClock float64
	if err := e.dba.QueryRow(t.Context(), `SELECT ca.float_default FROM class_attribute ca
		JOIN class c ON c.id = ca.class JOIN attribute a ON a.id = ca.attribute
		WHERE c.name = 'PIC' AND a.name = 'Clock'`).Scan(&defaultClock); err != nil || defaultClock != 20e6 {
		t.Errorf("20 MHz stored as %v (%v)", defaultClock, err)
	}

	// Conflicts: all of them reported, and nothing kept.
	conflicting := `{"format": "wtf-model", "version": 1,
		"attributes": [
			{"name": "Clock", "datatype": "text"},
			{"name": "Flash", "unit": "mm"},
			{"name": "Weight", "unit": "furlongs"},
			{"name": "Size", "unit": "B"},
			{"name": "Fresh", "datatype": "text"}],
		"classes": [
			{"name": "MCU", "container": false},
			{"name": "Tools", "attributes": [
				{"attribute": "Nothing"},
				{"attribute": "GPIO pins", "default": "many"}]},
			{"name": "MCU2", "classes": [{"name": "X", "attributes": [{"attribute": "Fresh"}]}]}]}`
	r = e.expect(t, 200, "POST", "/model/import", conflicting).body
	conflicts := get(t, r, "conflicts").([]any)
	if get(t, r, "applied") != false || len(conflicts) != 7 {
		t.Fatalf("conflicts: %v", r)
	}
	for _, want := range []string{"datatype float", "measured in Bytes", "no unit furlongs", "several unit families",
		"a container", "no attribute Nothing", "doesn't fit GPIO pins, an integer attribute"} {
		found := false
		for _, c := range conflicts {
			found = found || strings.Contains(str(t, c, "message"), want)
		}
		if !found {
			t.Errorf("no conflict says %q: %v", want, conflicts)
		}
	}
	for _, a := range e.expect(t, 200, "GET", "/attributes", nil).body.([]any) {
		if str(t, a, "name") == "Fresh" {
			t.Error("a file with conflicts added an attribute")
		}
	}

	// Below a class.
	r = e.expect(t, 200, "POST", "/model/import?parent="+avr,
		`{"format": "wtf-model", "version": 1, "classes": [{"name": "ATtiny"}]}`).body
	if get(t, r, "applied") != true || str(t, r, "classes", "added", 0) != "MCU/AVR/ATtiny" {
		t.Errorf("below AVR: %v", r)
	}
	e.expect(t, 422, "POST", "/model/import?parent=00000000-0000-0000-0000-000000000001",
		`{"format": "wtf-model", "version": 1}`)

	// Files that aren't valid model files.
	for _, bad := range []string{
		`{"format": "wtf-units", "version": 1}`,
		`{"format": "wtf-model", "version": 2}`,
		`{"format": "wtf-model", "version": 1, "colour": "red"}`,
		`{"format": "wtf-model", "version": 1, "attributes": [{"name": "A", "datatype": "text"}, {"name": "a", "datatype": "text"}]}`,
		`{"format": "wtf-model", "version": 1, "attributes": [{"name": "A"}]}`,
		`{"format": "wtf-model", "version": 1, "attributes": [{"name": "A", "datatype": "text", "options": ["x"]}]}`,
		`{"format": "wtf-model", "version": 1, "classes": [{"name": "A/B"}]}`,
		`{"format": "wtf-model", "version": 1, "classes": [{"name": "A"}, {"name": "a"}]}`,
	} {
		e.expect(t, 400, "POST", "/model/import", bad)
	}
	// What is in "meta" is ignored, anywhere; other keys of one's own are refused.
	e.expect(t, 200, "POST", "/model/import", `{"format": "wtf-model", "version": 1, "meta": {"by": "me"},
		"classes": [{"name": "MCU", "meta": {"note": "ok", "tags": [1, 2]}}]}`)
	e.expect(t, 400, "POST", "/model/import", `{"format": "wtf-model", "version": 1, "x-by": "me"}`)

	// The CLI: a file that is there already, then one with a conflict.
	c := e.cli(t)
	out, _ := c.run(0, "", "model", "import", "../../seed/models/mcu.json")
	if !strings.Contains(out, "Nothing new.") || !strings.Contains(out, "Already there: 11 attributes") {
		t.Errorf("wtf model import: %s", out)
	}
	bad := t.TempDir() + "/bad.json"
	if err := os.WriteFile(bad, []byte(`{"format": "wtf-model", "version": 1, "attributes": [{"name": "Clock", "datatype": "text"}]}`), 0o600); err != nil {
		t.Fatal(err)
	}
	out, errOut := c.run(1, "", "model", "import", "--parent", "MCU", bad)
	if !strings.Contains(out, "Attribute Clock: There is an attribute Clock already") || !strings.Contains(errOut, "nothing was imported") {
		t.Errorf("a conflict in the CLI: %s / %s", out, errOut)
	}

	// Model write is needed.
	e.expect(t, 401, "POST", "/model/import", string(mcu), "Cookie", "")

	// Another tenant has none of it, and its own import is its own.
	_, hostname, token := e.otherTenant(t)
	b := at(hostname, token)
	r = e.expect(t, 200, "POST", "/model/import", string(mcu), b...).body
	if get(t, r, "applied") != true || count(r, "attributes", "added") != 11 {
		t.Errorf("the other tenant's import: %v", r)
	}

	// The example in seed/model-format.md imports, into an empty inventory.
	doc, err := os.ReadFile("../../seed/model-format.md")
	if err != nil {
		t.Fatal(err)
	}
	example, _, _ := strings.Cut(strings.SplitN(string(doc), "```json\n", 2)[1], "```")
	_, hostname, token = e.otherTenant(t)
	r = e.expect(t, 200, "POST", "/model/import?dry_run=true", example, at(hostname, token)...).body
	if len(get(t, r, "conflicts").([]any)) != 0 || count(r, "units", "added") != 3 || count(r, "classes", "added") != 3 {
		t.Errorf("the example in model-format.md: %v", r)
	}
}

// TestModelExport checks exporting a class with everything below it: the
// file stands on its own, importing it where it came from changes nothing,
// and importing it into another tenant sets up the same.
func TestModelExport(t *testing.T) {
	e := setup(t)
	e.reset(t)
	t.Cleanup(func() { e.dropTenantUnits(t) })
	mcu, err := os.ReadFile("../../seed/models/mcu.json")
	if err != nil {
		t.Fatal(err)
	}
	e.expect(t, 200, "POST", "/model/import", string(mcu))
	// Units of the tenant's own: a quantity, and a unit in a global family.
	e.expect(t, 200, "POST", "/model/import", `{"format": "wtf-model", "version": 1,
		"quantities": [
			{"name": "Pressure", "base_unit": {"symbol": "Pa", "name": "pascal"}, "families": [
				{"name": "Bar", "units": [{"symbol": "mbar", "name": "millibar", "factor": "100"}, {"symbol": "bar", "name": "bar", "factor": "100000"}]}]},
			{"name": "Length", "base_unit": {"symbol": "m", "name": "metre"}, "families": [
				{"name": "Imperial length", "units": [{"symbol": "hh", "name": "hand", "factor": "0.1016"}]}]}],
		"attributes": [{"name": "Air pressure", "unit": "bar"}, {"name": "Height", "unit": "hh", "unit_lock": true}],
		"classes": [{"name": "MCU", "classes": [{"name": "AVR", "classes": [
			{"name": "Dev boards", "attributes": [{"attribute": "Air pressure", "default": 2.5}, {"attribute": "Height", "per_unit": true}]}]}]}]}`)
	ids := map[string]string{}
	var walk func(nodes any, path string)
	walk = func(nodes any, path string) {
		for _, n := range nodes.([]any) {
			p := path + str(t, n, "name")
			ids[p] = str(t, n, "id")
			walk(get(t, n, "children"), p+"/")
		}
	}
	walk(get(t, e.expect(t, 200, "GET", "/classes", nil).body, "tree"), "")

	x := e.expect(t, 200, "GET", "/classes/"+ids["MCU/AVR"]+"/model", nil).body.(map[string]any)
	if str(t, x, "format") != "wtf-model" || get(t, x, "version") != 1.0 ||
		str(t, x, "meta", "class") != "MCU/AVR" || str(t, x, "meta", "exported_from") == "" {
		t.Errorf("the export's header: %v", x)
	}
	avr := get(t, x, "classes", 0)
	if len(get(t, x, "classes").([]any)) != 1 || str(t, avr, "name") != "AVR" || get(t, avr, "container") != nil {
		t.Fatalf("the exported class: %v", avr)
	}
	// AVR's inherited assignments are its own in the file.
	assignments := map[string]any{}
	for _, a := range get(t, avr, "attributes").([]any) {
		assignments[str(t, a, "attribute")] = a
	}
	if len(assignments) != 11 || get(t, assignments["Core"], "default") != "AVR" ||
		get(t, assignments["Clock"], "required") != true || get(t, assignments["RAM"], "required") != nil {
		t.Errorf("AVR's assignments: %v", get(t, avr, "attributes"))
	}
	boards := get(t, avr, "classes", 0)
	if str(t, boards, "name") != "Dev boards" || len(get(t, boards, "attributes").([]any)) != 2 ||
		get(t, boards, "attributes", 0, "default") != 2.5 || get(t, boards, "attributes", 1, "per_unit") != true {
		t.Errorf("Dev boards, below AVR: %v", boards)
	}
	attributes := map[string]any{}
	for _, a := range get(t, x, "attributes").([]any) {
		attributes[str(t, a, "name")] = a
	}
	if len(attributes) != 13 || str(t, attributes["EEPROM"], "unit") != "B (Binary bytes)" ||
		str(t, attributes["Clock"], "unit") != "MHz" || str(t, attributes["Clock"], "datatype") != "float" ||
		get(t, attributes["Height"], "unit_lock") != true || len(get(t, attributes["Core"], "options").([]any)) != 8 {
		t.Errorf("the exported attributes: %v", get(t, x, "attributes"))
	}
	// Only the units of the tenant's own, with their families.
	quantities := get(t, x, "quantities").([]any)
	if len(quantities) != 2 || str(t, quantities[0], "name") != "Length" || str(t, quantities[1], "name") != "Pressure" ||
		str(t, quantities[0], "base_unit", "symbol") != "m" ||
		len(get(t, quantities[0], "families").([]any)) != 1 || len(get(t, quantities[0], "families", 0, "units").([]any)) != 1 ||
		str(t, quantities[0], "families", 0, "units", 0, "factor") != "0.1016" ||
		len(get(t, quantities[1], "families", 0, "units").([]any)) != 2 {
		t.Errorf("the exported units: %v", quantities)
	}

	// Importing it where it came from changes nothing.
	r := e.expect(t, 200, "POST", "/model/import?parent="+ids["MCU"], x).body
	added := 0
	for _, kind := range []string{"quantities", "families", "units", "attributes", "options", "classes", "assignments"} {
		added += len(get(t, r, kind, "added").([]any))
	}
	if get(t, r, "applied") != true || added != 0 || len(get(t, r, "classes", "existing").([]any)) != 2 {
		t.Errorf("the export imported where it came from: %v", r)
	}

	// Into another tenant: the same is set up, and exports the same.
	_, hostname, token := e.otherTenant(t)
	b := at(hostname, token)
	r = e.expect(t, 200, "POST", "/model/import", x, b...).body
	if get(t, r, "applied") != true || len(get(t, r, "units", "added").([]any)) != 3 ||
		len(get(t, r, "attributes", "added").([]any)) != 13 || len(get(t, r, "classes", "added").([]any)) != 2 {
		t.Fatalf("the export imported into another tenant: %v", r)
	}
	var otherAVR string
	for _, n := range get(t, e.expect(t, 200, "GET", "/classes", nil, b...).body, "tree").([]any) {
		if str(t, n, "name") == "AVR" {
			otherAVR = str(t, n, "id")
		}
	}
	y := e.expect(t, 200, "GET", "/classes/"+otherAVR+"/model", nil, b...).body.(map[string]any)
	delete(x, "meta")
	delete(y, "meta")
	if a, b := must(json.Marshal(x)), must(json.Marshal(y)); !bytes.Equal(a, b) {
		t.Errorf("exported again, the file differs:\n%s\n%s", a, b)
	}

	e.expect(t, 404, "GET", "/classes/"+missing+"/model", nil)
	e.expect(t, 404, "GET", "/classes/"+ids["MCU"]+"/model", nil, b...)
	e.expect(t, 401, "GET", "/classes/"+ids["MCU"]+"/model", nil, "Cookie", "")

	// The CLI: to stdout, in the order of the format, and to a file that
	// imports as nothing new.
	c := e.cli(t)
	out := c.ok("model", "export", "MCU/AVR")
	last := -1
	for _, key := range []string{`"format"`, `"version"`, `"meta"`, `"quantities"`, `"attributes"`, `"classes"`} {
		i := strings.Index(out, key)
		if i < last {
			t.Errorf("%s is out of order in:\n%s", key, out)
		}
		last = i
	}
	path := t.TempDir() + "/avr.json"
	contains(t, c.ok("model", "export", "MCU", "-o", path), "Saved "+path)
	_, errOut := c.run(1, "", "model", "export", "MCU", "-o", path)
	contains(t, errOut, "exists")
	contains(t, c.ok("model", "import", path), "Nothing new.")
}
