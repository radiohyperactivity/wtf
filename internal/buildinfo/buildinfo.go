// Package buildinfo says which build of wtfd this is: when it was built,
// and from which commit. Go records the commit when it builds in a git
// checkout; the build time it doesn't, so scripts/build.sh stamps it:
//
//	go build -ldflags "-X github.com/radiohyperactivity/wtf/internal/buildinfo.date=2026-11-06T14:02:11Z"
package buildinfo

import (
	"runtime/debug"
	"time"
)

// date is when the build was made, RFC 3339 in UTC, as stamped by the
// build; "" when it wasn't.
var date string

// Info is the build's details; a zero time or an empty revision is one
// that isn't known.
type Info struct {
	Build    time.Time // when it was built
	Commit   time.Time // when the commit it was built from was made
	Revision string    // that commit's ID
}

// Read returns the build's details.
func Read() Info {
	var info Info
	if t, err := time.Parse(time.RFC3339, date); err == nil {
		info.Build = t.UTC()
	}
	if bi, ok := debug.ReadBuildInfo(); ok {
		for _, s := range bi.Settings {
			switch s.Key {
			case "vcs.revision":
				info.Revision = s.Value
			case "vcs.time":
				if t, err := time.Parse(time.RFC3339, s.Value); err == nil {
					info.Commit = t.UTC()
				}
			}
		}
	}
	return info
}
