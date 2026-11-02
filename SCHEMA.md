# WtF Database Schema

Target: PostgreSQL 18 or newer (`uuidv7()` is built in since 18). The server must be built with ICU, for the collation that sorts names (the official `postgres:18` image is).

The schema is created and upgraded by `wtfd schema` (see [WTFD.md](WTFD.md)) from the SQL files in [db/](db/):

- **[db/migrations/](db/migrations/)** holds what holds data: the tables, their columns, constraints and indexes, the types and domains. A migration runs once and is then frozen. [`0001_schema.sql`](db/migrations/0001_schema.sql) is the schema.
- **[db/repeatable/](db/repeatable/)** holds the functions the API calls and their helpers, one script per schema. Each script makes its schema (`item`, `class`, …), and `wtfd schema` drops them all and runs the scripts again whenever one changes. Changing a function is editing a file, not writing a migration. Nothing that holds data uses one of these functions, which `wtfd schema` checks before it drops them.

Tables, types and domains are in `public`; every function is in a schema named after what it belongs to. All data access goes through the functions the API calls, described in [API.md](API.md). One database is one installation of WtF; several installations are several databases, each with its own `wtfd`. Why the schema is as it is: [2026-11-02-attributes-in-json.md](2026-11-02-attributes-in-json.md).

## Tables

| Table | Meaning |
|---|---|
| `meta` | The installation, in one row: `code`, the last label code handed out to a location, item or stock row (every code up to it was given to one, see [api/code.md](api/code.md)), and the versions of the class tree and the location tree (`class_version`, `location_version`), so clients can cheaply check whether their copy is still current. Columns are added as they are needed. |
| `account` | A user: email (in lower case, unique), bcrypt password hash, and role: viewer, user or admin (see [ACCOUNTS.md](ACCOUNTS.md)). |
| `session` | A login: the SHA-256 of its token, its account, the client's name, when it was made and last used, how long it may sit unused (`max_idle`, NULL for ever), and the last 8 addresses it was used from (`usage`). |
| `class` | A category in a tree (Tools → Power tools → Drills), with `attributes`: every attribute it has, its own and those it inherits, by name, in JSON ([api/attribute.md](api/attribute.md)). |
| `item` | A *kind* of thing ("M3x10 hex screw", "Makita DHP482 drill"), in exactly one class: its `unit` (a label for its stock amounts; NULL: pieces), `values` (JSON, by attribute name), `defaulted` (the names of the values that follow the class's default), `search` (its search text) and `photo` (a file's hash). |
| `location` | A place in a tree (House → Garage → Shelf 2 → Bin 4). |
| `stock` | The physical things: an `amount` of an item at a location (NULL: present, not counted), with an optional `reference` and `serial`, `values` and `defaulted` for its class's stock attributes, and a `photo`. |

Types: `datatype` (`text`, `integer`, `decimal`, `date`, `boolean`, `url`, `choice`, `attachment`), `scope` (`item`, `stock`), `role` (ordered: viewer < user < admin), `session_usage` and `request` (who is calling: token and address, the first argument of every function the API calls). Domains: `name_text` (text that isn't blank), `path_name` (a `name_text` without `/`), `file_hash` (a SHA-256 as hex) and `json_object`. The collation `natural` sorts numbers by value ("Item 2" before "Item 10").

## Indexes

Only these, each with its reason ([2026-11-02-attributes-in-json.md](2026-11-02-attributes-in-json.md), "Indexes"):

| Index | For |
|-------|-----|
| `account (email)`, unique; `session (account)` | logins; an email once; an account's sessions |
| `class (parent, lower(name))`, unique, nulls equal | sibling names; the top-level classes; children; the check before deleting a class |
| `location (parent, lower(name))`, unique, nulls equal; `location (code)`, unique | as for classes; resolving a label |
| `item (code)`, unique; `stock (code)`, unique | resolving a label |
| `item (name COLLATE natural)` | lists, searches and filters read the items in this order and stop after the page |
| `item (class)` | a class's items |
| `stock (item)`; `stock (location)` | an item's and a location's stock |

## Conventions

- **Reference columns are named after what they reference,** without `_id` (`parent`, `class`, `item`).
- **Nullable columns are marked `NULL`** explicitly.
- **Keys are UUID version 7** (`DEFAULT uuidv7()`): new keys land at the end of the index.
- **Indexes are named `<table>_<columns>_idx`;** unique ones end in `_unique`.
- **Column names are one word** where one word is clear (`amount`, `scope`), and two where one would be vague.

## What the database enforces

The constraints hold what a row needs on its own, and the foreign keys what it refers to. There are no triggers: every rule that reads another row is checked by the accessor that writes ([API.md](API.md)), as they are the only way to change a row.

- **By constraints:** names aren't blank, and class and location names have no `/`; an email is in lower case; a photo is a file's hash; `values` and `attributes` are JSON objects; an amount isn't below 0; a node isn't its own parent; sibling names, emails and codes are unique.
- **By the foreign keys:** what others still use can't be deleted (`RESTRICT`: an item with stock, a class or location with something in it); an account's sessions go with it (`ON DELETE CASCADE`). The parent keys are checked after each statement, so a subtree can be deleted in one statement ([api/deleting.md](api/deleting.md)).
- **By the accessors:**
  - **Values:** every value of an item or stock row is of an attribute of its class, of its scope, and fits its type; a required one is there; a value that follows the default has it ([api/attribute.md](api/attribute.md)). A change of a class's attributes checks, and where needed rewrites, every row below it. An item or stock row write locks its class row for sharing, so that a class change waits for it, or it for the class change.
  - **Trees and containers:** no cycles (a move below itself is refused); a container class holds no items, and a container location no stock; a node becomes a container only while it holds none. The item or stock row locks its class or location for sharing until commit, so both can't happen at once. Moving two nodes under each other at the same moment is not guarded against.
  - **Amounts** of an item counted in pieces are whole.
  - **Codes:** every location, item and stock row gets its `code` from `util.take_codes`, one counter for all three, in the meta row. The row stays locked until commit, so codes have no gaps, and every code up to `meta.code` was given to something: a code up to it that nothing has belonged to something deleted (410 in the API). The API renders codes in Crockford Base32 (`1000`, `1A7K`, …).
  - **Versions:** every change of a tree, a class's attributes included, moves its version on in the meta row, last in the change, so that the row's lock is held only until commit.
