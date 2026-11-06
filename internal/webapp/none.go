//go:build !webapp

package webapp

import "io/fs"

// Files is the web app built into wtfd: none, in a build without the tag
// "webapp".
var Files fs.FS
