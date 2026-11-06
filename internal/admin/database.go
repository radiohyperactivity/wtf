package admin

import (
	"context"
	"crypto/hmac"
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"
)

// MinServerVersion is the oldest PostgreSQL WtF runs on, as
// server_version_num.
const MinServerVersion = 180000

// NewDatabase is what "wtfd database create" makes: a database, the role
// that owns it (DBA) and the role the REST API connects as (API), set up as
// README.md describes by hand.
type NewDatabase struct {
	Name               string // the database
	DBAUser            string
	DBAPassword        string
	APIUser            string
	APIPassword        string
	ICULocale          string // the collation, an ICU locale; "und" is language-neutral
	APIConnectionLimit int
}

// Server is what the administrator's connection found out about the server.
type Server struct {
	Version   string // as the server reports it, "18.1"
	Superuser bool   // the administrator is a superuser; otherwise it has CREATEROLE and CREATEDB
}

// CheckServer checks, over the administrator's connection, that the server
// is new enough and has ICU, and that the administrator may create roles
// and databases.
func CheckServer(ctx context.Context, conn *pgx.Conn) (Server, error) {
	var s Server
	var version, icu int
	var createRole, createDB bool
	err := conn.QueryRow(ctx, `
		SELECT current_setting('server_version'),
		       current_setting('server_version_num')::int,
		       (SELECT count(*) FROM pg_collation WHERE collprovider = 'i'),
		       rolsuper, rolcreaterole, rolcreatedb
		FROM pg_roles WHERE rolname = current_user`,
	).Scan(&s.Version, &version, &icu, &s.Superuser, &createRole, &createDB)
	if err != nil {
		return s, err
	}
	switch {
	case version < MinServerVersion:
		return s, fmt.Errorf("the server runs PostgreSQL %s; WtF needs %d or newer", s.Version, MinServerVersion/10000)
	case icu == 0:
		return s, errors.New("the server's PostgreSQL is built without ICU, which WtF needs for sorting text")
	case !s.Superuser && !(createRole && createDB):
		return s, errors.New("the administrator must be a superuser, or have CREATEROLE and CREATEDB")
	}
	return s, nil
}

// Check reports what is wrong with d's names and passwords, and whether the
// database or the roles exist already. It changes nothing.
func (d NewDatabase) Check(ctx context.Context, conn *pgx.Conn) error {
	for _, n := range []struct{ what, name string }{
		{"database", d.Name}, {"DBA role", d.DBAUser}, {"API role", d.APIUser},
	} {
		if n.name == "" || len(n.name) > 63 {
			return fmt.Errorf("the %s's name must be 1 to 63 bytes long", n.what)
		}
	}
	if d.DBAUser == d.APIUser {
		return errors.New("the DBA and API roles must be different roles")
	}
	if d.APIConnectionLimit < 1 {
		return errors.New("the API role's connection limit must be at least 1")
	}
	for _, p := range []struct{ role, password string }{{d.DBAUser, d.DBAPassword}, {d.APIUser, d.APIPassword}} {
		if err := CheckPassword(p.password); err != nil {
			return fmt.Errorf("the password for %s %w", p.role, err)
		}
	}
	var exists bool
	err := conn.QueryRow(ctx, "SELECT EXISTS (SELECT FROM pg_database WHERE datname = $1)", d.Name).Scan(&exists)
	if err != nil {
		return err
	}
	if exists {
		return fmt.Errorf("there is a database %s already", d.Name)
	}
	rows, err := conn.Query(ctx, "SELECT rolname FROM pg_roles WHERE rolname IN ($1, $2) ORDER BY rolname", d.DBAUser, d.APIUser)
	if err != nil {
		return err
	}
	taken, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return err
	}
	if len(taken) > 0 {
		return fmt.Errorf("there is a role %s already", strings.Join(taken, " and a role "))
	}
	return nil
}

// CheckPassword refuses what the hashing below can't handle: PostgreSQL
// prepares a password with SASLprep before hashing it, which leaves
// printable ASCII as it is, so only that is taken.
func CheckPassword(p string) error {
	if len(p) < 8 {
		return errors.New("must be at least 8 characters")
	}
	for _, c := range p {
		if c < 0x20 || c > 0x7e {
			return errors.New("may only have printable ASCII characters (letters, digits, punctuation and space)")
		}
	}
	return nil
}

// The statements, in the order they run. Those on the server run over the
// administrator's connection to its own database; those in the database
// over a second one, to the new database, as the DBA role.
func (d NewDatabase) serverStatements(passwords bool) []string {
	dba, api := ident(d.DBAUser), ident(d.APIUser)
	password := func(p string) string {
		if !passwords {
			return ""
		}
		return "\n    PASSWORD " + literal(scramVerifier(p, nil))
	}
	return []string{
		"CREATE ROLE " + dba + `
    LOGIN
    NOSUPERUSER
    NOCREATEDB
    NOCREATEROLE
    NOREPLICATION
    NOBYPASSRLS` + password(d.DBAPassword),
		"CREATE ROLE " + api + `
    LOGIN
    NOSUPERUSER
    NOCREATEDB
    NOCREATEROLE
    NOREPLICATION
    NOBYPASSRLS
    CONNECTION LIMIT ` + fmt.Sprint(d.APIConnectionLimit) + password(d.APIPassword),
	}
}

func (d NewDatabase) createStatement() string {
	return "CREATE DATABASE " + ident(d.Name) + `
    OWNER           ` + ident(d.DBAUser) + `
    TEMPLATE        template0
    ENCODING        'UTF8'
    LOCALE_PROVIDER icu
    ICU_LOCALE      ` + literal(d.ICULocale)
}

func (d NewDatabase) settingStatements() []string {
	db, dba, api := ident(d.Name), ident(d.DBAUser), ident(d.APIUser)
	return []string{
		"ALTER ROLE " + api + " IN DATABASE " + db + " SET search_path = public",
		"ALTER ROLE " + api + " IN DATABASE " + db + " SET statement_timeout = '30s'",
		"ALTER ROLE " + api + " IN DATABASE " + db + " SET idle_in_transaction_session_timeout = '60s'",
		"ALTER ROLE " + dba + " IN DATABASE " + db + " SET search_path = public",
	}
}

func (d NewDatabase) databaseStatements() []string {
	db, dba, api := ident(d.Name), ident(d.DBAUser), ident(d.APIUser)
	return []string{
		"SET ROLE " + dba,
		"REVOKE ALL ON DATABASE " + db + " FROM PUBLIC",
		"GRANT CONNECT ON DATABASE " + db + " TO " + api,
		"REVOKE ALL ON SCHEMA public FROM PUBLIC",
		"GRANT USAGE ON SCHEMA public TO " + api,
		"ALTER DEFAULT PRIVILEGES FOR ROLE " + dba + "\n    REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC",
		"RESET ROLE",
	}
}

// Script is what Create does, as a psql script for a superuser, for those
// who would rather run it by hand. psql's \password asks for the roles'
// passwords and sends them hashed.
func (d NewDatabase) Script(adminDatabase string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "-- As a superuser, connected to %s (psql -U postgres -d %s).\n\n", adminDatabase, adminDatabase)
	for _, s := range d.serverStatements(false) {
		b.WriteString(s + ";\n\n")
	}
	fmt.Fprintf(&b, "\\password %s\n\\password %s\n\n", ident(d.DBAUser), ident(d.APIUser))
	b.WriteString(d.createStatement() + ";\n\n")
	for _, s := range d.settingStatements() {
		b.WriteString(s + ";\n")
	}
	fmt.Fprintf(&b, "\n\\connect %s\n\n", ident(d.Name))
	for _, s := range d.databaseStatements() {
		b.WriteString(s + ";\n")
	}
	b.WriteString("\n-- Then, as the DBA role: wtfd schema\n")
	return b.String()
}

// Create makes the roles and the database over conn, the administrator's
// connection, and sets up the database's privileges over a connection
// connect opens to it as the administrator. On a failure it removes what it
// made, and says so in the error.
//
// An administrator that isn't a superuser makes itself a member of the DBA
// role for the time being, as only a member may make a role a database's
// owner and act for it.
func (d NewDatabase) Create(ctx context.Context, conn *pgx.Conn, server Server, connect func(ctx context.Context, database string) (*pgx.Conn, error)) (err error) {
	var undo []string // statements that remove what is made, latest first
	defer func() {
		if err == nil || len(undo) == 0 {
			return
		}
		// The context may be what failed, so the cleanup gets its own.
		cleanup := context.WithoutCancel(ctx)
		var failed []string
		for _, s := range undo {
			if _, e := conn.Exec(cleanup, s); e != nil {
				failed = append(failed, fmt.Sprintf("%s (%v)", s, e))
			}
		}
		if len(failed) > 0 {
			err = fmt.Errorf("%w; removing what was made failed, so remove it by hand: %s", err, strings.Join(failed, "; "))
		} else {
			err = fmt.Errorf("%w; what was made has been removed again", err)
		}
	}()
	exec := func(sql, undoSQL string) error {
		if _, err := conn.Exec(ctx, sql); err != nil {
			return err
		}
		if undoSQL != "" {
			undo = append([]string{undoSQL}, undo...)
		}
		return nil
	}

	roles := d.serverStatements(true)
	if err := exec(roles[0], "DROP ROLE "+ident(d.DBAUser)); err != nil {
		return fmt.Errorf("creating role %s: %w", d.DBAUser, err)
	}
	if err := exec(roles[1], "DROP ROLE "+ident(d.APIUser)); err != nil {
		return fmt.Errorf("creating role %s: %w", d.APIUser, err)
	}
	if !server.Superuser {
		if err := exec("GRANT "+ident(d.DBAUser)+" TO CURRENT_USER WITH INHERIT FALSE, SET TRUE",
			"REVOKE "+ident(d.DBAUser)+" FROM CURRENT_USER"); err != nil {
			return fmt.Errorf("becoming a member of %s: %w", d.DBAUser, err)
		}
	}
	if err := exec(d.createStatement(), "DROP DATABASE "+ident(d.Name)+" WITH (FORCE)"); err != nil {
		return fmt.Errorf("creating database %s: %w", d.Name, err)
	}
	for _, s := range d.settingStatements() {
		if err := exec(s, ""); err != nil {
			return fmt.Errorf("setting the roles' defaults: %w", err)
		}
	}

	dbConn, err := connect(ctx, d.Name)
	if err != nil {
		return fmt.Errorf("connecting to %s: %w", d.Name, err)
	}
	defer dbConn.Close(context.WithoutCancel(ctx))
	for _, s := range d.databaseStatements() {
		if _, err := dbConn.Exec(ctx, s); err != nil {
			return fmt.Errorf("setting the privileges in %s: %w", d.Name, err)
		}
	}

	if !server.Superuser {
		if _, err := conn.Exec(ctx, "REVOKE "+ident(d.DBAUser)+" FROM CURRENT_USER"); err != nil {
			return fmt.Errorf("leaving %s: %w", d.DBAUser, err)
		}
	}
	return nil
}

// GeneratePassword returns a new random password for a role.
func GeneratePassword() (string, error) {
	return generatePassword(24)
}

// scramVerifier hashes password as PostgreSQL stores it for SCRAM-SHA-256
// (as psql's \password does), so the password itself never reaches the
// server, nor its log. A nil salt is a new random one.
func scramVerifier(password string, salt []byte) string {
	const iterations = 4096 // PostgreSQL's default, scram_iterations
	if salt == nil {
		salt = make([]byte, 16)
		rand.Read(salt)
	}
	salted, err := pbkdf2.Key(sha256.New, password, salt, iterations, sha256.Size)
	if err != nil {
		panic(err) // only for key lengths SHA-256 can't give
	}
	clientKey := hmacSHA256(salted, "Client Key")
	storedKey := sha256.Sum256(clientKey)
	serverKey := hmacSHA256(salted, "Server Key")
	b64 := base64.StdEncoding.EncodeToString
	return fmt.Sprintf("SCRAM-SHA-256$%d:%s$%s:%s", iterations, b64(salt), b64(storedKey[:]), b64(serverKey))
}

func hmacSHA256(key []byte, message string) []byte {
	h := hmac.New(sha256.New, key)
	h.Write([]byte(message))
	return h.Sum(nil)
}

// ident quotes a name for SQL.
func ident(name string) string {
	return pgx.Identifier{name}.Sanitize()
}

// literal quotes a text for SQL (standard_conforming_strings is on).
func literal(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "''") + "'"
}
