package integration

// Tests of attributes in JSON (2026-11-02-attributes-in-json.md), on the
// functions the API calls: a class's attributes and what it inherits, the
// values of items and stock rows, and what a change of a class does to
// them.

import (
	"encoding/json"
	"fmt"
	"reflect"
	"strings"
	"testing"
)

// js is v as JSON text, for a jsonb argument.
func js(v any) string {
	b, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return string(b)
}

// sameJSON fails the test unless got, decoded JSON, is want once both are
// encoded and decoded again (so that numbers and maps compare as values).
func sameJSON(t *testing.T, what string, got, want any) {
	t.Helper()
	var g, w any
	_ = json.Unmarshal([]byte(js(got)), &g)
	_ = json.Unmarshal([]byte(js(want)), &w)
	if !reflect.DeepEqual(g, w) {
		t.Fatalf("%s: got %s, want %s", what, js(got), js(want))
	}
}

// attributeNames is the names of a class's attributes, as class.get lists
// them, in that order.
func attributeNames(t *testing.T, class any) []string {
	t.Helper()
	var names []string
	for _, a := range get(t, class, "attributes").([]any) {
		names = append(names, str(t, a, "name"))
	}
	return names
}

// addAttribute adds an attribute to a class, and returns the class's
// answer.
func addAttribute(t *testing.T, c caller, class, name string, def map[string]any) any {
	t.Helper()
	return c.must(t, "class.attribute_add", class, name, js(def), false)
}

func TestAttributes(t *testing.T) {
	at := newAccessors(t, "attributes")
	admin, user := at.admin, at.user

	tools := admin.id(t, "class.create", "Tools", nil, false)
	drills := admin.id(t, "class.create", "Drills", tools, false)
	addAttribute(t, admin, tools, "Length", obj("scope", "item", "type", "decimal", "unit", "mm"))
	addAttribute(t, admin, tools, "Colour", obj("scope", "item", "type", "choice",
		"choices", []string{"Red", "Green", "Blue"}, "default", "Red"))
	addAttribute(t, admin, tools, "Bought", obj("scope", "stock", "type", "date"))
	addAttribute(t, admin, drills, "Manual", obj("scope", "item", "type", "attachment", "media", []string{"application/pdf"}))

	t.Run("inherited", func(t *testing.T) {
		d := admin.must(t, "class.get", drills)
		if got := strings.Join(attributeNames(t, d), ","); got != "Length,Colour,Manual,Bought" {
			t.Fatalf("attributes of Drills: %s", got)
		}
		for _, a := range get(t, d, "attributes").([]any) {
			if want := str(t, a, "name") != "Manual"; get(t, a, "inherited") != want {
				t.Fatalf("%s inherited: %v", str(t, a, "name"), get(t, a, "inherited"))
			}
		}
		// A class made below it inherits them all.
		cordless := admin.must(t, "class.create", "Cordless", drills, false)
		if got := len(attributeNames(t, cordless)); got != 4 {
			t.Fatalf("Cordless has %d attributes", got)
		}
	})

	t.Run("names", func(t *testing.T) {
		_, err := admin.call(t, "class.attribute_add", drills, "Length", js(obj("scope", "item", "type", "text")), false)
		wantState(t, err, "23505", `has an attribute "Length" already`)
		_, err = admin.call(t, "class.attribute_add", tools, "Manual", js(obj("scope", "item", "type", "text")), false)
		wantState(t, err, "23514", `has an attribute "Manual" of its own, and would also inherit one`)
		_, err = admin.call(t, "class.attribute_change", drills, "Length", js(obj("unit", "cm")), false)
		wantState(t, err, "23514", "inherits")
		_, err = admin.call(t, "class.attribute_change", tools, "Length", js(obj("type", "integer")), false)
		wantState(t, err, "23514", "can't change")
		_, err = admin.call(t, "class.attribute_add", tools, "Bad", js(obj("scope", "item", "type", "choice")), false)
		wantState(t, err, "22023", "needs its choices")
		_, err = admin.call(t, "class.attribute_add", tools, "Bad", js(obj("scope", "item", "type", "integer", "default", 1.5)), false)
		wantState(t, err, "22023", "a whole number")
	})

	var drill string
	t.Run("values", func(t *testing.T) {
		v := user.must(t, "item.create", drills, "Drill", nil, js(obj("Length", 120)))
		drill = str(t, v, "id")
		sameJSON(t, "values", get(t, v, "values"), obj("Length", 120, "Colour", "Red"))
		sameJSON(t, "defaulted", get(t, v, "defaulted"), []string{"Colour"})

		_, err := user.call(t, "item.create", drills, "Bad", nil, js(obj("Length", "long")))
		wantState(t, err, "23514", `"Length" that isn't a number`)
		_, err = user.call(t, "item.create", drills, "Bad", nil, js(obj("Weight", 1)))
		wantState(t, err, "23514", `"Weight", which isn't one of its class's item attributes`)
		_, err = user.call(t, "item.create", drills, "Bad", nil, js(obj("Bought", "2026-01-01")))
		wantState(t, err, "23514", "isn't one of its class's item attributes")
		_, err = user.call(t, "item.create", drills, "Bad", nil, js(obj("Manual", strings.Repeat("a", 64))))
		wantState(t, err, "22023", "is a file: upload it")
		_, err = user.call(t, "item.create", drills, "Bad", nil, js(obj("Colour", "Pink")))
		wantState(t, err, "23514", "one of Red, Green, Blue")

		v = user.must(t, "item.patch", drill, js(obj("values", obj("Colour", "Green"))))
		sameJSON(t, "defaulted after set", get(t, v, "defaulted"), []string{})
		v = user.must(t, "item.patch", drill, js(obj("default", []string{"Colour"})))
		sameJSON(t, "back to the default", get(t, v, "values", "Colour"), "Red")
		sameJSON(t, "following again", get(t, v, "defaulted"), []string{"Colour"})
		v = user.must(t, "item.patch", drill, js(obj("values", obj("Length", nil))))
		if _, ok := get(t, v, "values").(map[string]any)["Length"]; ok {
			t.Fatal("Length still there after removing it")
		}
		// Several changes at once, checked together: a bad one stops all.
		_, err = user.call(t, "item.patch", drill, js(obj("name", "Big drill", "values", obj("Length", 120, "Colour", "Pink"))))
		wantState(t, err, "23514", "one of Red, Green, Blue")
		if str(t, user.must(t, "item.get", drill), "name") != "Drill" {
			t.Fatal("the name changed with a refused patch")
		}
		user.must(t, "item.patch", drill, js(obj("values", obj("Length", 120))))
		_, err = admin.call(t, "class.attribute_add", tools, "Serial", js(obj("scope", "item", "type", "text")), false)
		wantState(t, err, "22023", "fixed field")
	})

	t.Run("a changed default", func(t *testing.T) {
		own := user.id(t, "item.create", drills, "Green drill", nil, js(obj("Colour", "Green")))
		r := admin.must(t, "class.attribute_change", tools, "Colour", js(obj("default", "Blue")), true)
		if get(t, r, "dry_run") != true || num(t, r, "items") != 1 {
			t.Fatalf("dry run: %v", r)
		}
		sameJSON(t, "after the dry run", get(t, user.must(t, "item.get", drill), "values", "Colour"), "Red")
		r = admin.must(t, "class.attribute_change", tools, "Colour", js(obj("default", "Blue")), false)
		if num(t, r, "items") != 1 {
			t.Fatalf("change: %v", r)
		}
		sameJSON(t, "follows", get(t, user.must(t, "item.get", drill), "values", "Colour"), "Blue")
		sameJSON(t, "its own", get(t, user.must(t, "item.get", own), "values", "Colour"), "Green")
	})

	t.Run("required", func(t *testing.T) {
		_, err := admin.call(t, "class.attribute_add", tools, "Brand", js(obj("scope", "item", "type", "text", "required", true)), false)
		wantState(t, err, "23514", `needs a value for "Brand", which is required`)
		r := admin.must(t, "class.attribute_add", tools, "Brand", js(obj("scope", "item", "type", "text",
			"required", true, "default", "Acme")), false)
		if num(t, r, "items") != 2 {
			t.Fatalf("required with a default: %v", r)
		}
		v := user.must(t, "item.get", drill)
		sameJSON(t, "Brand", get(t, v, "values", "Brand"), "Acme")
		// Removing a required value with a default gives the default back.
		user.must(t, "item.patch", drill, js(obj("values", obj("Brand", "Bosch"))))
		v = user.must(t, "item.patch", drill, js(obj("values", obj("Brand", nil))))
		sameJSON(t, "Brand back", get(t, v, "values", "Brand"), "Acme")
	})

	t.Run("renames and removals", func(t *testing.T) {
		r := admin.must(t, "class.attribute_rename", tools, "Brand", "Make", false)
		if num(t, r, "items") != 2 {
			t.Fatalf("rename: %v", r)
		}
		v := user.must(t, "item.get", drill)
		sameJSON(t, "Make", get(t, v, "values", "Make"), "Acme")
		sameJSON(t, "defaulted", get(t, v, "defaulted"), []string{"Colour", "Make"})

		admin.must(t, "class.choice_rename", tools, "Colour", "Blue", "Navy", false)
		sameJSON(t, "renamed choice", get(t, user.must(t, "item.get", drill), "values", "Colour"), "Navy")
		_, err := admin.call(t, "class.choice_remove", tools, "Colour", "Green", false)
		wantState(t, err, "23001", "1 item(s)")
		_, err = admin.call(t, "class.choice_remove", tools, "Colour", "Navy", false)
		wantState(t, err, "23001", "is the default")
		admin.must(t, "class.choice_add", tools, "Colour", "Yellow", false)
		admin.must(t, "class.choice_remove", tools, "Colour", "Yellow", false)

		r = admin.must(t, "class.attribute_remove", tools, "Make", false)
		if num(t, r, "items") != 2 {
			t.Fatalf("remove: %v", r)
		}
		v = user.must(t, "item.get", drill)
		if _, ok := get(t, v, "values").(map[string]any)["Make"]; ok {
			t.Fatal("Make still there")
		}
	})

	t.Run("moving a class", func(t *testing.T) {
		other := admin.id(t, "class.create", "Other", nil, false)
		_, err := admin.call(t, "class.patch", drills, js(obj("parent", other)))
		wantState(t, err, "23514", "item(s) wouldn't fit")
		_, err = admin.call(t, "class.patch", tools, js(obj("parent", drills)))
		wantState(t, err, "23514", "can't be moved below itself")
		// Moving an item to a class without its attributes is refused too.
		_, err = user.call(t, "item.patch", drill, js(obj("class", other)))
		wantState(t, err, "23514", "isn't one of its class's item attributes")
	})

	t.Run("search", func(t *testing.T) {
		page := at.viewer.must(t, "item.list", nil, "rill", nil, 100, nil)
		if got := len(get(t, page, "rows").([]any)); got != 2 {
			t.Fatalf("search rill: %d rows", got)
		}
		page = at.viewer.must(t, "item.list", nil, "tools navy", nil, 100, nil)
		if got := len(get(t, page, "rows").([]any)); got != 1 {
			t.Fatalf("search tools navy: %d rows", got)
		}
	})
}

func TestItemListPagesAndFilters(t *testing.T) {
	at := newAccessors(t, "itemlist")
	admin, user, viewer := at.admin, at.user, at.viewer
	parts := admin.id(t, "class.create", "Parts", nil, false)
	addAttribute(t, admin, parts, "Size", obj("scope", "item", "type", "integer"))
	addAttribute(t, admin, parts, "Kind", obj("scope", "item", "type", "choice", "choices", []string{"Bolt", "Nut"}))
	addAttribute(t, admin, parts, "Made", obj("scope", "item", "type", "date"))
	addAttribute(t, admin, parts, "Lot", obj("scope", "stock", "type", "text"))
	shelf := admin.id(t, "location.create", "Shelf", nil, false, nil, nil, nil)
	for i := 1; i <= 25; i++ {
		kind := "Bolt"
		if i%2 == 0 {
			kind = "Nut"
		}
		item := user.id(t, "item.create", parts, fmt.Sprintf("Part %d", i), nil,
			js(obj("Size", i, "Kind", kind, "Made", fmt.Sprintf("2026-01-%02d", i))))
		if i == 7 {
			user.must(t, "stock.create", item, shelf, 1, nil, nil, js(obj("Lot", "L-77")))
		}
	}
	// Two of the same name, which paging keeps apart by id.
	user.must(t, "item.create", parts, "Part 10", nil, js(obj()))

	names := func(page any) []string {
		var n []string
		for _, r := range get(t, page, "rows").([]any) {
			n = append(n, str(t, r, "name"))
		}
		return n
	}
	t.Run("pages", func(t *testing.T) {
		var all []string
		var after any
		for pages := 0; ; pages++ {
			page := viewer.must(t, "item.list", nil, nil, nil, 10, after)
			all = append(all, names(page)...)
			if get(t, page, "more") != true {
				if pages != 2 {
					t.Fatalf("%d pages", pages+1)
				}
				break
			}
			after = str(t, page, "next")
		}
		if len(all) != 26 || all[0] != "Part 1" || all[1] != "Part 2" || all[9] != "Part 10" || all[10] != "Part 10" || all[25] != "Part 25" {
			t.Fatalf("items in order: %v", all)
		}
	})
	t.Run("filters", func(t *testing.T) {
		count := func(where any) int {
			return len(get(t, viewer.must(t, "item.list", nil, nil, js(where), 100, nil), "rows").([]any))
		}
		if n := count([]any{obj("attribute", "Size", "op", ">", "value", 20)}); n != 5 {
			t.Fatalf("Size > 20: %d", n)
		}
		if n := count([]any{obj("attribute", "Size", "op", "between", "value", []int{3, 6}),
			obj("attribute", "Kind", "op", "=", "value", "nut")}); n != 2 {
			t.Fatalf("Size 3-6, Nut: %d", n)
		}
		if n := count([]any{obj("attribute", "Kind", "op", "in", "value", []string{"Bolt", "nut"})}); n != 25 {
			t.Fatalf("Kind in: %d", n)
		}
		if n := count([]any{obj("attribute", "Made", "op", "<", "value", "2026-01-04")}); n != 3 {
			t.Fatalf("Made before: %d", n)
		}
		if n := count([]any{obj("attribute", "Lot", "op", "contains", "value", "l-7")}); n != 1 {
			t.Fatalf("Lot, on stock: %d", n)
		}
		_, err := viewer.call(t, "item.list", nil, nil, js([]any{obj("attribute", "Size", "op", "~", "value", 1)}), 100, nil)
		wantState(t, err, "22023", "can't compare")
	})
}

func TestStockValuesAndMerge(t *testing.T) {
	at := newAccessors(t, "stockvalues")
	admin, user := at.admin, at.user
	cables := admin.id(t, "class.create", "Cables", nil, false)
	addAttribute(t, admin, cables, "Colour", obj("scope", "stock", "type", "text", "default", "Black"))
	shelf := admin.id(t, "location.create", "Shelf", nil, false, nil, nil, nil)
	box := admin.id(t, "location.create", "Box", nil, false, nil, nil, nil)
	cable := user.id(t, "item.create", cables, "Cable", "m", js(obj()))
	pieces := user.id(t, "item.create", cables, "Plug", nil, js(obj()))

	a := user.must(t, "stock.create", cable, shelf, 12.5, "PO-1", nil, js(obj()))
	sameJSON(t, "default on stock", get(t, a, "values"), obj("Colour", "Black"))
	_, err := user.call(t, "stock.create", pieces, shelf, 1.5, nil, nil, js(obj()))
	wantState(t, err, "23514", "counted in pieces")

	split := user.must(t, "stock.move", str(t, a, "id"), box, 2.5)
	if str(t, split, "reference") != "PO-1" || num(t, split, "amount") != 2.5 {
		t.Fatalf("split: %v", split)
	}
	b := user.must(t, "stock.create", cable, box, 1, "PO-2", "SN-9", js(obj("Colour", "Red")))

	_, err = user.call(t, "stock.merge", str(t, b, "id"), str(t, split, "id"), nil, nil)
	wantState(t, err, "23514", "differ in reference, serial, values.Colour")
	r := user.must(t, "stock.merge", str(t, b, "id"), str(t, split, "id"), nil,
		js(obj("reference", "into", "serial", "from", "values", obj("Colour", "from"))))
	if num(t, r, "amount") != 3.5 || str(t, r, "serial") != "SN-9" || str(t, r, "reference") != "PO-1" {
		t.Fatalf("merged: %v", r)
	}
	sameJSON(t, "merged values", get(t, r, "values"), obj("Colour", "Red"))
	if _, err := user.call(t, "stock.get", str(t, b, "id")); sqlState(err) != "P0002" {
		t.Fatalf("merged row still there: %v", err)
	}

	page := at.viewer.must(t, "stock.list", nil, nil, "sn-9", 100, nil)
	if len(get(t, page, "rows").([]any)) != 1 {
		t.Fatalf("stock search: %v", page)
	}
}

func TestFilesAndModels(t *testing.T) {
	at := newAccessors(t, "filesmodels")
	admin, user := at.admin, at.user
	tools := admin.id(t, "class.create", "Tools", nil, false)
	addAttribute(t, admin, tools, "Manual", obj("scope", "item", "type", "attachment", "media", []string{"application/pdf"}))
	addAttribute(t, admin, tools, "Volts", obj("scope", "item", "type", "decimal", "unit", "V", "required", true, "default", 18))
	drill := user.id(t, "item.create", tools, "Drill", nil, js(obj()))
	hash := strings.Repeat("ab", 32)

	t.Run("files", func(t *testing.T) {
		v := user.must(t, "attachment.set", "item", drill, nil, hash, "image/png")
		if str(t, v, "photo") != hash {
			t.Fatalf("photo: %v", v)
		}
		_, err := user.call(t, "attachment.set", "item", drill, nil, hash, "application/pdf")
		wantState(t, err, "22023", "must be an image")
		_, err = user.call(t, "attachment.set", "item", drill, "Manual", hash, "image/png")
		wantState(t, err, "23514", "takes application/pdf")
		v = user.must(t, "attachment.set", "item", drill, "Manual", hash, "application/pdf")
		sameJSON(t, "manual", get(t, v, "values", "Manual"), hash)
		f := at.viewer.must(t, "attachment.get", "item", drill, "Manual")
		if str(t, f, "hash") != hash || str(t, f, "name") != "Manual" {
			t.Fatalf("file: %v", f)
		}
		_, err = at.viewer.call(t, "attachment.get", "item", drill, "Volts")
		wantState(t, err, "P0002", "")
		user.must(t, "item.patch", drill, js(obj("photo", nil)))
		_, err = at.viewer.call(t, "attachment.get", "item", drill, nil)
		wantState(t, err, "P0002", "")
	})

	t.Run("models", func(t *testing.T) {
		admin.must(t, "class.create", "Cordless", tools, false)
		file := admin.must(t, "model.export", tools)
		// Into a class that has it all already: nothing is added.
		r := admin.must(t, "model.import", js(file), nil, false)
		if num(t, r, "classes", "existing") != 2 || num(t, r, "attributes", "existing") != 2 {
			t.Fatalf("import where it is: %v", r)
		}
		// Below another class: all of it is new.
		elsewhere := admin.id(t, "class.create", "Elsewhere", nil, false)
		r = admin.must(t, "model.import", js(file), elsewhere, true)
		if get(t, r, "dry_run") != true || num(t, r, "classes", "added") != 2 {
			t.Fatalf("dry run: %v", r)
		}
		r = admin.must(t, "model.import", js(file), elsewhere, false)
		if num(t, r, "classes", "added") != 2 || num(t, r, "attributes", "added") != 2 {
			t.Fatalf("import: %v", r)
		}
		var copied string
		for _, n := range get(t, admin.must(t, "class.list", nil), "nodes").([]any) {
			if str(t, n, "name") == "Tools" && get(t, n, "parent") == elsewhere {
				copied = str(t, n, "id")
			}
		}
		sameJSON(t, "the same model", admin.must(t, "model.export", copied), file)
	})

	t.Run("codes", func(t *testing.T) {
		code := str(t, user.must(t, "item.get", drill), "code")
		r := at.viewer.must(t, "code.resolve", code)
		if str(t, r, "type") != "item" || str(t, r, "object", "id") != drill {
			t.Fatalf("resolve: %v", r)
		}
	})
}
