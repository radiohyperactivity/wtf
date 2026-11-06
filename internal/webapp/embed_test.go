//go:build webapp

package webapp

import (
	"io/fs"
	"testing"
)

// The embedded build has what the web app starts from, at its root, and
// nothing hidden.
func TestFiles(t *testing.T) {
	for _, name := range []string{"index.html", "flutter_bootstrap.js", "main.dart.js", "version.json"} {
		if _, err := fs.Stat(Files, name); err != nil {
			t.Errorf("%s: %v", name, err)
		}
	}
	if _, err := fs.Stat(Files, ".last_build_id"); err == nil {
		t.Error(".last_build_id is embedded")
	}
}
