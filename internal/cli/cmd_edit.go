package cli

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"

	"github.com/radiohyperactivity/wtf/internal/prompt"
)

// Edit forms: "wtf <noun> edit <ref>" asks for every field in turn, with the
// current value filled in; Enter keeps it, Tab completes. The changes are
// collected and applied only at the end, so Ctrl-C at any point changes
// nothing. Applying may take several requests; if one fails, the message says
// what was already saved.

// editPlan collects the changes of a form.
type editPlan struct {
	path  string // the object's API path, for the PATCH
	patch object
	steps []editStep
}

type editStep struct {
	what string // "set Length", "remove option red", …
	run  func() error
}

func newPlan(path string) *editPlan { return &editPlan{path: path, patch: object{}} }

func (p *editPlan) add(what string, run func() error) {
	p.steps = append(p.steps, editStep{what, run})
}

// apply sends the PATCH, then the other steps, and reports what was saved.
func (e *env) apply(p *editPlan) error {
	var done []string
	if len(p.patch) > 0 {
		if _, err := e.do(http.MethodPatch, p.path, p.patch); err != nil {
			return err
		}
		for _, k := range sortedKeys(p.patch) {
			done = append(done, "changed "+strings.ReplaceAll(k, "_", " "))
		}
	}
	for _, s := range p.steps {
		if err := s.run(); err != nil {
			if len(done) == 0 {
				return fmt.Errorf("%s: %w", s.what, err)
			}
			return fmt.Errorf("%s: %w\nAlready saved: %s", s.what, err, strings.Join(done, ", "))
		}
		done = append(done, s.what)
	}
	if !e.json {
		if len(done) == 0 {
			fmt.Fprintln(e.stderr, "No changes.")
		} else {
			fmt.Fprintf(e.stderr, "Saved: %s.\n", strings.Join(done, ", "))
		}
	}
	return nil
}

// needTerminal reports that something needs an interactive terminal.
func (e *env) needTerminal(what string) error {
	if e.term == nil {
		return fmt.Errorf("%s needs a terminal; in scripts, use 'set' and the other commands", what)
	}
	return nil
}

// field asks for one field with its current value filled in.
func (e *env) field(label, current string, c completer) (string, error) {
	var complete prompt.Completer
	if c != nil {
		complete = func(input string) []string { return c(e, nil, input, true) }
	}
	v, err := e.term.ReadLine(label+": ", current, complete)
	return strings.TrimSpace(v), err
}

// requiredField is field, asking again while the input is empty.
func (e *env) requiredField(label, current string, c completer) (string, error) {
	for {
		v, err := e.field(label, current, c)
		if err != nil || v != "" {
			return v, err
		}
		fmt.Fprintf(e.stderr, "%s can't be empty.\n", label)
	}
}

// yesNoField asks a yes/no question with the current answer filled in.
func (e *env) yesNoField(label string, current bool) (bool, error) {
	text := map[bool]string{true: "yes", false: "no"}[current]
	for {
		v, err := e.field(label, text, words("yes", "no"))
		if err != nil {
			return false, err
		}
		if b, ok := parseYesNo(v); ok {
			return b, nil
		}
		fmt.Fprintln(e.stderr, "Answer yes or no.")
		text = v
	}
}

// valueField asks for a value of attribute a until it parses. Empty input
// means no value (nil).
func (e *env) valueField(label, current string, a attribute) (string, any, error) {
	complete := func(e *env, _ []string, cur string, _ bool) []string { return e.valueCandidates(&a, cur) }
	for {
		text, err := e.field(label, current, complete)
		if err != nil || text == "" {
			return text, nil, err
		}
		v, err := e.parseValue(&a, text)
		if err == nil {
			return text, v, nil
		}
		fmt.Fprintln(e.stderr, err)
		current = text
	}
}

// formatDefault renders a class attribute's default, or "".
func formatDefault(ca classAttribute) string {
	if ca.DefaultDisplay != nil {
		return formatDisplay(ca.DefaultDisplay)
	}
	return formatJSONValue(ca.Default)
}

func hasDefault(ca classAttribute) bool {
	return len(ca.Default) > 0 && string(ca.Default) != "null"
}

// editTitle introduces a form.
func (e *env) editTitle(what string) {
	fmt.Fprintf(e.stderr, "Editing %s. Enter keeps a value, Tab completes, Ctrl-C cancels without saving.\n", what)
}

// showAfterEdit fetches and shows the object after it was saved.
func (e *env) showAfterEdit(path string, show func(*env, json.RawMessage) error) error {
	data, err := e.api.Get(e.ctx, path, nil)
	if err != nil {
		return err
	}
	return e.emit(data, func() error { return show(e, data) })
}

// editCommand is "wtf <noun> edit <ref>".
func editCommand(kind string, p param, resolve func(*env, string) (string, error), edit func(*env, string) error) command {
	return command{
		name:    "edit",
		args:    "<" + kind + ">",
		summary: "Edit " + article(kind) + " in a form: every field, with its current value (needs a terminal).",
		params:  []param{p},
		setup: simple(func(e *env, args []string) error {
			if err := wantArgs(args, 1, 1); err != nil {
				return err
			}
			if err := e.needTerminal("edit"); err != nil {
				return err
			}
			id, err := resolve(e, args[0])
			if err != nil {
				return err
			}
			return edit(e, id)
		}),
	}
}

// editNode edits a class or location.
func (e *env) editNode(kind, id string) error {
	if kind == "class" {
		return e.editClass(id)
	}
	return e.editLocation(id)
}

// editTreeFields asks for name, parent and container, the fields classes and
// locations share.
func (e *env) editTreeFields(p *editPlan, ix *treeIndex, kind, name string, parent *string, container bool, c completer) error {
	v, err := e.requiredField("Name", name, nil)
	if err != nil {
		return err
	}
	if v != name {
		p.patch["name"] = v
	}
	current := ""
	if parent != nil {
		current = ix.pathString(*parent)
	}
	if v, err = e.field("Parent (empty: top level)", current, c); err != nil {
		return err
	}
	if v != current {
		if v == "" {
			p.patch["parent"] = nil
		} else {
			id, err := e.resolveNode(ix, kind, v)
			if err != nil {
				return err
			}
			p.patch["parent"] = id
		}
	}
	plural := map[string]string{"class": "classes", "location": "locations"}[kind]
	b, err := e.yesNoField("Container (holds only other "+plural+")", container)
	if err != nil {
		return err
	}
	if b != container {
		p.patch["container"] = b
	}
	return nil
}

func (e *env) editLocation(id string) error {
	var l location
	if err := e.get("/locations/"+id, nil, &l); err != nil {
		return err
	}
	ix, err := e.locationTree()
	if err != nil {
		return err
	}
	e.editTitle("location " + pathNames(l.Path))
	p := newPlan("/locations/" + id)
	if err := e.editTreeFields(p, ix, "location", l.Name, l.Parent, l.Container, completeLocations); err != nil {
		return err
	}
	if err := e.apply(p); err != nil {
		return err
	}
	return e.showAfterEdit("/locations/"+id, func(e *env, d json.RawMessage) error { return e.printLocationJSON(d) })
}

func (e *env) editClass(id string) error {
	var c class
	if err := e.get("/classes/"+id, nil, &c); err != nil {
		return err
	}
	ix, err := e.classTree()
	if err != nil {
		return err
	}
	e.editTitle("class " + pathNames(c.Path))
	p := newPlan("/classes/" + id)
	if err := e.editTreeFields(p, ix, "class", c.Name, c.Parent, c.Container, completeClasses); err != nil {
		return err
	}

	// Attribute assignments: a loop of NAME (assign or change) and -NAME
	// (remove), until an empty line.
	own := map[string]classAttribute{}
	var ownNames []string
	for _, ca := range c.Attributes {
		if !ca.Inherited {
			own[ca.Attribute.ID] = ca
			ownNames = append(ownNames, "-"+ca.Attribute.Name)
		}
	}
	fmt.Fprintln(e.stderr, "Attributes:")
	if len(c.Attributes) == 0 {
		fmt.Fprintln(e.stderr, "  (none)")
	}
	for _, ca := range c.Attributes {
		from := ""
		if ca.Inherited {
			from = "inherited from " + ix.pathString(ca.DefinedOnClass)
		}
		var notes []string
		if hasDefault(ca) {
			notes = append(notes, "default "+formatDefault(ca))
		}
		if ca.PerUnit {
			notes = append(notes, "per unit")
		}
		if ca.Required {
			notes = append(notes, "required")
		}
		fmt.Fprintf(e.stderr, "  %s  %s %s\n", ca.Attribute.Name, strings.Join(notes, ", "), from)
	}
	complete := func(e *env, args []string, cur string, full bool) []string {
		return append(completeAttributes(e, args, cur, full), ownNames...)
	}
	for {
		v, err := e.field("Attribute to assign or change (-NAME removes, Enter: done)", "", complete)
		if err != nil {
			return err
		}
		if v == "" {
			break
		}
		if name, remove := strings.CutPrefix(v, "-"); remove {
			a, err := e.resolveAttribute(name)
			if err != nil {
				fmt.Fprintln(e.stderr, err)
				continue
			}
			if _, ok := own[a.ID]; !ok {
				fmt.Fprintf(e.stderr, "%s isn't assigned on this class itself.\n", a.Name)
				continue
			}
			attrID := a.ID
			p.add("removed "+a.Name, func() error {
				_, err := e.do(http.MethodDelete, "/classes/"+id+"/attributes/"+attrID, nil)
				return err
			})
			continue
		}
		a, err := e.resolveAttribute(v)
		if err != nil {
			fmt.Fprintln(e.stderr, err)
			continue
		}
		cur := own[a.ID]
		curDefault := ""
		if hasDefault(cur) {
			curDefault = formatDefault(cur)
		}
		_, def, err := e.valueField("  Default (empty: none)", curDefault, *a)
		if err != nil {
			return err
		}
		perUnit, err := e.yesNoField("  Per unit (values on stock rows)", cur.PerUnit)
		if err != nil {
			return err
		}
		required, err := e.yesNoField("  Required", cur.Required)
		if err != nil {
			return err
		}
		attrID, body := a.ID, object{"default": def, "per_unit": perUnit, "required": required}
		p.add("assigned "+a.Name, func() error {
			_, err := e.do(http.MethodPut, "/classes/"+id+"/attributes/"+attrID, body)
			return err
		})
	}
	if err := e.apply(p); err != nil {
		return err
	}
	return e.showAfterEdit("/classes/"+id, func(e *env, d json.RawMessage) error { return e.printClassJSON(d) })
}

// editValues asks for the values of a class's attributes of one scope (item
// values, or with perUnit those of a stock row), and plans the changes on
// owner ("/items/ID" or "/stock/ID").
func (e *env) editValues(p *editPlan, owner, classID string, perUnit bool, values []value) error {
	var c class
	if err := e.get("/classes/"+classID, nil, &c); err != nil {
		return err
	}
	current := map[string]string{}
	for _, v := range values {
		if !v.IsDefault {
			current[v.Attribute.ID] = formatValue(v)
		}
	}
	header := false
	for _, ca := range c.Attributes {
		if ca.PerUnit != perUnit {
			continue
		}
		if !header {
			fmt.Fprintln(e.stderr, "Values (empty: none, or the default):")
			header = true
		}
		a := ca.Attribute
		label := "  " + a.Name
		switch {
		case hasDefault(ca):
			label += " [default " + formatDefault(ca) + "]"
		case ca.Required:
			label += " (required)"
		}
		if hint := valueHint(a); hint != "" {
			label += " " + hint
		}
		old := current[a.ID]
		var text string
		var v any
		for {
			var err error
			if text, v, err = e.valueField(label, old, a); err != nil {
				return err
			}
			if text != "" || !ca.Required || hasDefault(ca) {
				break
			}
			fmt.Fprintf(e.stderr, "%s is required.\n", a.Name)
		}
		switch {
		case text == old:
		case text == "":
			attrID := a.ID
			p.add("removed "+a.Name, func() error {
				_, err := e.do(http.MethodDelete, owner+"/values/"+attrID, nil)
				return err
			})
		default:
			attrID, body := a.ID, object{"value": v}
			p.add("set "+a.Name, func() error {
				_, err := e.do(http.MethodPut, owner+"/values/"+attrID, body)
				return err
			})
		}
	}
	return nil
}

func (e *env) editItem(id string) error {
	var it item
	if err := e.get("/items/"+id, nil, &it); err != nil {
		return err
	}
	e.editTitle("item " + it.Name + " (" + it.Code + ")")
	p := newPlan("/items/" + id)
	v, err := e.requiredField("Name", it.Name, nil)
	if err != nil {
		return err
	}
	if v != it.Name {
		p.patch["name"] = v
	}
	classPath := pathNames(it.Class.Path)
	if v, err = e.requiredField("Class", classPath, completeItemClasses); err != nil {
		return err
	}
	classID := it.Class.ID
	if v != classPath {
		if classID, err = e.resolveClass(v); err != nil {
			return err
		}
		p.patch["class"] = classID
	}
	// A unit can only be changed to another of the same quantity, never
	// added or removed, so it is only asked for when there is one.
	if it.Unit != nil {
		if err := e.editUnit(p, it.Unit, it.UnitLock); err != nil {
			return err
		}
	}
	if err := e.editValues(p, "/items/"+id, classID, false, it.Values); err != nil {
		return err
	}
	if err := e.apply(p); err != nil {
		return err
	}
	return e.showItem(id)
}

func (e *env) editStock(id string) error {
	var s stock
	if err := e.get("/stock/"+id, nil, &s); err != nil {
		return err
	}
	ix, err := e.locationTree()
	if err != nil {
		return err
	}
	e.editTitle("stock " + s.Code + " of " + s.Item.Name)
	p := newPlan("/stock/" + id)
	current := ""
	if s.Quantity != nil {
		current = formatQuantity(s.Quantity, s.Display)
	}
	for {
		v, err := e.field("Quantity (empty: uncounted)", current, nil)
		if err != nil {
			return err
		}
		if v == current {
			break
		}
		if v == "" {
			p.patch["quantity"] = nil
			break
		}
		q, err := e.parseQuantity(v, s.Item.Unit)
		if err == nil {
			p.patch["quantity"] = q
			break
		}
		fmt.Fprintln(e.stderr, err)
		current = v
	}
	place := ix.pathString(s.Location)
	v, err := e.requiredField("Location", place, completeStockLocations)
	if err != nil {
		return err
	}
	if v != place {
		if p.patch["location"], err = e.resolveLocation(v); err != nil {
			return err
		}
	}
	if err := e.editValues(p, "/stock/"+id, s.Item.Class, true, s.Values); err != nil {
		return err
	}
	if err := e.apply(p); err != nil {
		return err
	}
	return e.showAfterEdit("/stock/"+id, func(e *env, d json.RawMessage) error { return e.printStockJSON(d) })
}

func (e *env) editAttribute(id string) error {
	var a attribute
	if err := e.get("/attributes/"+id, nil, &a); err != nil {
		return err
	}
	e.editTitle("attribute " + a.Name)
	p := newPlan("/attributes/" + id)
	v, err := e.requiredField("Name", a.Name, nil)
	if err != nil {
		return err
	}
	if v != a.Name {
		p.patch["name"] = v
	}
	datatype := a.Datatype
	for {
		if v, err = e.requiredField("Type (text, integer, float, date, boolean, url, choice)", datatype, datatypes); err != nil {
			return err
		}
		if strings.Contains(" text integer float date boolean url choice ", " "+v+" ") {
			break
		}
		fmt.Fprintf(e.stderr, "%q is not a type.\n", v)
		datatype = v
	}
	if v != a.Datatype {
		p.patch["datatype"] = v
	}
	datatype = v
	// As for items, the unit is only asked for when there is one.
	if a.Unit != nil && (datatype == "integer" || datatype == "float") {
		if err := e.editUnit(p, a.Unit, a.UnitLock); err != nil {
			return err
		}
	}
	if datatype == "choice" {
		if err := e.editOptions(p, a); err != nil {
			return err
		}
	}
	if err := e.apply(p); err != nil {
		return err
	}
	return e.showAfterEdit("/attributes/"+id, func(e *env, d json.RawMessage) error { return e.printAttributeJSON(d) })
}

// editUnit asks for the unit of an attribute or item, which can change to
// another unit of the same quantity, and for its Unit lock.
func (e *env) editUnit(p *editPlan, u *unit, lock bool) error {
	current, err := e.unitLabel(u)
	if err != nil {
		return err
	}
	for {
		v, err := e.requiredField("Unit", current, completeQuantityUnits(u.Quantity.ID))
		if err != nil {
			return err
		}
		if v == current {
			break
		}
		nu, err := e.resolveUnit(v)
		if err == nil {
			p.patch["unit"] = nu.ID
			break
		}
		fmt.Fprintln(e.stderr, err)
		current = v
	}
	for {
		v, err := e.requiredField("Unit lock: always show in this unit (yes/no)", yesNo(lock), words("yes", "no"))
		if err != nil {
			return err
		}
		if b, ok := parseYesNo(v); ok {
			if b != lock {
				p.patch["unit_lock"] = b
			}
			return nil
		}
		fmt.Fprintf(e.stderr, "%q is not yes or no.\n", v)
	}
}

// editOptions is a loop over the options of a choice attribute: NAME adds,
// -NAME removes, OLD=NEW renames, an empty line ends it.
func (e *env) editOptions(p *editPlan, a attribute) error {
	byName := map[string]option{}
	var names, removable []string
	for _, o := range a.Options {
		byName[strings.ToLower(o.Name)] = o
		names = append(names, o.Name)
		removable = append(removable, "-"+o.Name)
	}
	if len(names) == 0 {
		fmt.Fprintln(e.stderr, "Options: (none)")
	} else {
		fmt.Fprintf(e.stderr, "Options: %s\n", strings.Join(names, ", "))
	}
	complete := func(*env, []string, string, bool) []string {
		var out []string
		for _, n := range names {
			out = append(out, n+"=")
		}
		return append(out, removable...)
	}
	for {
		v, err := e.field("Option (NAME adds, -NAME removes, OLD=NEW renames, Enter: done)", "", complete)
		if err != nil {
			return err
		}
		switch old, renamed, isRename := strings.Cut(v, "="); {
		case v == "":
			return nil
		case strings.HasPrefix(v, "-"):
			o, ok := byName[strings.ToLower(strings.TrimSpace(v[1:]))]
			if !ok {
				fmt.Fprintf(e.stderr, "There is no option %q.\n", v[1:])
				continue
			}
			p.add("removed option "+o.Name, func() error {
				_, err := e.do(http.MethodDelete, "/options/"+o.ID, nil)
				return err
			})
		case isRename:
			o, ok := byName[strings.ToLower(strings.TrimSpace(old))]
			renamed = strings.TrimSpace(renamed)
			if !ok || renamed == "" {
				fmt.Fprintf(e.stderr, "Write OLD=NEW with an existing option.\n")
				continue
			}
			p.add("renamed option "+o.Name, func() error {
				_, err := e.do(http.MethodPatch, "/options/"+o.ID, object{"name": renamed})
				return err
			})
		default:
			name := v
			attrID := a.ID
			p.add("added option "+name, func() error {
				_, err := e.do(http.MethodPost, "/attributes/"+attrID+"/options", object{"name": name})
				return err
			})
		}
	}
}

func (e *env) editAccount(id string) error {
	var a account
	if err := e.get("/accounts/"+id, nil, &a); err != nil {
		return err
	}
	if a.Deleted {
		return errors.New("a deleted account can't be changed")
	}
	e.editTitle("account " + a.Email)
	p := newPlan("/accounts/" + id)
	v, err := e.requiredField("Email", a.Email, nil)
	if err != nil {
		return err
	}
	if v != a.Email {
		p.patch["email"] = v
	}
	short := map[string]string{"none": "none", "read_only": "read", "read_write": "write"}
	for _, f := range []struct{ key, label, current string }{
		{"data_privilege", "Data privilege (none, read, write)", a.DataPrivilege},
		{"model_privilege", "Model privilege", a.ModelPrivilege},
		{"account_privilege", "Account privilege", a.AccountPrivilege},
		{"history_privilege", "History privilege (none, read)", a.HistoryPrivilege},
	} {
		text := short[f.current]
		for {
			v, err := e.requiredField(f.label, text, privilegeList)
			if err != nil {
				return err
			}
			priv, err := parsePrivilege(v)
			if err == nil {
				if priv != f.current {
					p.patch[f.key] = priv
				}
				break
			}
			fmt.Fprintln(e.stderr, err)
			text = v
		}
	}
	for {
		v, err := e.field("Password (keep, set or remove)", "keep", words("keep", "set", "remove"))
		if err != nil {
			return err
		}
		switch strings.ToLower(v) {
		case "keep", "":
		case "set":
			pw, err := e.newPassword("New password: ")
			if err != nil {
				return err
			}
			p.patch["password"] = pw
		case "remove":
			p.patch["password"] = nil
		default:
			fmt.Fprintln(e.stderr, "Answer keep, set or remove.")
			continue
		}
		break
	}
	if err := e.apply(p); err != nil {
		return err
	}
	return e.showAfterEdit("/accounts/"+id, func(e *env, d json.RawMessage) error { return printAccountJSON(e, d) })
}

// editCreated opens the object an add command just created in its form.
func (e *env) editCreated(data json.RawMessage, edit func(*env, string) error) error {
	var created struct {
		ID string `json:"id"`
	}
	if err := decode(data, &created); err != nil {
		return err
	}
	return edit(e, created.ID)
}
