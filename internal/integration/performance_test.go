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

// TestPerformance times the functions the API calls, on databases of
// growing size, as the API's role calls them (with util.session first, as a
// real request). WTFD_TEST_PERF lists the sizes, in items:
// "1000,10000,50000". Each size starts from empty data, shaped like a real
// inventory and scaled with it (see perfShape), loaded with set-based
// statements; then the reads and the writes are timed, and the data is
// emptied again. Without WTFD_TEST_PERF it is skipped. Run it with -v to see
// the tables, and with WTFD_TEST_PERF_REPORT=<file> to also write them as
// Markdown.
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

// perfShape is how a database of n items is made: 10 groups of classes with
// leaves below them, 10 rooms with shelves in them, two stock rows per
// item, four values per item, and a lot number on each stock row of the
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

// perfData is what loadPerf made, with what the timed calls point at.
type perfData struct {
	at                       accessors
	middle, middleCode       string // an item in the middle, and its code
	group, leaf, room, shelf string
	lot                      string // the first six characters of one lot number
	loads                    []timing
}

func runPerformance(t *testing.T, n int) string {
	p := loadPerf(t, n)
	at, d := p.at, p.at.admin.d
	t.Cleanup(func() {
		d.reset(t)
		if _, err := d.dba.Exec(context.Background(), "VACUUM ANALYZE"); err != nil {
			t.Fatal(err)
		}
	})
	admin, user, viewer := at.admin, at.user, at.viewer
	ctx := context.Background()

	const runs = 7
	rows := func(v any) string {
		more := ""
		if get(t, v, "more") == true {
			more = ", more"
		}
		return fmt.Sprintf("%d rows%s", len(get(t, v, "rows").([]any)), more)
	}
	where := func(filters ...map[string]any) string { return js(filters) }
	var reads []timing
	read := func(name string, f func() string) { reads = append(reads, measure(name, runs, f)) }
	read("item.list, first page", func() string { return rows(viewer.must(t, "item.list", nil, nil, nil, 100, nil)) })
	read("item.list, a page in the middle", func() string {
		return rows(viewer.must(t, "item.list", nil, nil, nil, 100, p.middle))
	})
	read("item.list, a class group", func() string { return rows(viewer.must(t, "item.list", p.group, nil, nil, 100, nil)) })
	read("item.list, a number filter", func() string {
		return rows(viewer.must(t, "item.list", nil, nil, where(obj("attribute", "Length", "op", ">", "value", 50)), 100, nil))
	})
	read("item.list, two filters", func() string {
		return rows(viewer.must(t, "item.list", nil, nil, where(obj("attribute", "Weight", "op", "<", "value", 20),
			obj("attribute", "Colour", "op", "=", "value", "Colour 3")), 100, nil))
	})
	read("item.list, a rare filter (reads all)", func() string {
		return rows(viewer.must(t, "item.list", nil, nil, where(obj("attribute", "Length", "op", "=", "value", 99.95)), 100, nil))
	})
	read("item.list, a stock value filter", func() string {
		return rows(viewer.must(t, "item.list", nil, nil, where(obj("attribute", "Lot", "op", "contains", "value", p.lot)), 100, nil))
	})
	read("item.list, search of one word", func() string { return rows(viewer.must(t, "item.list", nil, "abc", nil, 100, nil)) })
	read("item.list, search of two words", func() string { return rows(viewer.must(t, "item.list", nil, "item 12", nil, 100, nil)) })
	read("item.list, search matching a class", func() string { return rows(viewer.must(t, "item.list", nil, "kind", nil, 100, nil)) })
	read("item.list, a rare search (reads all)", func() string {
		return rows(viewer.must(t, "item.list", nil, "zzzz", nil, 100, nil))
	})
	read("item.get", func() string { viewer.must(t, "item.get", p.middle); return "" })
	read("code.resolve", func() string { viewer.must(t, "code.resolve", p.middleCode); return "" })
	read("stock.list, one item", func() string { return rows(viewer.must(t, "stock.list", p.middle, nil, nil, 100, nil)) })
	read("stock.list, a room (subtree)", func() string { return rows(viewer.must(t, "stock.list", nil, p.room, nil, 100, nil)) })
	read("stock.list, all, first page", func() string { return rows(viewer.must(t, "stock.list", nil, nil, nil, 100, nil)) })
	read("stock.list, a serial (reads all)", func() string {
		return rows(viewer.must(t, "stock.list", nil, nil, "sn-"+p.middleCode, 100, nil))
	})
	nodes := func(v any) string { return fmt.Sprintf("%d nodes", len(get(t, v, "nodes").([]any))) }
	read("class.list (the tree)", func() string { return nodes(viewer.must(t, "class.list", nil)) })
	read("location.list (the tree)", func() string { return nodes(viewer.must(t, "location.list", nil)) })
	read("class.get, a leaf", func() string { viewer.must(t, "class.get", p.leaf); return "" })
	read("class.delete_tree, dry run of a group", func() string {
		v := admin.must(t, "class.delete_tree", p.group, true, true)
		return fmt.Sprintf("%d items", len(get(t, v, "items").([]any)))
	})
	read("location.delete_tree, dry run of a room", func() string {
		v := admin.must(t, "location.delete_tree", p.room, true, true)
		return fmt.Sprintf("%d stock rows", len(get(t, v, "stock").([]any)))
	})

	// Writes: each run makes what it changes, so runs don't depend on each
	// other; deletes and merges use rows made for them.
	values := js(obj("Length", 12.5, "Weight", 3, "Note", "a note", "Colour", "Colour 7"))
	var writes []timing
	write := func(name string, f func() string) { writes = append(writes, measure(name, runs, f)) }
	write("item.create, 4 values", func() string { user.must(t, "item.create", p.leaf, "New item", nil, values); return "" })
	newItem := user.id(t, "item.create", p.leaf, "Patched item", nil, values)
	write("item.patch, name", func() string { user.must(t, "item.patch", newItem, `{"name": "Renamed item"}`); return "" })
	write("item.patch, two values", func() string {
		user.must(t, "item.patch", newItem, `{"values": {"Length": 42, "Note": "another"}}`)
		return ""
	})
	write("stock.create", func() string { user.must(t, "stock.create", newItem, p.shelf, 100, nil, nil, "{}"); return "" })
	big := user.id(t, "stock.create", newItem, p.shelf, 1000000, nil, nil, "{}")
	write("stock.move, a part (split)", func() string { user.must(t, "stock.move", big, p.room, 1); return "" })
	into := user.id(t, "stock.create", newItem, p.shelf, 1, nil, nil, "{}")
	write("stock.merge, a part", func() string { user.must(t, "stock.merge", big, into, 1, nil); return "" })
	write("stock.create + stock.merge, whole", func() string {
		from := user.id(t, "stock.create", newItem, p.shelf, 1, nil, nil, "{}")
		user.must(t, "stock.merge", from, into, nil, nil)
		return "both calls"
	})
	write("stock.create + stock.delete", func() string {
		row := user.id(t, "stock.create", newItem, p.shelf, 1, nil, nil, "{}")
		user.must(t, "stock.delete", row)
		return "both calls"
	})
	write("item.create + item.delete", func() string {
		item := user.id(t, "item.create", p.leaf, "Short-lived", nil, values)
		user.must(t, "item.delete", item)
		return "both calls"
	})

	// Class changes, as dry runs: each does all its work, and then undoes it.
	var changes []timing
	change := func(name string, f func() string) { changes = append(changes, measure(name, 3, f)) }
	written := func(v any) string {
		return fmt.Sprintf("%.0f items, %.0f stock rows", num(t, v, "items"), num(t, v, "stock"))
	}
	change("an optional attribute added to a group", func() string {
		return written(admin.must(t, "class.attribute_add", p.group, "Extra", `{"scope": "item", "type": "text"}`, true))
	})
	change("a default added (checks every item of a group)", func() string {
		return written(admin.must(t, "class.attribute_change", p.group, "Note", `{"default": "another"}`, true))
	})
	change("a required attribute with a default added", func() string {
		return written(admin.must(t, "class.attribute_add", p.group, "Brand",
			`{"scope": "item", "type": "text", "required": true, "default": "Acme"}`, true))
	})
	change("an attribute renamed", func() string {
		return written(admin.must(t, "class.attribute_rename", p.group, "Weight", "Mass", true))
	})
	change("a group renamed (search texts)", func() string {
		admin.must(t, "class.patch", p.group, `{"name": "Group renamed"}`)
		r := admin.must(t, "class.patch", p.group, `{"name": "Group 1"}`)
		return "renamed and back: " + str(t, r, "name")
	})

	var out strings.Builder
	fmt.Fprintf(&out, "\n## %d items\n\n", n)
	var stock, classes, locations int64
	if err := d.dba.QueryRow(ctx, `SELECT
		(SELECT count(*) FROM public.stock), (SELECT count(*) FROM public.class), (SELECT count(*) FROM public.location)`).
		Scan(&stock, &classes, &locations); err != nil {
		t.Fatal(err)
	}
	fmt.Fprintf(&out, "%d classes, %d locations, %d items, %d stock rows, %d item values.\n",
		classes, locations, n, stock, 4*n)
	for _, section := range []struct {
		title string
		rows  []timing
	}{
		{"Loading (one statement each)", p.loads},
		{fmt.Sprintf("Reads (median and fastest of %d, after one warm-up)", runs), reads},
		{fmt.Sprintf("Writes (median and fastest of %d, after one warm-up)", runs), writes},
		{"Class changes (dry runs; median and fastest of 3, after one warm-up)", changes},
	} {
		fmt.Fprintf(&out, "\n### %s\n\n| Operation | Median ms | Fastest ms | |\n|---|---:|---:|---|\n", section.title)
		for _, r := range section.rows {
			out.WriteString(r.row() + "\n")
		}
	}
	t.Log(out.String())
	return out.String()
}

// loadPerf empties the data and makes n items (perfShape): the classes'
// attributes through the accessors, everything else with set-based
// statements, each timed. The rows are written as the accessors would write
// them, values, defaults and search texts included, but the statements
// don't check them.
func loadPerf(t *testing.T, n int) perfData {
	at := newAccessors(t, "perf")
	d := at.admin.d
	admin := at.admin
	ctx := context.Background()

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
	shape := shapeFor(n)
	step("classes: 10 groups", `INSERT INTO public.class (name) SELECT 'Group ' || g FROM generate_series(1, 10) g`)
	begin := time.Now()
	var groups []string
	rows, _ := d.dba.Query(ctx, "SELECT id::text FROM public.class ORDER BY name COLLATE public.natural")
	groups, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		t.Fatal(err)
	}
	choices := make([]string, 20)
	for i := range choices {
		choices[i] = fmt.Sprintf("Colour %d", i+1)
	}
	for i, g := range groups {
		addAttribute(t, admin, g, "Length", obj("scope", "item", "type", "decimal", "unit", "mm"))
		addAttribute(t, admin, g, "Weight", obj("scope", "item", "type", "decimal"))
		addAttribute(t, admin, g, "Note", obj("scope", "item", "type", "text"))
		addAttribute(t, admin, g, "Colour", obj("scope", "item", "type", "choice", "choices", choices))
		if i == 0 {
			addAttribute(t, admin, g, "Lot", obj("scope", "stock", "type", "text"))
		}
	}
	took := time.Since(begin)
	loads = append(loads, timing{name: "attributes (through the accessors)", median: took, lowest: took, note: "41 calls"})
	step("classes: leaves", `INSERT INTO public.class (parent, name, attributes)
		SELECT c.id, c.name || ' kind ' || k, c.attributes
		FROM public.class c, generate_series(1, $1::integer) k
		WHERE c.parent IS NULL`, shape.leavesPerGroup)
	step("locations: 10 rooms", `INSERT INTO public.location (code, name)
		SELECT (SELECT util.take_codes(10)) + g - 1, 'Room ' || g FROM generate_series(1, 10) g`)
	step("locations: shelves", `
		WITH rooms AS (SELECT id, row_number() OVER (ORDER BY id) - 1 AS n FROM public.location),
		     codes AS (SELECT util.take_codes(10 * $1::integer) AS first)
		INSERT INTO public.location (code, parent, name)
		SELECT codes.first + r.n * $1 + k - 1, r.id, 'Shelf ' || k
		FROM rooms r CROSS JOIN codes CROSS JOIN generate_series(1, $1::integer) k`, shape.shelvesPerRoom)
	step("items, with 4 values each", `
		WITH leaves AS (
		    SELECT c.id, c.attributes, class.path_text(c.id) AS path, row_number() OVER (ORDER BY c.id) - 1 AS n
		    FROM public.class c WHERE c.parent IS NOT NULL
		), codes AS (SELECT util.take_codes($1::integer) AS first),
		made AS (
		    SELECT codes.first + g - 1 AS code, l.id AS class, l.attributes, l.path,
		           'Item ' || g || ' ' || substr(md5(g::text), 1, 8) AS name,
		           jsonb_build_object('Length', ((codes.first + g - 1) % 1000) / 10.0,
		                              'Weight', ((codes.first + g - 1) % 1000) / 10.0,
		                              'Note', 'note ' || md5(g::text),
		                              'Colour', 'Colour ' || (1 + (codes.first + g - 1) % 20)) AS values
		    FROM generate_series(1, $1::integer) g
		    CROSS JOIN codes
		    JOIN leaves l ON l.n = g % (SELECT count(*) FROM leaves)
		)
		INSERT INTO public.item (code, class, name, values, search)
		SELECT code, class, name, values, class.search_text(name, path, values, attributes) FROM made`, n)
	step("stock rows (2 per item, a lot number in group 1)", `
		WITH shelves AS (
		    SELECT id, row_number() OVER (ORDER BY id) - 1 AS n
		    FROM public.location WHERE parent IS NOT NULL
		), rows AS (
		    SELECT i.id, i.code AS item_code, k, g.name = 'Group 1' AS lot
		    FROM public.item i
		    JOIN public.class l ON l.id = i.class
		    JOIN public.class g ON g.id = l.parent
		    CROSS JOIN generate_series(1, 2) k
		), codes AS (SELECT util.take_codes((SELECT count(*)::integer FROM rows)) AS first),
		numbered AS (SELECT r.*, codes.first + row_number() OVER () - 1 AS code FROM rows r CROSS JOIN codes)
		INSERT INTO public.stock (code, item, location, amount, serial, values)
		SELECT r.code, r.id, s.id, r.item_code % 7, 'SN-' || util.code_text(r.code),
		       CASE WHEN r.lot THEN jsonb_build_object('Lot', 'L-' || r.code) ELSE '{}' END
		FROM numbered r
		JOIN shelves s ON s.n = (r.item_code + r.k) % (SELECT count(*) FROM shelves)`)
	if _, err := d.dba.Exec(ctx, "VACUUM ANALYZE"); err != nil {
		t.Fatal(err)
	}

	// Things to point the calls at.
	pick := func(sql string, args ...any) string { return d.value(t, sql, args...).(string) }
	middle := pick(`SELECT id::text FROM public.item ORDER BY name COLLATE public.natural, id OFFSET $1 LIMIT 1`, n/2)
	room := pick(`SELECT id::text FROM public.location WHERE name = 'Room 1'`)
	group := pick(`SELECT id::text FROM public.class WHERE name = 'Group 1'`)
	return perfData{
		at:         at,
		middle:     middle,
		middleCode: pick(`SELECT util.code_text(code) FROM public.item WHERE id = $1`, middle),
		group:      group,
		leaf:       pick(`SELECT id::text FROM public.class WHERE parent = $1 ORDER BY name LIMIT 1`, group),
		room:       room,
		shelf:      pick(`SELECT id::text FROM public.location WHERE parent = $1 ORDER BY name LIMIT 1`, room),
		lot:        pick(`SELECT substr(min(values ->> 'Lot'), 1, 6) FROM public.stock WHERE values ? 'Lot'`),
		loads:      loads,
	}
}
