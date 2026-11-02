// Package admin implements the operator's actions that bypass the REST API:
// "wtfd account" (creating an account, such as the first, and setting a
// lost password). It connects as the DBA role. See WTFD.md and ACCOUNTS.md.
package admin

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"math/big"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
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
// "admin"), such as the first one. It returns the account's generated
// password.
func CreateAccount(ctx context.Context, conn *pgx.Conn, email, role string) (string, error) {
	password, err := generatePassword(16)
	if err != nil {
		return "", err
	}
	_, err = conn.Exec(ctx, `
		INSERT INTO public.account (email, password_hash, role)
		VALUES (account.clean_email($1), account.password_hash($2), $3::public.role)`,
		email, password, role)
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "23505" {
		return "", fmt.Errorf("there is an account for %s already", email)
	}
	if err != nil {
		return "", err
	}
	return password, nil
}

// SetPassword gives an account a new generated password, lifts a lockout and ends the account's sessions: the way back
// in when the password is lost. It returns the password.
func SetPassword(ctx context.Context, conn *pgx.Conn, email string) (string, error) {
	password, err := generatePassword(16)
	if err != nil {
		return "", err
	}
	err = pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
		var id string
		err := tx.QueryRow(ctx, `
			UPDATE public.account
			SET password_hash = account.password_hash($2),
			    failed_logins = 0, last_failed_login = NULL
			WHERE email = lower(btrim($1))
			RETURNING id`,
			email, password).Scan(&id)
		if errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("no account with email %q", email)
		}
		if err != nil {
			return err
		}
		_, err = tx.Exec(ctx, "DELETE FROM public.session WHERE account = $1", id)
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
