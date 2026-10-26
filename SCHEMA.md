# WtF Database Schema

Target: PostgreSQL 15+ (`gen_random_uuid()` is built in since 13; `UNIQUE ... NULLS NOT DISTINCT` needs 15).

The schema is created and upgraded by `wtfd schema` (see [WTFD.md](WTFD.md)) from the SQL files in [db/](db/).

All data access goes through the functions described in [API.md](API.md). The ER diagram is in [SCHEMA.html](SCHEMA.html).

## Concepts

| Table             | Meaning                                                                          |
|-------------------|----------------------------------------------------------------------------------|
| `class`           | A category in a tree (Tools → Power tools → Drills). Attributes are inherited down the tree. |
| `quantity`        | A physical quantity ("Length", "Mass", "Resistance"). Numbers of a quantity are always stored in its SI base unit. |
| `unit`            | A unit of measure of one quantity ("millimetre" / "mm"), with its conversion to the quantity's SI base unit. |
| `unit_group`      | A set of related units of one quantity that a number is scaled between on output ("Metric length": nm … km). |
| `unit_group_unit` | Membership of a unit in a unit group. A unit may be in several groups.          |
| `attribute`       | A global, reusable property definition ("Weight", "Voltage") with a fixed datatype and an optional unit group. |
| `attribute_option`| An allowed option for a `choice` attribute ("0805", "0603", "THT"). Listed alphabetically by the API. |
| `class_attribute` | Assigns an attribute to a class (and thereby to all its descendants): with an optional default, as per kind or per unit, and optionally required. |
| `item`            | A *kind* of thing ("M3x10 hex screw", "Makita DHP482 drill"). Belongs to exactly one class, and optionally names the unit group its stock is measured in (none = pieces). |
| `value`           | The value of one per-kind attribute for one item. Numbers with a unit group are in the base unit. |
| `stock_value`     | The value of one per-unit attribute for one stock row (serial number, purchase date, …). Same rules as `value`. |
| `location`        | A place in a tree (House → Garage → Shelf 2 → Bin 4).                            |
| `stock`           | The physical things: a quantity of an item at a location.                        |
| `code_sequence`   | The shared sequence that numbers the label codes of locations, items and stock rows (see [api/code.md](api/code.md)). |
| `tenant`          | An independent inventory, reached through its own hostname (see [TENANTS.md](TENANTS.md)). |
| `account`         | A user of one tenant: email (unique per tenant), bcrypt password hash, and the data, model and account privileges. |
| `session`         | A login: the SHA-256 of its token, its account and when it was last used. |
| `history`         | One entry per changed row of tenant data: when, transaction, account, table, operation, the row, and the changed columns (see [api/history.md](api/history.md)). |
| `file`            | A stored file content, by SHA-256 hash and size. The bytes live on disk in `wtfd`'s files directory (see [api/attachment.md](api/attachment.md)). |
| `attachment`      | A file attached to exactly one item, stock row, location or class, with file name, content type, caption and a primary photo flag. |
| `data_version`    | A change counter per tree (`class`, `location`), so clients can cheaply check whether their cached tree is still current. |

### Conventions

- Reference columns are named after what they reference, without an `_id` suffix (`parent`, `class`, `item`).
- Nullable columns are marked `NULL` explicitly.
- Unique indexes and unique constraints have names ending in `_unique`.

### Integrity rules enforced by the database

- Class and location trees cannot contain cycles (trigger).
- Sibling names are unique, case-insensitively, within the same parent class/location.
- Class and location names can't contain `/` (CHECK, migration 0008). Clients join names with `/` into paths (`Garage/Shelf 2`), so a path always means one thing.
- **Containers** (migration 0009): a class or location with `container` set holds only other classes or locations. Items can't be in a container class, and stock can't be at a container location; inserts, updates and moves are all checked (triggers, which lock the class or location row). A node can only become a container while it holds no items or stock (trigger).
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
- Quantities, units and unit groups are system data (seeded). The API only reads them.
- Every unit converts to its quantity's base unit as `base = value × base_factor + base_offset`. The base unit is the one with factor 1 and offset 0; there is at most one per quantity (unique index).
- Unit symbols are unique (case-sensitive: `mS` ≠ `ms`); unit names are unique case-insensitively.
- A unit can only be in unit groups of its own quantity (trigger).
- Every number that has a unit group (values, defaults, stock quantities) is stored in the base unit of the group's quantity. The database never converts stored numbers.
- Each quantity has a datatype: `integer` for Count, `float` for everything else. An attribute with a unit group must have its quantity's datatype (trigger).
- Stock quantities of an item without a unit group (pieces), or with an integer quantity, must be whole numbers (triggers).
- An attribute's or item's unit group can only change to another group of the same quantity (e.g. Metric length → Imperial length). Adding a group where there was none, or removing one, is not allowed (trigger).
- An absent `value` row means "no value". Rows where every typed column is NULL are not allowed.
- **Tenants:** every tenant-scoped table (class, attribute, attribute_option, class_attribute, item, value, location, stock, stock_value, attachment, session) has a `tenant` column. Every reference between them is a composite foreign key `(tenant, x) → (tenant, id)`, so a reference can never cross tenants. Names are unique per tenant. This duplication of the tenant is deliberate; it keeps tenant boundaries declarative.
- **History** is written by one row-level trigger (`record_history`) on every tenant data table and `account`. Password hashes are never logged, and updates that only touch the lockout counters aren't either. History copies past states on purpose; the current data never depends on it.
- **Accounts are never deleted,** only marked `deleted`, so history can always refer to them. Email uniqueness only applies to accounts that aren't deleted.
- **Shared between tenants:** quantities, units, unit groups, stored `file` contents and `code_sequence`.
- An attachment belongs to exactly one item, stock row, location or class: four nullable foreign keys, exactly one set (CHECK). It is deleted with its object. At most one attachment per object is the primary photo (partial unique indexes), and it must be an image (CHECK).
- Every location, item and stock row has a `code`, the next number from `code_sequence`. One sequence for all three tables makes codes globally unique by construction, and a unique index per table guards it. The API renders codes in Crockford Base32 (`1000`, `1A7K`, …).
- Every statement that changes `class` or `location` increments that table's counter in `data_version` (statement-level triggers). The counter row is locked until commit, so concurrent changes are serialised and every committed change produces a new value.

## DDL

The SQL is in [`db/migrations/0001_schema.sql`](db/migrations/0001_schema.sql), with later changes in further migrations in [`db/migrations/`](db/migrations/), e.g. [`0003_codes.sql`](db/migrations/0003_codes.sql).

## Open questions

None at the moment.

### Deferred

- **Attributes on physical things.** Values attach to `item` (the kind). Serial numbers, purchase dates and condition belong to one physical unit (a `stock` row).
- **History.** A movement/audit log (what moved where, when).
- **Users/ownership.**
