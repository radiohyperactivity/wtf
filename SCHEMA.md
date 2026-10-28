# WtF Database Schema

Target: PostgreSQL 15+ (`gen_random_uuid()` is built in since 13; `UNIQUE ... NULLS NOT DISTINCT` needs 15).

The schema is created and upgraded by `wtfd schema` (see [WTFD.md](WTFD.md)) from the SQL files in [db/](db/).

All data access goes through the functions described in [API.md](API.md). The ER diagram is in [SCHEMA.html](SCHEMA.html).

## Concepts

| Table             | Meaning                                                                          |
|-------------------|----------------------------------------------------------------------------------|
| `class`           | A category in a tree (Tools → Power tools → Drills). Attributes are inherited down the tree. |
| `quantity`        | A physical quantity ("Length", "Weight", "Resistance"). Numbers of a quantity are always stored in its base unit. |
| `unit_family`     | A set of related units of one quantity that a number is scaled between on output ("Metric length": nm … km). A quantity can have several. |
| `unit`            | A unit of measure in one family ("millimetre" / "mm"), with its conversion to the quantity's base unit. |
| `attribute`       | A global, reusable property definition ("Weight", "Voltage") with a fixed datatype, an optional unit and Unit lock. |
| `attribute_option`| An allowed option for a `choice` attribute ("0805", "0603", "THT"). Listed alphabetically by the API. |
| `class_attribute` | Assigns an attribute to a class (and thereby to all its descendants): with an optional default, as per kind or per unit, and optionally required. |
| `item`            | A *kind* of thing ("M3x10 hex screw", "Makita DHP482 drill"). Belongs to exactly one class, and optionally has the unit its stock is measured in (none = pieces), with Unit lock. |
| `value`           | The value of one per-kind attribute for one item. Numbers with a unit are in the base unit. |
| `stock_value`     | The value of one per-unit attribute for one stock row (serial number, purchase date, …). Same rules as `value`. |
| `location`        | A place in a tree (House → Garage → Shelf 2 → Bin 4).                            |
| `stock`           | The physical things: a quantity of an item at a location.                        |
| `tenant`          | One inventory: its `host` (the first label of its hostnames) and `next_code`, the next label code of its locations, items and stock rows (see [TENANTS.md](TENANTS.md) and [api/code.md](api/code.md)). |
| `tenant_quantity`, `tenant_unit_family` | A tenant's choices of which quantities and unit families it has available; only where it differs from the default. |
| `account`         | A user: email, bcrypt password hash, and the data, model, account and history privileges (see [ACCOUNTS.md](ACCOUNTS.md)). |
| `session`         | A login: the SHA-256 of its token, its account and when it was last used. |
| `history`         | One entry per changed row of data: when, transaction, account, table, operation, the row, and the changed columns (see [api/history.md](api/history.md)). |
| `item_attachment`, `stock_attachment`, `location_attachment`, `class_attachment` | The files attached to an item, stock row, location or class: id, the object, MIME type, SHA-256 hash, size and title. The bytes live on disk in `wtfd`'s files directory, named by the hash (see [api/attachment.md](api/attachment.md)). |
| `data_version`    | A change counter per tree (`class`, `location`), so clients can cheaply check whether their cached tree is still current. |

### Conventions

- Reference columns are named after what they reference, without an `_id` suffix (`parent`, `class`, `item`).
- Nullable columns are marked `NULL` explicitly.
- Unique indexes and unique constraints have names ending in `_unique`.

### Integrity rules enforced by the database

- Class and location trees cannot contain cycles (trigger).
- Sibling names are unique, case-insensitively, within the same parent class/location.
- Class and location names can't contain `/` (CHECK). Clients join names with `/` into paths (`Garage/Shelf 2`), so a path always means one thing.
- **Containers:** a class or location with `container` set holds only other classes or locations. Items can't be in a container class, and stock can't be at a container location; inserts, updates and moves are all checked (triggers, which lock the class or location row). A node can only become a container while it holds no items or stock (trigger).
- A value has exactly one typed column filled (CHECK), and it is the one matching its attribute's datatype (trigger).
- `url` values and defaults are stored in the text column and must start with `http://` or `https://` (trigger). Full validation is done by the API.
- An attribute's datatype cannot be changed while values, defaults or options exist for it (trigger).
- A value can only be stored for an attribute that applies to the item's class, directly or by inheritance (trigger).
- An item's class cannot be changed if that would leave existing values without a matching attribute (trigger).
- An attribute cannot be removed from a class, and a class cannot be moved to a new parent, if that would leave existing values without a matching attribute (triggers).
- A class attribute's default is optional. At most one typed column is filled (CHECK), and it is the one matching the attribute's datatype (trigger).
- A choice value or default can only reference an option of its own attribute (composite FK). Options can only be added to `choice` attributes (trigger).
- Datatype triggers lock the attribute row (`FOR SHARE`), so a concurrent datatype change can't slip past them.
- An item has at most one value per attribute, and so has a stock row.
- **Scope:** a class assignment is *per kind* (values on the item, in `value`) or *per unit* (values on each stock row, in `stock_value`). As with defaults, the nearest assignment in the class path wins (`attribute_scope`). A value can only be stored for an attribute of its scope (triggers). Changing an item's class, a stock row's item, a class's parent, or an assignment's scope is rejected if it would leave values without an attribute of the right scope.
- **Required:** an assignment can be `required`. A new item, or a new stock row for per-unit attributes, must have a value for every required attribute without a default. Removing such a value is rejected. Both checks are deferred constraint triggers, which run at commit, so an object can be created first and its values added afterwards in the same transaction. Making an attribute required later never blocks anything; the API reports such gaps as `missing`.
- Every table of tenant data has a `tenant` column, `UNIQUE (tenant, id)`, and composite foreign keys `(tenant, x) → (tenant, id)`, so a row never refers to another tenant's ([TENANTS.md](TENANTS.md)).
- Quantities, unit families and units are global (`tenant` NULL: seeded, see [seed/units.md](seed/units.md), or imported by the operator) or a tenant's own (imported from unit files, [seed/units-format.md](seed/units-format.md)). A tenant's family may be in a global quantity, and its unit in a global family. Names and symbols are unique among what a tenant sees. Global quantities and families have `default_available`.
- Every quantity names its base unit (`base_symbol`, `base_name`; migration `0003_base_units.sql`). A unit with that symbol must have factor 1 and offset 0 (trigger).
- Every unit converts to its quantity's base unit as `base = value × base_factor + base_offset`.
- Unit symbols are unique within a family (case-sensitive: `mS` ≠ `ms`), and unit names case-insensitively. Family names are unique case-insensitively.
- The same symbol may be in several families of one quantity (`B` in decimal and binary bytes), but only for units that convert the same (trigger).
- Every number that has a unit (values, defaults, stock quantities) is stored in the base unit of the unit's quantity. The database never converts stored numbers.
- Each quantity has a datatype: `integer` for Count, `float` for everything else. An attribute with a unit must have its quantity's datatype (trigger).
- Stock quantities of an item without a unit (pieces), or with an integer quantity, must be whole numbers (triggers).
- An attribute's or item's unit can only change to another unit of the same quantity, in any family (e.g. mm → in). Adding a unit where there was none, or removing one, is not allowed (trigger).
- Unit lock can only be set together with a unit (CHECK).
- An absent `value` row means "no value". Rows where every typed column is NULL are not allowed.
- **History** is written by one row-level trigger (`record_history`) on every data table and `account`. Password hashes are never logged, and updates that only touch the lockout counters aren't either. History copies past states on purpose; the current data never depends on it. Only restoring reads it, to find what was deleted together, and without that history it restores the object alone.
- **Accounts are never deleted,** only marked `deleted`, so history can always refer to them. Email uniqueness only applies to accounts that aren't deleted.
- **Deleting marks rows** (see [api/deleting.md](api/deleting.md)): items, stock rows, locations, classes, attributes, options and attachments have `deleted`, and only a purge removes them. Their values, assignments and attachments aren't marked; they stay with them. The rules in this list apply between live (not deleted) rows only:
  - Sibling names, attribute names and option names are unique among a tenant's live rows (partial unique indexes). Label codes stay unique across all of a tenant's rows.
  - A live row only refers to live rows: a stock row's item and location, an item's class, a parent, an option's attribute; a value's, default's or attachment's owner, attribute and option (triggers, which lock the referenced row).
  - A row can only be marked deleted while nothing live depends on it (triggers, 23001).
  - A deleted row is frozen: any change other than restoring it is refused (trigger, 55000). So are changes to its values, assignments and attachments.
  - Containers, required attributes, value scopes and datatype changes only count live rows. Restoring a row checks it again, required attributes included (deferred constraint triggers).
  - A stock row merged into another by a move is deleted, with `merged_into` pointing to that row (CHECK: only on deleted rows; cleared when that row is purged).
- **Attachments** (migrations `0005_attachments.sql`, `0006_attachment_deleted.sql`) belong to exactly one object, in the table of its kind; nothing is shared. Deleting one marks it deleted; a deleted attachment can't be a photo (trigger). A deleted object keeps its attachments, frozen (trigger); purging it removes them. The same content is stored once on disk, however many attachments have its hash.
- **Photos:** items, stock rows, locations and classes have a nullable `photo`. The foreign key `(id, photo) → <kind>_attachment (<kind>, id)` makes it one of the object's own attachments, and clears it when that is deleted; a trigger checks that it is an image.
- Every location, item and stock row has a `code`, the next number of its tenant (`next_code(tenant)`, which takes `tenant.next_code`). One counter for all three tables makes codes unique within the tenant by construction, and a unique index `(tenant, code)` per table guards it. Two tenants have the same codes for different things. The API renders codes in Crockford Base32 (`1000`, `1A7K`, …).
- Every statement that changes `class` or `location` increments that table's counter in `data_version` (statement-level triggers). So does every statement that changes `class_attachment` or `location_attachment` (`0007_tree_photos.sql`), because the tree nodes include their photo, whose title can change. The counter row is locked until commit, so concurrent changes are serialised and every committed change produces a new value.

## DDL

The SQL is in [`db/migrations/0001_schema.sql`](db/migrations/0001_schema.sql). Later changes will go in further migrations in [`db/migrations/`](db/migrations/).

## Open questions

None at the moment.

### Deferred

- **Attributes on physical things.** Values attach to `item` (the kind). Serial numbers, purchase dates and condition belong to one physical unit (a `stock` row).
- **History.** A movement/audit log (what moved where, when).
- **Users/ownership.**
