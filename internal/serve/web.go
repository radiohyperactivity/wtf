package serve

import (
	"errors"
	"io/fs"
	"net/http"
	"os"
	urlpath "path"
	"strings"
)

// webCSP is the Content Security Policy of the web app's pages: everything
// from this server only, WebAssembly allowed (Flutter needs it), and no
// framing by other sites (clickjacking). Flutter's web build must then
// bundle its engine and fonts instead of loading them from Google's CDN:
// build it with "flutter build web --no-web-resources-cdn". See WTFD.md.
const webCSP = "default-src 'self'; " +
	"script-src 'self' 'wasm-unsafe-eval'; " +
	"style-src 'self' 'unsafe-inline'; " +
	"img-src 'self' data: blob:; " +
	"font-src 'self' data:; " +
	"connect-src 'self'; " +
	"worker-src 'self' blob:; " +
	"object-src 'none'; " +
	"base-uri 'self'; " +
	"form-action 'self'; " +
	"frame-ancestors 'none'"

// webApp serves the web app (a Flutter web build) from dir:
//
//   - files as they are, revalidated on every use (Cache-Control: no-cache),
//     so a new build is picked up at once; unchanged files cost a 304;
//   - for any other path without a file extension, index.html, so the app's
//     own URLs (/locations/1A7K) work when opened or reloaded;
//   - no hidden files (names starting with ".") and no directory listings.
func webApp(dir string) http.Handler {
	root := os.DirFS(dir)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			writeProblem(w, &problem{
				Type:   "/problems/method-not-allowed",
				Title:  "Method not allowed",
				Status: http.StatusMethodNotAllowed,
				Detail: r.Method + " is not supported here; allowed: GET, HEAD",
			})
			return
		}
		name := strings.TrimPrefix(urlpath.Clean("/"+r.URL.Path), "/")
		for _, segment := range strings.Split(name, "/") {
			if strings.HasPrefix(segment, ".") {
				writeProblem(w, notFound)
				return
			}
		}
		if name == "" {
			name = "index.html"
		}
		f, err := root.Open(name)
		if err == nil {
			if fi, statErr := f.Stat(); statErr == nil && fi.IsDir() {
				f.Close()
				f, err = root.Open(urlpath.Join(name, "index.html"))
			}
		}
		if errors.Is(err, fs.ErrNotExist) && !strings.Contains(urlpath.Base(name), ".") {
			f, err = root.Open("index.html") // one of the app's own URLs
		}
		if err != nil {
			writeProblem(w, notFound)
			return
		}
		defer f.Close()
		fi, err := f.Stat()
		content, ok := f.(interface {
			Read([]byte) (int, error)
			Seek(int64, int) (int64, error)
		})
		if err != nil || fi.IsDir() || !ok {
			writeProblem(w, notFound)
			return
		}
		h := w.Header()
		h.Set("Cache-Control", "no-cache")
		h.Set("Content-Security-Policy", webCSP)
		h.Set("X-Frame-Options", "DENY") // frame-ancestors, for older browsers
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Referrer-Policy", "same-origin")
		http.ServeContent(w, r, fi.Name(), fi.ModTime(), content)
	})
}
