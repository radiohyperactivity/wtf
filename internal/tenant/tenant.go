// Package tenant implements "wtfd tenant": creating, listing and changing
// tenants. It connects as the DBA role; tenants are not managed through the
// REST API. See TENANTS.md.
package tenant

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"math/big"

	"github.com/jackc/pgx/v5"
)

// Info describes a tenant.
type Info struct {
	Name     string
	Hostname string
	Accounts int
}

// Connect opens a DBA connection with search_path set to public.
func Connect(ctx context.Context, cfg *pgx.ConnConfig) (*pgx.Conn, error) {
	cfg = cfg.Copy()
	cfg.RuntimeParams["search_path"] = "public"
	return pgx.ConnectConfig(ctx, cfg)
}

// Create creates a tenant with its first account, which gets every privilege
// (read-write data, model and account; read history). It returns the
// account's generated password.
func Create(ctx context.Context, conn *pgx.Conn, name, hostname, email string) (string, error) {
	password, err := generatePassword(16)
	if err != nil {
		return "", err
	}
	err = pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, "SELECT util.check_email($1)", email); err != nil {
			return err
		}
		var tenantID string
		if err := tx.QueryRow(ctx,
			"INSERT INTO tenant (name, hostname) VALUES (btrim($1), lower(btrim($2))) RETURNING id",
			name, hostname).Scan(&tenantID); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `
			INSERT INTO account (tenant, email, password_hash,
			                     data_privilege, model_privilege, account_privilege, history_privilege)
			VALUES ($1, btrim($2), extensions.crypt($3, extensions.gen_salt('bf')),
			        'read_write', 'read_write', 'read_write', 'read_only')`,
			tenantID, email, password)
		return err
	})
	if err != nil {
		return "", err
	}
	return password, nil
}

// List returns all tenants by name.
func List(ctx context.Context, conn *pgx.Conn) ([]Info, error) {
	rows, _ := conn.Query(ctx, `
		SELECT t.name, t.hostname, (SELECT count(*) FROM account a WHERE a.tenant = t.id)
		FROM tenant t
		ORDER BY lower(t.name)`)
	return pgx.CollectRows(rows, func(row pgx.CollectableRow) (Info, error) {
		var i Info
		err := row.Scan(&i.Name, &i.Hostname, &i.Accounts)
		return i, err
	})
}

// Update renames a tenant and/or changes its hostname. Empty values are left
// unchanged.
func Update(ctx context.Context, conn *pgx.Conn, name, newName, newHostname string) error {
	tag, err := conn.Exec(ctx, `
		UPDATE tenant
		SET name     = COALESCE(NULLIF(btrim($2), ''), name),
		    hostname = COALESCE(NULLIF(lower(btrim($3)), ''), hostname)
		WHERE lower(name) = lower(btrim($1))`,
		name, newName, newHostname)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return fmt.Errorf("tenant %q not found", name)
	}
	return nil
}

// Readable characters only: no 0/o, 1/l/i.
const passwordAlphabet = "abcdefghjkmnpqrstuvwxyz23456789"

func generatePassword(length int) (string, error) {
	if length < 1 {
		return "", errors.New("invalid password length")
	}
	out := make([]byte, length)
	limit := big.NewInt(int64(len(passwordAlphabet)))
	for i := range out {
		n, err := rand.Int(rand.Reader, limit)
		if err != nil {
			return "", err
		}
		out[i] = passwordAlphabet[n.Int64()]
	}
	return string(out), nil
}
