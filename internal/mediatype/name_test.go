package mediatype

import "testing"

func TestDownloadName(t *testing.T) {
	for _, c := range []struct{ title, typ, want string }{
		{"Datasheet", "application/pdf", "Datasheet.pdf"},
		{"manual.pdf", "application/pdf", "manual.pdf"},
		{"Front view", "image/png", "Front view.png"},
		{"photo.JPG", "image/jpeg", "photo.JPG"},
		{"photo.jpeg", "image/jpeg", "photo.jpeg"},
		{"notes.md", "text/plain", "notes.md.txt"},
		{"Firmware", "application/x-unknown-thing", "Firmware"},
	} {
		if got := DownloadName(c.title, c.typ); got != c.want {
			t.Errorf("DownloadName(%q, %q) = %q, want %q", c.title, c.typ, got, c.want)
		}
	}
}
