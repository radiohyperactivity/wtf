package serve

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"time"
)

// events: GET /me/events, the session's event stream.
func (s *server) events(w http.ResponseWriter, r *http.Request) error {
	return s.stream(w, r, func() (string, error) { return s.myAccount(r) })
}

// myAccount is the id of the account the request is made with, from
// account.me; an ended session is refused (401).
func (s *server) myAccount(r *http.Request) (string, error) {
	result, err := s.callJSON(r.Context(), "account.me", nil)
	if err != nil {
		return "", err
	}
	var me struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(result, &me); err != nil {
		return "", err
	}
	return me.ID, nil
}

// stream sends the session's events as server-sent events until the client
// goes, the session is found ended (check, when the stream opens and every
// streamRecheck), or wtfd shuts down. check gives the session's account,
// so that the stream also gets the events for the whole account. A quiet
// stream sends a comment line every streamKeepAlive, so that proxies keep
// it open.
func (s *server) stream(w http.ResponseWriter, r *http.Request, check func() (string, error)) error {
	// Before the answer starts, an ended session still gets its 401.
	account, err := check()
	if err != nil {
		return err
	}
	session := sessionID(callerOf(r.Context()).token)
	st := s.hub.open(session, account)
	if st == nil {
		return &problem{
			Type:   "/problems/unavailable",
			Title:  "Shutting down",
			Status: http.StatusServiceUnavailable,
		}
	}
	defer s.hub.close(session, st)
	s.cameras.opened(session, st)

	// The server's read and write timeouts are for ordinary requests; this
	// one stays open. Each write gets a deadline of its own instead.
	rc := http.NewResponseController(w)
	_ = rc.SetReadDeadline(time.Time{})
	write := func(text string) bool {
		_ = rc.SetWriteDeadline(time.Now().Add(streamKeepAlive))
		if _, err := fmt.Fprint(w, text); err != nil {
			return false
		}
		return rc.Flush() == nil
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("X-Accel-Buffering", "no") // nginx: pass it on as it comes
	w.WriteHeader(http.StatusOK)
	if !write(": events\n\n") {
		return nil
	}

	keepAlive := time.NewTicker(streamKeepAlive)
	defer keepAlive.Stop()
	recheck := time.NewTicker(streamRecheck)
	defer recheck.Stop()
	// Once the answer has started, an error can't become a problem any
	// more: the stream just ends.
	for {
		select {
		case <-r.Context().Done():
			return nil
		case <-st.done:
			return nil
		case e := <-st.events:
			if !write(fmt.Sprintf("event: %s\ndata: %s\n\n", e.name, e.data)) {
				return nil
			}
		case <-keepAlive.C:
			if !write(": keep-alive\n\n") {
				return nil
			}
		case <-recheck.C:
			_, err := check()
			if p, _ := problemFor(err, r.Method); err != nil && p.Status == http.StatusUnauthorized {
				write("event: ended\ndata: {}\n\n")
				s.ended(session)
				return nil
			} else if err != nil && !errors.Is(err, r.Context().Err()) {
				s.log.Warn("event stream: checking the session failed", "error", err)
			}
		}
	}
}

// ended forgets a session that has ended: its camera, the cameras for it,
// and its event streams, which end.
func (s *server) ended(session string) {
	s.cameras.forget(session)
	s.hub.end(session)
}

// preferencesPatch: PATCH /me/preferences, changes some of the caller's
// preferences (account.preferences_patch), and answers them all. Every
// session of the account with an open event stream is told (preferences),
// this one too, and asks for them again: the event has no data, so that
// one sent late can't bring back older preferences.
func (s *server) preferencesPatch(w http.ResponseWriter, r *http.Request) error {
	args, err := patch("p_patch")(r)
	if err != nil {
		return err
	}
	result, err := s.callJSON(r.Context(), "account.preferences_patch", args)
	if err != nil {
		return err
	}
	if account, err := s.myAccount(r); err == nil {
		s.hub.sendAccount(account, eventData("preferences", map[string]string{}))
	}
	writeJSON(w, http.StatusOK, result)
	return nil
}
