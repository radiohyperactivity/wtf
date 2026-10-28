package serve

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// Routes that work without logging in.
var anonymousRoutes = map[string]bool{
	"GET /health":       true,
	"GET /openapi.yaml": true,
	"POST /login":       true,
}

// session is the login of a request: its session token.
type session struct {
	token string
}

type sessionKey struct{}

// querier is satisfied by both the pool and a transaction.
type querier interface {
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

// inSession runs fn in a transaction that first starts the request's session
// (session_use), so the database knows the account and its tenant, which
// must be the tenant of the request's hostname. Anonymous requests run fn
// directly.
func (s *server) inSession(ctx context.Context, fn func(q querier) error) error {
	sess, ok := ctx.Value(sessionKey{}).(session)
	if !ok {
		return fn(s.pool)
	}
	return pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		if err := useSession(ctx, tx, sess, tenantOf(ctx)); err != nil {
			return err
		}
		return fn(tx)
	})
}

func useSession(ctx context.Context, tx pgx.Tx, sess session, host string) error {
	_, err := tx.Exec(ctx, "SELECT session_use($1, $2)", sess.token, host)
	return err
}

// The session travels in a cookie, for every client: browsers keep it
// themselves, other clients (the CLI, the apps) store it and send it back
// in a Cookie header. See WTFD.md, "Logins".
const (
	sessionCookie = "wtf_session"
	sessionMaxAge = 30 * 24 * 60 * 60 // seconds; the session expires after 30 days without use
)

// sessionToken returns the token of the session cookie.
func sessionToken(r *http.Request) (string, bool) {
	c, err := r.Cookie(sessionCookie)
	if err != nil || c.Value == "" {
		return "", false
	}
	return c.Value, true
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
	return s.remove("logout")(w, r)
}

var unauthenticated = &problem{
	Type:   "/problems/unauthenticated",
	Title:  "Not authenticated",
	Status: http.StatusUnauthorized,
	Detail: "Log in with POST " + apiPrefix + "/login, which sets the session cookie \"" + sessionCookie + "\", and send it with every request.",
}

// login: POST /login {email, password}, to the tenant of the request's
// hostname.
func (s *server) login(w http.ResponseWriter, r *http.Request) error {
	args, err := collect(r, []param{body(
		field{key: "email", name: "p_email", typ: "text"},
		field{key: "password", name: "p_password", typ: "text"},
	)})
	if err != nil {
		return err
	}
	email := args[0].value
	args = append(args, arg{name: "p_host", typ: "text", value: tenantOf(r.Context())})
	result, err := s.callJSON(r.Context(), "login", args)
	if err != nil {
		return err
	}

	var outcome map[string]json.RawMessage
	if err := json.Unmarshal(result, &outcome); err != nil {
		return err
	}
	// Every login attempt is logged: who and from where. Passwords never
	// are.
	attrs := []any{"host", tenantOf(r.Context()), "email", email, "remote", r.RemoteAddr}
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
