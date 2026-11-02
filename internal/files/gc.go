package files

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// hashesUsed is the hashes of the files in use: the photos of the items and
// stock rows, and the values of their attachment attributes. One read of
// the items and stock rows, once per run.
const hashesUsed = `
	SELECT i.photo FROM public.item i WHERE i.photo IS NOT NULL
	UNION
	SELECT s.photo FROM public.stock s WHERE s.photo IS NOT NULL
	UNION
	SELECT e.value
	FROM public.item i
	JOIN public.class c ON c.id = i.class
	CROSS JOIN LATERAL jsonb_each_text(i.values) e
	WHERE c.attributes -> e.key ->> 'type' = 'attachment'
	UNION
	SELECT e.value
	FROM public.stock s
	JOIN public.item i  ON i.id = s.item
	JOIN public.class c ON c.id = i.class
	CROSS JOIN LATERAL jsonb_each_text(s.values) e
	WHERE c.attributes -> e.key ->> 'type' = 'attachment'`

// hashUsed tells whether the file with hash $1 is in use: as a photo,
// or as any value of an item or stock row (a text value that happens to be
// the hash keeps the file too, which errs on the safe side). The check
// before a removal, under the file's lock.
const hashUsed = `SELECT
	EXISTS (SELECT 1 FROM public.item i
	        WHERE i.photo = $1 OR EXISTS (SELECT 1 FROM jsonb_each_text(i.values) e WHERE e.value = $1))
	OR EXISTS (SELECT 1 FROM public.stock s
	           WHERE s.photo = $1 OR EXISTS (SELECT 1 FROM jsonb_each_text(s.values) e WHERE e.value = $1))`

// expiredSessions removes the expired sessions: those that sat
// unused for longer than their max_idle.
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

// GC removes files that nothing references:
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
	rows, err := conn.Query(ctx, hashesUsed)
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
		if _, err := tx.Exec(ctx, "SELECT pg_advisory_xact_lock(attachment.file_lock_key($1))", hash); err != nil {
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
