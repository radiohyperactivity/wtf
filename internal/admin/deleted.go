package admin

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
)

// PurgedKinds are the kinds of objects PurgeDeleted removes, in the order it
// removes them and reports them.
var PurgedKinds = []struct{ Table, Name string }{
	{"stock", "stock rows"},
	{"item", "items"},
	{"location", "locations"},
	{"class", "classes"},
	{"attribute_option", "options"},
	{"attribute", "attributes"},
}

// errDryRun rolls back a dry run's transaction.
var errDryRun = errors.New("dry run")

// PurgeDeleted removes for good the objects that were marked deleted longer
// than olderThan ago. What belongs to them goes with them: values,
// assignments, options, and their links to attachments (an attachment left
// on nothing is deleted, and its file goes at the next "wtfd gc"). An object whose deletion is no longer in history counts as
// deleted long ago. An object something else still refers to stays until
// that is purged too: an item while it has stock rows, a location or class
// while something is in it, an attribute or option while values or classes
// of deleted objects use it. With dryRun nothing is removed. It returns the
// number of objects (that would be) removed per table.
func PurgeDeleted(ctx context.Context, conn *pgx.Conn, olderThan time.Duration, dryRun bool) (map[string]int64, error) {
	age := fmt.Sprintf("%d seconds", int64(olderThan.Seconds()))
	// Deleted, and not deleted recently.
	old := func(table string) string {
		return fmt.Sprintf(`
			r.deleted
			AND NOT EXISTS (
				SELECT 1 FROM history h
				WHERE (h.data ->> 'id') = r.id::text
				  AND h.table_name = '%s'
				  AND h.operation = 'update'
				  AND h.changes -> 'deleted' ->> 'new' = 'true'
				  AND h.happened_at >= now() - $1::interval)`, table)
	}
	statements := map[string]string{
		"stock": `DELETE FROM stock r WHERE ` + old("stock"),
		"item": `DELETE FROM item r WHERE ` + old("item") + `
			AND NOT EXISTS (SELECT 1 FROM stock s WHERE s.item = r.id)`,
		// Leaves first; repeated until nothing is left to remove.
		"location": `DELETE FROM location r WHERE ` + old("location") + `
			AND NOT EXISTS (SELECT 1 FROM location c WHERE c.parent = r.id)
			AND NOT EXISTS (SELECT 1 FROM stock s WHERE s.location = r.id)`,
		"class": `DELETE FROM class r WHERE ` + old("class") + `
			AND NOT EXISTS (SELECT 1 FROM class c WHERE c.parent = r.id)
			AND NOT EXISTS (SELECT 1 FROM item i WHERE i.class = r.id)`,
		"attribute_option": `DELETE FROM attribute_option r WHERE ` + old("attribute_option") + `
			AND NOT EXISTS (SELECT 1 FROM value v WHERE v.option_value = r.id)
			AND NOT EXISTS (SELECT 1 FROM stock_value v WHERE v.option_value = r.id)
			AND NOT EXISTS (SELECT 1 FROM class_attribute ca WHERE ca.option_default = r.id)`,
		"attribute": `DELETE FROM attribute r WHERE ` + old("attribute") + `
			AND NOT EXISTS (SELECT 1 FROM value v WHERE v.attribute = r.id)
			AND NOT EXISTS (SELECT 1 FROM stock_value v WHERE v.attribute = r.id)
			AND NOT EXISTS (SELECT 1 FROM class_attribute ca WHERE ca.attribute = r.id)
			AND NOT EXISTS (SELECT 1 FROM value v JOIN attribute_option o ON o.id = v.option_value WHERE o.attribute = r.id)
			AND NOT EXISTS (SELECT 1 FROM stock_value v JOIN attribute_option o ON o.id = v.option_value WHERE o.attribute = r.id)
			AND NOT EXISTS (SELECT 1 FROM class_attribute ca JOIN attribute_option o ON o.id = ca.option_default WHERE o.attribute = r.id)`,
	}

	counts := map[string]int64{}
	err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
		for _, kind := range PurgedKinds {
			for {
				tag, err := tx.Exec(ctx, statements[kind.Table], age)
				if err != nil {
					return fmt.Errorf("purge %s: %w", kind.Name, err)
				}
				counts[kind.Table] += tag.RowsAffected()
				if tag.RowsAffected() == 0 || (kind.Table != "location" && kind.Table != "class") {
					break
				}
			}
		}
		if dryRun {
			return errDryRun
		}
		return nil
	})
	if err != nil && !errors.Is(err, errDryRun) {
		return nil, err
	}
	return counts, nil
}
