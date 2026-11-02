package cli

import (
	"encoding/json"
	"fmt"
	"net/http"
	"slices"
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
	complete := func(e *env, _ []string, cur string, _ bool) []string { return valueCandidates(a, cur) }
	for {
		text, err := e.field(label, current, complete)
		if err != nil || text == "" {
			return text, nil, err
		}
		v, err := parseValue(a, text)
		if err == nil {
			return text, v, nil
		}
		fmt.Fprintln(e.stderr, err)
		current = text
	}
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
	e.editTitle("class " + pathNames(c.Path) + " (its attributes change with 'wtf class attribute')")
	p := newPlan("/classes/" + id)
	if err := e.editTreeFields(p, ix, "class", c.Name, c.Parent, c.Container, completeClasses); err != nil {
		return err
	}
	if err := e.apply(p); err != nil {
		return err
	}
	return e.showAfterEdit("/classes/"+id, func(e *env, d json.RawMessage) error { return e.printClassJSON(d) })
}

// editValues asks for the values of class c's attributes of scope ("item"
// or "stock"), with the values vals and those of them that follow the
// default, defaulted, and plans the changes in the patch: values to set or
// remove, and default, those to follow the default again ("default" as the
// answer). Files are uploaded with 'wtf file put', and left alone here.
func (e *env) editValues(p *editPlan, c class, scope string, vals values, defaulted []string) error {
	set := object{}
	var back []string
	header := false
	for _, a := range c.Attributes {
		if a.Scope != scope || a.Type == "attachment" {
			continue
		}
		if !header {
			fmt.Fprintln(e.stderr, "Values (empty: none; \"default\": the class's default):")
			header = true
		}
		label := "  " + a.Name
		switch {
		case a.hasDefault():
			label += " [default " + formatJSONValue(a.Default) + "]"
		case a.Required:
			label += " (required)"
		}
		if hint := valueHint(a); hint != "" {
			label += " " + hint
		}
		old := ""
		if raw, ok := vals[a.Name]; ok {
			old = formatJSONValue(raw)
			if slices.Contains(defaulted, a.Name) {
				old = "default"
			}
		}
		for {
			text, err := e.field(label, old, func(e *env, _ []string, cur string, _ bool) []string {
				return append(valueCandidates(a, cur), "default")
			})
			if err != nil {
				return err
			}
			switch {
			case text == old:
			case text == "default":
				if !a.hasDefault() {
					fmt.Fprintf(e.stderr, "%s has no default.\n", a.Name)
					continue
				}
				back = append(back, a.Name)
			case text == "":
				if a.Required && !a.hasDefault() {
					fmt.Fprintf(e.stderr, "%s is required.\n", a.Name)
					continue
				}
				set[a.Name] = nil
			default:
				v, err := parseValue(a, text)
				if err != nil {
					fmt.Fprintln(e.stderr, err)
					old = text
					continue
				}
				set[a.Name] = v
			}
			break
		}
	}
	if len(set) > 0 {
		p.patch["values"] = set
	}
	if len(back) > 0 {
		p.patch["default"] = back
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
	unit := ""
	if it.Unit != nil {
		unit = *it.Unit
	}
	if v, err = e.field("Unit of its stock (empty: pieces)", unit, nil); err != nil {
		return err
	}
	if v != unit {
		p.patch["unit"] = orNil(v)
	}
	c, err := e.classDetail(classID)
	if err != nil {
		return err
	}
	if err := e.editValues(p, c, "item", it.Values, it.Defaulted); err != nil {
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
	if s.Amount != nil {
		current = s.Amount.String()
	}
	for {
		v, err := e.field("Amount (empty: uncounted)", current, nil)
		if err != nil {
			return err
		}
		if v == current {
			break
		}
		if v == "" {
			p.patch["amount"] = nil
			break
		}
		q, err := e.parseAmount(v, s.Item.Unit)
		if err == nil {
			p.patch["amount"] = q
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
	for _, f := range []struct {
		label, key string
		current    *string
	}{{"Reference (empty: none)", "reference", s.Reference}, {"Serial (empty: none)", "serial", s.Serial}} {
		old := ""
		if f.current != nil {
			old = *f.current
		}
		v, err := e.field(f.label, old, nil)
		if err != nil {
			return err
		}
		if v != old {
			p.patch[f.key] = orNil(v)
		}
	}
	c, err := e.classDetail(s.Item.Class)
	if err != nil {
		return err
	}
	if err := e.editValues(p, c, "stock", s.Values, s.Defaulted); err != nil {
		return err
	}
	if err := e.apply(p); err != nil {
		return err
	}
	return e.showAfterEdit("/stock/"+id, func(e *env, d json.RawMessage) error { return e.printStockJSON(d) })
}

// orNil is nil for "", for a patch that clears a field.
func orNil(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func (e *env) editAccount(id string) error {
	var a account
	if err := e.get("/accounts/"+id, nil, &a); err != nil {
		return err
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
	for text := a.Role; ; {
		v, err := e.requiredField("Role (viewer, user, admin)", text, roleList)
		if err != nil {
			return err
		}
		role, err := parseRole(v)
		if err == nil {
			if role != a.Role {
				p.patch["role"] = role
			}
			break
		}
		fmt.Fprintln(e.stderr, err)
		text = v
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
	if _, ok := p.patch["password"]; ok {
		end, err := e.yesNoField("Log out its sessions too", true)
		if err != nil {
			return err
		}
		p.patch["end_sessions"] = end
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
	if err := e.decode(data, &created); err != nil {
		return err
	}
	return edit(e, created.ID)
}
