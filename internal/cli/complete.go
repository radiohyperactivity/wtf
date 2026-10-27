package cli

import (
	"flag"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/radiohyperactivity/wtf/internal/prompt"
)

// param describes a positional argument, for prompting and completion.
type param struct {
	name     string    // label in prompts, e.g. "Location"
	complete completer // nil: free text
	files    bool      // a local file name
	optional bool      // prompted only in an interactive session
	variadic bool      // takes the rest of the arguments
}

// completer returns the candidates for cur. args are the positional
// arguments before it. full asks for whole paths of tree nodes (for the
// picker and PowerShell) instead of one path segment at a time. Candidates
// ending in "/" or "=" are partial: completion continues after them.
type completer func(e *env, args []string, cur string, full bool) []string

func arg(name string, c completer) param      { return param{name: name, complete: c} }
func optional(name string, c completer) param { return param{name: name, complete: c, optional: true} }
func rest(name string, c completer) param     { return param{name: name, complete: c, variadic: true} }
func fileArg(name string) param               { return param{name: name, complete: completeFiles, files: true} }

// words completes from a fixed list.
func words(list ...string) completer {
	return func(*env, []string, string, bool) []string { return list }
}

func completeLocations(e *env, _ []string, cur string, full bool) []string {
	ix, err := e.locationTree()
	if err != nil {
		return nil
	}
	return treeCandidates(ix, cur, full, false)
}

func completeClasses(e *env, _ []string, cur string, full bool) []string {
	ix, err := e.classTree()
	if err != nil {
		return nil
	}
	return treeCandidates(ix, cur, full, false)
}

// completeStockLocations completes the locations that can hold stock: not
// containers, though their paths still lead through them ("Garage/").
func completeStockLocations(e *env, _ []string, cur string, full bool) []string {
	ix, err := e.locationTree()
	if err != nil {
		return nil
	}
	return treeCandidates(ix, cur, full, true)
}

// completeItemClasses completes the classes that can have items.
func completeItemClasses(e *env, _ []string, cur string, full bool) []string {
	ix, err := e.classTree()
	if err != nil {
		return nil
	}
	return treeCandidates(ix, cur, full, true)
}

// treeCandidates completes a path: every full path, or the children of the
// path typed so far ("Garage/" → "Garage/Shelf 1", "Garage/Shelf 2/", …).
// With noContainers, containers are only offered as a way through
// ("Garage/"), not as a choice of their own.
func treeCandidates(ix *treeIndex, cur string, full, noContainers bool) []string {
	var out []string
	if full {
		for id, n := range ix.byID {
			if !noContainers || !n.Container {
				out = append(out, ix.pathString(id))
			}
		}
		sort.Strings(out)
		return out
	}
	nodes := ix.roots
	dir := ""
	if i := strings.LastIndex(cur, "/"); i >= 0 {
		dir = cur[:i+1]
		nodes = nil
		for _, n := range ix.walk(strings.Split(cur[:i], "/")) {
			nodes = append(nodes, n.Children...)
		}
	}
	for _, n := range nodes {
		p := dir + n.Name
		if !noContainers || !n.Container {
			out = append(out, p)
		}
		if len(n.Children) > 0 {
			out = append(out, p+"/")
		}
	}
	return out
}

// walk returns the nodes at a path from a root, ignoring case.
func (ix *treeIndex) walk(segments []string) []*node {
	level := ix.roots
	var found []*node
	for i, s := range segments {
		found = nil
		for _, n := range level {
			if strings.EqualFold(n.Name, strings.TrimSpace(s)) {
				found = append(found, n)
			}
		}
		if i < len(segments)-1 {
			level = nil
			for _, n := range found {
				level = append(level, n.Children...)
			}
		}
	}
	return found
}

func completeItems(e *env, _ []string, cur string, _ bool) []string {
	q := url.Values{"limit": {"100"}}
	if strings.TrimSpace(cur) != "" {
		q.Set("search", cur)
	}
	var p page[itemRow]
	if e.get("/items", q, &p) != nil {
		return nil
	}
	var out []string
	for _, r := range p.Rows {
		out = append(out, r.Name)
	}
	return out
}

// completeStock completes items, and after "ITEM@" the item's locations.
func completeStock(e *env, args []string, cur string, full bool) []string {
	itemRef, _, at := strings.Cut(cur, "@")
	if !at {
		return completeItems(e, args, cur, full)
	}
	id, err := e.resolveItem(itemRef)
	if err != nil {
		return nil
	}
	var it item
	if e.get("/items/"+id, nil, &it) != nil {
		return nil
	}
	ix, err := e.locationTree()
	if err != nil {
		return nil
	}
	var out []string
	for _, s := range it.Stock {
		out = append(out, itemRef+"@"+ix.pathString(s.Location))
	}
	return out
}

func completeAttributes(e *env, _ []string, _ string, _ bool) []string {
	list, err := e.attributes()
	if err != nil {
		return nil
	}
	var out []string
	for _, a := range list {
		out = append(out, a.Name)
	}
	return out
}

// completeOptionsOf completes the options of the attribute in args[i].
func completeOptionsOf(i int) completer {
	return func(e *env, args []string, _ string, _ bool) []string {
		if i >= len(args) {
			return nil
		}
		a, err := e.resolveAttribute(args[i])
		if err != nil {
			return nil
		}
		return e.optionNames(a.ID)
	}
}

func (e *env) optionNames(attributeID string) []string {
	var options []option
	if e.get("/attributes/"+attributeID+"/options", nil, &options) != nil {
		return nil
	}
	var out []string
	for _, o := range options {
		out = append(out, o.Name)
	}
	return out
}

// completeValueOf completes a value of the attribute in args[i].
func completeValueOf(i int) completer {
	return func(e *env, args []string, cur string, _ bool) []string {
		if i >= len(args) {
			return nil
		}
		a, err := e.resolveAttribute(args[i])
		if err != nil {
			return nil
		}
		return e.valueCandidates(a, cur)
	}
}

// valueCandidates are option names, yes/no, date words, or the typed number
// with each unit of the attribute's unit family.
func (e *env) valueCandidates(a *attribute, cur string) []string {
	switch a.Datatype {
	case "choice":
		return e.optionNames(a.ID)
	case "boolean":
		return []string{"yes", "no"}
	case "date":
		return []string{"today", "yesterday", "tomorrow"}
	case "integer", "float":
		if a.Unit == nil {
			return nil
		}
		m := numberPattern.FindStringSubmatch(cur)
		if m == nil || m[2] != "" {
			return nil
		}
		units, err := e.familyUnits(a.Unit)
		if err != nil {
			return nil
		}
		var out []string
		for _, u := range units {
			out = append(out, strings.TrimSpace(cur)+u.Symbol)
		}
		return out
	}
	return nil
}

// completeAssignment completes --value ATTRIBUTE=VALUE.
func completeAssignment(e *env, _ []string, cur string, _ bool) []string {
	name, value, ok := strings.Cut(cur, "=")
	if !ok {
		var out []string
		for _, n := range completeAttributes(e, nil, "", false) {
			out = append(out, n+"=")
		}
		return out
	}
	a, err := e.resolveAttribute(name)
	if err != nil {
		return nil
	}
	var out []string
	for _, v := range e.valueCandidates(a, value) {
		out = append(out, name+"="+v)
	}
	return out
}

func completeFamilies(e *env, _ []string, _ string, _ bool) []string {
	list, err := e.unitFamilies()
	if err != nil {
		return nil
	}
	var out []string
	for _, f := range list {
		out = append(out, f.Name)
	}
	return out
}

func completeQuantities(e *env, _ []string, _ string, _ bool) []string {
	if err := e.loadQuantities(); err != nil {
		return nil
	}
	var out []string
	for _, q := range e.cache.quantities {
		out = append(out, q.Name)
	}
	return out
}

// completeUnits completes units as resolveUnit takes them: by symbol, with
// the family where several families share it ("B (Binary bytes)").
func completeUnits(e *env, _ []string, _ string, _ bool) []string {
	return e.unitRefs(0)
}

// completeQuantityUnits completes the units of one quantity, for changing an
// attribute's or item's unit.
func completeQuantityUnits(quantityID int) completer {
	return func(e *env, _ []string, _ string, _ bool) []string { return e.unitRefs(quantityID) }
}

// unitRefs are the units of a quantity (0: of all), named as unitRef does.
func (e *env) unitRefs(quantityID int) []string {
	families, err := e.unitFamilies()
	if err != nil {
		return nil
	}
	var all []unit
	for _, f := range families {
		all = append(all, f.Units...)
	}
	var out []string
	for i := range all {
		if quantityID == 0 || all[i].Quantity.ID == quantityID {
			out = append(out, unitRef(all, &all[i]))
		}
	}
	return out
}

func completeAccounts(e *env, _ []string, _ string, _ bool) []string {
	var list []account
	if e.get("/accounts", nil, &list) != nil {
		return nil
	}
	var out []string
	for _, a := range list {
		out = append(out, a.Email)
	}
	return out
}

func completeProfiles(e *env, _ []string, _ string, _ bool) []string {
	if e.config == nil {
		return nil
	}
	return e.config.profileNames()
}

// completeTargetOf completes the object named after the attachment target
// type in args[i].
func completeTargetOf(i int) completer {
	return func(e *env, args []string, cur string, full bool) []string {
		if i >= len(args) {
			return nil
		}
		switch args[i] {
		case "item":
			return completeItems(e, args, cur, full)
		case "stock":
			return completeStock(e, args, cur, full)
		case "location":
			return completeLocations(e, args, cur, full)
		case "class":
			return completeClasses(e, args, cur, full)
		}
		return nil
	}
}

// completeFiles completes local file names (in prompts; shells use their
// own file completion).
func completeFiles(_ *env, _ []string, cur string, _ bool) []string {
	matches, _ := filepath.Glob(cur + "*")
	var out []string
	for _, m := range matches {
		if fi, err := os.Stat(m); err == nil && fi.IsDir() {
			m += string(filepath.Separator)
		}
		out = append(out, m)
	}
	return out
}

var (
	datatypes     = words("text", "integer", "float", "date", "boolean", "url", "choice")
	privilegeList = words("none", "read", "write")
	targetTypes   = words("item", "stock", "location", "class")
)

// candidates returns the completions for the last of words (the arguments
// after "wtf"), unfiltered, and whether file names should be completed.
func (e *env) candidates(words []string, full bool) ([]string, bool) {
	cur, prev := words[len(words)-1], words[:len(words)-1]

	// Global flags before the command.
	i := 0
globals:
	for i < len(prev) {
		switch w := prev[i]; {
		case w == "--json" || w == "-json" || strings.HasPrefix(w, "--profile=") || strings.HasPrefix(w, "--server="):
			i++
		case w == "--profile" || w == "-profile" || w == "--server" || w == "-server":
			if i+1 == len(prev) {
				if strings.HasSuffix(w, "profile") {
					return completeProfiles(e, nil, cur, full), false
				}
				return nil, false
			}
			i += 2
		default:
			break globals
		}
	}
	prev = prev[i:]
	if len(prev) == 0 {
		if strings.HasPrefix(cur, "-") {
			return []string{"--json", "--profile", "--server"}, false
		}
		var out []string
		for _, c := range topLevel {
			out = append(out, c.name)
		}
		for _, g := range groups {
			out = append(out, g.name)
		}
		return append(out, "help"), false
	}
	if prev[0] == "help" {
		return nil, false
	}
	if len(prev) == 1 {
		for _, g := range groups {
			if g.name == prev[0] {
				var out []string
				for _, c := range g.commands {
					out = append(out, c.name)
				}
				return out, false
			}
		}
	}
	cmd, _, after, ok := lookup(prev)
	if !ok || cmd == nil {
		return nil, false
	}

	fs := flag.NewFlagSet("", flag.ContinueOnError)
	fs.Bool("json", false, "")
	fs.String("profile", "", "")
	fs.String("server", "", "")
	cmd.setup(fs)

	var positional []string
	expect := ""
	for _, w := range after {
		switch {
		case expect != "":
			expect = ""
		case strings.HasPrefix(w, "-") && w != "-" && !negativeNumber.MatchString(w):
			if takesValue(fs, w) {
				expect = strings.TrimLeft(w, "-")
			}
		default:
			positional = append(positional, w)
		}
	}
	flagValue := func(name, value, prefix string) ([]string, bool) {
		if name == "profile" {
			return completeProfiles(e, nil, value, full), false
		}
		p, ok := cmd.flags[name]
		if !ok || p.complete == nil {
			return nil, false
		}
		if p.files {
			return nil, true
		}
		var out []string
		for _, c := range p.complete(e, positional, value, full) {
			out = append(out, prefix+c)
		}
		return out, false
	}
	if expect != "" {
		return flagValue(expect, cur, "")
	}
	if strings.HasPrefix(cur, "-") && !negativeNumber.MatchString(cur) {
		if name, value, ok := strings.Cut(strings.TrimLeft(cur, "-"), "="); ok {
			return flagValue(name, value, cur[:len(cur)-len(value)])
		}
		var out []string
		fs.VisitAll(func(f *flag.Flag) { out = append(out, "--"+f.Name) })
		return out, false
	}
	var p *param
	switch {
	case len(positional) < len(cmd.params):
		p = &cmd.params[len(positional)]
	case len(cmd.params) > 0 && cmd.params[len(cmd.params)-1].variadic:
		p = &cmd.params[len(cmd.params)-1]
	}
	if p == nil || p.complete == nil {
		return nil, false
	}
	if p.files {
		return nil, true
	}
	return p.complete(e, positional, cur, full), false
}

// filterCandidates keeps the candidates that start with cur, ignoring case.
// When none does, a single candidate containing cur is kept: the shell
// replaces the word with it ("drill" → "Cordless drill").
func filterCandidates(cands []string, cur string) []string {
	if out := prompt.MatchPrefix(cands, cur); len(out) > 0 {
		return dedupe(out)
	}
	if out := dedupe(prompt.MatchSubstring(cands, cur)); len(out) == 1 {
		return out
	}
	return nil
}

func dedupe(list []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, s := range list {
		if !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	return out
}

// partial reports whether completion continues after a candidate.
func partial(c string) bool { return strings.HasSuffix(c, "/") || strings.HasSuffix(c, "=") }
