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

	"github.com/radiohyperactivity/wtf/internal/mediatype"
)

func attachmentGroup() group {
	printAttachment := printAttachmentJSON
	targetParams := []param{arg("Type", targetTypes), arg("Object", completeTargetOf(0))}
	withID := append(append([]param{}, targetParams...), arg("Attachment id", nil))
	return group{
		name:    "attachment",
		summary: "Files attached to items, stock, locations and classes",
		commands: []command{
			{
				name:    "list",
				args:    "<item|stock|location|class> <ref>",
				summary: "List an object's attachments (for an item also its stock rows').",
				params:  targetParams,
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
						Photo       *attachment     `json:"photo"`
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
					printAttachments(e.stdout, "", list, obj.Photo, photoName(args[0]))
					if args[0] == "item" {
						for _, s := range obj.Stock {
							if len(s.Attachments) > 0 {
								fmt.Fprintf(e.stdout, "Stock %s:\n", s.Code)
								printAttachments(e.stdout, "  ", s.Attachments, s.Photo, "stock row photo")
							}
						}
					}
					return nil
				}),
			},
			{
				name:    "add",
				args:    "<item|stock|location|class> <ref> <file> [--title T] [--photo]",
				summary: "Attach a file; its title is the file name unless --title gives one.",
				params:  append(append([]param{}, targetParams...), fileArg("File")),
				setup: func(fs *flag.FlagSet) func(*env, []string) error {
					title := fs.String("title", "", "title (default: the file name)")
					photo := fs.Bool("photo", false, "make it the object's photo (images only)")
					return func(e *env, args []string) error {
						if err := wantArgs(args, 3, 3); err != nil {
							return err
						}
						path, err := e.targetPath(args[0], args[1])
						if err != nil {
							return err
						}
						form := map[string]string{"photo": strconv.FormatBool(*photo)}
						if *title != "" {
							form["title"] = *title
						}
						data, err := e.api.Upload(e.ctx, path+"/attachments", args[2], form)
						if err != nil {
							return err
						}
						return e.emit(data, func() error { return printAttachment(e, data) })
					}
				},
			},
			{
				name:    "get",
				args:    "<item|stock|location|class> <ref> <attachment-id>",
				summary: "Show an attachment's details.",
				params:  withID,
				setup: simple(func(e *env, args []string) error {
					path, err := e.attachmentPath(args)
					if err != nil {
						return err
					}
					data, err := e.api.Get(e.ctx, path, nil)
					if err != nil {
						return err
					}
					return e.emit(data, func() error {
						if err := printAttachment(e, data); err != nil {
							return err
						}
						var a attachment
						if decode(data, &a) == nil && a.Deleted {
							fmt.Fprintf(e.stdout, "Deleted:  yes; restore it with 'wtf attachment restore %s %q %s'\n",
								args[0], args[1], args[2])
						}
						return nil
					})
				}),
			},
			{
				name:    "download",
				args:    "<item|stock|location|class> <ref> <attachment-id> [-o FILE|-] [--force]",
				summary: "Save an attachment's content, by default named after its title in the current directory.",
				params:  withID,
				flags:   map[string]param{"o": fileArg("Output file")},
				setup: func(fs *flag.FlagSet) func(*env, []string) error {
					out := fs.String("o", "", "output file, or - for stdout")
					force := fs.Bool("force", false, "overwrite an existing file")
					return func(e *env, args []string) error {
						path, err := e.attachmentPath(args)
						if err != nil {
							return err
						}
						if *out == "-" {
							_, err := e.api.Download(e.ctx, path+"/content", e.stdout)
							return err
						}
						name := *out
						if name == "" {
							var a attachment
							if err := e.get(path, nil, &a); err != nil {
								return err
							}
							name = filepath.Base(mediatype.DownloadName(a.Title, a.Type))
							if name == "." || name == string(filepath.Separator) || name == "" {
								name = a.ID
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
						_, err = e.api.Download(e.ctx, path+"/content", f)
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
				args:    "<item|stock|location|class> <ref> <attachment-id> --title T",
				summary: "Change an attachment's title.",
				params:  withID,
				setup: func(fs *flag.FlagSet) func(*env, []string) error {
					var title optString
					fs.Var(&title, "title", "new title")
					return func(e *env, args []string) error {
						path, err := e.attachmentPath(args)
						if err != nil {
							return err
						}
						if !title.set {
							return usagef("nothing to change")
						}
						data, err := e.do(http.MethodPatch, path, object{"title": title.value})
						if err != nil {
							return err
						}
						return e.emit(data, func() error { return printAttachment(e, data) })
					}
				},
			},
			{
				name:    "photo",
				args:    "<item|stock|location|class> <ref> <attachment-id|none>",
				summary: "Make one of an object's image attachments its photo (item photo, …), or none.",
				params:  withID,
				setup: simple(func(e *env, args []string) error {
					if err := wantArgs(args, 3, 3); err != nil {
						return err
					}
					path, err := e.targetPath(args[0], args[1])
					if err != nil {
						return err
					}
					var photo any
					if !isNone(args[2]) {
						if !isUUID(args[2]) {
							return usagef("attachments are named by id; 'wtf attachment list TYPE REF' shows them")
						}
						photo = strings.ToLower(args[2])
					}
					if _, err := e.do(http.MethodPatch, path, object{"photo": photo}); err != nil {
						return err
					}
					if !e.json {
						if photo == nil {
							fmt.Fprintf(e.stdout, "No %s.\n", photoName(args[0]))
						} else {
							fmt.Fprintf(e.stdout, "%s set.\n", capitalize(photoName(args[0])))
						}
					}
					return nil
				}),
			},
			{
				name:    "delete",
				args:    "<item|stock|location|class> <ref> <attachment-id>",
				summary: "Delete an attachment (it can be restored, until it is purged).",
				params:  withID,
				setup: simple(func(e *env, args []string) error {
					path, err := e.attachmentPath(args)
					if err != nil {
						return err
					}
					if _, err := e.do(http.MethodDelete, path, nil); err != nil {
						return err
					}
					if !e.json {
						fmt.Fprintf(e.stdout, "Deleted attachment %s.\n", args[2])
					}
					return nil
				}),
			},
			{
				name:    "restore",
				args:    "<item|stock|location|class> <ref> <attachment-id>",
				summary: "Restore a deleted attachment (as an ordinary one, not the photo it may have been).",
				params:  withID,
				setup: simple(func(e *env, args []string) error {
					path, err := e.attachmentPath(args)
					if err != nil {
						return err
					}
					data, err := e.do(http.MethodPost, path+"/restore", object{})
					if err != nil {
						return err
					}
					return e.emit(data, func() error { return printAttachment(e, data) })
				}),
			},
		},
	}
}

// photoName names the photo of an object of type ("item", …): "item
// photo", "stock row photo", "location photo" or "class photo".
func photoName(typ string) string {
	if typ == "stock" {
		return "stock row photo"
	}
	return typ + " photo"
}

// capitalize upper-cases the first letter of an ASCII text.
func capitalize(s string) string {
	if s == "" {
		return s
	}
	return strings.ToUpper(s[:1]) + s[1:]
}

// attachmentPath is the path of an attachment named by TYPE REF ID:
// /items/{id}/attachments/{attachment}, and so on.
func (e *env) attachmentPath(args []string) (string, error) {
	if err := wantArgs(args, 3, 3); err != nil {
		return "", err
	}
	if !isUUID(args[2]) {
		return "", usagef("attachments are named by id; 'wtf attachment list TYPE REF' shows them")
	}
	path, err := e.targetPath(args[0], args[1])
	if err != nil {
		return "", err
	}
	return path + "/attachments/" + strings.ToLower(args[2]), nil
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
						t := newTable(e.stdout, "NAME", "TYPE")
						for _, q := range list {
							t.row(q.Name, q.Datatype)
						}
						t.flush()
						return nil
					})
				}),
			},
			{
				name:    "get",
				args:    "<quantity>",
				summary: "Show a quantity with its unit families and their units.",
				params:  []param{arg("Quantity", completeQuantities)},
				setup: simple(func(e *env, args []string) error {
					if err := wantArgs(args, 1, 1); err != nil {
						return err
					}
					id, err := e.resolveQuantity(args[0])
					if err != nil {
						return err
					}
					data, err := e.api.Get(e.ctx, "/quantities/"+strconv.Itoa(id), nil)
					if err != nil {
						return err
					}
					return e.emit(data, func() error {
						var q quantity
						if err := decode(data, &q); err != nil {
							return err
						}
						fields(e.stdout, "Name", q.Name, "Type", q.Datatype)
						var units []unit
						for _, f := range q.Families {
							units = append(units, f.Units...)
						}
						printUnits(e, units)
						return nil
					})
				}),
			},
		},
	}
}

func printUnits(e *env, units []unit) {
	t := newTable(e.stdout, "SYMBOL", "NAME", "FAMILY", "QUANTITY", "FACTOR", "OFFSET")
	for _, u := range units {
		offset := u.BaseOffset.String()
		if offset == "0" {
			offset = ""
		}
		t.row(u.Symbol, u.Name, u.Family.Name, u.Quantity.Name, u.BaseFactor.String(), offset)
	}
	t.flush()
}

func unitsGroup() group {
	return group{
		name:    "unit",
		summary: "Units of measurement (system data)",
		commands: []command{
			{
				name:    "list",
				args:    "[--quantity Q] [--family F]",
				summary: "List units: base = value × factor + offset.",
				flags: map[string]param{
					"quantity": arg("Quantity", completeQuantities),
					"family":   arg("Unit family", completeFamilies),
				},
				setup: func(fs *flag.FlagSet) func(*env, []string) error {
					q := fs.String("quantity", "", "only units of this quantity")
					f := fs.String("family", "", "only units of this unit family")
					return func(e *env, args []string) error {
						if err := wantArgs(args, 0, 0); err != nil {
							return err
						}
						v := url.Values{}
						if *q != "" {
							id, err := e.resolveQuantity(*q)
							if err != nil {
								return err
							}
							v.Set("quantity", strconv.Itoa(id))
						}
						if *f != "" {
							id, err := e.resolveFamily(*f)
							if err != nil {
								return err
							}
							v.Set("family", strconv.Itoa(id))
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
				summary: "Show a unit, named by symbol, name or id; \"B (Binary bytes)\" where families share a symbol.",
				params:  []param{arg("Unit", completeUnits)},
				setup: simple(func(e *env, args []string) error {
					if err := wantArgs(args, 1, 1); err != nil {
						return err
					}
					u, err := e.resolveUnit(args[0])
					if err != nil {
						return err
					}
					data, err := e.api.Get(e.ctx, "/units/"+strconv.Itoa(u.ID), nil)
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
			{
				name:    "import",
				args:    "<file> [--dry-run]",
				summary: "Import quantities, unit families and units from a unit file (seed/units-format.md); nothing that exists is changed.",
				params:  []param{fileArg("File")},
				setup: func(fs *flag.FlagSet) func(*env, []string) error {
					dryRun := fs.Bool("dry-run", false, "only tell what would be added, and the conflicts")
					return func(e *env, args []string) error {
						if err := wantArgs(args, 1, 1); err != nil {
							return err
						}
						file, err := os.ReadFile(args[0])
						if err != nil {
							return err
						}
						if !json.Valid(file) {
							return fmt.Errorf("%s is not JSON", args[0])
						}
						var q url.Values
						if *dryRun {
							q = url.Values{"dry_run": {"true"}}
						}
						data, _, err := e.api.Do(e.ctx, http.MethodPost, "/units/import", q, json.RawMessage(file))
						if err != nil {
							return err
						}
						e.wrote("/units/import")
						var report importReport
						if err := decode(data, &report); err != nil {
							return err
						}
						if err := e.emit(data, func() error {
							printImport(e, report)
							return nil
						}); err != nil {
							return err
						}
						if len(report.Conflicts) > 0 {
							return fmt.Errorf("nothing was imported: %d conflicts", len(report.Conflicts))
						}
						return nil
					}
				},
			},
		},
	}
}

// importReport is the answer of POST /units/import.
type importReport struct {
	Applied    bool `json:"applied"`
	DryRun     bool `json:"dry_run"`
	Quantities struct {
		Added, Existing []struct{ Name string }
	}
	Families struct {
		Added, Existing []struct{ Quantity, Name string }
	}
	Units struct {
		Added, Existing []struct{ Quantity, Family, Symbol, Name string }
	}
	Conflicts []struct{ Where, Message string }
}

// printImport tells what an import added (or would add), what was there
// already, and the conflicts.
func printImport(e *env, r importReport) {
	verb := "Added"
	if !r.Applied {
		verb = "Would add"
	}
	var lines []string
	for _, q := range r.Quantities.Added {
		lines = append(lines, "  quantity "+q.Name)
	}
	for _, f := range r.Families.Added {
		lines = append(lines, "  unit family "+f.Quantity+" › "+f.Name)
	}
	byFamily := map[string][]string{}
	var families []string
	for _, u := range r.Units.Added {
		key := u.Quantity + " › " + u.Family
		if byFamily[key] == nil {
			families = append(families, key)
		}
		byFamily[key] = append(byFamily[key], u.Symbol)
	}
	for _, f := range families {
		lines = append(lines, "  units "+strings.Join(byFamily[f], ", ")+" in "+f)
	}
	if len(lines) == 0 {
		fmt.Fprintln(e.stdout, "Nothing new.")
	} else {
		fmt.Fprintln(e.stdout, verb+":")
		for _, l := range lines {
			fmt.Fprintln(e.stdout, l)
		}
	}
	if n := len(r.Quantities.Existing) + len(r.Families.Existing) + len(r.Units.Existing); n > 0 {
		fmt.Fprintf(e.stdout, "Already there: %d quantities, %d unit families, %d units.\n",
			len(r.Quantities.Existing), len(r.Families.Existing), len(r.Units.Existing))
	}
	if len(r.Conflicts) > 0 {
		fmt.Fprintln(e.stdout, "Conflicts, so nothing was imported:")
		for _, c := range r.Conflicts {
			fmt.Fprintf(e.stdout, "  %s: %s\n", c.Where, c.Message)
		}
	}
}

func unitFamilyGroup() group {
	return group{
		name:    "unit-family",
		summary: "Unit families: units used together, such as mm, cm and m (system data)",
		commands: []command{
			{
				name:    "list",
				args:    "[--quantity Q]",
				summary: "List unit families with their units.",
				flags:   map[string]param{"quantity": arg("Quantity", completeQuantities)},
				setup: func(fs *flag.FlagSet) func(*env, []string) error {
					q := fs.String("quantity", "", "only families of this quantity")
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
							v = url.Values{"quantity": {strconv.Itoa(id)}}
						}
						data, err := e.api.Get(e.ctx, "/unit-families", v)
						if err != nil {
							return err
						}
						return e.emit(data, func() error {
							var list []unitFamily
							if err := decode(data, &list); err != nil {
								return err
							}
							t := newTable(e.stdout, "NAME", "QUANTITY", "UNITS")
							for _, f := range list {
								t.row(f.Name, f.Quantity.Name, unitSymbols(f.Units))
							}
							t.flush()
							return nil
						})
					}
				},
			},
			{
				name:    "get",
				args:    "<unit-family>",
				summary: "Show a unit family with its units.",
				params:  []param{arg("Unit family", completeFamilies)},
				setup: simple(func(e *env, args []string) error {
					if err := wantArgs(args, 1, 1); err != nil {
						return err
					}
					id, err := e.resolveFamily(args[0])
					if err != nil {
						return err
					}
					data, err := e.api.Get(e.ctx, "/unit-families/"+strconv.Itoa(id), nil)
					if err != nil {
						return err
					}
					return e.emit(data, func() error {
						var f unitFamily
						if err := decode(data, &f); err != nil {
							return err
						}
						fields(e.stdout, "Name", f.Name, "Quantity", f.Quantity.Name)
						printUnits(e, f.Units)
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
		summary: "Accounts (account privilege)",
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
			historyCommand("account", "/accounts/", "", resolveAccountFn),
		},
	}
}

// printAttachmentJSON prints an attachment.
func printAttachmentJSON(e *env, data json.RawMessage) error {
	var a attachment
	if err := decode(data, &a); err != nil {
		return err
	}
	fields(e.stdout,
		"Title", a.Title,
		"Type", a.Type,
		"Size", formatSize(a.Size),
		"SHA-256", a.Hash,
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
