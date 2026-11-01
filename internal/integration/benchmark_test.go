package integration

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// TestItemListBenchmark times item.list on a large tenant: 500 classes,
// 50,000 items with 4 values each (200,000), and 100,000 stock rows in 100
// locations; with no search, with an attribute filter and with a search.
// Making the tenant takes minutes, so it only runs with
// WTFD_TEST_BENCHMARK=1, and logs what it measures (go test -v).
func TestItemListBenchmark(t *testing.T) {
	if os.Getenv("WTFD_TEST_BENCHMARK") == "" {
		t.Skip("set WTFD_TEST_BENCHMARK=1 to run the benchmark of item.list")
	}
	at := newAccessorTenant(t, "benchmark")
	d := at.admin.d
	ctx := context.Background()
	admin := at.admin

	length := admin.id(t, "attribute.create", "Length", "decimal", nil, false)
	weight := admin.id(t, "attribute.create", "Weight", "decimal", nil, false)
	note := admin.id(t, "attribute.create", "Note", "text", nil, false)
	colour := admin.id(t, "attribute.create", "Colour", "choice", nil, false)
	for i := 1; i <= 20; i++ {
		admin.must(t, "attribute.option_create", colour, fmt.Sprintf("Colour %d", i))
	}

	start := time.Now()
	if err := d.inAction(t, at.id, func(tx pgx.Tx, _ string) error {
		for _, sql := range []string{
			// 10 classes at the top, each with 49 below it, the attributes
			// assigned at the top.
			`INSERT INTO public.class (tenant, name)
			 SELECT $1, 'Group ' || g FROM generate_series(1, 10) g`,
			`INSERT INTO public.class (tenant, parent, name)
			 SELECT $1, c.id, c.name || ' kind ' || k
			 FROM public.class c, generate_series(1, 49) k
			 WHERE c.tenant = $1 AND c.parent IS NULL`,
			`INSERT INTO public.class_attribute (class, attribute, scope)
			 SELECT c.id, a.id, 'item'
			 FROM public.class c, public.attribute a
			 WHERE c.tenant = $1 AND c.parent IS NULL AND a.tenant = $1`,
			`INSERT INTO public.location (tenant, code, name)
			 SELECT $1, tenant.take_codes($1, 1), 'Shelf ' || g FROM generate_series(1, 100) g`,
		} {
			if _, err := tx.Exec(ctx, sql, at.id); err != nil {
				return fmt.Errorf("%s: %w", sql, err)
			}
		}
		if _, err := tx.Exec(ctx, `
			WITH leaves AS (
			    SELECT id, row_number() OVER (ORDER BY id) - 1 AS n
			    FROM public.class WHERE tenant = $1 AND parent IS NOT NULL
			), codes AS (SELECT tenant.take_codes($1, 50000) AS first)
			INSERT INTO public.item (code, class, name)
			SELECT codes.first + g - 1, l.id, 'Item ' || g || ' ' || md5(g::text)
			FROM generate_series(1, 50000) g
			CROSS JOIN codes
			JOIN leaves l ON l.n = g % 490`, at.id); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `
			INSERT INTO public.item_value (item, attribute, number, text, option)
			SELECT i.id, a.id,
			       CASE WHEN a.datatype = 'decimal' THEN (i.code % 1000) / 10.0 END,
			       CASE WHEN a.datatype = 'text' THEN 'note ' || md5(i.id::text) END,
			       CASE WHEN a.datatype = 'choice' THEN
			           (SELECT o.id FROM public.attribute_option o
			            WHERE o.attribute = a.id ORDER BY o.id OFFSET i.code % 20 LIMIT 1) END
			FROM public.item i
			JOIN public.class c ON c.id = i.class AND c.tenant = $1
			CROSS JOIN public.attribute a
			WHERE a.tenant = $1`, at.id); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `
			WITH shelves AS (
			    SELECT id, row_number() OVER (ORDER BY id) - 1 AS n
			    FROM public.location WHERE tenant = $1
			), rows AS (
			    SELECT i.id, i.code, k FROM public.item i
			    JOIN public.class c ON c.id = i.class AND c.tenant = $1
			    CROSS JOIN generate_series(1, 2) k
			), codes AS (SELECT tenant.take_codes($1, (SELECT count(*)::integer FROM rows)) AS first)
			INSERT INTO public.stock (code, item, location, amount)
			SELECT codes.first + row_number() OVER () - 1, r.id, s.id, r.code % 7
			FROM rows r CROSS JOIN codes
			JOIN shelves s ON s.n = (r.code + r.k) % 100`, at.id)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	t.Logf("made the tenant in %s", time.Since(start).Round(time.Second))
	if _, err := d.dba.Exec(ctx, "ANALYZE"); err != nil {
		t.Fatal(err)
	}

	cases := []struct {
		name   string
		search any
		where  any
	}{
		{"no search, no filter", nil, nil},
		{"an attribute filter", nil, fmt.Sprintf(`[{"attribute": "%s", "op": ">", "value": 50}]`, length)},
		{"two filters", nil, fmt.Sprintf(`[{"attribute": "%s", "op": "<", "value": 20},
		                                   {"attribute": "%s", "op": "=", "value": "Colour 3"}]`, weight, colour)},
		{"a search of one word", "abc", nil},
		{"a search of two words", "item 12", nil},
	}
	_ = note
	for _, c := range cases {
		var best time.Duration
		var total float64
		for run := 0; run < 3; run++ {
			begin := time.Now()
			page := at.viewer.must(t, "item.list", nil, c.search, c.where, 100, 0)
			took := time.Since(begin)
			if run == 0 || took < best {
				best = took
			}
			total = num(t, page, "total")
		}
		t.Logf("%-22s %7.0f ms best of 3, %6.0f matching", c.name, float64(best.Microseconds())/1000, total)
	}
}
