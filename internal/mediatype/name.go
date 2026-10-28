// Package mediatype names downloaded attachments after their title and MIME
// type, the same in wtfd and the CLI.
package mediatype

import (
	"mime"
	"path/filepath"
	"strings"
)

// preferredExtensions are the extensions downloads get for common types;
// for others, the first one the mime package knows is used.
var preferredExtensions = map[string]string{
	"image/jpeg":       ".jpg",
	"image/png":        ".png",
	"image/gif":        ".gif",
	"image/webp":       ".webp",
	"image/svg+xml":    ".svg",
	"application/pdf":  ".pdf",
	"text/plain":       ".txt",
	"text/csv":         ".csv",
	"application/zip":  ".zip",
	"application/json": ".json",
}

// DownloadName is the file name a download gets: the title, plus an
// extension for the type when the title doesn't already end in one that
// fits ("Datasheet" as application/pdf is "Datasheet.pdf"; the default
// title, the uploaded file's name, usually ends in one).
func DownloadName(title, contentType string) string {
	ext := strings.ToLower(filepath.Ext(title))
	if ext != "" {
		if t := mime.TypeByExtension(ext); t != "" {
			if mt, _, err := mime.ParseMediaType(t); err == nil && mt == contentType {
				return title
			}
		}
		if preferredExtensions[contentType] == ext {
			return title
		}
	}
	if pref, ok := preferredExtensions[contentType]; ok {
		return title + pref
	}
	if exts, err := mime.ExtensionsByType(contentType); err == nil && len(exts) > 0 {
		for _, e := range exts {
			if e == ext {
				return title
			}
		}
		return title + exts[0]
	}
	return title
}
