# Database refactor – plan

**Status: steps 1–4 done (2026-11-01, overnight); SCHEMA.md next.** Part 1 of 3: the database model, then the PL/pgSQL accessor functions ([2026-10-31-pl-pgsql-accessor-refactor.md](2026-10-31-pl-pgsql-accessor-refactor.md)), then the API ([2026-10-31-api-refactor.md](2026-10-31-api-refactor.md)).

## How we work

- **No rewrites until the plan is complete.** We go through the model topic by topic, decide, and write the decision down here. Only when every topic is decided does the work start.
- **Going back is fine.** A decision in the functions or the API may reopen one here; it's then marked as reopened, with why.
- **"Right" is yours to define.** The principles below are what the schema follows today; confirm, change or add to them first, as they decide the rest.

## Principles

Confirmed: the conventions from before the refactor (1–4, 8) and those its decisions made.

1. **Explicit over implicit:** visible mechanisms in the SQL, such as tenant filters in every query, rather than row-level security.
2. **The database enforces integrity:** what must always hold is a constraint or a trigger, except that rows stay within their tenant, which the accessors guarantee (principle 6). That is still the database: the accessors are its PL/pgSQL functions, and the only way in, as the API's role can execute them but touch no table.
3. **Reference columns are named after what they reference,** without `_id` (`parent`, `class`, `item`). One exception: `deleted`, which refers to the `action` that deleted the row but reads as the row's state (`WHERE deleted IS NULL`) (decision 15).
4. **Nullable columns are marked `NULL`** explicitly.
5. **Indexes are named `<table>_<columns>_idx`, with the column names as they are; unique indexes and constraints end in `_unique` instead** (decision 10).
6. **A table has `tenant` only where it can't be derived** through a NOT NULL foreign key (decision 1). That rows stay within their tenant is guaranteed by the accessors, which take the tenant from the session and check every id against it.
7. **Nothing is deleted outright** except by a purge: rows refer to the `action` they were deleted in, and can be restored (decisions 15 and 37).
8. **Numbers with a unit are stored in the base unit** of their quantity; the database never converts stored numbers.
9. **Column names are one word where one word is clear,** and two where one would be vague (`media_type`, `default_number`) *(yours)*.

## The model today

Base schema `db/migrations/0001_schema.sql` (1,881 lines), then `0002_units.sql` (the bootstrap units), `0003_renames.sql` (`next_code` → `code`, `default_available` → `standard`) and `0004_roles.sql` (one role in place of four privileges). Trigger functions live in the migrations; the API functions in `db/repeatable/`.

| Group | Tables |
|---|---|
| Tenancy | `tenant` (host, next label code) |
| Units | `quantity`, `unit_family`, `unit`; the tenant's choices in `tenant_quantity`, `tenant_unit_family`. Global rows have `tenant` NULL. |
| Model | `class` (tree, `container`), `attribute` (datatype, unit, unit lock), `attribute_option`, `class_attribute` (default, `per_unit`, `required`) |
| Data | `item`, `value` (per-kind values), `location` (tree, `container`), `stock` (quantity, `merged_into`), `stock_value` (per-unit values) |
| Attachments | `item_attachment`, `stock_attachment`, `location_attachment`, `class_attachment`, made by one `DO` loop; `photo` on the four owners |
| Accounts | `account` (email, bcrypt hash, role, lockout), `session` (token hash) |
| Bookkeeping | `history` (one row per changed row, jsonb), `data_version` (counter per tree) |

Types: `datatype` (text, integer, float, date, boolean, url, choice), `role`, `history_operation`. View: `class_effective_attribute`.

## Topics

Things I noticed reading the schema. They're candidates for discussion, not proposals; some may well be right as they are. Each gets a decision before anything is changed.

### A. Names

- ~~**A1. "Unit" means two things:** a unit of measure (`unit`, `item.unit`) and one physical thing (`per_unit`, "per-unit attributes").~~ *Decided: 2.*
- ~~**A2. "Quantity" means two things:** a physical quantity (`quantity`, Length) and an amount (`stock.quantity`).~~ *Decided: 3.*
- ~~**A3. `value` and `stock_value`:** the item's values are just `value`, not `item_value`.~~ *Decided: 2.*
- ~~**A4. Typed columns:** `text_value` … `option_value` in values, `text_default` … `option_default` in `class_attribute`.~~ *Decided: 4.*
- ~~**A5. Index names** end in `_id_idx` (`item_class_id_idx`), against principle 3; one is `value_value_option_id_idx`.~~ *Decided: 10.*
- ~~**A6. `per_unit` as a boolean** where the documents speak of a *scope* (per kind, per unit), and `attribute_scope()` returns true/false/NULL.~~ *Decided: 2.*
- ~~**A7. Attachments' `type`** (MIME type), next to `datatype` elsewhere.~~ *Decided: 9.*

### B. Structure

- ~~**B1. Typed values:** six nullable columns, exactly one set, in three tables (`value`, `stock_value`, `class_attribute`). `url` is text checked by a regex.~~ *Decided: 4.*
- ~~**B2. `value` has an `id`, `stock_value` doesn't;** their keys differ (`UNIQUE (item, attribute)` vs `PRIMARY KEY (stock, attribute)`).~~ *Decided: 5.*
- ~~**B3. Four attachment tables made by dynamic SQL** in a `DO` loop, so they don't appear in the file as tables. Alternatives: written out, or one table with an owner per kind.~~ *Decided: 8.*
- ~~**B4. Numeric types:** `stock.quantity` and unit factors are `numeric`, float values `double precision`, integers `bigint`.~~ *Decided: 4.*
- ~~**B5. Containers** as a flag on `class` and `location`.~~ *Decided: 14.*
- ~~**B6. `quantity.datatype`** reuses the `datatype` enum, restricted to integer and float by a CHECK.~~ *Decided: 12.*
- ~~**B7. Primary keys** are random UUIDs (v4).~~ *Decided: 11.*
- ~~**B8. Empty-name checks** (`btrim(name) <> ''`) repeated in every table; a domain could say it once.~~ *Decided: 13.*

### C. Deleting and history

- ~~**C1. Soft delete** as `deleted boolean` on eight tables, with per-table triggers for "live refers to live", "deletable" and "frozen".~~ *Decided: 15.*
- ~~**C2. Restoring reads history** (`util.deletion_transaction`) to find what was deleted together, so restore depends on history.~~ *Decided: 15.*
- ~~**C3. History finds the account by hashing the session token** (`wtf.token`) again for every changed row.~~ *Decided: 16.*
- ~~**C4. History's `table_name`** is free text and `data` has no reference to the row; looked up through an index on `data ->> 'id'`.~~ *Decided: 17.*

### D. Tenancy and units

- ~~**D1. Global and tenant rows in the same unit tables** (`tenant` NULL = global): uniqueness is enforced twice, by partial unique indexes and by triggers that see both.~~ *Decided: 18.*
- ~~**D2. `item.unit` and `attribute.unit` are plain foreign keys** (a unit may be global), with a trigger for the tenant.~~ *Decided: 19.*
- ~~**D3. One label-code counter per tenant** in `tenant.code`: every new item, location or stock row of a tenant waits for the others until commit.~~ *Decided: 20.*

### E. Where the SQL lives

- ~~**E1. Migrations carry history** that a new installation replays: the four privileges made in 0001 and replaced in 0004, the renames in 0003. Is there data to keep, or can the migrations start over once more?~~ *Decided: 6.*
- ~~**E2. Trigger functions are in the migrations,** so changing a rule needs a new migration, while the API functions are repeatable scripts.~~ *Decided: 7.*
- ~~**E3. SCHEMA.md is out of date:** it names migrations that no longer exist (`0003_base_units.sql`, `0005`–`0007`), and its "Deferred" list has things that are built (per-unit values, history, accounts).~~ *Decided: 7.*

### F. Runtime cost

- ~~**F1. `class_effective_attribute` works out every class of every tenant** each time it's used: a recursive view starting from all classes, which no `WHERE e.class = …` can narrow; used in seven places, among them per item and attribute in search results.~~ *Decided: 21.*
- ~~**F2. `data_version` is bumped once per row,** not per statement as SCHEMA.md says: deleting a tree of 200 locations updates the same counter 200 times.~~ *Decided: 22.*
- ~~**F3. No history index for a tenant's history, newest first.**~~ *Decided: 23.*

## Decisions

1. **`tenant` only where it's needed** *(yours)*. The API never takes a tenant: inserts use the session's, and no update changes it (checked: no API function has a tenant parameter, and `tenant` is never in a `SET`). So a stored tenant that a NOT NULL foreign key leads to is redundant.
    - **Keep `tenant` (11):** `account`; `class` and `location` (the roots have no parent); `attribute` (its unit is nullable, and may be global); `quantity`, `unit_family` and `unit` (NULL = global, and a tenant's own may be in a global parent); `tenant_quantity`, `tenant_unit_family` and `data_version` (part of the key); `history` (doesn't refer to its row).
    - **Drop `tenant` (11):** `session` (→ account); `attribute_option` (→ attribute); `class_attribute` (→ class); `item` (→ class); `value` (→ item → class); `stock` (→ location); `stock_value` (→ stock → location); `class_attachment`, `location_attachment`, `item_attachment`, `stock_attachment` (→ the owner).
    - **No composite foreign keys, and no `UNIQUE (tenant, id)`:** references are plain. That a row's two parents (`class_attribute`, `value`, `stock`, `stock_value`) are the same tenant's is the accessors' guarantee, with no trigger in its place. An option is kept within its attribute by `(attribute, option) → attribute_option (attribute, id)`.
    - **Label codes** are unique per tenant because only `next_code()` writes them (it locks the tenant row, and no API function accepts a code). `UNIQUE (tenant, code)` goes from `item` and `stock`, which get a plain index on `code` for `code_resolve`. `location`, which keeps its tenant, keeps `UNIQUE (tenant, code)` *(yours)*: code look-ups need an index on it anyway, and this one matches them exactly.
    - **For the accessors** ([part 2](2026-10-31-pl-pgsql-accessor-refactor.md)): tenant filters on the derived tables become joins to the nearest table with `tenant`. The history and `data_version` triggers read `NEW.tenant` today and will have to look it up; so will `wtfd gc` and the attachment file paths (one directory per tenant).
2. **"Unit" is only a unit of measure; values are on the item or on the stock row** *(yours)*. Topics A1, A3 and A6. A "per-unit" value was never per unit anyway: a stock row can be a batch.
    - **`class_attribute.scope`,** of a new type `scope AS ENUM ('item', 'stock')`, default `'item'`, in place of `per_unit boolean`. An enum names both scopes alike, where a boolean makes one of them the exception.
    - **`attribute_scope()`** returns `'item'`, `'stock'` or NULL (not assigned).
    - **`value` becomes `item_value`,** beside `stock_value`.
    - **Words:** "item attributes" and "stock attributes", in place of "per-kind" and "per-unit".
    - **Model files:** `"scope": "stock"`, left out for `item`, in place of `"per_unit": true`; the files in `seed/` are rewritten.
    - **Beyond the schema** (about 225 places): the accessors, the API, the CLI, the docs, and the apps ([2026-10-31-changes-to-the-apps.md](2026-10-31-changes-to-the-apps.md)).
3. **"Quantity" is only a physical quantity; a stock row has an `amount`** *(both of ours)*. Topic A2. "Quantity" is the metrology term (SI, ISO 80000) and runs through the whole units model, while the stock side is one column; and "amount" fits 12 pieces and 2.5 m of cable alike, where "count" wouldn't.
    - **`stock.amount numeric NULL`** in place of `stock.quantity`, meaning the same: in the base unit of the item's unit (counted if none); NULL = present but not counted, 0 = none left.
    - **`p_amount`** in place of `p_quantity` in the stock functions (`stock_create`, `stock_update`, `stock_move`), and "total amount" for an item's stock total (part 2).
    - **The JSON and the CLI say `amount`** (part 3), and the apps say **Amount** ([2026-10-31-changes-to-the-apps.md](2026-10-31-changes-to-the-apps.md)): one word all the way through.
4. **Typed values keep their typed columns, five of them: `text`, `number`, `date`, `boolean` and `option`** *(yours)*. Topics B1, B4 and A4 (for the values). Real types sort, compare and index natively, and an option has a real foreign key; one `jsonb` column, a table per type or one `text` column would each give some of that up.
    - **`number numeric`** in place of `integer_value bigint` and `float_value double precision`: decimals are exact (a double can't hold 4.7 µF in farads), as are the unit factors and stock amounts they're converted with. Every number in the data is now `numeric`.
    - **The `integer` datatype stays,** for attributes and quantities: an integer attribute's number must be whole, checked as stock amounts are.
    - **In `item_value` and `stock_value`:** exactly one of the five is set (CHECK), the one matching the attribute's datatype (trigger, as today; storing the datatype on each row to make it a CHECK was considered, and not done, as it's the kind of copy decision 1 removed). `url` stays in `text`, checked by its regex. The option's foreign key is `(attribute, option) → attribute_option (attribute, id)`.
    - **The defaults in `class_attribute` are `default_text`, `default_number`, `default_date`, `default_boolean` and `default_option`** *(yours)*: at most one set, matching the attribute's datatype, as today. A table of its own for them (`class_attribute_default`) would have matched the value tables, but costs a join wherever defaults are read; the prefix costs nothing.
5. **`item_value` has no `id`; its key is `PRIMARY KEY (item, attribute)`,** like `stock_value`'s `(stock, attribute)` *(yours)*. Topic B2. Nothing refers to a value row by its id (checked: the API addresses values as `/items/{id}/values/{attribute}`, and history and restore find them by `data ->> 'item'`), so the column, its index and the separate `UNIQUE (item, attribute)` only cost space and index updates.
6. **The schema starts over** *(yours)*. Topic E1. The database is reset when the refactor is done, so no data is kept and nothing is migrated: the new schema is one fresh `0001`, with no history of renames and replaced columns. History written before the reset is gone with it, so nothing has to read old names.
7. **Migrations hold what holds data; the rules are repeatable** *(yours)*. Topics E2 and E3. A migration runs once and is then frozen; the repeatable scripts are dropped and run again whenever one changes. The trigger functions hold no data, like the API functions, so they belong with them: changing a rule is then editing a file, not writing a migration.
    - **Migrations:** tables, columns, constraints, indexes, enum types, the bootstrap units.
    - **Repeatable:** trigger functions together with their `CREATE TRIGGER`, views (`class_effective_attribute`), helpers such as `next_code()` and `attribute_scope()`, and the API functions. A rebuild drops them all, so a trigger taken out of a script is really gone.
    - **Nothing that holds data uses a repeatable function directly,** since a rebuild would drop it with the function. `wtfd schema` refuses a rebuild that would drop anything but functions, triggers and views.
    - **Our code in a constraint goes through a wrapper:** a PL/pgSQL function in a migration whose body calls the repeatable one (`RETURN item_name_ok(p_name);`). PostgreSQL records no dependency on what a PL/pgSQL body calls, so the rule behind the wrapper can be rebuilt freely. The wrapper's name, arguments and result are frozen with its migration, and, as for any CHECK, a changed rule only applies to rows as they are written.
    - **SCHEMA.md** is rewritten with the new `0001`, so its stale migration names and "Deferred" list go (E3).
8. **One `attachment` table** *(yours)*. Topic B3. One table of one kind of thing, an attachment, whichever object it belongs to; in place of four identical tables made by a `DO` loop that never shows them as tables.
    - **Columns:** `id`, the owner as four nullable foreign keys `item`, `stock`, `location` and `class` (ON DELETE CASCADE) with `CHECK (num_nonnulls(item, stock, location, class) = 1)`, then `type`, `hash`, `size`, `title` and `deleted` as today.
    - **Photos:** `UNIQUE (item, id)`, `(stock, id)`, `(location, id)` and `(class, id)` are the targets of the owners' photo foreign keys, `(id, photo) → attachment (item, id)` and so on, which keep a photo among the owner's own attachments as today. The same indexes find an owner's attachments, so no others are needed for that.
    - **One set of triggers:** the owner is live, a deleted attachment is frozen, a photo is an image; and the class or location tree moves on when a class's or a location's attachment changes.
    - **Static SQL in the accessors** (part 2): `WHERE id = p_id AND item = p_owner`, in place of the nine `EXECUTE format(…)` that build table names today. An attachment id is now unique across all kinds; the API still reaches it only through its owner.
    - **No runtime cost:** reading one owner's attachments goes straight to them through its index, and `wtfd gc` reads one table instead of four.
9. **An attachment's `type` is `media_type`** *(yours)*. Topic A7. A bare `type` is vague beside `datatype`; "media type" is what IANA calls it ("MIME type" is the older name). Whether the API's JSON follows is for part 3.
10. **Index names are `<table>_<columns>_idx`** *(yours, as meant all along)*. Topic A5. The column names as they are, so no `_id` (principle 3): `item_class_idx`, `stock_location_idx`, `item_value_option_idx`. Unique ones keep `_unique`.
11. **Primary keys are UUID version 7, `DEFAULT uuidv7()`; PostgreSQL 18 or newer** *(yours)*. Topic B7. A v7 UUID starts with its creation time in milliseconds, so new keys land at the end of the index: cheaper inserts, a more compact index, and recent rows together. Still a `uuid`, as unique and as unguessable; the one cost is that an id tells when its row was made.
    - **`uuidv7()` is built into PostgreSQL 18,** which the server runs (18.6) and CI uses (`postgres:18`). The minimum goes from 15 to 18: `minServerVersion` in `internal/schema/schema.go`, and README.md, WTFD.md and SCHEMA.md, which say 15.
12. **`quantity.datatype` stays the `datatype` enum, limited to `integer` and `float`** *(yours)*. Topic B6. It says what an attribute's datatype says, whether its numbers are whole (decision 4); a type of its own for two values would only add a name.
13. **Domains for text that must not be blank** *(yours)*. Topic B8. The check is written once, where today it's repeated in fourteen columns; the same check, so no runtime cost. Domains are used by columns, so they're in the migration (decision 7).
    ```sql
    CREATE DOMAIN name_text AS text CHECK (btrim(VALUE) <> '');
    CREATE DOMAIN path_name AS name_text CHECK (strpos(VALUE, '/') = 0);
    ```
    - **`path_name`:** `class.name` and `location.name`, which are joined with `/` into paths.
    - **`name_text`:** every other name, symbol and title: `quantity.name`, `base_symbol` and `base_name`; `unit_family.name`; `unit.name` and `symbol`; `attribute.name`; `attribute_option.name`; `item.name`; `attachment.title`; and also `account.email` and `attachment.media_type`, which aren't names but must not be blank either.
    - (`name` alone can't be a domain's name: PostgreSQL has a type called `name`.)
14. **Containers stay a flag on `class` and `location`** *(yours)*. Topic B5. It's the user's choice per node, so it can't be derived (a shelf may have both bins and stock of its own), and its triggers are cheap. A node `kind` would only pay off with more kinds of node.
15. **A deletion is a row of its own, and deleted rows refer to it** *(revised by decision 37: the row is an `action`, made by every writing call)* *(yours; the table in place of my timestamp)*. Topics C1 and C2. Restoring needs to know what was deleted together; today that's read from history, which can be purged, and then a restore quietly brings back less. A shared key says it outright, where a shared timestamp would only happen to be equal.
    ```sql
    CREATE TABLE deletion (
        id      uuid        NOT NULL PRIMARY KEY DEFAULT uuidv7(),
        tenant  uuid        NOT NULL REFERENCES tenant (id),
        account uuid        NULL     REFERENCES account (id),  -- who; NULL = the operator
        at      timestamptz NOT NULL DEFAULT now()
    );
    ```
    - **`deleted uuid NULL REFERENCES deletion (id)`** in place of `deleted boolean` in `item`, `stock`, `location`, `class`, `attribute`, `attribute_option`, `attachment` and `account`: NULL = live. Named `deleted`, not after the table it refers to (principle 3's one exception), as it reads as the row's state *(yours, in the review)*. Accounts are deleted the same way as everything else.
    - **Deleting:** the accessor makes one `deletion` per call and sets it on every row it marks; explicit, no trigger guessing at "the same transaction".
    - **Restoring:** what goes together is the rows with the same `deleted`, below or belonging to the object; history isn't read. Restoring part of a deletion clears only those rows; the deletion stays for the rest. A `deletion` no row refers to any more is removed by the operator's purge.
    - **Cost:** whether a row is live is `deleted IS NULL` on the row itself, no join; a join only to show when or who. One insert per deleting call. A NULL takes no space (a bit in the row's null bitmap, which these rows already have), so live rows are a byte smaller than with the boolean, and only deleted rows carry the 16 bytes. Each of the eight tables gets a partial index `WHERE deleted IS NOT NULL` for restoring.
    - **Unchanged:** the rules that live rows only refer to live rows, that only what nothing live depends on can be deleted, and that deleted rows are frozen; `merged_into` on stock.
16. **History keeps finding the account through the session token** *(yours; replaced by decision 37: the account is the action's)*. Topic C3. One SHA-256 and one primary-key look-up per changed row, small beside the history insert; and who did something can't be forged without a valid session, as it could if the API set the account itself.
17. **History gets `object uuid NULL`, the changed row's id** *(yours; replaced by decision 38: `about`)*. Topic C4. Indexed with `(tenant, table_name, object)` in place of the expression index on `data ->> 'id'`: smaller and faster, and it says what the entry is about. Not a foreign key, as history outlives purged rows. NULL for value and assignment rows, which have no id (decision 5) and are found by their item, stock row or class as today. `table_name` stays text.
18. **One `NULLS NOT DISTINCT` unique index per naming rule of the units, and a lock in the triggers** *(yours)*. Topic D1. A name is unique among what a tenant sees, its own and the global ones.
    - **The indexes:** `UNIQUE (tenant, lower(name)) NULLS NOT DISTINCT` means unique among the global rows and unique within each tenant, in one index where there are two partial ones today: for `quantity` and `unit_family` the name, for `unit` the symbol and the name within the family (`(tenant, family, symbol)`, `(tenant, family, lower(name))`). Eight indexes become four.
    - **The triggers** (`quantity_check`, `unit_family_check`, `unit_check`) keep what no index can do, a tenant's name against a global one, and the message that names who has it. They first take `pg_advisory_xact_lock` on the name, so that a global and a tenant's import of the same name at once can't both pass: the second waits for the first's commit and then sees it.
    - **Not done:** separate tables for global and tenant units, which would put a `UNION` in every units query.
19. **No tenant trigger on an item's or attribute's unit** *(yours)*. Topic D2. `check_unit_tenant` goes: that a reference stays within its tenant is the accessors' guarantee (decision 1), and they check more than it did, that the unit is available to the tenant, which rules out other tenants' units and the ones it turned off. The rules about the data stay: a unit only changes to one of the same quantity (`check_unit_change`), and an attribute's datatype is its unit's quantity's (`attribute_check_unit`).
20. **One label-code counter per tenant, as today** *(yours)*. Topic D3. `next_code()` locks only the tenant's own row, until commit, as every row lock is; so a tenant's creating transactions take their codes one at a time, and other tenants never wait. That's what keeps codes short and without gaps (a rollback undoes the increment), and short codes matter on printed labels. A sequence, per tenant or shared, wouldn't wait, but leaves gaps, and per tenant needs dynamic SQL. Many large imports into one tenant at once are far from the common case.
21. **The effective attributes of a class are a function, starting from that class** *(yours)*. Topic F1. `class_effective_attributes(p_class)` in place of the view `class_effective_attribute`: its recursion walks up from the one class, as `attribute_scope()` does, a handful of rows, where the view works out the ancestry of every class in the database first. No table is added.
22. **`data_version` is bumped once per statement** *(yours)*. Topic F2. Statement-level triggers with transition tables (`REFERENCING NEW TABLE AS …`, and `OLD TABLE` for deletes) bump each affected tenant's counter once, in place of once per row. For `attachment` (decision 8), whose tenant is derived, the trigger joins the class or location: once per statement.
23. **No new history index** *(yours, on the condition, which held)*. Topic F3. There's no history page of a whole tenant; the pages per kind (`location_list_history`, `class_list_history`, `attribute_list_history`) are served, newest first, by the existing `(tenant, table_name, id)`, which stays beside decision 17's `(tenant, table_name, object)`.
24. **The datatype `'float'` is `'decimal'`** *(yours, in the review)*. Since decision 4 these numbers are `numeric`, exact decimals, so "float" would mislead; "decimal" says what they are and pairs with `'integer'`. For attributes and quantities alike; model and unit files say `"decimal"`, and the API, CLI and apps follow (parts 2 and 3, [2026-10-31-changes-to-the-apps.md](2026-10-31-changes-to-the-apps.md)).
25. **Sessions last as long as their user chooses, and remember where they were used from** *(yours, in the review)*.
    ```sql
    -- Where a session has been used from, and when last.
    CREATE TYPE session_usage AS (address inet, seen timestamptz);

    CREATE TABLE session (
        token_hash bytea           NOT NULL PRIMARY KEY CHECK (length(token_hash) = 32),
        account    uuid            NOT NULL REFERENCES account (id) ON DELETE CASCADE,
        client     name_text       NULL,
        created    timestamptz     NOT NULL DEFAULT now(),
        last_used  timestamptz     NOT NULL DEFAULT now(),
        max_idle   interval        NULL CHECK (max_idle > interval '0'),
        usage      session_usage[] NOT NULL DEFAULT '{}' CHECK (cardinality(usage) <= 8)
    );
    ```
    - **`max_idle`:** the client sends the user's choice at login; NULL = the session never expires, and only logging out or deleting the account ends it. A session is valid while `max_idle IS NULL OR last_used > now() - max_idle`; `last_used` is still written at most once a minute.
    - **`usage`:** the last 8 addresses the session was used from, with when each was last seen. The same once-a-minute write refreshes the current address's `seen`, or puts it in place of the entry seen longest ago. In the row rather than a table of its own: no join, and the row is written then anyway. The addresses live and die with the session.
    - **`client`** (what the client calls itself at login, "WtF on Pixel 9") and **`created`:** so that a list of one's sessions can be recognised, and a lost phone's logged out.
    - **The key stays the token's hash, `bytea`:** compared as plain bytes, with no collation; a 33-byte key where a uuid is 16, which is nothing for one row per login.
    - **For the API** ([part 3](2026-10-31-api-refactor.md)): the database can't see the user's address (the API connects from `wtfd`), so `wtfd` passes it with the token.
26. **A quantity refers to its base unit** *(yours, in the review)*. `base_unit uuid NOT NULL REFERENCES unit (id) DEFERRABLE INITIALLY DEFERRED`, in place of the text columns `base_symbol` and `base_name`, which repeated what the unit row says.
    - **The cycle** quantity → unit → family → quantity is why the key is deferred: checked at commit, so a quantity, its family and its base unit are inserted in one transaction, in any order.
    - **A trigger** checks that the base unit is of this quantity (through its family), with factor 1 and offset 0; it replaces the check that a unit with the base symbol has them.
    - **Every base unit is a real unit in a family.** For the bootstrap units that means: Charge's family "Battery capacity" becomes **"Charge"**, with the coulomb (C, factor 1) beside mAh (3.6) and Ah (3600); Bytes' base is Decimal bytes' `B` (Binary bytes' `B` means the same, which the rule on shared symbols allows).
    - **Unit files** still state the base unit's symbol, matched on import against the quantity's base unit.
    - **Cost:** one join by primary key to show a base unit, on the units screens only; the deferred check runs at commit, for unit imports only.
27. **`standard` is NULL on a tenant's own quantity or family** *(yours, in the review)*: `standard boolean NULL` with `CHECK ((tenant IS NULL) = (standard IS NOT NULL))`. It only means something on global ones, so a tenant's row can't carry a value that is ignored.
28. **History's `happened_at` is `at`,** as in `deletion` *(revised by decision 37: `at` is the action's, and leaves `history`)* *(yours, in the review)*: one name for "when it happened". `when`, your first choice, is a reserved word in PostgreSQL and would need quoting everywhere; `at` is a keyword too, but not a reserved one.
29. **`tenant.code` is the last code handed out,** not the next *(yours, in the review)*: `DEFAULT 32767`, `CHECK (code >= 32767)`, and `next_code()` is `UPDATE … SET code = code + 1 … RETURNING code`, with nothing to subtract, where today it returns the value before the increment as `code - 1`.
30. **Every function is in a schema named after what it belongs to** *(yours, in the review)*. Tables, types and domains stay in `public`.
    - **Schemas, singular and named like their tables:** `tenant`, `account` (accounts, login, sessions), `unit` (quantities, families, units, a tenant's choices), `class` (classes, assignments, effective attributes), `attribute` (attributes, options), `item` (items, values), `location`, `stock` (stock rows, values, moves), `attachment`, `history`, `model` (model files), `code`, `meta`, and `util` for what belongs to nothing in particular (paging, names, code rendering, typed values, the generic rule helpers).
    - **The prefix becomes the schema:** `item_get` → `item.get`, `stock_move` → `stock.move`, `attribute_option_restore` → `attribute.option_restore`, `next_code` → `tenant.next_code`, `util.item_json` → `item.json`; trigger functions too (`item.check_container`).
    - **These schemas hold only functions, so they are the repeatable part** (decision 7): a rebuild drops each with `CASCADE`, taking their triggers along, and recreates them; `wtfd schema` still refuses if anything else would go. API functions are the `SECURITY DEFINER` ones, as today, and only they get `EXECUTE` for the API role, which gets `USAGE` on the schemas.
    - **Calls between functions are schema-qualified;** tables are named unqualified through `search_path = public, pg_temp`, and as `public.x` where a schema of the same name could mislead.
    - **For part 3:** the server calls the API functions by their new names.
31. **The error raisers are in a schema `error`** *(yours, in the review)*: the contract between the database and the API (which SQLSTATE means which HTTP status) in one place, and `util` left with utilities. `raise_` drops off, as the schema says it: `error.invalid`, `error.not_found`, `error.bad_reference`, `error.deleted`, `error.not_deleted`, `error.restore_into_deleted`, `error.unauthenticated`; and `error.row_label`, which words their messages. (The SQLSTATE of each is checked against `internal/serve/problem.go` in part 2.)
32. **"Live refers to live" is checked only when it could have changed, and only for writes** *(yours, in the review)*.
    - **The live triggers fire on insert, when a reference changes, and on restore** (`deleted` back to NULL), through `UPDATE OF <references>, deleted` with a `WHEN`; not on every update, as today, where renaming an item re-checks and locks its class.
    - **They stay triggers,** though the accessor has often just read the same row: the second read is of a page in memory, and the rule, with its lock, holds in one place for every path that writes.
    - **`util.check_live` is for writes only:** its `FOR SHARE` lock protects a write, and locking a row writes to it. Reads that care whether something is deleted read `deleted` themselves. Today one read uses it, `model_export`; it folds the check into its existence query instead (part 2).
    - **Static queries, one per table,** in place of `EXECUTE format(… %I …)`, so each is checked when the function is made.
33. **Deleted rows are frozen, accounts too, and the rule costs live rows nothing** *(yours, in the review)*.
    - **`WHEN (OLD.deleted IS NOT NULL)`** on the frozen-row triggers: PostgreSQL skips the function for live rows, where today it runs on every update and compares the whole row as JSON first.
    - **Accounts are frozen when deleted,** by the same trigger, as everything else; today only their accessors refuse it.
    - **Triggers are written out, one `CREATE TRIGGER` each:** no `DO` loops, for the frozen-row triggers and the history triggers alike, as for the attachment tables (decision 8).
    - **A rule's trigger has the same name on every table it guards** (`block_change_when_deleted`); trigger names are per table.
34. **Reads are set-based: nothing that reads walks a graph, or runs a query, once per row** *(yours, in the review)*. A list page asking the same question for every item, when the answer depends on the item's class, cost a walk up the class tree per item and per stock row: 200 for a page of 50 items.
    - **Helpers that reads use take arrays,** so one call answers for a whole page: `class.effective_attributes(p_classes uuid[])` walks up from all the classes in one recursive query; `item.missing_attributes(p_items uuid[])` and `stock.missing_attributes(p_stock uuid[])` return `(item or stock row, attribute)` pairs. A single object passes a one-element array.
    - **Graph walks start from every node needed at once,** never once per row; their cost grows with the classes or locations involved, not with the items.
    - **Lists are built in one query** with joins (and one `GROUP BY` for totals), not by calling a function per row that runs its own queries.
    - **Writes may work one row at a time** (a rule checking the one value written), since that is what they change.
    - **Where this applies today** (part 2): the text search and attribute filters of `item_list`, its `incomplete` flag, the class and location trees, and the per-row JSON of `item_list` and `stock_list`; listed in [the accessor document](2026-10-31-pl-pgsql-accessor-refactor.md).

35. **An attribute's datatype never changes** *(yours, in the review)*. It is chosen when the attribute is created; to change it, make a new attribute. A change would have to check every value, default and option, live and deleted (a deleted item restored later would bring back a value of the old datatype), and every rule that writes a value would have to lock the attribute against it.
    - **What it saves:** the `FOR SHARE` locks on the attribute in the option, default and value rules (R24, R25, R30), so writing a value no longer writes to the attribute's row; R23's update trigger; and the restore checks a datatype change would need.
    - **The rule:** `attribute.refuse_datatype_change` (R35).
    - **For the accessors** (part 2): `attribute_patch` no longer takes `datatype` (today it is required in every patch); a model import that finds an attribute with another datatype reports a conflict.
    - **For the apps:** the attribute form shows the datatype as fixed when editing ([2026-10-31-changes-to-the-apps.md](2026-10-31-changes-to-the-apps.md)).

36. **History takes the tenant from whoever makes the change** *(yours, in the review; revised by decision 37: from the action, and `wtf.tenant` goes)*. Most tables have no `tenant` (decision 1), and a row removed along with its owner (an item's values, when the item is purged) can't be traced to one once the owner is gone. So `history.record` takes it from the session (its account's tenant, in the same look-up that finds the account, decision 16) or, outside the API, from `wtf.tenant`, which `wtfd` sets for its own maintenance; a change with neither is refused, and for the tables that have a `tenant` it must match.
    - **For the API** (part 3): `wtfd`'s purge of deleted objects (`internal/admin/deleted.go`) runs one tenant at a time under `SET LOCAL wtf.tenant` (today it can purge every tenant in one statement); so does creating a tenant's first account.
37. **Every writing call makes one `action`; history and deletions refer to it** *(yours, in the accessor review)*. In place of `deletion` (decision 15), and of grouping history by transaction number and time, which used a timestamp as part of a key.
    ```sql
    -- One call that changed something: who, for which tenant, and when.
    CREATE TABLE action (
        id          uuid        NOT NULL PRIMARY KEY DEFAULT uuidv7(),
        tenant      uuid        NOT NULL REFERENCES tenant (id),
        account     uuid        NULL     REFERENCES account (id),  -- NULL: wtfd itself
        at          timestamptz NOT NULL DEFAULT now(),
        -- Only to check that the action in wtf.action was made in this
        -- transaction; never a key.
        transaction xid8        NOT NULL DEFAULT pg_current_xact_id()
    );
    ```
    - **Made explicitly:** each writing accessor starts with `util.begin_action(...)`, which inserts the row and puts its id in the transaction-local setting `wtf.action`; `wtfd`'s own maintenance (the purge, a tenant's first account) calls it with the tenant and no account. A change without an action is refused by history. Read-only calls make none.
    - **Deleted rows** refer to the action that deleted them: `deleted uuid NULL REFERENCES action (id)`; restoring is as decision 15 says, by `deleted = <action id>`.
    - **History** gets `action uuid NOT NULL REFERENCES action (id)`, and loses `account`, `transaction` and `at` (the action has them); it keeps `tenant`, which the pages per kind filter on with their index. A call's entries are grouped by `action`.
    - **`history.record`** reads the tenant and account from the action, one primary-key look-up per changed row, in place of a SHA-256 of the token and a session look-up (decision 16). It accepts only an action made in this transaction (`transaction = pg_current_xact_id()`): the API role can set `wtf.action` but can't insert an action, so it can't hand over another's.
    - **The purge** removes actions nothing refers to any more, neither a deleted row nor a history entry; `CREATE INDEX history_action_idx ON history (action)` serves that, and the check of history's foreign key when an action is removed (API decision 15).
38. **History records what each entry is about** *(yours, in the accessor review)*. In place of `object` (decision 17): `about uuid[] NOT NULL`, the ids the entry concerns, with `CREATE INDEX history_about_idx ON history USING gin (about)` in place of `(tenant, table_name, object)`. `history.record` fills it from the row's own columns, old and new, one line per table and no look-ups: an item its id and class; an item value its item; a stock row its id, item and location; a stock value its stock row; a class or location its id and parent; an assignment its class and attribute; an attribute its id; an option its id and attribute; an attachment its id and owner; an account its id; with the old value too where one changed. An object's history page is then `WHERE about @> ARRAY[<id>]`, reading only that object's entries (accessor decision 19). `(tenant, table_name, id)` stays, for the pages per kind.
39. **The units a tenant sees have a version too** *(yours, in the accessor review)*. `data_version` gets a third name, `'unit'` (`CHECK (name IN ('class', 'location', 'unit'))`), bumped once per statement, as the trees are (R56): on `tenant_quantity` and `tenant_unit_family`, and on a tenant's own `quantity`, `unit_family` and `unit` rows; a change to global ones (migrations, `wtfd`'s unit imports, both rare) bumps every tenant's in one statement. Clients keep the units as they keep the trees, and ask again with the version they have (accessor decision 27). The rule is R58.

## Review of the objects

Your review of every object, as it will be with the decisions applied, one at a time.

1. ~~Schema `extensions` and `pgcrypto`~~: unchanged, for bcrypt only.
2. ~~Domains `name_text` and `path_name`~~: as decision 13; the accessors trim, the domains don't refuse surrounding spaces.
3. ~~Enums `datatype`, `scope`, `role`, `history_operation`~~: `'float'` becomes `'decimal'` (decision 24); `role` relies on its order.
4. ~~`tenant`~~: as today, keyed by `uuidv7()`; `code` is the last code handed out, `CHECK (code >= 32767)` (decision 29).
5. ~~`account`~~: `role` from the start, `deleted` (its foreign key added after the `action` table, which refers back; decision 37), `email name_text`; `account_tenant_email_unique`, as decision 10's pattern applied to unique indexes.
6. ~~`session`~~: no `tenant` (decision 1); `client`, `created`, `max_idle` and the `usage` trail (decision 25).
7. ~~`deletion`~~, now `action` (decision 37): the column referring to it from deleted rows is `deleted`; `account.deleted` gets its foreign key after the table.
8. ~~`quantity`~~: `base_unit` in place of the base symbol and name (decision 26), `standard` NULL on tenants' own (decision 27).
9. ~~`unit_family`~~: `standard` NULL on tenants' own (decision 27), one `NULLS NOT DISTINCT` name index (decision 18).
10. ~~`unit`~~: the unique indexes start with `family`, so they also find a family's units and no index on `family` alone is needed; `quantity.base_unit` gets its foreign key after the table.
11. ~~`tenant_quantity`, `tenant_unit_family`~~: unchanged; not in history, as today.
12. ~~`class`~~: plain `parent` key, `path_name`, `photo` and `deleted` written in the table.
13. ~~`attribute`~~: as the decisions make it.
14. ~~`attribute_option`~~: no `tenant`; `UNIQUE (attribute, id)` for the option keys; no hand-set order, as today.
15. ~~`class_attribute`~~: `scope`, the `default_*` columns, plain keys; no index on `default_option`.
16. ~~`item`~~: no `tenant`, a plain index on `code`; tenant-wide queries join `class`.
17. ~~`item_value`~~: as the decisions make it; the option index partial (`WHERE option IS NOT NULL`).
18. ~~`location`~~: the twin of `class`, with `UNIQUE (tenant, code)` kept.
19. ~~`stock`~~: `amount`, no `tenant` (through the location), a plain index on `code`.
20. ~~`stock_value`~~: the shape of `item_value`.
21. ~~`attachment`~~: as decision 8, with the photo keys `ON DELETE SET NULL (photo)`; `hash` stays hex text; `wtfd gc` joins the four owners for the tenant. An index on `attachment (hash)` for it (API decision 16).
22. ~~`data_version`~~: `CHECK (name IN ('class', 'location', 'unit'))` (decision 39); bumped per statement (decision 22).
23. ~~`history`~~: `object` (decision 17), `action` in place of `account`, `transaction` and `at` (decision 37), `about` in place of `object` (decision 38); keyed by `bigint`, as an append-only table never referred to.

Then the repeatable rules and helpers (decision 7), named as decision 30 makes them:

- R1. ~~`tenant.next_code`~~: returns the counter after the increment (decision 29). Revised in the accessor review (accessor decision 32): `tenant.take_codes(p_tenant, p_count)`, which takes several at once and returns the first.
- R2. ~~`util.typed_value_fits`~~ (was `typed_column_is_set`): five values; an `integer` must be whole.
- R3. ~~`error.row_label`~~: one `'attachment'` branch, an `'account'` branch, a stock row named with its code.
- R4. ~~`error.deleted`~~ (was `raise_deleted`), decision 31.
- R5. ~~`util.check_live`~~: static queries, writes only (decision 32).
- R6. ~~`util.block_change_when_deleted`~~: decision 33.
- R7. ~~`util.prevent_tree_cycle`~~: static queries; runs only when the parent changes to another node; a message without ids. Two simultaneous moves of each other's nodes could still make a cycle; noted, not locked against.
- R8. ~~`unit_tenant_fits`~~: no longer a function; inlined, with its explanation as a comment, in the two rules that use it (a unit family's quantity, a unit's family).
- R9. ~~`unit_quantity`~~: no longer a function. A SQL function with a `FROM` is never inlined, so each call is a separate sub-query; the four places that use it (the two unit rules, whole stock amounts, model import) join `unit_family` themselves, which also says what happens.
- R10. ~~`stock.check_whole`~~: `item_counts_whole` folded into the one rule that used it, with the joins written out; the trigger's `WHEN (NEW.amount <> trunc(NEW.amount))` skips it for whole and uncounted amounts, nearly all of them; the message names the item.
- R11. ~~`attachment.file_lock_key`~~: moved to the schema `attachment`, as a SQL function; `wtfd gc` calls it by its new name (part 3). The approach itself (an advisory lock keyed by part of the hash) is to be replaced later: in TODO.md.
- R12. ~~`class.attribute_scope`~~: returns `scope`; used only by the rules, never by a read (checked). The rules writing one value keep it (one walk up the tree per value written); the rules that check many values at once (an item changing class, a stock row changing item, removing an assignment or changing its scope, moving a class) work out each affected class's attributes once with `class.effective_attributes` and join, in place of a walk per value. A table of each class's ancestors would make every walk one look-up; not now.
- R13. ~~`class.effective_attributes`~~: in place of the view (decision 21); columns `assigned_to` and `depth`. Used by reads: once per get, which is fine, and once per candidate item in a filtered `item_list`, which part 2 changes to once per class.
- R14. ~~`class.check_values_still_apply`~~ (was `check_values_applicable_in_subtree`), with `class.check_assignment_change` and `class.check_move`: set-based (each class's attributes worked out once); the message counts the items and names one; the assignment trigger fires on removal and on a change of `scope` only.
- R13 (revised). ~~`class.effective_attributes(p_classes uuid[])`~~: for many classes in one recursive query (decision 34); R14 passes the subtree's classes in one call.
- R15. ~~`item.missing_attributes(p_items uuid[])`~~: replaces `required_without_default` and `item_missing_attributes`; built on `class.effective_attributes`, for many items at once (decision 34).
- R16. ~~`stock.missing_attributes(p_stock uuid[])`~~: the twin of R15 for stock rows, through each row's item's class; one walk for all the rows given.
- R17. ~~`error.attribute_names`~~: in the `error` schema, as SQL; runs only when a required-value rule is about to fail.
- R18. ~~`unit.check_family`~~: the tenant-fit check written out; an advisory lock on (the table, a hash of the lower-case name) before the name check, where a hash collision only means an unneeded wait; the update trigger runs only when the quantity or the name (letter case ignored) actually changes.
- R19. ~~`unit.check_quantity`~~: the name rule of R18 for quantities, without a tenant-fit check; the base unit is checked at commit (R20).
- R20. ~~`unit.check_base_unit`~~ (new): deferred; the base unit is in one of the quantity's own families, with factor 1 and offset 0; checked on a new quantity and when its base unit, that unit's family, factor or offset, or that family's quantity changes. Open, not taken up: making those unit and family columns unchangeable instead.
- R21. ~~`unit.check_unit`~~: the base-symbol check gone (R20 does it); one advisory lock per quantity covers both the symbol and the name checks; the update trigger runs only on a real change.
- R22. ~~`unit.check_same_quantity`~~ (was `check_unit_change`): one query with the joins written out; the message names the item or attribute; renamed so its trigger name differs from R21's.
- R23. ~~`attribute.check_unit`~~: one query with the joins written out; "has a unit" and "really changed" in `WHEN`; trigger `check_unit_datatype`, so its name differs from R21's. Revised by decision 35: only the insert trigger; the update one goes, as neither the datatype nor the unit's quantity can change.
- R24. ~~`attribute.check_option_choice`~~: the message names the attribute. Revised by decision 35: no lock, as the datatype can't change.
- R25. ~~`class.check_default`~~ (was `class_attribute_check_datatype`): `util.typed_value_fits`; "has a default" and "the default or attribute really changed" in `WHEN`; no lock (decision 35); the option default's attribute is the foreign key's job.
- R26. ~~`item.check_container`~~: also on restore, which closes a gap (an item deleted, its class made a container, the item restored); the `FOR SHARE` lock on the class stays, as the foreign key's `FOR KEY SHARE` doesn't block a change of `container`.
- R27. ~~`class.check_container`~~: `EXISTS` decides, the count and one item's name only for the message; `WHEN` in the trigger; no lock needed, as the update's own row lock waits for R26's.
- R28. ~~`stock.check_container`~~: the twin of R26 for stock rows and locations, also on restore.
- R29. ~~`location.check_container`~~: the twin of R27; the message names one stock row with `error.row_label`.
- R30. ~~`attribute.check_value_datatype`~~ (was `value_check_datatype`): `util.typed_value_fits`, for both value tables; the update triggers run only on a real change; no lock on the attribute (decision 35, which replaced the `FOR SHARE` lock first agreed).
- R31. ~~`item.check_value_applies`~~ (was `value_check_applicable`): uses `class.attribute_scope`; names the item and attribute. A restored item's values are checked by R33, which also runs on restore (a gap today).
- R32. ~~`stock.check_value_applies`~~ (was `stock_value_check_applicable`): the twin of R31; named by the stock row's item.
- R33. ~~`item.check_values_still_apply`~~ (was `item_check_class_change`): set-based, the new class's attributes worked out once; also on restore; the message names the item, the class and every attribute that doesn't apply.
- R34. ~~`stock.check_values_still_apply`~~ (was `stock_check_item_change`): the twin of R33 for a stock row moving to another item or being restored.
- R35. ~~`attribute.refuse_datatype_change`~~ (was `attribute_check_datatype_change`): refuses every change of datatype (decision 35).
- R36. ~~`item.check_required`~~: built on `item.missing_attributes`; deferred, per row (PostgreSQL has no deferred statement triggers); runs on insert, on restore and, new, when an item changes class; reads the item's name and liveness at commit.
- R37. ~~`item.check_required_value_removal`~~: deferred; returns early when the item is deleted or purged (so a purge costs a look-up per value, not a walk), then asks `item.missing_attributes`; names the item and the attribute.
- R38. ~~`stock.check_required`~~: the twin of R36 for stock rows; runs on insert, on restore and when a row moves to another item; names the item.
- R36 (revised). ~~`item.check_required`~~: when an item changes class, also checks its live stock rows, all in one `stock.missing_attributes` call.
- R39. ~~`stock.check_required_value_removal`~~: the twin of R37, with the early return.
- R40–R47. ~~The rules that live rows refer only to live rows~~: `class.check_live`, `location.check_live`, `item.check_live`, `stock.check_live`, `attribute.check_option_live`, `item.check_value_live`, `stock.check_value_live`, `class.check_assignment_live`; each calls `util.check_live` on insert, when a reference really changes, and on restore (decision 32). On restore, `item.check_live`, `stock.check_live` and `class.check_live` also check, in one query after locking them, that their values' or assignments' attributes and options are live: those have no `deleted` of their own, and an attribute or option can be deleted while its owner is. This replaces the restores' no-op updates (`UPDATE value SET item = item …`), which only re-fired the value triggers and fire nothing once the triggers have a `WHEN`.
- R48. ~~`attachment.check_live`~~: one function for the one table, four static `util.check_live` calls; on insert, an owner change and restore.
- R49. ~~`attachment.check_photo`~~: one static query; "no photo" and "unchanged" in `WHEN`; on the four owner tables.
- R50. ~~`attachment.check_not_photo`~~ (new): a live object's photo can't be deleted, which today only the accessor ensures; four primary-key look-ups, on deletion only.
- R51–R55. ~~The deletable rules~~: `class.check_deletable`, `location.check_deletable`, `item.check_deletable`, `attribute.check_deletable`, `attribute.check_option_deletable`; as today, with `deleted IS NULL` and the new names. An object's own parts (an attribute's options, an item's values, its attachments) stay as they are when it is deleted and come back with it.
- R56. ~~`util.bump_tree_version` and `attachment.bump_tree_version`~~ (was `bump_data_version`): once per statement, with transition tables, three triggers per table (insert, update, delete); the tree's name is the table's; attachments find their tenant through their class or location.
- R57. ~~`history.record`~~ (was `record_history`): the tenant from the session or `wtf.tenant` (decision 36); `object` filled; eleven triggers written out. Revised by decision 37: the action (from `wtf.action`, made in this transaction) gives the tenant and account; entries refer to it. And by decision 38: it fills `about` in place of `object`.

- R14 (revised, from the accessor review). ~~`class.check_assignment_change`~~ also runs on insert, when a class above assigns the same attribute with another scope: a new own assignment overriding an inherited one could leave the subtree's values on the wrong side (item values where the nearest assignment now says stock rows). Set-based, as for a change of scope; it costs only when an assignment is added. Closes the gap for `class.assign` and model import alike.
- R58. ~~`unit.bump_version`~~ (new, decision 39): once per statement on the five unit tables; for a global row, every tenant's `unit` version.

The review is done.


## Plan

Part 1 is written on a branch and goes live with parts 2 and 3: the new schema can't serve the API until the accessors are rewritten, and the database is reset only when all three are done (decision 6).

1. **The migrations, rewritten.**
    - `db/migrations/0001_schema.sql`: the extensions, domains, enum and composite types (with `request`, accessor decision 22, and `owner_kind`, accessor function 66), the collation `public.natural` (accessor decision 5), the tables in the order of the review (objects 1–23) with their constraints and indexes, the foreign keys that close a cycle (`account.deleted`, `quantity.base_unit`) added after the table they refer to, and `CREATE SCHEMA` for each schema of decision 30, each with `ALTER DEFAULT PRIVILEGES … REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC` (accessor decision 1). No functions, unless a constraint needs a wrapper (decision 7); none does now.
    - `db/migrations/0002_units.sql`: the bootstrap units as object 24 has them (the coulomb in "Charge", base units with their ids written out).
    - `0003_renames.sql` and `0004_roles.sql` go: what they did is in the new `0001`.
2. **The rules, as repeatable scripts** in `db/repeatable/`, one file per schema, each with its trigger functions and, after them, the `CREATE TRIGGER` statements: `error`, `util`, `tenant`, `unit`, `class`, `attribute`, `item`, `stock`, `location`, `attachment`, `history` (R1–R58). Ordered so that a SQL function's body only names what already exists (PostgreSQL checks those when the function is made; PL/pgSQL bodies only when they run): `error` and `util` first, then `class` before `item` and `stock`, which build on `class.effective_attributes`.
3. **`wtfd schema` (`internal/schema/`)** learns the schemas: a rebuild drops each function schema with `CASCADE` (which takes the triggers along) and lets the scripts make them again; its refusal to drop anything but functions, triggers and views checks every one of those schemas, not only `util`; and its check that `PUBLIC` can execute none of our functions covers them too. The API role's grants follow part 2, which decides where the API functions live.
4. **Tests of the rules,** in `internal/integration/`, on a database with the new schema and no API: for each rule, a change it allows and one it refuses, including the races the locks close where that can be shown with two connections, and the gaps closed in the review (restoring into a container, values of deleted options, a deleted photo). And a benchmark (accessor decision 30): a generated tenant of about 50,000 items, `item.list` timed and explained with no search, a filter and a search.
5. **SCHEMA.md** rewritten for the new `0001` and the rules (topic E3).
6. **Then part 2,** the accessors, which starts from the topics collected in its document.

## Log

- **2026-10-31:** document started; the model surveyed and the topics listed.
- **2026-10-31:** decision 1, `tenant` only where it's needed; principle 6 rewritten to match.
- **2026-10-31:** decision 2, scopes `item` and `stock` (A1, A3, A6); the apps' changes are collected in [2026-10-31-changes-to-the-apps.md](2026-10-31-changes-to-the-apps.md).
- **2026-10-31:** decision 3, a stock row's `amount` (A2).
- **2026-10-31:** decision 4, typed columns `text`, `number`, `date`, `boolean`, `option` (B1, B4, A4); the defaults `default_text` … `default_option`.
- **2026-10-31:** decision 5, `item_value` keyed by `(item, attribute)` (B2); decision 6, the schema starts over (E1).
- **2026-10-31:** decision 7, rules in repeatable scripts, constraints calling them through wrappers (E2, E3).
- **2026-10-31:** decision 8, one `attachment` table (B3).
- **2026-10-31:** decision 9, `media_type` (A7); principle 9, one-word column names where clear.
- **2026-10-31:** decision 10, index names (A5); principle 5 rewritten to match.
- **2026-10-31:** decision 11, UUID v7 keys and PostgreSQL 18 (B7).
- **2026-10-31:** decision 12, `quantity.datatype` unchanged (B6); decision 13, domains `name_text` and `path_name` (B8).
- **2026-10-31:** decision 14, containers unchanged (B5).
- **2026-10-31:** decision 15, the `deletion` table (C1, C2); principle 7 rewritten to match. Decision 16, history's account unchanged (C3); decision 17, history's `object` (C4).
- **2026-10-31:** decision 18, `NULLS NOT DISTINCT` unit indexes and a lock in their triggers (D1).
- **2026-10-31:** decision 19, no tenant trigger on units (D2).
- **2026-10-31:** decision 20, the label-code counter unchanged (D3). Every topic is decided.
- **2026-10-31:** principles confirmed; principle 2 says the accessors are the database's own functions. Topics F1–F3 added (runtime cost) and decided: 21, the effective attributes as a function; 22, `data_version` per statement; 23, no new history index.
- **2026-10-31:** the review of the objects started; decision 24, `'decimal'` in place of `'float'`; decision 25, sessions with a chosen lifetime and an address trail.
- **2026-10-31:** decision 26, a quantity refers to its base unit (and the coulomb joins mAh and Ah in the family "Charge"); decision 27, `standard` NULL on tenants' own rows; decision 28, history's `at`; decision 29, `tenant.code` the last code handed out; decision 30, functions in schemas named after what they belong to; decision 31, the schema `error`; decision 32, live checks only when they can have changed, and only for writes; decision 33, frozen rows (accounts too), triggers written out; decision 34, reads are set-based.
- **2026-10-31:** decision 35, an attribute's datatype never changes (in the review).
- **2026-10-31:** the review finished (R36–R57); decision 36, history's tenant from whoever makes the change; the plan written.
- **2026-10-31:** decision 37, the `action` table in place of `deletion`, for history and deletions (from the accessor review, E1); decisions 15, 16, 28 and 36 revised.
- **2026-10-31:** decision 38, history's `about` in place of `object` (from the accessor review, E2); decision 17 replaced.
- **2026-11-01:** decision 39, a version for the units a tenant sees (from the accessor review); R58.
- **2026-11-01:** R14 revised: the assignment rule also runs on insert (from the accessor review, model import).
- **2026-11-01 (overnight, decided on my own; to review):**
    - **The function schemas are made by the repeatable scripts, not by `0001`** (each script starts with `CREATE SCHEMA`), and `wtfd schema` drops them with `CASCADE` on a rebuild, as decision 30 says. Step 1 had them in the migration with `ALTER DEFAULT PRIVILEGES IN SCHEMA … REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC`, but PostgreSQL can't revoke per schema (per-schema default privileges only add to the global ones), and a schema dropped on rebuild would lose them anyway. New functions stay closed to `PUBLIC` through the global default privilege that `wtfd schema` already sets, and its grant check covers every function schema.
    - **`unit_family_tenant_lower_name_unique`** for the unit's name index: by decision 10's pattern it and the unit family's name index were both `unit_family_tenant_name_unique`, which PostgreSQL refuses.
    - **`wtfd schema`'s guard** before dropping the function schemas refuses when anything but functions, triggers, views and their types is in them, or when anything outside them (a default, a constraint, an index) uses one of their functions, naming each.
    - **`util.begin_action` is written with the rules** (step 2), as the rules' tests need actions; the rest of part 2's shared pieces follow there.
    - **The API's integration tests are skipped** (`setup` in `internal/integration/setup_test.go`) until part 3 rewrites them: the old accessors went with the old schema, so the old API can't run between parts 1 and 3. The new tests (`database_test.go`, `schema_test.go`, `rules_test.go`) run against the new schema alone.
    - **The benchmark** (step 4) needs `item.list`, so it is written with the accessors' tests (accessor plan, step 4).
- **2026-11-01:** steps 1–4 done: `0001` and `0002` rewritten, `0003` and `0004` gone; the rules in `db/repeatable/` (`10_error`, `11_util`, `12_tenant`, `21_unit`, `30_class`, `31_attribute`, `40_item`, `41_location`, `42_stock`, `50_attachment`, `70_history`); `wtfd schema` for function schemas and PostgreSQL 18; the rules' tests.
