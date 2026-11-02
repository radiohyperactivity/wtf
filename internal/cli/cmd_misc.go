package cli

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	iofs "io/fs"
	"mime"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"

	"github.com/radiohyperactivity/wtf/internal/mediatype"
)

// owner is an item or a stock row that has files: its API path, its kind
// ("item" or "stock"), and its class.
type owner struct {
	path, kind, class string
}

// resolveOwner finds the item or stock row ref names: a label code says
// which it is; ITEM@LOCATION is a stock row; anything else is an item.
func (e *env) resolveOwner(ref string) (owner, error) {
	if r, ok, err := e.lookupCode(ref); err != nil {
		return owner{}, err
	} else if ok {
		switch r.Type {
		case "item":
			var it item
			err := e.decode(r.Object, &it)
			return owner{path: "/items/" + it.ID, kind: "item", class: it.Class.ID}, err
		case "stock":
			var s stock
			err := e.decode(r.Object, &s)
			return owner{path: "/stock/" + s.ID, kind: "stock", class: s.Item.Class}, err
		}
		return owner{}, fmt.Errorf("%s is the code of a %s, which has no files", normalizeCode(ref), r.Type)
	}
	if strings.Contains(ref, "@") {
		id, err := e.resolveStock(ref)
		if err != nil {
			return owner{}, err
		}
		var s stock
		err = e.get("/stock/"+id, nil, &s)
		return owner{path: "/stock/" + id, kind: "stock", class: s.Item.Class}, err
	}
	id, err := e.resolveItem(ref)
	if err != nil {
		return owner{}, err
	}
	var it item
	err = e.get("/items/"+id, nil, &it)
	return owner{path: "/items/" + id, kind: "item", class: it.Class.ID}, err
}

// filePath is the API path of the photo, or of the file of attachment
// attribute name, of o.
func (e *env) filePath(o owner, name string) (string, error) {
	if strings.EqualFold(strings.TrimSpace(name), "photo") {
		return o.path + "/photo", nil
	}
	c, err := e.classDetail(o.class)
	if err != nil {
		return "", err
	}
	a, err := matchAttribute(c, o.kind, name)
	if err != nil {
		return "", err
	}
	if a.Type != "attachment" {
		return "", usagef("%s is %s, not a file", a.Name, article(a.Type))
	}
	return o.path + "/files/" + url.PathEscape(a.Name), nil
}

func fileGroup() group {
	owner := arg("Item or stock row", completeItems)
	name := arg("Attribute or photo", completeOwnerFiles(0))
	return group{
		name:    "file",
		summary: "Files of items and stock rows: their photos and attachment attributes",
		commands: []command{
			{
				name:    "put",
				args:    "<item or stock row> <attribute|photo> <file>",
				summary: "Upload a file as the photo, or as the file of an attachment attribute; it replaces the one there.",
				params:  []param{owner, name, fileArg("File")},
				setup: simple(func(e *env, args []string) error {
					if err := wantArgs(args, 3, 3); err != nil {
						return err
					}
					o, err := e.resolveOwner(args[0])
					if err != nil {
						return err
					}
					path, err := e.filePath(o, args[1])
					if err != nil {
						return err
					}
					data, err := e.api.Upload(e.ctx, path, args[2])
					if err != nil {
						return err
					}
					e.wrote(path)
					return e.emit(data, func() error {
						if o.kind == "item" {
							return e.printItemJSON(data)
						}
						return e.printStockJSON(data)
					})
				}),
			},
			{
				name:    "get",
				args:    "<item or stock row> <attribute|photo> [file] [--force]",
				summary: "Save a file; without a file name, it is named after the attribute (or Photo), with an extension for its type. - writes it to stdout.",
				params:  []param{owner, name, {name: "File", files: true, optional: true, complete: completeFiles}},
				setup: func(fs *flag.FlagSet) func(*env, []string) error {
					force := fs.Bool("force", false, "overwrite a file that is there")
					return func(e *env, args []string) error {
						if err := wantArgs(args, 2, 3); err != nil {
							return err
						}
						o, err := e.resolveOwner(args[0])
						if err != nil {
							return err
						}
						path, err := e.filePath(o, args[1])
						if err != nil {
							return err
						}
						if len(args) == 3 && args[2] == "-" {
							_, err := e.api.Download(e.ctx, path, e.stdout)
							return err
						}
						// Into a file of its own first, named once the type is known.
						tmp, err := os.CreateTemp(".", ".wtf-download-*")
						if err != nil {
							return err
						}
						header, err := e.api.Download(e.ctx, path, tmp)
						if cerr := tmp.Close(); err == nil {
							err = cerr
						}
						if err != nil {
							os.Remove(tmp.Name())
							return err
						}
						target := ""
						if len(args) == 3 {
							target = args[2]
						} else {
							target = downloadName(header, args[1])
						}
						if !*force {
							if _, err := os.Stat(target); err == nil {
								os.Remove(tmp.Name())
								return fmt.Errorf("%s exists; use --force to overwrite it, or give another file name", target)
							} else if !errors.Is(err, iofs.ErrNotExist) {
								os.Remove(tmp.Name())
								return err
							}
						}
						if err := os.Rename(tmp.Name(), target); err != nil {
							os.Remove(tmp.Name())
							return err
						}
						if !e.json {
							fmt.Fprintf(e.stdout, "Saved %s.\n", target)
						}
						return nil
					}
				},
			},
		},
	}
}

// downloadName is the name a download is saved as: what the server says in
// Content-Disposition, or else name with an extension for its type, in the
// current directory.
func downloadName(header http.Header, name string) string {
	if _, params, err := mime.ParseMediaType(header.Get("Content-Disposition")); err == nil && params["filename"] != "" {
		return filepath.Base(params["filename"])
	}
	return filepath.Base(mediatype.DownloadName(name, header.Get("Content-Type")))
}

func codeCommand() command {
	return command{
		name:    "code",
		args:    "<code>",
		summary: "Show what a label code belongs to (a location, item or stock row).",
		params:  []param{arg("Code", nil)},
		setup: simple(func(e *env, args []string) error {
			if err := wantArgs(args, 1, 1); err != nil {
				return err
			}
			code := normalizeCode(args[0])
			if code == "" {
				return fmt.Errorf("%q is not a label code", args[0])
			}
			data, err := e.api.Get(e.ctx, "/codes/"+code, nil)
			if err != nil {
				return err
			}
			return e.emit(data, func() error {
				var r codeResult
				if err := e.decode(data, &r); err != nil {
					return err
				}
				fmt.Fprintf(e.stdout, "%s is %s.\n\n", code, article(r.Type))
				switch r.Type {
				case "location":
					return e.printLocationJSON(r.Object)
				case "item":
					return e.printItemJSON(r.Object)
				case "stock":
					return e.printStockJSON(r.Object)
				}
				return e.printJSON(r.Object)
			})
		}),
	}
}

// parseRole accepts viewer, user and admin, in any case.
func parseRole(s string) (string, error) {
	switch r := strings.ToLower(strings.TrimSpace(s)); r {
	case "viewer", "user", "admin":
		return r, nil
	}
	return "", usagef("role %q: use viewer, user or admin", s)
}

func accountGroup() group {
	printAccount := printAccountJSON
	roleParams := map[string]param{"role": arg("Role", roleList)}
	return group{
		name:    "account",
		summary: "Accounts (admins)",
		commands: []command{
			{
				name:    "list",
				summary: "List the accounts.",
				setup: simple(func(e *env, args []string) error {
					if err := wantArgs(args, 0, 0); err != nil {
						return err
					}
					data, err := e.api.Get(e.ctx, "/accounts", nil)
					if err != nil {
						return err
					}
					return e.emit(data, func() error {
						var list []account
						if err := e.decode(data, &list); err != nil {
							return err
						}
						t := newTable(e.stdout, "EMAIL", "ROLE", "PASSWORD")
						for _, a := range list {
							t.row(a.Email, a.Role, yesNo(a.HasPassword))
						}
						t.flush()
						return nil
					})
				}),
			},
			getCommand("account", "/accounts/", resolveAccountFn, printAccount),
			{
				name:    "add",
				args:    "<email> [--password] [--role R] [--edit]",
				summary: "Create an account, a viewer unless --role says user or admin. --password prompts for one; without it the account can't log in yet.",
				params:  []param{arg("Email", nil)},
				flags:   roleParams,
				setup: func(fs *flag.FlagSet) func(*env, []string) error {
					withPassword := fs.Bool("password", false, "prompt for a password")
					editAfter := fs.Bool("edit", false, "open the new account in the edit form")
					var role optString
					fs.Var(&role, "role", "role: viewer, user or admin")
					return func(e *env, args []string) error {
						if *editAfter {
							if err := e.needTerminal("--edit"); err != nil {
								return err
							}
						}
						if err := wantArgs(args, 1, 1); err != nil {
							return err
						}
						body := object{"email": args[0], "password": nil, "role": "viewer"}
						if role.set {
							r, err := parseRole(role.value)
							if err != nil {
								return err
							}
							body["role"] = r
						}
						if *withPassword {
							p, err := e.newPassword("Password for " + args[0] + ": ")
							if err != nil {
								return err
							}
							body["password"] = p
						}
						data, err := e.do(http.MethodPost, "/accounts", body)
						if err != nil {
							return err
						}
						if *editAfter {
							return e.editCreated(data, (*env).editAccount)
						}
						return e.emit(data, func() error { return printAccount(e, data) })
					}
				},
			},
			{
				name:    "set",
				args:    "<account> [--email E] [--password|--no-password [--log-out|--keep-sessions]] [--role R]",
				summary: "Change an account. With a new password (or none), its sessions end or stay, as --log-out or --keep-sessions says, or as asked.",
				params:  []param{arg("Account", completeAccounts)},
				flags:   roleParams,
				setup: func(fs *flag.FlagSet) func(*env, []string) error {
					var email optString
					fs.Var(&email, "email", "new email")
					withPassword := fs.Bool("password", false, "prompt for a new password")
					noPassword := fs.Bool("no-password", false, "remove the password (the account can't log in)")
					logOut := fs.Bool("log-out", false, "with a new password: end the account's sessions")
					keep := fs.Bool("keep-sessions", false, "with a new password: keep the account's sessions")
					var role optString
					fs.Var(&role, "role", "new role: viewer, user or admin")
					return func(e *env, args []string) error {
						if err := wantArgs(args, 1, 1); err != nil {
							return err
						}
						if *withPassword && *noPassword {
							return usagef("--password and --no-password exclude each other")
						}
						id, err := e.resolveAccount(args[0])
						if err != nil {
							return err
						}
						body := object{}
						if email.set {
							body["email"] = email.value
						}
						if role.set {
							r, err := parseRole(role.value)
							if err != nil {
								return err
							}
							body["role"] = r
						}
						if *noPassword {
							body["password"] = nil
						}
						if *withPassword {
							p, err := e.newPassword("New password for " + args[0] + ": ")
							if err != nil {
								return err
							}
							body["password"] = p
						}
						if *logOut && *keep {
							return usagef("--log-out and --keep-sessions exclude each other")
						}
						if _, ok := body["password"]; ok {
							end := *logOut
							if !*logOut && !*keep {
								if end, err = e.yesNo("Log out the account's sessions too?"); err != nil {
									return err
								}
							}
							body["end_sessions"] = end
						} else if *logOut || *keep {
							return usagef("--log-out and --keep-sessions go with --password or --no-password")
						}
						if len(body) == 0 {
							return usagef("nothing to change")
						}
						data, err := e.do(http.MethodPatch, "/accounts/"+id, body)
						if err != nil {
							return err
						}
						return e.emit(data, func() error { return printAccount(e, data) })
					}
				},
			},
			editCommand("account", objectParam("account"), resolveAccountFn, (*env).editAccount),
			deleteCommand("account", "/accounts/", resolveAccountFn),
		},
	}
}

// printAccountJSON prints an account.
func printAccountJSON(e *env, data json.RawMessage) error {
	var a account
	if err := e.decode(data, &a); err != nil {
		return err
	}
	fields(e.stdout,
		"Email", a.Email,
		"Password", map[bool]string{true: "set", false: "none (can't log in)"}[a.HasPassword],
		"Role", a.Role,
		"Id", a.ID)
	return nil
}
