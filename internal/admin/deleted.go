package admin

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
)

// PurgedKinds are the kinds of objects PurgeDeleted removes, in the order it
// removes them and reports them; "action" counts the actions that nothing
// refers to any more, removed last.
var PurgedKinds = []struct{ Table, Name string }{
	{"attachment", "attachments"},
	{"stock", "stock rows"},
	{"item", "items"},
	{"location", "locations"},
	{"class", "classes"},
	{"attribute_option", "options"},
	{"attribute", "attributes"},
	{"action", "actions nothing refers to"},
}

// errDryRun rolls back a dry run's transaction.
var errDryRun = errors.New("dry run")

// purgeStatements remove one kind of object, of tenant $2, that the action
// in its deleted column deleted longer than $1 ago. A row and the action
// that deleted it are of the same tenant (the accessors make sure), so the
// action's tenant is the row's. An object something else still refers to
// stays until that is purged too.
var purgeStatements = map[string]string{
	"attachment": `
		DELETE FROM public.attachment r USING public.action d
		WHERE r.deleted = d.id AND d.tenant = $2 AND d.at < now() - $1::interval`,
	"stock": `
		DELETE FROM public.stock r USING public.action d
		WHERE r.deleted = d.id AND d.tenant = $2 AND d.at < now() - $1::interval`,
	"item": `
		DELETE FROM public.item r USING public.action d
		WHERE r.deleted = d.id AND d.tenant = $2 AND d.at < now() - $1::interval
		  AND NOT EXISTS (SELECT 1 FROM public.stock s WHERE s.item = r.id)`,
	"location": `
		DELETE FROM public.location r USING public.action d
		WHERE r.deleted = d.id AND d.tenant = $2 AND d.at < now() - $1::interval
		  AND NOT EXISTS (SELECT 1 FROM public.location c WHERE c.parent = r.id)
		  AND NOT EXISTS (SELECT 1 FROM public.stock s WHERE s.location = r.id)`,
	"class": `
		DELETE FROM public.class r USING public.action d
		WHERE r.deleted = d.id AND d.tenant = $2 AND d.at < now() - $1::interval
		  AND NOT EXISTS (SELECT 1 FROM public.class c WHERE c.parent = r.id)
		  AND NOT EXISTS (SELECT 1 FROM public.item i WHERE i.class = r.id)`,
	"attribute_option": `
		DELETE FROM public.attribute_option r USING public.action d
		WHERE r.deleted = d.id AND d.tenant = $2 AND d.at < now() - $1::interval
		  AND NOT EXISTS (SELECT 1 FROM public.item_value v WHERE v.option = r.id)
		  AND NOT EXISTS (SELECT 1 FROM public.stock_value v WHERE v.option = r.id)
		  AND NOT EXISTS (SELECT 1 FROM public.class_attribute ca WHERE ca.default_option = r.id)`,
	"attribute": `
		DELETE FROM public.attribute r USING public.action d
		WHERE r.deleted = d.id AND d.tenant = $2 AND d.at < now() - $1::interval
		  AND NOT EXISTS (SELECT 1 FROM public.item_value v WHERE v.attribute = r.id)
		  AND NOT EXISTS (SELECT 1 FROM public.stock_value v WHERE v.attribute = r.id)
		  AND NOT EXISTS (SELECT 1 FROM public.class_attribute ca WHERE ca.attribute = r.id)`,
	// The tenant's actions older than $1 that no deleted row and no history
	// entry refers to any more (an action is the record of who deleted
	// something, and when, and of a call's history entries); never the
	// purge's own, which its history entries refer to.
	"action": `
		DELETE FROM public.action a
		WHERE a.tenant = $2 AND a.at < now() - $1::interval
		  AND a.id <> current_setting('wtf.action')::uuid
		  AND NOT EXISTS (SELECT 1 FROM public.history h WHERE h.action = a.id)
		  AND NOT EXISTS (SELECT 1 FROM public.item x WHERE x.deleted = a.id)
		  AND NOT EXISTS (SELECT 1 FROM public.stock x WHERE x.deleted = a.id)
		  AND NOT EXISTS (SELECT 1 FROM public.location x WHERE x.deleted = a.id)
		  AND NOT EXISTS (SELECT 1 FROM public.class x WHERE x.deleted = a.id)
		  AND NOT EXISTS (SELECT 1 FROM public.attribute x WHERE x.deleted = a.id)
		  AND NOT EXISTS (SELECT 1 FROM public.attribute_option x WHERE x.deleted = a.id)
		  AND NOT EXISTS (SELECT 1 FROM public.attachment x WHERE x.deleted = a.id)
		  AND NOT EXISTS (SELECT 1 FROM public.account x WHERE x.deleted = a.id)`,
}

// PurgeDeleted removes for good the objects that were marked deleted longer
// than olderThan ago: deleted attachments, and objects with what belongs to
// them (values, assignments, options, attachments). The files of purged
// attachments go at the next "wtfd gc". An object something else still
// refers to stays until that is purged too: an item while it has stock
// rows, a location or class while something is in it, an attribute or
// option while values or classes of deleted objects use it. Then the
// actions that nothing refers to any more go too.
//
// Only the tenant with host host, or every tenant, one at a time, when
// host is "". Each tenant's purge is one transaction with an action of its
// own (wtfd's, with no account), which history records the removals under.
// With dryRun nothing is removed. It returns the number of objects (that
// would be) removed per table, all tenants together.
func PurgeDeleted(ctx context.Context, conn *pgx.Conn, host string, olderThan time.Duration, dryRun bool) (map[string]int64, error) {
	var tenants []string
	if host != "" {
		id, err := tenantID(ctx, conn, host)
		if err != nil {
			return nil, err
		}
		tenants = []string{id}
	} else {
		rows, _ := conn.Query(ctx, "SELECT id::text FROM public.tenant ORDER BY host")
		var err error
		if tenants, err = pgx.CollectRows(rows, pgx.RowTo[string]); err != nil {
			return nil, err
		}
	}
	age := fmt.Sprintf("%d seconds", int64(olderThan.Seconds()))

	counts := map[string]int64{}
	for _, tenant := range tenants {
		these := map[string]int64{}
		err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, "SELECT util.begin_action($1::uuid)", tenant); err != nil {
				return err
			}
			for _, kind := range PurgedKinds {
				for {
					tag, err := tx.Exec(ctx, purgeStatements[kind.Table], age, tenant)
					if err != nil {
						return fmt.Errorf("purge %s: %w", kind.Name, err)
					}
					these[kind.Table] += tag.RowsAffected()
					// A tree goes one level per round: what was in a
					// location or class can only go once that is gone.
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
		for table, n := range these {
			counts[table] += n
		}
	}
	return counts, nil
}
