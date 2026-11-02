# Attributes in JSON – plan

**Status: being rewritten (2026-11-02); decisions 1–49 settled.** The schema, the accessors and `wtfd` were written for decisions 1–35 before tenants were dropped (decisions 36–42), and now change for those too. The CLI's commands are decisions 44–48.

## How we work

As for the refactor: decisions written down here first, and no rewrites until the plan is complete. **No index is created without its reason written here and your approval** (decision 13).

## Why

The performance test (`PERFORMANCE.md`) showed how today's design scales:
- a filter or search on 200,000 items takes 1–4 seconds;
- every list counts all its matches;
- a small tenant's lists cost 15–30 ms more next to a large one.

Most of the schema's complexity comes from one choice: every value is a row of its own (`item_value`, `stock_value`), with typed columns, units and the rules that check them.

The aims:
- **Much less complexity.**
- **Reads that stay fast with tens or hundreds of millions of rows in the database.**
- **The cost of an operation inversely proportional to how often it happens.** Searching and showing are the most frequent, so they must be very cheap. Changing a class's attributes is rare, so it may be expensive: it may rewrite every item or stock row below the class.

This breaks some of the principles the refactor followed. The rules move from triggers to the accessors, and values lose their foreign keys. That is accepted here.

## Why now

- **Nothing is live, and no data is kept** *(yours)*. The schema starts again, fresh and empty, as revision 1 did: `0001_schema.sql` changes in place, `0002_units.sql` goes, and nothing is migrated.
- **The apps haven't moved to the new API yet,** so they change only once.

## What it is today

Measured on `main` at `01fce1b`.

- **The schema:** 19 tables. 11 of them go in this plan:
  - `attribute`, `attribute_option`, `class_attribute`;
  - `item_value`, `stock_value`;
  - `attachment`;
  - `quantity`, `unit_family`, `unit`, `tenant_quantity`, `tenant_unit_family`.

  Left are `tenant`, `account`, `session`, `class`, `item`, `location`, `stock` and `data_version`.
- **The functions:** 191 in `db/repeatable/` (6,889 lines), with 68 triggers.
  - Three files go almost whole: `21_unit.sql` (889 lines), `30_attribute.sql` (620) and `13_attachment.sql` (368).
  - `42_item.sql`, `41_stock.sql`, `31_class.sql` and `60_model.sql` are rewritten.
  - `0002_units.sql` (199 lines) and `seed/units.json` go.

## Decisions

### The model

1. **A class holds all its attributes in one JSON column, `class.attributes`, inherited ones included** *(yours)*.
   - Each entry names the class that defines it (`"class": "<id>"`). The class's own attributes are the entries that name it, so nothing is stored twice.
   - Changing a class rewrites the `attributes` of the classes below it.
   - An item write reads one class row and walks no tree.
2. **The class hierarchy stays** *(yours)*.
3. **An attribute is keyed by its name** *(yours)*. Item and stock rows store values under the attribute's name, so a row stands alone, without its class. A rename rewrites the rows of the attribute's kind (items or stock) below the class.
4. **A class can't define a name it inherits** *(yours)*. There is no overriding: adding the name, or moving a class under one that has it, is refused.
5. **An attribute belongs to its class and the classes below it** *(yours)*.
   - Two unrelated classes don't share one: their "Length" attributes are separate.
   - A filter across both works only if the attribute is defined on a common parent, and if that matters, the user makes one.
6. **An attribute's definition** is an object with these fields:
   - `class`, `scope` (`"item"` or `"stock"`), `type`, `required`, `default`, `unit` (free text, only a label) and `order`, the position on screen, counted separately within items and stock;
   - for a choice, `choices`, a list of texts;
   - for an attachment, optionally `media`, the allowed media types.

   No validation beyond the type: no ranges, no patterns *(yours)*. An example:

   ```json
   {
     "Length": {"class": "<id of Tools>", "scope": "item", "type": "decimal",
                "unit": "mm", "required": true, "default": 100, "order": 1},
     "Colour": {"class": "<id of Tools>", "scope": "item", "type": "choice",
                "choices": ["Red", "Green", "Blue"], "default": "Red", "order": 2},
     "Manual": {"class": "<id of Drills>", "scope": "item", "type": "attachment",
                "media": ["application/pdf"], "order": 3},
     "Bought": {"class": "<id of Tools>", "scope": "stock", "type": "date", "order": 1}
   }
   ```
7. **The types** are today's `text`, `integer`, `decimal`, `date`, `boolean`, `url` and `choice`, plus `attachment`. In the JSON:
   - numbers are JSON numbers, which PostgreSQL keeps exactly;
   - a date is a string, `"2026-11-02"`;
   - a choice is its text;
   - an attachment is its file's hash.
8. **An item's values are a plain map, in `item.values`** *(yours)*: `{"Length": 100, "Colour": "Green", "Manual": "9f86d081…"}`.
   - An attribute with no value is left out, and null isn't stored.
   - Every value is stored, defaults included, so that the row stands alone and search sees them.
9. **Values that follow the class's default are named in `item.defaulted`, a column of its own (`text[]`)** *(yours)*.
   - A new item gets the defaults of the attributes it isn't given, and they go on that list.
   - Setting a value by hand takes it off the list, even when it equals the default. "Back to the default" is an explicit action.
   - When a default changes, the rows that follow it are rewritten.
10. **Stock has values and defaults the same way,** `stock.values` and `stock.defaulted`, for the attributes with `"scope": "stock"` *(yours)*.

### Checking

11. **The accessors check values on every insert and update; no triggers do** *(yours)*. An item or stock write takes a share lock on its class row, so that a class change, which takes an update lock on its subtree's class rows, can't slip past a write.
12. **A class change is checked against every item and stock row below it** *(yours)*. What each change costs:

    | Change | Cost |
    |---|---|
    | Adding an optional attribute | the subtree's class rows only |
    | Adding a required attribute with a default | rewriting the rows of its kind that lack it, with the default, marked as defaulted |
    | Adding a required attribute without a default | refused while the subtree has rows of its kind |
    | Renaming an attribute | rewriting the rows of its kind |
    | Changing a default | rewriting the rows that follow it |
    | Making it required | refused if a row lacks it, unless a default fills them |
    | Changing its type | **refused** *(yours)*: remove it and add it again |
    | Adding a choice | the class rows only |
    | Renaming a choice | rewriting the rows that have it |
    | Removing a choice | **refused while a row uses it** *(yours)* |
    | Removing an attribute | rewriting the rows to drop it |
    | Moving a class to another parent | its subtree's class rows, then checking the subtree's rows against what it now inherits |
    | Moving an item to another class | checking that one item and its stock rows |

### Indexes and lists

13. **No index is created without a reason written here and your approval** *(yours)*. The proposals are in "Indexes, for approval".
14. **Indexes are made with the schema, not by API actions** *(yours)*. So a range filter ("Length > 50") reads, at worst, all the tenant's items or stock rows. That is accepted for now *(yours)*.
15. **Lists give no total** *(yours)*. A page says only whether more follow. A way to ask for the total can come later, if it's needed.
16. ~~**Item and stock rows carry their tenant,** `item.tenant` and `stock.tenant` *(yours)*. Every index on them can lead with it, so a tenant's queries never read another tenant's rows.~~ Replaced by decision 36: there are no tenants.

### Units, files and fixed fields

17. **Quantities and units go** *(yours)*. An attribute's `unit` is free text, only a label. Nothing converts, and the user keeps to the unit.
18. **Files**
    - **An attachment is an attribute of type `attachment`, holding one file** *(yours)*. Only the attachments a class defines can be uploaded. The `attachment` table goes, and with it the attachments of locations and classes.
    - **The value is only the file's hash** *(yours)*:
      - the size is read from the file;
      - the name is the attribute's, with an extension for its type;
      - the media type is found from the file's first bytes, at upload and when serving.

      Sniffing can't tell some formats apart: Word and Excel files are ZIP archives to it, and CSV is plain text. That is accepted for now.
    - **Item and stock each get an optional photo,** a column of their own *(yours)*. Locations have none *(yours)*.
    - **A tenant's files stay in a directory named after its host** *(yours)*, as today (`internal/files/store.go`). Renaming a tenant moves the directory. `wtfd gc` finds the files in use by reading the hashes in `values` and the photo columns. That is a scan, but `gc` is rare.
19. **Stock gets two fixed, optional text columns, `reference` and `serial`** *(yours)*. Neither is unique *(yours)*.
20. **No data is carried over** *(yours)*: see "Why now".

### Settled from the open topics

21. **Items keep a unit, as a free-text label, `item.unit`** *(yours)*. Topic A. Stock amounts are stored as entered ("12.5" with the item's unit "m"); nothing converts.
22. **Classes lose their photo, and keep `container`** *(yours)*. Topic B.
23. **Lists page by key** *(yours)*. Topic D. A page asks for "the 100 after this name and id"; the API's `offset` goes, and `after` takes its place.
24. **Attributes are changed through class functions** *(yours)*. Topic E.
    - The functions: `class.attribute_add`, `_change`, `_rename`, `_remove`, `_choice_add`, `_choice_rename` and `_choice_remove`.
    - Each answers what it changed ("rewrote 12,040 items"), and has a dry run.
25. **The database keeps foreign keys, `NOT NULL` and `CHECK`; the triggers go** *(yours)*. Topic F. The checks for cycles and depth in the trees move to the move functions.
26. **A merge of stock rows that differ asks how to resolve each difference** *(yours)*. Topic H.
    - This covers every field: `reference`, `serial`, the photo, and each value in `values`.
    - A merge with differences and no resolution is refused, with the list of fields that differ.
    - The client asks the user, then sends the merge again with which side wins for each one.
27. **Emails are stored in lower case** *(yours)*. Index I-2. The accessors lower them, and a `CHECK (email = lower(email))` holds it. The unique index is then on `(tenant, email)`.
28. **No search index for now** *(yours)*. Index I-7. No `pg_trgm` and no `btree_gin`.
29. **No index on `stock.serial`** *(yours)*. Index I-11. Finding a stock row by serial reads the tenant's stock rows.
30. **Approved indexes** *(yours)*: I-1, I-2 (as decision 27), I-5, I-9 and I-10.
31. **Model files stay, simplified** *(yours)*. Topic G.
    - A file is the class tree, with each class's own attributes in the same JSON as `class.attributes`, without the class ids. The units section goes.
    - Importing new classes costs almost nothing.
    - Importing under or into existing classes is checked as a class change.
32. **Sibling names are unique through `(parent, tenant, lower(name))`, for classes and for locations** *(yours)*. Indexes I-3 and I-4.
    - Parent comes first: the same index serves the top-level classes (`parent IS NULL AND tenant = …`), the children of a class, a child by name, and PostgreSQL's own check before deleting a parent.
    - Nulls count as equal, so top-level siblings are unique too.
    - Today's separate `class (parent)` and `location (parent)` indexes go.
    - Locations also keep `(tenant, code)`, unique.
33. **No GIN index on `values` for now** *(yours)*. Index I-8. Equality filters read the tenant's rows, as range filters and search do. The performance test on large tenants will show whether GIN, and `btree_gin` with it, earns its place.

34. **Search reads one text column per item, `item.search`, with no index** *(yours)*. Topic C.
    - **What it holds:** in lower case, the item's name, the names of the classes in its path, and its text, URL and choice values. Numbers and dates are left out; filters handle them.
    - **Who writes it:** the accessors, whenever an item is created or changed.
    - **When it's rewritten in bulk:** when a class is renamed or moved (its subtree), and when an attribute or a choice is renamed.
    - **How a search matches:** every word must appear somewhere in the text (`strpos`), so "anan" finds "banana", whatever the word's length.
    - **What it reads:** the tenant's items, in name order (index I-6), stopping at the page's last match plus one. A common word stops early; a rare one reads the whole tenant.
    - Stock is searched the same way, by `reference` and `serial`.
35. **The list index is `item (tenant, name COLLATE public.natural)`, without the id** *(yours)*. Index I-6. PostgreSQL reads it in order and sorts by id only within a group of equal names. The id can be added later without changing a query.

### Dropping tenants

Decided after decisions 1–35, and done in the same rewrite *(yours)*. Where an earlier decision speaks of a tenant, this section says what it becomes.

36. **No tenants** *(yours)*. One database is one installation: its accounts, classes, locations, items and stock. The `tenant` table and every `tenant` column go (`account`, `class`, `location`, `item`, `stock`, `data_version`), with the tenant filter in every query. This replaces decision 16; "the tenant's rows" in decisions 14, 29, 33 and 34 become "all the rows".
37. **The installation's own data is in one row, `public.meta`** *(yours)*. It has the label code counter, `code`, that `tenant.code` had, and gets more columns as they are needed. The counter stays an `UPDATE` of that row, not a sequence: a sequence leaves gaps when a transaction rolls back, and 410 Gone relies on every code up to the counter having been used (the previous plan's decision 5). The table is in schema `public`; the function schema `meta` is another thing.
38. **Several installations are several databases, each with its own `wtfd`** *(yours)*. A request's hostname no longer picks anything, so `public.request` loses its host, and `wtfd` its host routing.
39. **An email address is unique in the database** *(yours)*. The unique index is on `account (email)` (decision 27, without the tenant).
40. **Files are stored straight in the files directory,** with no directory per host *(yours)*. This replaces the per-host part of decision 18; deleting an installation's files is deleting its files directory.
41. **The CLI's profiles have the server's address only** *(yours)*, with no host to pick a tenant.
42. **`wtfd tenant` goes,** and `wtfd account create` loses `--host`. TENANTS.md goes; what of it still matters (the label codes, the files directory) moves to WTFD.md and API.md. The tests of tenant isolation, and the performance test's second tenant, go too.

### Values in one change, and the CLI

43. **An attribute can't be named after a fixed field** *(yours)*: `id`, `code`, `name`, `class`, `unit`, `photo`, `item`, `location`, `amount`, `reference` or `serial`, letter case ignored, for item and stock attributes alike. Then a name means one thing everywhere: in the JSON, in filters, in `wtf file put <item> photo`, and as a CLI flag (decision 45).
44. **A patch of an item or a stock row changes its values too, in one transaction** *(yours)*: `PATCH /items/{id}` (and `/stock/{id}`) takes `"values": {"Colour": "Blue", "Length": null}` (null removes a value) and `"default": ["Size"]` (back to the class's default), beside its fixed fields. The routes and functions for one value (`value_set`, `value_delete`, `value_default`, for items and stock) go.
45. **In the CLI, an attribute is a flag of its own** *(yours)*: `--colour Blue` sets "Colour", `--no-colour` removes it, and `--default colour` (as often as needed) puts it back to the default. Letter case is ignored and a hyphen stands for a space (`--supply-voltage` is "Supply voltage"); a flag that would match two attributes is refused, saying which. An attribute whose name is one of the CLI's own flags (`--json`, `--yes`, `--edit`, `--dry-run`, `--all`, `--profile`, …) is set with `--value NAME=V`. This goes for `item add`, `item set`, `stock add` and `stock set`.
46. **A class's attributes are changed with `wtf class attribute add|set|rename|remove` and `wtf class choice add|rename|remove`** *(yours)*. `add` takes `--type`, `--stock` (a stock attribute), `--unit`, `--required`, `--default`, `--choices A,B,C` and `--media TYPES`; `set` takes `--required yes|no`, `--default V` or `--no-default`, `--unit U` or `--no-unit`, `--media TYPES` or `--no-media`, and `--order N`. Each takes `--dry-run`, and says what it wrote ("Rewrote 1,204 items"); `remove` asks first on a terminal, as deletes do. The groups `attribute`, `option`, `attachment`, `quantity`, `units` and `unit-family` go.
47. **Files are `wtf file put|get <item or stock row> <attribute or photo> FILE`** *(yours)*.
48. **Lists show the first page and say when more follow; `--all` follows the pages to the end** *(yours)*. `stock merge` asks for each difference on a terminal, and takes `--keep FIELD=from|into` in scripts. `stock move` and the commands not named here stay as they are, but for values, paging and tenants.

49. **The trees' versions are in the meta row,** `meta.class_version` and `meta.location_version`, and `data_version` goes *(yours)*. With one installation they are two numbers. The meta row also hands out label codes, so a change of a tree moves its version on last, after any rewriting of rows: the row stays locked until commit, and new items, stock rows and locations wait for it only that long.

## Topics

All settled; the decisions above say how. Kept as they were proposed.

- **A. Item units.**
  - Today an item can have a unit (`item.unit`), and its stock amounts are stored in it ("12.5 m of cable").
  - Recommended: a free-text `item.unit`, a label like the attributes' `unit`, with amounts stored as entered.
- **B. Class photos and container classes.**
  - Today a class can have a photo (one of its attachments), and a "container" class holds only other classes.
  - Recommended: drop the class photo, as a class has no files any more, and keep `container`.
- **C. Search.**
  - Recommended: one column, `item.search`, written by the accessors. It holds, in lower case, the item's name, its class path, and the text and choice values it shows.
  - A search then reads only that column, through an index (see I-7).
  - Renaming a class or moving it rewrites its subtree's search texts: expensive, but rare.
  - For stock: a search of `reference` and `serial`, and filters on `stock.values`.
- **D. Paging by key.**
  - Recommended: a page asks for "the 100 after this name and id", not an offset. Every page then costs what the first does; a page in the middle of 50,000 items costs 4 times the first today.
  - The API's `offset` goes, and an `after` takes its place.
- **E. Changing classes through the API.**
  - With attributes inside the class, the `attribute.*` functions become class functions: `class.attribute_add`, `_change`, `_rename`, `_remove`, `_choice_add`, `_choice_rename` and `_choice_remove`.
  - Each answers what it changed, for example "rewrote 12,040 items".
  - A dry run, as for recursive deletes, says what a change would do.
- **F. The rules that stay in the database.**
  - Recommended: foreign keys, `NOT NULL` and `CHECK` stay; the triggers go.
  - Today's trees check for cycles and depth with triggers; that moves to the move functions, which are the only way to change a parent.
- **G. Model files** (`seed/model-format.md`, `60_model.sql`).
  - Recommended: a model file becomes the class tree with each class's own attributes, as they are stored.
  - The units section goes; importing checks, as a class change does.
- **H. Merging stock** (decision 6 of the last plan). "The same values" becomes `values` and `defaulted` being equal, plus the same `reference` and `serial`. Should a merge also require the same photo?

## Indexes

Approved, as decisions 36–39 change them:

| # | Index | Reason |
|---|---|---|
| I-1 | ~~`tenant (host)`~~ | gone with the tenants |
| I-2 | `account (email)`, unique (in lower case, decision 27); `session (account)` | logins, and the rule that an email is used once; deleting an account deletes its sessions |
| I-3 | `class (parent, lower(name))`, unique, nulls equal | sibling names; the top-level classes (`parent IS NULL`); children; the check before deleting a class (decision 32) |
| I-4 | `location (parent, lower(name))`, unique, nulls equal; `location (code)`, unique | as I-3; resolving a label |
| I-5 | `item (code)`, unique; `stock (code)`, unique | resolving a label |
| I-6 | `item (name COLLATE public.natural)` | a list page, a search and a filter read the items in order and stop after the page (decisions 34, 35) |
| I-9 | `item (class)` | a class's items, for class lists, class changes and the check before deleting a class |
| I-10 | `stock (item)`; `stock (location)` | an item's and a location's stock, and the checks before deleting either |

Declined, for now: I-7, a trigram index for search (decision 28); I-8, GIN on `values` (decision 33); I-11, `stock (serial)` (decision 29).

## Plan

On `main`, before the apps, in the same order as the refactor; each step kept working and tested as before.

1. **The schema** (`db/migrations/0001_schema.sql` rewritten in place; `0002_units.sql` and `seed/units.json` go):
   - `meta`, one row with the label code counter and the trees' versions (decisions 37, 49), in place of `tenant`;
   - `account` (email in lower case, unique) and `session`, without tenants; `data_version` goes (decision 49);
   - `class`: `attributes` (JSON) and `container`, with no photo;
   - `location`: no photo;
   - `item`: `code`, `class`, `name`, `unit` (text), `values`, `defaulted`, `search`, `photo` (a hash);
   - `stock`: `code`, `item`, `location`, `amount`, `reference`, `serial`, `values`, `defaulted`, `photo` (a hash);
   - `CHECK`s hold the shapes that need no other row: `values` is a JSON object, a photo is a SHA-256 in hex, an email is in lower case;
   - only the indexes above.
2. **The accessors** (`db/repeatable/`):
   - `21_unit.sql` and `30_attribute.sql` go, and `13_attachment.sql` shrinks to the uploads of attachment values and photos;
   - one function checks a values map against a class's attributes for items or stock, and fills in the defaults;
   - `31_class.sql` gains the attribute functions (decision 24), each rewriting what decision 12 says, with a count and a dry run;
   - `42_item.sql` writes `search`, and lists by key (decision 23), with search and filters as decisions 33 and 34 say; a patch changes values too (decision 44);
   - `41_stock.sql` merges with resolutions (decision 26);
   - `60_model.sql` reads and writes the new model files (decision 31);
   - the tree moves check for cycles and depth (decision 25);
   - no triggers.
3. **`wtfd`:**
   - the routes and `openapi.json` follow the functions: the attribute routes become class routes, units go, attachments become uploads to an item's or stock row's attribute, and photos are uploads of their own;
   - `wtfd unit` and its commands go;
   - `wtfd gc` reads the hashes in `values` and the photo columns.
4. **The CLI:** units go; attributes are changed with class commands; lists page with `after`; `stock merge` asks how to resolve each difference.
5. **The tests:**
   - the accessor tests replace the rules tests;
   - the API and CLI tests follow the changes;
   - the performance test is reshaped for the new schema and run as before, then at tens of millions of rows in the database, as far as the test database allows. The rows are loaded with set-based statements, which skip the accessors' checks.
6. **The documents:**
   - API.md and `api/*.md` (`attribute.md` and `attachment.md` rewritten);
   - SCHEMA.md, WTFD.md, CLI.md and the README;
   - `seed/model-format.md` and `seed/models/mcu.json`, with `seed/units.md` gone;
   - PERFORMANCE.md, with the new figures;
   - TODO.md, where the tables of effective attributes and class ancestors, and the stored search text, are now done or moot.
7. **The apps plan** follows: no units, attribute editing in the class screen, uploads per attachment attribute, merges that ask, and no totals.

## Log

- **2026-11-02:** started from the performance results with another tenant in the database; decisions 1–20 from our discussion; topics A–H and indexes I-1 to I-11 proposed.
- **2026-11-02:** topics A–H and the indexes settled (decisions 21–35); the plan written.
- **2026-11-02:** the schema, the accessors and `wtfd` written for decisions 1–35, with tests of the new accessors (all pass); then tenants dropped (decisions 36–42), to be done in the same rewrite; the CLI's commands proposed.
- **2026-11-02:** the CLI's commands settled (decisions 43–48), with the names of the fixed fields reserved and a patch that changes values.
