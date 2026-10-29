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
	"strings"
)

// modelGroup imports and exports model files: quantities and units,
// attributes and a tree of classes set up for one use
// (seed/model-format.md).
func modelGroup() group {
	return group{
		name:    "model",
		summary: "Model files: units, attributes and classes for one use, such as microcontrollers",
		commands: []command{
			{
				name:    "import",
				args:    "<file> [--parent CLASS] [--dry-run]",
				summary: "Import units, attributes and classes from a model file (seed/model-format.md); what is there and the same is used as it is.",
				params:  []param{fileArg("File")},
				flags:   map[string]param{"parent": arg("Class", completeClasses)},
				setup: func(fs *flag.FlagSet) func(*env, []string) error {
					parent := fs.String("parent", "", "import the file's classes below this class, instead of at the top")
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
						// New units, classes and attributes: the cached ones go.
						e.wrote("/quantities")
						e.wrote("/classes")
						e.wrote("/attributes")
						var report modelReport
						if err := decode(data, &report); err != nil {
							return err
						}
						if err := e.emit(data, func() error {
							printModelImport(e, report)
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
			{
				name:    "export",
				args:    "<class> [-o FILE] [--force]",
				summary: "Export a class and everything below it as a model file, with the attributes and units of your own it needs.",
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
	Applied     bool `json:"applied"`
	DryRun      bool `json:"dry_run"`
	Quantities  struct{ Added, Existing []string }
	Families    struct{ Added, Existing []string }
	Units       struct{ Added, Existing []string }
	Attributes  struct{ Added, Existing []string }
	Options     struct{ Added []string }
	Classes     struct{ Added, Existing []string }
	Assignments struct{ Added, Existing []string }
	Conflicts   []struct{ Where, Message string }
}

// printModelImport tells what an import added (or would add), how much was
// there already, and the conflicts.
func printModelImport(e *env, r modelReport) {
	verb := "Added"
	if !r.Applied {
		verb = "Would add"
	}
	var lines []string
	add := func(what string, names []string) {
		for _, n := range names {
			lines = append(lines, "  "+what+" "+n)
		}
	}
	add("quantity", r.Quantities.Added)
	add("unit family", r.Families.Added)
	add("unit", r.Units.Added)
	add("attribute", r.Attributes.Added)
	add("option", r.Options.Added)
	add("class", r.Classes.Added)
	add("assignment", r.Assignments.Added)
	if len(lines) == 0 {
		fmt.Fprintln(e.stdout, "Nothing new.")
	} else {
		fmt.Fprintln(e.stdout, verb+":")
		for _, l := range lines {
			fmt.Fprintln(e.stdout, l)
		}
	}
	var there []string
	for _, c := range []struct {
		n         int
		one, many string
	}{
		{len(r.Quantities.Existing), "quantity", "quantities"},
		{len(r.Families.Existing), "unit family", "unit families"},
		{len(r.Units.Existing), "unit", "units"},
		{len(r.Attributes.Existing), "attribute", "attributes"},
		{len(r.Classes.Existing), "class", "classes"},
		{len(r.Assignments.Existing), "assignment", "assignments"},
	} {
		if c.n == 1 {
			there = append(there, "1 "+c.one)
		} else if c.n > 1 {
			there = append(there, fmt.Sprintf("%d %s", c.n, c.many))
		}
	}
	if len(there) > 0 {
		fmt.Fprintf(e.stdout, "Already there: %s.\n", strings.Join(there, ", "))
	}
	if len(r.Conflicts) > 0 {
		fmt.Fprintln(e.stdout, "Conflicts, so nothing was imported:")
		for _, c := range r.Conflicts {
			fmt.Fprintf(e.stdout, "  %s: %s\n", c.Where, c.Message)
		}
	}
}
