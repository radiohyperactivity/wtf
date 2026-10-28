package cli

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net/http"
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
				if err := decode(data, &t); err != nil {
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
					body := object{"name": m}
					if parentID != "" {
						body["parent"] = parentID
					}
					data, err := e.do(http.MethodPost, path, body)
					if err != nil {
						return fmt.Errorf("creating %s %q: %w", kind, m, err)
					}
					var created node
					if err := decode(data, &created); err != nil {
						return err
					}
					parentID = created.ID
					if !e.json {
						fmt.Fprintf(e.stdout, "Created %s %s.\n", kind, m)
					}
				}
				body := object{"name": name}
				if parentID != "" {
					body["parent"] = parentID
				}
				if *container {
					body["container"] = true
				}
				if columns > 0 {
					body["grid"] = object{"columns": columns, "rows": rows, "confirm": confirmed}
				}
				data, err := e.do(http.MethodPost, path, body)
				if err != nil {
					return err
				}
				if *editAfter {
					var created node
					if err := decode(data, &created); err != nil {
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
			restoreCommand(restoreKind{kind: "location", prefix: "/locations/", codeType: "location", place: "parent", placeKind: "location", named: true, show: show}),
			historyCommand("location", "/locations/", "the top-level locations", resolveLocationFn),
		},
	}
}

func (e *env) printLocationJSON(data json.RawMessage) error {
	var l location
	if err := decode(data, &l); err != nil {
		return err
	}
	fields(e.stdout,
		"Code", l.Code,
		"Name", l.Name,
		"Deleted", deletedNote(l.Deleted, "location", l.Code),
		"Container", yesNo(l.Container),
		"Path", pathNames(l.Path),
		"Id", l.ID)
	printAttachments(e.stdout, "", l.Attachments, l.Photo)
	return nil
}

func classGroup() group {
	show := func(e *env, data json.RawMessage) error { return e.printClassJSON(data) }
	return group{
		name:    "class",
		summary: "Classes: kinds of items (a tree) and their attributes",
		commands: []command{
			treeCommand("classes", "/classes"),
			getCommand("class", "/classes/", resolveClassFn, show),
			nodeAddCommand("class", "/classes", resolveClassFn, show),
			nodeSetCommand("class", "/classes/", resolveClassFn, show),
			editCommand("class", objectParam("class"), resolveClassFn, (*env).editClass),
			treeDeleteCommand("class", "/classes/", resolveClassFn),
			restoreCommand(restoreKind{kind: "class", prefix: "/classes/", place: "parent", placeKind: "class", named: true, show: show}),
			historyCommand("class", "/classes/", "the top-level classes", resolveClassFn),
			{
				name:    "assign",
				args:    "<class> <attribute> [--default V] [--per-unit] [--required]",
				summary: "Give a class (and its subclasses) an attribute, or change the assignment. Unset flags are reset.",
				params:  []param{arg("Class", completeClasses), arg("Attribute", completeAttributes)},
				flags:   map[string]param{"default": arg("Default", completeValueOf(1))},
				setup: func(fs *flag.FlagSet) func(*env, []string) error {
					var def optString
					fs.Var(&def, "default", "default value, which may carry a unit")
					perUnit := fs.Bool("per-unit", false, "values belong to stock rows (e.g. serial numbers), not to the item")
					required := fs.Bool("required", false, "new items and stock rows must have a value")
					return func(e *env, args []string) error {
						if err := wantArgs(args, 2, 2); err != nil {
							return err
						}
						classID, err := e.resolveClass(args[0])
						if err != nil {
							return err
						}
						a, err := e.resolveAttribute(args[1])
						if err != nil {
							return err
						}
						body := object{"default": nil, "per_unit": *perUnit, "required": *required}
						if def.set && !isNone(def.value) {
							if body["default"], err = e.parseValue(a, def.value); err != nil {
								return err
							}
						}
						data, err := e.do(http.MethodPut, "/classes/"+classID+"/attributes/"+a.ID, body)
						if err != nil {
							return err
						}
						return e.emit(data, func() error { return show(e, data) })
					}
				},
			},
			{
				name:    "unassign",
				args:    "<class> <attribute>",
				summary: "Remove an attribute assignment from a class.",
				params:  []param{arg("Class", completeClasses), arg("Attribute", completeAttributes)},
				setup: simple(func(e *env, args []string) error {
					if err := wantArgs(args, 2, 2); err != nil {
						return err
					}
					classID, err := e.resolveClass(args[0])
					if err != nil {
						return err
					}
					a, err := e.resolveAttribute(args[1])
					if err != nil {
						return err
					}
					data, err := e.do(http.MethodDelete, "/classes/"+classID+"/attributes/"+a.ID, nil)
					if err != nil {
						return err
					}
					return e.emit(data, func() error { return show(e, data) })
				}),
			},
		},
	}
}

func (e *env) printClassJSON(data json.RawMessage) error {
	var c class
	if err := decode(data, &c); err != nil {
		return err
	}
	w := e.stdout
	fields(w,
		"Name", c.Name,
		"Deleted", deletedNote(c.Deleted, "class", c.ID),
		"Container", yesNo(c.Container),
		"Path", pathNames(c.Path),
		"Id", c.ID)
	if len(c.Attributes) > 0 {
		fmt.Fprintln(w, "Attributes:")
		t := newTable(w, "  NAME", "TYPE", "DEFAULT", "PER UNIT", "REQUIRED", "FROM")
		for _, a := range c.Attributes {
			def := formatJSONValue(a.Default)
			if a.DefaultDisplay != nil {
				def = formatDisplay(a.DefaultDisplay)
			}
			from := "this class"
			if a.Inherited {
				from = "inherited"
				if classes, err := e.classTree(); err == nil {
					from = "from " + classes.pathString(a.DefinedOnClass)
				}
			}
			t.row("  "+a.Attribute.Name, datatypeName(a.Attribute), def, yesNo(a.PerUnit), yesNo(a.Required), from)
		}
		t.flush()
	}
	printAttachments(w, "", c.Attachments, c.Photo)
	return nil
}

// datatypeName is the datatype, with the unit if there is one.
func datatypeName(a attribute) string {
	if a.Unit != nil {
		return a.Datatype + " (" + unitName(a.Unit, a.UnitLock) + ")"
	}
	return a.Datatype
}

func attributeGroup() group {
	show := func(e *env, data json.RawMessage) error { return e.printAttributeJSON(data) }
	return group{
		name:    "attribute",
		summary: "Attributes: properties that classes give their items",
		commands: []command{
			{
				name:    "list",
				summary: "List the attributes.",
				setup: simple(func(e *env, args []string) error {
					if err := wantArgs(args, 0, 0); err != nil {
						return err
					}
					data, err := e.api.Get(e.ctx, "/attributes", nil)
					if err != nil {
						return err
					}
					return e.emit(data, func() error {
						var list []attribute
						if err := decode(data, &list); err != nil {
							return err
						}
						t := newTable(e.stdout, "NAME", "TYPE", "UNIT")
						for _, a := range list {
							t.row(a.Name, a.Datatype, unitName(a.Unit, a.UnitLock))
						}
						t.flush()
						return nil
					})
				}),
			},
			getCommand("attribute", "/attributes/", resolveAttrIDFn, show),
			{
				name:    "add",
				args:    "<name> --type T [--unit U [--unit-lock]] [--edit]",
				summary: "Create an attribute. Types: text, integer, float, date, boolean, url, choice; with a unit, the type follows from it.",
				params:  []param{arg("Name", nil)},
				flags: map[string]param{
					"type": arg("Type", datatypes),
					"unit": arg("Unit", completeUnits),
				},
				setup: func(fs *flag.FlagSet) func(*env, []string) error {
					datatype := fs.String("type", "", "datatype (required without --unit)")
					unitRef := fs.String("unit", "", "unit of integer and float values, e.g. mm; any unit of its family is accepted")
					unitLock := fs.Bool("unit-lock", false, "always show values in that unit, instead of scaling within the unit's family")
					editAfter := fs.Bool("edit", false, "open the new attribute in the edit form")
					return func(e *env, args []string) error {
						if *editAfter {
							if err := e.needTerminal("--edit"); err != nil {
								return err
							}
						}
						if err := wantArgs(args, 1, 1); err != nil {
							return err
						}
						if *datatype == "" && *unitRef != "" {
							u, err := e.resolveUnit(*unitRef)
							if err != nil {
								return err
							}
							*datatype = u.Quantity.Datatype
						}
						if err := e.need(datatype, "type", arg("Type (text, integer, float, date, boolean, url, choice)", datatypes), args); err != nil {
							return err
						}
						body := object{"name": args[0], "datatype": *datatype}
						var err error
						if *unitRef == "" && (*datatype == "integer" || *datatype == "float") {
							if *unitRef, err = e.offer("Unit (Enter: none)", arg("", completeUnits), args); err != nil {
								return err
							}
						}
						if err := e.setUnit(body, *unitRef, *unitLock); err != nil {
							return err
						}
						data, err := e.do(http.MethodPost, "/attributes", body)
						if err != nil {
							return err
						}
						if *editAfter {
							return e.editCreated(data, (*env).editAttribute)
						}
						return e.emit(data, func() error { return show(e, data) })
					}
				},
			},
			{
				name:    "set",
				args:    "<attribute> [--name N] [--type T] [--unit U] [--unit-lock yes|no]",
				summary: "Change an attribute. Its unit can change to another of the same quantity.",
				params:  []param{arg("Attribute", completeAttributes)},
				flags: map[string]param{
					"type":      arg("Type", datatypes),
					"unit":      arg("Unit", completeUnits),
					"unit-lock": arg("Unit lock", words("yes", "no")),
				},
				setup: func(fs *flag.FlagSet) func(*env, []string) error {
					var name, datatype, unitRef, unitLock optString
					fs.Var(&name, "name", "new name")
					fs.Var(&datatype, "type", "new datatype")
					fs.Var(&unitRef, "unit", "new unit, of the same quantity")
					fs.Var(&unitLock, "unit-lock", "yes: always show values in the unit; no: scale within its family")
					return func(e *env, args []string) error {
						if err := wantArgs(args, 1, 1); err != nil {
							return err
						}
						a, err := e.resolveAttribute(args[0])
						if err != nil {
							return err
						}
						body := object{}
						if name.set {
							body["name"] = name.value
						}
						if datatype.set {
							body["datatype"] = datatype.value
						}
						if err := e.patchUnit(body, unitRef, unitLock); err != nil {
							return err
						}
						if len(body) == 0 {
							return usagef("nothing to change")
						}
						data, err := e.do(http.MethodPatch, "/attributes/"+a.ID, body)
						if err != nil {
							return err
						}
						return e.emit(data, func() error { return show(e, data) })
					}
				},
			},
			editCommand("attribute", objectParam("attribute"), resolveAttrIDFn, (*env).editAttribute),
			deleteCommand("attribute", "/attributes/", resolveAttrIDFn),
			restoreCommand(restoreKind{kind: "attribute", prefix: "/attributes/", named: true, show: show}),
			historyCommand("attribute", "/attributes/", "the list of attributes", resolveAttrIDFn),
		},
	}
}

func (e *env) printAttributeJSON(data json.RawMessage) error {
	var a attribute
	if err := decode(data, &a); err != nil {
		return err
	}
	units := ""
	if a.Unit != nil {
		if family, err := e.familyUnits(a.Unit); err == nil {
			units = unitSymbols(family)
		}
	}
	fields(e.stdout,
		"Name", a.Name,
		"Deleted", deletedNote(a.Deleted, "attribute", a.ID),
		"Type", a.Datatype,
		"Unit", unitName(a.Unit, a.UnitLock),
		"Units", units,
		"Id", a.ID)
	if len(a.Options) > 0 {
		var names []string
		for _, o := range a.Options {
			names = append(names, o.Name)
		}
		fields(e.stdout, "Options", strings.Join(names, ", "))
	}
	return nil
}

func optionGroup() group {
	// resolveOptionArgs takes <attribute> <option>, or a single option id.
	optionParams := []param{arg("Attribute", completeAttributes), optional("Option", completeOptionsOf(0))}
	resolveOptionArgs := func(e *env, args []string) (string, error) {
		if len(args) == 1 && isUUID(args[0]) {
			return strings.ToLower(args[0]), nil
		}
		if len(args) == 1 && e.term != nil {
			p := optionParams[1]
			p.optional = false
			v, err := e.ask(p, args)
			if err != nil {
				return "", err
			}
			args = append(args, v)
		}
		if err := wantArgs(args, 2, 2); err != nil {
			return "", err
		}
		a, err := e.resolveAttribute(args[0])
		if err != nil {
			return "", err
		}
		return e.resolveOption(a.ID, args[1])
	}
	printOption := func(e *env, data json.RawMessage) error {
		var o option
		if err := decode(data, &o); err != nil {
			return err
		}
		fields(e.stdout, "Name", o.Name, "Attribute", o.Attribute, "Id", o.ID)
		return nil
	}
	return group{
		name:    "option",
		summary: "Options of choice attributes",
		commands: []command{
			{
				name:    "list",
				args:    "<attribute>",
				summary: "List the options of a choice attribute.",
				params:  []param{arg("Attribute", completeAttributes)},
				setup: simple(func(e *env, args []string) error {
					if err := wantArgs(args, 1, 1); err != nil {
						return err
					}
					a, err := e.resolveAttribute(args[0])
					if err != nil {
						return err
					}
					data, err := e.api.Get(e.ctx, "/attributes/"+a.ID+"/options", nil)
					if err != nil {
						return err
					}
					return e.emit(data, func() error {
						var list []option
						if err := decode(data, &list); err != nil {
							return err
						}
						t := newTable(e.stdout, "NAME", "ID")
						for _, o := range list {
							t.row(o.Name, o.ID)
						}
						t.flush()
						return nil
					})
				}),
			},
			{
				name:    "get",
				args:    "<attribute> <option>",
				summary: "Show an option.",
				params:  optionParams,
				setup: simple(func(e *env, args []string) error {
					id, err := resolveOptionArgs(e, args)
					if err != nil {
						return err
					}
					data, err := e.api.Get(e.ctx, "/options/"+id, nil)
					if err != nil {
						return err
					}
					return e.emit(data, func() error { return printOption(e, data) })
				}),
			},
			{
				name:    "add",
				args:    "<attribute> <name>…",
				summary: "Add options to a choice attribute.",
				params:  []param{arg("Attribute", completeAttributes), rest("Name", nil)},
				setup: simple(func(e *env, args []string) error {
					if err := wantArgs(args, 2, -1); err != nil {
						return err
					}
					a, err := e.resolveAttribute(args[0])
					if err != nil {
						return err
					}
					for _, name := range args[1:] {
						data, err := e.do(http.MethodPost, "/attributes/"+a.ID+"/options", object{"name": name})
						if err != nil {
							return err
						}
						if err := e.emit(data, func() error {
							fmt.Fprintf(e.stdout, "Added %s.\n", name)
							return nil
						}); err != nil {
							return err
						}
					}
					return nil
				}),
			},
			{
				name:    "set",
				args:    "<attribute> <option> --name N",
				summary: "Rename an option.",
				params:  optionParams,
				setup: func(fs *flag.FlagSet) func(*env, []string) error {
					name := fs.String("name", "", "new name (required)")
					return func(e *env, args []string) error {
						id, err := resolveOptionArgs(e, args)
						if err != nil {
							return err
						}
						if err := e.need(name, "name", arg("New name", nil), args); err != nil {
							return err
						}
						data, err := e.do(http.MethodPatch, "/options/"+id, object{"name": *name})
						if err != nil {
							return err
						}
						return e.emit(data, func() error { return printOption(e, data) })
					}
				},
			},
			{
				name:    "delete",
				args:    "<attribute> <option>",
				summary: "Delete an option that no value or default uses.",
				params:  optionParams,
				setup: simple(func(e *env, args []string) error {
					id, err := resolveOptionArgs(e, args)
					if err != nil {
						return err
					}
					if _, err := e.do(http.MethodDelete, "/options/"+id, nil); err != nil {
						return err
					}
					e.deleted("option " + args[len(args)-1])
					return nil
				}),
			},
			restoreCommand(restoreKind{kind: "option", prefix: "/options/", named: true, show: (*env).printOptionJSON}),
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
