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

	contains(t, c.ok("whoami"), "admin@test.local", "Role:     admin")

	// The model: locations, attributes with units and options, classes.
	c.ok("location", "add", "Garage")
	c.ok("location", "add", "Shelf 2", "--parent", "Garage")
	c.ok("location", "add", "Attic")
	c.ok("location", "add", "Shelf 2", "--parent", "Attic")
	contains(t, c.ok("location", "tree"), "Garage", "  Shelf 2", "Attic")
	_, stderr := c.run(1, "", "location", "get", "Shelf 2")
	contains(t, stderr, "ambiguous", "Garage/Shelf 2", "Attic/Shelf 2")

	c.ok("class", "add", "Hardware")
	c.ok("class", "add", "Screws", "--parent", "Hardware")
	c.ok("class", "attribute", "add", "Hardware", "Colour", "--type", "choice", "--choices", "Red,Blue")
	c.ok("class", "attribute", "add", "Hardware", "Lot", "--type", "text", "--stock")
	c.ok("class", "attribute", "add", "Hardware", "Manual", "--type", "attachment", "--media", "text/*")
	contains(t, c.ok("class", "attribute", "add", "Screws", "Length", "--type", "decimal", "--unit", "mm", "--default", "12"),
		"Length", "mm", "12")
	contains(t, c.ok("class", "tree"), "Hardware", "  Screws")
	contains(t, c.ok("class", "get", "Hardware/Screws"), "Colour", "from Hardware", "Length", "this class", "Stock attributes:", "Lot")

	// Items with values, by their own flags; a number may carry its unit.
	contains(t, c.ok("item", "add", "M4 screw", "--class", "Screws", "--colour", "red"), "Length:", "12 mm", "(default)", "Red")
	contains(t, c.ok("item", "set", "M4 screw", "--length", "25 mm"), "25 mm")
	var it struct {
		ID     string         `json:"id"`
		Code   string         `json:"code"`
		Values map[string]any `json:"values"`
	}
	c.json(&it, "item", "get", "m4 SCREW")
	if it.Values["Length"] != 25.0 {
		t.Errorf("Length = %v, want 25", it.Values["Length"])
	}
	_, stderr = c.run(1, "", "item", "set", "M4 screw", "--length", "3 kg")
	contains(t, stderr, "in mm, and nothing converts")
	_, stderr = c.run(2, "", "item", "set", "M4 screw", "--weight", "3")
	contains(t, stderr, `no item attribute "weight"`, "Length")
	contains(t, c.ok("item", "set", "M4 screw", "--default", "length"), "12 mm", "(default)")
	contains(t, c.ok("item", "set", "M4 screw", "--length", "30", "--no-colour"), "30 mm")

	// A changed default reaches the values that follow it, and a dry run
	// says so without changing anything.
	c.ok("item", "add", "M3 screw", "--class", "Screws")
	contains(t, c.ok("class", "attribute", "set", "Screws", "Length", "--default", "16", "--dry-run"), "would rewrite 1 item")
	contains(t, c.ok("class", "attribute", "set", "Screws", "Length", "--default", "16"), "Rewrote 1 item")
	contains(t, c.ok("item", "get", "M3 screw"), "16 mm")
	contains(t, c.ok("class", "attribute", "rename", "Screws", "Length", "Size"), "Rewrote 2 items")

	// Attribute conditions, by name; all must match.
	contains(t, c.ok("item", "list", "--where", "Size>=20"), "M4 screw")
	contains(t, c.ok("item", "list", "--class", "Screws", "--where", "Size = 10..40", "--where", "Size>15"), "M4 screw", "M3 screw")
	if out := c.ok("item", "list", "--where", "Size<20"); strings.Contains(out, "M4 screw") {
		t.Errorf("Size<20 found the 30 mm screw:\n%s", out)
	}
	_, stderr = c.run(0, "", "find", "--where", "Colour=Blue")
	contains(t, stderr, "Nothing found.")

	// Stock: add, find, move part of it, merge it back, look it up by code.
	c.ok("stock", "add", "M4 screw", "Garage/Shelf 2", "100", "--lot", "A1", "--serial", "SN-1")
	contains(t, c.ok("find", "screw"), "M4 screw", "Hardware/Screws", "Garage/Shelf 2", "100")
	contains(t, c.ok("stock", "move", "M4 screw@Garage/Shelf 2", "Garage", "40"), "Garage", "40")
	contains(t, c.ok("stock", "list", "--item", "M4 screw"), "Garage/Shelf 2", "60", "40")
	contains(t, c.ok("stock", "list", "--search", "sn-1"), "M4 screw")
	c.ok("stock", "set", "M4 screw@Garage", "--lot", "B2", "--no-serial")
	_, stderr = c.run(1, "", "stock", "merge", "M4 screw@Garage", "M4 screw@Garage/Shelf 2")
	contains(t, stderr, "differ", "serial", "Lot", "--keep")
	contains(t, c.ok("stock", "merge", "M4 screw@Garage", "M4 screw@Garage/Shelf 2", "--keep", "serial=into", "--keep", "lot=from"),
		"100", "B2", "SN-1")
	_, stderr = c.run(1, "", "stock", "get", "M4 screw@Garage")
	contains(t, stderr, "no stock")
	contains(t, c.ok("code", strings.ToLower(it.Code)), "is an item", "M4 screw")
	contains(t, c.ok("item", "get", it.Code), "M4 screw")
	contains(t, c.ok("item", "list", "--class", "Hardware"), "M4 screw", "100")

	// Files: an attachment attribute's, and a photo.
	file := filepath.Join(t.TempDir(), "note.txt")
	if err := os.WriteFile(file, []byte("hello"), 0o644); err != nil {
		t.Fatal(err)
	}
	contains(t, c.ok("file", "put", "M4 screw", "manual", file), "Manual:", "file ")
	out, _ := c.run(0, "", "file", "get", "M4 screw", "Manual", "-")
	if out != "hello" {
		t.Errorf("download = %q", out)
	}
	_, stderr = c.run(1, "", "file", "put", "M4 screw", "photo", file)
	contains(t, stderr, "must be an image")
	_, stderr = c.run(2, "", "file", "put", "M4 screw", "Size", file)
	contains(t, stderr, "not a file")

	// Accounts, login and logout through a profile. Accounts outlive reset(),
	// so the email is new on every run.
	bob := fmt.Sprintf("bob-%d@test.local", time.Now().UnixNano())
	c.run(0, "secret-password\n", "account", "add", bob, "--password", "--role", "user")
	contains(t, c.ok("account", "list"), bob, "user")
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
	c.ok("stock", "delete", "M4 screw@Garage/Shelf 2")
	c.ok("account", "delete", bob)
	_, stderr = c.run(1, "", "location", "delete", "Garage")
	contains(t, stderr, "Still in use")
}
