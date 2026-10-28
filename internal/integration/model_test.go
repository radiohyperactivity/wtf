package integration

import (
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
	more := `{"format": "wtf-model", "version": 1,
		"attributes": [{"name": "Package", "datatype": "choice", "options": ["DIP", "PLCC"]}],
		"classes": [{"name": "MCU", "classes": [
			{"name": "PIC", "attributes": [{"attribute": "Clock", "default": 20}, {"attribute": "Package"}]}]}]}`
	r = e.expect(t, 200, "POST", "/model/import", more).body
	if get(t, r, "applied") != true || count(r, "options", "added") != 1 || count(r, "classes", "added") != 1 ||
		count(r, "classes", "existing") != 1 || count(r, "assignments", "added") != 2 {
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
	// Keys of one's own are ignored.
	e.expect(t, 200, "POST", "/model/import", `{"format": "wtf-model", "version": 1, "x-by": "me", "classes": [{"name": "MCU", "x-note": "ok"}]}`)

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
}
