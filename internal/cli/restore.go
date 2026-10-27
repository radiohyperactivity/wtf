package cli

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net/http"
	"strings"

	"github.com/radiohyperactivity/wtf/internal/client"
)

// restoreKind describes how objects of a kind are restored (see
// api/deleting.md, "Restoring").
type restoreKind struct {
	kind   string // as in commands: "item", "stock", "location", …
	prefix string // "/items/"
	// codeType is the type a label code of the kind resolves to; "" when the
	// kind has no codes and is named by id only.
	codeType string
	// place is the body key naming another place to restore it in
	// ("class", "location", "parent"), placeKind what that place is; ""
	// when there is none.
	place, placeKind string
	named            bool // takes --name
	show             func(*env, json.RawMessage) error
}

// restoreCommand restores a deleted object. When it is in something deleted,
// --with-parents restores that too and --to restores it somewhere else; on a
// terminal the command asks which, when neither is given.
func restoreCommand(rk restoreKind) command {
	ref := "<" + rk.kind + " id>"
	if rk.codeType != "" {
		ref = "<" + rk.kind + " id or code>"
	}
	args := ref
	if rk.named {
		args += " [--name N]"
	}
	if rk.place != "" {
		args += " [--with-parents | --to " + strings.ToUpper(rk.placeKind) + "]"
	}
	flags := map[string]param{}
	if rk.place != "" {
		flags["to"] = arg(strings.ToUpper(rk.placeKind[:1])+rk.placeKind[1:], kindCompleters[rk.placeKind])
	}
	return command{
		name:    "restore",
		args:    args,
		summary: "Restore a deleted " + strings.TrimPrefix(strings.TrimPrefix(article(rk.kind), "a "), "an ") + ", with what was deleted together with it.",
		params:  []param{arg(strings.ToUpper(rk.kind[:1])+rk.kind[1:]+" id or code", nil)},
		flags:   flags,
		setup: func(fs *flag.FlagSet) func(*env, []string) error {
			var name, to optString
			var withParents *bool
			if rk.named {
				fs.Var(&name, "name", "a new name, for when the old one is taken")
			}
			if rk.place != "" {
				withParents = fs.Bool("with-parents", false, "also restore the deleted "+rk.placeKind+" it is in, and those above it")
				usage := "restore it in this " + rk.placeKind + " instead"
				if rk.place == "parent" {
					usage += " ('none': at the top)"
				}
				fs.Var(&to, "to", usage)
			}
			return func(e *env, args []string) error {
				if err := wantArgs(args, 1, 1); err != nil {
					return err
				}
				id, err := e.resolveDeleted(rk, args[0])
				if err != nil {
					return err
				}
				body := object{}
				if name.set {
					body["name"] = name.value
				}
				if withParents != nil && *withParents {
					if to.set {
						return usagef("--with-parents and --to exclude each other")
					}
					body["with_parents"] = true
				}
				if to.set {
					if body[rk.place], err = e.resolvePlace(rk, to.value); err != nil {
						return err
					}
				}
				data, err := e.do(http.MethodPost, rk.prefix+id+"/restore", body)
				if p := intoDeleted(err); p != nil && rk.place != "" && !to.set && (withParents == nil || !*withParents) {
					if e.term == nil {
						return fmt.Errorf("%s\nAdd --with-parents to restore that too, or --to %s to restore it somewhere else", p.Detail, strings.ToUpper(rk.placeKind))
					}
					if err := e.askRestorePlace(rk, p, body, flags["to"], args); err != nil {
						return err
					}
					data, err = e.do(http.MethodPost, rk.prefix+id+"/restore", body)
				}
				if err != nil {
					return err
				}
				return e.emit(data, func() error {
					fmt.Fprintf(e.stdout, "Restored %s %s.\n\n", strings.TrimPrefix(strings.TrimPrefix(article(rk.kind), "a "), "an "), args[0])
					return rk.show(e, data)
				})
			}
		},
	}
}

// askRestorePlace asks how to restore something that is in something
// deleted, and puts the answer into the request body.
func (e *env) askRestorePlace(rk restoreKind, p *client.Problem, body object, placeParam param, args []string) error {
	fmt.Fprintln(e.stderr, p.Detail+".")
	i, err := e.term.Choose("Restore it how? ", []string{
		"together with the " + rk.placeKind + " it is in",
		"in another " + rk.placeKind,
	})
	if err != nil {
		return err
	}
	if i == 0 {
		body["with_parents"] = true
		return nil
	}
	place, err := e.ask(placeParam, args)
	if err != nil {
		return err
	}
	body[rk.place], err = e.resolvePlace(rk, place)
	return err
}

// intoDeleted returns the problem of a restore refused because the object is
// in something deleted, or nil.
func intoDeleted(err error) *client.Problem {
	var p *client.Problem
	if errors.As(err, &p) && p.Type == "/problems/deleted" && strings.Contains(p.Hint, "with_parents") {
		return p
	}
	return nil
}

// resolveDeleted names a deleted object: deleted objects are in no list or
// tree, so only an id, or for some kinds a label code, can name them. Their
// history shows the id.
func (e *env) resolveDeleted(rk restoreKind, ref string) (string, error) {
	if isUUID(ref) {
		return strings.ToLower(ref), nil
	}
	if rk.codeType != "" {
		r, ok, err := e.lookupCode(ref)
		if err != nil {
			return "", err
		}
		if ok && r.Type == rk.codeType {
			var o struct {
				ID string `json:"id"`
			}
			return o.ID, decode(r.Object, &o)
		}
		if ok {
			return "", fmt.Errorf("%s is the code of %s, not of %s", normalizeCode(ref), article(r.Type), article(rk.kind))
		}
		return "", fmt.Errorf("no %s with the code %q; a deleted %s is named by its id or label code", rk.kind, ref, rk.kind)
	}
	return "", usagef("a deleted %s is named by its id (its history shows it)", rk.kind)
}

// resolvePlace names the live place to restore into; 'none' is the top of a
// tree, as a parent.
func (e *env) resolvePlace(rk restoreKind, ref string) (any, error) {
	if rk.place == "parent" && isNone(ref) {
		return nil, nil
	}
	if rk.placeKind == "class" {
		return e.resolveClass(ref)
	}
	return e.resolveLocation(ref)
}

func (e *env) printOptionJSON(data json.RawMessage) error {
	var o option
	if err := decode(data, &o); err != nil {
		return err
	}
	fields(e.stdout, "Name", o.Name, "Attribute", o.Attribute, "Deleted", deletedNote(o.Deleted, "option", o.ID), "Id", o.ID)
	return nil
}

// deletedNote is the "Deleted" field of a deleted object: how to restore it.
// It is empty for a live one, so fields leaves the line out.
func deletedNote(deleted bool, kind, ref string) string {
	if !deleted {
		return ""
	}
	return "yes; restore it with 'wtf " + kind + " restore " + ref + "'"
}
