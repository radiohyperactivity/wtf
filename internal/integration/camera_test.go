package integration

// The phone as a remote camera (2026-11-19-remote-camera.md): through a real
// HTTP server, as the desktop's event stream needs one.

import (
	"bufio"
	"bytes"
	"fmt"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// events opens a session's event stream on server, and returns its events,
// "name data", one per line.
func events(t *testing.T, server, token string) <-chan string {
	t.Helper()
	req, _ := http.NewRequest("GET", server+"/api/v1/me/events", nil)
	req.Header.Set("Cookie", "wtf_session="+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != 200 {
		t.Fatalf("GET /me/events: %d", resp.StatusCode)
	}
	t.Cleanup(func() { resp.Body.Close() })
	out := make(chan string, 16)
	go func() {
		defer close(out)
		scanner := bufio.NewScanner(resp.Body)
		var name string
		for scanner.Scan() {
			line := scanner.Text()
			if v, ok := strings.CutPrefix(line, "event: "); ok {
				name = v
			} else if v, ok := strings.CutPrefix(line, "data: "); ok {
				out <- name + " " + v
			}
		}
	}()
	return out
}

// expectEvent fails unless the stream's next event is want.
func expectEvent(t *testing.T, stream <-chan string, want string) {
	t.Helper()
	select {
	case got := <-stream:
		if got != want {
			t.Fatalf("event %s, want %s", got, want)
		}
	case <-time.After(5 * time.Second):
		t.Fatalf("no event, want %s", want)
	}
}

// expectNoEvent fails when an event comes on the stream within a moment.
func expectNoEvent(t *testing.T, stream <-chan string) {
	t.Helper()
	select {
	case got := <-stream:
		t.Fatalf("unexpected event %s", got)
	case <-time.After(200 * time.Millisecond):
	}
}

// photoUpload is a multipart body with one "file" part of content, and its
// content type.
func photoUpload(t *testing.T, content []byte) (string, string) {
	t.Helper()
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	part, err := mw.CreateFormFile("file", "photo.png")
	if err != nil {
		t.Fatal(err)
	}
	part.Write(content)
	mw.Close()
	return buf.String(), mw.FormDataContentType()
}

func TestCamera(t *testing.T) {
	e := setup(t)
	server := httptest.NewServer(e.handler)
	// Close waits for open requests: the streams, closed by cleanups
	// registered later, which run first.
	t.Cleanup(server.Close)

	email := fmt.Sprintf("camera-%d@test.local", time.Now().UnixNano())
	e.expect(t, 201, "POST", "/accounts", obj("email", email, "password", "secret-password", "role", "user"))
	login := func(client string) string {
		return session(t, e.expect(t, 200, "POST", "/login",
			obj("email", email, "password", "secret-password", "client", client, "max_idle", nil), "Cookie", ""))
	}
	pc, phone := login("WtF on Windows"), login("WtF on iPhone")
	ids := map[string]string{}
	for _, s := range e.expect(t, 200, "GET", "/me/sessions", nil, as(phone)...).body.([]any) {
		ids[str(t, s, "client")] = str(t, s, "id")
	}
	pcID := ids["WtF on Windows"]
	look := "/me/camera?session=" + pcID
	photo := func(status int, content []byte) response {
		t.Helper()
		body, contentType := photoUpload(t, content)
		return e.expect(t, status, "PUT", "/me/camera/photo?session="+pcID, body,
			append([]string{"Content-Type", contentType}, as(phone)...)...)
	}

	// Only another active session of one's own account.
	e.expect(t, 400, "PUT", "/me/camera", obj("session", ids["WtF on iPhone"]), as(phone)...)
	e.expect(t, 400, "PUT", "/me/camera", obj("session", "not-an-id"), as(phone)...)
	e.expect(t, 400, "GET", "/me/camera?session=not-an-id", nil, as(phone)...)
	var adminID string
	for _, s := range e.expect(t, 200, "GET", "/me/sessions", nil).body.([]any) {
		if get(t, s, "current") == true {
			adminID = str(t, s, "id")
		}
	}
	e.expect(t, 404, "PUT", "/me/camera", obj("session", adminID), as(phone)...)
	e.expect(t, 401, "GET", "/me/events", nil, "Cookie", "wtf_session=not-a-token")

	// A desktop without a camera keeps nothing; once it has one, it is told.
	e.expect(t, 204, "PUT", "/me/target", obj("waiting", "item"), as(pc)...)
	pcEvents := events(t, server.URL, pc)
	expectNoEvent(t, pcEvents)
	r := e.expect(t, 200, "PUT", "/me/camera", obj("session", pcID), as(phone)...).body
	if str(t, r, "session") != pcID || str(t, r, "client") != "WtF on Windows" || str(t, r, "camera") != "WtF on iPhone" {
		t.Fatalf("camera: %v", r)
	}
	expectEvent(t, pcEvents, `camera {"client":"WtF on iPhone"}`)
	if got := e.expect(t, 200, "GET", look, nil, as(phone)...).body; len(got.(map[string]any)) != 0 {
		t.Fatalf("before the desktop said: %v", got)
	}
	photo(409, pngBytes)

	// A new item not saved yet: still no photo.
	e.expect(t, 204, "PUT", "/me/target", obj("waiting", "item"), as(pc)...)
	if got := e.expect(t, 200, "GET", look, nil, as(phone)...).body; str(t, got, "waiting") != "item" {
		t.Fatalf("waiting: %v", got)
	}
	photo(409, pngBytes)

	// A saved one: the photo goes to it, and the desktop is told.
	class := str(t, e.expect(t, 201, "POST", "/classes", obj("name", "Camera "+email)).body, "id")
	item := str(t, e.expect(t, 201, "POST", "/items", obj("class", class, "name", "Drill"), as(pc)...).body, "id")
	drill := obj("type", "item", "id", item, "name", "Drill")
	e.expect(t, 204, "PUT", "/me/target", drill, as(pc)...)
	if got := e.expect(t, 200, "GET", look, nil, as(phone)...).body; str(t, got, "id") != item || str(t, got, "name") != "Drill" {
		t.Fatalf("target: %v", got)
	}
	if got := photo(200, pngBytes).body; str(t, got, "id") != item || str(t, got, "type") != "item" {
		t.Fatalf("photo went to: %v", got)
	}
	expectEvent(t, pcEvents, `changed {"path":"/items/`+item+`/photo"}`)
	if got := e.expect(t, 200, "GET", "/items/"+item, nil).body; get(t, got, "photo") == nil {
		t.Fatalf("no photo on the item: %v", got)
	}
	photo(400, pdfBytes)

	// What a desktop says must make sense.
	e.expect(t, 400, "PUT", "/me/target", obj("type", "thing", "id", item), as(pc)...)
	e.expect(t, 400, "PUT", "/me/target", obj("type", "item", "id", "x"), as(pc)...)
	e.expect(t, 400, "PUT", "/me/target", obj("waiting", "item", "type", "item"), as(pc)...)
	e.expect(t, 400, "PUT", "/me/target", obj("other", "x"), as(pc)...)

	// Stopping tells the desktop; asking again makes the phone the camera
	// again, as after a restart of wtfd.
	e.expect(t, 204, "DELETE", "/me/camera", nil, as(phone)...)
	expectEvent(t, pcEvents, `camera {}`)
	e.expect(t, 200, "GET", look, nil, as(phone)...)
	expectEvent(t, pcEvents, `camera {"client":"WtF on iPhone"}`)

	// The desktop logs out: the phone hears so on its next request.
	e.expect(t, 204, "POST", "/logout", nil, as(pc)...)
	e.expect(t, 404, "GET", look, nil, as(phone)...)
	photo(404, pngBytes)
	e.expect(t, 204, "DELETE", "/me/camera", nil, as(phone)...)
}
