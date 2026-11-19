package serve

import (
	"bufio"
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// next returns the stream's next event, or fails when none is waiting.
func next(t *testing.T, st *stream) string {
	t.Helper()
	select {
	case e := <-st.events:
		return e.name + " " + string(e.data)
	default:
		t.Fatal("no event")
		return ""
	}
}

// none fails when an event is waiting on the stream.
func none(t *testing.T, st *stream) {
	t.Helper()
	select {
	case e := <-st.events:
		t.Fatalf("unexpected event %s %s", e.name, e.data)
	default:
	}
}

// Which phone is the camera for which desktop, the targets, and the
// changes, as decisions 10 to 14 of the plan say.
func TestCameras(t *testing.T) {
	c := newCameras()
	pc := c.open("pc")
	drill := target{Type: "item", ID: "0198a5c4-0000-7000-8000-000000000001", Name: "Drill"}

	// A desktop without a camera keeps no target.
	c.report("pc", drill)
	if len(c.target) != 0 {
		t.Fatalf("target of a desktop without a camera: %v", c.target)
	}

	// The desktop is told it has a camera, and says what it has open.
	c.start("phone", "pc", "WtF on Windows", "WtF on iPhone")
	if got := next(t, pc); got != `camera {"client":"WtF on iPhone"}` {
		t.Fatalf("camera: %s", got)
	}
	if got, ok := c.lookup("phone", "pc"); !ok || got != (target{}) {
		t.Fatalf("before the desktop said: %v %v", got, ok)
	}
	c.report("pc", drill)
	if got, ok := c.lookup("phone", "pc"); !ok || got != drill {
		t.Fatalf("target: %v %v", got, ok)
	}
	if _, ok := c.lookup("phone", "laptop"); ok {
		t.Fatal("the phone is the camera for the laptop")
	}
	if _, ok := c.lookup("tablet", "pc"); ok {
		t.Fatal("the tablet is a camera")
	}

	// The same camera again, as a phone says after a restart of the app:
	// nothing changes, and the desktop isn't told again.
	c.start("phone", "pc", "WtF on Windows", "WtF on iPhone")
	none(t, pc)
	if got, _ := c.lookup("phone", "pc"); got != drill {
		t.Fatalf("target after starting again: %v", got)
	}

	// A desktop that reconnects hears at once that it has a camera.
	c.close("pc", pc)
	pc = c.open("pc")
	if got := next(t, pc); got != `camera {"client":"WtF on iPhone"}` {
		t.Fatalf("camera on reconnecting: %s", got)
	}

	// A change by the phone goes to the desktop; nobody else's does.
	c.changed("phone", "/items/1/photo")
	if got := next(t, pc); got != `changed {"path":"/items/1/photo"}` {
		t.Fatalf("changed: %s", got)
	}
	c.changed("pc", "/items/1")
	c.changed("elsewhere", "/items/1")
	none(t, pc)

	// The desktop logs out: nothing is kept, and the phone finds out on its
	// next request.
	c.forget("pc")
	if !pc.ended || len(c.of) != 0 || len(c.phones) != 0 || len(c.target) != 0 {
		t.Fatalf("after logging out: %v %v %v", c.of, c.phones, c.target)
	}

	// Stopping drops the desktop's target, and tells it.
	laptop := c.open("laptop")
	c.start("phone", "laptop", "", "WtF on iPhone")
	next(t, laptop)
	c.report("laptop", drill)
	c.unpair("phone")
	if got := next(t, laptop); got != `camera {}` {
		t.Fatalf("camera after stopping: %s", got)
	}
	if len(c.target) != 0 || len(c.phones) != 0 {
		t.Fatalf("after stopping: %v %v", c.target, c.phones)
	}
}

// A camera ends after cameraIdle without its phone asking, but not while it
// asks.
func TestCamerasExpire(t *testing.T) {
	now := time.Date(2026, 11, 19, 12, 0, 0, 0, time.UTC)
	c := newCameras()
	c.now = func() time.Time { return now }
	c.start("phone", "pc", "", "")
	c.start("tablet", "pc", "", "")

	now = now.Add(cameraIdle - time.Minute)
	c.lookup("tablet", "pc")
	now = now.Add(2 * time.Minute)
	c.open("pc") // looks for old cameras
	if c.of["phone"] != nil || c.of["tablet"] == nil {
		t.Fatalf("after %v: %v", cameraIdle, c.of)
	}

	// Looked for at most every cameraSweep.
	now = now.Add(cameraSweep - time.Second)
	c.of["tablet"].seen = now.Add(-2 * cameraIdle)
	c.open("pc")
	if c.of["tablet"] == nil {
		t.Fatal("looked for old cameras too soon")
	}
	now = now.Add(time.Second)
	c.open("pc")
	if c.of["tablet"] != nil {
		t.Fatal("the tablet's camera is still there")
	}
}

// The stream outlives the server's read and write timeouts, sends a line
// when quiet, passes events on, and ends with "ended" once its session is
// found ended.
func TestStream(t *testing.T) {
	saved := []time.Duration{streamKeepAlive, streamRecheck}
	defer func() { streamKeepAlive, streamRecheck = saved[0], saved[1] }()
	streamKeepAlive, streamRecheck = 100*time.Millisecond, 700*time.Millisecond

	s := testServer()
	var valid atomic.Bool
	valid.Store(true)
	check := func() error {
		if valid.Load() {
			return nil
		}
		return &problem{Status: http.StatusUnauthorized}
	}
	ts := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r = r.WithContext(context.WithValue(r.Context(), callerKey{}, caller{token: "pc-token"}))
		_ = s.stream(w, r, check)
	}))
	ts.Config.ReadTimeout = 300 * time.Millisecond
	ts.Config.WriteTimeout = 300 * time.Millisecond
	ts.Start()
	defer ts.Close()

	pc := sessionID("pc-token")
	resp, err := http.Get(ts.URL)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if ct := resp.Header.Get("Content-Type"); ct != "text/event-stream" {
		t.Fatalf("content type %q", ct)
	}

	lines := make(chan string)
	go func() {
		scanner := bufio.NewScanner(resp.Body)
		for scanner.Scan() {
			lines <- scanner.Text()
		}
		close(lines)
	}()
	// wait reads lines until one starts with want.
	wait := func(want string) {
		t.Helper()
		deadline := time.After(3 * time.Second)
		for {
			select {
			case line, ok := <-lines:
				if !ok {
					t.Fatalf("the stream ended before %q", want)
				}
				if strings.HasPrefix(line, want) {
					return
				}
			case <-deadline:
				t.Fatalf("no %q", want)
			}
		}
	}

	wait(": keep-alive")
	time.Sleep(400 * time.Millisecond) // past both timeouts
	s.cameras.start("phone", pc, "WtF on Windows", "WtF on iPhone")
	wait("event: camera")
	wait(`data: {"client":"WtF on iPhone"}`)

	valid.Store(false)
	wait("event: ended")
	// Its data and the empty line after it; then the stream ends.
	for n := 0; ; n++ {
		if _, ok := <-lines; !ok {
			break
		}
		if n == 2 {
			t.Fatal("the stream goes on after ended")
		}
	}
	if s.cameras.of["phone"] != nil {
		t.Fatal("the camera for an ended session is still there")
	}
}

// Changes under /items, /stock and /locations are passed on; reading and
// the rest aren't.
func TestCameraChange(t *testing.T) {
	for _, c := range []struct {
		method, path string
		want         bool
	}{
		{"PUT", "/items/1/photo", true},
		{"PATCH", "/stock/1", true},
		{"POST", "/locations", true},
		{"DELETE", "/items/1", true},
		{"GET", "/items/1", false},
		{"PUT", "/me/target", false},
		{"POST", "/itemsx", false},
		{"PATCH", "/classes/1", false},
	} {
		if got := cameraChange(c.method, c.path); got != c.want {
			t.Errorf("%s %s: %v", c.method, c.path, got)
		}
	}
}
