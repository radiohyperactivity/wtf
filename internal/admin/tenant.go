package admin

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/radiohyperactivity/wtf/internal/files"
)

// querier is satisfied by a connection and a transaction.
type querier interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

// tenantID returns the id of the tenant with host host.
func tenantID(ctx context.Context, q querier, host string) (string, error) {
	var id string
	err := q.QueryRow(ctx, "SELECT id FROM tenant WHERE host = lower($1)", host).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", fmt.Errorf("there is no tenant with host %q", host)
	}
	return id, err
}

// CreateTenant creates a tenant with host host, and its first account with
// every privilege. It returns the account's generated password.
func CreateTenant(ctx context.Context, conn *pgx.Conn, host, email string) (string, error) {
	var password string
	err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, "INSERT INTO tenant (host) VALUES ($1)", host); err != nil {
			return hostError(host, err)
		}
		var err error
		password, err = createAccount(ctx, tx, host, email)
		return err
	})
	return password, err
}

// hostError explains the errors of an invalid or taken host.
func hostError(host string, err error) error {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) {
		switch pgErr.Code {
		case "23505":
			return fmt.Errorf("there is a tenant with host %q already", host)
		case "23514":
			return fmt.Errorf("%q can't be a host: it must be a DNS label of lower-case letters, digits and -, "+
				"starting with a letter, at most 63 characters", host)
		}
	}
	return err
}

// Tenant is one row of ListTenants.
type Tenant struct {
	Host     string
	Accounts int64 // live accounts
	Items    int64 // live items
	Files    int64 // attachments, live and deleted
}

// ListTenants lists the tenants by host.
func ListTenants(ctx context.Context, conn *pgx.Conn) ([]Tenant, error) {
	rows, err := conn.Query(ctx, `
		SELECT t.host,
		       (SELECT count(*) FROM account a WHERE a.tenant = t.id AND NOT a.deleted),
		       (SELECT count(*) FROM item i WHERE i.tenant = t.id AND NOT i.deleted),
		       (SELECT count(*) FROM item_attachment a WHERE a.tenant = t.id)
		       + (SELECT count(*) FROM stock_attachment a WHERE a.tenant = t.id)
		       + (SELECT count(*) FROM location_attachment a WHERE a.tenant = t.id)
		       + (SELECT count(*) FROM class_attachment a WHERE a.tenant = t.id)
		FROM tenant t
		ORDER BY t.host`)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(row pgx.CollectableRow) (Tenant, error) {
		var t Tenant
		err := row.Scan(&t.Host, &t.Accounts, &t.Items, &t.Files)
		return t, err
	})
}

// RenameTenant changes a tenant's host, and moves its directory in the files
// directory with it. The directory is moved first and moved back if the
// database refuses the new host.
func RenameTenant(ctx context.Context, conn *pgx.Conn, store *files.Store, host, newHost string) error {
	if _, err := tenantID(ctx, conn, host); err != nil {
		return err
	}
	from, err := store.Tenant(host)
	if err != nil {
		return err
	}
	to, err := store.Tenant(newHost)
	if err != nil {
		return hostError(newHost, &pgconn.PgError{Code: "23514"})
	}
	if _, err := os.Stat(to.Dir()); err == nil {
		return fmt.Errorf("the files directory already has a directory %s; move it away first", to.Dir())
	}
	moved := false
	if _, err := os.Stat(from.Dir()); err == nil {
		if err := os.Rename(from.Dir(), to.Dir()); err != nil {
			return err
		}
		moved = true
	} else if !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	_, err = conn.Exec(ctx, "UPDATE tenant SET host = $2 WHERE host = $1", host, newHost)
	if err != nil {
		if moved {
			if back := os.Rename(to.Dir(), from.Dir()); back != nil {
				return fmt.Errorf("%w; moving %s back to %s failed too: %v",
					hostError(newHost, err), filepath.Base(to.Dir()), from.Dir(), back)
			}
		}
		return hostError(newHost, err)
	}
	return nil
}

// ImportGlobalUnits imports a unit file as global units, which every tenant
// sees (util.unit_import with no tenant). It returns the import's report
// (JSON), as POST /units/import does.
func ImportGlobalUnits(ctx context.Context, conn *pgx.Conn, data []byte, dryRun bool) ([]byte, error) {
	var report string
	err := conn.QueryRow(ctx, "SELECT util.unit_import(NULL, $1::jsonb, $2)::text", string(data), dryRun).Scan(&report)
	return []byte(report), err
}

// SetUnitStandard sets whether a global quantity (kind "quantity") or unit
// family (kind "family"), named name, is available to tenants that haven't
// chosen.
func SetUnitStandard(ctx context.Context, conn *pgx.Conn, kind, name string, available bool) error {
	table := map[string]string{"quantity": "quantity", "family": "unit_family"}[kind]
	if table == "" {
		return fmt.Errorf("unknown kind %q", kind)
	}
	tag, err := conn.Exec(ctx, fmt.Sprintf(
		"UPDATE %s SET standard = $2 WHERE tenant IS NULL AND lower(name) = lower($1)", table),
		name, available)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return fmt.Errorf("there is no global %s named %q", map[string]string{"quantity": "quantity", "family": "unit family"}[kind], name)
	}
	return nil
}
