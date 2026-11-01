package serve

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"strings"
)

// Routes that work without logging in.
var anonymousRoutes = map[string]bool{
	"GET /health":  true,
	"GET /openapi": true,
	"POST /login":  true,
}

// The session travels in a cookie, for every client: browsers keep it
// themselves, other clients (the CLI, the apps) store it and send it back in
// a Cookie header. The database decides how long a session lasts (as the
// user chose when logging in); the cookie is kept for as long as browsers
// keep one. See WTFD.md, "Logins".
const (
	sessionCookie = "wtf_session"
	sessionMaxAge = 400 * 24 * 60 * 60 // seconds: 400 days, the longest browsers keep a cookie
)

// sessionToken returns the token of the session cookie.
func sessionToken(r *http.Request) (string, bool) {
	c, err := r.Cookie(sessionCookie)
	if err != nil || c.Value == "" {
		return "", false
	}
	return c.Value, true
}

// sessionID is a session's id as the database gives it: the SHA-256 of its
// token, in hex.
func sessionID(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

// setSessionCookie sends the session cookie. It is HttpOnly (scripts on a page
// can't read it), SameSite=Strict (browsers don't send it with requests from
// other sites), limited to /api, and Secure (sent over HTTPS only) when the
// request came over HTTPS, directly or through a proxy. maxAge 0 deletes it.
func setSessionCookie(w http.ResponseWriter, r *http.Request, token string, maxAge int) {
	c := &http.Cookie{
		Name:     sessionCookie,
		Value:    token,
		Path:     "/api",
		MaxAge:   maxAge,
		HttpOnly: true,
		SameSite: http.SameSiteStrictMode,
		Secure:   r.TLS != nil || strings.EqualFold(r.Header.Get("X-Forwarded-Proto"), "https"),
	}
	if maxAge == 0 {
		c.MaxAge = -1 // "Max-Age=0": delete it now
	}
	w.Header().Set("Set-Cookie", c.String())
}

// logout ends the session and deletes the cookie. The cookie is deleted
// first: once the 204 is written, headers can't change any more.
func (s *server) logout(w http.ResponseWriter, r *http.Request) error {
	setSessionCookie(w, r, "", 0)
	return s.remove("account.logout")(w, r)
}

// sessionLogout ends one of the caller's sessions, DELETE
// /me/sessions/{id}; the current one's id logs out as POST /logout does,
// and deletes the cookie.
func (s *server) sessionLogout(w http.ResponseWriter, r *http.Request) error {
	if sessionID(callerOf(r.Context()).token) == strings.ToLower(r.PathValue("id")) {
		setSessionCookie(w, r, "", 0)
	}
	return s.remove("account.session_logout", pathText("p_session", "id"))(w, r)
}

// logoutOthers ends the caller's other sessions, POST
// /me/sessions/logout-others, and says how many: {"ended": n}.
func (s *server) logoutOthers(w http.ResponseWriter, r *http.Request) error {
	result, err := s.callJSON(r.Context(), "account.session_logout_others", nil)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, []byte(`{"ended":`+string(result)+`}`))
	return nil
}

var unauthenticated = &problem{
	Type:   "/problems/unauthenticated",
	Title:  "Not authenticated",
	Status: http.StatusUnauthorized,
	Detail: "Log in with POST " + apiPrefix + "/login, which sets the session cookie \"" + sessionCookie + "\", and send it with every request.",
}

// login: POST /login {email, password, client, max_idle}, to the tenant of
// the request's hostname. client is what the client calls itself ("WtF on
// Pixel 9"), and may be null; max_idle is how long, in seconds, the session
// may sit unused before it expires, or null for never. Both are required.
func (s *server) login(w http.ResponseWriter, r *http.Request) error {
	args, err := collect(r, []param{body(
		field{key: "email", name: "p_email", typ: "text"},
		field{key: "password", name: "p_password", typ: "text"},
		field{key: "client", name: "p_client", typ: "text"},
		field{key: "max_idle", name: "p_max_idle", typ: "seconds"},
	)})
	if err != nil {
		return err
	}
	email, client := args[0].value, args[2].value
	result, err := s.callJSON(r.Context(), "account.login", args)
	if err != nil {
		return err
	}

	var outcome map[string]json.RawMessage
	if err := json.Unmarshal(result, &outcome); err != nil {
		return err
	}
	// Every login attempt is logged: who, with what and from where.
	// Passwords never are.
	who := callerOf(r.Context())
	attrs := []any{"host", who.host, "email", email, "client", client, "address", who.address}
	if string(outcome["ok"]) != "true" {
		var reason string
		_ = json.Unmarshal(outcome["reason"], &reason)
		s.log.Warn("login failed", append(attrs, "reason", reason)...)
		if reason == "locked" {
			w.Header().Set("Retry-After", "60")
			return &problem{
				Type:   "/problems/too-many-attempts",
				Title:  "Too many failed logins",
				Status: http.StatusTooManyRequests,
				Detail: "After 5 failed logins only one attempt per minute is accepted. Try again in a minute.",
			}
		}
		return &problem{
			Type:   "/problems/unauthenticated",
			Title:  "Wrong email or password",
			Status: http.StatusUnauthorized,
		}
	}
	var account struct {
		ID string `json:"id"`
	}
	_ = json.Unmarshal(outcome["account"], &account)
	s.log.Info("login", append(attrs, "account", account.ID)...)
	var token string
	_ = json.Unmarshal(outcome["token"], &token)
	setSessionCookie(w, r, token, sessionMaxAge)
	// The token is only in the cookie, never in the body, so scripts on a
	// web page can't get at it.
	delete(outcome, "ok")
	delete(outcome, "token")
	body, err := json.Marshal(outcome)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, body)
	return nil
}
