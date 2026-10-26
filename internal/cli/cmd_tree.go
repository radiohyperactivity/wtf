package cli

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net/http"
	"net/url"
	"strings"

	"github.com/radiohyperactivity/wtf/internal/client"
)

// What class_delete_tree and location_delete_tree report.
type deletedClasses struct {
	Classes []struct {
		ID   string `json:"id"`
		Path string `json:"path"`
	} `json:"classes"`
	Items []struct {
		ID    string `json:"id"`
		Code  string `json:"code"`
		Name  string `json:"name"`
		Class string `json:"class"`
	} `json:"items"`
	Stock int `json:"stock"`
}

type deletedLocations struct {
	Locations []struct {
		ID   string `json:"id"`
		Code string `json:"code"`
		Path string `json:"path"`
	} `json:"locations"`
	Stock []struct {
		ID   string `json:"id"`
		Code string `json:"code"`
		Item struct {
			Code string `json:"code"`
			Name string `json:"name"`
		} `json:"item"`
		Location string       `json:"location"`
		Quantity *json.Number `json:"quantity"`
	} `json:"stock"`
}

// treeDeleteCommand deletes a class or location, with --recursive also
// everything below it, in one transaction on the server.
func treeDeleteCommand(kind, prefix string, resolve func(*env, string) (string, error)) command {
	plural := map[string]string{"class": "classes", "location": "locations"}[kind]
	users := map[string]string{"class": "items", "location": "stock rows"}[kind]
	return command{
		name:    "delete",
		args:    "<" + kind + "> [--recursive [--force]] [--yes] [--verbose]",
		summary: "Delete " + article(kind) + "; with --recursive also everything below it, and with --force also its " + users + ".",
		params:  []param{objectParam(kind)},
		setup: func(fs *flag.FlagSet) func(*env, []string) error {
			recursive := fs.Bool("recursive", false, "also delete the "+plural+" below it (all or nothing)")
			force := fs.Bool("force", false, "with --recursive: also delete the "+users+" of the deleted "+plural)
			yes := fs.Bool("yes", false, "don't ask before a recursive delete (needed in scripts)")
			verbose := fs.Bool("verbose", false, "list everything a recursive delete deletes")
			return func(e *env, args []string) error {
				if err := wantArgs(args, 1, 1); err != nil {
					return err
				}
				if *force && !*recursive {
					return usagef("--force only works with --recursive")
				}
				id, err := resolve(e, args[0])
				if err != nil {
					return err
				}
				if !*recursive {
					_, err := e.do(http.MethodDelete, prefix+id, nil)
					var p *client.Problem
					if errors.As(err, &p) && p.Status == http.StatusConflict {
						return fmt.Errorf("%w\nTo delete everything below it as well, add --recursive (and --force for its %s).", err, users)
					}
					if err != nil {
						return err
					}
					e.deleted(kind + " " + args[0])
					return nil
				}

				// The preview is a GET, so a server without recursive deletes
				// answers 404 (an unknown route has no SQLSTATE) instead of
				// deleting anything.
				plan, err := e.api.Get(e.ctx, prefix+id+"/deletion", url.Values{"force": {fmt.Sprint(*force)}})
				var p *client.Problem
				if errors.As(err, &p) && p.Status == http.StatusNotFound && p.SQLState == "" {
					return errors.New("the server doesn't support recursive deletes yet; nothing was deleted\nUpdate wtfd (wtfd schema, then restart wtfd serve).")
				}
				if err != nil {
					return err
				}
				var s treeDeletion
				if kind == "class" {
					s, err = classDeletion(plan)
				} else {
					s, err = locationDeletion(plan)
				}
				if err != nil {
					return err
				}
				if len(s.inUse) > 0 && !*force {
					return fmt.Errorf("nothing was deleted: these %s still have %s: %s\nTo delete those as well, add --force.",
						plural, users, strings.Join(s.inUse, ", "))
				}
				if *verbose {
					for _, line := range s.listing {
						fmt.Fprintln(e.stderr, line)
					}
				}
				if !*yes {
					if e.term == nil {
						return fmt.Errorf("a recursive delete must be confirmed: %s\nAdd --yes to confirm it without being asked.", s.question)
					}
					answer, err := e.term.ReadLine(s.question+"? [y/N] ", "", nil)
					if err != nil {
						return err
					}
					if a := strings.ToLower(strings.TrimSpace(answer)); a != "y" && a != "yes" {
						return errors.New("nothing was deleted")
					}
				}
				data, _, err := e.api.Do(e.ctx, http.MethodDelete, prefix+id, url.Values{"recursive": {"true"}, "force": {fmt.Sprint(*force)}}, nil)
				if err != nil {
					return err
				}
				return e.emit(data, func() error {
					fmt.Fprintf(e.stdout, "Deleted %s.\n", s.summary)
					return nil
				})
			}
		},
	}
}

// treeDeletion describes a recursive delete for the user.
type treeDeletion struct {
	question string   // "Delete class MCU/Intel and the 3 classes below it"
	summary  string   // "4 classes, 2 items and 3 stock rows"
	inUse    []string // "MCU/Intel/No (2 items)"
	listing  []string // everything, for --verbose
}

func classDeletion(data json.RawMessage) (treeDeletion, error) {
	var d deletedClasses
	if err := decode(data, &d); err != nil || len(d.Classes) == 0 {
		return treeDeletion{}, errors.New("unexpected answer to a recursive delete")
	}
	top := d.Classes[len(d.Classes)-1] // deepest first, so the class itself is last
	t := treeDeletion{question: "Delete class " + top.Path}
	if n := len(d.Classes) - 1; n > 0 {
		t.question += fmt.Sprintf(" and the %s below it", count(n, "class", "classes"))
	}
	if len(d.Items) > 0 {
		t.question += ", with " + joinCounts(count(len(d.Items), "item", "items"), count(d.Stock, "stock row", "stock rows"))
	}
	t.summary = joinCounts(count(len(d.Classes), "class", "classes"), count(len(d.Items), "item", "items"), count(d.Stock, "stock row", "stock rows"))

	paths := map[string]string{}
	perClass := map[string]int{}
	t.listing = append(t.listing, fmt.Sprintf("Classes (%d):", len(d.Classes)))
	for i := len(d.Classes) - 1; i >= 0; i-- {
		c := d.Classes[i]
		paths[c.ID] = c.Path
		t.listing = append(t.listing, "  "+c.Path)
	}
	if len(d.Items) > 0 {
		t.listing = append(t.listing, fmt.Sprintf("Items (%d), with %s:", len(d.Items), count(d.Stock, "stock row", "stock rows")))
		var rows [][]string
		for _, it := range d.Items {
			perClass[it.Class]++
			rows = append(rows, []string{"  " + it.Code, it.Name, "(" + paths[it.Class] + ")"})
		}
		t.listing = append(t.listing, tableLines(nil, rows, false)...)
	}
	for i := len(d.Classes) - 1; i >= 0; i-- {
		if n := perClass[d.Classes[i].ID]; n > 0 {
			t.inUse = append(t.inUse, fmt.Sprintf("%s (%s)", d.Classes[i].Path, count(n, "item", "items")))
		}
	}
	return t, nil
}

func locationDeletion(data json.RawMessage) (treeDeletion, error) {
	var d deletedLocations
	if err := decode(data, &d); err != nil || len(d.Locations) == 0 {
		return treeDeletion{}, errors.New("unexpected answer to a recursive delete")
	}
	top := d.Locations[len(d.Locations)-1]
	t := treeDeletion{question: "Delete location " + top.Path}
	if n := len(d.Locations) - 1; n > 0 {
		t.question += fmt.Sprintf(" and the %s below it", count(n, "location", "locations"))
	}
	if len(d.Stock) > 0 {
		t.question += fmt.Sprintf(", with %s", count(len(d.Stock), "stock row", "stock rows"))
	}
	t.summary = joinCounts(count(len(d.Locations), "location", "locations"), count(len(d.Stock), "stock row", "stock rows"))

	paths := map[string]string{}
	perLocation := map[string]int{}
	t.listing = append(t.listing, fmt.Sprintf("Locations (%d):", len(d.Locations)))
	var rows [][]string
	for i := len(d.Locations) - 1; i >= 0; i-- {
		l := d.Locations[i]
		paths[l.ID] = l.Path
		rows = append(rows, []string{"  " + l.Code, l.Path})
	}
	t.listing = append(t.listing, tableLines(nil, rows, false)...)
	if len(d.Stock) > 0 {
		t.listing = append(t.listing, fmt.Sprintf("Stock rows (%d):", len(d.Stock)))
		rows = nil
		for _, s := range d.Stock {
			perLocation[s.Location]++
			rows = append(rows, []string{"  " + s.Code, s.Item.Name, formatQuantity(s.Quantity, nil), "at " + paths[s.Location]})
		}
		t.listing = append(t.listing, tableLines(nil, rows, false)...)
	}
	for i := len(d.Locations) - 1; i >= 0; i-- {
		if n := perLocation[d.Locations[i].ID]; n > 0 {
			t.inUse = append(t.inUse, fmt.Sprintf("%s (%s)", d.Locations[i].Path, count(n, "stock row", "stock rows")))
		}
	}
	return t, nil
}

// count is "1 class" or "3 classes".
func count(n int, one, many string) string {
	if n == 1 {
		return "1 " + one
	}
	return fmt.Sprintf("%d %s", n, many)
}

// joinCounts joins the non-zero counts: "4 classes, 2 items and 3 stock rows".
func joinCounts(parts ...string) string {
	var kept []string
	for _, p := range parts {
		if !strings.HasPrefix(p, "0 ") {
			kept = append(kept, p)
		}
	}
	if len(kept) <= 1 {
		return strings.Join(kept, "")
	}
	return strings.Join(kept[:len(kept)-1], ", ") + " and " + kept[len(kept)-1]
}
