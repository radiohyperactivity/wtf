package files

import (
	"context"
	"time"
)

// Daily calls run every day at hour:minute in the local time zone, until
// ctx is done. It looks at the clock once a minute, rather than sleeping
// until the time, so that a clock that is set, or a machine that was
// asleep at the time, doesn't make it miss a day: it then runs when it
// next looks.
func Daily(ctx context.Context, hour, minute int, run func(context.Context)) {
	next := nextAt(time.Now(), hour, minute)
	ticker := time.NewTicker(time.Minute)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			// Round(0) compares the clock's time, not the time since
			// wtfd started, which doesn't count time spent asleep.
			if now := time.Now().Round(0); !now.Before(next) {
				run(ctx)
				next = nextAt(time.Now(), hour, minute)
			}
		}
	}
}

// nextAt is the first hour:minute after now, in now's time zone. On a day
// when the clocks go forward past that time, it is as much later.
func nextAt(now time.Time, hour, minute int) time.Time {
	t := time.Date(now.Year(), now.Month(), now.Day(), hour, minute, 0, 0, now.Location())
	if !t.After(now) {
		t = time.Date(now.Year(), now.Month(), now.Day()+1, hour, minute, 0, 0, now.Location())
	}
	return t
}
