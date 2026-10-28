package cli

import (
	"encoding/json"
	"flag"
	"fmt"
	"net/http"
	"net/url"
	"os"
)

// modelGroup imports model files: attributes and a tree of classes set up
// for one use (seed/model-format.md).
func modelGroup() group {
	return group{
		name:    "model",
		summary: "Model files: attributes and classes for one use, such as microcontrollers",
		commands: []command{
			{
				name:    "import",
				args:    "<file> [--parent CLASS] [--dry-run]",
				summary: "Import attributes and classes from a model file (seed/model-format.md); what is there and the same is used as it is.",
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
						// New classes and attributes: the cached tree and list go.
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
		},
	}
}

// modelReport is the answer of POST /model/import.
type modelReport struct {
	Applied     bool `json:"applied"`
	DryRun      bool `json:"dry_run"`
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
	for _, a := range r.Attributes.Added {
		lines = append(lines, "  attribute "+a)
	}
	for _, o := range r.Options.Added {
		lines = append(lines, "  option "+o)
	}
	for _, c := range r.Classes.Added {
		lines = append(lines, "  class "+c)
	}
	for _, a := range r.Assignments.Added {
		lines = append(lines, "  assignment "+a)
	}
	if len(lines) == 0 {
		fmt.Fprintln(e.stdout, "Nothing new.")
	} else {
		fmt.Fprintln(e.stdout, verb+":")
		for _, l := range lines {
			fmt.Fprintln(e.stdout, l)
		}
	}
	if n := len(r.Attributes.Existing) + len(r.Classes.Existing) + len(r.Assignments.Existing); n > 0 {
		fmt.Fprintf(e.stdout, "Already there: %d attributes, %d classes, %d assignments.\n",
			len(r.Attributes.Existing), len(r.Classes.Existing), len(r.Assignments.Existing))
	}
	if len(r.Conflicts) > 0 {
		fmt.Fprintln(e.stdout, "Conflicts, so nothing was imported:")
		for _, c := range r.Conflicts {
			fmt.Fprintf(e.stdout, "  %s: %s\n", c.Where, c.Message)
		}
	}
}
