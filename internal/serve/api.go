package serve

import (
	"fmt"
	"net/http"
	"net/url"
	"regexp"
	"strings"
)

// The API is served under /api/v1/. A breaking change would add /api/v2/
// next to it; within a version, changes only add (routes, optional fields,
// fields in answers), and every addition increases the revision. See
// WTFD.md, "Versions".
const (
	apiPrefix   = "/api/v1"
	apiVersion  = 1
	apiRevision = 4 // increase with every addition to /api/v1
	healthPath  = "/api/health"
)

// apiSunset, when set (an HTTP date), announces that this API version will
// be retired: its answers then carry Deprecation and Sunset headers.
var apiSunset = ""

// versionPath matches /api/vN and /api/vN/…, for versions this server
// doesn't serve.
var versionPath = regexp.MustCompile(`^/api/v[0-9]+(/|$)`)

// fullPattern turns a route pattern ("GET /items") into the pattern it is
// served at ("GET /api/v1/items"). Health is outside the versions.
func fullPattern(pattern string) string {
	method, path, _ := strings.Cut(pattern, " ")
	if path == "/health" {
		return method + " " + healthPath
	}
	return method + " " + apiPrefix + path
}

// apiHeaders sets the headers every answer of /api/v1 carries.
func apiHeaders(w http.ResponseWriter) {
	w.Header().Set("API-Revision", fmt.Sprint(apiRevision))
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if apiSunset != "" {
		w.Header().Set("Deprecation", "true")
		w.Header().Set("Sunset", apiSunset)
	}
}

// unsupportedVersion answers a request for an API version this server
// doesn't serve, naming the one it does.
func unsupportedVersion(w http.ResponseWriter, r *http.Request) {
	writeProblem(w, &problem{
		Type:      "/problems/unsupported-api-version",
		Title:     "Unsupported API version",
		Status:    http.StatusNotFound,
		Detail:    fmt.Sprintf("This server serves API version %d at %s/, not %s", apiVersion, apiPrefix, r.URL.Path),
		Supported: []int{apiVersion},
	})
}

// crossSite reports a request that changes something but was sent by a page
// of another site. Browsers name the sending page's origin in the Origin
// header; other clients (the CLI, the apps) send none and pass. Together with
// the SameSite=Strict session cookie this prevents cross-site request
// forgery.
func crossSite(r *http.Request) bool {
	switch r.Method {
	case http.MethodGet, http.MethodHead, http.MethodOptions:
		return false
	}
	origin := r.Header.Get("Origin")
	if origin == "" {
		return false
	}
	u, err := url.Parse(origin)
	return err != nil || !strings.EqualFold(u.Host, r.Host)
}

var crossSiteProblem = &problem{
	Type:   "/problems/cross-site",
	Title:  "Cross-site request",
	Status: http.StatusForbidden,
	Detail: "Requests that change something must come from this site.",
}
