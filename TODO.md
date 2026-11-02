# To do

Things to come back to later.

- **Exporting the whole class tree at once** as a model file. An export is of one class for now.
- **Linux beyond the `.deb`:** a Flatpak on Flathub, so Linux users other than Debian and Ubuntu can install WtF, or at the very least detailed instructions for building and installing it yourself. Flathub builds from source without network access, which for Flutter means listing every Dart package and the SDK in advance.
- **Uploads and `wtfd gc` keep out of each other's way through an advisory lock keyed by the file's hash** (`file_lock_key`: the hash's first 16 hex digits read as a bigint). It works, but it's a poor solution to the problem; find a better one. Noted in the database refactor's review (2026-10-31-database-refactor.md, R11).
- **Choice options in the apps need another way of being shown.** With many options (100 or more), the list of every option on screen is unusable. A drop-down that can be searched, and that can pick several where a filter takes several (`in`), is likely the way.

## Potential performance improvements

Not needed now; for when something measurably gets slow ([PERFORMANCE.md](PERFORMANCE.md)).

- **A trigram index on `item.search`** (`pg_trgm`, with `btree_gin`), so that a search reads only the items that match; today it reads the items in name order until the page is full, all of them for a rare word ([2026-11-02-attributes-in-json.md](2026-11-02-attributes-in-json.md), decision 28).
- **A GIN index on `item.values` and `stock.values`** (`jsonb_path_ops`), so that an equality filter reads only the rows that match (decision 33).
- **An index on `stock.serial`,** if serial numbers are looked up often (decision 29).
- **Running a big class change in the background:** a change that rewrites millions of rows holds its class's lock for the whole of it, and writes of items in that class wait.
