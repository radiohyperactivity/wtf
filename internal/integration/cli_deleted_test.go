package integration

import (
	"strings"
	"testing"
)

// The CLI shows deleted objects as such and restores them, also into
// something deleted.
func TestCLIRestore(t *testing.T) {
	e := setup(t)
	e.reset(t)
	c := e.cli(t)

	c.ok("class", "add", "Tools")
	c.ok("location", "add", "Shed")
	c.ok("location", "add", "Shed/Box")
	var drill struct{ ID, Code string }
	c.json(&drill, "item", "add", "Drill", "--class", "Tools")
	var row struct{ ID, Code string }
	c.json(&row, "stock", "add", "Drill", "Shed/Box", "2")
	var box struct{ ID, Code string }
	c.json(&box, "location", "get", "Shed/Box")

	// Deleted things are shown as deleted, by their code.
	c.ok("location", "delete", "Shed", "--recursive", "--force", "--yes")
	if out := c.ok("code", row.Code); !strings.Contains(out, "Deleted:") || !strings.Contains(out, "wtf stock restore "+row.Code) {
		t.Errorf("code of a deleted row:\n%s", out)
	}

	// Without a terminal, restoring into something deleted names both ways out.
	_, stderr := c.run(1, "", "location", "restore", box.Code)
	if !strings.Contains(stderr, "which is deleted") || !strings.Contains(stderr, "--with-parents") || !strings.Contains(stderr, "--to LOCATION") {
		t.Errorf("restore into a deleted parent:\n%s", stderr)
	}
	if out := c.ok("location", "restore", box.Code, "--with-parents"); !strings.Contains(out, "Restored location "+box.Code) {
		t.Errorf("restore output:\n%s", out)
	}
	if out := c.ok("stock", "get", row.Code); strings.Contains(out, "Deleted:") {
		t.Errorf("the row wasn't restored with its box:\n%s", out)
	}

	// Somewhere else, and at the top.
	c.ok("location", "add", "Van")
	c.ok("stock", "delete", row.Code)
	c.ok("location", "delete", "Shed/Box")
	c.ok("stock", "restore", row.Code, "--to", "Van")
	if out := c.ok("stock", "get", row.Code); !strings.Contains(out, "Van") {
		t.Errorf("restored at the van:\n%s", out)
	}
	c.ok("location", "restore", box.Code, "--to", "none")
	if out := c.ok("location", "get", box.Code); !strings.Contains(out, "Path:") || strings.Contains(out, "Shed") {
		t.Errorf("box at the top:\n%s", out)
	}

	// Errors carry the server's hint; a class is named by its id.
	c.run(2, "", "class", "restore", "Tools")
	_, stderr = c.run(1, "", "item", "restore", drill.Code)
	if !strings.Contains(stderr, "is not deleted") {
		t.Errorf("restoring a live item:\n%s", stderr)
	}
}

// On a terminal, restoring into something deleted asks which way.
func TestCLIRestoreAsks(t *testing.T) {
	e := setup(t)
	e.reset(t)
	c := e.cli(t)

	c.ok("location", "add", "Shed")
	c.ok("location", "add", "Van")
	var box struct{ ID, Code string }
	c.json(&box, "location", "add", "Box", "--parent", "Shed")
	c.ok("location", "delete", "Shed/Box")
	c.ok("location", "delete", "Shed")

	// Enter takes the first way: together with the shed.
	_, prompts := c.interact([]string{"\r"}, false, "location", "restore", box.Code)
	if !strings.Contains(prompts, "Restore it how?") {
		t.Errorf("prompts: %q", prompts)
	}
	if out := c.ok("location", "get", "Shed"); strings.Contains(out, "Deleted:") {
		t.Errorf("the shed wasn't restored:\n%s", out)
	}

	// The second way asks where.
	c.ok("location", "delete", "Shed/Box")
	c.ok("location", "delete", "Shed")
	c.interact([]string{"\x1b[B", "\r", "Van\r"}, false, "location", "restore", box.Code)
	if out := c.ok("location", "get", box.Code); !strings.Contains(out, "Van/Box") {
		t.Errorf("box in the van:\n%s", out)
	}
}
