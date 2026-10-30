// Package admin implements the operator's actions that bypass the REST API:
// "wtfd tenant" (creating, listing and renaming tenants), "wtfd account"
// (creating an account, setting a password), "wtfd
// unit" (global units), "wtfd history purge" and "wtfd deleted purge". It
// connects as the DBA role. See WTFD.md, ACCOUNTS.md and TENANTS.md.
package admin

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"math/big"

	"github.com/jackc/pgx/v5"
)

// Connect opens a DBA connection with search_path set to public.
func Connect(ctx context.Context, cfg *pgx.ConnConfig) (*pgx.Conn, error) {
	cfg = cfg.Copy()
	cfg.RuntimeParams["search_path"] = "public"
	return pgx.ConnectConfig(ctx, cfg)
}

// Roles are the account roles (ACCOUNTS.md), from least to most.
var Roles = []string{"viewer", "user", "admin"}

// CreateAccount creates an account with role role ("viewer", "user" or
// "admin") in the tenant with host host, such as its first one. It returns
// the account's generated password.
func CreateAccount(ctx context.Context, conn *pgx.Conn, host, email, role string) (string, error) {
	var password string
	err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
		var err error
		password, err = createAccount(ctx, tx, host, email, role)
		return err
	})
	return password, err
}

// createAccount is CreateAccount in a transaction of the caller's.
func createAccount(ctx context.Context, tx pgx.Tx, host, email, role string) (string, error) {
	tenant, err := tenantID(ctx, tx, host)
	if err != nil {
		return "", err
	}
	password, err := generatePassword(16)
	if err != nil {
		return "", err
	}
	if _, err := tx.Exec(ctx, "SELECT util.check_email($1)", email); err != nil {
		return "", err
	}
	_, err = tx.Exec(ctx, `
		INSERT INTO account (tenant, email, password_hash, role)
		VALUES ($1, btrim($2), extensions.crypt($3, extensions.gen_salt('bf')), $4::role)`,
		tenant, email, password, role)
	if err != nil {
		return "", err
	}
	return password, nil
}

// SetPassword gives an account of the tenant with host host a new generated
// password, lifts a lockout and ends the account's sessions: the way back
// in when the password is lost. It returns the password.
func SetPassword(ctx context.Context, conn *pgx.Conn, host, email string) (string, error) {
	password, err := generatePassword(16)
	if err != nil {
		return "", err
	}
	err = pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
		tenant, err := tenantID(ctx, tx, host)
		if err != nil {
			return err
		}
		var id string
		err = tx.QueryRow(ctx, `
			UPDATE account
			SET password_hash = extensions.crypt($3, extensions.gen_salt('bf')),
			    failed_logins = 0, last_failed_login = NULL
			WHERE tenant = $1 AND lower(email) = lower(btrim($2)) AND NOT deleted
			RETURNING id`,
			tenant, email, password).Scan(&id)
		if errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("no account with email %q in tenant %s", email, host)
		}
		if err != nil {
			return err
		}
		_, err = tx.Exec(ctx, "DELETE FROM session WHERE account = $1", id)
		return err
	})
	if err != nil {
		return "", err
	}
	return password, nil
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
