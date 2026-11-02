package cli

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
)

// run runs wtf against a fake server.
func runAgainst(t *testing.T, handler http.HandlerFunc, args ...string) (int, string) {
	t.Helper()
	server := httptest.NewServer(handler)
	defer server.Close()
	dir := t.TempDir()
	vars := map[string]string{
		"WTF_SERVER":    server.URL,
		"WTF_TOKEN":     "token",
		"WTF_CONFIG":    filepath.Join(dir, "config.json"),
		"WTF_CACHE_DIR": dir,
	}
	var stdout, stderr bytes.Buffer
	code := Run(context.Background(), args, strings.NewReader(""), &stdout, &stderr, func(k string) string { return vars[k] })
	return code, stderr.String()
}

// TestRecursiveDeleteOnOldServer: a server without recursive deletes doesn't
// know the preview route. The client must stop there and never send the
// DELETE, which such a server would take for a plain delete.
func TestRecursiveDeleteOnOldServer(t *testing.T) {
	var deletes int
	code, stderr := runAgainst(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("API-Revision", "1")
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/api/v1/classes":
			w.Header().Set("Content-Type", "application/json")
			w.Write([]byte(`{"version": 1, "unchanged": false, "tree": [{"id": "11111111-1111-1111-1111-111111111111", "name": "Leaf", "parent": null, "children": []}]}`))
		case r.Method == http.MethodDelete:
			deletes++
			w.WriteHeader(http.StatusNoContent)
		default: // what wtfd answers for an unknown route
			w.Header().Set("Content-Type", "application/problem+json")
			w.WriteHeader(http.StatusNotFound)
			w.Write([]byte(`{"type": "/problems/not-found", "title": "Not found", "status": 404}`))
		}
	}, "class", "delete", "Leaf", "--recursive", "--yes")
	if code != 1 || !strings.Contains(stderr, "doesn't support recursive deletes") {
		t.Errorf("exit %d, stderr: %s", code, stderr)
	}
	if deletes != 0 {
		t.Errorf("%d DELETE requests sent to an old server", deletes)
	}
}

// The client sends the session as a cookie and tells which side is out of
// date: a server without /api/v1 at all, one serving only another API
// version, or one with an older revision of version 1.
func TestServerVersions(t *testing.T) {
	var cookie string
	code, stderr := runAgainst(t, func(w http.ResponseWriter, r *http.Request) {
		if c, err := r.Cookie("wtf_session"); err == nil {
			cookie = c.Value
		}
		w.Header().Set("Content-Type", "application/problem+json")
		w.WriteHeader(http.StatusNotFound) // an old wtfd: no /api/v1, no API-Revision
		w.Write([]byte(`{"type": "/problems/not-found", "title": "Not found", "status": 404}`))
	}, "whoami")
	if code != 1 || !strings.Contains(stderr, "doesn't serve /api/v1") || !strings.Contains(stderr, "update the server") {
		t.Errorf("old server: exit %d, %s", code, stderr)
	}
	if cookie != "token" {
		t.Errorf("session cookie sent: %q", cookie)
	}

	code, stderr = runAgainst(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/problem+json")
		w.WriteHeader(http.StatusNotFound)
		w.Write([]byte(`{"type": "/problems/unsupported-api-version", "title": "Unsupported API version", "status": 404, "supported": [2, 3]}`))
	}, "whoami")
	if code != 1 || !strings.Contains(stderr, "update this client") {
		t.Errorf("newer server: exit %d, %s", code, stderr)
	}

	for _, c := range []struct {
		server, built int
		warn          bool
	}{{0, 3, false}, {2, 3, true}, {3, 3, false}, {4, 3, false}} {
		if got := revisionWarning(c.server, c.built) != ""; got != c.warn {
			t.Errorf("server %d, client %d: warning %v", c.server, c.built, got)
		}
	}
}
