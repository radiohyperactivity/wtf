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
	ConnConfig *pgx.ConnConfig // connection as the API role
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

// GC removes files that nothing references, with the database functions
// for it (attachment.gc_hashes_used, attachment.gc_unused and
// account.gc_sessions), which the API role may call:
//
//   - files on disk whose hash no photo or attachment value has: what had them was deleted or given another file, or an upload's
//     database change failed;
//   - abandoned uploads in the tmp directory;
//   - and, in the database, the expired sessions.
//
// Files younger than MinAge are left alone, so uploads in progress are safe.
// Each removal takes the file's advisory lock (as uploads do) and checks
// again that the file is still unreferenced.
func GC(ctx context.Context, o GCOptions) (GCResult, error) {
	cfg := o.ConnConfig.Copy()
	cfg.RuntimeParams["search_path"] = "public"
	conn, err := pgx.ConnectConfig(ctx, cfg)
	if err != nil {
		return GCResult{}, fmt.Errorf("connect: %w", err)
	}
	defer conn.Close(context.Background())

	var result GCResult
	err = conn.QueryRow(ctx, "SELECT account.gc_sessions($1)", o.DryRun).Scan(&result.Sessions)
	if err != nil {
		return result, fmt.Errorf("expired sessions: %w", err)
	}
	if err := gcFiles(ctx, conn, o, &result); err != nil {
		return result, err
	}
	return result, nil
}

// gcFiles removes the unreferenced files.
func gcFiles(ctx context.Context, conn *pgx.Conn, o GCOptions, result *GCResult) error {
	store := o.Store
	cutoff := time.Now().Add(-o.MinAge)
	remove := func(hash string, size int64) error {
		if o.DryRun {
			o.Logger.Info("would remove file", "sha256", hash, "size", size)
		} else {
			removed, err := removeUnreferenced(ctx, conn, store, hash)
			if err != nil || !removed {
				return err
			}
			o.Logger.Debug("removed file", "sha256", hash, "size", size)
		}
		result.Files++
		result.Bytes += size
		return nil
	}

	// Files on disk that nothing has.
	rows, err := conn.Query(ctx, "SELECT attachment.gc_hashes_used()")
	if err != nil {
		return err
	}
	hashes, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return err
	}
	used := make(map[string]bool, len(hashes))
	for _, h := range hashes {
		used[h] = true
	}
	type candidate struct {
		hash string
		size int64
	}
	var unreferenced []candidate
	err = store.Walk(func(hash string, modTime time.Time) error {
		if modTime.After(cutoff) {
			return nil
		}
		if !used[hash] {
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

// removeUnreferenced deletes a file under its advisory lock, if nothing
// uses it. It reports whether the file was removed.
func removeUnreferenced(ctx context.Context, conn *pgx.Conn, store *Store, hash string) (bool, error) {
	removed := false
	err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
		var unused bool
		if err := tx.QueryRow(ctx, "SELECT attachment.gc_unused($1)", hash).Scan(&unused); err != nil {
			return err
		}
		if !unused {
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
