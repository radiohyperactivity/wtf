package integration

import (
	"context"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// TestPerformance times the functions the API calls, on tenants of growing
// size, as the API's role calls them (with util.session first, as a real
// request). WTFD_TEST_PERF lists the sizes, in items: "1000,10000,50000".
// Each size gets a tenant of its own, shaped like a real inventory and
// scaled with it (see perfShape), loaded with set-based statements through
// the rules; then the reads and the writes are timed. Without
// WTFD_TEST_PERF it is skipped. Run it with -v to see the tables, and with
// WTFD_TEST_PERF_REPORT=<file> to also write them as Markdown.
func TestPerformance(t *testing.T) {
	sizes := os.Getenv("WTFD_TEST_PERF")
	if sizes == "" {
		t.Skip("set WTFD_TEST_PERF to the sizes to try, e.g. 1000,10000")
	}
	var report strings.Builder
	fmt.Fprintf(&report, "# Performance, %s\n", time.Now().Format("2006-01-02 15:04"))
	for _, field := range strings.Split(sizes, ",") {
		n, err := strconv.Atoi(strings.TrimSpace(field))
		if err != nil || n < 100 {
			t.Fatalf("WTFD_TEST_PERF: %q is not a number of items (at least 100)", field)
		}
		t.Run(fmt.Sprintf("%d items", n), func(t *testing.T) {
			report.WriteString(runPerformance(t, n))
		})
	}
	if path := os.Getenv("WTFD_TEST_PERF_REPORT"); path != "" {
		if err := os.WriteFile(path, []byte(report.String()), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

// perfShape is how a tenant of n items is made: 10 groups of classes with
// leaves below them, 10 rooms with shelves in them, two stock rows per
// item, four values per item, and a serial number on each stock row of the
// items in one group.
type perfShape struct {
	items, leavesPerGroup, shelvesPerRoom int
}

func shapeFor(n int) perfShape {
	clamp := func(v, low, high int) int { return max(low, min(high, v)) }
	return perfShape{
		items:          n,
		leavesPerGroup: clamp(n/1000, 2, 49),
		shelvesPerRoom: clamp(n/1000, 2, 50),
	}
}

// timing is one measured operation: its median and fastest of the runs.
type timing struct {
	name           string
	median, lowest time.Duration
	note           string
}

func (tm timing) row() string {
	ms := func(d time.Duration) string { return fmt.Sprintf("%.1f", float64(d.Microseconds())/1000) }
	return fmt.Sprintf("| %s | %s | %s | %s |", tm.name, ms(tm.median), ms(tm.lowest), tm.note)
}

// measure runs f once to warm up, then runs times, and returns the median
// and the fastest. f's string is a note for the table (e.g. how many rows
// matched).
func measure(name string, runs int, f func() string) timing {
	note := f()
	var took []time.Duration
	for range runs {
		begin := time.Now()
		note = f()
		took = append(took, time.Since(begin))
	}
	sort.Slice(took, func(i, j int) bool { return took[i] < took[j] })
	return timing{name: name, median: took[len(took)/2], lowest: took[0], note: note}
}

// perfTenant is a tenant made by loadPerfTenant, with what the timed calls
// point at.
type perfTenant struct {
	at                           accessorTenant
	length, weight, note, colour string // attributes
	serial                       string // on each stock row of group 1
	middle, middleCode           string // an item in the middle, and its code
	group, leaf, room, shelf     string
	loads                        []timing
}

func runPerformance(t *testing.T, n int) string {
	p := loadPerfTenant(t, n)
	at, d := p.at, p.at.admin.d
	admin, user, viewer := at.admin, at.user, at.viewer
	ctx := context.Background()
	tenant, loads := at.id, p.loads
	length, weight, note, colour, serial := p.length, p.weight, p.note, p.colour, p.serial
	middle, middleCode, group, leaf, room, shelf := p.middle, p.middleCode, p.group, p.leaf, p.room, p.shelf

	// The first six characters of one serial number ("SN-345"): a filter
	// that matches a few stock rows, of a few items.
	serialPart := d.value(t, `SELECT substr(min(v.text), 1, 6) FROM public.stock_value v WHERE v.attribute = $1`, serial).(string)

	const runs = 7
	total := func(v any) string { return fmt.Sprintf("%.0f matching", num(t, v, "total")) }
	var reads []timing
	read := func(name string, f func() string) { reads = append(reads, measure(name, runs, f)) }
	read("item.list, first page", func() string { return total(viewer.must(t, "item.list", nil, nil, nil, 100, 0)) })
	read("item.list, a page in the middle", func() string { return total(viewer.must(t, "item.list", nil, nil, nil, 100, n/2)) })
	read("item.list, a class group", func() string { return total(viewer.must(t, "item.list", group, nil, nil, 100, 0)) })
	read("item.list, a number filter", func() string {
		return total(viewer.must(t, "item.list", nil, nil, fmt.Sprintf(`[{"attribute": "%s", "op": ">", "value": 50}]`, length), 100, 0))
	})
	read("item.list, two filters", func() string {
		return total(viewer.must(t, "item.list", nil, nil, fmt.Sprintf(`[{"attribute": "%s", "op": "<", "value": 20},
			{"attribute": "%s", "op": "=", "value": "Colour 3"}]`, weight, colour), 100, 0))
	})
	read("item.list, a stock value filter", func() string {
		return total(viewer.must(t, "item.list", nil, nil, fmt.Sprintf(`[{"attribute": "%s", "op": "contains", "value": "%s"}]`, serial, serialPart), 100, 0))
	})
	read("item.list, search of one word", func() string { return total(viewer.must(t, "item.list", nil, "abc", nil, 100, 0)) })
	read("item.list, search of two words", func() string { return total(viewer.must(t, "item.list", nil, "item 12", nil, 100, 0)) })
	read("item.list, search matching a class", func() string { return total(viewer.must(t, "item.list", nil, "kind", nil, 100, 0)) })
	read("item.get", func() string { viewer.must(t, "item.get", middle); return "" })
	read("code.resolve", func() string { viewer.must(t, "code.resolve", middleCode); return "" })
	read("stock.list, one item", func() string { return total(viewer.must(t, "stock.list", middle, nil, 100, 0)) })
	read("stock.list, a room (subtree)", func() string { return total(viewer.must(t, "stock.list", nil, room, 100, 0)) })
	read("stock.list, all, first page", func() string { return total(viewer.must(t, "stock.list", nil, nil, 100, 0)) })
	nodes := func(v any) string { return fmt.Sprintf("%d nodes", len(get(t, v, "nodes").([]any))) }
	read("class.list (the tree)", func() string { return nodes(viewer.must(t, "class.list", nil)) })
	read("location.list (the tree)", func() string { return nodes(viewer.must(t, "location.list", nil)) })
	read("class.get, a leaf", func() string { viewer.must(t, "class.get", leaf); return "" })
	read("unit.family_list", func() string { viewer.must(t, "unit.family_list", nil, nil); return "" })
	read("attribute.list", func() string { viewer.must(t, "attribute.list"); return "" })
	read("class.delete_tree, dry run of a group", func() string {
		v := admin.must(t, "class.delete_tree", group, true, true)
		return fmt.Sprintf("%d items", len(get(t, v, "items").([]any)))
	})
	read("location.delete_tree, dry run of a room", func() string {
		v := admin.must(t, "location.delete_tree", room, true, true)
		return fmt.Sprintf("%d stock rows", len(get(t, v, "stock").([]any)))
	})

	// Writes: each run makes what it changes, so runs don't depend on each
	// other; deletes and merges use rows made for them.
	values := fmt.Sprintf(`{"%s": 12.5, "%s": 3, "%s": "a note", "%s": "Colour 7"}`, length, weight, note, colour)
	var writes []timing
	write := func(name string, f func() string) { writes = append(writes, measure(name, runs, f)) }
	write("item.create, 4 values", func() string { user.must(t, "item.create", leaf, "New item", nil, false, values); return "" })
	newItem := user.id(t, "item.create", leaf, "Patched item", nil, false, values)
	write("item.patch, name", func() string { user.must(t, "item.patch", newItem, `{"name": "Renamed item"}`); return "" })
	write("item.value_set", func() string { user.must(t, "item.value_set", newItem, length, "42"); return "" })
	write("stock.create", func() string { user.must(t, "stock.create", newItem, shelf, 100, "{}"); return "" })
	big := user.id(t, "stock.create", newItem, shelf, 1000000, "{}")
	write("stock.move, a part (split)", func() string { user.must(t, "stock.move", big, room, 1); return "" })
	into := user.id(t, "stock.create", newItem, shelf, 1, "{}")
	write("stock.merge, a part", func() string { user.must(t, "stock.merge", big, into, 1); return "" })
	write("stock.create + stock.merge, whole", func() string {
		from := user.id(t, "stock.create", newItem, shelf, 1, "{}")
		user.must(t, "stock.merge", from, into, nil)
		return "both calls"
	})
	write("stock.create + stock.delete", func() string {
		row := user.id(t, "stock.create", newItem, shelf, 1, "{}")
		user.must(t, "stock.delete", row)
		return "both calls"
	})
	write("item.create + item.delete", func() string {
		item := user.id(t, "item.create", leaf, "Short-lived", nil, false, values)
		user.must(t, "item.delete", item)
		return "both calls"
	})
	write("item.delete of a loaded item, refused", func() string {
		if _, err := user.call(t, "item.delete", middle); sqlState(err) != "23001" {
			t.Fatalf("item.delete of an item with stock: %v", err)
		}
		return "has stock"
	})

	var out strings.Builder
	fmt.Fprintf(&out, "\n## %d items\n\n", n)
	var stock, classes, locations int64
	if err := d.dba.QueryRow(ctx, `SELECT
		(SELECT count(*) FROM public.stock s JOIN public.location l ON l.id = s.location WHERE l.tenant = $1),
		(SELECT count(*) FROM public.class WHERE tenant = $1),
		(SELECT count(*) FROM public.location WHERE tenant = $1)`, tenant).Scan(&stock, &classes, &locations); err != nil {
		t.Fatal(err)
	}
	fmt.Fprintf(&out, "%d classes, %d locations, %d items, %d stock rows, %d item values.\n",
		classes, locations, n, stock, 4*n)
	for _, section := range []struct {
		title string
		rows  []timing
	}{
		{"Loading (one statement each, with the rules)", loads},
		{fmt.Sprintf("Reads (median and fastest of %d, after one warm-up)", runs), reads},
		{fmt.Sprintf("Writes (median and fastest of %d, after one warm-up)", runs), writes},
	} {
		fmt.Fprintf(&out, "\n### %s\n\n| Operation | Median ms | Fastest ms | |\n|---|---:|---:|---|\n", section.title)
		for _, r := range section.rows {
			out.WriteString(r.row() + "\n")
		}
	}
	t.Log(out.String())
	return out.String()
}

// loadPerfTenant makes a tenant of n items (perfShape), loading it with
// set-based statements through the rules, each timed.
func loadPerfTenant(t *testing.T, n int) perfTenant {
	host := fmt.Sprintf("perf-%d-%d", n, time.Now().UnixNano()%1000000)
	at := newAccessorTenant(t, host)
	d := at.admin.d
	admin := at.admin
	ctx := context.Background()

	mm := d.value(t, `SELECT u.id::text FROM public.unit u JOIN public.unit_family f ON f.id = u.family
		WHERE f.name = 'Metric length' AND u.symbol = 'mm' AND u.tenant IS NULL`).(string)
	length := admin.id(t, "attribute.create", "Length", "decimal", mm, false)
	weight := admin.id(t, "attribute.create", "Weight", "decimal", nil, false)
	note := admin.id(t, "attribute.create", "Note", "text", nil, false)
	colour := admin.id(t, "attribute.create", "Colour", "choice", nil, false)
	serial := admin.id(t, "attribute.create", "Serial", "text", nil, false)
	for i := 1; i <= 20; i++ {
		admin.must(t, "attribute.option_create", colour, fmt.Sprintf("Colour %d", i))
	}

	// Loading, one statement per step, each timed: the rules run for every
	// row, as they would for rows made one at a time.
	var loads []timing
	step := func(name, sql string, args ...any) {
		begin := time.Now()
		var rows int64
		if err := d.inTx(t, func(tx pgx.Tx) error {
			tag, err := tx.Exec(ctx, sql, args...)
			rows = tag.RowsAffected()
			return err
		}); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		took := time.Since(begin)
		loads = append(loads, timing{name: name, median: took, lowest: took, note: fmt.Sprintf("%d rows", rows)})
	}
	tenant := at.id
	shape := shapeFor(n)
	step("classes: 10 groups", `INSERT INTO public.class (tenant, name)
		SELECT $1, 'Group ' || g FROM generate_series(1, 10) g`, tenant)
	step("classes: leaves", `INSERT INTO public.class (tenant, parent, name)
		SELECT $1, c.id, c.name || ' kind ' || k
		FROM public.class c, generate_series(1, $2::integer) k
		WHERE c.tenant = $1 AND c.parent IS NULL`, tenant, shape.leavesPerGroup)
	step("assignments", `INSERT INTO public.class_attribute (class, attribute, scope)
		SELECT c.id, a.id, CASE WHEN a.id = $2::uuid THEN 'stock' ELSE 'item' END::public.scope
		FROM public.class c, public.attribute a
		WHERE c.tenant = $1 AND c.parent IS NULL AND a.tenant = $1
		  AND (a.id <> $2::uuid OR c.name = 'Group 1')`, tenant, serial)
	step("locations: 10 rooms", `INSERT INTO public.location (tenant, code, name)
		SELECT $1, (SELECT tenant.take_codes($1, 10)) + g - 1, 'Room ' || g FROM generate_series(1, 10) g`, tenant)
	step("locations: shelves", `
		WITH rooms AS (SELECT id, row_number() OVER (ORDER BY id) - 1 AS n FROM public.location WHERE tenant = $1),
		     codes AS (SELECT tenant.take_codes($1, 10 * $2::integer) AS first)
		INSERT INTO public.location (tenant, code, parent, name)
		SELECT $1, codes.first + r.n * $2 + k - 1, r.id, 'Shelf ' || k
		FROM rooms r CROSS JOIN codes CROSS JOIN generate_series(1, $2::integer) k`, tenant, shape.shelvesPerRoom)
	step("items", `
		WITH leaves AS (
		    SELECT id, row_number() OVER (ORDER BY id) - 1 AS n
		    FROM public.class WHERE tenant = $1 AND parent IS NOT NULL
		), codes AS (SELECT tenant.take_codes($1, $2::integer) AS first)
		INSERT INTO public.item (code, class, name)
		SELECT codes.first + g - 1, l.id, 'Item ' || g || ' ' || substr(md5(g::text), 1, 8)
		FROM generate_series(1, $2::integer) g
		CROSS JOIN codes
		JOIN leaves l ON l.n = g % (SELECT count(*) FROM leaves)`, tenant, n)
	step("item values (4 per item)", `
		INSERT INTO public.item_value (item, attribute, number, text, option)
		SELECT i.id, a.id,
		       CASE WHEN a.datatype = 'decimal' THEN (i.code % 1000) / 10.0 END,
		       CASE WHEN a.datatype = 'text' THEN 'note ' || md5(i.id::text) END,
		       CASE WHEN a.datatype = 'choice' THEN o.id END
		FROM public.item i
		JOIN public.class c ON c.id = i.class AND c.tenant = $1
		CROSS JOIN public.attribute a
		LEFT JOIN LATERAL (SELECT o.id FROM public.attribute_option o
		                   WHERE o.attribute = a.id ORDER BY o.id OFFSET i.code % 20 LIMIT 1) o ON true
		WHERE a.tenant = $1 AND a.id <> $2::uuid`, tenant, serial)
	step("stock rows (2 per item)", `
		WITH shelves AS (
		    SELECT id, row_number() OVER (ORDER BY id) - 1 AS n
		    FROM public.location WHERE tenant = $1 AND parent IS NOT NULL
		), rows AS (
		    SELECT i.id, i.code, k FROM public.item i
		    JOIN public.class c ON c.id = i.class AND c.tenant = $1
		    CROSS JOIN generate_series(1, 2) k
		), codes AS (SELECT tenant.take_codes($1, (SELECT count(*)::integer FROM rows)) AS first)
		INSERT INTO public.stock (code, item, location, amount)
		SELECT codes.first + row_number() OVER () - 1, r.id, s.id, r.code % 7
		FROM rows r CROSS JOIN codes
		JOIN shelves s ON s.n = (r.code + r.k) % (SELECT count(*) FROM shelves)`, tenant)
	step("stock values (serial, group 1)", `
		INSERT INTO public.stock_value (stock, attribute, text)
		SELECT s.id, $2::uuid, 'SN-' || s.code
		FROM public.stock s
		JOIN public.item i  ON i.id = s.item
		JOIN public.class l ON l.id = i.class
		JOIN public.class g ON g.id = l.parent AND g.name = 'Group 1'
		WHERE g.tenant = $1`, tenant, serial)
	if _, err := d.dba.Exec(ctx, "ANALYZE"); err != nil {
		t.Fatal(err)
	}

	// Things to point the calls at.
	pick := func(sql string, args ...any) string { return d.value(t, sql, args...).(string) }
	middle := pick(`SELECT i.id::text FROM public.item i JOIN public.class c ON c.id = i.class
		WHERE c.tenant = $1 ORDER BY i.code OFFSET $2 LIMIT 1`, tenant, n/2)
	middleCode := pick(`SELECT util.code_text(code) FROM public.item WHERE id = $1`, middle)
	group := pick(`SELECT id::text FROM public.class WHERE tenant = $1 AND name = 'Group 1'`, tenant)
	room := pick(`SELECT id::text FROM public.location WHERE tenant = $1 AND name = 'Room 1'`, tenant)
	shelf := pick(`SELECT id::text FROM public.location WHERE parent = $1 ORDER BY name LIMIT 1`, room)
	leaf := pick(`SELECT id::text FROM public.class WHERE parent = $1 ORDER BY name LIMIT 1`, group)

	return perfTenant{at: at, length: length, weight: weight, note: note, colour: colour, serial: serial,
		middle: middle, middleCode: middleCode, group: group, leaf: leaf, room: room, shelf: shelf, loads: loads}
}
