package files

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// hashUsed tells whether any attachment of tenant $1, live or deleted, has
// the file with hash $2. An attachment's tenant is its owner's: an item's
// through its class, a stock row's through its location.
const hashUsed = `SELECT EXISTS (
	SELECT 1
	FROM public.attachment a
	LEFT JOIN public.item i      ON i.id = a.item
	LEFT JOIN public.class ic    ON ic.id = i.class
	LEFT JOIN public.stock s     ON s.id = a.stock
	LEFT JOIN public.location sl ON sl.id = s.location
	LEFT JOIN public.location l  ON l.id = a.location
	LEFT JOIN public.class c     ON c.id = a.class
	WHERE a.hash = $2
	  AND coalesce(ic.tenant, sl.tenant, l.tenant, c.tenant) = $1)`

// expiredSessions removes every tenant's expired sessions: those that sat
// unused for longer than their max_idle. Sessions aren't in history, so no
// action is needed.
const expiredSessions = `DELETE FROM public.session
	WHERE max_idle IS NOT NULL AND last_used <= now() - max_idle`

// GCOptions configures GC.
type GCOptions struct {
	ConnConfig *pgx.ConnConfig // connection as the schema owner (DBA role)
	Store      *Store
	MinAge     time.Duration // files younger than this are never removed
	DryRun     bool
	Logger     *slog.Logger
}

// GCResult reports what GC removed, or with DryRun, would remove.
type GCResult struct {
	Files    int
	Bytes    int64
	Sessions int64 // expired sessions
}

// GC removes files that no attachment references, in every tenant's
// directory:
//
//   - files on disk whose hash no attachment of the tenant has: their
//     attachments were deleted, or an upload's database insert failed;
//   - abandoned uploads in the tenant's tmp directory;
//   - and, in the database, every tenant's expired sessions.
//
// Files younger than MinAge are left alone, so uploads in progress are safe.
// Each removal takes the file's advisory lock (as uploads do) and re-checks
// that the file is still unreferenced. A directory that belongs to no
// tenant is reported and left alone.
func GC(ctx context.Context, o GCOptions) (GCResult, error) {
	cfg := o.ConnConfig.Copy()
	cfg.RuntimeParams["search_path"] = "public"
	conn, err := pgx.ConnectConfig(ctx, cfg)
	if err != nil {
		return GCResult{}, fmt.Errorf("connect: %w", err)
	}
	defer conn.Close(context.Background())

	var result GCResult
	if o.DryRun {
		err = conn.QueryRow(ctx, "SELECT count(*) FROM public.session WHERE max_idle IS NOT NULL AND last_used <= now() - max_idle").
			Scan(&result.Sessions)
	} else {
		var tag pgconn.CommandTag
		tag, err = conn.Exec(ctx, expiredSessions)
		result.Sessions = tag.RowsAffected()
	}
	if err != nil {
		return result, fmt.Errorf("expired sessions: %w", err)
	}
	hosts, err := o.Store.Hosts()
	if err != nil {
		return result, err
	}
	for _, host := range hosts {
		var tenant string
		err := conn.QueryRow(ctx, "SELECT id::text FROM public.tenant WHERE host = $1", host).Scan(&tenant)
		if errors.Is(err, pgx.ErrNoRows) {
			o.Logger.Warn("a directory of no tenant, left alone", "directory", host)
			continue
		}
		if err != nil {
			return result, err
		}
		store, err := o.Store.Tenant(host)
		if err != nil {
			return result, err
		}
		if err := gcTenant(ctx, conn, o, tenant, host, store, &result); err != nil {
			return result, err
		}
	}
	return result, nil
}

// gcTenant removes the unreferenced files of one tenant.
func gcTenant(ctx context.Context, conn *pgx.Conn, o GCOptions, tenant, host string, store *Store, result *GCResult) error {
	cutoff := time.Now().Add(-o.MinAge)
	remove := func(hash string, size int64) error {
		if o.DryRun {
			o.Logger.Info("would remove file", "tenant", host, "sha256", hash, "size", size)
		} else {
			removed, err := removeUnreferenced(ctx, conn, store, tenant, hash)
			if err != nil || !removed {
				return err
			}
			o.Logger.Debug("removed file", "tenant", host, "sha256", hash, "size", size)
		}
		result.Files++
		result.Bytes += size
		return nil
	}

	// Files on disk that no attachment has.
	type candidate struct {
		hash string
		size int64
	}
	var unreferenced []candidate
	err := store.Walk(func(hash string, modTime time.Time) error {
		if modTime.After(cutoff) {
			return nil
		}
		var referenced bool
		if err := conn.QueryRow(ctx,
			hashUsed, tenant, hash).Scan(&referenced); err != nil {
			return err
		}
		if !referenced {
			p, _ := store.path(hash)
			info, err := os.Stat(p)
			if err != nil {
				return err
			}
			unreferenced = append(unreferenced, candidate{hash, info.Size()})
		}
		return nil
	})
	if err != nil {
		return err
	}
	for _, c := range unreferenced {
		if err := remove(c.hash, c.size); err != nil {
			return err
		}
	}

	// Abandoned uploads.
	return store.TempFiles(func(path string, modTime time.Time) error {
		if modTime.After(cutoff) {
			return nil
		}
		info, err := os.Stat(path)
		if err != nil {
			return err
		}
		if o.DryRun {
			o.Logger.Info("would remove abandoned upload", "path", path, "size", info.Size())
		} else if err := os.Remove(path); err != nil {
			return err
		}
		result.Files++
		result.Bytes += info.Size()
		return nil
	})
}

// removeUnreferenced deletes a file of a tenant under its advisory lock, if
// no attachment of the tenant has its hash. It reports whether the file was
// removed.
func removeUnreferenced(ctx context.Context, conn *pgx.Conn, store *Store, tenant, hash string) (bool, error) {
	removed := false
	err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, "SELECT pg_advisory_xact_lock(attachment.file_lock_key($1))", hash); err != nil {
			return err
		}
		var referenced bool
		if err := tx.QueryRow(ctx,
			hashUsed, tenant, hash).Scan(&referenced); err != nil {
			return err
		}
		if referenced {
			return nil
		}
		if err := store.Remove(hash); err != nil {
			return err
		}
		removed = true
		return nil
	})
	return removed, err
}
