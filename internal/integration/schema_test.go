package integration

import (
	"context"
	"io"
	"log/slog"
	"strings"
	"testing"

	"github.com/radiohyperactivity/wtf/db"
	"github.com/radiohyperactivity/wtf/internal/schema"
)

// The schema is built from nothing by openDatabase; running "wtfd schema"
// again finds it up to date.
func TestSchemaUpToDate(t *testing.T) {
	d := database(t)
	result, err := schema.Run(context.Background(), schema.Options{
		ConnConfig: d.dbaConfig,
		APIUser:    d.apiUser,
		Scripts:    db.Scripts,
		DryRun:     true,
		Logger:     slog.New(slog.NewTextHandler(io.Discard, nil)),
	})
	if err != nil {
		t.Fatal(err)
	}
	if result.Pending {
		t.Error("a second run of wtfd schema found something to do")
	}
}

// The server sorts names with an ICU collation, which needs a server built
// with ICU.
func TestNaturalCollation(t *testing.T) {
	d := database(t)
	got := d.value(t, `
		SELECT string_agg(n, ',' ORDER BY n COLLATE public.natural)
		FROM unnest(ARRAY['Item 10', 'item 2', 'Item 1']) n`)
	if got != "Item 1,item 2,Item 10" {
		t.Errorf("sorted %q", got)
	}
}

// A rebuild drops the function schemas whole, so it refuses when that would
// take anything else with them, such as a table made in one by mistake.
func TestRebuildRefusesToDropData(t *testing.T) {
	d := database(t)
	ctx := context.Background()
	run := func() error {
		_, err := schema.Run(ctx, schema.Options{
			ConnConfig: d.dbaConfig,
			APIUser:    d.apiUser,
			Scripts:    db.Scripts,
			Logger:     slog.New(slog.NewTextHandler(io.Discard, nil)),
		})
		return err
	}
	for _, sql := range []string{
		"CREATE TABLE util.stray (id integer)",
		// Forgetting the scripts makes the next run rebuild them.
		"DELETE FROM wtfd.repeatable",
	} {
		if _, err := d.dba.Exec(ctx, sql); err != nil {
			t.Fatal(err)
		}
	}
	err := run()
	if err == nil || !strings.Contains(err.Error(), "table util.stray") {
		t.Fatalf("rebuild with a table in util: %v", err)
	}
	if _, err := d.dba.Exec(ctx, "DROP TABLE util.stray"); err != nil {
		t.Fatal(err)
	}
	if err := run(); err != nil {
		t.Fatalf("rebuild: %v", err)
	}
}
