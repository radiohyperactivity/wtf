package cli

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
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

// formatDisplay is "1.2 mm".
func formatDisplay(d *display) string {
	if d == nil {
		return ""
	}
	return d.Value.String() + " " + d.Unit.Symbol
}

// formatQuantity is a stock quantity: in its display unit, a plain count, or
// "uncounted".
func formatQuantity(q *json.Number, d *display) string {
	switch {
	case q == nil:
		return "uncounted"
	case d != nil:
		return formatDisplay(d)
	}
	return q.String()
}

// formatTotal is an item's total stock.
func formatTotal(t *stockTotal) string {
	if t == nil {
		return ""
	}
	s := t.Total.String()
	if t.Display != nil {
		s = formatDisplay(t.Display)
	}
	if t.Uncounted {
		if s == "0" {
			return "uncounted"
		}
		s += " + uncounted"
	}
	return s
}

// formatJSONValue renders a typed value: strings as they are, booleans as
// yes/no, choices by name.
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
	case map[string]any:
		if name, ok := x["name"].(string); ok {
			return name
		}
	}
	return strings.TrimSpace(string(raw))
}

// formatValue renders a value in its display unit when it has one.
func formatValue(v value) string {
	if v.Display != nil {
		return formatDisplay(v.Display)
	}
	return formatJSONValue(v.Value)
}

func formatSize(n int64) string {
	switch {
	case n >= 1<<30:
		return fmt.Sprintf("%.1f GiB", float64(n)/(1<<30))
	case n >= 1<<20:
		return fmt.Sprintf("%.1f MiB", float64(n)/(1<<20))
	case n >= 1<<10:
		return fmt.Sprintf("%.1f KiB", float64(n)/(1<<10))
	}
	return fmt.Sprintf("%d B", n)
}

func pathNames(p []ref) string {
	var names []string
	for _, r := range p {
		names = append(names, r.Name)
	}
	return strings.Join(names, "/")
}

func unitGroupName(g *unitGroup) string {
	if g == nil {
		return ""
	}
	return g.Name
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

// printValues prints attribute values as a table; defaults are marked.
func printValues(w io.Writer, indent string, values []value) {
	t := newTable(w)
	for _, v := range values {
		note := ""
		if v.IsDefault {
			note = "(default)"
		}
		t.row(indent+v.Attribute.Name+":", formatValue(v), note)
	}
	t.flush()
}

func printMissing(w io.Writer, indent string, missing []ref) {
	if len(missing) == 0 {
		return
	}
	var names []string
	for _, m := range missing {
		names = append(names, m.Name)
	}
	fmt.Fprintf(w, "%sMissing required: %s\n", indent, strings.Join(names, ", "))
}

func printAttachments(w io.Writer, indent string, list []attachment) {
	if len(list) == 0 {
		return
	}
	fmt.Fprintf(w, "%sAttachments:\n", indent)
	t := newTable(w)
	for _, a := range list {
		caption := ""
		if a.Caption != nil {
			caption = *a.Caption
		}
		photo := ""
		if a.PrimaryPhoto {
			photo = "primary photo"
		}
		t.row(indent+"  "+a.ID, a.FileName, a.ContentType, formatSize(a.Size), caption, photo)
	}
	t.flush()
}

// pageFooter tells how to see more rows of a paged list.
func (e *env) pageFooter(total, limit, offset, shown int) {
	if offset == 0 && shown >= total {
		return
	}
	if shown == 0 {
		fmt.Fprintf(e.stderr, "No rows at offset %d of %d.\n", offset, total)
		return
	}
	fmt.Fprintf(e.stderr, "Rows %d–%d of %d.", offset+1, offset+shown, total)
	if offset+shown < total {
		fmt.Fprintf(e.stderr, " Next: --offset %d", offset+shown)
	}
	fmt.Fprintln(e.stderr)
}

// historyLines formats history entries, newest first, one block per entry.
func historyLines(rows []historyEntry) []string {
	var lines []string
	for _, h := range rows {
		who := "(system)"
		if h.Account != nil {
			who = h.Account.Email
			if h.Account.Deleted {
				who += " (deleted)"
			}
		}
		when := h.HappenedAt
		if t, err := time.Parse(time.RFC3339Nano, h.HappenedAt); err == nil {
			when = t.Local().Format("2006-01-02 15:04:05")
		}
		lines = append(lines, fmt.Sprintf("%s  %s  %s %s%s", when, who, h.Operation, h.Table, historySubject(h)))
		if h.Operation == "update" {
			for _, k := range sortedKeys(h.Changes) {
				var c struct{ Old, New json.RawMessage }
				if err := json.Unmarshal(h.Changes[k], &c); err == nil && (c.Old != nil || c.New != nil) {
					lines = append(lines, fmt.Sprintf("    %s: %s → %s", k, compactJSON(c.Old), compactJSON(c.New)))
				} else {
					lines = append(lines, fmt.Sprintf("    %s: %s", k, formatJSONValue(h.Changes[k])))
				}
			}
		}
	}
	return lines
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

// historySubject names the changed row briefly, e.g. ` "Drill"`.
func historySubject(h historyEntry) string {
	for _, k := range []string{"name", "email", "file_name"} {
		if raw, ok := h.Data[k]; ok {
			var s string
			if json.Unmarshal(raw, &s) == nil && s != "" {
				return fmt.Sprintf(" %q", s)
			}
		}
	}
	return ""
}

func compactJSON(raw json.RawMessage) string {
	if raw == nil {
		return "null"
	}
	var buf bytes.Buffer
	if json.Compact(&buf, raw) != nil {
		return string(raw)
	}
	return buf.String()
}

func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
