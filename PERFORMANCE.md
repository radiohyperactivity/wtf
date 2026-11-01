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
