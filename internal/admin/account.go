// Package admin implements the operator's actions that bypass the REST API:
// "wtfd account" (creating an account with every privilege, setting a
// password), "wtfd history purge" and "wtfd deleted purge". It connects as
// the DBA role. See WTFD.md and ACCOUNTS.md.
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

// CreateAccount creates an account with every privilege (read-write data,
// model and account; read history), such as the first one of a new
// database. It returns the account's generated password.
func CreateAccount(ctx context.Context, conn *pgx.Conn, email string) (string, error) {
	password, err := generatePassword(16)
	if err != nil {
		return "", err
	}
	err = pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, "SELECT util.check_email($1)", email); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `
			INSERT INTO account (email, password_hash,
			                     data_privilege, model_privilege, account_privilege, history_privilege)
			VALUES (btrim($1), extensions.crypt($2, extensions.gen_salt('bf')),
			        'read_write', 'read_write', 'read_write', 'read_only')`,
			email, password)
		return err
	})
	if err != nil {
		return "", err
	}
	return password, nil
}

// SetPassword gives an account a new generated password, lifts a lockout
// and ends the account's sessions: the way back in when the password is lost.
// It returns the password.
func SetPassword(ctx context.Context, conn *pgx.Conn, email string) (string, error) {
	password, err := generatePassword(16)
	if err != nil {
		return "", err
	}
	err = pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
		var id string
		err := tx.QueryRow(ctx, `
			UPDATE account
			SET password_hash = extensions.crypt($2, extensions.gen_salt('bf')),
			    failed_logins = 0, last_failed_login = NULL
			WHERE lower(email) = lower(btrim($1)) AND NOT deleted
			RETURNING id`,
			email, password).Scan(&id)
		if errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("no account with email %q", email)
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
