//go:build webapp

package webapp

import (
	"embed"
	"io/fs"
)

// dist is the web build. Names starting with "." or "_" are left out, as
// embed does without "all:"; Flutter's .last_build_id among them.
//
//go:embed dist
var dist embed.FS

// Files is the web app built into wtfd.
var Files = func() fs.FS {
	files, err := fs.Sub(dist, "dist")
	if err != nil {
		panic(err) // dist is embedded above, so it is there
	}
	return files
}()
