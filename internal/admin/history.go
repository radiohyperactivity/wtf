package admin

import (
	"context"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// PurgeHistory deletes history entries older than olderThan, of the tenant
// with host host, or of every tenant when host is "". With dryRun nothing is
// deleted. It returns the number of entries (that would be) deleted.
func PurgeHistory(ctx context.Context, conn *pgx.Conn, host string, olderThan time.Duration, dryRun bool) (int64, error) {
	tenant, err := optionalTenant(ctx, conn, host)
	if err != nil {
		return 0, err
	}
	const where = ` WHERE happened_at < now() - $1::interval AND ($2::uuid IS NULL OR tenant = $2)`
	age := fmt.Sprintf("%d seconds", int64(olderThan.Seconds()))
	if dryRun {
		var n int64
		err := conn.QueryRow(ctx, "SELECT count(*) FROM history"+where, age, tenant).Scan(&n)
		return n, err
	}
	tag, err := conn.Exec(ctx, "DELETE FROM history"+where, age, tenant)
	return tag.RowsAffected(), err
}

// optionalTenant returns the id of the tenant with host host, or nil for "".
func optionalTenant(ctx context.Context, q querier, host string) (any, error) {
	if host == "" {
		return nil, nil
	}
	return tenantID(ctx, q, host)
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
