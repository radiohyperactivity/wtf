package cli

import (
	"encoding/json"
	"errors"
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
)

// article is "a location", "an item", "a stock row".
func article(kind string) string {
	switch kind {
	case "stock":
		return "a stock row"
	case "item", "attribute", "account", "attachment", "integer":
		return "an " + kind
	}
	return "a " + kind
}

// kindCompleters complete the objects of the generic commands above.
var kindCompleters = map[string]completer{
	"item":     completeItems,
	"stock":    completeStock,
	"location": completeLocations,
	"class":    completeClasses,
	"account":  completeAccounts,
}

// objectParam is the argument naming an object of a kind.
func objectParam(kind string) param {
	return arg(strings.ToUpper(kind[:1])+kind[1:], kindCompleters[kind])
}
