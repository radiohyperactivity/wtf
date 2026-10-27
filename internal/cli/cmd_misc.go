package cli

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	iofs "io/fs"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

func attachmentGroup() group {
	printAttachment := printAttachmentJSON
	attachmentID := func(args []string) (string, error) {
		if err := wantArgs(args, 1, 1); err != nil {
			return "", err
		}
		if !isUUID(args[0]) {
			return "", usagef("attachments are named by id; 'wtf attachment list TYPE REF' shows them")
		}
		return strings.ToLower(args[0]), nil
	}
	return group{
		name:    "attachment",
		summary: "Files attached to items, stock, locations and classes",
		commands: []command{
			editCommand("attachment", arg("Attachment id", nil), func(e *env, s string) (string, error) {
				return attachmentID([]string{s})
			}, (*env).editAttachment),
			{
				name:    "list",
				args:    "<item|stock|location|class> <ref>",
				summary: "List an object's attachments (for an item also its stock rows').",
				params:  []param{arg("Type", targetTypes), arg("Object", completeTargetOf(0))},
				setup: simple(func(e *env, args []string) error {
					if err := wantArgs(args, 2, 2); err != nil {
						return err
					}
					path, err := e.targetPath(args[0], args[1])
					if err != nil {
						return err
					}
					data, err := e.api.Get(e.ctx, path, nil)
					if err != nil {
						return err
					}
					var obj struct {
						Attachments json.RawMessage `json:"attachments"`
						Stock       []itemStock     `json:"stock"`
					}
					if err := decode(data, &obj); err != nil {
						return err
					}
					if e.json {
						return e.printJSON(obj.Attachments)
					}
					var list []attachment
					if err := decode(obj.Attachments, &list); err != nil {
						return err
					}
					printAttachments(e.stdout, "", list)
					if args[0] == "item" {
						for _, s := range obj.Stock {
							if len(s.Attachments) > 0 {
								fmt.Fprintf(e.stdout, "Stock %s:\n", s.Code)
								printAttachments(e.stdout, "  ", s.Attachments)
							}
						}
					}
					return nil
				}),
			},
			{
				name:    "add",
				args:    "<item|stock|location|class> <ref> <file> [--caption C] [--primary] [--edit]",
				summary: "Attach a file.",
				params:  []param{arg("Type", targetTypes), arg("Object", completeTargetOf(0)), fileArg("File")},
				setup: func(fs *flag.FlagSet) func(*env, []string) error {
					caption := fs.String("caption", "", "caption")
					primary := fs.Bool("primary", false, "make it the primary photo (images only)")
					editAfter := fs.Bool("edit", false, "open the new attachment in the edit form")
					return func(e *env, args []string) error {
						if *editAfter {
							if err := e.needTerminal("--edit"); err != nil {
								return err
							}
						}
						if err := wantArgs(args, 3, 3); err != nil {
							return err
						}
						path, err := e.targetPath(args[0], args[1])
						if err != nil {
							return err
						}
						form := map[string]string{"primary_photo": strconv.FormatBool(*primary)}
						if *caption != "" {
							form["caption"] = *caption
						}
						data, err := e.api.Upload(e.ctx, path+"/attachments", args[2], form)
						if err != nil {
							return err
						}
						if *editAfter {
							return e.editCreated(data, (*env).editAttachment)
						}
						return e.emit(data, func() error { return printAttachment(e, data) })
					}
				},
			},
			{
				name:    "get",
				args:    "<attachment-id>",
				summary: "Show an attachment's details.",
				params:  []param{arg("Attachment id", nil)},
				setup: simple(func(e *env, args []string) error {
					id, err := attachmentID(args)
					if err != nil {
						return err
					}
					data, err := e.api.Get(e.ctx, "/attachments/"+id, nil)
					if err != nil {
						return err
					}
					return e.emit(data, func() error { return printAttachment(e, data) })
				}),
			},
			{
				name:    "download",
				args:    "<attachment-id> [-o FILE|-] [--force]",
				summary: "Save an attachment's content, by default under its file name in the current directory.",
				params:  []param{arg("Attachment id", nil)},
				flags:   map[string]param{"o": fileArg("Output file")},
				setup: func(fs *flag.FlagSet) func(*env, []string) error {
					out := fs.String("o", "", "output file, or - for stdout")
					force := fs.Bool("force", false, "overwrite an existing file")
					return func(e *env, args []string) error {
						id, err := attachmentID(args)
						if err != nil {
							return err
						}
						if *out == "-" {
							_, err := e.api.Download(e.ctx, "/attachments/"+id+"/content", e.stdout)
							return err
						}
						name := *out
						if name == "" {
							var a attachment
							if err := e.get("/attachments/"+id, nil, &a); err != nil {
								return err
							}
							name = filepath.Base(a.FileName)
							if name == "." || name == string(filepath.Separator) || name == "" {
								name = id
							}
						}
						flags := os.O_WRONLY | os.O_CREATE | os.O_EXCL
						if *force {
							flags = os.O_WRONLY | os.O_CREATE | os.O_TRUNC
						}
						f, err := os.OpenFile(name, flags, 0o644)
						if errors.Is(err, iofs.ErrExist) {
							return fmt.Errorf("%s exists; use --force to overwrite it, or -o FILE", name)
						}
						if err != nil {
							return err
						}
						_, err = e.api.Download(e.ctx, "/attachments/"+id+"/content", f)
						if cerr := f.Close(); err == nil {
							err = cerr
						}
						if err != nil {
							os.Remove(name)
							return err
						}
						if !e.json {
							fmt.Fprintf(e.stdout, "Saved %s.\n", name)
						}
						return nil
					}
				},
			},
			{
				name:    "set",
				args:    "<attachment-id> [--name N] [--caption C|none] [--primary true|false]",
				summary: "Change an attachment's file name, caption or primary-photo flag.",
				params:  []param{arg("Attachment id", nil)},
				flags:   map[string]param{"primary": arg("Primary", words("true", "false"))},
				setup: func(fs *flag.FlagSet) func(*env, []string) error {
					var name, caption, primary optString
					fs.Var(&name, "name", "new file name")
					fs.Var(&caption, "caption", "new caption, or none")
					fs.Var(&primary, "primary", "true or false")
					return func(e *env, args []string) error {
						id, err := attachmentID(args)
						if err != nil {
							return err
						}
						body := object{}
						if name.set {
							body["file_name"] = name.value
						}
						if caption.set {
							body["caption"] = nil
							if !isNone(caption.value) {
								body["caption"] = caption.value
							}
						}
						if primary.set {
							b, err := strconv.ParseBool(primary.value)
							if err != nil {
								return usagef("--primary must be true or false")
							}
							body["primary_photo"] = b
						}
						if len(body) == 0 {
							return usagef("nothing to change")
						}
						data, err := e.do(http.MethodPatch, "/attachments/"+id, body)
						if err != nil {
							return err
						}
						return e.emit(data, func() error { return printAttachment(e, data) })
					}
				},
			},
			{
				name:    "delete",
				args:    "<attachment-id>",
				summary: "Delete an attachment (it can be restored; its file stays until it is purged).",
				params:  []param{arg("Attachment id", nil)},
				setup: simple(func(e *env, args []string) error {
					id, err := attachmentID(args)
					if err != nil {
						return err
					}
					if _, err := e.do(http.MethodDelete, "/attachments/"+id, nil); err != nil {
						return err
					}
					e.deleted("attachment " + id)
					return nil
				}),
			},
			restoreCommand(restoreKind{kind: "attachment", prefix: "/attachments/", show: printAttachmentJSON}),
		},
	}
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
				if err := decode(data, &r); err != nil {
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

func quantityGroup() group {
	return group{
		name:    "quantity",
		summary: "Physical quantities (system data)",
		commands: []command{
			{
				name:    "list",
				summary: "List the quantities.",
				setup: simple(func(e *env, args []string) error {
					if err := wantArgs(args, 0, 0); err != nil {
						return err
					}
					data, err := e.api.Get(e.ctx, "/quantities", nil)
					if err != nil {
						return err
					}
					return e.emit(data, func() error {
						var list []quantity
						if err := decode(data, &list); err != nil {
							return err
						}
						t := newTable(e.stdout, "NAME", "TYPE", "BASE UNIT")
						for _, q := range list {
							base := ""
							if q.BaseUnit != nil {
								base = q.BaseUnit.Symbol
							}
							t.row(q.Name, q.Datatype, base)
						}
						t.flush()
						return nil
					})
				}),
			},
			{
				name:    "get",
				args:    "<quantity>",
				summary: "Show a quantity with its units and unit groups.",
				params:  []param{arg("Quantity", completeQuantities)},
				setup: simple(func(e *env, args []string) error {
					if err := wantArgs(args, 1, 1); err != nil {
						return err
					}
					id, err := e.resolveQuantity(args[0])
					if err != nil {
						return err
					}
					data, err := e.api.Get(e.ctx, "/quantities/"+id, nil)
					if err != nil {
						return err
					}
					return e.emit(data, func() error {
						var q quantity
						if err := decode(data, &q); err != nil {
							return err
						}
						var groups []string
						for _, g := range q.UnitGroups {
							groups = append(groups, g.Name)
						}
						fields(e.stdout, "Name", q.Name, "Type", q.Datatype, "Unit groups", strings.Join(groups, ", "))
						printUnits(e, q.Units)
						return nil
					})
				}),
			},
		},
	}
}

func printUnits(e *env, units []unit) {
	t := newTable(e.stdout, "SYMBOL", "NAME", "QUANTITY", "FACTOR", "OFFSET")
	for _, u := range units {
		offset := u.BaseOffset.String()
		if offset == "0" {
			offset = ""
		}
		t.row(u.Symbol, u.Name, u.Quantity.Name, u.BaseFactor.String(), offset)
	}
	t.flush()
}

func unitsGroup() group {
	quantityFilter := func(fs *flag.FlagSet) *string {
		return fs.String("quantity", "", "only units of this quantity")
	}
	query := func(e *env, quantityRef string) (url.Values, error) {
		if quantityRef == "" {
			return nil, nil
		}
		id, err := e.resolveQuantity(quantityRef)
		if err != nil {
			return nil, err
		}
		return url.Values{"quantity": {id}}, nil
	}
	return group{
		name:    "unit",
		summary: "Units of measurement (system data)",
		commands: []command{
			{
				name:    "list",
				args:    "[--quantity Q]",
				summary: "List units: base = value × factor + offset.",
				flags:   map[string]param{"quantity": arg("Quantity", completeQuantities)},
				setup: func(fs *flag.FlagSet) func(*env, []string) error {
					q := quantityFilter(fs)
					return func(e *env, args []string) error {
						if err := wantArgs(args, 0, 0); err != nil {
							return err
						}
						v, err := query(e, *q)
						if err != nil {
							return err
						}
						data, err := e.api.Get(e.ctx, "/units", v)
						if err != nil {
							return err
						}
						return e.emit(data, func() error {
							var list []unit
							if err := decode(data, &list); err != nil {
								return err
							}
							printUnits(e, list)
							return nil
						})
					}
				},
			},
			{
				name:    "get",
				args:    "<unit>",
				summary: "Show a unit, named by symbol, name or id.",
				params:  []param{arg("Unit", completeUnits)},
				setup: simple(func(e *env, args []string) error {
					if err := wantArgs(args, 1, 1); err != nil {
						return err
					}
					id, err := e.resolveUnit(args[0])
					if err != nil {
						return err
					}
					data, err := e.api.Get(e.ctx, "/units/"+id, nil)
					if err != nil {
						return err
					}
					return e.emit(data, func() error {
						var u unit
						if err := decode(data, &u); err != nil {
							return err
						}
						printUnits(e, []unit{u})
						return nil
					})
				}),
			},
		},
	}
}

func unitGroupGroup() group {
	return group{
		name:    "unit-group",
		summary: "Unit groups: the units an attribute or item is shown in (system data)",
		commands: []command{
			{
				name:    "list",
				args:    "[--quantity Q]",
				summary: "List unit groups.",
				flags:   map[string]param{"quantity": arg("Quantity", completeQuantities)},
				setup: func(fs *flag.FlagSet) func(*env, []string) error {
					q := fs.String("quantity", "", "only groups of this quantity")
					return func(e *env, args []string) error {
						if err := wantArgs(args, 0, 0); err != nil {
							return err
						}
						var v url.Values
						if *q != "" {
							id, err := e.resolveQuantity(*q)
							if err != nil {
								return err
							}
							v = url.Values{"quantity": {id}}
						}
						data, err := e.api.Get(e.ctx, "/unit-groups", v)
						if err != nil {
							return err
						}
						return e.emit(data, func() error {
							var list []unitGroup
							if err := decode(data, &list); err != nil {
								return err
							}
							t := newTable(e.stdout, "NAME", "QUANTITY", "BASE UNIT")
							for _, g := range list {
								base := ""
								if g.BaseUnit != nil {
									base = g.BaseUnit.Symbol
								}
								t.row(g.Name, g.Quantity.Name, base)
							}
							t.flush()
							return nil
						})
					}
				},
			},
			{
				name:    "get",
				args:    "<unit-group>",
				summary: "Show a unit group with its units.",
				params:  []param{arg("Unit group", completeUnitGroups)},
				setup: simple(func(e *env, args []string) error {
					if err := wantArgs(args, 1, 1); err != nil {
						return err
					}
					id, err := e.resolveUnitGroup(args[0])
					if err != nil {
						return err
					}
					data, err := e.api.Get(e.ctx, "/unit-groups/"+id, nil)
					if err != nil {
						return err
					}
					return e.emit(data, func() error {
						var g unitGroup
						if err := decode(data, &g); err != nil {
							return err
						}
						fields(e.stdout, "Name", g.Name, "Quantity", g.Quantity.Name)
						printUnits(e, g.Units)
						return nil
					})
				}),
			},
		},
	}
}

// parsePrivilege accepts none, read, write and the API's names.
func parsePrivilege(s string) (string, error) {
	switch strings.ToLower(s) {
	case "none", "no", "-":
		return "none", nil
	case "read", "r", "ro", "read_only", "read-only":
		return "read_only", nil
	case "write", "w", "rw", "read_write", "read-write":
		return "read_write", nil
	}
	return "", usagef("privilege %q: use none, read or write", s)
}

func accountGroup() group {
	printAccount := printAccountJSON
	// privilegeFlags registers --data, --model, --account and --history.
	privilegeFlags := func(fs *flag.FlagSet) map[string]*optString {
		flags := map[string]*optString{}
		for _, area := range []string{"data", "model", "account", "history"} {
			o := &optString{}
			fs.Var(o, area, area+" privilege: none, read or write")
			flags[area] = o
		}
		return flags
	}
	applyPrivileges := func(body object, flags map[string]*optString) error {
		for area, o := range flags {
			if o.set {
				p, err := parsePrivilege(o.value)
				if err != nil {
					return err
				}
				body[area+"_privilege"] = p
			}
		}
		return nil
	}
	privilegeParams := map[string]param{}
	for _, area := range []string{"data", "model", "account", "history"} {
		privilegeParams[area] = arg("Privilege", privilegeList)
	}
	return group{
		name:    "account",
		summary: "Accounts of the tenant (account privilege)",
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
						if err := decode(data, &list); err != nil {
							return err
						}
						t := newTable(e.stdout, "EMAIL", "DATA", "MODEL", "ACCOUNT", "HISTORY", "PASSWORD")
						for _, a := range list {
							t.row(a.Email, a.DataPrivilege, a.ModelPrivilege, a.AccountPrivilege, a.HistoryPrivilege, yesNo(a.HasPassword))
						}
						t.flush()
						return nil
					})
				}),
			},
			getCommand("account", "/accounts/", resolveAccountFn, printAccount),
			{
				name:    "add",
				args:    "<email> [--password] [--data P] [--model P] [--account P] [--history P] [--edit]",
				summary: "Create an account. --password prompts for one; without it the account can't log in yet.",
				params:  []param{arg("Email", nil)},
				flags:   privilegeParams,
				setup: func(fs *flag.FlagSet) func(*env, []string) error {
					withPassword := fs.Bool("password", false, "prompt for a password")
					editAfter := fs.Bool("edit", false, "open the new account in the edit form")
					privs := privilegeFlags(fs)
					return func(e *env, args []string) error {
						if *editAfter {
							if err := e.needTerminal("--edit"); err != nil {
								return err
							}
						}
						if err := wantArgs(args, 1, 1); err != nil {
							return err
						}
						body := object{"email": args[0]}
						if err := applyPrivileges(body, privs); err != nil {
							return err
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
				args:    "<account> [--email E] [--password|--no-password] [--data P] [--model P] [--account P] [--history P]",
				summary: "Change an account. A new password ends its sessions.",
				params:  []param{arg("Account", completeAccounts)},
				flags:   privilegeParams,
				setup: func(fs *flag.FlagSet) func(*env, []string) error {
					var email optString
					fs.Var(&email, "email", "new email")
					withPassword := fs.Bool("password", false, "prompt for a new password")
					noPassword := fs.Bool("no-password", false, "remove the password (the account can't log in)")
					privs := privilegeFlags(fs)
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
						if err := applyPrivileges(body, privs); err != nil {
							return err
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
			historyCommand("account", "/accounts/", resolveAccountFn),
		},
	}
}

// printAttachmentJSON prints an attachment.
func printAttachmentJSON(e *env, data json.RawMessage) error {
	var a attachment
	if err := decode(data, &a); err != nil {
		return err
	}
	caption := ""
	if a.Caption != nil {
		caption = *a.Caption
	}
	fields(e.stdout,
		"File name", a.FileName,
		"Deleted", deletedNote(a.Deleted, "attachment", a.ID),
		"Type", a.ContentType,
		"Size", formatSize(a.Size),
		"Caption", caption,
		"Primary photo", yesNo(a.PrimaryPhoto),
		"SHA-256", a.SHA256,
		"Id", a.ID)
	return nil
}

// printAccountJSON prints an account.
func printAccountJSON(e *env, data json.RawMessage) error {
	var a account
	if err := decode(data, &a); err != nil {
		return err
	}
	state := ""
	if a.Deleted {
		state = "deleted"
	}
	fields(e.stdout,
		"Email", a.Email,
		"Password", map[bool]string{true: "set", false: "none (can't log in)"}[a.HasPassword],
		"Privileges", privileges(a),
		"State", state,
		"Id", a.ID)
	return nil
}
