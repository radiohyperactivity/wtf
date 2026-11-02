# WtF Database API

All access to the data goes through the PL/pgSQL functions described here. `wtfd serve` calls one of them for each request; [WTFD.md](WTFD.md) has the routes' side. The tables are described in [SCHEMA.md](SCHEMA.md). One database is one installation of WtF.

## Files

The functions live in schemas named after what they belong to, one repeatable script each:

| Documentation                            | SQL                                                          | Contents |
|------------------------------------------|--------------------------------------------------------------|----------|
| [SCHEMA.md](SCHEMA.md)                   | [db/migrations/0001_schema.sql](db/migrations/0001_schema.sql) | Types, tables, indexes |
| [api/helpers.md](api/helpers.md)         | [10_error.sql](db/repeatable/10_error.sql), [11_util.sql](db/repeatable/11_util.sql) | Schemas `error` and `util`: errors, the session check, label codes, the trees' versions, dry runs |
| [api/attachment.md](api/attachment.md)   | [13_attachment.sql](db/repeatable/13_attachment.sql)         | `attachment.*`: photos and the files of attachment attributes |
| [api/account.md](api/account.md)         | [20_account.sql](db/repeatable/20_account.sql)               | `account.*`: logging in, sessions, accounts |
| [api/attribute.md](api/attribute.md), [api/class.md](api/class.md) | [31_class.sql](db/repeatable/31_class.sql) | `class.*`: classes, their attributes, and the checking of values |
| [api/location.md](api/location.md)       | [40_location.sql](db/repeatable/40_location.sql), [41_stock.sql](db/repeatable/41_stock.sql) | `location.*`, `stock.*` |
| [api/item.md](api/item.md)               | [42_item.sql](db/repeatable/42_item.sql)                     | `item.*` |
| [seed/model-format.md](seed/model-format.md) | [60_model.sql](db/repeatable/60_model.sql)               | `model.*`: model files |
| [api/deleting.md](api/deleting.md)       | the scripts above                                            | Deleting, and the labels of deleted things |
| [api/meta.md](api/meta.md)               | [80_meta.sql](db/repeatable/80_meta.sql)                     | `meta.schema_version()` |
| [api/code.md](api/code.md)               | [81_code.sql](db/repeatable/81_code.sql)                     | `code.resolve` |

The files are applied by `wtfd schema` (see [WTFD.md](WTFD.md)). Migrations run once, in order. The repeatable scripts are rebuilt as a whole whenever one of them changes: `wtfd schema` drops the function schemas and runs every script again.

## Conventions

- **The request comes first.** Every function the API calls takes `p_request public.request` as its first argument: `(token, address)`, the session token from the cookie and the client's address. `wtfd` passes it in the same statement as the call, so a request is one statement:

  ```sql
  SELECT item.get(p_request => ROW($1, $2)::public.request, p_item => $3)
  ```

- **The session and the role are checked first.** Each function starts with `util.session(p_request, '<role>')`, which finds the session by its token's hash, checks the role, renews the session at most once a minute, and returns the session, its account and the role.
- **Access.**
  - The functions are `SECURITY DEFINER`, owned by the schema owner, with `SET search_path = pg_catalog, pg_temp`: every name in them is written with its schema (`public.item`, `util.session`), so a caller can't redirect one. They also have `SET jit = off`: the planner over-estimates the functions that return rows, and compiling the queries cost seconds that these short queries never win back (see [PERFORMANCE.md](PERFORMANCE.md)).
  - `wtf_api`, the role `wtfd serve` connects as, has `USAGE` on the function schemas and `EXECUTE` on these functions only. It has no access to tables, or to the helpers in the same schemas. See [README.md](README.md).
- **The accessors check everything.** There are no triggers: the foreign keys, `NOT NULL` and `CHECK` are the database's own guarantees, and every rule that reads another row (a value against its class, a container, a cycle in a tree) is checked by the function that writes.
- **Naming.**
  - `<schema>.<verb>`, the schema being what the function is about: `item.get`, `stock.move`, `class.attribute_add`, `account.session_list`.
  - Parameters start with `p_` and are named after what they are (`p_item`, `p_class`, not `p_id`); local variables start with `v_`.
- **Create and patch.**
  - Creating takes every field as a parameter. The API requires each in the body (null where none is meant), so nothing is left out by mistake.
  - Changes go through `….patch(p_<object>, p_patch jsonb)`: only the keys present change, and `null` clears a field that may be empty (`{"parent": null}` puts a class at the top). Unknown keys, and `null` for a field that can't be empty, are refused (22023, 400). A patch of an item or a stock row changes its values too, in the same transaction.
  - Both return the object as the matching `get` does.
- **Names are trimmed** before they are stored. **No `/` in class and location names** (22023), as `/` separates the names in a path.
- **Order.** Lists and trees sort names in natural order (the collation `public.natural`): numbers inside names by their value, letter case ignored, so "DIP4" comes before "dip8" and "DIP10"; `id` breaks ties. Numbers are compared as digits, not as what they mean: "4k7" comes before "100R".
- **Lists.**
  - The accounts are few, and their list is a plain array.
  - The lists that grow, `item.list` and `stock.list`, are paged by key: `p_limit` (1–1000, default 100) and `p_after`, the last row of the page before. They answer `{rows, more, next}`, where `next` is the `p_after` of the next page. There is no total.
- **Versions.** The class tree and the location tree each have a version (`meta.class_version`, `meta.location_version`) that changes with every change to them, a class's attributes included. `class.list` and `location.list` take `p_known_version`: when it is the current one, they answer `{version, unchanged: true}` without the rest. `wtfd` turns that into `ETag`, `If-None-Match` and `304 Not Modified`.
  - The trees come from the database as flat lists of nodes (`{id, name, parent, container}`, locations with `code`); `wtfd` nests them (`children`) for the client.
  - Other objects refer to classes and locations by id; clients resolve them from the trees they keep. `class.get` and `location.get` include the `path` from the top.
- **Attributes and values.** A class's attributes are in the class, its own and those it inherits; an item's or a stock row's values are a JSON object by attribute name, with the names of those that follow the class's default. See [api/attribute.md](api/attribute.md).
- **Units are labels.** An attribute's `unit` and an item's `unit` say what numbers are in ("mm", "m"); nothing converts.
- **Files.** An item or a stock row has a photo, and the files of its class's attachment attributes, each its content's hash. See [api/attachment.md](api/attachment.md).
- **Search.** `item.list`'s `p_search` is split into words; every word must occur, letter case ignored, as part of a word or whole, in the item's search text: its name, the names of the classes in its path, and its text, url and choice values. See [api/item.md](api/item.md).
- **Attribute filters.** `item.list`'s `p_where` is a list of conditions on attribute values, by name, all of which must pass; see [api/item.md](api/item.md).
- **Dry runs.** The changes of a class's attributes, model imports and recursive deletes take `p_dry_run`: the change does all its work, undoes it, and answers what it would have done.
- **Deleting removes** a row for good, with what belongs to it alone; something others still use can't be deleted (23001, 409, naming what is in the way). See [api/deleting.md](api/deleting.md). There is no restore and no history: a backup is the way back.

## Errors

Each error keeps its standard SQLSTATE, raised through the `error` schema's functions so the messages are alike. `wtfd` maps them to problems ([WTFD.md](WTFD.md)):

| SQLSTATE | Raised by | When | HTTP |
|----------|-----------|------|------|
| `P0002` | `error.not_found` | The object named by the URL doesn't exist | 404 |
| `22023` | `error.invalid` | Bad input: wrong type of value, a bad page size, an invalid definition | 400 |
| `22P02`, `22003`, `22008`, `23502` | PostgreSQL | A malformed id, a number too large, an impossible date, a missing value | 400 |
| `23503` | `error.bad_reference` | A body refers to something that doesn't exist | 422 |
| `23505` | `error.duplicate` | A name that is taken | 409 |
| `23514` | `error.not_allowed` | A request the rules refuse: a value its class doesn't take, a cycle, a container, stock rows that differ | 422 |
| `23001` | `error.in_use` | Deleting something that others still depend on, or a choice that values have | 409 |
| `55000` | `error.wrong_state` | Not possible in this state: an item moved to another class just as it was written; trying again works | 409 (`/problems/wrong-state`) |
| `WT001` | `error.gone` | A label code that was handed out, but whose item, stock row or location has been deleted | 410 (`/problems/gone`) |
| `28000` | `error.unauthenticated` | Not logged in, or the session has ended | 401 |
| `42501` | `error.forbidden`, the role check | The account's role doesn't allow it | 403 |

## JSON shapes

```text
node       { id, name, parent, container }                      (locations also code; wtfd adds children)
attribute  { name, class: <the class that defines it>, inherited, scope, type, required, order,
             unit?, default?, choices?, media? }
class      { id, name, parent, container, path: [ { id, name } ], attributes: [ attribute ] }
change     { class, items, stock, dry_run }                     (a change of a class's attributes)
location   { id, code, name, parent, container, path: [ { id, name } ] }
values     { "<attribute name>": value, … }                     (no key: no value)
item       (list) { id, code, name, class: <class id>, unit, photo, stock: { total, uncounted } }
           (get)  { id, code, name, class: { id, name, path }, unit, photo, values, defaulted: [ name ],
                    stock: [ stock, with item: <item id> ] }
stock      { id, code, item: item (list form, without stock), location: <location id>, amount: number | null,
             reference, serial, photo, values, defaulted }      (stock.list rows: without values and defaulted)
page       { rows, more, next }
```

`photo` is a file's hash or null; `unit` a label or null.

## Function index

The 50 functions the API calls, and the routes that call them (under `/api/v1`). `wtfd`'s own work (the operator's accounts, `gc`) uses the tables directly, as the schema owner ([WTFD.md](WTFD.md)).

| Function | Returns | Route |
|----------|---------|-------|
| `account.login(p_email, p_password, p_client, p_max_idle)` | `{ok, token, account}` or `{ok: false, reason}` | `POST /login` (the token becomes the session cookie) |
| `account.logout()` | void | `POST /logout` |
| `account.me()` | account | `GET /me` |
| `account.password_change(p_current, p_new, p_end_other_sessions)` | void | `PUT /me/password` |
| `account.session_list()` | [session] | `GET /me/sessions` |
| `account.session_logout(p_session)` | void | `DELETE /me/sessions/{id}` |
| `account.session_logout_others()` | the number ended | `POST /me/sessions/logout-others` |
| `account.list()` | [account] | `GET /accounts` |
| `account.get(p_account)` | account | `GET /accounts/{id}` |
| `account.create(p_email, p_password, p_role)` | account | `POST /accounts` |
| `account.patch(p_account, p_patch)` | account | `PATCH /accounts/{id}` |
| `account.delete(p_account)` | void | `DELETE /accounts/{id}` |
| `class.list(p_known_version)` | `{version, nodes}` | `GET /classes` (ETag; nested by wtfd) |
| `class.get(p_class)` | class | `GET /classes/{id}` |
| `class.create(p_name, p_parent, p_container)` | class | `POST /classes` |
| `class.patch(p_class, p_patch)` | class | `PATCH /classes/{id}` |
| `class.delete(p_class)` | void | `DELETE /classes/{id}` |
| `class.delete_tree(p_class, p_force, p_dry_run)` | `{classes, items, stock}` | `DELETE /classes/{id}?recursive=true[&force=true]`; preview `GET /classes/{id}/deletion` |
| `class.attribute_add(p_class, p_name, p_definition, p_dry_run)` | change | `POST /classes/{id}/attributes` |
| `class.attribute_change(p_class, p_name, p_patch, p_dry_run)` | change | `PATCH /classes/{id}/attributes/{attribute}` |
| `class.attribute_rename(p_class, p_name, p_new_name, p_dry_run)` | change | `POST /classes/{id}/attributes/{attribute}/rename` |
| `class.attribute_remove(p_class, p_name, p_dry_run)` | change | `DELETE /classes/{id}/attributes/{attribute}` |
| `class.choice_add(p_class, p_name, p_choice, p_dry_run)` | change | `POST /classes/{id}/attributes/{attribute}/choices` |
| `class.choice_rename(p_class, p_name, p_choice, p_new_choice, p_dry_run)` | change | `POST /classes/{id}/attributes/{attribute}/choices/{choice}/rename` |
| `class.choice_remove(p_class, p_name, p_choice, p_dry_run)` | change | `DELETE /classes/{id}/attributes/{attribute}/choices/{choice}` |
| `location.list(p_known_version)` | `{version, nodes}` | `GET /locations` (ETag; nested by wtfd) |
| `location.get(p_location)` | location | `GET /locations/{id}` |
| `location.create(p_name, p_parent, p_container, p_columns, p_rows, p_confirm)` | location | `POST /locations` (the body's `grid` gives the last three) |
| `location.patch(p_location, p_patch)` | location | `PATCH /locations/{id}` |
| `location.delete(p_location)` | void | `DELETE /locations/{id}` |
| `location.delete_tree(p_location, p_force, p_dry_run)` | `{locations, stock}` | `DELETE /locations/{id}?recursive=true[&force=true]`; preview `GET /locations/{id}/deletion` |
| `stock.list(p_item, p_location, p_search, p_limit, p_after)` | page of stock | `GET /stock` |
| `stock.get(p_stock)` | stock | `GET /stock/{id}` |
| `stock.create(p_item, p_location, p_amount, p_reference, p_serial, p_values)` | stock | `POST /stock` |
| `stock.patch(p_stock, p_patch)` | stock | `PATCH /stock/{id}` |
| `stock.move(p_stock, p_location, p_amount)` | stock (where it went) | `POST /stock/{id}/move` |
| `stock.merge(p_stock, p_into, p_amount, p_resolve)` | stock (`p_into`) | `POST /stock/{id}/merge` |
| `stock.delete(p_stock)` | void | `DELETE /stock/{id}` |
| `item.list(p_class, p_search, p_where, p_limit, p_after)` | page of items (list form) | `GET /items` |
| `item.get(p_item)` | item | `GET /items/{id}` |
| `item.create(p_class, p_name, p_unit, p_values)` | item | `POST /items` |
| `item.patch(p_item, p_patch)` | item | `PATCH /items/{id}` |
| `item.delete(p_item)` | void | `DELETE /items/{id}` |
| `attachment.lock(p_hash)` | void | `PUT /{kind}/{id}/photo`, `PUT /{kind}/{id}/files/{attribute}` (multipart; wtfd stores the file between the two calls) |
| `attachment.set(p_kind, p_owner, p_attribute, p_hash, p_media_type)` | item or stock | the same |
| `attachment.get(p_kind, p_owner, p_attribute)` | `{hash, name}` | `GET /{kind}/{id}/photo`, `GET /{kind}/{id}/files/{attribute}` (wtfd sends the file) |
| `model.import(p_data, p_parent, p_dry_run)` | report | `POST /model/import?parent=&dry_run=` |
| `model.export(p_class)` | a model file | `GET /classes/{id}/model` |
| `code.resolve(p_code)` | `{type, object}`; 410 for a deleted thing's code | `GET /codes/{code}` |
| `meta.schema_version()` | `{version, repeatables}` | – (wtfd at startup; takes no request) |

`{kind}` is `items` or `stock`. The routes with `dry_run` take it as a query parameter (`?dry_run=true`).

## Deferred

- **Indexes for search and filters.** A trigram index on `item.search` (`pg_trgm`, with `btree_gin`) would let a search read only the items that match, and a GIN index on `values` the same for equality filters. Neither is made for now ([2026-11-02-attributes-in-json.md](2026-11-02-attributes-in-json.md), decisions 28 and 33); the performance test shows when they would earn their place. They can be added in a migration without changing the API.
