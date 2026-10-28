package integration

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/radiohyperactivity/wtf/internal/cli"
)

// cliEnv runs the wtf client against the API handler.
type cliEnv struct {
	t      *testing.T
	config string
	vars   map[string]string
}

func (e *environment) cli(t *testing.T) *cliEnv {
	t.Helper()
	server := httptest.NewServer(e.handler)
	t.Cleanup(server.Close)
	return &cliEnv{t: t, config: filepath.Join(t.TempDir(), "config.json"), vars: map[string]string{
		"WTF_SERVER":    server.URL,
		"WTF_TOKEN":     e.token,
		"WTF_CACHE_DIR": t.TempDir(),
	}}
}

// run runs wtf with args and stdin, and fails the test unless the exit code is
// the expected one.
func (c *cliEnv) run(code int, stdin string, args ...string) (string, string) {
	c.t.Helper()
	var stdout, stderr bytes.Buffer
	getenv := func(name string) string {
		if name == "WTF_CONFIG" {
			return c.config
		}
		return c.vars[name]
	}
	got := cli.Run(context.Background(), args, strings.NewReader(stdin), &stdout, &stderr, getenv)
	if got != code {
		c.t.Fatalf("wtf %s: exit %d, want %d\nstdout: %s\nstderr: %s", strings.Join(args, " "), got, code, stdout.String(), stderr.String())
	}
	return stdout.String(), stderr.String()
}

// ok runs wtf, expects success and returns stdout.
func (c *cliEnv) ok(args ...string) string {
	c.t.Helper()
	out, _ := c.run(0, "", args...)
	return out
}

func (c *cliEnv) json(v any, args ...string) {
	c.t.Helper()
	out := c.ok(append([]string{"--json"}, args...)...)
	if err := json.Unmarshal([]byte(out), v); err != nil {
		c.t.Fatalf("wtf %s: %v\n%s", strings.Join(args, " "), err, out)
	}
}

func contains(t *testing.T, out string, want ...string) {
	t.Helper()
	for _, w := range want {
		if !strings.Contains(out, w) {
			t.Errorf("output lacks %q:\n%s", w, out)
		}
	}
}

func TestCLI(t *testing.T) {
	e := setup(t)
	e.reset(t)
	c := e.cli(t)

	contains(t, c.ok("whoami"), "admin@test.local", "read_write")

	// The model: locations, attributes with units and options, classes.
	c.ok("location", "add", "Garage")
	c.ok("location", "add", "Shelf 2", "--parent", "Garage")
	c.ok("location", "add", "Attic")
	c.ok("location", "add", "Shelf 2", "--parent", "Attic")
	contains(t, c.ok("location", "tree"), "Garage", "  Shelf 2", "Attic")
	_, stderr := c.run(1, "", "location", "get", "Shelf 2")
	contains(t, stderr, "ambiguous", "Garage/Shelf 2", "Attic/Shelf 2")

	c.ok("attribute", "add", "Length", "--unit", "m")
	c.ok("attribute", "add", "Colour", "--type", "choice")
	c.ok("option", "add", "Colour", "red", "blue")
	contains(t, c.ok("option", "list", "colour"), "blue", "red")
	c.ok("attribute", "add", "Serial", "--type", "text")

	c.ok("class", "add", "Hardware")
	c.ok("class", "add", "Screws", "--parent", "Hardware")
	contains(t, c.ok("class", "assign", "Screws", "Length", "--default", "12mm"), "Length", "1.2 cm")
	c.ok("class", "assign", "Hardware", "Colour")
	c.ok("class", "assign", "Hardware", "Serial", "--per-unit")
	contains(t, c.ok("class", "tree"), "Hardware", "  Screws")
	contains(t, c.ok("class", "get", "Hardware/Screws"), "Colour", "from Hardware", "Length", "1.2 cm")

	// Items with values, given in other units.
	c.ok("item", "add", "M4 screw", "--class", "Screws", "--value", "Colour=Red")
	contains(t, c.ok("item", "value-set", "M4 screw", "Length", "25", "mm"), "2.5 cm")
	var it struct {
		ID     string `json:"id"`
		Code   string `json:"code"`
		Values []struct {
			Attribute struct{ Name string } `json:"attribute"`
			Value     any                   `json:"value"`
		} `json:"values"`
	}
	c.json(&it, "item", "get", "m4 SCREW")
	for _, v := range it.Values {
		if v.Attribute.Name == "Length" && v.Value != 0.025 {
			t.Errorf("Length = %v, want 0.025 (metres)", v.Value)
		}
	}
	_, stderr = c.run(1, "", "item", "value-set", "M4 screw", "Length", "3", "kg")
	contains(t, stderr, "unknown unit", "mm")

	// A plain number is in the attribute's unit: 20 is 20 °C, stored as
	// 293.15 K. The type follows from the unit.
	c.ok("attribute", "add", "Max temperature", "--unit", "degC")
	c.ok("class", "assign", "Hardware", "Max temperature")
	contains(t, c.ok("item", "value-set", "M4 screw", "Max temperature", "20"), "20 °C")
	c.json(&it, "item", "get", "M4 screw")
	for _, v := range it.Values {
		if v.Attribute.Name == "Max temperature" && v.Value != 293.15 {
			t.Errorf("Max temperature = %v, want 293.15 (kelvin)", v.Value)
		}
	}
	contains(t, c.ok("item", "value-set", "M4 screw", "Length", "0.03"), "3 cm")

	// Attribute conditions, in any unit; all must match.
	contains(t, c.ok("item", "list", "--where", "Length>=2.5cm"), "M4 screw")
	contains(t, c.ok("item", "list", "--where", "Length = 1in..2in", "--where", "Colour=red,blue"), "M4 screw")
	if out := c.ok("item", "list", "--where", "Length<1in"); strings.Contains(out, "M4 screw") {
		t.Errorf("Length<1in found the 3 cm screw:\n%s", out)
	}
	_, stderr = c.run(0, "", "find", "--where", "Colour=Blue")
	contains(t, stderr, "Nothing found.")
	_, stderr = c.run(2, "", "item", "list", "--where", "Length~3")
	contains(t, stderr, "Length can be compared with")

	// Stock: add, find, move part of it, look it up by code.
	c.ok("stock", "add", "M4 screw", "Garage/Shelf 2", "100", "--value", "Serial=A1")
	contains(t, c.ok("find", "screw"), "M4 screw", "Hardware/Screws", "Garage/Shelf 2", "100")
	contains(t, c.ok("stock", "move", "M4 screw@Garage/Shelf 2", "Garage", "40"), "Garage", "40")
	contains(t, c.ok("stock", "list", "--item", "M4 screw"), "Garage/Shelf 2", "60", "40")
	_, stderr = c.run(1, "", "stock", "get", "M4 screw")
	contains(t, stderr, "ambiguous")
	contains(t, c.ok("code", strings.ToLower(it.Code)), "is an item", "M4 screw")
	contains(t, c.ok("item", "get", it.Code), "M4 screw")
	contains(t, c.ok("item", "list", "--class", "Hardware"), "M4 screw", "100")

	// Attachments.
	file := filepath.Join(t.TempDir(), "note.txt")
	if err := os.WriteFile(file, []byte("hello"), 0o644); err != nil {
		t.Fatal(err)
	}
	var att struct{ ID string }
	c.json(&att, "attachment", "add", "item", "M4 screw", file, "--title", "A note")
	contains(t, c.ok("attachment", "list", "item", "M4 screw"), att.ID, "A note", "text/plain", "5 B")
	out, _ := c.run(0, "", "attachment", "download", "item", "M4 screw", att.ID, "-o", "-")
	if out != "hello" {
		t.Errorf("download = %q", out)
	}
	contains(t, c.ok("attachment", "set", "item", "M4 screw", att.ID, "--title", "Notes"), "Title:", "Notes")
	_, stderr = c.run(1, "", "attachment", "photo", "item", "M4 screw", att.ID)
	contains(t, stderr, "must be an image")
	contains(t, c.ok("attachment", "delete", "item", "M4 screw", att.ID), "Deleted attachment")
	contains(t, c.ok("attachment", "get", "item", "M4 screw", att.ID), "Deleted:", "wtf attachment restore item")
	if out := c.ok("attachment", "list", "item", "M4 screw"); strings.Contains(out, att.ID) {
		t.Errorf("a deleted attachment is listed:\n%s", out)
	}
	contains(t, c.ok("attachment", "restore", "item", "M4 screw", att.ID), "Notes")
	contains(t, c.ok("attachment", "list", "item", "M4 screw"), att.ID)

	// History.
	contains(t, c.ok("item", "history", "M4 screw"), "admin@test.local", "insert item", "insert stock")

	// Accounts, login and logout through a profile. Accounts outlive reset(),
	// so the email is new on every run.
	bob := fmt.Sprintf("bob-%d@test.local", time.Now().UnixNano())
	c.run(0, "secret-password\n", "account", "add", bob, "--password", "--data", "read")
	contains(t, c.ok("account", "list"), bob, "read_only")
	delete(c.vars, "WTF_TOKEN")
	c.vars["WTF_PASSWORD"] = "secret-password"
	c.ok("login", "--profile", "bob", "--email", bob)
	delete(c.vars, "WTF_PASSWORD")
	contains(t, c.ok("whoami"), bob, "bob")
	contains(t, c.ok("profile", "list"), "*", "bob")
	_, stderr = c.run(1, "", "location", "add", "Cellar")
	contains(t, stderr, "Not allowed")
	c.ok("logout")
	_, stderr = c.run(1, "", "whoami")
	contains(t, stderr, "wtf login")

	// Deleting, as the admin again.
	c.vars["WTF_TOKEN"] = e.token
	c.ok("stock", "delete", "M4 screw@Garage")
	c.ok("account", "delete", bob)
	_, stderr = c.run(1, "", "location", "delete", "Garage")
	contains(t, stderr, "Still in use")
}
