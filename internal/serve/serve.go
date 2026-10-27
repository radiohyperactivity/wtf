// Package serve implements "wtfd serve": the REST API, a thin layer that maps
// each request to one database function and passes its jsonb result through.
// The design is described in WTFD.md.
package serve

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/radiohyperactivity/wtf/internal/files"
	"github.com/radiohyperactivity/wtf/internal/schema"
)

// Options configures Run.
type Options struct {
	ConnString         string // connection as the API role
	MaxConnections     int
	Listen             string
	MaxRequestBodySize int
	Files              *files.Store // attachment contents
	MaxAttachmentSize  int
	Scripts            fs.FS  // the embedded schema scripts, to check the database against
	WebRoot            string // the web app's files; "" serves no web app
	Logger             *slog.Logger
}

type server struct {
	pool          *pgxpool.Pool
	log           *slog.Logger
	maxBody       int64
	files         *files.Store
	maxAttachment int64
	webRoot       string
}

// Run serves the API until ctx is cancelled, then shuts down gracefully.
func Run(ctx context.Context, o Options) error {
	expected, err := schema.Expected(o.Scripts)
	if err != nil {
		return fmt.Errorf("embedded scripts: %w", err)
	}

	poolConfig, err := pgxpool.ParseConfig(o.ConnString)
	if err != nil {
		return err
	}
	poolConfig.MaxConns = int32(o.MaxConnections)
	poolConfig.ConnConfig.RuntimeParams["search_path"] = "public"
	pool, err := pgxpool.NewWithConfig(ctx, poolConfig)
	if err != nil {
		return err
	}
	defer pool.Close()

	if err := checkSchema(ctx, pool, expected); err != nil {
		return err
	}

	httpServer := &http.Server{
		Handler:           NewHandler(pool, o.Logger, int64(o.MaxRequestBodySize), o.Files, int64(o.MaxAttachmentSize), o.WebRoot),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      60 * time.Second,
		IdleTimeout:       120 * time.Second,
		ErrorLog:          slog.NewLogLogger(o.Logger.Handler(), slog.LevelWarn),
	}

	listener, err := net.Listen("tcp", o.Listen)
	if err != nil {
		return err
	}
	o.Logger.Info("listening", "address", listener.Addr().String(), "schema_version", expected.Version)

	served := make(chan error, 1)
	go func() { served <- httpServer.Serve(listener) }()

	select {
	case err := <-served:
		return err
	case <-ctx.Done():
		o.Logger.Info("shutting down")
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		return httpServer.Shutdown(shutdownCtx)
	}
}

// NewHandler returns the HTTP handler: the API, and the web app from webRoot
// if it isn't "". Run uses it; integration tests use it directly, without a
// listening socket.
func NewHandler(pool *pgxpool.Pool, log *slog.Logger, maxRequestBodySize int64,
	store *files.Store, maxAttachmentSize int64, webRoot string) http.Handler {
	s := &server{pool: pool, log: log, maxBody: maxRequestBodySize, files: store, maxAttachment: maxAttachmentSize, webRoot: webRoot}
	return s.handler()
}

// CheckSchema refuses a database whose schema differs from the scripts in fsys.
func CheckSchema(ctx context.Context, pool *pgxpool.Pool, fsys fs.FS) error {
	expected, err := schema.Expected(fsys)
	if err != nil {
		return err
	}
	return checkSchema(ctx, pool, expected)
}

// checkSchema refuses to serve a database whose schema differs from the
// scripts embedded in this binary.
func checkSchema(ctx context.Context, pool *pgxpool.Pool, expected schema.Fingerprint) error {
	var text string
	if err := pool.QueryRow(ctx, "SELECT schema_version()::text").Scan(&text); err != nil {
		return fmt.Errorf("reading the schema version failed (%w); run 'wtfd schema'", err)
	}
	var actual schema.Fingerprint
	if err := json.Unmarshal([]byte(text), &actual); err != nil {
		return err
	}
	switch {
	case actual.Version != expected.Version:
		return fmt.Errorf("the database schema is at version %d, but this wtfd expects version %d; run 'wtfd schema'",
			actual.Version, expected.Version)
	case !actual.Equal(expected):
		return errors.New("the database's API functions differ from this wtfd's (repeatable scripts changed); run 'wtfd schema'")
	}
	return nil
}

// handler returns the complete HTTP handler: the API under /api/v1 (plus
// /api/health), problem responses for unknown routes, methods and API
// versions, the web app outside /api, request size limits and access
// logging.
func (s *server) handler() http.Handler {
	mux := http.NewServeMux()
	for _, rt := range s.routes() {
		mux.Handle(fullPattern(rt.pattern), s.wrap(rt.handler, s.maxBody, anonymousRoutes[rt.pattern]))
	}
	for _, rt := range s.uploadRoutes() {
		mux.Handle(fullPattern(rt.pattern), s.wrap(rt.handler, s.maxAttachment+multipartOverhead, false))
	}
	web := http.Handler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { writeProblem(w, notFound) }))
	if s.webRoot != "" {
		web = webApp(s.webRoot)
	}

	api := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if _, pattern := mux.Handler(r); pattern != "" {
			mux.ServeHTTP(w, r)
			return
		}
		// The mux would answer with plain text; answer with a problem instead.
		if allowed := allowedMethods(mux, r); len(allowed) > 0 {
			list := strings.Join(allowed, ", ")
			w.Header().Set("Allow", list)
			writeProblem(w, &problem{
				Type:   "/problems/method-not-allowed",
				Title:  "Method not allowed",
				Status: http.StatusMethodNotAllowed,
				Detail: fmt.Sprintf("%s is not supported here; allowed: %s", r.Method, list),
			})
			return
		}
		writeProblem(w, notFound)
	})

	return s.logRequests(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path
		switch {
		case path == healthPath || path == apiPrefix || strings.HasPrefix(path, apiPrefix+"/"):
			apiHeaders(w)
			if crossSite(r) {
				writeProblem(w, crossSiteProblem)
				return
			}
			api.ServeHTTP(w, r)
		case versionPath.MatchString(path):
			unsupportedVersion(w, r)
		case path == "/api" || strings.HasPrefix(path, "/api/"):
			writeProblem(w, notFound)
		default:
			web.ServeHTTP(w, r)
		}
	}))
}

// wrap turns a handlerFunc into an http.Handler: it requires the session
// cookie (unless anonymous) and passes it on in the context, limits the
// request body and converts returned errors into problem responses.
func (s *server) wrap(h handlerFunc, maxBody int64, anonymous bool) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !anonymous {
			token, ok := sessionToken(r)
			if !ok {
				writeProblem(w, unauthenticated)
				return
			}
			// The session lasts 30 days from its last use, and so does the
			// cookie: each answer renews it.
			setSessionCookie(w, r, token, sessionMaxAge)
			r = r.WithContext(context.WithValue(r.Context(), sessionKey{}, session{token: token}))
		}
		r.Body = http.MaxBytesReader(w, r.Body, maxBody)
		err := h(w, r)
		if err == nil {
			return
		}
		p, expected := problemFor(err, r.Method)
		if p.Status == http.StatusUnauthorized && !anonymous {
			setSessionCookie(w, r, "", 0) // the session has ended: drop the cookie
		}
		if !expected && !errors.Is(err, context.Canceled) {
			s.log.Error("request failed", "method", r.Method, "path", r.URL.Path, "error", err)
		}
		writeProblem(w, p)
	})
}

var methods = []string{http.MethodGet, http.MethodPost, http.MethodPut, http.MethodPatch, http.MethodDelete}

func allowedMethods(mux *http.ServeMux, r *http.Request) []string {
	var allowed []string
	for _, m := range methods {
		probe := r.Clone(r.Context())
		probe.Method = m
		if _, pattern := mux.Handler(probe); pattern != "" {
			allowed = append(allowed, m)
		}
	}
	return allowed
}

// statusRecorder captures the status code for the access log.
type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(status int) {
	r.status = status
	r.ResponseWriter.WriteHeader(status)
}

// Unwrap lets http.ResponseController reach the connection, for the longer
// deadlines of uploads and downloads.
func (r *statusRecorder) Unwrap() http.ResponseWriter {
	return r.ResponseWriter
}

func (s *server) logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		s.log.Info("request",
			"method", r.Method,
			"path", r.URL.Path,
			"status", rec.status,
			"duration", time.Since(start).Round(time.Microsecond))
	})
}
