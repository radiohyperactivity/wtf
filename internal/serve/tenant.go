package serve

import (
	"context"
	"net"
	"net/http"
	"regexp"
	"strings"
)

// A request's tenant is picked by the first label of its hostname: "bob" for
// bob.wtf.example (TENANTS.md). A hostname that picks no tenant gets 404,
// except for /api/health.

// hostPattern is what a tenant's host can be: a DNS label that starts with
// a letter. An IP address never matches.
var hostPattern = regexp.MustCompile(`^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$`)

type tenantKey struct{}

// hostLabel returns the first label of the request's hostname, lower-cased
// and without the port: "bob" for "Bob.wtf.example:8080".
func hostLabel(r *http.Request) string {
	host := r.Host
	if h, _, err := net.SplitHostPort(host); err == nil {
		host = h
	}
	label, _, _ := strings.Cut(strings.ToLower(host), ".")
	return label
}

// tenantOf returns the host of the tenant a request was let in for.
func tenantOf(ctx context.Context) string {
	host, _ := ctx.Value(tenantKey{}).(string)
	return host
}

// knownTenant tells whether a tenant has host label host.
func (s *server) knownTenant(ctx context.Context, host string) (bool, error) {
	if !hostPattern.MatchString(host) {
		return false, nil
	}
	if s.tenantKnown != nil {
		return s.tenantKnown(ctx, host)
	}
	var known bool
	err := s.pool.QueryRow(ctx, "SELECT tenant_known($1)", host).Scan(&known)
	return known, err
}

// withTenant lets a request through to next with its tenant in the
// context, or answers 404 when its hostname picks none.
func (s *server) withTenant(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == healthPath {
			next.ServeHTTP(w, r)
			return
		}
		host := hostLabel(r)
		known, err := s.knownTenant(r.Context(), host)
		if err != nil {
			s.log.Error("request failed", "method", r.Method, "path", r.URL.Path, "error", err)
			writeProblem(w, internalError)
			return
		}
		if !known {
			s.log.Debug("no tenant for this hostname", "host", r.Host)
			writeProblem(w, notFound)
			return
		}
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), tenantKey{}, host)))
	})
}
