package cli

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net/http"
	"net/url"
	"strings"

	"github.com/radiohyperactivity/wtf/internal/prompt"
)

func findCommand() command {
	return command{
		name:    "find",
		args:    "<words…> [--class C] [--limit N] [--offset N]",
		summary: "Search items by name, class, and text or choice values, and show where they are.",
		params:  []param{{name: "Search", complete: completeItems, variadic: true, optional: true}},
		flags:   map[string]param{"class": arg("Class", completeClasses)},
		setup: func(fs *flag.FlagSet) func(*env, []string) error {
			classRef := fs.String("class", "", "only items of this class (and its subclasses)")
			var p paging
			p.register(fs)
			return func(e *env, args []string) error {
				if len(args) == 0 && *classRef == "" {
					if e.term == nil {
						return usagef("give search words or --class")
					}
					v, err := e.ask(param{name: "Search", complete: completeItems}, nil)
					if err != nil {
						return err
					}
					args = []string{v}
				}
				q := url.Values{}
				if len(args) > 0 {
					q.Set("search", strings.Join(args, " "))
				}
				if *classRef != "" {
					id, err := e.resolveClass(*classRef)
					if err != nil {
						return err
					}
					q.Set("class", id)
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

// renderFound shows each found item with its stock rows.
func (e *env) renderFound(data json.RawMessage, _ bool) ([]string, error) {
	var pg page[itemRow]
	if err := decode(data, &pg); err != nil {
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
			rows = append(rows, []string{"      ", s.Code, locations.pathString(s.Location), formatQuantity(s.Quantity, s.Display)})
		}
		lines = append(lines, tableLines(nil, rows, false)...)
		if len(it.Stock) == 0 {
			lines = append(lines, "       (no stock)")
		}
	}
	return lines, nil
}

func itemGroup() group {
	itemParam := arg("Item", completeItems)
	attributeParam := arg("Attribute", completeAttributes)
	return group{
		name:    "item",
		summary: "Items (things you own) and their attribute values",
		commands: []command{
			{
				name:    "list",
				args:    "[--class C] [--search WORDS] [--limit N] [--offset N]",
				summary: "List items alphabetically.",
				flags:   map[string]param{"class": arg("Class", completeClasses)},
				setup: func(fs *flag.FlagSet) func(*env, []string) error {
					classRef := fs.String("class", "", "only items of this class (and its subclasses)")
					search := fs.String("search", "", "search words")
					var p paging
					p.register(fs)
					return func(e *env, args []string) error {
						if err := wantArgs(args, 0, 0); err != nil {
							return err
						}
						q := url.Values{}
						if *search != "" {
							q.Set("search", *search)
						}
						if *classRef != "" {
							id, err := e.resolveClass(*classRef)
							if err != nil {
								return err
							}
							q.Set("class", id)
						}
						return e.list(p, listing{path: "/items", query: q, render: e.renderItems})
					}
				},
			},
			{
				name:    "get",
				args:    "<item>",
				summary: "Show an item with its values, stock and attachments.",
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
				args:    "<name> --class C [--unit-group G] [--value ATTRIBUTE=VALUE]… [--edit]",
				summary: "Create an item. Values may carry units (--value Length=12mm).",
				params:  []param{arg("Name", nil)},
				flags: map[string]param{
					"class":      arg("Class", completeItemClasses),
					"unit-group": arg("Unit group", completeUnitGroups),
					"value":      arg("Value", completeAssignment),
				},
				setup: func(fs *flag.FlagSet) func(*env, []string) error {
					classRef := fs.String("class", "", "the item's class (required)")
					group := fs.String("unit-group", "", "unit group of its stock quantities (default: counted in pieces)")
					editAfter := fs.Bool("edit", false, "open the new item in the edit form")
					var values stringList
					fs.Var(&values, "value", "an attribute value, ATTRIBUTE=VALUE (repeatable)")
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
						body := object{"name": args[0]}
						classID, err := e.resolveClass(*classRef)
						if err != nil {
							return err
						}
						body["class"] = classID
						if *group == "" {
							if *group, err = e.offer("Unit group (Enter: counted in pieces)", arg("", completeUnitGroups), args); err != nil {
								return err
							}
						}
						if *group != "" {
							if body["unit_group"], err = e.resolveUnitGroup(*group); err != nil {
								return err
							}
						}
						v, err := e.parseValues(values)
						if err != nil {
							return err
						}
						if v == nil {
							v = object{}
						}
						if err := e.askValues(classID, false, v); err != nil {
							return err
						}
						if len(v) > 0 {
							body["values"] = v
						}
						data, err := e.do(http.MethodPost, "/items", body)
						if err != nil {
							return err
						}
						var created struct {
							ID string `json:"id"`
						}
						if err := decode(data, &created); err != nil {
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
				args:    "<item> [--name N] [--class C] [--unit-group G|none]",
				summary: "Change an item's name, class or unit group.",
				params:  []param{itemParam},
				flags: map[string]param{
					"class":      arg("Class", completeItemClasses),
					"unit-group": arg("Unit group", completeUnitGroups),
				},
				setup: func(fs *flag.FlagSet) func(*env, []string) error {
					var name, classRef, group optString
					fs.Var(&name, "name", "new name")
					fs.Var(&classRef, "class", "new class")
					fs.Var(&group, "unit-group", "new unit group, or none")
					return func(e *env, args []string) error {
						if err := wantArgs(args, 1, 1); err != nil {
							return err
						}
						id, err := e.resolveItem(args[0])
						if err != nil {
							return err
						}
						body := object{}
						if name.set {
							body["name"] = name.value
						}
						if classRef.set {
							if body["class"], err = e.resolveClass(classRef.value); err != nil {
								return err
							}
						}
						if group.set {
							body["unit_group"] = nil
							if !isNone(group.value) {
								if body["unit_group"], err = e.resolveUnitGroup(group.value); err != nil {
									return err
								}
							}
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
			restoreCommand(restoreKind{kind: "item", prefix: "/items/", codeType: "item", place: "class", placeKind: "class", named: true,
				show: func(e *env, data json.RawMessage) error { return e.printItemJSON(data) }}),
			historyCommand("item", "/items/", "", resolveItemFn),
			valueSetCommand("item", "/items/", itemParam, attributeParam, resolveItemFn, func(e *env, data json.RawMessage) error { return e.printItemJSON(data) }),
			valueDeleteCommand("item", "/items/", itemParam, attributeParam, resolveItemFn, func(e *env, data json.RawMessage) error { return e.printItemJSON(data) }),
		},
	}
}

// renderItems formats a page of item_list.
func (e *env) renderItems(data json.RawMessage, header bool) ([]string, error) {
	var pg page[itemRow]
	if err := decode(data, &pg); err != nil {
		return nil, err
	}
	classes, err := e.classTree()
	if err != nil {
		return nil, err
	}
	var rows [][]string
	for _, r := range pg.Rows {
		note := ""
		if r.Incomplete {
			note = "incomplete"
		}
		rows = append(rows, []string{r.Code, r.Name, classes.pathString(r.Class), formatTotal(r.Stock), note})
	}
	return tableLines([]string{"CODE", "NAME", "CLASS", "STOCK"}, rows, header), nil
}

// valueSetCommand sets one attribute value of an item or stock row.
func valueSetCommand(kind, prefix string, owner, attr param, resolve func(*env, string) (string, error), show func(*env, json.RawMessage) error) command {
	return command{
		name:    "value-set",
		args:    "<" + kind + "> <attribute> <value…>",
		summary: "Set an attribute value, e.g. 'Length 12 mm' or 'Colour red'.",
		params:  []param{owner, attr, rest("Value", completeValueOf(1))},
		setup: simple(func(e *env, args []string) error {
			if err := wantArgs(args, 3, -1); err != nil {
				return err
			}
			id, err := resolve(e, args[0])
			if err != nil {
				return err
			}
			a, err := e.resolveAttribute(args[1])
			if err != nil {
				return err
			}
			v, err := e.parseValue(a, strings.Join(args[2:], " "))
			if err != nil {
				return err
			}
			data, err := e.do(http.MethodPut, prefix+id+"/values/"+a.ID, object{"value": v})
			if err != nil {
				return err
			}
			return e.emit(data, func() error { return show(e, data) })
		}),
	}
}

// valueDeleteCommand removes an attribute value of an item or stock row.
func valueDeleteCommand(kind, prefix string, owner, attr param, resolve func(*env, string) (string, error), show func(*env, json.RawMessage) error) command {
	return command{
		name:    "value-delete",
		args:    "<" + kind + "> <attribute>",
		summary: "Remove an attribute value (the class default, if any, shows again).",
		params:  []param{owner, attr},
		setup: simple(func(e *env, args []string) error {
			if err := wantArgs(args, 2, 2); err != nil {
				return err
			}
			id, err := resolve(e, args[0])
			if err != nil {
				return err
			}
			a, err := e.resolveAttribute(args[1])
			if err != nil {
				return err
			}
			data, err := e.do(http.MethodDelete, prefix+id+"/values/"+a.ID, nil)
			if err != nil {
				return err
			}
			return e.emit(data, func() error { return show(e, data) })
		}),
	}
}

func (e *env) showItem(id string) error {
	data, err := e.api.Get(e.ctx, "/items/"+id, nil)
	if err != nil {
		return err
	}
	return e.emit(data, func() error { return e.printItemJSON(data) })
}

func (e *env) printItemJSON(data json.RawMessage) error {
	var it item
	if err := decode(data, &it); err != nil {
		return err
	}
	locations, err := e.locationTree()
	if err != nil {
		return err
	}
	w := e.stdout
	photo := ""
	if it.Photo != nil {
		photo = it.Photo.FileName + " (" + it.Photo.ID + ")"
	}
	fields(w,
		"Code", it.Code,
		"Name", it.Name,
		"Deleted", deletedNote(it.Deleted, "item", it.Code),
		"Class", pathNames(it.Class.Path),
		"Unit group", unitGroupName(it.UnitGroup),
		"Photo", photo,
		"Id", it.ID)
	if len(it.Values) > 0 {
		fmt.Fprintln(w, "Values:")
		printValues(w, "  ", it.Values)
	}
	printMissing(w, "", it.Missing)
	printAttachments(w, "", it.Attachments)
	if len(it.Stock) == 0 {
		fmt.Fprintln(w, "Stock: none")
		return nil
	}
	fmt.Fprintln(w, "Stock:")
	for _, s := range it.Stock {
		t := newTable(w)
		t.row("  "+s.Code, locations.pathString(s.Location), formatQuantity(s.Quantity, s.Display))
		t.flush()
		printValues(w, "      ", s.Values)
		printMissing(w, "      ", s.Missing)
		printAttachments(w, "      ", s.Attachments)
	}
	return nil
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
				args:    "[--item I] [--location L] [--limit N] [--offset N]",
				summary: "List stock rows, of an item and/or at a location.",
				flags: map[string]param{
					"item":     arg("Item", completeItems),
					"location": arg("Location", completeLocations),
				},
				setup: func(fs *flag.FlagSet) func(*env, []string) error {
					itemRef := fs.String("item", "", "only this item's stock")
					locationRef := fs.String("location", "", "only stock at this location (not below it)")
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
				args:    "<item> <location> [quantity] [--value ATTRIBUTE=VALUE]… [--edit]",
				summary: "Put an item at a location. Without a quantity it is uncounted; quantities may carry units (2.5m).",
				params:  []param{arg("Item", completeItems), locationParam, {name: "Quantity", optional: true, variadic: true}},
				flags:   map[string]param{"value": arg("Value", completeAssignment)},
				setup: func(fs *flag.FlagSet) func(*env, []string) error {
					var values stringList
					fs.Var(&values, "value", "a per-unit attribute value, ATTRIBUTE=VALUE (repeatable)")
					editAfter := fs.Bool("edit", false, "open the new stock row in the edit form")
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
						quantity := strings.Join(args[2:], " ")
						if quantity == "" {
							if quantity, err = e.offer("Quantity (Enter: uncounted)", param{}, args); err != nil {
								return err
							}
						}
						v, err := e.parseValues(values)
						if err != nil {
							return err
						}
						data, err := e.createStock(it, locationID, quantity, v)
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
				args:    "<stock> <location> [quantity]",
				summary: "Move a stock row, or part of it, to another location. Rows with the same values merge.",
				params:  []param{stockParam, locationParam, {name: "Quantity", optional: true, variadic: true}},
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
					body := object{"location": locationID}
					quantity := strings.Join(args[2:], " ")
					if quantity == "" {
						if quantity, err = e.offer("Quantity (Enter: all of it)", param{}, args); err != nil {
							return err
						}
					}
					if quantity != "" {
						var s stock
						if err := e.get("/stock/"+stockID, nil, &s); err != nil {
							return err
						}
						if body["quantity"], err = e.parseQuantity(quantity, s.Item.UnitGroup); err != nil {
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
				name:    "set",
				args:    "<stock> [--quantity Q|none] [--location L] [--item I]",
				summary: "Change a stock row's quantity (none: uncounted), location or item.",
				params:  []param{stockParam},
				flags: map[string]param{
					"location": locationParam,
					"item":     arg("Item", completeItems),
				},
				setup: func(fs *flag.FlagSet) func(*env, []string) error {
					var quantity, locationRef, itemRef optString
					fs.Var(&quantity, "quantity", "new quantity, or none for uncounted")
					fs.Var(&locationRef, "location", "new location (no merging; see 'stock move')")
					fs.Var(&itemRef, "item", "new item")
					return func(e *env, args []string) error {
						if err := wantArgs(args, 1, 1); err != nil {
							return err
						}
						id, err := e.resolveStock(args[0])
						if err != nil {
							return err
						}
						body := object{}
						if itemRef.set {
							if body["item"], err = e.resolveItem(itemRef.value); err != nil {
								return err
							}
						}
						if locationRef.set {
							if body["location"], err = e.resolveLocation(locationRef.value); err != nil {
								return err
							}
						}
						if quantity.set {
							body["quantity"] = nil
							if !isNone(quantity.value) {
								// The unit group is the (possibly new) item's.
								itemID := ""
								if v, ok := body["item"].(string); ok {
									itemID = v
								} else {
									var s stock
									if err := e.get("/stock/"+id, nil, &s); err != nil {
										return err
									}
									itemID = s.Item.ID
								}
								var it item
								if err := e.get("/items/"+itemID, nil, &it); err != nil {
									return err
								}
								if body["quantity"], err = e.parseQuantity(quantity.value, it.UnitGroup); err != nil {
									return err
								}
							}
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
			restoreCommand(restoreKind{kind: "stock", prefix: "/stock/", codeType: "stock", place: "location", placeKind: "location", show: show}),
			historyCommand("stock", "/stock/", "", resolveStockFn),
			valueSetCommand("stock", "/stock/", stockParam, arg("Attribute", completeAttributes), resolveStockFn, show),
			valueDeleteCommand("stock", "/stock/", stockParam, arg("Attribute", completeAttributes), resolveStockFn, show),
		},
	}
}

// renderStock formats a page of stock_list.
func (e *env) renderStock(data json.RawMessage, header bool) ([]string, error) {
	var pg page[stock]
	if err := decode(data, &pg); err != nil {
		return nil, err
	}
	locations, err := e.locationTree()
	if err != nil {
		return nil, err
	}
	var rows [][]string
	for _, s := range pg.Rows {
		rows = append(rows, []string{s.Code, s.Item.Name, locations.pathString(s.Location), formatQuantity(s.Quantity, s.Display)})
	}
	return tableLines([]string{"CODE", "ITEM", "LOCATION", "QUANTITY"}, rows, header), nil
}

func (e *env) printStockJSON(data json.RawMessage) error {
	var s stock
	if err := decode(data, &s); err != nil {
		return err
	}
	locations, err := e.locationTree()
	if err != nil {
		return err
	}
	w := e.stdout
	deleted, merged := deletedNote(s.Deleted, "stock", s.Code), ""
	if s.MergedInto != nil {
		deleted, merged = "yes", s.MergedInto.Code+" (a move added its quantity to that row)"
	}
	fields(w,
		"Code", s.Code,
		"Deleted", deleted,
		"Merged into", merged,
		"Item", s.Item.Code+"  "+s.Item.Name,
		"Location", locations.pathString(s.Location),
		"Quantity", formatQuantity(s.Quantity, s.Display),
		"Id", s.ID)
	if len(s.Values) > 0 {
		fmt.Fprintln(w, "Values:")
		printValues(w, "  ", s.Values)
	}
	printMissing(w, "", s.Missing)
	printAttachments(w, "", s.Attachments)
	return nil
}

// createStock puts item it at a location: quantity as typed ("" for
// uncounted), values as given, and on a terminal the per-unit values it
// still needs (all of them in an interactive session).
func (e *env) createStock(it item, locationID, quantity string, values object) (json.RawMessage, error) {
	body := object{"item": it.ID, "location": locationID}
	if quantity != "" {
		q, err := e.parseQuantity(quantity, it.UnitGroup)
		if err != nil {
			return nil, err
		}
		body["quantity"] = q
	}
	if values == nil {
		values = object{}
	}
	if err := e.askValues(it.Class.ID, true, values); err != nil {
		return nil, err
	}
	if len(values) > 0 {
		body["values"] = values
	}
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
	e.prompted = true // optional per-unit values are offered too
	where, err := e.ask(arg("Location", completeStockLocations), nil)
	if err != nil {
		return err
	}
	quantity, err := e.offer("Quantity (Enter: uncounted)", param{}, nil)
	if err != nil {
		return err
	}
	locationID, err := e.resolveLocation(where)
	var data json.RawMessage
	if err == nil {
		data, err = e.createStock(it, locationID, quantity, nil)
	}
	if err != nil {
		if errors.Is(err, prompt.ErrInterrupted) {
			return err
		}
		return fmt.Errorf("%s was created, but its stock wasn't: %w", it.Name, err)
	}
	return e.printStockJSON(data)
}
