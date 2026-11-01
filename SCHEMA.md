# WtF Database Schema

Target: PostgreSQL 18 or newer (`uuidv7()` is built in since 18). The server must be built with ICU, for the collation that sorts names (the official `postgres:18` image is).

The schema is created and upgraded by `wtfd schema` (see [WTFD.md](WTFD.md)) from the SQL files in [db/](db/):

- **[db/migrations/](db/migrations/)** holds what holds data: the tables, their columns, constraints and indexes, the types and domains, and the bootstrap units. A migration runs once and is then frozen. [`0001_schema.sql`](db/migrations/0001_schema.sql) is the schema; [`0002_units.sql`](db/migrations/0002_units.sql) the global units every tenant sees ([seed/units.md](seed/units.md)).
- **[db/repeatable/](db/repeatable/)** holds the rules (trigger functions, with their triggers) and the functions the API calls, one script per schema. Each script makes its schema (`item`, `class`, `unit`, …), and `wtfd schema` drops them all and runs the scripts again whenever one changes. Changing a rule is editing a file, not writing a migration. Nothing that holds data uses one of these functions, which `wtfd schema` checks before it drops them.

Tables, types and domains are in `public`; every function is in a schema named after what it belongs to. All data access goes through the functions the API calls, described in [API.md](API.md). The ER diagram is in [SCHEMA.html](SCHEMA.html).

## Concepts

| Table | Meaning |
|---|---|
| `tenant` | One inventory: its `host` (the first label of its hostnames) and `code`, the last label code handed out to its locations, items and stock rows; every code up to it was given to one (see [TENANTS.md](TENANTS.md) and [api/code.md](api/code.md)). |
| `account` | A user of one tenant: email, bcrypt password hash, and role: viewer, user or admin (see [ACCOUNTS.md](ACCOUNTS.md)). |
| `session` | A login: the SHA-256 of its token, its account, the client's name, when it was made and last used, how long it may sit unused (`max_idle`, NULL for ever), and the last 8 addresses it was used from (`usage`). |
| `quantity` | A physical quantity ("Length", "Weight", "Resistance"), with its base unit (`base_unit`). Numbers of a quantity are always stored in its base unit. |
| `unit_family` | A set of related units of one quantity that a number is scaled between on output ("Metric length": nm … km). A quantity can have several. |
| `unit` | A unit of measure in one family ("millimetre" / "mm"), with its conversion to the quantity's base unit. |
| `tenant_quantity`, `tenant_unit_family` | A tenant's choices of which quantities and unit families it uses; only where they differ from the default. |
| `class` | A category in a tree (Tools → Power tools → Drills). Attributes are inherited down the tree. |
| `attribute` | A reusable property ("Weight", "Voltage") with a datatype that never changes, an optional unit and unit lock. |
| `attribute_option` | An allowed value of a `choice` attribute ("0805", "0603", "THT"). |
| `class_attribute` | Assigns an attribute to a class, and so to all the classes below it: where its values live (`scope`: on the item, or on each stock row), whether they're required, and an optional default. |
| `item` | A *kind* of thing ("M3x10 hex screw", "Makita DHP482 drill"). Belongs to exactly one class, and optionally has the unit its stock is measured in (none = counted), with unit lock. |
| `item_value` | The value of one item attribute for one item. Numbers with a unit are in the base unit. |
| `location` | A place in a tree (House → Garage → Shelf 2 → Bin 4). |
| `stock` | The physical things: an `amount` of an item at a location (NULL: present, not counted). |
| `stock_value` | The value of one stock attribute for one stock row (serial number, purchase date, …). Same rules as `item_value`. |
| `attachment` | A file attached to exactly one item, stock row, location or class: its media type, SHA-256 hash, size and title. The bytes live on disk in `wtfd`'s files directory, named by the hash (see [api/attachment.md](api/attachment.md)). |
| `data_version` | A change counter per tenant for the class tree, the location tree and the units it sees, so clients can cheaply check whether their copy is still current. |

Types: `datatype` (`text`, `integer`, `decimal`, `date`, `boolean`, `url`, `choice`), `scope` (`item`, `stock`), `role` (ordered: viewer < user < admin), `owner_kind` (what an attachment can belong to), `session_usage` and `request` (who is calling: token, host and address, the first argument of every function the API calls). Domains: `name_text` (text that isn't blank) and `path_name` (a `name_text` without `/`). The collation `natural` sorts numbers by value ("Item 2" before "Item 10").

### Conventions

- **Explicit over implicit:** tenant filters are written in every query, rather than left to row-level security.
- **Reference columns are named after what they reference,** without `_id` (`parent`, `class`, `item`).
- **Nullable columns are marked `NULL`** explicitly.
- **A table has `tenant` only where it can't be derived** through a NOT NULL foreign key: `account`, `class`, `location`, `attribute`, the unit tables (NULL = global), the tenants' choices and `data_version`. An item's tenant is its class's, a stock row's its location's, and so on; the accessors check every id against the session's tenant by joining to the nearest table that has one.
- **Keys are UUID version 7** (`DEFAULT uuidv7()`): new keys land at the end of the index.
- **Indexes are named `<table>_<columns>_idx`;** unique ones end in `_unique`.
- **Column names are one word** where one word is clear (`amount`, `scope`), and two where one would be vague (`media_type`, `default_number`).

### Integrity rules enforced by the database

The database enforces what must always hold, by constraints and by the rules in `db/repeatable/`. Each rule runs only when its answer can change (a `WHEN` on its trigger), and those that check many rows check them in one query.

**Trees and containers**
- Class and location trees can't contain cycles (`util.prevent_tree_cycle`). Moving two nodes under each other at the same moment is not guarded against.
- Sibling names are unique, letter case ignored; top-level nodes among the tenant's top-level nodes.
- Class and location names can't contain `/` (the domain `path_name`), so a path (`Garage/Shelf 2`) always means one thing.
- **Containers:** a class or location with `container` set holds only other classes or locations. No item can be put in or moved to a container class, nor stock into a container location; a node becomes a container only while it holds no items or stock. The item or stock row locks its class or location for sharing until commit, so both can't happen at once.

**Values**
- A value has exactly one of its typed columns (`text`, `number`, `date`, `boolean`, `option`) set (CHECK), the one matching its attribute's datatype, and an `integer` is whole (`util.typed_value_fits`). `url` is in `text` and must start with `http://` or `https://`; full validation is the API's.
- An attribute's datatype never changes. To change it, make a new attribute.
- An option value or default belongs to its own attribute (the foreign key `(attribute, option)`). Options only belong to `choice` attributes.
- **Scope:** the nearest assignment in a class's path decides where an attribute's values live: on the item (`item_value`) or on each stock row (`stock_value`). A value can only be stored for an attribute of its scope. Changing an item's class, a stock row's item, a class's parent, or an assignment (adding, removing, or changing its scope) is refused if it would leave values without an attribute of the right scope.
- **Required:** an assignment can be `required`. A new item, or one moved to another class, must have a value for every required attribute without a default, and so must a stock row for its stock attributes; removing such a value is refused. These run at commit, so an object can be created first and its values added afterwards in the same transaction. Making an attribute required later never blocks anything; the API reports such gaps as `missing`.
- An absent value row means "no value".

**Units**
- Quantities, unit families and units are global (`tenant` NULL: the bootstrap units, or imported by the operator) or owned by one tenant (imported from model files, [seed/model-format.md](seed/model-format.md)). A family owned by a tenant may be in a global quantity, and a unit owned by a tenant in a global family; nothing global is in anything owned by a tenant.
- Names are unique, letter case ignored, among what a tenant sees, its own and the global ones; unit symbols within a family, case-sensitively (`mS` ≠ `ms`). The unique indexes cover the global rows and each tenant's; a rule covers a tenant's against the global ones, with an advisory lock so that two such inserts at once can't both pass.
- A quantity refers to its base unit, one of its own units with factor 1 and offset 0 (checked at commit, as a quantity and its base unit refer to each other). Every unit converts to it as `base = value × base_factor + base_offset`.
- The same symbol may be in several families of one quantity (`B` in decimal and binary bytes), but only for units that convert the same.
- Every number that has a unit (values, defaults, stock amounts) is stored in the base unit of the unit's quantity. The database never converts stored numbers.
- A quantity's numbers are `integer` (Count) or `decimal`; an attribute with a unit has its quantity's datatype. Stock amounts of a counted item, or of one with an integer quantity, are whole.
- An attribute's or item's unit only changes to another unit of the same quantity (mm → in). Adding a unit where there was none, or removing one, is refused. Unit lock needs a unit (CHECK).
- Global quantities and families have `standard` (whether a tenant has them without having chosen); tenants' own have none (CHECK).

**Deleting** (see [api/deleting.md](api/deleting.md))
- Deleting removes a row. What belongs to it alone goes with it (`ON DELETE CASCADE`: values, assignments, options, attachments, sessions); what others still use can't be deleted (`RESTRICT`: an item with stock, a class or location with something in it, an attribute or option in use, a unit). The delete functions say what is in the way first.
- The parent keys are `RESTRICT` and checked after each statement, so a subtree can be deleted in one statement.

**Attachments and photos**
- An attachment belongs to exactly one owner (CHECK). The same content is stored once on disk per tenant, however many attachments have its hash.
- Items, stock rows, locations and classes have a nullable `photo`, which the foreign key `(id, photo) → attachment (<owner>, id)` keeps among the object's own attachments; it must be an image. Deleting the photo's attachment clears the photo (`ON DELETE SET NULL (photo)`).

**Codes and versions**
- Every location, item and stock row has a `code`, handed out by `tenant.take_codes` from the tenant's counter. One counter for all three tables makes codes unique within the tenant, as only that function writes them; `location` also has a unique index `(tenant, code)`. The tenant's row stays locked until commit, so codes have no gaps, and every code up to `tenant.code` was given to something: a code up to it that nothing has belonged to something deleted (410 in the API). The API renders codes in Crockford Base32 (`1000`, `1A7K`, …).
- Every statement that changes classes or locations (or their attachments, whose titles the tree nodes show) moves that tree's version on, once per tenant. Every statement that changes a tenant's units or its choices of them moves its `unit` version on; a change to a global unit moves every tenant's. The counter row stays locked until commit, so every committed change gets a new version.
