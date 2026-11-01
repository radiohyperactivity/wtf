# To do

Things to come back to later.

- **Is the Units screen needed?** The app's Manage → Units lists every quantity, unit family and unit (grouped by quantity since `828a2c2`). Units are already chosen through the unit picker and the menu next to number fields, so the screen may be unnecessary.
- **Model files: the decisions made while you were away,** in [seed/model-format.md](seed/model-format.md), "Decisions to discuss" (unit files are part of model files now).
- **Exporting units on their own,** from the Units screen, and the whole class tree at once. An export is of one class for now, with the units its attributes need.
- **Linux beyond the `.deb`:** a Flatpak on Flathub, so Linux users other than Debian and Ubuntu can install WtF, or at the very least detailed instructions for building and installing it yourself. Flathub builds from source without network access, which for Flutter means listing every Dart package and the SDK in advance.
- **Uploads and `wtfd gc` keep out of each other's way through an advisory lock keyed by the file's hash** (`file_lock_key`: the hash's first 16 hex digits read as a bigint). It works, but it's a poor solution to the problem; find a better one. Noted in the database refactor's review (2026-10-31-database-refactor.md, R11).
- **Choice options in the apps need another way of being shown.** With many options (100 or more), the list of every option on screen is unusable. A drop-down that can be searched, and that can pick several where a filter takes several (`in`), is likely the way.

## Potential performance improvements

Not needed now; for when something measurably gets slow.

- **A table of each class's effective attributes,** kept current by triggers when assignments change or classes move. Reads of a class's attributes (item and stock screens, lists, search) would be a plain join, with no walk up the class tree. Today one recursive query per request does it (database refactor, decision 34), and a stored copy would have to be kept right by every change to the model.
- **A table of each class's ancestors** (class, ancestor, depth), kept current when classes move: every walk up the class tree becomes one index look-up, including the rules that check one value as it's written. Moves get slower.
- **A trigram index on item names and values** (`pg_trgm`, an extension), for searching by part of a word, which no ordinary index can do.
- **A stored search text per item** (its name, class path and shown text and choice values, kept current by triggers), with a trigram index on it: a search would read only the items that match, where today it reads every shown value of the tenant's items (measured 0.7–0.9 s for 50,000 items and 2.8–4 s for 200,000; see PERFORMANCE.md).
