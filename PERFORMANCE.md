# Performance

How fast the functions the API calls are, on tenants of 1,000 to 200,000 items, and what was changed to get there. The figures come from `TestPerformance` (see the README, "Running the integration tests"). It calls the functions directly in the database, as `wtfd serve` does, so HTTP and JSON encoding in Go are not included.

**Measured 2026-11-01** on `wtf_test` (PostgreSQL 18.6, default settings) from the development PC, after dropping "mark as deleted" and history. Each read and write is run once to warm up, then 7 times; the tables give the median.

## The tenant

Each size has the same shape, scaled to the number of items:

- 10 class groups with leaves under them (500 classes at most), with 4 attributes (a length, a weight, a note and a colour choice) and a serial on group 1's stock;
- 10 rooms with shelves under them (510 locations at most);
- every item with 4 values and 2 stock rows, and a serial on each stock row of group 1.

At 200,000 items, that is 400,000 stock rows and 800,000 item values.

## Results

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

## With another large tenant

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

## What was changed

The first run, at 1,000 items, took 2.4–2.7 s for every filtered or searched `item.list` and 150 ms for a plain page. Four changes brought that to the figures above:

1. **JIT compilation is off in every API function** (`SET jit = off`, next to the `search_path`). The planner over-estimates functions that return rows, so the queries' estimated cost passed PostgreSQL's limit for compiling them, and compiling cost 2.4 s per call. These queries are short, so they gain nothing from it.
2. **`item.list` matches filters and words by joining,** not with a subquery per candidate item. Each filter row is numbered; an item passes when it matches as many filters as there are. A word matches when it is found in the item's name, a class in its path, or a text or choice value it shows; an item passes when it has every word. Each value is looked at once, where before it was looked at once per candidate, which grew with the square of the tenant.
3. **The page is a plain `ORDER BY … LIMIT`,** without the `row_number()` that numbered the rows for the answer. PostgreSQL then sorts it as a top-N, keeping only the rows up to the page's end, instead of sorting every match.
4. **`stock.list` sorts and counts only the stock ids and item names,** and reads the full rows for the page alone.

## What is still slow

- **Search reads every value the tenant's items show** (`strpos` on each), because a search finds part of a word, which no ordinary index can. `TODO.md` has the fix: a stored search text per item with a trigram index. It is the largest gain left.
- **Filters read every value of the filtered attributes,** for the same reason, and an index per kind of value would be needed to avoid it.
- **Every list counts all its matches** for the total. With no filter, that is the whole tenant.
- **A page far down the list costs more than the first:** the sort keeps every row up to the page's end (387 ms in the middle of 50,000 items, against 89 ms for the first page).
- **A recursive delete's dry run** lists everything it would delete: 2 s for a room of 40,000 stock rows.
- **Loading through the API is one call per row**, at about 0.5 ms per row in the database. An import of 200,000 items would take some minutes.

For a household or a small business (some thousands of items), every call is under 200 ms. At 50,000 items, search and filters approach a second.
