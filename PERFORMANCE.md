# Performance

How fast the functions the API calls are, measured with `TestPerformance` (see the README, "Running the integration tests"). It calls the functions directly in the database, as `wtfd serve` does, so HTTP and JSON encoding in Go are not included. Each read and write is run once to warm up, then 7 times (class changes 3 times); the tables give the median, in milliseconds.

## Attributes in JSON, and no tenants

**Measured 2026-11-02** on `wtf_test` (PostgreSQL 18.6, default settings) from the development PC, after the rewrite of [2026-11-02-attributes-in-json.md](2026-11-02-attributes-in-json.md), with 1,000 to 1,000,000 items.

### The data

Each size has the same shape, scaled to the number of items:

- 10 class groups with leaves under them (500 classes at most), each group with 4 item attributes (a length, a weight, a note and a colour choice), and group 1 with a stock attribute, a lot number;
- 10 rooms with shelves under them (510 locations at most);
- every item with 4 values and 2 stock rows, each stock row with a serial, and those of group 1 with a lot number.

At 1,000,000 items, that is 2,000,000 stock rows. The rows are loaded with set-based statements, as the accessors would write them: 1,000,000 items in 83 s, 2,000,000 stock rows in 145 s.

### Results

| Operation | 1k | 10k | 100k | 1M | at 1M |
|---|---:|---:|---:|---:|---|
| `item.list`, first page | 9 | 6 | 7 | 7 | 100 rows, more |
| `item.list`, a page in the middle | 8 | 10 | 7 | 10 | |
| `item.list`, a class group (a tenth) | 8 | 6 | 8 | 10 | |
| `item.list`, a number filter (half pass) | 8 | 12 | 7 | 14 | |
| `item.list`, two filters (1 in 100 pass) | 11 | 119 | 147 | 143 | |
| `item.list`, a filter nothing passes | 9 | 104 | 1214 | 17939 | reads all |
| `item.list`, a stock value filter | 9 | 95 | 1126 | 832 | |
| `item.list`, search of one word | 2 | 10 | 24 | 24 | |
| `item.list`, search of two words | 7 | 6 | 8 | 8 | |
| `item.list`, search matching a class | 7 | 6 | 7 | 8 | |
| `item.list`, a search nothing matches | 2 | 6 | 83 | 1108 | reads all |
| `item.get`, `code.resolve` | 1–2 | 1 | 1–2 | 1–2 | |
| `stock.list`, one item | 2 | 2 | 2 | 2 | |
| `stock.list`, a room (a tenth) | 10 | 18 | 12 | 14 | |
| `stock.list`, all, first page | 14 | 9 | 9 | 12 | |
| `stock.list`, a serial nothing has | 6 | 40 | 522 | 12987 | reads all |
| `class.list`, `location.list` (the trees) | 2 | 4 | 13–17 | 13–19 | 500 nodes |
| `class.delete_tree`, dry run of a group | 7 | 27 | 286 | 2806 | 100,000 items |
| `location.delete_tree`, dry run of a room | 12 | 88 | 1019 | 9963 | 200,000 stock rows |
| writes (create, patch with values, move, merge, delete) | 3–7 | 3–8 | 4–8 | 3–8 | |
| class change: an optional attribute added to a group | 6 | 10 | 14 | 14 | no rows |
| class change: a default added (checks the group's items) | 41 | 289 | 2734 | 27845 | 100,000 checked |
| class change: a required attribute with a default | 46 | 340 | 3187 | 37408 | 100,009 rewritten |
| class change: an attribute renamed | 8 | 42 | 434 | 5168 | 100,009 rewritten |
| a group renamed and back (search texts) | 85 | 651 | 6002 | 70482 | 2 × 100,009 rewritten |

The class changes are dry runs, which do all the work and then undo it.

### What it shows

- **Pages, single reads and writes don't grow with the data:** 1–15 ms at 1,000 and at 1,000,000 items, where the old design took 300 ms for a first page at 200,000 items, and 1–4 s for a filter or a search. Paging by key, without a total, reads only as many items as the page needs, in name order.
- **What few items pass reads more of them:** a filter or a search that passes 1 item in 100 still takes 100–150 ms at 1,000,000 items, as the page fills after about 10,000 items. One that nothing passes reads every item: 1.1 s for a search, 18 s for a filter. The search text is a column of its own, so search is the cheaper of the two. The indexes for these were left out for now ([2026-11-02-attributes-in-json.md](2026-11-02-attributes-in-json.md), decisions 28 and 33).
- **A filter on a stock value** looks at an item's stock rows for every item it reads: about 1 s at 100,000 items and more.
- **A serial number** is found by reading the stock rows: 13 s at 2,000,000 of them. An index on `stock (serial)` was left out for now (decision 29).
- **Class changes cost what they rewrite,** as decided: an optional attribute costs nothing below the class, and one that rewrites 100,000 items about 37 s. A rename of a class rewrites the search texts of its items: 35 s for 100,000. Item writes in that class wait while it runs (TODO.md).
- **The trees** are read whole: 13–19 ms for 500 nodes.

## Before: tenants, and values in rows of their own

The measurements of 1 November 2026, of the design before the rewrite: each value a row of its own, units, and tenants.

### The tenant

Each size has the same shape, scaled to the number of items:

- 10 class groups with leaves under them (500 classes at most), with 4 attributes (a length, a weight, a note and a colour choice) and a serial on group 1's stock;
- 10 rooms with shelves under them (510 locations at most);
- every item with 4 values and 2 stock rows, and a serial on each stock row of group 1.

At 200,000 items, that is 400,000 stock rows and 800,000 item values.

### Results

Median times in milliseconds.

| Operation | 1k | 10k | 50k | 200k |
|---|---:|---:|---:|---:|
| `item.list`, first page | 19 | 36 | 89 | 304 |
| `item.list`, a page in the middle | 16 | 36 | 387 | 403 |
| `item.list`, a class group (a tenth) | 15 | 25 | 31 | 76 |
| `item.list`, a number filter | 20 | 73 | 281 | 1036 |
| `item.list`, two filters | 19 | 110 | 496 | 2083 |
| `item.list`, a stock value filter | 12 | 35 | 125 | 411 |
| `item.list`, search of one word | 22 | 142 | 678 | 2833 |
| `item.list`, search of two words | 29 | 188 | 903 | 3969 |
| `item.list`, search matching a class | 28 | 164 | 798 | 3439 |
| `item.get` | 6 | 3 | 3 | 4 |
| `code.resolve` | 3 | 3 | 3 | 4 |
| `stock.list`, one item | 3 | 3 | 3 | 3 |
| `stock.list`, a room (a tenth) | 11 | 26 | 55 | 225 |
| `stock.list`, all, first page | 13 | 63 | 272 | 656 |
| `class.list`, the tree | 2 | 3 | 14 | 14 |
| `location.list`, the tree | 2 | 5 | 20 | 20 |
| `class.delete_tree`, dry run of a group | 7 | 31 | 123 | 526 |
| `location.delete_tree`, dry run of a room | 12 | 86 | 471 | 1985 |
| `item.create`, 4 values | 6 | 7 | 13 | 16 |
| `item.patch`, name | 4 | 4 | 5 | 6 |
| `stock.move`, a part | 6 | 6 | 5 | 6 |
| `stock.merge`, a part | 3 | 4 | 3 | 4 |
| `item.create` + `item.delete` | 9 | 9 | 10 | 10 |

The classes and locations stop growing at 50,000 items (500 and 510), so the trees take the same time at 50k and 200k.

**Writes and single reads stay flat:** 3–16 ms at every size. **Lists grow with the tenant,** about linearly, as each one reads every match to count and sort it. **A filter or search on 200,000 items takes 1–4 seconds.**

**Loading goes through the rules,** one statement per kind of row: about 0.6 ms per item or stock row, and 0.35 ms per value. 200,000 items took 11 minutes to load.

### With another large tenant

The same sizes again, the second time alongside another tenant of 200,000 items (with its 400,000 stock rows and 800,000 values), loaded first and kept for the whole run. Each size's tenant is deleted after it is timed, so the first series had the database to itself. Median times in milliseconds, measured the same evening:

| Operation | 1k alone | 1k with | 10k alone | 10k with | 50k alone | 50k with | 200k alone | 200k with |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `item.list`, first page | 20 | 34 | 34 | 46 | 83 | 104 | 291 | 327 |
| `item.list`, a class group | 14 | 42 | 23 | 45 | 28 | 59 | 70 | 107 |
| `item.list`, a number filter | 19 | 37 | 72 | 85 | 266 | 289 | 984 | 1028 |
| `item.list`, two filters | 18 | 36 | 104 | 128 | 422 | 516 | 1702 | 1727 |
| `item.list`, search of one word | 21 | 39 | 137 | 154 | 578 | 681 | 2585 | 2582 |
| `stock.list`, a room (a tenth) | 11 | 29 | 25 | 95 | 48 | 184 | 181 | 323 |
| `stock.list`, all, first page | 12 | 31 | 33 | 56 | 138 | 272 | 614 | 744 |
| `class.delete_tree`, dry run of a group | 8 | 24 | 31 | 44 | 119 | 139 | 508 | 541 |
| `item.get`, `code.resolve` | 3–7 | 3–6 | 3 | 3 | 3 | 4 | 3 | 4 |
| the trees, `class.get`, `attribute.list` | 1–3 | 1–4 | 1–5 | 1–5 | 1–21 | 1–21 | 1–21 | 1–21 |
| writes | 2–9 | 2–10 | 2–10 | 2–10 | 2–13 | 2–16 | 2–14 | 2–16 |
| loading 1,000 items, per row (items, stock, values) | 0.36, 0.36, 0.09 | 0.50, 0.51, 0.21 | | | | | | |
| loading 200,000 items, per row | | | | | | | 0.46, 0.50, 0.18 | 0.58, 0.59, 0.28 |

- **Single reads, the trees and writes don't change.** They find their rows by index.
- **Every list costs a small tenant about 15–30 ms more,** whatever it lists: at 1,000 items, lists go from 11–29 ms to 29–48 ms. The extra is about the same at every size, so it matters most to small tenants and is lost in the noise at 200,000 items. It looks like a fixed scan of something the size of the whole database; which part of the plan does it isn't found yet.
- **`stock.list` of a location's subtree is hit hardest:** 4 times slower at 10,000 and 50,000 items (25 to 95 ms, 48 to 184 ms). The planner probably reads all the stock rows of the database, not the subtree's, once the table is large; not confirmed.
- **Loading is 25–130 % slower** with the neighbour, the values most: the rules' checks are slower on larger tables.

The first series repeats the first run within about 10 % (lower where the first run had the smaller sizes' tenants left in the database).

### What was changed

The first run, at 1,000 items, took 2.4–2.7 s for every filtered or searched `item.list` and 150 ms for a plain page. Four changes brought that to the figures above:

1. **JIT compilation is off in every API function** (`SET jit = off`, next to the `search_path`). The planner over-estimates functions that return rows, so the queries' estimated cost passed PostgreSQL's limit for compiling them, and compiling cost 2.4 s per call. These queries are short, so they gain nothing from it.
2. **`item.list` matches filters and words by joining,** not with a subquery per candidate item. Each filter row is numbered; an item passes when it matches as many filters as there are. A word matches when it is found in the item's name, a class in its path, or a text or choice value it shows; an item passes when it has every word. Each value is looked at once, where before it was looked at once per candidate, which grew with the square of the tenant.
3. **The page is a plain `ORDER BY … LIMIT`,** without the `row_number()` that numbered the rows for the answer. PostgreSQL then sorts it as a top-N, keeping only the rows up to the page's end, instead of sorting every match.
4. **`stock.list` sorts and counts only the stock ids and item names,** and reads the full rows for the page alone.

### What is still slow

- **Search reads every value the tenant's items show** (`strpos` on each), because a search finds part of a word, which no ordinary index can. `TODO.md` has the fix: a stored search text per item with a trigram index. It is the largest gain left.
- **Filters read every value of the filtered attributes,** for the same reason, and an index per kind of value would be needed to avoid it.
- **Every list counts all its matches** for the total. With no filter, that is the whole tenant.
- **A page far down the list costs more than the first:** the sort keeps every row up to the page's end (387 ms in the middle of 50,000 items, against 89 ms for the first page).
- **A recursive delete's dry run** lists everything it would delete: 2 s for a room of 40,000 stock rows.
- **Loading through the API is one call per row**, at about 0.5 ms per row in the database. An import of 200,000 items would take some minutes.

For a household or a small business (some thousands of items), every call is under 200 ms. At 50,000 items, search and filters approach a second.
