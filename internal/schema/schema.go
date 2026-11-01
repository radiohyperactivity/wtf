// Package schema implements "wtfd schema": it creates or upgrades the database
// schema from the embedded SQL scripts and brings function grants up to date.
// The design is described in WTFD.md.
package schema

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

const (
	minServerVersion = 180000

	// Key of the advisory lock that serialises concurrent "wtfd schema" runs.
	lockKey int64 = 0x7774666473636865 // "wtfdsche"
)

const bootstrapSQL = `
CREATE SCHEMA IF NOT EXISTS wtfd;

CREATE TABLE IF NOT EXISTS wtfd.migration (
    version    integer     NOT NULL PRIMARY KEY,
    name       text        NOT NULL,
    checksum   bytea       NOT NULL,
    applied_at timestamptz NOT NULL DEFAULT now(),
    applied_by name        NOT NULL DEFAULT current_user
);

CREATE TABLE IF NOT EXISTS wtfd.repeatable (
    name       text        NOT NULL PRIMARY KEY,
    checksum   bytea       NOT NULL,
    applied_at timestamptz NOT NULL DEFAULT now(),
    applied_by name        NOT NULL DEFAULT current_user
);
`

// Options configures Run.
type Options struct {
	ConnConfig *pgx.ConnConfig // connection as the schema owner (DBA role)
	APIUser    string          // role that gets EXECUTE on the API functions
	Scripts    fs.FS           // contains migrations/ and repeatable/
	DryRun     bool
	Logger     *slog.Logger
}

// Result reports the outcome of Run.
type Result struct {
	// Pending is true when the database was not up to date. With DryRun
	// nothing was changed; otherwise the changes have been applied.
	Pending bool
}

// querier is satisfied by both *pgx.Conn and pgx.Tx.
type querier interface {
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

type appliedMigration struct {
	version  int
	name     string
	checksum []byte
}

// Run brings the database schema up to date.
func Run(ctx context.Context, o Options) (Result, error) {
	log := o.Logger

	migrations, repeatables, err := loadScripts(o.Scripts)
	if err != nil {
		return Result{}, fmt.Errorf("embedded scripts: %w", err)
	}

	cfg := o.ConnConfig.Copy()
	cfg.RuntimeParams["search_path"] = "public"
	cfg.RuntimeParams["statement_timeout"] = "0"
	conn, err := pgx.ConnectConfig(ctx, cfg)
	if err != nil {
		return Result{}, fmt.Errorf("connect: %w", err)
	}
	defer conn.Close(context.Background())

	if err := checkPreconditions(ctx, conn, o.APIUser); err != nil {
		return Result{}, err
	}

	// Wait for any concurrent run to finish, then fail fast on table locks.
	// The advisory lock is released when the session ends.
	if _, err := conn.Exec(ctx, "SELECT pg_advisory_lock($1)", lockKey); err != nil {
		return Result{}, fmt.Errorf("advisory lock: %w", err)
	}
	if _, err := conn.Exec(ctx, "SET lock_timeout = '30s'"); err != nil {
		return Result{}, err
	}

	if !o.DryRun {
		if _, err := conn.Exec(ctx, bootstrapSQL); err != nil {
			return Result{}, fmt.Errorf("bootstrap: %w", err)
		}
	}

	applied, appliedRepeatables, err := readBookkeeping(ctx, conn)
	if err != nil {
		return Result{}, err
	}
	if err := verify(migrations, applied); err != nil {
		return Result{}, err
	}

	pendingMigrations := migrations[len(applied):]
	rebuild := len(pendingMigrations) > 0 || repeatablesChanged(repeatables, appliedRepeatables)

	defaultsOK, err := defaultPrivilegesOK(ctx, conn)
	if err != nil {
		return Result{}, err
	}
	grants, err := grantStatements(ctx, conn, o.APIUser)
	if err != nil {
		return Result{}, err
	}

	log.Info("database checked",
		"database_version", len(applied),
		"binary_version", len(migrations))

	pending := len(pendingMigrations) > 0 || rebuild || !defaultsOK || len(grants) > 0
	if o.DryRun {
		for _, m := range pendingMigrations {
			log.Info("would apply migration", "file", m.name)
		}
		if rebuild {
			log.Info("would rebuild repeatable scripts", "scripts", len(repeatables))
		}
		if !defaultsOK {
			log.Info("would revoke default EXECUTE on new functions from PUBLIC")
		}
		for _, g := range grants {
			log.Info("would correct grant", "statement", g)
		}
		if !pending {
			log.Info("up to date")
		}
		return Result{Pending: pending}, nil
	}

	if !defaultsOK {
		if _, err := conn.Exec(ctx, "ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC"); err != nil {
			return Result{}, fmt.Errorf("default privileges: %w", err)
		}
		log.Info("revoked default EXECUTE on new functions from PUBLIC")
	}

	for _, m := range pendingMigrations {
		if err := applyMigration(ctx, conn, m, log); err != nil {
			return Result{}, err
		}
		log.Info("applied migration", "file", m.name)
	}

	if rebuild {
		if err := rebuildRepeatables(ctx, conn, repeatables, o.APIUser, log); err != nil {
			return Result{}, err
		}
	} else if len(grants) > 0 {
		if err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			return applyGrants(ctx, tx, o.APIUser, log)
		}); err != nil {
			return Result{}, err
		}
	}

	log.Info("up to date", "version", len(migrations))
	return Result{Pending: pending}, nil
}

func checkPreconditions(ctx context.Context, conn *pgx.Conn, apiUser string) error {
	var version int
	var isOwner, apiExists bool
	err := conn.QueryRow(ctx, `
		SELECT current_setting('server_version_num')::int,
		       d.datdba = r.oid,
		       EXISTS (SELECT 1 FROM pg_roles WHERE rolname = $1)
		FROM pg_database d, pg_roles r
		WHERE d.datname = current_database()
		  AND r.rolname = current_user`, apiUser).Scan(&version, &isOwner, &apiExists)
	if err != nil {
		return fmt.Errorf("preconditions: %w", err)
	}
	switch {
	case version < minServerVersion:
		return fmt.Errorf("PostgreSQL %d.%d is too old; 18 or newer is required", version/10000, version%10000)
	case !isOwner:
		return errors.New("the DBA role must own the database, so that it owns every object it creates")
	case !apiExists:
		return fmt.Errorf("API role %q does not exist", apiUser)
	}
	return nil
}

// readBookkeeping returns the applied migrations (by version) and the checksums
// of the applied repeatable scripts. Before the first run the tables don't
// exist yet (only possible with DryRun), which reads as nothing applied.
func readBookkeeping(ctx context.Context, conn *pgx.Conn) ([]appliedMigration, map[string][]byte, error) {
	var exists bool
	if err := conn.QueryRow(ctx, "SELECT to_regclass('wtfd.migration') IS NOT NULL").Scan(&exists); err != nil {
		return nil, nil, err
	}
	if !exists {
		return nil, map[string][]byte{}, nil
	}

	rows, _ := conn.Query(ctx, "SELECT version, name, checksum FROM wtfd.migration ORDER BY version")
	applied, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (appliedMigration, error) {
		var m appliedMigration
		err := row.Scan(&m.version, &m.name, &m.checksum)
		return m, err
	})
	if err != nil {
		return nil, nil, fmt.Errorf("read wtfd.migration: %w", err)
	}

	repeatables := map[string][]byte{}
	rows, _ = conn.Query(ctx, "SELECT name, checksum FROM wtfd.repeatable")
	var name string
	var checksum []byte
	if _, err := pgx.ForEachRow(rows, []any{&name, &checksum}, func() error {
		repeatables[name] = checksum
		return nil
	}); err != nil {
		return nil, nil, fmt.Errorf("read wtfd.repeatable: %w", err)
	}
	return applied, repeatables, nil
}

// verify checks that the applied migrations are exactly the first migrations
// of this binary, unchanged.
func verify(migrations []script, applied []appliedMigration) error {
	if len(applied) > len(migrations) {
		return fmt.Errorf("the database is at version %d, but this wtfd only knows versions up to %d; use a newer wtfd",
			applied[len(applied)-1].version, len(migrations))
	}
	for i, a := range applied {
		m := migrations[i]
		switch {
		case a.version != m.version:
			return fmt.Errorf("wtfd.migration: expected version %d, found %d", m.version, a.version)
		case a.name != m.name:
			return fmt.Errorf("migration %d was applied as %s, but is now named %s", a.version, a.name, m.name)
		case !bytes.Equal(a.checksum, m.checksum):
			return fmt.Errorf("migration %s was changed after it was applied; put changes in a new migration", m.name)
		}
	}
	return nil
}

func repeatablesChanged(scripts []script, applied map[string][]byte) bool {
	if len(scripts) != len(applied) {
		return true
	}
	for _, s := range scripts {
		if !bytes.Equal(applied[s.name], s.checksum) {
			return true
		}
	}
	return false
}

func applyMigration(ctx context.Context, conn *pgx.Conn, m script, log *slog.Logger) error {
	log.Debug("applying migration", "file", m.name)
	return pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, m.sql); err != nil {
			return scriptError(m, err)
		}
		_, err := tx.Exec(ctx,
			"INSERT INTO wtfd.migration (version, name, checksum) VALUES ($1, $2, $3)",
			m.version, m.name, m.checksum)
		return err
	})
}

// functionSchemasSQL selects the schemas the repeatable scripts make: every
// schema the connected role owns, except public (the tables), extensions
// (pgcrypto) and wtfd (this bookkeeping). They hold only functions, so a
// rebuild drops them whole.
const functionSchemasSQL = `
	SELECT n.oid
	FROM pg_namespace n
	WHERE n.nspowner = (SELECT oid FROM pg_roles WHERE rolname = current_user)
	  AND n.nspname NOT IN ('public', 'extensions', 'wtfd')
	  AND n.nspname NOT LIKE 'pg\_%'`

// rebuildRepeatables drops every repeatable object and recreates them all,
// including the grants, in one transaction. The function schemas are
// dropped with CASCADE, which takes their triggers along; before that,
// refuseToDropData makes sure nothing else would go with them.
func rebuildRepeatables(ctx context.Context, conn *pgx.Conn, scripts []script, apiUser string, log *slog.Logger) error {
	return pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
		if err := refuseToDropData(ctx, tx); err != nil {
			return err
		}
		rows, _ := tx.Query(ctx, `
			SELECT n.nspname
			FROM pg_namespace n
			WHERE n.oid IN (`+functionSchemasSQL+`)
			ORDER BY n.nspname`)
		schemas, err := pgx.CollectRows(rows, pgx.RowTo[string])
		if err != nil {
			return err
		}
		for _, name := range schemas {
			log.Debug("dropping schema", "schema", name)
			if _, err := tx.Exec(ctx, "DROP SCHEMA "+pgx.Identifier{name}.Sanitize()+" CASCADE"); err != nil {
				return err
			}
		}

		if _, err := tx.Exec(ctx, "DELETE FROM wtfd.repeatable"); err != nil {
			return err
		}
		for _, s := range scripts {
			log.Debug("running repeatable script", "file", s.name)
			if _, err := tx.Exec(ctx, s.sql); err != nil {
				return scriptError(s, err)
			}
			if _, err := tx.Exec(ctx,
				"INSERT INTO wtfd.repeatable (name, checksum) VALUES ($1, $2)",
				s.name, s.checksum); err != nil {
				return err
			}
		}

		// The functions the API calls are the SECURITY DEFINER ones; they
		// are logged per schema, so that a change in the list shows.
		rows, _ = tx.Query(ctx, `
			SELECT n.nspname,
			       count(*),
			       count(*) FILTER (WHERE p.prosecdef),
			       coalesce(string_agg(p.proname, ' ' ORDER BY p.proname) FILTER (WHERE p.prosecdef), '')
			FROM pg_proc p
			JOIN pg_namespace n ON n.oid = p.pronamespace
			WHERE n.oid IN (`+functionSchemasSQL+`)
			GROUP BY n.nspname
			ORDER BY n.nspname`)
		var schemaName, apiNames string
		var functions, apiFunctions, total, totalAPI int
		if _, err := pgx.ForEachRow(rows, []any{&schemaName, &functions, &apiFunctions, &apiNames}, func() error {
			total += functions
			totalAPI += apiFunctions
			log.Debug("schema", "schema", schemaName, "functions", functions, "api_functions", apiNames)
			return nil
		}); err != nil {
			return err
		}
		log.Info("rebuilt repeatable scripts", "scripts", len(scripts), "functions", total, "api_functions", totalAPI)

		return applyGrants(ctx, tx, apiUser, log)
	})
}

// refuseToDropData returns an error when dropping the function schemas
// would take more than functions, triggers, views and the types PostgreSQL
// makes along with them: anything else in those schemas (a table made there
// by mistake), or anything outside them that uses one of their functions (a
// column default, a CHECK constraint or an index). Those hold or guard
// data, so they belong in a migration, and must not depend on a function a
// rebuild drops (WTFD.md, "Schema").
func refuseToDropData(ctx context.Context, tx pgx.Tx) error {
	rows, _ := tx.Query(ctx, `
		WITH schemas AS (`+functionSchemasSQL+`),
		functions AS (
		    SELECT p.oid FROM pg_proc p WHERE p.pronamespace IN (SELECT oid FROM schemas)
		)
		SELECT format('%s %s.%s', CASE c.relkind WHEN 'r' THEN 'table' WHEN 'S' THEN 'sequence'
		                                         WHEN 'i' THEN 'index' ELSE 'relation' END,
		              n.nspname, c.relname)
		FROM pg_class c
		JOIN pg_namespace n ON n.oid = c.relnamespace
		WHERE c.relnamespace IN (SELECT oid FROM schemas)
		  AND c.relkind NOT IN ('v', 'c')
		UNION ALL
		SELECT format('type %s.%s', n.nspname, t.typname)
		FROM pg_type t
		JOIN pg_namespace n ON n.oid = t.typnamespace
		WHERE t.typnamespace IN (SELECT oid FROM schemas)
		  AND t.typtype IN ('b', 'd', 'e', 'r', 'm')
		  AND t.typelem = 0
		UNION ALL
		SELECT pg_describe_object(d.classid, d.objid, d.objsubid)
		       || ' uses ' || pg_describe_object(d.refclassid, d.refobjid, 0)
		FROM pg_depend d
		WHERE d.refclassid = 'pg_proc'::regclass
		  AND d.refobjid IN (SELECT oid FROM functions)
		  AND d.deptype = 'n'
		  AND d.classid NOT IN ('pg_proc'::regclass, 'pg_trigger'::regclass, 'pg_rewrite'::regclass)
		ORDER BY 1`)
	blockers, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return fmt.Errorf("check what a rebuild would drop: %w", err)
	}
	if len(blockers) > 0 {
		return fmt.Errorf("a rebuild would drop more than functions, triggers and views: %s",
			strings.Join(blockers, "; "))
	}
	return nil
}

// grantStatements returns the GRANT/REVOKE statements needed so that the API
// role may use every function schema and execute exactly the SECURITY
// DEFINER functions in them, and PUBLIC may execute none of our functions.
// Only functions owned by the connected role are considered, in public and
// the function schemas.
func grantStatements(ctx context.Context, q querier, apiUser string) ([]string, error) {
	role := pgx.Identifier{apiUser}.Sanitize()
	var statements []string

	rows, _ := q.Query(ctx, `
		SELECT n.nspname
		FROM pg_namespace n
		WHERE n.oid IN (`+functionSchemasSQL+`)
		  AND NOT has_schema_privilege($1, n.oid, 'USAGE')
		ORDER BY n.nspname`, apiUser)
	missing, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return nil, fmt.Errorf("check schema grants: %w", err)
	}
	for _, name := range missing {
		statements = append(statements, "GRANT USAGE ON SCHEMA "+pgx.Identifier{name}.Sanitize()+" TO "+role)
	}

	rows, _ = q.Query(ctx, `
		WITH f AS (
		    SELECT p.oid::regprocedure::text                      AS signature,
		           p.prosecdef AND n.nspname <> 'public'          AS want_api,
		           coalesce(p.proacl, acldefault('f', p.proowner)) AS acl
		    FROM pg_proc p
		    JOIN pg_namespace n ON n.oid = p.pronamespace
		    WHERE (n.nspname = 'public' OR n.oid IN (`+functionSchemasSQL+`))
		      AND p.prokind = 'f'
		      AND p.proowner = (SELECT oid FROM pg_roles WHERE rolname = current_user)
		)
		SELECT signature,
		       want_api,
		       EXISTS (SELECT 1 FROM aclexplode(acl) x
		               WHERE x.grantee = 0 AND x.privilege_type = 'EXECUTE') AS public_has,
		       EXISTS (SELECT 1 FROM aclexplode(acl) x
		               WHERE x.grantee = (SELECT oid FROM pg_roles WHERE rolname = $1)
		                 AND x.privilege_type = 'EXECUTE')                   AS api_has
		FROM f
		ORDER BY signature`, apiUser)

	var signature string
	var wantAPI, publicHas, apiHas bool
	_, err = pgx.ForEachRow(rows, []any{&signature, &wantAPI, &publicHas, &apiHas}, func() error {
		if publicHas {
			statements = append(statements, "REVOKE EXECUTE ON FUNCTION "+signature+" FROM PUBLIC")
		}
		if wantAPI && !apiHas {
			statements = append(statements, "GRANT EXECUTE ON FUNCTION "+signature+" TO "+role)
		}
		if !wantAPI && apiHas {
			statements = append(statements, "REVOKE EXECUTE ON FUNCTION "+signature+" FROM "+role)
		}
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("check grants: %w", err)
	}
	return statements, nil
}

func applyGrants(ctx context.Context, tx pgx.Tx, apiUser string, log *slog.Logger) error {
	statements, err := grantStatements(ctx, tx, apiUser)
	if err != nil {
		return err
	}
	for _, s := range statements {
		log.Debug("grant", "statement", s)
		if _, err := tx.Exec(ctx, s); err != nil {
			return fmt.Errorf("%s: %w", s, err)
		}
	}
	if len(statements) > 0 {
		log.Info("corrected grants", "statements", len(statements))
	}
	return nil
}

// defaultPrivilegesOK reports whether functions created by the connected role
// are, by default, not executable by PUBLIC.
func defaultPrivilegesOK(ctx context.Context, conn *pgx.Conn) (bool, error) {
	var ok bool
	err := conn.QueryRow(ctx, `
		SELECT EXISTS (
		    SELECT 1
		    FROM pg_default_acl d
		    WHERE d.defaclrole = (SELECT oid FROM pg_roles WHERE rolname = current_user)
		      AND d.defaclnamespace = 0
		      AND d.defaclobjtype = 'f'
		      AND NOT EXISTS (SELECT 1 FROM aclexplode(d.defaclacl) x
		                      WHERE x.grantee = 0 AND x.privilege_type = 'EXECUTE')
		)`).Scan(&ok)
	if err != nil {
		return false, fmt.Errorf("check default privileges: %w", err)
	}
	return ok, nil
}

// scriptError adds the script name, the line number and PostgreSQL's details
// to an error from executing a script.
func scriptError(s script, err error) error {
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) {
		return fmt.Errorf("%s: %w", s.name, err)
	}

	location := s.name
	if pgErr.Position > 0 {
		// Position is a 1-based character (not byte) offset into the script.
		runes := []rune(s.sql)
		if int(pgErr.Position) <= len(runes) {
			line := strings.Count(string(runes[:pgErr.Position]), "\n") + 1
			location = fmt.Sprintf("%s:%d", s.name, line)
		}
	}

	msg := fmt.Sprintf("%s: %s (SQLSTATE %s)", location, pgErr.Message, pgErr.Code)
	for _, extra := range []string{pgErr.Detail, pgErr.Hint, pgErr.Where} {
		if extra != "" {
			msg += "\n  " + extra
		}
	}
	return errors.New(msg)
}
