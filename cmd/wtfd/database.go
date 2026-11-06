package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/signal"
	"strings"
	"syscall"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/radiohyperactivity/wtf/db"
	"github.com/radiohyperactivity/wtf/internal/admin"
	"github.com/radiohyperactivity/wtf/internal/config"
	"github.com/radiohyperactivity/wtf/internal/schema"
)

const databaseUsage = `Usage:
  wtfd database create [flags]

create makes WtF's database on a PostgreSQL server: the database, the role
that owns it (DBA) and the role the REST API connects as (API), with their
privileges and settings, and then its schema, as "wtfd schema" does. It
connects as an administrator: a superuser, or a role with CREATEROLE and
CREATEDB. On a terminal it asks for what the flags don't give. It reads
none of wtfd's environment variables, which describe a database that
exists. Run "wtfd database create -h" for the flags.
`

func runDatabase(args []string, stdin *os.File, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprint(stderr, databaseUsage)
		return exitUsage
	}
	switch args[0] {
	case "create":
	case "help", "-h", "-help", "--help":
		fmt.Fprint(stderr, databaseUsage)
		return exitOK
	default:
		fmt.Fprintf(stderr, "wtfd database: unknown command %q\n\n%s", args[0], databaseUsage)
		return exitUsage
	}

	const name = "wtfd database create"
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	fs.SetOutput(stderr)
	c := registerDatabaseCreation(fs, name)
	printSQL := fs.Bool("print-sql", false, "print what it does as a psql script for a superuser, and do nothing")
	if code, ok := parse(fs, args[1:], stderr); !ok {
		return code
	}
	c.given(fs)
	if *printSQL {
		fmt.Fprint(stdout, c.nd().Script(c.adminDatabase))
		return exitOK
	}

	code := c.run(openQuestions(stdin, stdout), stdout, stderr)
	if c.created && len(c.generated) > 0 {
		fmt.Fprintln(stdout, "\nThe generated passwords, shown only this once, as lines for PostgreSQL's password file (pgpass.conf):")
		for _, line := range c.pgpassLines(c.generated...) {
			fmt.Fprintln(stdout, "  "+line)
		}
		fmt.Fprintln(stdout, "wtfd serve needs only the API role's; the DBA's is for wtfd schema, gc and account.")
	}
	return code
}

// databaseCreation is what "wtfd database create" asks for and makes, as
// does "wtfd install" when there is no database yet.
type databaseCreation struct {
	action        string           // for messages: "wtfd database create"
	database      *config.Database // the server; the new database's and roles' names
	adminUser     string
	adminDatabase string
	locale        string
	limit         int
	firstAccount  string
	set           map[string]bool // the flags given, which aren't asked for

	dbaPassword, apiPassword string
	created                  bool     // the roles and the database were made
	generated                []string // the roles whose password was generated
}

func registerDatabaseCreation(fs *flag.FlagSet, action string) *databaseCreation {
	c := &databaseCreation{action: action, database: config.RegisterNewDatabase(fs)}
	fs.StringVar(&c.adminUser, "admin-user", "postgres", "the administrator's role; password from PostgreSQL's password file, or asked for")
	fs.StringVar(&c.adminDatabase, "admin-database", "postgres", "the database the administrator connects to")
	fs.StringVar(&c.locale, "icu-locale", "und", `collation of the new database, an ICU locale ("und" sorts language-neutral; "nb", "de", …)`)
	fs.IntVar(&c.limit, "api-connection-limit", 50, "most connections the API role may have at once")
	fs.StringVar(&c.firstAccount, "first-account", "", "email of an admin account to create when done (empty: none)")
	return c
}

// given records which flags were given, after parsing.
func (c *databaseCreation) given(fs *flag.FlagSet) {
	c.set = map[string]bool{}
	fs.Visit(func(f *flag.Flag) { c.set[f.Name] = true })
}

func (c *databaseCreation) nd() admin.NewDatabase {
	return admin.NewDatabase{
		Name:               c.database.Name,
		DBAUser:            c.database.DBAUser,
		DBAPassword:        c.dbaPassword,
		APIUser:            c.database.APIUser,
		APIPassword:        c.apiPassword,
		ICULocale:          c.locale,
		APIConnectionLimit: c.limit,
	}
}

// pgpassLines are the password file's lines for roles, both when none is
// named.
func (c *databaseCreation) pgpassLines(roles ...string) []string {
	d := c.database
	var lines []string
	for _, r := range []struct{ role, password string }{{d.DBAUser, c.dbaPassword}, {d.APIUser, c.apiPassword}} {
		for _, want := range roles {
			if want == r.role {
				lines = append(lines, pgpassLine(d.Host, d.Port, d.Name, r.role, r.password))
			}
		}
		if len(roles) == 0 {
			lines = append(lines, pgpassLine(d.Host, d.Port, d.Name, r.role, r.password))
		}
	}
	return lines
}

// run asks for what the flags don't give (q nil: nothing), and makes the
// database, its schema and the first account. It reports on stdout and
// stderr, and returns the exit code.
func (c *databaseCreation) run(q *questions, stdout, stderr io.Writer) int {
	database := c.database
	// Ctrl-C ends the program as usual while it asks; from creating on, it
	// cancels, so that what was made is removed again.
	ctx := context.Background()
	fail := func(err error) int {
		if errors.Is(err, errCancelled) {
			fmt.Fprintln(stderr, "Cancelled; nothing was changed.")
			return exitFailure
		}
		fmt.Fprintf(stderr, "%s: %v\n", c.action, err)
		return exitFailure
	}

	// The server, and the administrator.
	if q != nil {
		fmt.Fprintln(stdout, "The PostgreSQL server, and an administrator on it:")
		var err error
		if !c.set["database-host"] {
			database.Host, err = q.text("  Host", database.Host)
		}
		if err == nil && !c.set["database-port"] {
			database.Port, err = q.number("  Port", database.Port)
		}
		if err == nil && !c.set["admin-user"] {
			c.adminUser, err = q.text("  Administrator", c.adminUser)
		}
		if err != nil {
			return fail(err)
		}
	}
	if err := database.Validate(); err != nil {
		fmt.Fprintf(stderr, "%s: %v\n", c.action, err)
		return exitUsage
	}
	adminPassword := "" // from the password file, unless it has none
	conn, err := connectTo(ctx, database, c.adminUser, adminPassword, c.adminDatabase, c.action)
	if err != nil && q != nil && needsPassword(err) {
		adminPassword, err = q.password(fmt.Sprintf("  Password for %s", c.adminUser))
		if err != nil {
			return fail(err)
		}
		conn, err = connectTo(ctx, database, c.adminUser, adminPassword, c.adminDatabase, c.action)
	}
	if err != nil {
		return fail(fmt.Errorf("connecting as %s: %w", c.adminUser, err))
	}
	defer conn.Close(context.WithoutCancel(ctx))
	server, err := admin.CheckServer(ctx, conn)
	if err != nil {
		return fail(err)
	}

	// The new database.
	if q != nil {
		fmt.Fprintf(stdout, "\nPostgreSQL %s. The new database:\n", server.Version)
		ask := []struct {
			flag, question string
			value          *string
		}{
			{"database-name", "  Database", &database.Name},
			{"dba-database-user", "  Its owner (DBA role)", &database.DBAUser},
			{"api-database-user", "  The REST API's role", &database.APIUser},
			{"icu-locale", `  Collation, an ICU locale ("und": language-neutral)`, &c.locale},
		}
		for _, a := range ask {
			if !c.set[a.flag] {
				if *a.value, err = q.text(a.question, *a.value); err != nil {
					return fail(err)
				}
			}
		}
	}
	// A role's password is typed in, or else generated; which is told
	// before anything is made.
	var sources []string
	for _, r := range []struct {
		role     string
		password *string
	}{{database.DBAUser, &c.dbaPassword}, {database.APIUser, &c.apiPassword}} {
		source := "typed in"
		if q != nil {
			if *r.password, err = q.newPassword(r.role); err != nil {
				return fail(err)
			}
		}
		if *r.password == "" {
			if *r.password, err = admin.GeneratePassword(); err != nil {
				return fail(err)
			}
			source = "generated"
			c.generated = append(c.generated, r.role)
		}
		sources = append(sources, fmt.Sprintf("  The password for %s: %s.", r.role, source))
	}
	if q != nil && !c.set["first-account"] {
		fmt.Fprintln(stdout, "\nThe first account in WtF, an admin:")
		if c.firstAccount, err = q.text("  Email (empty: none for now)", ""); err != nil {
			return fail(err)
		}
	}
	nd := c.nd()
	if err := nd.Check(ctx, conn); err != nil {
		return fail(err)
	}
	fmt.Fprintf(stdout, "\nDatabase %s on %s:%d, owned by %s, with %s for the REST API.\n",
		nd.Name, database.Host, database.Port, nd.DBAUser, nd.APIUser)
	fmt.Fprintln(stdout, strings.Join(sources, "\n"))
	if q != nil {
		if ok, err := q.yes("  Create it?", false); err != nil || !ok {
			return fail(errCancelled)
		}
	}

	ctx, stop := signal.NotifyContext(ctx, os.Interrupt, syscall.SIGTERM)
	defer stop()
	err = nd.Create(ctx, conn, server, func(ctx context.Context, dbName string) (*pgx.Conn, error) {
		return connectTo(ctx, database, c.adminUser, adminPassword, dbName, c.action)
	})
	if err != nil {
		return fail(err)
	}
	c.created = true
	fmt.Fprintf(stdout, "Created database %s, and roles %s and %s.\n", nd.Name, nd.DBAUser, nd.APIUser)

	// From here on, the database stays: what fails can be done again by hand.
	unreachable := func(role string, err error) int {
		fmt.Fprintf(stderr, "%s: connecting as %s: %v\n", c.action, role, err)
		if strings.Contains(err.Error(), "pg_hba.conf") {
			fmt.Fprintf(stderr, "The server's pg_hba.conf has no line that lets %s connect to %s from here; add one (README.md, step 5), and reload it.\n", role, nd.Name)
		}
		fmt.Fprintln(stderr, "The database is made; once that works, run wtfd schema (and wtfd account create).")
		return exitFailure
	}
	dbaConfig, err := database.ConnConfig(nd.DBAUser, nd.DBAPassword, "wtfd schema")
	if err != nil {
		return fail(err)
	}
	log := slog.New(slog.NewTextHandler(stderr, &slog.HandlerOptions{Level: slog.LevelWarn})).With("action", "schema")
	if _, err := schema.Run(ctx, schema.Options{
		ConnConfig: dbaConfig,
		APIUser:    nd.APIUser,
		Scripts:    db.Scripts,
		Logger:     log,
	}); err != nil {
		var connectErr *pgconn.ConnectError
		if errors.As(err, &connectErr) {
			return unreachable(nd.DBAUser, err)
		}
		fmt.Fprintf(stderr, "%s: creating the schema: %v\nThe database is made; run wtfd schema to try again.\n", c.action, err)
		return exitFailure
	}
	fmt.Fprintln(stdout, "Created the schema.")

	apiConn, err := connectTo(ctx, database, nd.APIUser, nd.APIPassword, nd.Name, c.action)
	if err != nil {
		return unreachable(nd.APIUser, err)
	}
	apiConn.Close(ctx)
	fmt.Fprintf(stdout, "%s can connect.\n", nd.APIUser)

	if c.firstAccount != "" {
		dbaConn, err := admin.Connect(ctx, dbaConfig)
		if err != nil {
			return unreachable(nd.DBAUser, err)
		}
		defer dbaConn.Close(context.WithoutCancel(ctx))
		password, err := admin.CreateAccount(ctx, dbaConn, c.firstAccount, "admin")
		if err != nil {
			fmt.Fprintf(stderr, "%s: creating the account: %v\n", c.action, err)
			return exitFailure
		}
		fmt.Fprintf(stdout, "Account %s created, an admin, with password %s (shown only this once; change it after logging in).\n", c.firstAccount, password)
	}
	return exitOK
}

// connectTo connects as user to the database dbName on database's server.
func connectTo(ctx context.Context, database *config.Database, user, password, dbName, action string) (*pgx.Conn, error) {
	d := *database
	d.Name = dbName
	cfg, err := d.ConnConfig(user, password, action)
	if err != nil {
		return nil, err
	}
	return pgx.ConnectConfig(ctx, cfg)
}

// needsPassword reports whether connecting failed for want of the right
// password.
func needsPassword(err error) bool {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "28P01" {
		return true
	}
	return strings.Contains(err.Error(), "password")
}
