package integration

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/radiohyperactivity/wtf/internal/cli"
	"github.com/radiohyperactivity/wtf/internal/prompt"
)

// clear is Ctrl-U: it empties a pre-filled field before typing a new value.
const clear = "\x15"

// TestCLIEdit drives the edit forms and the container flag with scripted keys.
func TestCLIEdit(t *testing.T) {
	e := setup(t)
	e.reset(t)
	c := e.cli(t)
	cli.OpenTerminal = func(io.Reader, io.Writer) *prompt.Terminal { return nil }

	c.ok("attribute", "add", "Length", "--type", "float", "--unit-group", "Metric length")
	c.ok("attribute", "add", "Colour", "--type", "choice")
	c.ok("option", "add", "Colour", "red", "blue")
	c.ok("class", "add", "Hardware", "--container")
	c.ok("class", "add", "Hardware/Screws")
	c.ok("class", "assign", "Hardware/Screws", "Length", "--required")
	c.ok("location", "add", "Garage", "--container")
	c.ok("location", "add", "Garage/Shelf")
	c.ok("item", "add", "M3", "--class", "Hardware/Screws", "--value", "Length=12mm")

	// Containers: marked in the tree, refused for items and stock, and only
	// offered as a way through by completion.
	contains(t, c.ok("class", "tree"), "Hardware/\n  Screws\n")
	_, stderr := c.run(1, "", "item", "add", "Loose", "--class", "Hardware")
	contains(t, stderr, `Class "Hardware" is a container`)
	_, stderr = c.run(1, "", "stock", "add", "M3", "Garage", "1")
	contains(t, stderr, `Location "Garage" is a container`)
	got := c.ok("__complete", "zsh", "item", "add", "X", "--class", "")
	if !strings.Contains(got, "Hardware/\n") || strings.Contains(got, "Hardware\n") {
		t.Errorf("class completion for items: %q", got)
	}
	got = c.ok("__complete", "zsh", "stock", "add", "M3", "")
	if !strings.Contains(got, "Garage/\n") || strings.Contains(got, "Garage\n") {
		t.Errorf("location completion for stock: %q", got)
	}
	contains(t, c.ok("class", "get", "Hardware"), "Container:  yes")
	c.ok("class", "set", "Hardware", "--container", "no")
	c.ok("class", "set", "Hardware", "--container", "yes")

	// Class form: keep name, parent and container, assign Colour (default
	// red), then try to remove Length, which M3 still has a value of. The
	// second step fails, and the message says what was already saved.
	_, prompts := c.interactExit(1, []string{"\r", "\r", "\r", "Colour\r", "red\r", "\r", "\r", "-Length\r", "\r"},
		false, "class", "edit", "Hardware/Screws")
	contains(t, prompts, "Editing class Hardware/Screws", "Name: Screws", "Parent (empty: top level): Hardware",
		"Container (holds only other classes): no", "Length  required", "Already saved: assigned Colour")
	contains(t, c.ok("class", "get", "Hardware/Screws"), "Colour", "red")

	// Becoming a container is refused while the class has items.
	_, prompts = c.interactExit(1, []string{"\r", "\r", clear + "yes\r", "\r"}, false, "class", "edit", "Hardware/Screws")
	contains(t, prompts, "can't become a container")

	// Item form: rename, keep the class, set Colour, change Length.
	out, prompts := c.interact([]string{clear + "M3x10\r", "\r", "blue\r", clear + "15mm\r"}, false, "item", "edit", "M3")
	contains(t, prompts, "Class: Hardware/Screws", "Colour [default red]", "Length (required) (Metric length): 1.2 cm",
		"Saved: changed name, set Colour, set Length.")
	contains(t, out, "Name:   M3x10", "blue", "1.5 cm")

	// Ctrl-C in the middle changes nothing.
	c.interactExit(130, []string{clear + "Other\r", "\x03"}, false, "item", "edit", "M3x10")
	contains(t, c.ok("item", "get", "M3x10"), "M3x10")

	// Stock form.
	c.ok("stock", "add", "M3x10", "Garage/Shelf", "5")
	out, _ = c.interact([]string{clear + "8\r", "\r"}, false, "stock", "edit", "M3x10")
	contains(t, out, "Quantity:  8", "Garage/Shelf")

	// Attribute form with options: add green, rename red.
	out, _ = c.interact([]string{"\r", "\r", "green\r", "red=Red\r", "\r"}, false, "attribute", "edit", "Colour")
	contains(t, out, "Options:  blue, green, Red")

	// Location form.
	out, _ = c.interact([]string{clear + "Shelf A\r", "\r", "\r"}, false, "location", "edit", "Garage/Shelf")
	contains(t, out, "Path:  Garage/Shelf A")

	// Account form: data write, keep the rest and the password.
	c.run(0, "secret-password\n", "account", "add", "editor@test.local", "--password")
	out, _ = c.interact([]string{"\r", clear + "write\r", "\r", "\r", "\r", "\r"}, false, "account", "edit", "editor@test.local")
	contains(t, out, "data read_write, model none")
	c.ok("account", "delete", "editor@test.local")

	// Attachment form.
	file := filepath.Join(t.TempDir(), "note.txt")
	if err := os.WriteFile(file, []byte("hello"), 0o644); err != nil {
		t.Fatal(err)
	}
	var att struct{ ID string }
	c.json(&att, "attachment", "add", "item", "M3x10", file)
	out, _ = c.interact([]string{clear + "readme.txt\r", "a caption\r", "\r"}, false, "attachment", "edit", att.ID)
	contains(t, out, "File name:  readme.txt", "Caption:    a caption")

	// --edit on add opens the form for the new object.
	out, _ = c.interact([]string{"\r", "\r", clear + "yes\r"}, false, "location", "add", "Cellar", "--edit")
	contains(t, out, "Container:  yes")
	// With --edit, item add ends with the form: no question about stock.
	out, prompts = c.interact([]string{"\r", "\r", "red\r", clear + "3mm\r"},
		false, "item", "add", "M2", "--class", "Hardware/Screws", "--value", "Length=2mm", "--edit")
	contains(t, out, "Name:   M2", "Colour:  Red", "3 mm") // the option was renamed above
	if strings.Contains(prompts, "Add stock") {
		t.Errorf("asked about stock after --edit:\n%s", prompts)
	}

	// Without --edit, it asks once and adds one stock row.
	out, prompts = c.interact([]string{"y\r", "Garage/Shelf A\r", "7\r"},
		false, "item", "add", "M6", "--class", "Hardware/Screws", "--value", "Length=6mm")
	contains(t, prompts, "Add stock for M6? [y/N]")
	contains(t, out, "Location:  Garage/Shelf A", "Quantity:  7")
	if strings.Contains(prompts, "another") {
		t.Errorf("asked for more stock:\n%s", prompts)
	}
	// A failed stock row is reported; the item stays.
	_, prompts = c.interactExit(1, []string{"y\r", "Garage\r", "\r"},
		false, "item", "add", "M7", "--class", "Hardware/Screws", "--value", "Length=7mm")
	contains(t, prompts, "M7 was created, but its stock wasn't", `Location "Garage" is a container`)
	c.ok("item", "get", "M7")
	// No question in scripts, or with --json.
	out, _ = c.run(0, "", "item", "add", "M1", "--class", "Hardware/Screws", "--value", "Length=1mm")
	if strings.Contains(out, "Add stock") {
		t.Error("asked about stock without a terminal")
	}
	out, _ = c.interact(nil, false, "--json", "item", "add", "M5", "--class", "Hardware/Screws", "--value", "Length=5mm")
	if !strings.HasPrefix(strings.TrimSpace(out), "{") {
		t.Errorf("--json output: %s", out)
	}

	// A box with a grid of compartments, also below a new parent.
	out, _ = c.run(0, "", "location", "add", "Workshop/Box 3", "--grid", "8x5", "--create-parents")
	contains(t, out, "Container:  yes", "Compartments: 40 compartments, A1 … H5")
	contains(t, c.ok("location", "tree"), "Workshop\n", "  Box 3/\n", "    A1\n", "    H5\n")
	contains(t, c.ok("stock", "add", "M3x10", "Box 3/C4", "5"), "Workshop/Box 3/C4")
	_, stderr = c.run(1, "", "stock", "add", "M3x10", "Box 3", "1")
	contains(t, stderr, `Location "Box 3" is a container`)
	_, stderr = c.run(2, "", "location", "add", "Box 4", "--grid", "A1:H5")
	contains(t, stderr, "COLUMNSxROWS")

	// More than 1000 locations: asked first (counting a new parent too), or
	// --yes in scripts; "no" creates nothing, not even the parent.
	_, stderr = c.run(1, "", "location", "add", "Big", "--grid", "50x20")
	contains(t, stderr, "This creates 1001 locations; add --yes")
	_, prompts = c.interactExit(1, []string{"n\r"}, false, "location", "add", "Store/Big", "--grid", "50x20", "--create-parents")
	contains(t, prompts, "This creates 1002 locations. Continue? [y/N]")
	if strings.Contains(c.ok("location", "tree"), "Store") {
		t.Error("answering no created the parent")
	}
	out, _ = c.run(0, "", "location", "add", "Big", "--grid", "50x20", "--yes")
	contains(t, out, "1000 compartments, A1 … AX20")

	// Without a terminal, edit and --edit refuse, and --edit creates nothing.
	_, stderr = c.run(1, "", "class", "edit", "Hardware")
	contains(t, stderr, "edit needs a terminal")
	_, stderr = c.run(1, "", "location", "add", "Attic", "--edit")
	contains(t, stderr, "--edit needs a terminal")
	if strings.Contains(c.ok("location", "tree"), "Attic") {
		t.Error("--edit without a terminal created the location")
	}
}
