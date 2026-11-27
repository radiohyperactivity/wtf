package files

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Files where versions before uploads kept them are moved into uploads when
// the directory is opened: a directory whole, or file by file into one that
// uploads has already.
func TestOpenMovesFilesIntoUploads(t *testing.T) {
	dir := t.TempDir()
	a := strings.Repeat("a", 64)
	b := "bb" + strings.Repeat("1", 62)
	b2 := "bb" + strings.Repeat("2", 62)
	write := func(p string) {
		t.Helper()
		if err := os.MkdirAll(filepath.Dir(p), 0o750); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte("content"), 0o640); err != nil {
			t.Fatal(err)
		}
	}
	write(filepath.Join(dir, "aa", a))
	write(filepath.Join(dir, "bb", b))
	write(filepath.Join(dir, "bb", b2))
	write(filepath.Join(dir, uploadDir, "bb", b2)) // the same content, there already
	write(filepath.Join(dir, thumbnailDir, "aa", a+"-128"))

	s, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, hash := range []string{a, b, b2} {
		if _, ok, err := s.ModTime(hash); err != nil || !ok {
			t.Errorf("%s is not in uploads (%v)", hash[:4], err)
		}
	}
	for _, old := range []string{"aa", "bb"} {
		if _, err := os.Stat(filepath.Join(dir, old)); !os.IsNotExist(err) {
			t.Errorf("%s is still at the top (%v)", old, err)
		}
	}
	if _, err := os.Stat(filepath.Join(dir, thumbnailDir, "aa", a+"-128")); err != nil {
		t.Errorf("the thumbnail moved: %v", err)
	}

	var walked []string
	if err := s.Walk(func(hash string, _ time.Time) error {
		walked = append(walked, hash[:4])
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if len(walked) != 3 {
		t.Errorf("walked %v, want the three files", walked)
	}

	// Opened again, there is nothing to move.
	if _, err := Open(dir); err != nil {
		t.Fatal(err)
	}
}
