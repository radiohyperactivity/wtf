package cli

import (
	"encoding/json"
	"flag"
	"fmt"
	"net/http"
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

// do sends a request and returns the response body.
func (e *env) do(method, path string, body any) (json.RawMessage, error) {
	data, _, err := e.api.Do(e.ctx, method, path, nil, body)
	return data, err
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
		args:    "<" + kind + ">",
		summary: "Delete " + article(kind) + ".",
		params:  []param{objectParam(kind)},
		setup: simple(func(e *env, args []string) error {
			if err := wantArgs(args, 1, 1); err != nil {
				return err
			}
			id, err := resolve(e, args[0])
			if err != nil {
				return err
			}
			if _, err := e.do(http.MethodDelete, prefix+id, nil); err != nil {
				return err
			}
			e.deleted(kind + " " + args[0])
			return nil
		}),
	}
}

// historyCommand shows the history of the object named by the argument.
func historyCommand(kind, prefix string, resolve func(*env, string) (string, error)) command {
	return command{
		name:    "history",
		args:    "<" + kind + "> [--limit N] [--offset N]",
		summary: "Show the changes to " + article(kind) + ", newest first (history privilege).",
		params:  []param{objectParam(kind)},
		setup: func(fs *flag.FlagSet) func(*env, []string) error {
			var p paging
			p.register(fs)
			return func(e *env, args []string) error {
				if err := wantArgs(args, 1, 1); err != nil {
					return err
				}
				id, err := resolve(e, args[0])
				if err != nil {
					return err
				}
				return e.list(p, listing{
					path:  prefix + id + "/history",
					empty: "No history.",
					render: func(data json.RawMessage, _ bool) ([]string, error) {
						var pg page[historyEntry]
						if err := decode(data, &pg); err != nil {
							return nil, err
						}
						return historyLines(pg.Rows), nil
					},
				})
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
	case "item", "attribute", "account", "attachment":
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
