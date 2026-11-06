package buildinfo

import (
	"testing"
	"time"
)

// The build date is read as stamped; one that isn't a time is none.
func TestRead(t *testing.T) {
	saved := date
	defer func() { date = saved }()

	date = "2026-11-06T14:02:11Z"
	if got, want := Read().Build, time.Date(2026, 11, 6, 14, 2, 11, 0, time.UTC); !got.Equal(want) {
		t.Errorf("build %v, want %v", got, want)
	}
	for _, d := range []string{"", "yesterday"} {
		date = d
		if got := Read().Build; !got.IsZero() {
			t.Errorf("date %q: build %v, want none", d, got)
		}
	}
}
