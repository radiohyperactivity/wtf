package files

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"time"

	"github.com/jackc/pgx/v5"
)

// hashUsed tells whether any attachment has the file with hash $1.
const hashUsed = `SELECT EXISTS (SELECT 1 FROM item_attachment WHERE hash = $1)
	OR EXISTS (SELECT 1 FROM stock_attachment WHERE hash = $1)
	OR EXISTS (SELECT 1 FROM location_attachment WHERE hash = $1)
	OR EXISTS (SELECT 1 FROM class_attachment WHERE hash = $1)`

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
//   - files on disk whose hash no attachment has: their attachments were
//     deleted, or an upload's database insert failed;
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
	remove := func(hash string, size int64) error {
		if o.DryRun {
			o.Logger.Info("would remove file", "sha256", hash, "size", size)
		} else {
			removed, err := removeUnreferenced(ctx, conn, o.Store, hash)
			if err != nil || !removed {
				return err
			}
			o.Logger.Debug("removed file", "sha256", hash, "size", size)
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
	err = o.Store.Walk(func(hash string, modTime time.Time) error {
		if modTime.After(cutoff) {
			return nil
		}
		var referenced bool
		if err := conn.QueryRow(ctx,
			hashUsed, hash).Scan(&referenced); err != nil {
			return err
		}
		if !referenced {
			p, _ := o.Store.path(hash)
			info, err := os.Stat(p)
			if err != nil {
				return err
			}
			unreferenced = append(unreferenced, candidate{hash, info.Size()})
		}
		return nil
	})
	if err != nil {
		return result, err
	}
	for _, c := range unreferenced {
		if err := remove(c.hash, c.size); err != nil {
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

// removeUnreferenced deletes a file under its advisory lock, if no
// attachment has its hash. It reports whether the file was removed.
func removeUnreferenced(ctx context.Context, conn *pgx.Conn, store *Store, hash string) (bool, error) {
	removed := false
	err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, "SELECT pg_advisory_xact_lock(file_lock_key($1))", hash); err != nil {
			return err
		}
		var referenced bool
		if err := tx.QueryRow(ctx,
			hashUsed, hash).Scan(&referenced); err != nil {
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
