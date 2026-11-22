package files

import (
	"testing"
	"time"
)

func TestNextAt(t *testing.T) {
	oslo, err := time.LoadLocation("Europe/Oslo")
	if err != nil {
		t.Skip("no time zone database:", err)
	}
	at := func(s string) time.Time {
		t.Helper()
		v, err := time.ParseInLocation("2006-01-02 15:04", s, oslo)
		if err != nil {
			t.Fatal(err)
		}
		return v
	}
	for _, c := range []struct {
		name, now, want string
	}{
		{"later today", "2026-11-20 01:00", "2026-11-20 02:00"},
		{"tomorrow", "2026-11-20 13:00", "2026-11-21 02:00"},
		{"at the time itself, tomorrow", "2026-11-20 02:00", "2026-11-21 02:00"},
		{"across a month", "2026-11-30 03:00", "2026-12-01 02:00"},
		// The clocks go from 02:00 to 03:00 that night, so 02:00 is
		// an hour later than it would be.
		{"when the clocks go forward", "2027-03-27 12:00", "2027-03-28 03:00"},
		{"when the clocks go back", "2027-10-30 12:00", "2027-10-31 02:00"},
	} {
		t.Run(c.name, func(t *testing.T) {
			got := nextAt(at(c.now), 2, 0)
			if want := at(c.want); !got.Equal(want) {
				t.Errorf("nextAt(%s) = %s, want %s", c.now, got, want)
			}
		})
	}
}
