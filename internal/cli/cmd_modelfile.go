package cli

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	iofs "io/fs"
	"net/http"
	"net/url"
	"os"
)

// modelGroup imports and exports model files: quantities and units,
// attributes and a tree of classes set up for one use
// (seed/model-format.md).
func modelGroup() group {
	return group{
		name:    "model",
		summary: "Model files: classes with their attributes for one use, such as microcontrollers",
		commands: []command{
			{
				name:    "import",
				args:    "<file> [--parent CLASS] [--dry-run]",
				summary: "Import classes and their attributes from a model file (seed/model-format.md); a class that is there gets what it hasn't got.",
				params:  []param{fileArg("File")},
				flags:   map[string]param{"parent": arg("Class", completeClasses)},
				setup: func(fs *flag.FlagSet) func(*env, []string) error {
					parent := fs.String("parent", "", "import the file's classes below this class, instead of at the top")
					dryRun := fs.Bool("dry-run", false, "only tell what would be added")
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
						q := url.Values{}
						if *parent != "" {
							id, err := e.resolveClass(*parent)
							if err != nil {
								return err
							}
							q.Set("parent", id)
						}
						if *dryRun {
							q.Set("dry_run", "true")
						}
						data, _, err := e.api.Do(e.ctx, http.MethodPost, "/model/import", q, json.RawMessage(file))
						if err != nil {
							return err
						}
						// New classes and attributes: the cached ones go.
						e.wrote("/classes")
						var report modelReport
						if err := e.decode(data, &report); err != nil {
							return err
						}
						return e.emit(data, func() error {
							printModelImport(e, report)
							return nil
						})
					}
				},
			},
			{
				name:    "export",
				args:    "<class> [-o FILE] [--force]",
				summary: "Export a class and everything below it as a model file, with their attributes.",
				params:  []param{arg("Class", completeClasses)},
				flags:   map[string]param{"o": fileArg("Output file")},
				setup: func(fs *flag.FlagSet) func(*env, []string) error {
					out := fs.String("o", "", "output file; without it, the file goes to stdout")
					force := fs.Bool("force", false, "overwrite an existing file")
					return func(e *env, args []string) error {
						if err := wantArgs(args, 1, 1); err != nil {
							return err
						}
						id, err := e.resolveClass(args[0])
						if err != nil {
							return err
						}
						data, err := e.api.Get(e.ctx, "/classes/"+id+"/model", nil)
						if err != nil {
							return err
						}
						var file bytes.Buffer
						if err := json.Indent(&file, data, "", "  "); err != nil {
							return err
						}
						file.WriteByte('\n')
						if *out == "" || *out == "-" {
							_, err := file.WriteTo(e.stdout)
							return err
						}
						flags := os.O_WRONLY | os.O_CREATE | os.O_EXCL
						if *force {
							flags = os.O_WRONLY | os.O_CREATE | os.O_TRUNC
						}
						f, err := os.OpenFile(*out, flags, 0o644)
						if errors.Is(err, iofs.ErrExist) {
							return fmt.Errorf("%s exists; use --force to overwrite it", *out)
						}
						if err != nil {
							return err
						}
						_, err = file.WriteTo(f)
						if cerr := f.Close(); err == nil {
							err = cerr
						}
						if err != nil {
							return err
						}
						if !e.json {
							fmt.Fprintf(e.stdout, "Saved %s.\n", *out)
						}
						return nil
					}
				},
			},
		},
	}
}

// modelReport is the answer of POST /model/import.
type modelReport struct {
	Classes    struct{ Added, Existing int }
	Attributes struct{ Added, Existing int }
	Items      int  `json:"items"`
	Stock      int  `json:"stock"`
	DryRun     bool `json:"dry_run"`
}

// printModelImport tells what an import added (or would add), and how much
// was there already.
func printModelImport(e *env, r modelReport) {
	verb, rewrote := "Added", "Rewrote"
	if r.DryRun {
		verb, rewrote = "A dry run: nothing changed. It would add", "It would rewrite"
	}
	added := joinCounts(count(r.Classes.Added, "class", "classes"), count(r.Attributes.Added, "attribute", "attributes"))
	if added == "" {
		fmt.Fprintln(e.stdout, "Nothing new.")
	} else {
		fmt.Fprintf(e.stdout, "%s %s.\n", verb, added)
	}
	if there := joinCounts(count(r.Classes.Existing, "class", "classes"), count(r.Attributes.Existing, "attribute", "attributes")); there != "" {
		fmt.Fprintf(e.stdout, "Already there: %s.\n", there)
	}
	if rows := joinCounts(count(r.Items, "item", "items"), count(r.Stock, "stock row", "stock rows")); rows != "" {
		fmt.Fprintf(e.stdout, "%s %s.\n", rewrote, rows)
	}
}
