package cli

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"slices"
	"sort"
	"strings"
	"text/tabwriter"
	"time"
)

// emit prints the API's JSON with --json, or calls human otherwise.
func (e *env) emit(data json.RawMessage, human func() error) error {
	if e.json {
		return e.printJSON(data)
	}
	return human()
}

// printJSON pretty-prints JSON unchanged in content.
func (e *env) printJSON(data json.RawMessage) error {
	if len(data) == 0 {
		return nil
	}
	var buf bytes.Buffer
	if err := json.Indent(&buf, data, "", "  "); err != nil {
		_, err = e.stdout.Write(data)
		return err
	}
	buf.WriteByte('\n')
	_, err := buf.WriteTo(e.stdout)
	return err
}

// table writes aligned columns.
type table struct{ tw *tabwriter.Writer }

func newTable(w io.Writer, header ...string) *table {
	t := &table{tabwriter.NewWriter(w, 0, 0, 2, ' ', 0)}
	if len(header) > 0 {
		t.row(header...)
	}
	return t
}

func (t *table) row(cells ...string) {
	for len(cells) > 1 && cells[len(cells)-1] == "" {
		cells = cells[:len(cells)-1]
	}
	for i, c := range cells {
		cells[i] = strings.ReplaceAll(c, "\t", " ")
	}
	fmt.Fprintln(t.tw, strings.Join(cells, "\t"))
}

func (t *table) flush() { t.tw.Flush() }

// fields writes "Label:  value" lines, skipping empty values.
func fields(w io.Writer, pairs ...string) {
	t := newTable(w)
	for i := 0; i+1 < len(pairs); i += 2 {
		if pairs[i+1] != "" {
			t.row(pairs[i]+":", pairs[i+1])
		}
	}
	t.flush()
}

// formatAmount is a stock amount, with the item's unit (nil: pieces), or
// "uncounted".
func formatAmount(q *json.Number, unit *string) string {
	switch {
	case q == nil:
		return "uncounted"
	case unit != nil:
		return q.String() + " " + *unit
	}
	return q.String()
}

// formatTotal is an item's total stock, with its unit.
func formatTotal(t *stockTotal, unit *string) string {
	if t == nil {
		return ""
	}
	s := t.Total.String()
	if unit != nil {
		s += " " + *unit
	}
	if t.Uncounted {
		if t.Total.String() == "0" {
			return "uncounted"
		}
		s += " + uncounted"
	}
	return s
}

// formatJSONValue renders a value: strings as they are, booleans as yes/no.
func formatJSONValue(raw json.RawMessage) string {
	var v any
	if err := decode(raw, &v); err != nil || v == nil {
		return ""
	}
	switch x := v.(type) {
	case string:
		return x
	case bool:
		if x {
			return "yes"
		}
		return "no"
	case json.Number:
		return x.String()
	}
	return strings.TrimSpace(string(raw))
}

// formatAttributeValue renders a value of attribute a: with its unit label,
// and a file by the start of its hash.
func formatAttributeValue(a attribute, raw json.RawMessage) string {
	s := formatJSONValue(raw)
	switch {
	case a.Type == "attachment":
		return "file " + shortHash(s)
	case a.Unit != "":
		return s + " " + a.Unit
	}
	return s
}

// shortHash is the start of a file's hash, enough to tell files apart.
func shortHash(h string) string {
	if len(h) > 12 {
		return h[:12]
	}
	return h
}

func pathNames(p []ref) string {
	var names []string
	for _, r := range p {
		names = append(names, r.Name)
	}
	return strings.Join(names, "/")
}

func yesNo(b bool) string {
	if b {
		return "yes"
	}
	return ""
}

// printTree prints nested nodes, indented, with codes if they have them.
// Containers end with "/": they hold only other nodes.
func printTree(w io.Writer, nodes []*node) {
	var walk func([]*node, string)
	walk = func(nodes []*node, indent string) {
		for _, n := range nodes {
			name := n.Name
			if n.Container {
				name += "/"
			}
			if n.Code != "" {
				fmt.Fprintf(w, "%-6s %s%s\n", n.Code, indent, name)
			} else {
				fmt.Fprintf(w, "%s%s\n", indent, name)
			}
			walk(n.Children, indent+"  ")
		}
	}
	walk(nodes, "")
}

// printValues prints the values of an item or a stock row (scope) of class
// c as a table, in the class's order, the defaults it follows marked.
// Values of attributes the class doesn't list (it changed since) come last.
func printValues(w io.Writer, indent string, c class, scope string, vals values, defaulted []string) {
	t := newTable(w)
	seen := map[string]bool{}
	row := func(a attribute, raw json.RawMessage) {
		note := ""
		if slices.Contains(defaulted, a.Name) {
			note = "(default)"
		}
		t.row(indent+a.Name+":", formatAttributeValue(a, raw), note)
	}
	for _, a := range c.Attributes {
		if raw, ok := vals[a.Name]; ok && a.Scope == scope {
			row(a, raw)
			seen[a.Name] = true
		}
	}
	for _, name := range sortedKeys(vals) {
		if !seen[name] {
			row(attribute{Name: name}, vals[name])
		}
	}
	t.flush()
}

// pageFooter says that more rows follow a page, and how to see them.
func (e *env) pageFooter(more bool) {
	if more {
		fmt.Fprintln(e.stderr, "More rows follow; add --all to show them all.")
	}
}

// localTime shows an API timestamp in local time, to the second.
func localTime(at string) string {
	if t, err := time.Parse(time.RFC3339Nano, at); err == nil {
		return t.Local().Format("2006-01-02 15:04:05")
	}
	return at
}

// tableLines renders rows with aligned columns and returns the lines.
func tableLines(header []string, rows [][]string, withHeader bool) []string {
	var buf bytes.Buffer
	t := newTable(&buf)
	if withHeader {
		t.row(header...)
	}
	for _, r := range rows {
		t.row(r...)
	}
	t.flush()
	out := strings.Split(strings.TrimSuffix(buf.String(), "\n"), "\n")
	if len(out) == 1 && out[0] == "" {
		return nil
	}
	return out
}

func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
