package serve

import (
	"encoding/json"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/radiohyperactivity/wtf/internal/files"
)

// The phone as a remote camera (2026-11-19-remote-camera.md): a session, on
// a phone say, is the camera for another session of the same account, on a
// desktop, and a photo it takes goes to what that desktop has open. Which
// phone is the camera for which desktop, and what that desktop has open,
// live in wtfd's memory, not in the database; a restart forgets them, and
// the phone's next request makes it the camera again.

// How long a camera lasts while its phone doesn't ask, how often old cameras
// are looked for, how often a quiet stream sends a line, and how often an
// open stream asks the database whether its session is still valid.
// Variables, for the tests.
var (
	cameraIdle      = 12 * time.Hour
	cameraSweep     = 10 * time.Minute
	streamKeepAlive = 30 * time.Second
	streamRecheck   = 5 * time.Minute
)

// The name a desktop gives what it has open is at most this many
// characters.
const maxTargetName = 500

// A session's id, as account.session_list gives it: the SHA-256 of its
// token, in hex.
var sessionIDPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

// target is what a desktop has open that a photo can be for: an item, a
// stock row or a location (Type "item", "stock" or "location", its ID and
// its Name), or a new one that isn't saved yet (Waiting: its type). Form
// says that one is open in a form, to edit. A photo for a form, new or
// not, is held for the desktop, which puts it in the form, to upload with
// the rest when saved. The zero target is nothing a photo can be for.
type target struct {
	Type    string `json:"type,omitempty"`
	ID      string `json:"id,omitempty"`
	Name    string `json:"name,omitempty"`
	Waiting string `json:"waiting,omitempty"`
	Form    bool   `json:"form,omitempty"`
}

// toForm says whether a photo for t goes to a form on the desktop, rather
// than straight to what it is for.
func (t target) toForm() bool { return t.Waiting != "" || t.Form }

// targetPaths are the API paths of the types of target.
var targetPaths = map[string]string{"item": "/items/", "stock": "/stock/", "location": "/locations/"}

// camera is a phone's camera: the desktop session it is for, that
// session's client name, the phone's own, and when the phone last asked.
type camera struct {
	desktop, client, phoneClient string
	seen                         time.Time
}

// cameras are which phone is the camera for which desktop, and what each
// desktop with a camera has open, by session id (sessionID); its events go
// through hub, the open event streams. Only desktops with a camera have a target kept, so memory
// grows with the cameras, not with the sessions.
type cameras struct {
	mu     sync.Mutex
	of     map[string]*camera         // phone → its camera
	phones map[string]map[string]bool // desktop → its phones
	target map[string]target          // desktop → what it has open, once it said
	held   map[string]*files.Staged   // desktop → a photo for its form, not fetched yet
	swept  time.Time                  // when old cameras were last looked for
	hub    *hub                       // the open event streams
	now    func() time.Time
}

func newCameras(h *hub) *cameras {
	return &cameras{
		of:     map[string]*camera{},
		phones: map[string]map[string]bool{},
		target: map[string]target{},
		held:   map[string]*files.Staged{},
		hub:    h,
		now:    time.Now,
	}
}

// send queues e on every open stream of session; the cameras' lock is
// held (the hub takes its own after it, never the other way round).
func (c *cameras) send(session string, e event) {
	c.hub.send(session, e)
}

// cameraEvent is the camera event for desktop: the client name of the phone
// that asked last, or {} when it has no camera; the lock is held.
func (c *cameras) cameraEvent(desktop string) event {
	data := map[string]string{}
	var latest *camera
	for phone := range c.phones[desktop] {
		if cam := c.of[phone]; latest == nil || cam.seen.After(latest.seen) {
			latest = cam
		}
	}
	if latest != nil {
		data["client"] = latest.phoneClient
	}
	return eventData("camera", data)
}

// start makes phone, whose client name is phoneClient, the camera for
// desktop, whose client name is client, instead of any desktop it was the
// camera for before. A desktop that gets a camera is told, so that it says
// what it has open.
func (c *cameras) start(phone, desktop, client, phoneClient string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.sweep()
	if cam := c.of[phone]; cam != nil && cam.desktop == desktop {
		// The same camera again: it stays as it is, and so does the
		// desktop's target.
		cam.client, cam.phoneClient, cam.seen = client, phoneClient, c.now()
		return
	}
	c.stop(phone)
	c.of[phone] = &camera{desktop: desktop, client: client, phoneClient: phoneClient, seen: c.now()}
	if c.phones[desktop] == nil {
		c.phones[desktop] = map[string]bool{}
	}
	c.phones[desktop][phone] = true
	c.send(desktop, c.cameraEvent(desktop))
}

// stop ends phone's camera, if it has one; the lock is held. A desktop
// left without a camera loses its target, and is told.
func (c *cameras) stop(phone string) {
	cam := c.of[phone]
	if cam == nil {
		return
	}
	delete(c.of, phone)
	delete(c.phones[cam.desktop], phone)
	if len(c.phones[cam.desktop]) == 0 {
		delete(c.phones, cam.desktop)
		delete(c.target, cam.desktop)
		c.drop(cam.desktop)
	}
	c.send(cam.desktop, c.cameraEvent(cam.desktop))
}

// unpair ends phone's camera (DELETE /me/camera).
func (c *cameras) unpair(phone string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.stop(phone)
}

// forget drops a session that has ended: its own camera, and the cameras
// for it, whose phones hear so on their next request, when the database
// no longer finds it.
func (c *cameras) forget(session string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.stop(session)
	for phone := range c.phones[session] {
		c.stop(phone)
	}
}

// report notes what desktop has open. A desktop without a camera keeps
// nothing.
func (c *cameras) report(desktop string, t target) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.phones[desktop]) == 0 {
		return
	}
	c.target[desktop] = t
}

// lookup is what the desktop phone is the camera for has open, when phone
// is its camera; ok is false when it isn't (any more), as after a restart.
func (c *cameras) lookup(phone, desktop string) (t target, ok bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	cam := c.of[phone]
	if cam == nil || cam.desktop != desktop {
		return target{}, false
	}
	cam.seen = c.now()
	return c.target[desktop], true
}

// drop discards the photo held for desktop, if any; the lock is held.
func (c *cameras) drop(desktop string) {
	if st := c.held[desktop]; st != nil {
		st.Discard()
		delete(c.held, desktop)
	}
}

// hold keeps photo for the form open on the desktop that phone is the
// camera for, instead of one held before, and tells the desktop (photo).
// False when phone is no camera (any more); the photo is then discarded.
func (c *cameras) hold(phone string, photo *files.Staged) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	cam := c.of[phone]
	if cam == nil {
		photo.Discard()
		return false
	}
	c.drop(cam.desktop)
	c.held[cam.desktop] = photo
	c.send(cam.desktop, eventData("photo", map[string]string{"client": cam.phoneClient}))
	return true
}

// take hands over the photo held for desktop, which is no longer held:
// nil when there is none.
func (c *cameras) take(desktop string) *files.Staged {
	c.mu.Lock()
	defer c.mu.Unlock()
	st := c.held[desktop]
	delete(c.held, desktop)
	return st
}

// changed tells the desktop that session is the camera for, if any, that
// session changed what is at path.
func (c *cameras) changed(session, path string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if cam := c.of[session]; cam != nil {
		c.send(cam.desktop, eventData("changed", map[string]string{"path": path}))
	}
}

// opened tells st, a new event stream of session, at once when session is
// a desktop with a camera; the others of its streams have been told.
func (c *cameras) opened(session string, st *stream) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.sweep()
	if len(c.phones[session]) > 0 {
		c.hub.sendTo(st, c.cameraEvent(session))
	}
}

// sweep ends the cameras whose phone hasn't asked for cameraIdle, at most
// every cameraSweep; the lock is held.
func (c *cameras) sweep() {
	now := c.now()
	if now.Sub(c.swept) < cameraSweep {
		return
	}
	c.swept = now
	for phone, cam := range c.of {
		if now.Sub(cam.seen) > cameraIdle {
			c.stop(phone)
		}
	}
}

// pair asks the database whether this session may be the camera for
// desktop, and makes it so. Returns what account.session_camera does.
func (s *server) pair(r *http.Request, desktop string) ([]byte, error) {
	result, err := s.callJSON(r.Context(), "account.session_camera",
		[]arg{{name: "p_session", typ: "text", value: desktop}})
	if err != nil {
		return nil, err
	}
	var found struct {
		Session string  `json:"session"`
		Client  *string `json:"client"`
		Camera  *string `json:"camera"`
	}
	if err := json.Unmarshal(result, &found); err != nil {
		return nil, err
	}
	text := func(s *string) string {
		if s == nil {
			return ""
		}
		return *s
	}
	s.cameras.start(sessionID(callerOf(r.Context()).token), found.Session, text(found.Client), text(found.Camera))
	return result, nil
}

// cameraFor: PUT /me/camera {"session": "<id>"}. The database checks that
// this session may be the camera for that one; the camera itself is kept
// here. Answers {session, client, camera}.
func (s *server) cameraFor(w http.ResponseWriter, r *http.Request) error {
	object, err := readObject(r)
	if err != nil {
		return err
	}
	var desktop string
	for key, raw := range object {
		if key != "session" {
			return invalidInput("unknown field %q", key)
		}
		if json.Unmarshal(raw, &desktop) != nil {
			return invalidInput("field %q is a string", "session")
		}
	}
	result, err := s.pair(r, desktop)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, result)
	return nil
}

// cameraStop: DELETE /me/camera. Only the holder of the session's token can
// send a cookie that hashes to its id, so the database isn't asked.
func (s *server) cameraStop(w http.ResponseWriter, r *http.Request) error {
	s.cameras.unpair(sessionID(callerOf(r.Context()).token))
	w.WriteHeader(http.StatusNoContent)
	return nil
}

// cameraTarget is what the desktop session ?session=<id> has open, for this
// session as its camera. Without the database while it is the camera
// already; after a restart, the database is asked again, and a desktop
// session that has ended is not found (404).
func (s *server) cameraTarget(r *http.Request) (string, target, error) {
	desktop := r.URL.Query().Get("session")
	if !sessionIDPattern.MatchString(desktop) {
		return "", target{}, invalidInput("session must be a session's id, 64 hexadecimal digits")
	}
	phone := sessionID(callerOf(r.Context()).token)
	if t, ok := s.cameras.lookup(phone, desktop); ok {
		return desktop, t, nil
	}
	if _, err := s.pair(r, desktop); err != nil {
		return "", target{}, err
	}
	t, _ := s.cameras.lookup(phone, desktop)
	return desktop, t, nil
}

// cameraLook: GET /me/camera?session=<id>, what a photo would be for:
// {type, id, name}, {waiting}, or {}.
func (s *server) cameraLook(w http.ResponseWriter, r *http.Request) error {
	_, t, err := s.cameraTarget(r)
	if err != nil {
		return err
	}
	data, _ := json.Marshal(t)
	writeJSON(w, http.StatusOK, data)
	return nil
}

// cameraPhoto: PUT /me/camera/photo?session=<id>, a photo for what the
// desktop session has open as it arrives, uploaded as its photo; for a
// form there, new or not, held for the desktop, which is told (photo) and
// fetches it (cameraHeld). Answers the target it went to; 409 when there is
// none. The desktop is told of an upload (changed).
func (s *server) cameraPhoto(w http.ResponseWriter, r *http.Request) error {
	_, t, err := s.cameraTarget(r)
	if err != nil {
		return err
	}
	if t.toForm() {
		staged, err := s.stage(w, r)
		if err != nil {
			return err
		}
		if !strings.HasPrefix(sniff(staged.Head), "image/") {
			staged.Discard()
			return invalidInput("A photo must be an image, and this is %s", sniff(staged.Head))
		}
		if !s.cameras.hold(sessionID(callerOf(r.Context()).token), staged) {
			return &problem{
				Type:   "/problems/wrong-state",
				Title:  "Not possible in this state",
				Status: http.StatusConflict,
				Detail: "This is no longer the camera there.",
			}
		}
		data, _ := json.Marshal(t)
		writeJSON(w, http.StatusOK, data)
		return nil
	}
	if t.ID == "" {
		return &problem{
			Type:   "/problems/wrong-state",
			Title:  "Not possible in this state",
			Status: http.StatusConflict,
			Detail: "Nothing is open there that a photo can be for.",
		}
	}
	if _, err := s.store(w, r, t.Type, t.ID, ""); err != nil {
		return err
	}
	s.cameras.changed(sessionID(callerOf(r.Context()).token), targetPaths[t.Type]+t.ID+"/photo")
	data, _ := json.Marshal(t)
	writeJSON(w, http.StatusOK, data)
	return nil
}

// cameraHeld: GET /me/camera/photo, the photo this session's camera took
// for its form, once: it is no longer held afterwards. 404 when there is
// none.
func (s *server) cameraHeld(w http.ResponseWriter, r *http.Request) error {
	if _, err := s.callJSON(r.Context(), "account.me", nil); err != nil {
		return err
	}
	photo := s.cameras.take(sessionID(callerOf(r.Context()).token))
	if photo == nil {
		return &problem{
			Type:   "/problems/not-found",
			Title:  "Not found",
			Status: http.StatusNotFound,
			Detail: "No photo from the camera is waiting.",
		}
	}
	defer photo.Discard()
	f, err := photo.Open()
	if err != nil {
		return err
	}
	defer f.Close()
	w.Header().Set("Content-Type", sniff(photo.Head))
	w.Header().Set("Content-Length", strconv.FormatInt(photo.Size, 10))
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)
	_, _ = io.Copy(w, f)
	return nil
}

// targetReport: PUT /me/target, what this session's app has open: {type,
// id, name}, {waiting}, or {}; with form true, it is open in a form. Kept only when the session has a camera;
// without the database, as for cameraStop. The answer is the same either
// way.
func (s *server) targetReport(w http.ResponseWriter, r *http.Request) error {
	object, err := readObject(r)
	if err != nil {
		return err
	}
	var t target
	for key, raw := range object {
		if key == "form" {
			if json.Unmarshal(raw, &t.Form) != nil {
				return invalidInput("field %q is true or false", key)
			}
			continue
		}
		var value string
		if json.Unmarshal(raw, &value) != nil {
			return invalidInput("field %q is a string", key)
		}
		switch key {
		case "type":
			t.Type = value
		case "id":
			t.ID = strings.ToLower(value)
		case "name":
			t.Name = value
		case "waiting":
			t.Waiting = value
		default:
			return invalidInput("unknown field %q", key)
		}
	}
	switch {
	case t.Waiting != "":
		if _, ok := targetPaths[t.Waiting]; !ok || t.Type != "" || t.ID != "" || t.Name != "" || t.Form {
			return invalidInput("waiting is item, stock or location, on its own")
		}
	case t.Form && t.Type == "":
		return invalidInput("form goes with type, id and name")
	case t.Type != "" || t.ID != "" || t.Name != "":
		if _, ok := targetPaths[t.Type]; !ok {
			return invalidInput("type is item, stock or location")
		}
		if !uuidPattern.MatchString(t.ID) {
			return invalidInput("id must be a UUID")
		}
		if len(t.Name) > maxTargetName {
			return invalidInput("a name is at most %d characters", maxTargetName)
		}
	}
	s.cameras.report(sessionID(callerOf(r.Context()).token), t)
	w.WriteHeader(http.StatusNoContent)
	return nil
}

// cameraChange is whether a successful request changes something the
// desktop a session is the camera for is told about (changed): any request
// but a GET under /items, /stock and /locations. path is relative to the
// API's prefix.
func cameraChange(method, path string) bool {
	if method == http.MethodGet {
		return false
	}
	for _, prefix := range []string{"/items", "/stock", "/locations"} {
		if path == prefix || strings.HasPrefix(path, prefix+"/") {
			return true
		}
	}
	return false
}
