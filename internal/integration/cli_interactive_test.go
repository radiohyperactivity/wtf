package integration

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"strings"
	"testing"

	"github.com/radiohyperactivity/wtf/internal/cli"
	"github.com/radiohyperactivity/wtf/internal/prompt"
)

// keys returns one scripted chunk per Read, as a terminal delivers input.
type keys []string

func (k *keys) Read(p []byte) (int, error) {
	if len(*k) == 0 {
		return 0, io.EOF
	}
	n := copy(p, (*k)[0])
	*k = (*k)[1:]
	return n, nil
}

// interact runs wtf as if stdin and stderr (and with pager, stdout) were a
// terminal, typing the given keys.
func (c *cliEnv) interact(input []string, pager bool, args ...string) (string, string) {
	c.t.Helper()
	return c.interactExit(0, input, pager, args...)
}

// interactExit is interact, expecting the given exit code.
func (c *cliEnv) interactExit(want int, input []string, pager bool, args ...string) (string, string) {
	c.t.Helper()
	var stdout, stderr bytes.Buffer
	in := keys(input)
	cli.OpenTerminal = func(_ io.Reader, out io.Writer) *prompt.Terminal {
		if out == &stderr || (pager && out == &stdout) {
			return prompt.New(&in, out)
		}
		return nil
	}
	defer func() { cli.OpenTerminal = func(io.Reader, io.Writer) *prompt.Terminal { return nil } }()
	getenv := func(name string) string {
		if name == "WTF_CONFIG" {
			return c.config
		}
		return c.vars[name]
	}
	if code := cli.Run(context.Background(), args, strings.NewReader(""), &stdout, &stderr, getenv); code != want {
		c.t.Fatalf("wtf %s: exit %d, want %d\nstdout: %s\nstderr: %s", strings.Join(args, " "), code, want, stdout.String(), stderr.String())
	}
	if len(in) > 0 {
		c.t.Errorf("wtf %s: keys left over: %q", strings.Join(args, " "), []string(in))
	}
	return stdout.String(), stderr.String()
}

func TestCLIInteractive(t *testing.T) {
	e := setup(t)
	e.reset(t)
	c := e.cli(t)
	cli.OpenTerminal = func(io.Reader, io.Writer) *prompt.Terminal { return nil }

	c.ok("location", "add", "Garage")
	c.ok("location", "add", "Shelf 2", "--parent", "Garage")
	c.ok("attribute", "add", "Length", "--type", "float", "--unit-group", "Metric length")
	c.ok("attribute", "add", "Colour", "--type", "choice")
	c.ok("option", "add", "Colour", "red", "blue")
	c.ok("attribute", "add", "Serial", "--type", "text")
	c.ok("class", "add", "Hardware")
	c.ok("class", "add", "Screws", "--parent", "Hardware")
	c.ok("class", "assign", "Screws", "Length", "--required")
	c.ok("class", "assign", "Screws", "Colour", "--default", "red")
	c.ok("class", "assign", "Screws", "Serial", "--per-unit")

	// A bare "item add" asks for everything: name, class (Tab completes
	// "Scr" to the path), unit group (skipped), the required Length, then
	// the optional Colour (picked with Tab Tab, filtering on "bl").
	out, prompts := c.interact([]string{"M3 screw\r", "Scr", "\t", "\r", "\r", "12mm\r", "\t", "\t", "b", "l", "\r", "\r", "\r"}, false, "item", "add") // the last: no stock
	contains(t, prompts, "Name: ", "Class: ", "Unit group", "Length (required) (Metric length): ", "Colour [red]")
	contains(t, out, "M3 screw", "Hardware/Screws", "1.2 cm", "blue")

	// Stock: the location by Tab, a quantity, and the per-unit Serial.
	out, _ = c.interact([]string{"Garage/Sh\t\r", "50\r", "S-1\r"}, false, "stock", "add", "M3 screw")
	contains(t, out, "Garage/Shelf 2", "50", "S-1")

	// With a complete command line only the missing required value is asked
	// for, again until it parses.
	out, prompts = c.interact([]string{"3kg\r", "3mm\r", "\r"}, false, "item", "add", "M4 screw", "--class", "Screws")
	contains(t, prompts, "Length (required)", "unknown unit")
	contains(t, out, "3 mm", "red")
	if strings.Contains(prompts, "Colour") || strings.Contains(prompts, "Unit group") {
		t.Errorf("optional data was offered:\n%s", prompts)
	}
	_, prompts = c.interact([]string{"red\r"}, false, "item", "value-set", "M3 screw", "Colour")
	contains(t, prompts, "Value: ")

	// Shell completion.
	contains(t, c.ok("__complete", "zsh", "location", "get", "gar"), "Garage\n", "Garage/\n")
	contains(t, c.ok("__complete", "bash", "wtf location get Garage/Sh", "Garage/Sh"), `Garage/Shelf\ 2 `)
	contains(t, c.ok("__complete", "bash", "wtf item add X --value Colour=b", "b"), "blue ")
	contains(t, c.ok("__complete", "zsh", "item", "get", "m3"), "M3 screw")
	contains(t, c.ok("__complete", "zsh", "stock", "move", "M3 screw@"), "M3 screw@Garage/Shelf 2")
	contains(t, c.ok("__complete", "zsh", "item", "value-set", "M3 screw", "Length", "5"), "5mm", "5cm")
	contains(t, c.ok("__complete", "powershell", "w:location", "w:get", "w:"), "Garage\n", "Garage/\n")
	contains(t, c.ok("__complete", "powershell", "w:location", "w:get", "w:Garage/"), "Garage/Shelf 2")
	contains(t, c.ok("__complete", "zsh", "option", "delete", "Colour", ""), "blue", "red")
	contains(t, c.ok("__complete", "bash", "wtf attachment add item X ", ""), ":files")

	// Names can't contain "/", so a path always means one thing. A path
	// matching several classes is refused with suggestions, also for delete.
	r := e.expect(t, 400, "POST", "/classes", map[string]any{"name": "MCU/AVR"})
	contains(t, fmt.Sprint(r.body), `can't contain "/"`)
	e.expect(t, 400, "POST", "/locations", map[string]any{"name": "Gar/age"})
	_, stderr := c.run(1, "", "location", "set", "Garage", "--name", "Gar/age")
	contains(t, stderr, `can't contain "/"`)
	c.ok("class", "add", "MCU")
	c.ok("class", "add", "AVR", "--parent", "MCU")
	c.ok("class", "add", "AVR")
	_, stderr = c.run(1, "", "class", "delete", "AVR")
	contains(t, stderr, `class "AVR" is ambiguous`, "for MCU/AVR", "for AVR")
	// On a terminal it asks instead: the matches are sorted by path, so
	// Enter picks the top-level AVR (before MCU/AVR), and AVR under MCU stays.
	_, prompts = c.interact([]string{"\r"}, false, "class", "delete", "AVR")
	contains(t, prompts, `Which class "AVR"? AVR`)
	tree := c.ok("class", "tree")
	contains(t, tree, "MCU\n  AVR")
	if strings.Count(tree, "AVR") != 1 {
		t.Errorf("the wrong AVR was deleted:\n%s", tree)
	}
	c.ok("class", "delete", "AVR") // now unique
	c.ok("class", "delete", "MCU")

	// "class add A/B/C" creates C under A/B. Missing parents are an error in
	// scripts, created with --create-parents, and asked about on a terminal.
	_, stderr = c.run(1, "", "class", "add", "Tools/Hand/Pliers")
	contains(t, stderr, "these classes don't exist: Tools, Tools/Hand", "--create-parents")
	out, _ = c.run(0, "", "class", "add", "Tools/Hand/Pliers", "--create-parents")
	contains(t, out, "Created class Tools.", "Created class Hand.", "Path:  Tools/Hand/Pliers")
	contains(t, c.ok("class", "add", "Hand/Saws"), "Path:  Tools/Hand/Saws") // the parent by its end
	out, prompts = c.interact([]string{"y\r"}, false, "class", "add", "tools/Power/Drills")
	contains(t, prompts, "These classes don't exist yet:\n  Tools/Power\n", "Create them? [y/N]")
	contains(t, out, "Created class Power.", "Path:  Tools/Power/Drills")
	_, prompts = c.interactExit(1, []string{"\r"}, false, "class", "add", "Garden/Hoses")
	contains(t, prompts, "Garden\n")
	contains(t, c.ok("class", "add", "Bar", "--parent", "Tools", "--create-parents"), "Path:  Tools/Bar")
	contains(t, c.ok("class", "add", "Clamps/Quick", "--parent", "Tools", "--create-parents"), "Path:  Tools/Clamps/Quick")
	tree = c.ok("class", "tree")
	contains(t, tree, "Tools\n  Bar\n  Clamps\n    Quick\n  Hand\n    Pliers\n    Saws\n  Power\n    Drills\n")
	if strings.Contains(tree, "Garden") {
		t.Errorf("answering no created something:\n%s", tree)
	}
	contains(t, c.ok("location", "add", "Garage/Shelf 2/Box 9"), "Path:  Garage/Shelf 2/Box 9")
	_, stderr = c.run(2, "", "class", "add", "Tools//X")
	contains(t, stderr, "empty name in path")
	contains(t, c.ok("__complete", "zsh", "class", "add", "Tools/H"), "Tools/Hand/\n")

	// Recursive deletes: suggested when a plain delete fails, always
	// confirmed (--yes in scripts), blocked by items unless forced.
	c.ok("class", "add", "MCU/Intel/No/No/Just No", "--create-parents")
	_, stderr = c.run(1, "", "class", "delete", "MCU/Intel")
	contains(t, stderr, "Still in use", "add --recursive")
	_, stderr = c.run(1, "", "class", "delete", "MCU/Intel", "--recursive")
	contains(t, stderr, "must be confirmed", "Delete class MCU/Intel and the 3 classes below it", "--yes")
	_, stderr = c.run(2, "", "class", "delete", "MCU/Intel", "--force")
	contains(t, stderr, "--force only works with --recursive")
	_, prompts = c.interactExit(1, []string{"n\r"}, false, "class", "delete", "MCU/Intel", "--recursive")
	contains(t, prompts, "Delete class MCU/Intel and the 3 classes below it? [y/N]")
	if strings.Contains(prompts, "Classes (4)") {
		t.Errorf("listed without --verbose:\n%s", prompts)
	}
	contains(t, c.ok("class", "tree"), "Just No")
	c.ok("item", "add", "8086", "--class", "MCU/Intel/No")
	_, stderr = c.run(1, "", "class", "delete", "MCU/Intel", "--recursive", "--yes")
	contains(t, stderr, "nothing was deleted", "MCU/Intel/No (1 item)", "add --force")
	out, prompts = c.interact([]string{"y\r"}, false, "class", "delete", "MCU/Intel", "--recursive", "--force", "--verbose")
	contains(t, prompts, "Classes (4):\n  MCU/Intel\n  MCU/Intel/No\n", "8086", "Delete class MCU/Intel and the 3 classes below it, with 1 item? [y/N]")
	contains(t, out, "Deleted 4 classes and 1 item.")
	tree = c.ok("class", "tree")
	if strings.Contains(tree, "Intel") || !strings.Contains(tree, "MCU") {
		t.Errorf("after the recursive delete:\n%s", tree)
	}
	c.ok("location", "add", "Cellar/Rack/Bin", "--create-parents")
	c.ok("stock", "add", "M3 screw", "Cellar/Rack/Bin", "5")
	out, _ = c.run(0, "", "location", "delete", "Cellar", "--recursive", "--force", "--yes")
	contains(t, out, "Deleted 3 locations and 1 stock row.")
	var deleted struct {
		Classes []any
	}
	c.ok("class", "add", "Temp/Sub", "--create-parents")
	c.json(&deleted, "class", "delete", "Temp", "--recursive", "--yes")
	if len(deleted.Classes) != 2 {
		t.Errorf("--json: %+v", deleted)
	}

	// Lists: all rows when piped, one page with --limit, and through the
	// pager on a terminal (24 lines: header and 22 rows, then "q").
	for i := 1; i <= 30; i++ {
		c.ok("item", "add", fmt.Sprintf("Bolt %02d", i), "--class", "Hardware")
	}
	contains(t, c.ok("item", "list"), "Bolt 30", "M3 screw")
	out, stderr = c.run(0, "", "item", "list", "--limit", "5")
	if strings.Contains(out, "Bolt 06") {
		t.Errorf("--limit 5 shows more:\n%s", out)
	}
	contains(t, stderr, "Next: --offset 5")
	var all struct {
		Total int
		Rows  []any
	}
	c.json(&all, "item", "list")
	if all.Total != 32 || len(all.Rows) != 32 {
		t.Errorf("--json: total %d, %d rows", all.Total, len(all.Rows))
	}
	out, _ = c.interact([]string{"q"}, true, "item", "list")
	contains(t, out, "Bolt 22", "-- More --")
	if strings.Contains(out, "Bolt 23") {
		t.Errorf("the pager went on after q:\n%s", out)
	}
	out, _ = c.interact([]string{"\r", " "}, true, "item", "list")
	contains(t, out, "Bolt 23", "M3 screw")
}
