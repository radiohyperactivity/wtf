package files

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"time"

	"github.com/jackc/pgx/v5"
)

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
	Files int
	Bytes int64
}

// GC removes files that no attachment references:
//
//   - rows in the file table without attachments, and their files on disk;
//   - files on disk without a row (e.g. an upload whose database insert
//     failed);
//   - abandoned uploads in the tmp directory.
//
// Files younger than MinAge are left alone, so uploads in progress are safe.
// Each removal takes the file's advisory lock (as uploads do) and re-checks
// that the file is still unreferenced.
func GC(ctx context.Context, o GCOptions) (GCResult, error) {
	cfg := o.ConnConfig.Copy()
	cfg.RuntimeParams["search_path"] = "public"
	conn, err := pgx.ConnectConfig(ctx, cfg)
	if err != nil {
		return GCResult{}, fmt.Errorf("connect: %w", err)
	}
	defer conn.Close(context.Background())

	var result GCResult
	cutoff := time.Now().Add(-o.MinAge)
	remove := func(hash string, size int64, reason string) error {
		if o.DryRun {
			o.Logger.Info("would remove file", "sha256", hash, "size", size, "reason", reason)
		} else {
			removed, err := removeUnreferenced(ctx, conn, o.Store, hash)
			if err != nil || !removed {
				return err
			}
			o.Logger.Debug("removed file", "sha256", hash, "size", size, "reason", reason)
		}
		result.Files++
		result.Bytes += size
		return nil
	}

	// File rows without attachments.
	rows, _ := conn.Query(ctx, `
		SELECT encode(f.sha256, 'hex'), f.size
		FROM file f
		WHERE NOT EXISTS (SELECT 1 FROM attachment a WHERE a.file = f.sha256)`)
	type candidate struct {
		hash string
		size int64
	}
	unreferenced, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (candidate, error) {
		var c candidate
		err := row.Scan(&c.hash, &c.size)
		return c, err
	})
	if err != nil {
		return GCResult{}, err
	}
	for _, c := range unreferenced {
		modTime, exists, err := o.Store.ModTime(c.hash)
		if err != nil {
			return result, err
		}
		if exists && modTime.After(cutoff) {
			continue
		}
		if err := remove(c.hash, c.size, "no attachment"); err != nil {
			return result, err
		}
	}

	// Files on disk without a row.
	var orphans []candidate
	err = o.Store.Walk(func(hash string, modTime time.Time) error {
		if modTime.After(cutoff) {
			return nil
		}
		var known bool
		if err := conn.QueryRow(ctx,
			"SELECT EXISTS (SELECT 1 FROM file WHERE sha256 = decode($1, 'hex'))", hash).Scan(&known); err != nil {
			return err
		}
		if !known {
			p, _ := o.Store.path(hash)
			info, err := os.Stat(p)
			if err != nil {
				return err
			}
			orphans = append(orphans, candidate{hash, info.Size()})
		}
		return nil
	})
	if err != nil {
		return result, err
	}
	for _, c := range orphans {
		if err := remove(c.hash, c.size, "not in database"); err != nil {
			return result, err
		}
	}

	// Abandoned uploads.
	err = o.Store.TempFiles(func(path string, modTime time.Time) error {
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
	return result, err
}

// removeUnreferenced deletes a file's row (if any) and the file itself under
// the file's advisory lock, if no attachment references it. It reports
// whether the file was removed.
func removeUnreferenced(ctx context.Context, conn *pgx.Conn, store *Store, hash string) (bool, error) {
	removed := false
	err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, "SELECT pg_advisory_xact_lock(file_lock_key(decode($1, 'hex')))", hash); err != nil {
			return err
		}
		var referenced bool
		if err := tx.QueryRow(ctx,
			"SELECT EXISTS (SELECT 1 FROM attachment WHERE file = decode($1, 'hex'))", hash).Scan(&referenced); err != nil {
			return err
		}
		if referenced {
			return nil
		}
		if _, err := tx.Exec(ctx, "DELETE FROM file WHERE sha256 = decode($1, 'hex')", hash); err != nil {
			return err
		}
		if err := store.Remove(hash); err != nil {
			return err
		}
		removed = true
		return nil
	})
	return removed, err
}
