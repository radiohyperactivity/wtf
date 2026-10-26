package serve

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"

	"github.com/jackc/pgx/v5/pgconn"
)

// problem is an RFC 9457 problem detail. It doubles as an error, so request
// handling code can return one directly.
type problem struct {
	Type     string `json:"type"`
	Title    string `json:"title"`
	Status   int    `json:"status"`
	Detail   string `json:"detail,omitempty"`
	SQLState string `json:"sqlstate,omitempty"`
	// Supported lists the API versions this server serves, in an
	// unsupported-api-version problem.
	Supported []int `json:"supported,omitempty"`
}

func (p *problem) Error() string {
	return fmt.Sprintf("%d %s: %s", p.Status, p.Title, p.Detail)
}

func invalidInput(format string, args ...any) *problem {
	return &problem{
		Type:   "/problems/invalid-input",
		Title:  "Invalid input",
		Status: http.StatusBadRequest,
		Detail: fmt.Sprintf(format, args...),
	}
}

var (
	notFound = &problem{
		Type:   "/problems/not-found",
		Title:  "Not found",
		Status: http.StatusNotFound,
	}
	internalError = &problem{
		Type:   "/problems/internal",
		Title:  "Internal error",
		Status: http.StatusInternalServerError,
		Detail: "The error has been logged.",
	}
)

// problemFor maps an error to the problem sent to the client. The second
// result is false for unexpected errors, which should be logged in full.
func problemFor(err error, method string) (*problem, bool) {
	var p *problem
	if errors.As(err, &p) {
		return p, true
	}

	var tooLarge *http.MaxBytesError
	if errors.As(err, &tooLarge) {
		return &problem{
			Type:   "/problems/body-too-large",
			Title:  "Request body too large",
			Status: http.StatusRequestEntityTooLarge,
			Detail: fmt.Sprintf("The request body may be at most %d bytes.", tooLarge.Limit),
		}, true
	}

	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) {
		return internalError, false
	}

	p = &problem{Detail: pgErr.Message, SQLState: pgErr.Code}
	if pgErr.Detail != "" {
		p.Detail += ": " + pgErr.Detail
	}
	switch pgErr.Code {
	case "28000": // invalid_authorization_specification: no or expired session
		p.Type, p.Title, p.Status = "/problems/unauthenticated", "Not authenticated", http.StatusUnauthorized
	case "42501": // insufficient_privilege
		p.Type, p.Title, p.Status = "/problems/forbidden", "Not allowed", http.StatusForbidden
	case "P0002": // no_data_found
		p.Type, p.Title, p.Status = "/problems/not-found", "Not found", http.StatusNotFound
	case "22023", "22P02", "22003", "22008", "23502":
		p.Type, p.Title, p.Status = "/problems/invalid-input", "Invalid input", http.StatusBadRequest
	case "23514": // check_violation, also raised by our triggers
		p.Type, p.Title, p.Status = "/problems/rule-violation", "Rule violation", http.StatusUnprocessableEntity
	case "23505":
		p.Type, p.Title, p.Status = "/problems/unique-violation", "Duplicate", http.StatusConflict
	case "23503", "23001": // foreign_key_violation; restrict_violation (ON DELETE RESTRICT)
		if method == http.MethodDelete {
			p.Type, p.Title, p.Status = "/problems/in-use", "Still in use", http.StatusConflict
		} else {
			p.Type, p.Title, p.Status = "/problems/invalid-reference", "Invalid reference", http.StatusUnprocessableEntity
		}
	case "57014": // query_canceled, e.g. statement_timeout
		p.Type, p.Title, p.Status = "/problems/timeout", "Timeout", http.StatusServiceUnavailable
	default:
		return internalError, false
	}
	return p, true
}

func writeProblem(w http.ResponseWriter, p *problem) {
	if p.Status == http.StatusUnauthorized {
		// There is no registered scheme for cookie sessions; this names ours.
		w.Header().Set("WWW-Authenticate", `Cookie realm="WtF", cookie-name="`+sessionCookie+`"`)
	}
	w.Header().Set("Content-Type", "application/problem+json")
	w.WriteHeader(p.Status)
	_ = json.NewEncoder(w).Encode(p)
}
