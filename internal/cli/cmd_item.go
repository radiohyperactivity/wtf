package cli

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net/http"
	"net/url"
	"slices"
	"strings"

	"github.com/radiohyperactivity/wtf/internal/prompt"
)

func findCommand() command {
	return command{
		name:    "find",
		args:    "<words…> [--class C] [--where CONDITION]… [--limit N] [--all]",
		summary: "Search items by name, class, and text or choice values, and attribute conditions, and show where they are.",
		params:  []param{{name: "Search", complete: completeItems, variadic: true, optional: true}},
		flags:   map[string]param{"class": arg("Class", completeClasses)},
		setup: func(fs *flag.FlagSet) func(*env, []string) error {
			classRef := fs.String("class", "", "only items of this class (and its subclasses)")
			var where stringList
			fs.Var(&where, "where", whereHelp)
			var p paging
			p.register(fs)
			return func(e *env, args []string) error {
				if len(args) == 0 && *classRef == "" && len(where) == 0 {
					if e.term == nil {
						return usagef("give search words, --class or --where")
					}
					v, err := e.ask(param{name: "Search", complete: completeItems}, nil)
					if err != nil {
						return err
					}
					args = []string{v}
				}
				q, err := e.itemQuery(strings.Join(args, " "), *classRef, where)
				if err != nil {
					return err
				}
				return e.list(p, listing{
					path:   "/items",
					query:  q,
					batch:  20, // each item takes a request of its own
					empty:  "Nothing found.",
					render: e.renderFound,
				})
			}
		},
	}
}

// itemQuery is the query of GET /items for search words, a class and
// --where conditions (by the class's attributes, when there is a class).
func (e *env) itemQuery(search, classRef string, where []string) (url.Values, error) {
	q := url.Values{}
	if search != "" {
		q.Set("search", search)
	}
	var c *class
	if classRef != "" {
		id, err := e.resolveClass(classRef)
		if err != nil {
			return nil, err
		}
		q.Set("class", id)
		detail, err := e.classDetail(id)
		if err != nil {
			return nil, err
		}
		c = &detail
	}
	if len(where) > 0 {
		filters, err := parseWhere(where, c)
		if err != nil {
			return nil, err
		}
		q.Set("where", filters)
	}
	return q, nil
}

// renderFound shows each found item with its stock rows.
func (e *env) renderFound(data json.RawMessage, _ bool) ([]string, error) {
	var pg page[itemRow]
	if err := e.decode(data, &pg); err != nil {
		return nil, err
	}
	classes, err := e.classTree()
	if err != nil {
		return nil, err
	}
	locations, err := e.locationTree()
	if err != nil {
		return nil, err
	}
	var lines []string
	for _, r := range pg.Rows {
		var it item
		if err := e.get("/items/"+r.ID, nil, &it); err != nil {
			return nil, err
		}
		lines = append(lines, fmt.Sprintf("%-6s %s  (%s)", r.Code, r.Name, classes.pathString(r.Class)))
		var rows [][]string
		for _, s := range it.Stock {
			rows = append(rows, []string{"      ", s.Code, locations.pathString(s.Location), formatAmount(s.Amount, it.Unit)})
		}
		lines = append(lines, tableLines(nil, rows, false)...)
		if len(it.Stock) == 0 {
			lines = append(lines, "       (no stock)")
		}
	}
	return lines, nil
}

// valueFlags are the flags of commands that set values, besides the
// attributes' own: --value NAME=VALUE for an attribute named like one of
// the command's flags, and --default NAME, for a patch.
func valueFlags(fs *flag.FlagSet, withDefault bool) (*stringList, *stringList) {
	var explicit, defaults stringList
	fs.Var(&explicit, "value", "an attribute's value, NAME=VALUE, for one named like a flag (repeatable)")
	if withDefault {
		fs.Var(&defaults, "default", "give an attribute its class's default, and follow it (repeatable)")
	}
	return &explicit, &defaults
}

func itemGroup() group {
	itemParam := arg("Item", completeItems)
	return group{
		name:    "item",
		summary: "Items (things you own) and their attribute values",
		commands: []command{
			{
				name:    "list",
				args:    "[--class C] [--search WORDS] [--where CONDITION]… [--limit N] [--all]",
				summary: "List items alphabetically.",
				flags:   map[string]param{"class": arg("Class", completeClasses)},
				setup: func(fs *flag.FlagSet) func(*env, []string) error {
					classRef := fs.String("class", "", "only items of this class (and its subclasses)")
					search := fs.String("search", "", "search words")
					var where stringList
					fs.Var(&where, "where", whereHelp)
					var p paging
					p.register(fs)
					return func(e *env, args []string) error {
						if err := wantArgs(args, 0, 0); err != nil {
							return err
						}
						q, err := e.itemQuery(*search, *classRef, where)
						if err != nil {
							return err
						}
						return e.list(p, listing{path: "/items", query: q, render: e.renderItems})
					}
				},
			},
			{
				name:    "get",
				args:    "<item>",
				summary: "Show an item with its values and stock.",
				params:  []param{itemParam},
				setup: simple(func(e *env, args []string) error {
					if err := wantArgs(args, 1, 1); err != nil {
						return err
					}
					id, err := e.resolveItem(args[0])
					if err != nil {
						return err
					}
					return e.showItem(id)
				}),
			},
			{
				name:    "add",
				args:    "<name> --class C [--unit U] [--<attribute> VALUE]… [--edit]",
				summary: "Create an item, with values for its class's attributes (--length 12, --colour red).",
				params:  []param{arg("Name", nil)},
				flags:   map[string]param{"class": arg("Class", completeItemClasses)},
				values:  true,
				setup: func(fs *flag.FlagSet) func(*env, []string) error {
					classRef := fs.String("class", "", "the item's class (required)")
					unit := fs.String("unit", "", "what its stock is counted in, a label such as m or kg (default: pieces)")
					editAfter := fs.Bool("edit", false, "open the new item in the edit form")
					explicit, _ := valueFlags(fs, false)
					return func(e *env, args []string) error {
						if *editAfter {
							if err := e.needTerminal("--edit"); err != nil {
								return err
							}
						}
						if err := wantArgs(args, 1, 1); err != nil {
							return err
						}
						if err := e.need(classRef, "class", arg("Class", completeItemClasses), args); err != nil {
							return err
						}
						classID, err := e.resolveClass(*classRef)
						if err != nil {
							return err
						}
						c, err := e.classDetail(classID)
						if err != nil {
							return err
						}
						set, _, err := e.valueChanges(c, "item", *explicit, nil)
						if err != nil {
							return err
						}
						if *unit == "" {
							if *unit, err = e.offer("Unit (Enter: pieces)", param{}, args); err != nil {
								return err
							}
						}
						if err := e.askValues(c, "item", set); err != nil {
							return err
						}
						data, err := e.do(http.MethodPost, "/items", object{
							"name": args[0], "class": classID, "unit": orNil(*unit), "values": set})
						if err != nil {
							return err
						}
						var created struct {
							ID string `json:"id"`
						}
						if err := e.decode(data, &created); err != nil {
							return err
						}
						if *editAfter {
							return e.editItem(created.ID)
						}
						if err := e.emit(data, func() error { return e.printItemJSON(data) }); err != nil {
							return err
						}
						return e.offerStock(created.ID)
					}
				},
			},
			{
				name:    "set",
				args:    "<item> [--name N] [--class C] [--unit U | --no-unit] [--no-photo] [--<attribute> VALUE] [--no-<attribute>] [--default ATTRIBUTE]…",
				summary: "Change an item's name, class, unit or values, in one change.",
				params:  []param{itemParam},
				flags:   map[string]param{"class": arg("Class", completeItemClasses)},
				values:  true,
				setup: func(fs *flag.FlagSet) func(*env, []string) error {
					var name, classRef, unit optString
					fs.Var(&name, "name", "new name")
					fs.Var(&classRef, "class", "new class; its values must fit it")
					fs.Var(&unit, "unit", "what its stock is counted in, a label")
					noUnit := fs.Bool("no-unit", false, "count its stock in pieces")
					noPhoto := fs.Bool("no-photo", false, "remove its photo")
					explicit, defaults := valueFlags(fs, true)
					return func(e *env, args []string) error {
						if err := wantArgs(args, 1, 1); err != nil {
							return err
						}
						id, err := e.resolveItem(args[0])
						if err != nil {
							return err
						}
						var it item
						if err := e.get("/items/"+id, nil, &it); err != nil {
							return err
						}
						body := object{}
						classID := it.Class.ID
						if name.set {
							body["name"] = name.value
						}
						if classRef.set {
							if classID, err = e.resolveClass(classRef.value); err != nil {
								return err
							}
							body["class"] = classID
						}
						switch {
						case unit.set && *noUnit:
							return usagef("give --unit or --no-unit, not both")
						case unit.set:
							body["unit"] = unit.value
						case *noUnit:
							body["unit"] = nil
						}
						if *noPhoto {
							body["photo"] = nil
						}
						c, err := e.classDetail(classID)
						if err != nil {
							return err
						}
						set, back, err := e.valueChanges(c, "item", *explicit, *defaults)
						if err != nil {
							return err
						}
						if len(set) > 0 {
							body["values"] = set
						}
						if len(back) > 0 {
							body["default"] = back
						}
						if len(body) == 0 {
							return usagef("nothing to change")
						}
						data, err := e.do(http.MethodPatch, "/items/"+id, body)
						if err != nil {
							return err
						}
						return e.emit(data, func() error { return e.printItemJSON(data) })
					}
				},
			},
			editCommand("item", itemParam, resolveItemFn, (*env).editItem),
			deleteCommand("item", "/items/", resolveItemFn),
		},
	}
}

// renderItems formats a page of item_list.
func (e *env) renderItems(data json.RawMessage, header bool) ([]string, error) {
	var pg page[itemRow]
	if err := e.decode(data, &pg); err != nil {
		return nil, err
	}
	classes, err := e.classTree()
	if err != nil {
		return nil, err
	}
	var rows [][]string
	for _, r := range pg.Rows {
		rows = append(rows, []string{r.Code, r.Name, classes.pathString(r.Class), formatTotal(r.Stock, r.Unit)})
	}
	return tableLines([]string{"CODE", "NAME", "CLASS", "STOCK"}, rows, header), nil
}

func (e *env) showItem(id string) error {
	data, err := e.api.Get(e.ctx, "/items/"+id, nil)
	if err != nil {
		return err
	}
	return e.emit(data, func() error { return e.printItemJSON(data) })
}

// photoText is how a photo is shown: the start of its file's hash.
func photoText(hash *string) string {
	if hash == nil {
		return ""
	}
	return "file " + shortHash(*hash)
}

func (e *env) printItemJSON(data json.RawMessage) error {
	var it item
	if err := e.decode(data, &it); err != nil {
		return err
	}
	locations, err := e.locationTree()
	if err != nil {
		return err
	}
	c, err := e.classDetail(it.Class.ID)
	if err != nil {
		return err
	}
	w := e.stdout
	unit := "pieces"
	if it.Unit != nil {
		unit = *it.Unit
	}
	fields(w,
		"Code", it.Code,
		"Name", it.Name,
		"Class", pathNames(it.Class.Path),
		"Unit", unit,
		"Photo", photoText(it.Photo),
		"Id", it.ID)
	if len(it.Values) > 0 {
		fmt.Fprintln(w, "Values:")
		printValues(w, "  ", c, "item", it.Values, it.Defaulted)
	}
	if len(it.Stock) == 0 {
		fmt.Fprintln(w, "Stock: none")
		return nil
	}
	fmt.Fprintln(w, "Stock:")
	for _, s := range it.Stock {
		t := newTable(w)
		t.row("  "+s.Code, locations.pathString(s.Location), formatAmount(s.Amount, it.Unit),
			stockNotes(s.Reference, s.Serial, s.Photo))
		t.flush()
		printValues(w, "      ", c, "stock", s.Values, s.Defaulted)
	}
	return nil
}

// stockNotes are a stock row's reference, serial and photo, for one line.
func stockNotes(reference, serial, photo *string) string {
	var notes []string
	if reference != nil {
		notes = append(notes, "ref "+*reference)
	}
	if serial != nil {
		notes = append(notes, "serial "+*serial)
	}
	if photo != nil {
		notes = append(notes, "photo")
	}
	return strings.Join(notes, ", ")
}

func stockGroup() group {
	show := func(e *env, data json.RawMessage) error { return e.printStockJSON(data) }
	stockParam := arg("Stock", completeStock)
	locationParam := arg("Location", completeStockLocations)
	return group{
		name:    "stock",
		summary: "Stock: how many of an item are where",
		commands: []command{
			{
				name:    "list",
				args:    "[--item I] [--location L] [--search WORDS] [--limit N] [--all]",
				summary: "List stock rows, of an item, at a location (and below it), or by reference or serial.",
				flags: map[string]param{
					"item":     arg("Item", completeItems),
					"location": arg("Location", completeLocations),
				},
				setup: func(fs *flag.FlagSet) func(*env, []string) error {
					itemRef := fs.String("item", "", "only this item's stock")
					locationRef := fs.String("location", "", "only stock at this location, or below it")
					search := fs.String("search", "", "words in the reference or the serial")
					var p paging
					p.register(fs)
					return func(e *env, args []string) error {
						if err := wantArgs(args, 0, 0); err != nil {
							return err
						}
						q := url.Values{}
						if *itemRef != "" {
							id, err := e.resolveItem(*itemRef)
							if err != nil {
								return err
							}
							q.Set("item", id)
						}
						if *locationRef != "" {
							id, err := e.resolveLocation(*locationRef)
							if err != nil {
								return err
							}
							q.Set("location", id)
						}
						if *search != "" {
							q.Set("search", *search)
						}
						return e.list(p, listing{path: "/stock", query: q, render: e.renderStock})
					}
				},
			},
			{
				name:    "get",
				args:    "<stock>",
				summary: "Show a stock row. Stock is named by id, code, ITEM@LOCATION, or an item with one stock row.",
				params:  []param{stockParam},
				setup: simple(func(e *env, args []string) error {
					if err := wantArgs(args, 1, 1); err != nil {
						return err
					}
					id, err := e.resolveStock(args[0])
					if err != nil {
						return err
					}
					data, err := e.api.Get(e.ctx, "/stock/"+id, nil)
					if err != nil {
						return err
					}
					return e.emit(data, func() error { return show(e, data) })
				}),
			},
			{
				name:    "add",
				args:    "<item> <location> [amount] [--reference R] [--serial S] [--<attribute> VALUE]… [--edit]",
				summary: "Put an item at a location. Without an amount it is uncounted.",
				params:  []param{arg("Item", completeItems), locationParam, {name: "Amount", optional: true, variadic: true}},
				values:  true,
				setup: func(fs *flag.FlagSet) func(*env, []string) error {
					reference := fs.String("reference", "", "an order number, an invoice, …")
					serial := fs.String("serial", "", "a serial number")
					editAfter := fs.Bool("edit", false, "open the new stock row in the edit form")
					explicit, _ := valueFlags(fs, false)
					return func(e *env, args []string) error {
						if *editAfter {
							if err := e.needTerminal("--edit"); err != nil {
								return err
							}
						}
						if err := wantArgs(args, 2, -1); err != nil {
							return err
						}
						itemID, err := e.resolveItem(args[0])
						if err != nil {
							return err
						}
						locationID, err := e.resolveLocation(args[1])
						if err != nil {
							return err
						}
						var it item
						if err := e.get("/items/"+itemID, nil, &it); err != nil {
							return err
						}
						amount := strings.Join(args[2:], " ")
						if amount == "" {
							if amount, err = e.offer("Amount (Enter: uncounted)", param{}, args); err != nil {
								return err
							}
						}
						c, err := e.classDetail(it.Class.ID)
						if err != nil {
							return err
						}
						set, _, err := e.valueChanges(c, "stock", *explicit, nil)
						if err != nil {
							return err
						}
						data, err := e.createStock(it, c, locationID, amount, *reference, *serial, set)
						if err != nil {
							return err
						}
						if *editAfter {
							return e.editCreated(data, (*env).editStock)
						}
						return e.emit(data, func() error { return show(e, data) })
					}
				},
			},
			{
				name:    "move",
				args:    "<stock> <location> [amount]",
				summary: "Move a stock row, or part of it, to another location; a part becomes a row of its own.",
				params:  []param{stockParam, locationParam, {name: "Amount", optional: true, variadic: true}},
				setup: simple(func(e *env, args []string) error {
					if err := wantArgs(args, 2, -1); err != nil {
						return err
					}
					stockID, err := e.resolveStock(args[0])
					if err != nil {
						return err
					}
					locationID, err := e.resolveLocation(args[1])
					if err != nil {
						return err
					}
					body := object{"location": locationID, "amount": nil}
					amount := strings.Join(args[2:], " ")
					if amount == "" {
						if amount, err = e.offer("Amount (Enter: all of it)", param{}, args); err != nil {
							return err
						}
					}
					if amount != "" {
						var s stock
						if err := e.get("/stock/"+stockID, nil, &s); err != nil {
							return err
						}
						if body["amount"], err = e.parseAmount(amount, s.Item.Unit); err != nil {
							return err
						}
					}
					data, err := e.do(http.MethodPost, "/stock/"+stockID+"/move", body)
					if err != nil {
						return err
					}
					return e.emit(data, func() error { return show(e, data) })
				}),
			},
			{
				name:    "merge",
				args:    "<stock> <into> [amount] [--keep FIELD=from|into]…",
				summary: "Add a stock row, or part of it, to another row of the same item; where they differ, it asks which to keep. All of it deletes the row.",
				params:  []param{stockParam, stockParam, {name: "Amount", optional: true, variadic: true}},
				setup: func(fs *flag.FlagSet) func(*env, []string) error {
					var keep stringList
					fs.Var(&keep, "keep", "which row's value to keep where they differ: reference=from, serial=into, Colour=from … (repeatable)")
					return func(e *env, args []string) error {
						if err := wantArgs(args, 2, -1); err != nil {
							return err
						}
						stockID, err := e.resolveStock(args[0])
						if err != nil {
							return err
						}
						intoID, err := e.resolveStock(args[1])
						if err != nil {
							return err
						}
						var from, into stock
						if err := e.get("/stock/"+stockID, nil, &from); err != nil {
							return err
						}
						if err := e.get("/stock/"+intoID, nil, &into); err != nil {
							return err
						}
						body := object{"into": intoID, "amount": nil}
						amount := strings.Join(args[2:], " ")
						if amount == "" {
							if amount, err = e.offer("Amount (Enter: all of it)", param{}, args); err != nil {
								return err
							}
						}
						if amount != "" {
							if body["amount"], err = e.parseAmount(amount, from.Item.Unit); err != nil {
								return err
							}
						}
						if body["resolve"], err = e.resolveMerge(from, into, keep); err != nil {
							return err
						}
						data, err := e.do(http.MethodPost, "/stock/"+stockID+"/merge", body)
						if err != nil {
							return err
						}
						return e.emit(data, func() error { return show(e, data) })
					}
				},
			},
			{
				name:    "set",
				args:    "<stock> [--amount A|none] [--location L] [--item I] [--reference R | --no-reference] [--serial S | --no-serial] [--no-photo] [--<attribute> VALUE] [--no-<attribute>] [--default ATTRIBUTE]…",
				summary: "Change a stock row's amount (none: uncounted), location, item, reference, serial or values, in one change.",
				params:  []param{stockParam},
				flags: map[string]param{
					"location": locationParam,
					"item":     arg("Item", completeItems),
				},
				values: true,
				setup: func(fs *flag.FlagSet) func(*env, []string) error {
					var amount, locationRef, itemRef, reference, serial optString
					fs.Var(&amount, "amount", "new amount, or none for uncounted")
					fs.Var(&locationRef, "location", "new location (a correction; see 'stock move')")
					fs.Var(&itemRef, "item", "new item; its class must take the row's values")
					fs.Var(&reference, "reference", "new reference")
					fs.Var(&serial, "serial", "new serial number")
					noReference := fs.Bool("no-reference", false, "remove the reference")
					noSerial := fs.Bool("no-serial", false, "remove the serial number")
					noPhoto := fs.Bool("no-photo", false, "remove its photo")
					explicit, defaults := valueFlags(fs, true)
					return func(e *env, args []string) error {
						if err := wantArgs(args, 1, 1); err != nil {
							return err
						}
						id, err := e.resolveStock(args[0])
						if err != nil {
							return err
						}
						var s stock
						if err := e.get("/stock/"+id, nil, &s); err != nil {
							return err
						}
						body := object{}
						classID, unit := s.Item.Class, s.Item.Unit
						if itemRef.set {
							itemID, err := e.resolveItem(itemRef.value)
							if err != nil {
								return err
							}
							var it item
							if err := e.get("/items/"+itemID, nil, &it); err != nil {
								return err
							}
							body["item"], classID, unit = itemID, it.Class.ID, it.Unit
						}
						if locationRef.set {
							if body["location"], err = e.resolveLocation(locationRef.value); err != nil {
								return err
							}
						}
						if amount.set {
							body["amount"] = nil
							if !isNone(amount.value) {
								if body["amount"], err = e.parseAmount(amount.value, unit); err != nil {
									return err
								}
							}
						}
						for _, f := range []struct {
							key   string
							value optString
							none  bool
						}{{"reference", reference, *noReference}, {"serial", serial, *noSerial}} {
							switch {
							case f.value.set && f.none:
								return usagef("give --%s or --no-%s, not both", f.key, f.key)
							case f.value.set:
								body[f.key] = f.value.value
							case f.none:
								body[f.key] = nil
							}
						}
						if *noPhoto {
							body["photo"] = nil
						}
						c, err := e.classDetail(classID)
						if err != nil {
							return err
						}
						set, back, err := e.valueChanges(c, "stock", *explicit, *defaults)
						if err != nil {
							return err
						}
						if len(set) > 0 {
							body["values"] = set
						}
						if len(back) > 0 {
							body["default"] = back
						}
						if len(body) == 0 {
							return usagef("nothing to change")
						}
						data, err := e.do(http.MethodPatch, "/stock/"+id, body)
						if err != nil {
							return err
						}
						return e.emit(data, func() error { return show(e, data) })
					}
				},
			},
			editCommand("stock", stockParam, resolveStockFn, (*env).editStock),
			deleteCommand("stock", "/stock/", resolveStockFn),
		},
	}
}

// resolveMerge says, for each difference between stock rows from and into,
// which row's to keep, as stock merge's resolve: from --keep FIELD=from|into
// (FIELD a fixed field, reference, serial or photo, or an attribute), and on
// a terminal by asking for the rest. Without a terminal, a difference that
// --keep doesn't settle is an error that lists them all.
func (e *env) resolveMerge(from, into stock, keep []string) (object, error) {
	type difference struct {
		key, label, fromText, intoText string
		value                          bool // a value, not a fixed field
	}
	text := func(s *string) string {
		if s == nil {
			return "(none)"
		}
		return *s
	}
	var diffs []difference
	for _, f := range []struct {
		key  string
		a, b *string
	}{{"reference", from.Reference, into.Reference}, {"serial", from.Serial, into.Serial}, {"photo", from.Photo, into.Photo}} {
		if text(f.a) != text(f.b) {
			a, b := text(f.a), text(f.b)
			if f.key == "photo" {
				a, b = photoText(f.a), photoText(f.b)
			}
			diffs = append(diffs, difference{key: f.key, label: f.key, fromText: a, intoText: b})
		}
	}
	var names []string
	for name := range from.Values {
		names = append(names, name)
	}
	for name := range into.Values {
		if _, ok := from.Values[name]; !ok {
			names = append(names, name)
		}
	}
	slices.Sort(names)
	for _, name := range names {
		a, okA := from.Values[name]
		b, okB := into.Values[name]
		if okA && okB && string(a) == string(b) {
			continue
		}
		show := func(raw json.RawMessage, ok bool) string {
			if !ok {
				return "(none)"
			}
			return formatJSONValue(raw)
		}
		diffs = append(diffs, difference{key: name, label: name, fromText: show(a, okA), intoText: show(b, okB), value: true})
	}

	resolve := object{}
	vals := object{}
	settle := func(d difference, side string) {
		if d.value {
			vals[d.key] = side
		} else {
			resolve[d.key] = side
		}
	}
	given := map[string]string{}
	for _, k := range keep {
		field, side, ok := strings.Cut(k, "=")
		side = strings.ToLower(strings.TrimSpace(side))
		if !ok || (side != "from" && side != "into") {
			return nil, usagef("--keep %q: expected FIELD=from or FIELD=into", k)
		}
		given[normalizeName(field)] = side
	}
	var open []difference
	for _, d := range diffs {
		if side, ok := given[normalizeName(d.key)]; ok {
			settle(d, side)
		} else {
			open = append(open, d)
		}
	}
	if len(open) > 0 && e.term == nil {
		var lines []string
		for _, d := range open {
			lines = append(lines, fmt.Sprintf("%s: %s in %s, %s in %s", d.label, d.fromText, from.Code, d.intoText, into.Code))
		}
		return nil, fmt.Errorf("%s and %s differ:\n  %s\nSay which to keep with --keep FIELD=from or --keep FIELD=into",
			from.Code, into.Code, strings.Join(lines, "\n  "))
	}
	for _, d := range open {
		i, err := e.term.Choose(fmt.Sprintf("%s differs. Keep which? ", d.label), []string{
			fmt.Sprintf("%s (from %s)", d.fromText, from.Code), fmt.Sprintf("%s (in %s)", d.intoText, into.Code)})
		if err != nil {
			return nil, err
		}
		settle(d, map[int]string{0: "from", 1: "into"}[i])
	}
	if len(vals) > 0 {
		resolve["values"] = vals
	}
	return resolve, nil
}

// renderStock formats a page of stock_list.
func (e *env) renderStock(data json.RawMessage, header bool) ([]string, error) {
	var pg page[stock]
	if err := e.decode(data, &pg); err != nil {
		return nil, err
	}
	locations, err := e.locationTree()
	if err != nil {
		return nil, err
	}
	var rows [][]string
	for _, s := range pg.Rows {
		rows = append(rows, []string{s.Code, s.Item.Name, locations.pathString(s.Location),
			formatAmount(s.Amount, s.Item.Unit), stockNotes(s.Reference, s.Serial, nil)})
	}
	return tableLines([]string{"CODE", "ITEM", "LOCATION", "AMOUNT"}, rows, header), nil
}

func (e *env) printStockJSON(data json.RawMessage) error {
	var s stock
	if err := e.decode(data, &s); err != nil {
		return err
	}
	locations, err := e.locationTree()
	if err != nil {
		return err
	}
	c, err := e.classDetail(s.Item.Class)
	if err != nil {
		return err
	}
	w := e.stdout
	reference, serial := "", ""
	if s.Reference != nil {
		reference = *s.Reference
	}
	if s.Serial != nil {
		serial = *s.Serial
	}
	fields(w,
		"Code", s.Code,
		"Item", s.Item.Code+"  "+s.Item.Name,
		"Location", locations.pathString(s.Location),
		"Amount", formatAmount(s.Amount, s.Item.Unit),
		"Reference", reference,
		"Serial", serial,
		"Photo", photoText(s.Photo),
		"Id", s.ID)
	if len(s.Values) > 0 {
		fmt.Fprintln(w, "Values:")
		printValues(w, "  ", c, "stock", s.Values, s.Defaulted)
	}
	return nil
}

// createStock puts item it, of class c, at a location: amount as typed (""
// for uncounted), with a reference, a serial and values as given, and on a
// terminal the stock values it still needs (all of them in an interactive
// session).
func (e *env) createStock(it item, c class, locationID, amount, reference, serial string, set object) (json.RawMessage, error) {
	body := object{"item": it.ID, "location": locationID, "amount": nil,
		"reference": orNil(reference), "serial": orNil(serial)}
	if amount != "" {
		q, err := e.parseAmount(amount, it.Unit)
		if err != nil {
			return nil, err
		}
		body["amount"] = q
	}
	if set == nil {
		set = object{}
	}
	if err := e.askValues(c, "stock", set); err != nil {
		return nil, err
	}
	body["values"] = set
	return e.do(http.MethodPost, "/stock", body)
}

// offerStock asks once, after an item was created, whether to put it
// somewhere right away, and adds that one stock row. It asks only on a
// terminal, and not with --json, which prints just the item.
func (e *env) offerStock(itemID string) error {
	if e.term == nil || e.json {
		return nil
	}
	var it item
	if err := e.get("/items/"+itemID, nil, &it); err != nil {
		return err
	}
	answer, err := e.term.ReadLine("Add stock for "+it.Name+"? [y/N] ", "", nil)
	if err != nil {
		return err
	}
	if a := strings.ToLower(strings.TrimSpace(answer)); a != "y" && a != "yes" {
		return nil
	}
	e.prompted = true // optional stock values are offered too
	where, err := e.ask(arg("Location", completeStockLocations), nil)
	if err != nil {
		return err
	}
	amount, err := e.offer("Amount (Enter: uncounted)", param{}, nil)
	if err != nil {
		return err
	}
	locationID, err := e.resolveLocation(where)
	var data json.RawMessage
	if err == nil {
		var c class
		if c, err = e.classDetail(it.Class.ID); err == nil {
			data, err = e.createStock(it, c, locationID, amount, "", "", nil)
		}
	}
	if err != nil {
		if errors.Is(err, prompt.ErrInterrupted) {
			return err
		}
		return fmt.Errorf("%s was created, but its stock wasn't: %w", it.Name, err)
	}
	return e.printStockJSON(data)
}
