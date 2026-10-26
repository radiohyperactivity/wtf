package tenant

import (
	"context"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// PurgeHistory deletes history entries older than olderThan, of one tenant
// (by name) or of all tenants (empty name). With dryRun nothing is deleted.
// It returns the number of entries (that would be) deleted.
func PurgeHistory(ctx context.Context, conn *pgx.Conn, olderThan time.Duration, tenantName string, dryRun bool) (int64, error) {
	if tenantName != "" {
		var exists bool
		if err := conn.QueryRow(ctx, "SELECT EXISTS (SELECT 1 FROM tenant WHERE lower(name) = lower(btrim($1)))",
			tenantName).Scan(&exists); err != nil {
			return 0, err
		}
		if !exists {
			return 0, fmt.Errorf("tenant %q not found", tenantName)
		}
	}

	const where = `
		WHERE happened_at < now() - $1::interval
		  AND ($2 = '' OR tenant = (SELECT id FROM tenant WHERE lower(name) = lower(btrim($2))))`
	age := fmt.Sprintf("%d seconds", int64(olderThan.Seconds()))
	if dryRun {
		var n int64
		err := conn.QueryRow(ctx, "SELECT count(*) FROM history"+where, age, tenantName).Scan(&n)
		return n, err
	}
	tag, err := conn.Exec(ctx, "DELETE FROM history"+where, age, tenantName)
	return tag.RowsAffected(), err
}

// ParseAge parses a duration that may also be given in days ("730d"), as
// well as anything time.ParseDuration accepts ("36h").
func ParseAge(s string) (time.Duration, error) {
	if days, ok := strings.CutSuffix(s, "d"); ok {
		n, err := strconv.Atoi(days)
		if err != nil || n < 0 {
			return 0, fmt.Errorf("%q is not a number of days", s)
		}
		return time.Duration(n) * 24 * time.Hour, nil
	}
	d, err := time.ParseDuration(s)
	if err != nil || d < 0 {
		return 0, fmt.Errorf("%q is not a duration (e.g. 730d, 36h)", s)
	}
	return d, nil
}
