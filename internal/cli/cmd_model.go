package cli

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
)

// treeCommand prints the class or location tree.
func treeCommand(kind, path string) command {
	return command{
		name:    "tree",
		summary: "Show all " + kind + " as a tree.",
		setup: simple(func(e *env, args []string) error {
			if err := wantArgs(args, 0, 0); err != nil {
				return err
			}
			data, err := e.api.Get(e.ctx, path, nil)
			if err != nil {
				return err
			}
			return e.emit(data, func() error {
				var t tree
				if err := e.decode(data, &t); err != nil {
					return err
				}
				if len(t.Tree) == 0 {
					fmt.Fprintf(e.stderr, "No %s yet.\n", kind)
				}
				printTree(e.stdout, t.Tree)
				return nil
			})
		}),
	}
}

// nodeAddCommand creates a class or location. The name may be a path
// ("MCU/AVR/Old"): the last name is created under the others. Missing
// parents are listed and created after asking, or at once with --create-parents.
func nodeAddCommand(kind, path string, resolve func(*env, string) (string, error), show func(*env, json.RawMessage) error) command {
	plural := map[string]string{"class": "classes", "location": "locations"}[kind]
	usage := "<name or path> [--parent P] [--create-parents] [--container] [--edit]"
	if kind == "location" {
		usage = "<name or path> [--parent P] [--create-parents] [--container | --grid COLUMNSxROWS [--yes]] [--edit]"
	}
	return command{
		name:    "add",
		args:    usage,
		summary: "Create a " + kind + `. A path ("A/B/C") creates C under A/B, offering to create missing parents.`,
		params:  []param{arg("Name", parentPaths(kindCompleters[kind]))},
		flags:   map[string]param{"parent": arg("Parent", kindCompleters[kind])},
		setup: func(fs *flag.FlagSet) func(*env, []string) error {
			parent := fs.String("parent", "", "the parent "+kind+"; a path in the name is then below it")
			parents := fs.Bool("create-parents", false, "create missing parents without asking")
			container := fs.Bool("container", false, "make it a container: it holds only other "+plural+", "+map[string]string{"class": "no items", "location": "no stock"}[kind])
			editAfter := fs.Bool("edit", false, "open the new "+kind+" in the edit form")
			grid, yes := new(string), new(bool)
			if kind == "location" {
				grid = fs.String("grid", "", "also create compartments named like spreadsheet cells: COLUMNSxROWS, e.g. 8x5 for A1 … H5 (makes it a container)")
				yes = fs.Bool("yes", false, "don't ask before creating more than 1000 locations (needed in scripts)")
			}
			return func(e *env, args []string) error {
				if *editAfter {
					if err := e.needTerminal("--edit"); err != nil {
						return err
					}
				}
				if err := wantArgs(args, 1, 1); err != nil {
					return err
				}
				var columns, rows int
				if *grid != "" {
					var err error
					if columns, rows, err = parseGrid(*grid); err != nil {
						return err
					}
				}
				segments, err := pathSegments(args[0])
				if err != nil {
					return err
				}
				name, dirs := segments[len(segments)-1], segments[:len(segments)-1]
				parentID := ""
				if *parent != "" {
					if parentID, err = resolve(e, *parent); err != nil {
						return err
					}
				}
				var missing []string
				if len(dirs) > 0 {
					ix, err := e.tree(kind)
					if err != nil {
						return err
					}
					if parentID, missing, err = e.locateParent(ix, kind, parentID, dirs); err != nil {
						return err
					}
					if len(missing) > 0 {
						if err := e.confirmParents(ix, kind, plural, parentID, missing, *parents); err != nil {
							return err
						}
					}
				}
				// A big grid is confirmed before anything is created.
				confirmed := false
				if total := columns*rows + 1 + len(missing); columns > 0 && total > 1000 {
					question := fmt.Sprintf("This creates %d locations", total)
					if !*yes {
						if e.term == nil {
							return fmt.Errorf("%s; add --yes to confirm it", question)
						}
						answer, err := e.term.ReadLine(question+". Continue? [y/N] ", "", nil)
						if err != nil {
							return err
						}
						if a := strings.ToLower(strings.TrimSpace(answer)); a != "y" && a != "yes" {
							return errors.New("nothing was created")
						}
					}
					confirmed = true
				}
				for _, m := range missing {
					body := newNode(kind, m, parentID, false)
					data, err := e.do(http.MethodPost, path, body)
					if err != nil {
						return fmt.Errorf("creating %s %q: %w", kind, m, err)
					}
					var created node
					if err := e.decode(data, &created); err != nil {
						return err
					}
					parentID = created.ID
					if !e.json {
						fmt.Fprintf(e.stdout, "Created %s %s.\n", kind, m)
					}
				}
				body := newNode(kind, name, parentID, *container)
				if columns > 0 {
					body["grid"] = object{"columns": columns, "rows": rows, "confirm": confirmed}
				}
				data, err := e.do(http.MethodPost, path, body)
				if err != nil {
					return err
				}
				if *editAfter {
					var created node
					if err := e.decode(data, &created); err != nil {
						return err
					}
					return e.editNode(kind, created.ID)
				}
				return e.emit(data, func() error {
					if err := show(e, data); err != nil {
						return err
					}
					if columns > 0 {
						fmt.Fprintf(e.stdout, "Compartments: %s, %s … %s%d\n", count(columns*rows, "compartment", "compartments"), "A1", columnLabel(columns), rows)
					}
					return nil
				})
			}
		},
	}
}

// pathSegments splits a path into its names; empty names are an error.
func pathSegments(path string) ([]string, error) {
	segments := strings.Split(path, "/")
	for i, s := range segments {
		segments[i] = strings.TrimSpace(s)
		if segments[i] == "" {
			return nil, usagef("%q: empty name in path", path)
		}
	}
	return segments, nil
}

// tree returns the class or location tree.
func (e *env) tree(kind string) (*treeIndex, error) {
	if kind == "class" {
		return e.classTree()
	}
	return e.locationTree()
}

// locateParent finds the node that the path dirs names, and returns the
// names at its end that don't exist yet. With startID, dirs is below that
// node; otherwise dirs is resolved like any reference (by its end), and when
// nothing matches, read from the top level down.
func (e *env) locateParent(ix *treeIndex, kind, startID string, dirs []string) (string, []string, error) {
	level := ix.roots
	if startID != "" {
		start := ix.byID[startID]
		if start == nil {
			return "", nil, fmt.Errorf("no %s with id %s", kind, startID)
		}
		level = start.Children
	} else {
		ref := strings.Join(dirs, "/")
		if matches := ix.find(ref); len(matches) > 0 {
			id, err := e.resolveNode(ix, kind, ref)
			return id, nil, err
		}
	}
	cur, i := startID, 0
	for ; i < len(dirs); i++ {
		var next *node
		for _, n := range level {
			if strings.EqualFold(n.Name, dirs[i]) {
				next = n
			}
		}
		if next == nil {
			break
		}
		cur, level = next.ID, next.Children
	}
	return cur, dirs[i:], nil
}

// confirmParents asks before missing parents are created; --create-parents skips
// the question. Without a terminal, missing parents are an error.
func (e *env) confirmParents(ix *treeIndex, kind, plural, parentID string, missing []string, force bool) error {
	if force {
		return nil
	}
	base := ""
	if parentID != "" {
		base = ix.pathString(parentID) + "/"
	}
	var paths []string
	for _, m := range missing {
		base += m
		paths = append(paths, base)
		base += "/"
	}
	if e.term == nil {
		return fmt.Errorf("these %s don't exist: %s\nCreate them first, or add --create-parents", plural, strings.Join(paths, ", "))
	}
	fmt.Fprintf(e.stderr, "These %s don't exist yet:\n  %s\n", plural, strings.Join(paths, "\n  "))
	answer, err := e.term.ReadLine("Create them? [y/N] ", "", nil)
	if err != nil {
		return err
	}
	switch strings.ToLower(strings.TrimSpace(answer)) {
	case "y", "yes":
		return nil
	}
	return errors.New("nothing was created")
}

// parentPaths completes the parent part of a new path: every existing node,
// with or without children, followed by "/" ("Home/"), since the new node
// goes below it.
func parentPaths(c completer) completer {
	return func(e *env, args []string, cur string, _ bool) []string {
		var out []string
		for _, s := range c(e, args, cur, false) {
			if !strings.HasSuffix(s, "/") {
				s += "/"
			}
			out = append(out, s)
		}
		return dedupe(out)
	}
}

// nodeSetCommand renames or moves a class or location.
func nodeSetCommand(kind, prefix string, resolve func(*env, string) (string, error), show func(*env, json.RawMessage) error) command {
	return command{
		name:    "set",
		args:    "<" + kind + "> [--name N] [--parent P|none] [--container yes|no]",
		summary: "Rename a " + kind + ", move it under another parent (none: make it a root), or (un)mark it as a container.",
		params:  []param{objectParam(kind)},
		flags: map[string]param{
			"parent":    arg("Parent", kindCompleters[kind]),
			"container": arg("Container", words("yes", "no")),
		},
		setup: func(fs *flag.FlagSet) func(*env, []string) error {
			var name, parent, container optString
			fs.Var(&name, "name", "new name")
			fs.Var(&parent, "parent", "new parent, or none")
			fs.Var(&container, "container", "yes: holds only other nodes; no: may hold items or stock")
			return func(e *env, args []string) error {
				if err := wantArgs(args, 1, 1); err != nil {
					return err
				}
				id, err := resolve(e, args[0])
				if err != nil {
					return err
				}
				body := object{}
				if name.set {
					body["name"] = name.value
				}
				if parent.set {
					body["parent"] = nil
					if !isNone(parent.value) {
						if body["parent"], err = resolve(e, parent.value); err != nil {
							return err
						}
					}
				}
				if container.set {
					b, ok := parseYesNo(container.value)
					if !ok {
						return usagef("--container must be yes or no")
					}
					body["container"] = b
				}
				if len(body) == 0 {
					return usagef("nothing to change")
				}
				data, err := e.do(http.MethodPatch, prefix+id, body)
				if err != nil {
					return err
				}
				return e.emit(data, func() error { return show(e, data) })
			}
		},
	}
}

// getCommand shows the object named by the argument.
func getCommand(kind, prefix string, resolve func(*env, string) (string, error), show func(*env, json.RawMessage) error) command {
	return command{
		name:    "get",
		args:    "<" + kind + ">",
		summary: "Show " + article(kind) + ".",
		params:  []param{objectParam(kind)},
		setup: simple(func(e *env, args []string) error {
			if err := wantArgs(args, 1, 1); err != nil {
				return err
			}
			id, err := resolve(e, args[0])
			if err != nil {
				return err
			}
			data, err := e.api.Get(e.ctx, prefix+id, nil)
			if err != nil {
				return err
			}
			return e.emit(data, func() error { return show(e, data) })
		}),
	}
}

func locationGroup() group {
	show := func(e *env, data json.RawMessage) error { return e.printLocationJSON(data) }
	return group{
		name:    "location",
		summary: "Locations: rooms, shelves, boxes, … (a tree)",
		commands: []command{
			treeCommand("locations", "/locations"),
			getCommand("location", "/locations/", resolveLocationFn, show),
			nodeAddCommand("location", "/locations", resolveLocationFn, show),
			nodeSetCommand("location", "/locations/", resolveLocationFn, show),
			editCommand("location", objectParam("location"), resolveLocationFn, (*env).editLocation),
			treeDeleteCommand("location", "/locations/", resolveLocationFn),
		},
	}
}

func (e *env) printLocationJSON(data json.RawMessage) error {
	var l location
	if err := e.decode(data, &l); err != nil {
		return err
	}
	fields(e.stdout,
		"Code", l.Code,
		"Name", l.Name,
		"Container", yesNo(l.Container),
		"Path", pathNames(l.Path),
		"Id", l.ID)
	return nil
}

func classGroup() group {
	show := func(e *env, data json.RawMessage) error { return e.printClassJSON(data) }
	return group{
		name:    "class",
		summary: "Classes: kinds of items (a tree); their attributes are 'class attribute' and 'class choice'",
		commands: []command{
			treeCommand("classes", "/classes"),
			getCommand("class", "/classes/", resolveClassFn, show),
			nodeAddCommand("class", "/classes", resolveClassFn, show),
			nodeSetCommand("class", "/classes/", resolveClassFn, show),
			editCommand("class", objectParam("class"), resolveClassFn, (*env).editClass),
			treeDeleteCommand("class", "/classes/", resolveClassFn),
		},
	}
}

func (e *env) printClassJSON(data json.RawMessage) error {
	var c class
	if err := e.decode(data, &c); err != nil {
		return err
	}
	e.printClass(c)
	return nil
}

func (e *env) printClass(c class) {
	w := e.stdout
	fields(w,
		"Name", c.Name,
		"Container", yesNo(c.Container),
		"Path", pathNames(c.Path),
		"Id", c.ID)
	for _, scope := range []string{"item", "stock"} {
		header := false
		var t *table
		for _, a := range c.Attributes {
			if a.Scope != scope {
				continue
			}
			if !header {
				fmt.Fprintln(w, map[string]string{"item": "Item attributes:", "stock": "Stock attributes:"}[scope])
				t = newTable(w, "  NAME", "TYPE", "UNIT", "DEFAULT", "REQUIRED", "FROM")
				header = true
			}
			from := "this class"
			if a.Inherited {
				from = "inherited"
				if classes, err := e.classTree(); err == nil {
					from = "from " + classes.pathString(a.Class)
				}
			}
			t.row("  "+a.Name, typeText(a), a.Unit, formatJSONValue(a.Default), yesNo(a.Required), from)
		}
		if t != nil {
			t.flush()
		}
	}
}

// typeText is an attribute's type, with its choices or media types.
func typeText(a attribute) string {
	switch {
	case a.Type == "choice":
		return "choice: " + strings.Join(a.Choices, ", ")
	case a.Type == "attachment" && len(a.Media) > 0:
		return "attachment: " + strings.Join(a.Media, ", ")
	}
	return a.Type
}

// classChange runs a change of a class's attributes: body is sent
// with method to path (below the class), with ?dry_run=true for --dry-run,
// and the answer says what it wrote.
func (e *env) classChange(method, path string, body any, dryRun bool) error {
	if dryRun {
		path += "?dry_run=true"
	}
	var data json.RawMessage
	var err error
	if dryRun {
		data, _, err = e.api.Do(e.ctx, method, path, nil, body)
	} else {
		data, err = e.do(method, path, body)
	}
	if err != nil {
		return err
	}
	return e.emit(data, func() error {
		var r classChange
		if err := e.decode(data, &r); err != nil {
			return err
		}
		e.printClass(r.Class)
		rows := joinCounts(count(r.Items, "item", "items"), count(r.Stock, "stock row", "stock rows"))
		switch {
		case r.DryRun && rows == "":
			fmt.Fprintln(e.stdout, "A dry run: nothing changed, and no item or stock row would be rewritten.")
		case r.DryRun:
			fmt.Fprintf(e.stdout, "A dry run: nothing changed. It would rewrite %s.\n", rows)
		case rows != "":
			fmt.Fprintf(e.stdout, "Rewrote %s.\n", rows)
		}
		return nil
	})
}

// classAttributePath is the API path of attribute name of the class in ref.
func (e *env) classAttributePath(classRef, name string) (string, string, error) {
	classID, err := e.resolveClass(classRef)
	if err != nil {
		return "", "", err
	}
	a, err := e.classAttribute(classID, name)
	if err != nil {
		return "", "", err
	}
	return "/classes/" + classID + "/attributes/" + url.PathEscape(a.Name), a.Name, nil
}

// parseDefault reads a default as a value of definition def.
func parseDefault(def object, name, text string) (any, error) {
	a := attribute{Name: name, Type: fmt.Sprint(def["type"])}
	if u, ok := def["unit"].(string); ok {
		a.Unit = u
	}
	if c, ok := def["choices"].([]string); ok {
		a.Choices = c
	}
	return parseValue(a, text)
}

// splitList reads a comma-separated list, trimmed.
func splitList(s string) []string {
	var out []string
	for _, x := range strings.Split(s, ",") {
		if x = strings.TrimSpace(x); x != "" {
			out = append(out, x)
		}
	}
	return out
}

func classAttributeGroup() group {
	classParam := arg("Class", completeClasses)
	ownAttribute := arg("Attribute", completeAttributesOf(0, true))
	return group{
		name:    "class attribute",
		summary: "The attributes of classes: added, changed, renamed and removed where they are defined",
		commands: []command{
			{
				name: "add",
				args: "<class> <name> --type T [--stock] [--unit U] [--required] [--default V] [--choices A,B,C] [--media TYPES] [--order N] [--dry-run]",
				summary: "Add an attribute to a class and the classes below it. Types: text, integer, decimal, date, boolean, url, choice, attachment. " +
					"A required one gives its default to every item (or stock row) below.",
				params: []param{classParam, arg("Name", nil)},
				flags:  map[string]param{"type": arg("Type", datatypes)},
				setup: func(fs *flag.FlagSet) func(*env, []string) error {
					typ := fs.String("type", "", "its type (required)")
					stock := fs.Bool("stock", false, "its values are on each stock row (a serial number, a purchase date), not on the item")
					unit := fs.String("unit", "", "a label for its values, e.g. mm (nothing converts)")
					required := fs.Bool("required", false, "every item (or stock row) must have a value")
					def := fs.String("default", "", "its default value")
					choices := fs.String("choices", "", "a choice's choices, separated by commas (required for a choice)")
					media := fs.String("media", "", "an attachment's media types, separated by commas: application/pdf,image/*")
					order := fs.Int("order", 0, "its place on screen (default: last)")
					dryRun := fs.Bool("dry-run", false, "change nothing, and say what it would do")
					return func(e *env, args []string) error {
						if err := wantArgs(args, 2, 2); err != nil {
							return err
						}
						if err := e.need(typ, "type", arg("Type", datatypes), args); err != nil {
							return err
						}
						classID, err := e.resolveClass(args[0])
						if err != nil {
							return err
						}
						d := object{"scope": "item", "type": *typ, "required": *required}
						if *stock {
							d["scope"] = "stock"
						}
						if *unit != "" {
							d["unit"] = *unit
						}
						if *choices != "" {
							d["choices"] = splitList(*choices)
						}
						if *media != "" {
							d["media"] = splitList(*media)
						}
						if *order != 0 {
							d["order"] = *order
						}
						if *def != "" {
							if d["default"], err = parseDefault(d, args[1], *def); err != nil {
								return err
							}
						}
						return e.classChange(http.MethodPost, "/classes/"+classID+"/attributes",
							object{"name": args[1], "definition": d}, *dryRun)
					}
				},
			},
			{
				name: "set",
				args: "<class> <attribute> [--required yes|no] [--default V | --no-default] [--unit U | --no-unit] [--media TYPES | --no-media] [--order N] [--dry-run]",
				summary: "Change an attribute the class defines. A new default reaches every value below that follows it. " +
					"Its type and where its values live never change: remove it and add it again.",
				params: []param{classParam, ownAttribute},
				flags:  map[string]param{"required": arg("Required", words("yes", "no"))},
				setup: func(fs *flag.FlagSet) func(*env, []string) error {
					var required, def, unit, media optString
					fs.Var(&required, "required", "yes: every item (or stock row) must have a value")
					fs.Var(&def, "default", "a new default")
					noDefault := fs.Bool("no-default", false, "no default")
					fs.Var(&unit, "unit", "a new label for its values")
					noUnit := fs.Bool("no-unit", false, "no unit label")
					fs.Var(&media, "media", "an attachment's media types, separated by commas")
					noMedia := fs.Bool("no-media", false, "an attachment takes any file")
					var order optString
					fs.Var(&order, "order", "its place on screen")
					dryRun := fs.Bool("dry-run", false, "change nothing, and say what it would do")
					return func(e *env, args []string) error {
						if err := wantArgs(args, 2, 2); err != nil {
							return err
						}
						path, name, err := e.classAttributePath(args[0], args[1])
						if err != nil {
							return err
						}
						classID, _ := e.resolveClass(args[0])
						a, err := e.classAttribute(classID, name)
						if err != nil {
							return err
						}
						body := object{}
						if required.set {
							b, ok := parseYesNo(required.value)
							if !ok {
								return usagef("--required takes yes or no")
							}
							body["required"] = b
						}
						for _, f := range []struct {
							key   string
							value optString
							none  bool
						}{{"default", def, *noDefault}, {"unit", unit, *noUnit}, {"media", media, *noMedia}} {
							switch {
							case f.value.set && f.none:
								return usagef("give --%s or --no-%s, not both", f.key, f.key)
							case f.none:
								body[f.key] = nil
							case f.value.set && f.key == "default":
								if unit.set {
									a.Unit = unit.value
								}
								if body["default"], err = parseValue(a, f.value.value); err != nil {
									return err
								}
							case f.value.set && f.key == "media":
								body["media"] = splitList(f.value.value)
							case f.value.set:
								body[f.key] = f.value.value
							}
						}
						if order.set {
							var n int
							if _, err := fmt.Sscanf(order.value, "%d", &n); err != nil {
								return usagef("--order takes an integer")
							}
							body["order"] = n
						}
						if len(body) == 0 {
							return usagef("nothing to change")
						}
						return e.classChange(http.MethodPatch, path, body, *dryRun)
					}
				},
			},
			{
				name:    "rename",
				args:    "<class> <attribute> <new name> [--dry-run]",
				summary: "Rename an attribute the class defines, in every value below it too.",
				params:  []param{classParam, ownAttribute, arg("New name", nil)},
				setup: func(fs *flag.FlagSet) func(*env, []string) error {
					dryRun := fs.Bool("dry-run", false, "change nothing, and say what it would do")
					return func(e *env, args []string) error {
						if err := wantArgs(args, 3, 3); err != nil {
							return err
						}
						path, _, err := e.classAttributePath(args[0], args[1])
						if err != nil {
							return err
						}
						return e.classChange(http.MethodPost, path+"/rename", object{"name": args[2]}, *dryRun)
					}
				},
			},
			{
				name:    "remove",
				args:    "<class> <attribute> [--dry-run] [--yes]",
				summary: "Remove an attribute the class defines, with its values below it, for good; on a terminal it asks first.",
				params:  []param{classParam, ownAttribute},
				setup: func(fs *flag.FlagSet) func(*env, []string) error {
					dryRun := fs.Bool("dry-run", false, "change nothing, and say what it would do")
					yes := fs.Bool("yes", false, "don't ask first")
					return func(e *env, args []string) error {
						if err := wantArgs(args, 2, 2); err != nil {
							return err
						}
						path, name, err := e.classAttributePath(args[0], args[1])
						if err != nil {
							return err
						}
						if !*dryRun {
							if err := e.confirmDelete("attribute "+name+" and its values", *yes); err != nil {
								return err
							}
						}
						return e.classChange(http.MethodDelete, path, nil, *dryRun)
					}
				},
			},
		},
	}
}

func classChoiceGroup() group {
	classParam := arg("Class", completeClasses)
	attributeParam := arg("Attribute", completeAttributesOf(0, true))
	choiceParam := arg("Choice", completeChoicesOf(0, 1))
	dryRunFlag := func(fs *flag.FlagSet) *bool {
		return fs.Bool("dry-run", false, "change nothing, and say what it would do")
	}
	return group{
		name:    "class choice",
		summary: "The choices of choice attributes",
		commands: []command{
			{
				name:    "add",
				args:    "<class> <attribute> <choice>… [--dry-run]",
				summary: "Add choices, last.",
				params:  []param{classParam, attributeParam, rest("Choice", nil)},
				setup: func(fs *flag.FlagSet) func(*env, []string) error {
					dryRun := dryRunFlag(fs)
					return func(e *env, args []string) error {
						if err := wantArgs(args, 3, -1); err != nil {
							return err
						}
						path, _, err := e.classAttributePath(args[0], args[1])
						if err != nil {
							return err
						}
						for _, c := range args[2:] {
							if err := e.classChange(http.MethodPost, path+"/choices", object{"choice": c}, *dryRun); err != nil {
								return err
							}
						}
						return nil
					}
				},
			},
			{
				name:    "rename",
				args:    "<class> <attribute> <choice> <new> [--dry-run]",
				summary: "Rename a choice, in its place, the default, and every value below the class.",
				params:  []param{classParam, attributeParam, choiceParam, arg("New", nil)},
				setup: func(fs *flag.FlagSet) func(*env, []string) error {
					dryRun := dryRunFlag(fs)
					return func(e *env, args []string) error {
						if err := wantArgs(args, 4, 4); err != nil {
							return err
						}
						path, _, err := e.classAttributePath(args[0], args[1])
						if err != nil {
							return err
						}
						return e.classChange(http.MethodPost, path+"/choices/"+url.PathEscape(args[2])+"/rename",
							object{"choice": args[3]}, *dryRun)
					}
				},
			},
			{
				name:    "remove",
				args:    "<class> <attribute> <choice> [--dry-run]",
				summary: "Remove a choice that no item (or stock row) below the class has, and that isn't the default.",
				params:  []param{classParam, attributeParam, choiceParam},
				setup: func(fs *flag.FlagSet) func(*env, []string) error {
					dryRun := dryRunFlag(fs)
					return func(e *env, args []string) error {
						if err := wantArgs(args, 3, 3); err != nil {
							return err
						}
						path, _, err := e.classAttributePath(args[0], args[1])
						if err != nil {
							return err
						}
						return e.classChange(http.MethodDelete, path+"/choices/"+url.PathEscape(args[2]), nil, *dryRun)
					}
				},
			},
		},
	}
}

var gridPattern = regexp.MustCompile(`^\s*([0-9]+)\s*[xX×]\s*([0-9]+)\s*$`)

// parseGrid reads COLUMNSxROWS ("8x5": columns A–H, rows 1–5).
func parseGrid(s string) (int, int, error) {
	m := gridPattern.FindStringSubmatch(s)
	if m == nil {
		return 0, 0, usagef("--grid %q: give COLUMNSxROWS, e.g. 8x5 for A1 … H5", s)
	}
	columns, err1 := strconv.Atoi(m[1])
	rows, err2 := strconv.Atoi(m[2])
	if err1 != nil || err2 != nil || columns < 1 || rows < 1 || columns > 1<<20 || rows > 1<<20 {
		return 0, 0, usagef("--grid %q: a grid has at least 1 column and 1 row", s)
	}
	return columns, rows, nil
}

// columnLabel is the spreadsheet name of column n: 1 → A, 27 → AA.
func columnLabel(n int) string {
	label := ""
	for n > 0 {
		n--
		label = string(rune('A'+n%26)) + label
		n /= 26
	}
	return label
}

// newNode is the body that creates a class or location: every field, as
// creating requires, with a location's grid null (none).
func newNode(kind, name, parentID string, container bool) object {
	body := object{"name": name, "parent": nil, "container": container}
	if parentID != "" {
		body["parent"] = parentID
	}
	if kind == "location" {
		body["grid"] = nil
	}
	return body
}
