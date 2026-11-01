package cli

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net/http"
	"net/url"
	"regexp"
	"strings"
)

// optString is a flag that remembers whether it was given, for PATCH bodies.
type optString struct {
	value string
	set   bool
}

func (o *optString) String() string     { return o.value }
func (o *optString) Set(v string) error { o.value, o.set = v, true; return nil }

// isNone is true for the words that clear an optional reference.
func isNone(s string) bool {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "", "none", "null", "-":
		return true
	}
	return false
}

// stringList is a repeatable flag.
type stringList []string

func (l *stringList) String() string     { return strings.Join(*l, ", ") }
func (l *stringList) Set(v string) error { *l = append(*l, v); return nil }

// parseValues turns "Attribute=value" flags into the API's values object,
// keyed by attribute id.
func (e *env) parseValues(list []string) (object, error) {
	if len(list) == 0 {
		return nil, nil
	}
	values := object{}
	for _, s := range list {
		name, text, ok := strings.Cut(s, "=")
		if !ok {
			return nil, usagef("--value %q: expected ATTRIBUTE=VALUE", s)
		}
		a, err := e.resolveAttribute(name)
		if err != nil {
			return nil, err
		}
		v, err := e.parseValue(a, text)
		if err != nil {
			return nil, err
		}
		values[a.ID] = v
	}
	return values, nil
}

// conditionPattern splits "Resistance >= 32k" into attribute, operator
// and value, at the first operator.
var conditionPattern = regexp.MustCompile(`^(.+?)\s*(>=|<=|>|<|=|~)\s*(.*)$`)

// parseWhere turns --where conditions into the API's attribute filters (the
// where query parameter of GET /items), as JSON:
//
//	Resistance>=32k     numbers and dates: =, >, >=, <, <=, in any unit
//	Resistance=10k..47k a range, both ends included
//	Package=0603,0805   choices: any of the options
//	Notes~metal         text: contains (= is the whole text), ignoring case
//	Lead-free=yes       yes/no
func (e *env) parseWhere(list []string) (string, error) {
	var filters []object
	for _, s := range list {
		m := conditionPattern.FindStringSubmatch(s)
		if m == nil {
			return "", usagef("--where %q: expected ATTRIBUTE OP VALUE, e.g. \"Resistance>=32k\"", s)
		}
		a, err := e.resolveAttribute(m[1])
		if err != nil {
			return "", err
		}
		op, text := m[2], strings.TrimSpace(m[3])
		filter := object{"attribute": a.ID, "op": op}
		switch a.Datatype {
		case "integer", "decimal", "date":
			if op == "~" {
				return "", usagef("--where %q: %s can be compared with =, >, >=, <, <= or a range LOW..HIGH", s, a.Name)
			}
			low, high, isRange := strings.Cut(text, "..")
			if isRange && op != "=" {
				return "", usagef("--where %q: a range goes with =", s)
			}
			if isRange {
				lo, err := e.parseValue(a, low)
				if err != nil {
					return "", err
				}
				hi, err := e.parseValue(a, high)
				if err != nil {
					return "", err
				}
				filter["op"], filter["value"] = "between", []any{lo, hi}
			} else if filter["value"], err = e.parseValue(a, text); err != nil {
				return "", err
			}
		case "text", "url":
			switch op {
			case "~":
				filter["op"] = "contains"
			case "=":
			default:
				return "", usagef("--where %q: %s can be compared with = (the whole text) or ~ (contains)", s, a.Name)
			}
			filter["value"] = text
		case "choice":
			if op != "=" {
				return "", usagef("--where %q: %s takes = with one or more options, e.g. %s=0603,0805", s, a.Name, a.Name)
			}
			var options []string
			for _, o := range strings.Split(text, ",") {
				options = append(options, strings.TrimSpace(o))
			}
			filter["op"], filter["value"] = "in", options
		case "boolean":
			b, ok := parseYesNo(text)
			if op != "=" || !ok {
				return "", usagef("--where %q: %s takes =yes or =no", s, a.Name)
			}
			filter["value"] = b
		}
		filters = append(filters, filter)
	}
	data, err := json.Marshal(filters)
	return string(data), err
}

const whereHelp = `an attribute condition, repeatable: "Resistance>=32k", "Resistance=10k..47k", "Package=0603,0805", "Notes~metal", "Lead-free=yes"`

// setWhere puts --where conditions in the query, if there are any.
func (e *env) setWhere(q url.Values, where []string) error {
	if len(where) == 0 {
		return nil
	}
	filters, err := e.parseWhere(where)
	if err != nil {
		return err
	}
	q.Set("where", filters)
	return nil
}

// do sends a request and returns the response body.
func (e *env) do(method, path string, body any) (json.RawMessage, error) {
	data, _, err := e.api.Do(e.ctx, method, path, nil, body)
	if err == nil && method != http.MethodGet {
		e.wrote(path)
	}
	return data, err
}

// confirmDelete asks on a terminal whether to delete what, as a delete
// can't be undone; yes (--yes) answers for the user. Without a terminal it
// doesn't ask: scripts delete as they always did, and a single delete is
// refused while anything is in or uses what it deletes.
func (e *env) confirmDelete(what string, yes bool) error {
	if yes || e.term == nil {
		return nil
	}
	answer, err := e.term.ReadLine("Delete "+what+"? This can't be undone. [y/N] ", "", nil)
	if err != nil {
		return err
	}
	if a := strings.ToLower(strings.TrimSpace(answer)); a != "y" && a != "yes" {
		return errors.New("nothing was deleted")
	}
	return nil
}

// deleted reports a deletion.
func (e *env) deleted(what string) {
	if !e.json {
		fmt.Fprintf(e.stdout, "Deleted %s.\n", what)
	}
}

// simple is the setup of a command without flags of its own.
func simple(run func(e *env, args []string) error) func(*flag.FlagSet) func(*env, []string) error {
	return func(*flag.FlagSet) func(*env, []string) error { return run }
}

// deleteCommand deletes the object named by the single argument.
func deleteCommand(kind, prefix string, resolve func(*env, string) (string, error)) command {
	return command{
		name:    "delete",
		args:    "<" + kind + "> [--yes]",
		summary: "Delete " + article(kind) + ", for good; on a terminal it asks first.",
		params:  []param{objectParam(kind)},
		setup: func(fs *flag.FlagSet) func(*env, []string) error {
			yes := fs.Bool("yes", false, "don't ask first")
			return func(e *env, args []string) error {
				if err := wantArgs(args, 1, 1); err != nil {
					return err
				}
				id, err := resolve(e, args[0])
				if err != nil {
					return err
				}
				if err := e.confirmDelete(kind+" "+args[0], *yes); err != nil {
					return err
				}
				if _, err := e.do(http.MethodDelete, prefix+id, nil); err != nil {
					return err
				}
				e.deleted(kind + " " + args[0])
				return nil
			}
		},
	}
}

// The resolvers as func(*env, string), for the generic commands above.
var (
	resolveItemFn     = (*env).resolveItem
	resolveStockFn    = (*env).resolveStock
	resolveLocationFn = (*env).resolveLocation
	resolveClassFn    = (*env).resolveClass
	resolveAccountFn  = (*env).resolveAccount
	resolveAttrIDFn   = func(e *env, s string) (string, error) {
		a, err := e.resolveAttribute(s)
		if err != nil {
			return "", err
		}
		return a.ID, nil
	}
)

// article is "a location", "an item", "a stock row".
func article(kind string) string {
	switch kind {
	case "stock":
		return "a stock row"
	case "item", "attribute", "account", "attachment", "option":
		return "an " + kind
	}
	return "a " + kind
}

// kindCompleters complete the objects of the generic commands above.
var kindCompleters = map[string]completer{
	"item":      completeItems,
	"stock":     completeStock,
	"location":  completeLocations,
	"class":     completeClasses,
	"attribute": completeAttributes,
	"account":   completeAccounts,
}

// objectParam is the argument naming an object of a kind.
func objectParam(kind string) param {
	return arg(strings.ToUpper(kind[:1])+kind[1:], kindCompleters[kind])
}

// setUnit puts a new attribute's or item's unit (by unitRef) and Unit lock
// into body. Without a unit, Unit lock is refused.
func (e *env) setUnit(body object, unitRef string, lock bool) error {
	body["unit"], body["unit_lock"] = nil, lock
	if unitRef == "" {
		if lock {
			return usagef("--unit-lock needs --unit")
		}
		return nil
	}
	u, err := e.resolveUnit(unitRef)
	if err != nil {
		return err
	}
	body["unit"] = u.ID
	return nil
}

// patchUnit puts a changed unit and Unit lock (yes or no) into a patch.
func (e *env) patchUnit(body object, unitRef, lock optString) error {
	if unitRef.set {
		u, err := e.resolveUnit(unitRef.value)
		if err != nil {
			return err
		}
		body["unit"] = u.ID
	}
	if lock.set {
		b, ok := parseYesNo(lock.value)
		if !ok {
			return usagef("--unit-lock takes yes or no, not %q", lock.value)
		}
		body["unit_lock"] = b
	}
	return nil
}
