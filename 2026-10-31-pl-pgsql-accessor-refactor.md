# PL/pgSQL accessor refactor – plan

**Status: planned; principles confirmed, topics decided, functions reviewed.** Part 2 of 3, after the database model ([2026-10-31-database-refactor.md](2026-10-31-database-refactor.md)) and before the API ([2026-10-31-api-refactor.md](2026-10-31-api-refactor.md)).

## How we work

As for the database: no rewrites until the plan is complete, decisions written down here, and going back to an earlier part is fine.

## Principles

Confirmed.

1. **The accessors are the only way in.** The API's role can execute them and touch nothing else; each is `SECURITY DEFINER` and starts by checking who is calling (`util.require`).
2. **The tenant is the session's, always.** No accessor takes a tenant; every id it is given is checked against the session's tenant before it is used, joining to the nearest table that has `tenant` where the row has none (database decision 1).
3. **Reads are set-based** (database decision 34): a page is built in one query, or a fixed few, however many rows it has; nothing runs a query or walks a tree once per row.
4. **Static SQL.** No `EXECUTE format(…)`; a query names its tables, so it is checked when the function is made and planned once.
5. **Every name schema-qualified** (`public.item`, `class.effective_attributes`), with `SET search_path = pg_catalog, pg_temp`, so that nothing depends on the caller's search path and a `SECURITY DEFINER` function can't be led to someone else's table or function.
6. **Errors only through the `error` schema** (database decision 31), so the SQLSTATE each raises, and with it the HTTP status, is decided in one place.
7. **The rules stay in the database's triggers;** an accessor checks first only where it can give a clearer error, or must decide something a rule can't (which parent to restore with).

## The functions today

The repeatable scripts in `db/repeatable/`, run by `wtfd schema`: 83 API functions (`SECURITY DEFINER`, granted to the API role), and the `util` schema's helpers in `10_util.sql`. Described in [API.md](API.md) and [api/](api/).

Surveyed 2026-10-31: 185 functions in eleven scripts (5,334 lines).

| Script | API functions | Helpers (`util.`) |
|---|---|---|
| `10_util.sql` | – | 70 |
| `20_attribute.sql` (units, attributes, options) | 20 | 7 |
| `30_class.sql` | 9 | – |
| `35_model.sql` (model import and export) | 2 | 19 |
| `40_item.sql` (items, item values) | 8 | – |
| `50_location.sql` (locations, stock, stock values) | 16 | – |
| `60_meta.sql`, `70_code.sql` | 2 | – |
| `80_attachment.sql` | 6 | 2 |
| `90_account.sql` (login, sessions, accounts) | 11 | 2 |
| `95_history.sql` | 9 | 2 |
| **Total** | **83** | **102** |

The helpers are reviewed with the first API function that uses them; many fold into a query or go.

## Topics

To decide before the functions are reviewed one by one, in this order:

- **A. Shape:** ~~A1 where the API functions live~~ *(decision 1)*; ~~A2 their names~~ *(decision 2)*; ~~A3 the search path~~ *(decision 3)*.
- **B. Reads:** ~~B1 list pages in one query~~ *(decisions 4, 5)*; ~~B2 the class and location trees~~ *(decision 6)*; ~~B3 text search and attribute filters~~ *(decision 7)*; ~~B4 paging~~ *(decision 8)*; ~~B5 `incomplete`~~ *(settled by decision 4)*.
- **C. Writes:** ~~C1 deleting and restoring through `deletion` rows~~ *(decision 9)*; ~~C2 restoring an owner whose values refer to deleted attributes or options~~ *(decision 10)*; ~~C3 tenant checks for the tables without `tenant`~~ *(decisions 11, 12)*; ~~C4 `attribute_patch` without `datatype`~~ *(decision 13)*; ~~C5 `model_export`~~ *(decision 14)*.
- **D. Sessions:** ~~D1 logging in with a client and a lifetime, and the usage trail~~ *(decision 15)*; ~~D2 the user's sessions, and logging one out~~ *(decision 16)*; ~~D3 removing expired sessions~~ *(decision 17)*.
- **E. History:** ~~E1 grouping a call's entries~~ *(decision 18)*; ~~E2 finding an object's entries~~ *(decision 19)*.
- **F. Errors:** ~~F1 each error's SQLSTATE and HTTP status~~ *(decision 20)*.

Noted while planning the database, to take up here:

- **`util.history_page` counts every matching entry on every page** (`count(*)` before the `LIMIT`), so a long history costs a full count per page.
- ~~**Sessions (database decision 25)**~~: decisions 15 and 16.
- ~~**A call's history entries are grouped by `transaction`**~~: decision 18.
- ~~**`model_export` locks the class it exports**~~: decision 14.
- **Reads that work once per row (database decision 34).** Each must become set-based:
    - **Text search** (`item_list`'s `p_search`) runs `util.item_search_texts` for every item of the tenant: its own walk up the class tree for the class names and defaults, and five queries for its values and its stock rows' values. Work out each class's names and defaults once, and match all items' values in one join.
    - **Attribute filters** (`item_list`'s `p_where`) run `util.item_matches` → `util.item_shown_values` per candidate item, a walk up the class tree each. Work out the candidates' classes once (`class.effective_attributes`, with an array) and join.
    - **`incomplete`** on each item of an `item_list` page (`util.item_incomplete`): a walk per item and per stock row. One `item.missing_attributes` and one `stock.missing_attributes` call for the whole page.
    - **The trees** (`util.class_tree`, `util.location_tree`) call themselves once per node, each a query for that node's children: a tree of 300 classes is 300 queries. Read all the tenant's live nodes in one query and build the tree from it (or let the API return them flat, part 3).
    - **List rows** (`item_list`, `stock_list`) are built by calling `util.item_summary_json`, `util.item_stock_total_json`, `util.item_photo_json` and `util.stock_json` per row, each running its own queries. Build the page in one query, with joins and one `GROUP BY` for the stock totals.
    - **Searching by name can't use an ordinary index** (`ILIKE '%…%'`); see TODO.md, "Potential performance improvements".
- ~~**An attribute's datatype never changes (database decision 35)**~~: decision 13.
- **The restores' no-op updates go** (`UPDATE value SET item = item, attribute = attribute …` in `item_restore`, `class_restore`, `util.restore_class_row`, `util.restore_item_rows`, `util.restore_stock_rows`): they only re-fired the value triggers, and fire nothing once those have a `WHEN` (database R40–R47). Restoring an owner whose values or assignments refer to deleted attributes or options is refused by the database; the accessor could offer to restore those too, as `with_parents` does for parents. The SQLSTATE of that refusal is matched to `error.deleted`'s.
- ~~**Expired sessions are only removed when their account logs in again**~~: decision 17.

## Decisions

1. **The API functions live in the area schemas** *(yours)*: `item.list`, `account.login`, beside the rules and helpers of the same area (database decision 30). Topic A1.
    - **Marked by `SECURITY DEFINER`:** `wtfd schema` grants the API role EXECUTE on exactly those, and revokes it from `PUBLIC` on every function, over every function schema (today `public` and `util`). It logs the API functions per schema, so a change in the list shows in review.
    - **The API role** gets `USAGE` on the function schemas; each schema's migration also has `ALTER DEFAULT PRIVILEGES IN SCHEMA … REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC`, so a new function is not callable until granted.
    - **Not done:** a schema `api`, which would show the boundary by schema; the flag and the grant check show it per function, as today.
2. **The schema says what a function is about, its name says what it does** *(yours)*. Topic A2. `item.list`, `item.get`, `item.create`, `item.patch`, `item.delete`, `item.restore`, `item.history`; what belongs to an object is prefixed in its schema: `item.value_set`, `stock.value_set`, `attribute.option_create`, `class.assign` and `class.unassign` (an attribute assigned to a class, in place of `class_attribute_set` and `class_attribute_remove`; renamed in the review); units in `unit` (`unit.quantity_list`, `unit.family_get`, `unit.list`); `model.import`, `meta.schema_version`, `code.resolve`, `attachment.lock`, `tenant.known`; logging in and accounts in `account` (`account.login`, `account.me`, `account.session_use`). Helpers follow the pattern as they are reviewed. `create` and `delete` are reserved words, allowed after the dot of a qualified name; the first test confirms it. The Go code calls the new names (part 3).
3. **The search path is set only on the API functions** *(yours)*. Topic A3. `SET search_path = pg_catalog, pg_temp` on each: the built-ins first, so nothing takes their place, and the session's temporary schema last (PostgreSQL otherwise searches it first, implicitly, so a caller's temporary table could be read in place of ours); no `public`, so an unqualified name fails at once. Helpers and rule functions have no `SET`: a SQL function with one is never inlined, and it costs a save and restore per call; their names are qualified anyway. Qualified are tables, our functions, pgcrypto's (`extensions.crypt`), and domains and enums in casts.
4. **A list page is one query** *(yours)*. Topic B1. The page's rows first, then what they show joined to them: the unit, its family and quantity, and the photo by joins; stock totals by one `GROUP BY` over the page's items; `incomplete` by one `item.missing_attributes` and one `stock.missing_attributes` call for the page. What is picked per row (the unit to show a total in) is a `LATERAL` join in the same query. In place of `util.item_summary_json`, `item_stock_total_json`, `item_incomplete`, `item_photo_json` and `stock_json` per row (about ten queries a row). The duplicate `photo` of `item_list` goes.
    - **JSON helpers take the rows they describe, not ids:** `unit.json(public.unit, public.unit_family, public.quantity)` builds the object and queries nothing, so it is inlined; the same helper serves every function that shows a unit.
5. **Names sort with an ICU collation that orders numbers by value** *(yours)*. Topic B1. `CREATE COLLATION public.natural (provider = icu, locale = 'und-u-kn-true')`, in the migration (database plan), and `ORDER BY name COLLATE public.natural, id`: "Item 2" before "Item 10", letter case ignored, as `util.natural_key` does today with a regular expression per matching row and page. `util.natural_key` goes. The server must be built with ICU (the official `postgres:18` image is); the first test confirms it.
6. **The trees leave the database flat; the API nests them** *(yours, the split)*. Topic B2. `class.list` and `location.list` return `{version, unchanged, nodes}`: every live node with its `parent`, its photo joined, sorted by name, in one query, in place of `util.class_tree` and `util.location_tree`, which call themselves once per node (a tree of 300 classes is 300 queries). `wtfd serve`'s tree handler, which already reads the result for the `ETag` and `304`, nests the nodes (part 3), so the API and its clients keep the nested tree.
7. **Search and filters work on what the candidates show, in one query** *(yours)*. Topic B3. The candidates (the tenant's live items, within `p_class`'s subtree); their classes' attributes worked out once (`class.effective_attributes` with all their classes); one table `shown (item, attribute, text, number, date, boolean, option)` of the values each candidate shows, its own or the class default, per item or per live stock row, for only the attributes needed (those filtered on, and the text, url and choice ones when searching). Filters are checked once by `util.check_item_filter` and become typed rows; an item matches when each filter has a `shown` row satisfying it. Search words match the name, the class path's names (once per class) and the `shown` texts and option names. In place of `util.item_search_texts`, `util.item_matches` and `util.item_shown_values`, run per item of the tenant. The behaviour is unchanged.
8. **Lists keep their count; history pages go by position, without one** *(yours)*. Topic B4. Item and stock lists keep `total`, counted from the matching rows their sort needs anyway; the apps show it. History pages take `p_before bigint DEFAULT NULL` (the oldest entry the client has) in place of `p_offset`, read `p_limit + 1` entries older than it by the index, and return `{rows, more}`: the same cost for every page, where today each page counts every entry of the object and skips the ones before it.
9. **A deleting call makes one `deletion` row; a restore finds what went with it by its id** *(yours; revised by decision 18: the row is the call's `action`, made by `util.begin_action`)*. Topic C1. `util.new_deletion()` inserts the session's tenant and account and returns the id, which the call sets as `deleted` on every row it deletes. A restore brings back the rows with the same `deleted` (by each table's partial index on it), as today: a class with the classes below it and their items and stock rows, an item with its stock rows, never rows merged into another. Restoring the deleted parents too (`with_parents`) walks up as today and restores one level per statement, top down, so each class's parent is live when its rule checks. The `deletion` row stays as the record; the purge removes those nothing refers to (part 3). `util.deletion_transaction`, `util.deleted_in`, `util.restore_class_row`, `util.restore_item_rows` and `util.restore_stock_rows` go, with the no-op updates; each restore has one `UPDATE … WHERE deleted = v_deletion` per table.
10. **Restoring an owner whose values refer to deleted attributes or options is refused** *(yours)*. Topic C2. The database's rule refuses it and names the attributes; the user restores those first. Not done, for now: a `with_attributes` option like `with_parents`, which would bring the attribute's own failures (a name taken since, which `attribute.restore` handles with a new name) and needs admin rights where restoring an item needs data write. It can be added later on its own.
11. **The tenant filter is written out in every query** *(yours)*. Topic C3. A row without `tenant` is checked by a join to the nearest table that has one: an item through its class, a stock row through its location, an item value through its item's class, a stock value through its stock row's location, an option through its attribute, an assignment through its class, an attachment through its owner, a session through its account. No helper per table, which would hide the filter. A row that refers to two things (a stock row's item and location) has both checked. One primary-key join per check.
12. **Each accessor reads the session once** *(yours; revised by decision 22: from its `p_request` argument)*. Topic C3. `util.session(p_role)` checks the role and returns `(tenant, account, role)`, in place of `util.require` and `util.tenant()`, which each look the session up (two SHA-256 and two look-ups per call today). Helpers never read the session; they are given the tenant (today `util.display_json` and `util.family_units_json` read it once per call, so once per row of a list).
13. **`attribute.patch` takes `name`, `unit` and `unit_lock`** *(yours)*. Topic C4. A patch with `datatype` is refused, even with the same value, with "an attribute's datatype can't be changed; make a new attribute" (database decision 35); a unit changes only within its quantity, which the database's rule checks. Model import is unchanged: an existing attribute with another datatype is already reported as a conflict and left as it is.
14. **`model.export` reads without locking, and without the old view** *(yours)*. Topic C5. Its existence query reads `deleted` (a deleted class gets `error.deleted`) in place of `check_live`'s `FOR SHARE`, as any read that cares whether something is deleted. Each class's own assignments come from `public.class_attribute` by its class, and only the top class's inherited ones from one `class.effective_attributes(ARRAY[p_class])`, in place of the view `class_effective_attribute` read once per class; defaults are shown by joins (the unit, the option's name), in place of `util.model_export_default`'s query per default. The nested file is still built one class at a time, two index look-ups each: a stated exception to database decision 34, as an export is a rare admin action on one subtree that makes a file, not a page.
15. **Logging in takes the client, the lifetime and the address; using a session keeps its trail** *(yours; revised by decision 22: `account.session_use` folds into `util.session`, and login takes `p_request`)*. Topic D1. `account.login(p_host, p_email, p_password, p_client, p_max_idle, p_address)`, with no defaults (NULL `p_max_idle` = never expires, said explicitly); the first `usage` entry is the login's address; lockout, timing and returned failures as today. `account.session_use(p_token, p_host, p_address)`: valid while the account is live and of `p_host`'s tenant and `max_idle IS NULL OR last_used > now() - max_idle`; the row is written when `last_used` is over a minute old or the address is new to the session, setting `last_used` and keeping the 8 addresses seen most recently; then `wtf.token` is set. Only the token is carried in a setting: the API role can set any `wtf.*` itself, so a setting holding the tenant could be forged, a token can't. JSON, defaults per client, an admin's cap and `X-Forwarded-For` are part 3's.
16. **Users see and end their own sessions** *(yours)*. Topic D2. `account.session_list()` returns the account's sessions, most recently used first, as `{id, client, created, last_used, max_idle, expires, current, usage}`; `id` is the token's hash in hex (the key; it can't be turned back into the token), `expires` is `last_used + max_idle` or null, `current` marks the session asking. `account.session_logout(p_session)` ends one of the caller's own (another's id is not found); `account.session_logout_others()` ends all but the current one, the statement `account.password_change` also uses. Not now: admins listing or ending other users' sessions, which deleting the account or changing its password already ends.
17. **Expired sessions are removed at login and by `wtfd gc`** *(yours)*. Topic D3. Expired is `max_idle IS NOT NULL AND last_used <= now() - max_idle`. `account.login` removes the account's own, as today; `wtfd gc` removes every tenant's in one statement (part 3; sessions aren't in history, so no tenant is needed). Nothing relies on it for safety: `account.session_use` refuses an expired session anyway.
18. **A writing call begins with an `action`; history groups by it** *(yours)*. Topic E1; database decision 37. Every writing accessor starts with `v_action := util.begin_action(v_session)`, which inserts the action (the session's tenant and account) and sets `wtf.action` for the transaction; `wtfd`'s maintenance calls `util.begin_action(p_tenant)`. A deleting call sets `deleted = v_action` (decision 9, with `util.new_deletion` gone). History entries carry the action, and its JSON gives `action: {id, at, account}` in place of `transaction`, `happened_at` and `account` on each entry; the app groups by the action's id. Not done: grouping by `(transaction, at)`, which used a timestamp as part of a key.
19. **History pages find an object's entries by `about`** *(yours)*. Topic E2; database decision 38. Each page is a static query, `WHERE h.about @> ARRAY[p_id]`, with the conditions it keeps today (a class's page shows an item's entry only when its class changed, or it was added or removed). `item.history` reads the entries about the item, then those about its stock rows, whose ids come from the first; purged stock rows are still found, and moves in and out by the old parent or location in `about`. In place of reading `data ->> …` and `changes -> … ->> 'old'` from every entry of the tenant's tables, and of `util.history_page`'s dynamic SQL. The pages per kind (`class.list_history`, the top of the tree) keep `(tenant, table_name, id)`.
20. **Each error keeps its SQLSTATE; 55000 maps to a neutral problem; our bugs are 500** *(yours)*. Topic F1, checked against `internal/serve/problem.go`. `error.invalid` 22023 (400), `error.not_found` P0002 (404), `error.bad_reference` 23503 (422), `error.deleted`, `error.not_deleted` and `error.restore_into_deleted` 55000 (409), `error.unauthenticated` 28000 (401), the role check 42501 (403), the rules 23514, 23505 and 23001 (422, 409, 409). Two changes: 55000 maps to `/problems/wrong-state`, "Not possible in this state", in place of `/problems/deleted`, whose title was wrong for "is not deleted" (part 3); and `history.record`'s refusals (no action, another tenant's row) raise a plain error, which maps to 500, as they mean a bug, not a user without rights.
21. **No separate check of the host** *(yours, in the review)*. `tenant_known` goes: it was a round trip per request, outside the call's transaction, to learn what the next query finds anyway. `account.session_use` tells an unknown host (`error.unknown_host`, 404) from a known one without a valid session (`error.unauthenticated`, 401) in its one query; `account.login` raises `error.unknown_host` too, in place of returning "invalid". `wtfd` drops its per-request check (part 3): a request without a session cookie gets 401 without the database, and `openapi.yaml` is served for any host. A request without a cookie no longer tells a known host from an unknown one, as today's 401 and 404 do.
22. **Who is calling is an argument, not a setting** *(yours, in the review)*. Every API function takes `p_request public.request` first, a composite type `(token text, host text, address inet)` (in the migration, database plan), which `wtfd` passes as `ROW($1, $2, $3)`. `util.session(p_request, p_role)` does what `account.session_use` did (the host and the session in one query, `last_used` and the address trail when due) and checks the role, and returns `(session, tenant, account, role)`, `session` being the token's hash, the row's key, so nothing hashes the token twice. `account.session_use` and the setting `wtf.token` go: one round trip less per request, and what a function knows of its caller is in its arguments. `account.login` takes `p_request` too (its token NULL). The read-only accessors are no longer `STABLE`, as `util.session` may write. `wtf.action` stays a setting, as triggers take no arguments.
23. **Passwords are hashed with bcrypt at cost 12** *(yours, in the review)*. `gen_salt('bf', 12)` in place of pgcrypto's default 6: guessing a stolen hash takes 64 times longer, for about a quarter of a second per login and per new password. `account.login`'s check for an unknown email address uses the same cost, so the time taken still doesn't tell addresses apart. Hashes record their cost, so a later change keeps old ones working.
24. **Ending the other sessions after a new password is the user's choice** *(yours, in the review)*. `account.password_change(p_request, p_current, p_new, p_end_other_sessions)`, with no default (NULL is refused); today they always end. An admin changing another user's password (`account.patch`) is taken up with that function.
25. **An admin's change of a user's password asks too** *(yours, in the review)*. `account.patch` takes `end_sessions` (true or false) with `password`, and only with it: a password without it, or it without a password, is refused. Also for a removed password, where keeping the sessions lets whoever is logged in finish. An admin's own password is not changed by `account.patch` (it needs the current one, `account.password_change`); today it can be, without.
26. **Parameters are named after what they are** *(yours, in the review)*, as columns are (database principle 3): `unit.quantity_get(p_request, p_quantity)`, `item.get(p_request, p_item)`, `account.patch(p_request, p_account, p_patch)`, `stock.move(p_request, p_stock, p_location, p_amount)`. `p_id` goes everywhere. `wtfd` calls with named arguments, so its names follow (part 3).
27. **The unit families are kept by clients, and asked for again by version** *(yours, in the review)*. `unit.family_list(p_request, p_known_version, p_quantity)` answers `{version, unchanged: true}` when the tenant's `unit` version (database decision 39) is the one given, and otherwise `{version, unchanged: false, families}`, as the trees do; `wtfd` gives it an `ETag` and `304` (part 3). Today the app fetches them once per run and never again, so another device's change goes unseen until a restart.
28. **Outside the unit functions, a unit is its id** *(yours, in the review)*. Attributes, items, values and stock rows carry `unit: <id>`, and `display` (how a number is shown) `{value, unit: <id>}`, the server still choosing the unit; clients look units up in the families they keep (decision 27), as they do locations. The `unit.` functions still send whole units, being the list clients keep. The joins of the unit, its family and quantity go from every other function, and each row of a page is about 400 bytes smaller. The apps and the CLI follow (part 3).
29. **A temporary table an accessor makes is dropped first if it is there** *(yours, in the review)*: `DROP TABLE IF EXISTS pg_temp.<name>` before `CREATE TEMPORARY TABLE pg_temp.<name> ON COMMIT DROP`, so that a second call in one transaction works. In `item.list` (`filter`) and `class.delete_tree` (`tree`), and any later one.
30. **`item.list` is measured on a large tenant** *(yours, in the review)*: a generated tenant of about 50,000 items, 200,000 values, 100,000 stock rows and 500 classes; `item.list` timed with no search, with an attribute filter and with a search, with `EXPLAIN ANALYZE` kept for each (estimated 0.1–0.3 s, 0.2–0.5 s and 0.5–2 s). If one is too slow, TODO.md's "Potential performance improvements" says what to pick from (a trigram index, or a stored search text per item). In the plan's tests.
31. **Accessors take typed parameters, and JSON only where the shape varies** *(yours, in the review)*: patches (which fields are present matters), values keyed by attribute id, `item.list`'s filters, restore options. A fixed shape is parameters of its own, which PostgreSQL checks by type and the signature shows: `location.create(p_request, p_name, p_parent, p_container, p_columns, p_rows, p_confirm)` in place of `p_grid jsonb` and the lines that checked its keys. `wtfd` takes the API's JSON apart into them (part 3).
32. **Codes are taken in one write, however many** *(in the review)*: `tenant.take_codes(p_tenant, p_count)` adds `p_count` to the tenant's counter and returns the first of the codes, in place of `next_code` (database R1) once per row; a grid of 8 × 5 compartments writes the tenant's row once, not 41 times. The other creating functions take 1.
33. **Model import checks before it inserts, in place of a subtransaction per insert** *(yours, in the review)*. Each insert was wrapped in `BEGIN … EXCEPTION`, a subtransaction each: a transaction id each, and past 64 in one transaction every session's visibility checks slow down until it ends. What can conflict is checked with plain queries first (names, including a tenant's against a global one; a container class; a unit's datatype; a symbol that means another unit); a refusal a check missed aborts the import with its rule's message, where it was listed as a conflict. All or nothing either way. The one subtransaction for the dry run and for conflicts stays, with the import's one action begun inside it (a global units import makes none).
34. **Model files say `decimal` and `scope`** *(yours, in the review)*: `"datatype": "decimal"` in place of `"float"`, and `"scope": "item" | "stock"` in place of `"per_unit"`, as the database does (database decisions 2 and 24). The format stays version 1, and nothing reads the old names: no files in the old form exist yet. `seed/model-format.md` and the seed files follow.
35. **One parser for typed values, which can report instead of raising** *(in the review)*: `attribute.try_parse_value` returns the value's columns and `problem text`; `attribute.parse_value` raises the problem. Model import reports a default that doesn't fit as a conflict through the first, without a subtransaction (decision 33).

## Review of the functions

Each API function as it will be, one at a time, with the helpers it is the first to use. 84: today's 83, decision 16's three, less `tenant_known` (decision 21) and `session_use` (decision 22). In this order:

- **Accounts and sessions (1–12):** `account.login`, `account.logout`, `account.me`, `account.password_change`, `account.session_list`, `account.session_logout`, `account.session_logout_others`, `account.list`, `account.get`, `account.create`, `account.patch`, `account.delete`.
- **Units (13–20):** `unit.quantity_list`, `unit.quantity_get`, `unit.quantity_patch`, `unit.family_list`, `unit.family_get`, `unit.family_patch`, `unit.list`, `unit.get`.
- **Attributes (21–32):** `attribute.list`, `get`, `create`, `patch`, `delete`, `restore`; `attribute.option_list`, `option_get`, `option_create`, `option_patch`, `option_delete`, `option_restore`.
- **Classes (33–41):** `class.list`, `get`, `create`, `patch`, `delete`, `delete_tree`, `restore`, `assign`, `unassign`.
- **Items (42–49):** `item.list`, `get`, `create`, `patch`, `delete`, `restore`, `value_set`, `value_delete`.
- **Locations (50–56):** `location.list`, `get`, `create`, `patch`, `delete`, `delete_tree`, `restore`.
- **Stock (57–65):** `stock.list`, `get`, `create`, `patch`, `move`, `delete`, `restore`, `value_set`, `value_delete`.
- **Attachments (66–71):** `attachment.create`, `get`, `patch`, `delete`, `restore`, `lock`.
- **Model (72–73):** `model.import`, `model.export`.
- **History (74–82):** `item.history`, `stock.history`, `location.history`, `class.history`, `location.list_history`, `class.list_history`, `attribute.history`, `attribute.list_history`, `account.history`.
- **The rest (83–84):** `meta.schema_version`, `code.resolve`.

Reviewed one by one: 1–66. Of 67–84, only 69 (`attachment.delete`), 72 (`model.import`) and 74 (`item.history`) are looked at in detail *(yours)*; the others follow the patterns already checked (static SQL by owner kind for attachments, decision 14 for the export, decisions 8, 18 and 19 for the history pages, decision 11 for `code.resolve`), and are written that way.

## Plan

Part 2 is written on the same branch as part 1, and goes live with it and part 3 (database plan, "Plan"). It starts once part 1's migrations and rules are written, as the accessors are written against them.

1. **The shared pieces first**, which every accessor calls:
    - **`error`:** the raisers of database decision 31, with those added in the review (`unknown_host`, `forbidden`, `duplicate`, `in_use`, `wrong_state`); `not_found` takes the id as text. Each with the SQLSTATE of decision 20.
    - **`util`:** `session` (decision 22), `begin_action` (decision 18), `trim_and_check` and `trim_and_check_path_name`, `check_patch`, `check_paging`, `check_limit`, `check_values`, `token_hash`, `typed_value_json`, `code_text`, `column_label`, `path_text`.
    - **`tenant.take_codes`** (decision 32), and **`unit.display`** (function 34).
2. **The accessors, one file per schema**, in `db/repeatable/`, after the rules of the same schema (database plan, step 2): `account`, `unit`, `attribute`, `class`, `item`, `location`, `stock`, `attachment`, `model`, `history`, `meta`, `code`. In each, the helpers that build JSON from rows first (`attribute.json`, `class.detail_json` …), then the API functions in the order of the review. Ordered so that a SQL function's body only names what already exists: `class` before `item` and `stock`, which use `class.effective_attributes` and `class.path_json`.
    - Each API function: `SECURITY DEFINER SET search_path = pg_catalog, pg_temp` (decision 3), `p_request` first and `util.session` on its first line (decision 22), every name qualified (principle 5), parameters named after what they are (decision 26) and typed (decision 31), an action before the first write (decision 18).
    - The old `util` helpers that the review replaced are not written again; `10_util.sql` and the scripts named after the old areas go.
3. **Checks that hold for every function**, as tests in `internal/integration/`, against the catalogue (`pg_proc`), so that a slip anywhere fails them:
    - no function body contains `EXECUTE` (principle 4);
    - every API function is `SECURITY DEFINER` with `search_path = pg_catalog, pg_temp`, and no other function sets a search path (decision 3);
    - the API role can execute exactly the API functions, and `PUBLIC` none (decision 1);
    - functions named after a reserved word (`item.create`, `item.delete`) can be called (decision 2).
4. **Tests of the accessors**, on a database with the new schema and no API, calling the functions with a `request`:
    - **tenant isolation:** for every function that takes an id, another tenant's id is "not found" (or a bad reference, in a body);
    - **roles:** each function refused below its role (403), and allowed at it;
    - **deleting and restoring by action** (decision 9): what comes back with a class, an item, a location; with `with_parents`; refused for deleted attributes and options (decision 10);
    - **sessions:** lifetime, the address trail, the user's own sessions (decisions 15, 16, 22), and the password choices (decisions 24, 25);
    - **model import:** a file imported, imported again (all existing), with conflicts, as a dry run, with a base unit missing;
    - **the benchmark** of decision 30.
    The API's own tests (`internal/integration/api_test.go` and the others) are rewritten with the API in part 3.
5. **The documents:** `API.md` and `api/*.md`, which describe the accessors and the API together, are rewritten with part 3, once the API's shape is settled; until then this document is the description.
6. **Then part 3,** the API, which starts from the topics collected in its document.

## Log

- **2026-10-31:** document started.
- **2026-10-31:** the functions surveyed; principles proposed; topics listed.
- **2026-10-31:** principles confirmed; decision 1, API functions in the area schemas (A1).
- **2026-10-31:** decision 2, the names (A2).
- **2026-10-31:** decision 3, the search path (A3).
- **2026-10-31:** decisions 4 and 5, list pages in one query and the natural collation (B1).
- **2026-10-31:** decision 6, flat trees from the database, nested by the API (B2).
- **2026-10-31:** decision 7, search and filters set-based (B3).
- **2026-10-31:** decision 8, paging (B4); B5 settled by decision 4.
- **2026-10-31:** decision 9, deleting and restoring through `deletion` rows (C1).
- **2026-10-31:** decision 10, restoring with deleted attributes or options refused (C2).
- **2026-10-31:** decisions 11 and 12, tenant filters written out, the session read once (C3).
- **2026-10-31:** decision 13, `attribute.patch` without `datatype` (C4).
- **2026-10-31:** decision 14, `model.export` (C5).
- **2026-10-31:** decision 15, logging in and using a session (D1).
- **2026-10-31:** decision 16, the user's sessions (D2).
- **2026-10-31:** decision 17, removing expired sessions (D3).
- **2026-10-31:** decision 18, actions (E1), with database decision 37.
- **2026-10-31:** decision 19, history pages by `about` (E2), with database decision 38.
- **2026-10-31:** decision 20, errors (F1); the topics are decided.
- **2026-10-31:** the review of the functions started; decision 21, no separate host check.
- **2026-10-31:** decision 22, the caller as an argument (`p_request`); `session_use` folded into `util.session`.
- **2026-10-31:** decisions 23 and 24, bcrypt cost 12 and ending other sessions optional.
- **2026-11-01:** decision 25, an admin's password change asks whether sessions end.
- **2026-11-01:** decision 26, parameters named after what they are.
- **2026-11-01:** decision 27, unit families by version.
- **2026-11-01:** decision 28, units by id outside the unit functions.
- **2026-11-01:** `class.assignment_set` and `assignment_remove` renamed `class.assign` and `class.unassign` (decision 2).
- **2026-11-01:** decisions 29 and 30, temporary tables dropped first, and `item.list` measured.
- **2026-11-01:** decisions 31 and 32, typed parameters, and codes taken in one write.
- **2026-11-01:** the review of functions 1–66 done; of the rest, 69, 72 and 74 in detail.
- **2026-11-01:** decisions 33 and 34, model import without a subtransaction per insert, and model files' names.
- **2026-11-01:** the review of the functions done (67–84 by the patterns checked, 69, 72 and 74 in detail); decision 35; the plan written.
- **2026-11-01:** `attribute.option_list` (function 27) goes, by API decision 8; 83 API functions.
- **2026-11-01:** `error.restore_into_deleted` raises `WT001`, with the place key in `DETAIL` (API decision 14); decision 20 otherwise unchanged.
