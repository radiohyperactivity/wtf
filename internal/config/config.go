// Package config holds wtfd's settings. Every setting is a command-line flag
// that can also be given as an environment variable; the flag wins.
// Passwords are only accepted from environment variables, because
// command-line arguments are visible to other users on the machine.
package config

import (
	"errors"
	"flag"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// Environment variables holding the database passwords.
const (
	DBAPasswordEnv = "WTFD_DBA_DATABASE_PASSWORD"
	APIPasswordEnv = "WTFD_API_DATABASE_PASSWORD"
)

var sslModes = []string{"disable", "allow", "prefer", "require", "verify-ca", "verify-full"}

// env reads flag defaults from environment variables and collects invalid
// values, which Validate reports.
type env struct {
	errs []error
}

func (e *env) string(name, fallback string) string {
	if v, ok := os.LookupEnv(name); ok {
		return v
	}
	return fallback
}

func (e *env) int(name string, fallback int) int {
	v, ok := os.LookupEnv(name)
	if !ok {
		return fallback
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		e.errs = append(e.errs, fmt.Errorf("%s: %q is not a number", name, v))
		return fallback
	}
	return n
}

// Database holds the connection settings shared by all actions.
type Database struct {
	Host    string
	Port    int
	Name    string
	SSLMode string
	DBAUser string
	APIUser string

	env env
}

// RegisterDatabase adds the database flags to fs.
func RegisterDatabase(fs *flag.FlagSet) *Database {
	d := &Database{}
	fs.StringVar(&d.Host, "database-host", d.env.string("WTFD_DATABASE_HOST", "localhost"),
		"database host name, IP address or Unix socket directory (env WTFD_DATABASE_HOST)")
	fs.IntVar(&d.Port, "database-port", d.env.int("WTFD_DATABASE_PORT", 5432),
		"database port (env WTFD_DATABASE_PORT)")
	fs.StringVar(&d.Name, "database-name", d.env.string("WTFD_DATABASE_NAME", "wtf"),
		"database name (env WTFD_DATABASE_NAME)")
	fs.StringVar(&d.SSLMode, "database-sslmode", d.env.string("WTFD_DATABASE_SSLMODE", "prefer"),
		"TLS mode: "+strings.Join(sslModes, ", ")+" (env WTFD_DATABASE_SSLMODE)")
	fs.StringVar(&d.DBAUser, "dba-database-user", d.env.string("WTFD_DBA_DATABASE_USER", "wtf_dba"),
		"role that owns the schema; password in env "+DBAPasswordEnv+" (env WTFD_DBA_DATABASE_USER)")
	fs.StringVar(&d.APIUser, "api-database-user", d.env.string("WTFD_API_DATABASE_USER", "wtf_api"),
		"role the REST API connects as; password in env "+APIPasswordEnv+" (env WTFD_API_DATABASE_USER)")
	return d
}

// Validate reports invalid settings, including invalid environment values.
func (d *Database) Validate() error {
	if err := errors.Join(d.env.errs...); err != nil {
		return err
	}
	switch {
	case d.Host == "":
		return errors.New("--database-host must not be empty")
	case d.Port < 1 || d.Port > 65535:
		return fmt.Errorf("--database-port %d is out of range", d.Port)
	case d.Name == "":
		return errors.New("--database-name must not be empty")
	case !slices.Contains(sslModes, d.SSLMode):
		return fmt.Errorf("--database-sslmode %q is not one of %s", d.SSLMode, strings.Join(sslModes, ", "))
	case d.DBAUser == "":
		return errors.New("--dba-database-user must not be empty")
	case d.APIUser == "":
		return errors.New("--api-database-user must not be empty")
	case d.DBAUser == d.APIUser:
		return errors.New("--dba-database-user and --api-database-user must be different roles")
	}
	return nil
}

// ConnString returns a keyword/value connection string for user. An empty
// password sends none, which works with peer or trust authentication.
func (d *Database) ConnString(user, password, applicationName string) string {
	params := []string{
		"host=" + quote(d.Host),
		"port=" + strconv.Itoa(d.Port),
		"dbname=" + quote(d.Name),
		"sslmode=" + quote(d.SSLMode),
		"user=" + quote(user),
		"application_name=" + quote(applicationName),
	}
	if password != "" {
		params = append(params, "password="+quote(password))
	}
	return strings.Join(params, " ")
}

// ConnConfig returns the connection configuration for user.
func (d *Database) ConnConfig(user, password, applicationName string) (*pgx.ConnConfig, error) {
	return pgx.ParseConfig(d.ConnString(user, password, applicationName))
}

// quote quotes a value for a keyword/value connection string.
func quote(s string) string {
	return "'" + strings.NewReplacer(`\`, `\\`, `'`, `\'`).Replace(s) + "'"
}

func (e *env) duration(name string, fallback time.Duration) time.Duration {
	v, ok := os.LookupEnv(name)
	if !ok {
		return fallback
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		e.errs = append(e.errs, fmt.Errorf("%s: %q is not a duration (e.g. 90m, 2h)", name, v))
		return fallback
	}
	return d
}

// Files holds the location of the attachment contents, used by serve and gc.
type Files struct {
	Directory string

	env env
}

// RegisterFiles adds the files directory flag to fs.
func RegisterFiles(fs *flag.FlagSet) *Files {
	f := &Files{}
	fs.StringVar(&f.Directory, "files-directory", f.env.string("WTFD_FILES_DIRECTORY", ""),
		"directory for attachment contents; required (env WTFD_FILES_DIRECTORY)")
	return f
}

// Validate reports a missing files directory.
func (f *Files) Validate() error {
	if f.Directory == "" {
		return errors.New("--files-directory is required")
	}
	return nil
}

// GC holds the settings of the gc action.
type GC struct {
	MinAge time.Duration

	env env
}

// RegisterGC adds the gc flags to fs.
func RegisterGC(fs *flag.FlagSet) *GC {
	g := &GC{}
	fs.DurationVar(&g.MinAge, "min-age", g.env.duration("WTFD_GC_MIN_AGE", time.Hour),
		"never remove files younger than this, so uploads in progress are safe (env WTFD_GC_MIN_AGE)")
	return g
}

// Validate reports invalid settings, including invalid environment values.
func (g *GC) Validate() error {
	if err := errors.Join(g.env.errs...); err != nil {
		return err
	}
	if g.MinAge < 0 {
		return errors.New("--min-age must not be negative")
	}
	return nil
}

// Serve holds the settings of the serve action.
type Serve struct {
	Listen             string
	MaxConnections     int
	MaxRequestBodySize int
	MaxAttachmentSize  int
	WebRoot            string

	env env
}

// RegisterServe adds the serve flags to fs.
func RegisterServe(fs *flag.FlagSet) *Serve {
	s := &Serve{}
	fs.StringVar(&s.Listen, "listen", s.env.string("WTFD_LISTEN", "127.0.0.1:8080"),
		"address and port to listen on (env WTFD_LISTEN)")
	fs.StringVar(&s.WebRoot, "web-root", s.env.string("WTFD_WEB_ROOT", ""),
		"directory of the web app (a Flutter web build), served outside /api; none if empty (env WTFD_WEB_ROOT)")
	fs.IntVar(&s.MaxConnections, "api-database-max-connections", s.env.int("WTFD_API_DATABASE_MAX_CONNECTIONS", 10),
		"size of the database connection pool (env WTFD_API_DATABASE_MAX_CONNECTIONS)")
	fs.IntVar(&s.MaxRequestBodySize, "max-request-body-size", s.env.int("WTFD_MAX_REQUEST_BODY_SIZE", 1<<20),
		"largest accepted request body in bytes (env WTFD_MAX_REQUEST_BODY_SIZE)")
	fs.IntVar(&s.MaxAttachmentSize, "max-attachment-size", s.env.int("WTFD_MAX_ATTACHMENT_SIZE", 100<<20),
		"largest accepted attachment in bytes (env WTFD_MAX_ATTACHMENT_SIZE)")
	return s
}

// Validate reports invalid settings, including invalid environment values.
func (s *Serve) Validate() error {
	if err := errors.Join(s.env.errs...); err != nil {
		return err
	}
	if _, _, err := net.SplitHostPort(s.Listen); err != nil {
		return fmt.Errorf("--listen %q: %w", s.Listen, err)
	}
	switch {
	case s.MaxConnections < 1:
		return errors.New("--api-database-max-connections must be at least 1")
	case s.MaxRequestBodySize < 1:
		return errors.New("--max-request-body-size must be at least 1")
	case s.MaxAttachmentSize < 1:
		return errors.New("--max-attachment-size must be at least 1")
	}
	if s.WebRoot != "" {
		if _, err := os.Stat(filepath.Join(s.WebRoot, "index.html")); err != nil {
			return fmt.Errorf("--web-root %q: no index.html there: %w", s.WebRoot, err)
		}
	}
	return nil
}
