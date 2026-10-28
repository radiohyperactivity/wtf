package cli

import (
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"regexp"
	"sort"
	"strings"
	"text/tabwriter"

	"github.com/radiohyperactivity/wtf/internal/client"
)

// cache holds what is fetched at most once per run: the trees, the
// attributes and the units of each quantity.
type cache struct {
	locations, classes *treeIndex
	attributes         []attribute
	families           []unitFamily
	quantities         []quantity
	units              map[string][]unit // by quantity id
}

// treeIndex is a class or location tree with lookups by id.
type treeIndex struct {
	roots []*node
	byID  map[string]*node
}

func newTreeIndex(t tree) *treeIndex {
	ix := &treeIndex{roots: t.Tree, byID: map[string]*node{}}
	var walk func([]*node)
	walk = func(nodes []*node) {
		for _, n := range nodes {
			ix.byID[n.ID] = n
			walk(n.Children)
		}
	}
	walk(t.Tree)
	return ix
}

// path returns the names from the root to the node, or nil if unknown.
func (ix *treeIndex) path(id string) []string {
	var names []string
	for n := ix.byID[id]; n != nil; {
		names = append([]string{n.Name}, names...)
		if n.Parent == nil {
			break
		}
		n = ix.byID[*n.Parent]
	}
	return names
}

// pathString is path joined with "/", or the id if unknown. Names can't
// contain "/" (the server rejects it), so a path always means one thing.
func (ix *treeIndex) pathString(id string) string {
	if p := ix.path(id); p != nil {
		return strings.Join(p, "/")
	}
	return id
}

// find returns the nodes whose path ends with the names in ref: "Shelf 2"
// and "Garage/Shelf 2" match at any depth. There is no marker for "from
// the root"; when a path matches several nodes, the caller reports the
// ambiguity with suggestions.
func (ix *treeIndex) find(ref string) []*node {
	segments := strings.Split(strings.TrimSuffix(strings.TrimSpace(ref), "/"), "/")
	for i := range segments {
		segments[i] = strings.TrimSpace(segments[i])
	}
	var matches []*node
	for _, n := range ix.byID {
		p := ix.path(n.ID)
		if len(p) < len(segments) {
			continue
		}
		tail := p[len(p)-len(segments):]
		ok := true
		for i := range segments {
			if !strings.EqualFold(tail[i], segments[i]) {
				ok = false
				break
			}
		}
		if ok {
			matches = append(matches, n)
		}
	}
	return matches
}

// suggestion is the shortest way to name a node uniquely: the last names of
// its path that match nothing else, else its label code, else its id.
func (ix *treeIndex) suggestion(n *node) string {
	p := ix.path(n.ID)
	for k := 1; k <= len(p); k++ {
		if s := strings.Join(p[len(p)-k:], "/"); len(ix.find(s)) == 1 {
			return s
		}
	}
	if n.Code != "" {
		return n.Code
	}
	return n.ID
}

var uuidPattern = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

func isUUID(s string) bool { return uuidPattern.MatchString(s) }

// normalizeCode applies Crockford's reading rules (I and L are 1, O is 0,
// hyphens are ignored) and returns the code, or "" if s can't be one.
func normalizeCode(s string) string {
	s = strings.ToUpper(strings.ReplaceAll(strings.TrimSpace(s), "-", ""))
	s = strings.NewReplacer("I", "1", "L", "1", "O", "0").Replace(s)
	if len(s) < 4 || len(s) > 7 {
		return ""
	}
	for _, r := range s {
		if !strings.ContainsRune("0123456789ABCDEFGHJKMNPQRSTVWXYZ", r) {
			return ""
		}
	}
	return s
}

// lookupCode resolves a label code; ok is false when ref isn't a known code.
func (e *env) lookupCode(ref string) (codeResult, bool, error) {
	code := normalizeCode(ref)
	if code == "" {
		return codeResult{}, false, nil
	}
	data, err := e.api.Get(e.ctx, "/codes/"+code, nil)
	var p *client.Problem
	if errors.As(err, &p) && (p.Status == http.StatusNotFound || p.Status == http.StatusBadRequest) {
		return codeResult{}, false, nil
	}
	if err != nil {
		return codeResult{}, false, err
	}
	var r codeResult
	if err := decode(data, &r); err != nil {
		return codeResult{}, false, err
	}
	return r, true, nil
}

// get fetches path and decodes it into v.
func (e *env) get(path string, query url.Values, v any) error {
	data, err := e.api.Get(e.ctx, path, query)
	if err != nil {
		return err
	}
	return decode(data, v)
}

func (e *env) locationTree() (*treeIndex, error) {
	if e.cache.locations == nil {
		t, err := e.cachedTree("/locations", "locations")
		if err != nil {
			return nil, err
		}
		e.cache.locations = newTreeIndex(t)
	}
	return e.cache.locations, nil
}

func (e *env) classTree() (*treeIndex, error) {
	if e.cache.classes == nil {
		t, err := e.cachedTree("/classes", "classes")
		if err != nil {
			return nil, err
		}
		e.cache.classes = newTreeIndex(t)
	}
	return e.cache.classes, nil
}

// ambiguous is the error for a name with several matches.
func ambiguous(kind, ref string, candidates []string) error {
	sort.Strings(candidates)
	return fmt.Errorf("%s %q is ambiguous; it could be:\n  %s", kind, ref, strings.Join(candidates, "\n  "))
}

// resolveTreeNode resolves a location or class reference by id or path.
func resolveTreeNode(ix *treeIndex, kind, ref string) (string, error) {
	if isUUID(ref) {
		return strings.ToLower(ref), nil
	}
	matches := ix.find(ref)
	switch len(matches) {
	case 0:
		if strings.HasPrefix(strings.TrimSpace(ref), "/") {
			return "", fmt.Errorf("no %s named %q (paths don't start with \"/\")", kind, ref)
		}
		return "", fmt.Errorf("no %s named %q", kind, ref)
	case 1:
		return matches[0].ID, nil
	}
	return "", ix.ambiguity(kind, ref, matches)
}

// ambiguity is the error for a path that matches several nodes. It lists
// each with a way to name it uniquely.
func (ix *treeIndex) ambiguity(kind, ref string, matches []*node) error {
	sort.Slice(matches, func(i, j int) bool { return ix.pathString(matches[i].ID) < ix.pathString(matches[j].ID) })
	var b strings.Builder
	fmt.Fprintf(&b, "%s %q is ambiguous. Name one of them like this:\n", kind, ref)
	tw := tabwriter.NewWriter(&b, 0, 0, 3, ' ', 0)
	for _, n := range matches {
		fmt.Fprintf(tw, "  %s\tfor %s\n", ix.suggestion(n), ix.pathString(n.ID))
	}
	tw.Flush()
	return errors.New(strings.TrimRight(b.String(), "\n"))
}

// resolveLocation returns the id of a location given by id, code or path.
func (e *env) resolveLocation(ref string) (string, error) {
	if isUUID(ref) {
		return strings.ToLower(ref), nil
	}
	ix, err := e.locationTree()
	if err != nil {
		return "", err
	}
	if matches := ix.find(ref); len(matches) == 1 {
		return matches[0].ID, nil
	}
	if r, ok, err := e.lookupCode(ref); err != nil {
		return "", err
	} else if ok && r.Type == "location" {
		var l location
		return l.ID, decode(r.Object, &l)
	}
	return e.resolveNode(ix, "location", ref)
}

// resolveClass returns the id of a class given by id or path.
func (e *env) resolveClass(ref string) (string, error) {
	if isUUID(ref) {
		return strings.ToLower(ref), nil
	}
	ix, err := e.classTree()
	if err != nil {
		return "", err
	}
	return e.resolveNode(ix, "class", ref)
}

// resolveNode is resolveTreeNode, but on a terminal it asks which of several
// matches is meant instead of failing.
func (e *env) resolveNode(ix *treeIndex, kind, ref string) (string, error) {
	if matches := ix.find(ref); len(matches) > 1 && !isUUID(ref) {
		sort.Slice(matches, func(i, j int) bool { return ix.pathString(matches[i].ID) < ix.pathString(matches[j].ID) })
		var labels []string
		for _, n := range matches {
			label := ix.pathString(n.ID)
			if n.Code != "" {
				label = n.Code + "  " + label
			}
			labels = append(labels, label)
		}
		if i, ok, err := e.choose(fmt.Sprintf("Which %s %q? ", kind, ref), labels); ok {
			if err != nil {
				return "", err
			}
			return matches[i].ID, nil
		}
	}
	return resolveTreeNode(ix, kind, ref)
}

// choose asks which of several matches is meant. ok is false without a
// terminal; the caller then reports the ambiguity instead.
func (e *env) choose(question string, labels []string) (int, bool, error) {
	if e.term == nil {
		return -1, false, nil
	}
	i, err := e.term.Choose(question, labels)
	return i, true, err
}

// resolveItem returns the id of an item given by id, code or exact name. The
// code of a stock row also names its item.
func (e *env) resolveItem(ref string) (string, error) {
	if isUUID(ref) {
		return strings.ToLower(ref), nil
	}
	var p page[itemRow]
	if err := e.get("/items", url.Values{"search": {ref}, "limit": {"1000"}}, &p); err != nil {
		return "", err
	}
	var exact []itemRow
	for _, r := range p.Rows {
		if strings.EqualFold(r.Name, strings.TrimSpace(ref)) {
			exact = append(exact, r)
		}
	}
	if len(exact) == 1 {
		return exact[0].ID, nil
	}
	if len(exact) == 0 {
		if r, ok, err := e.lookupCode(ref); err != nil {
			return "", err
		} else if ok {
			switch r.Type {
			case "item":
				var it item
				return it.ID, decode(r.Object, &it)
			case "stock":
				var s stock
				return s.Item.ID, decode(r.Object, &s)
			}
			return "", fmt.Errorf("%s is the code of a %s, not of an item", normalizeCode(ref), r.Type)
		}
	}
	if len(exact) > 1 {
		var candidates []string
		for _, r := range exact {
			candidates = append(candidates, r.Code+"  "+r.Name+e.classSuffix(r.Class))
		}
		if i, ok, err := e.choose(fmt.Sprintf("Which item %q? ", ref), candidates); ok {
			if err != nil {
				return "", err
			}
			return exact[i].ID, nil
		}
		return "", ambiguous("item", ref, candidates)
	}
	msg := fmt.Sprintf("no item named %q", ref)
	if len(p.Rows) > 0 {
		var names []string
		for i, r := range p.Rows {
			if i == 10 {
				names = append(names, "…")
				break
			}
			names = append(names, r.Code+"  "+r.Name)
		}
		msg += "; did you mean:\n  " + strings.Join(names, "\n  ")
	}
	return "", errors.New(msg)
}

// classSuffix is " (Class/Path)" for candidate lists.
func (e *env) classSuffix(classID string) string {
	ix, err := e.classTree()
	if err != nil {
		return ""
	}
	return " (" + ix.pathString(classID) + ")"
}

// resolveStock returns the id of a stock row given by id or code, as
// "item@location", or as an item that has exactly one stock row.
func (e *env) resolveStock(ref string) (string, error) {
	if isUUID(ref) {
		return strings.ToLower(ref), nil
	}
	if r, ok, err := e.lookupCode(ref); err != nil {
		return "", err
	} else if ok && r.Type == "stock" {
		var s stock
		return s.ID, decode(r.Object, &s)
	}
	itemRef, locationRef, at := strings.Cut(ref, "@")
	itemID, err := e.resolveItem(itemRef)
	if err != nil {
		return "", err
	}
	var it item
	if err := e.get("/items/"+itemID, nil, &it); err != nil {
		return "", err
	}
	rows := it.Stock
	if at {
		locationID, err := e.resolveLocation(locationRef)
		if err != nil {
			return "", err
		}
		rows = nil
		for _, s := range it.Stock {
			if s.Location == locationID {
				rows = append(rows, s)
			}
		}
	}
	switch len(rows) {
	case 0:
		return "", fmt.Errorf("no stock of %q found for %q", it.Name, ref)
	case 1:
		return rows[0].ID, nil
	}
	ix, err := e.locationTree()
	if err != nil {
		return "", err
	}
	var candidates []string
	for _, s := range rows {
		candidates = append(candidates, s.Code+"  "+ix.pathString(s.Location)+"  "+formatQuantity(s.Quantity, s.Display))
	}
	if i, ok, err := e.choose(fmt.Sprintf("Which stock of %q? ", it.Name), candidates); ok {
		if err != nil {
			return "", err
		}
		return rows[i].ID, nil
	}
	return "", ambiguous("stock of", it.Name, candidates)
}

func (e *env) attributes() ([]attribute, error) {
	if e.cache.attributes == nil {
		if err := e.cachedGet("/attributes", "attributes", &e.cache.attributes); err != nil {
			return nil, err
		}
	}
	return e.cache.attributes, nil
}

// resolveAttribute returns an attribute given by id or name.
func (e *env) resolveAttribute(ref string) (*attribute, error) {
	if isUUID(ref) {
		var a attribute
		if err := e.get("/attributes/"+strings.ToLower(ref), nil, &a); err != nil {
			return nil, err
		}
		return &a, nil
	}
	list, err := e.attributes()
	if err != nil {
		return nil, err
	}
	for i := range list {
		if strings.EqualFold(list[i].Name, strings.TrimSpace(ref)) {
			return &list[i], nil
		}
	}
	return nil, fmt.Errorf("no attribute named %q", ref)
}

// resolveOption returns the id of an option of an attribute, by id or name.
func (e *env) resolveOption(attributeID, ref string) (string, error) {
	if isUUID(ref) {
		return strings.ToLower(ref), nil
	}
	var options []option
	if err := e.get("/attributes/"+attributeID+"/options", nil, &options); err != nil {
		return "", err
	}
	for _, o := range options {
		if strings.EqualFold(o.Name, strings.TrimSpace(ref)) {
			return o.ID, nil
		}
	}
	return "", fmt.Errorf("no option named %q", ref)
}

// unitFamilies returns all unit families, each with its units.
func (e *env) unitFamilies() ([]unitFamily, error) {
	if e.cache.families == nil {
		if err := e.cachedGet("/unit-families", "unit-families", &e.cache.families); err != nil {
			return nil, err
		}
	}
	return e.cache.families, nil
}

// resolveFamily returns the id of a unit family given by id or name.
func (e *env) resolveFamily(ref string) (string, error) {
	list, err := e.unitFamilies()
	if err != nil {
		return "", err
	}
	for _, f := range list {
		if strings.EqualFold(f.Name, strings.TrimSpace(ref)) || f.ID == strings.TrimSpace(ref) {
			return f.ID, nil
		}
	}
	return "", fmt.Errorf("no unit family named %q (see 'wtf unit-family list')", ref)
}

func (e *env) loadQuantities() error {
	if e.cache.quantities == nil {
		return e.cachedGet("/quantities", "quantities", &e.cache.quantities)
	}
	return nil
}

// resolveQuantity returns the id of a quantity given by id or name.
func (e *env) resolveQuantity(ref string) (string, error) {
	if err := e.loadQuantities(); err != nil {
		return "", err
	}
	for _, q := range e.cache.quantities {
		if strings.EqualFold(q.Name, strings.TrimSpace(ref)) || q.ID == strings.TrimSpace(ref) {
			return q.ID, nil
		}
	}
	return "", fmt.Errorf("no quantity named %q (see 'wtf quantity list')", ref)
}

// resolveUnit returns a unit given by id, symbol or name. A symbol that
// several families share is told apart by its family, as unitRef writes
// it: "B (Binary bytes)".
func (e *env) resolveUnit(ref string) (*unit, error) {
	families, err := e.unitFamilies()
	if err != nil {
		return nil, err
	}
	var all []unit
	for _, f := range families {
		all = append(all, f.Units...)
	}
	ref = strings.TrimSpace(ref)
	for i := range all {
		if all[i].ID == ref || unitRef(all, &all[i]) == ref {
			return &all[i], nil
		}
	}
	if symbol, family, ok := strings.Cut(strings.TrimSuffix(ref, ")"), " ("); ok {
		var in []unit
		for _, u := range all {
			if strings.EqualFold(u.Family.Name, family) {
				in = append(in, u)
			}
		}
		return matchUnit(in, symbol)
	}
	u, err := matchUnit(all, ref)
	if err != nil {
		return nil, err
	}
	// The same unit in several families: the family must be named.
	var refs []string
	for i := range all {
		if all[i].ID != u.ID && all[i].Symbol == u.Symbol {
			refs = append(refs, unitRef(all, &all[i]))
		}
	}
	if refs != nil {
		return nil, ambiguous("unit", ref, append([]string{unitRef(all, u)}, refs...))
	}
	return u, nil
}

// unitRef names a unit for the command line: its symbol, followed by its
// family when other families have the same symbol.
func unitRef(all []unit, u *unit) string {
	for _, v := range all {
		if v.ID != u.ID && v.Symbol == u.Symbol {
			return u.Symbol + " (" + u.Family.Name + ")"
		}
	}
	return u.Symbol
}

// resolveAccount returns the id of an account given by id or email.
func (e *env) resolveAccount(ref string) (string, error) {
	if isUUID(ref) {
		return strings.ToLower(ref), nil
	}
	var list []account
	if err := e.get("/accounts", nil, &list); err != nil {
		return "", err
	}
	for _, a := range list {
		if strings.EqualFold(a.Email, strings.TrimSpace(ref)) {
			return a.ID, nil
		}
	}
	return "", fmt.Errorf("no account with email %q", ref)
}

// targetPath maps an attachment target type and reference to its API path.
func (e *env) targetPath(typ, ref string) (string, error) {
	var (
		id  string
		err error
	)
	switch typ {
	case "item":
		id, err = e.resolveItem(ref)
		typ = "items"
	case "stock":
		id, err = e.resolveStock(ref)
	case "location":
		id, err = e.resolveLocation(ref)
		typ = "locations"
	case "class":
		id, err = e.resolveClass(ref)
		typ = "classes"
	default:
		return "", usagef("unknown type %q: use item, stock, location or class", typ)
	}
	if err != nil {
		return "", err
	}
	return "/" + typ + "/" + id, nil
}

// object is a JSON request body.
type object = map[string]any

// unitLabel names a unit as resolveUnit takes it back (see unitRef).
func (e *env) unitLabel(u *unit) (string, error) {
	families, err := e.unitFamilies()
	if err != nil {
		return "", err
	}
	var all []unit
	for _, f := range families {
		all = append(all, f.Units...)
	}
	return unitRef(all, u), nil
}
