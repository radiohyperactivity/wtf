# WtF Database API

All access to the data goes through the PL/pgSQL functions described here. `wtfd serve` calls one of them for each request; [WTFD.md](WTFD.md) has the routes' side. The tables, and the rules that keep them consistent, are described in [SCHEMA.md](SCHEMA.md).

## Files

The functions live in schemas named after what they belong to, one repeatable script each:

| Documentation                            | SQL                                                          | Contents |
|------------------------------------------|--------------------------------------------------------------|----------|
| [SCHEMA.md](SCHEMA.md)                   | [db/migrations/0001_schema.sql](db/migrations/0001_schema.sql) | Types, tables, indexes |
| [seed/units.md](seed/units.md)           | [db/migrations/0002_units.sql](db/migrations/0002_units.sql)   | The global units: quantities, unit families and units |
| [api/helpers.md](api/helpers.md)         | [10_error.sql](db/repeatable/10_error.sql), [11_util.sql](db/repeatable/11_util.sql), [12_tenant.sql](db/repeatable/12_tenant.sql) | Schemas `error`, `util` and `tenant`: errors, the session check, actions, shared rules and JSON pieces |
| [api/attachment.md](api/attachment.md)   | [13_attachment.sql](db/repeatable/13_attachment.sql)         | `attachment.*` |
| [api/account.md](api/account.md)         | [20_account.sql](db/repeatable/20_account.sql)               | `account.*`: logging in, sessions, accounts |
| [api/attribute.md](api/attribute.md)     | [21_unit.sql](db/repeatable/21_unit.sql), [30_attribute.sql](db/repeatable/30_attribute.sql) | `unit.*`, `attribute.*` |
| [api/class.md](api/class.md)             | [31_class.sql](db/repeatable/31_class.sql)                   | `class.*` |
| [api/location.md](api/location.md)       | [40_location.sql](db/repeatable/40_location.sql), [41_stock.sql](db/repeatable/41_stock.sql) | `location.*`, `stock.*` |
| [api/item.md](api/item.md)               | [42_item.sql](db/repeatable/42_item.sql)                     | `item.*` |
| [seed/model-format.md](seed/model-format.md) | [60_model.sql](db/repeatable/60_model.sql)               | `model.*`: model files |
| [api/history.md](api/history.md)         | [70_history.sql](db/repeatable/70_history.sql)               | `history.record` and the `….history` pages |
| [api/deleting.md](api/deleting.md)       | the scripts above                                            | Marking deleted, `….restore`, purging |
| [api/meta.md](api/meta.md)               | [80_meta.sql](db/repeatable/80_meta.sql)                     | `meta.schema_version()` |
| [api/code.md](api/code.md)               | [81_code.sql](db/repeatable/81_code.sql)                     | `code.resolve` |
| [TENANTS.md](TENANTS.md)                 |                                                              | Tenants: many inventories, picked by hostname |

The files are applied by `wtfd schema` (see [WTFD.md](WTFD.md)). Migrations run once, in order. The repeatable scripts are rebuilt as a whole whenever one of them changes: `wtfd schema` drops the function schemas and runs every script again.

## Conventions

- **The request comes first.** Every function the API calls takes `p_request public.request` as its first argument: `(token, host, address)`, the session token from the cookie, the first label of the request's hostname, and the client's address. `wtfd` passes it in the same statement as the call, so a request is one statement:

  ```sql
  SELECT item.get(p_request => ROW($1, $2, $3)::public.request, p_item => $4)
  ```

- **The session and the role are checked first.** Each function starts with `util.session(p_request, '<role>')`, which finds the session by its token's hash in the tenant of the host, checks the role, renews the session at most once a minute, and returns the session, its tenant, its account and the role. Everything after that works in that tenant only ([TENANTS.md](TENANTS.md)).
- **Every change is an action.** A function that changes something calls `util.begin_action` first. The action (`public.action`: who, when, in which tenant) is what history entries and deleted rows refer to, so all changes of one call share it. A change without an action of its transaction is refused, so nothing writes around history.
- **Access.**
  - The functions are `SECURITY DEFINER`, owned by the schema owner, with `SET search_path = pg_catalog, pg_temp`: every name in them is written with its schema (`public.item`, `util.session`), so a caller can't redirect one.
  - `wtf_api`, the role `wtfd serve` connects as, has `USAGE` on the function schemas and `EXECUTE` on these functions only. It has no access to tables, or to the helpers in the same schemas. See [README.md](README.md).
- **Naming.**
  - `<schema>.<verb>`, the schema being what the function is about: `item.get`, `stock.move`, `class.assign`, `account.session_list`.
  - Parameters start with `p_` and are named after what they are (`p_item`, `p_class`, not `p_id`); local variables start with `v_`.
- **Create and patch.**
  - Creating takes every field as a parameter. The API requires each in the body (null where none is meant), so nothing is left out by mistake.
  - Changes go through `….patch(p_<object>, p_patch jsonb)`: only the keys present change, and `null` clears a field that may be empty (`{"parent": null}` puts a class at the top). Unknown keys, and `null` for a field that can't be empty, are refused (22023, 400).
  - Both return the object as the matching `get` does.
- **Names are trimmed** before they are stored. **No `/` in class and location names** (22023), as `/` separates the names in a path.
- **Order.** Lists and trees sort names in natural order (the collation `public.natural`): numbers inside names by their value, letter case ignored, so "DIP4" comes before "dip8" and "DIP10"; `id` breaks ties. Numbers are compared as digits, not as what they mean: "4k7" comes before "100R".
- **Lists.**
  - Lists of things defined once (quantities, unit families, units, attributes, accounts) are small, and return a plain array of everything.
  - The lists that grow with the inventory, `item.list` and `stock.list`, are paged with `p_limit` (1–1000, default 100) and `p_offset`, and return `{total, limit, offset, rows}`. Each page is one query, whatever its size.
  - History goes by position instead, `p_before` (an entry's id) and `p_limit`, and returns `{rows, more}`; see [api/history.md](api/history.md).
- **Versions.** The class tree, the location tree and the unit families each have a version that changes with every change to them. `class.list`, `location.list` and `unit.family_list` take `p_known_version`: when it is the current one, they answer `{version, unchanged: true}` without the rest. `wtfd` turns that into `ETag`, `If-None-Match` and `304 Not Modified`.
  - The trees come from the database as flat lists of nodes (`{id, name, parent, container, photo, …}`, locations with `code`); `wtfd` nests them (`children`) for the client.
  - Other objects refer to classes, locations and units by id; clients resolve them from the trees and families they keep. `class.get` and `location.get` include the `path` from the top.
- **Units by id.** Outside the unit functions, a unit is its id: an attribute's and an item's `unit`, and the `unit` of a `display`. A quantity's `base_unit` is an id too. The unit families' list has every unit, with its symbol and conversion.
- **Deleting marks objects** instead of removing them; see [api/deleting.md](api/deleting.md). `deleted` is `null`, or when and by whom: `{action, at, account: {id, email}}`. Lists and trees leave deleted objects out; `get` and `code.resolve` still return them. A deleted object can't be changed (55000, 409), only restored or purged.
- **Search.** `item.list`'s `p_search` is split into words; every word must occur, letter case ignored, in the item's name, a class in its class path, or a text, url or choice value the item or one of its live stock rows shows (own or default). Words may match in different places: "resistor 0805" finds 0805 resistors.
- **Attribute filters.** `item.list`'s `p_where` is a list of conditions on attribute values, all of which must match; see [api/item.md](api/item.md).
- **Where values live.** An assignment's `scope` says where an attribute's values are: `"item"`, on the item, or `"stock"`, on each stock row (a serial number, a purchase date). Defaults work the same way for both.
  - **Splitting** a row with `stock.move` copies its values; **merging** only happens when both rows have exactly the same values.
  - **Search** also finds items by the values of their stock rows.
- **Required attributes.** A `required` assignment must be met, by a value or a default, when an item or stock row is created, and a required value can't be removed. Requirements added later are only reported: `item.get` and `stock.get` list what is `missing`, and `item.list` rows say `incomplete`.
- **Attachments.** Files on items, stock rows, locations and classes; see [api/attachment.md](api/attachment.md). They are listed in the `get` answers of those objects, with the object's `photo`.
- **Defaults are fallbacks.** A class attribute's default is never stored on an item: `item.get` shows the item's own values, and the current default for every attribute without one, marked `"is_default": true`.
- **Typed values.** Values and defaults are passed as `jsonb`, and read by the attribute's datatype:

  | Datatype  | JSON input                                   | JSON output              |
  |-----------|----------------------------------------------|--------------------------|
  | `text`    | string                                       | string                   |
  | `url`     | string starting with `http://` or `https://` | string                   |
  | `integer` | whole number                                 | number                   |
  | `decimal` | number                                       | number                   |
  | `date`    | string `"YYYY-MM-DD"`                        | string `"YYYY-MM-DD"`    |
  | `boolean` | `true` / `false`                             | boolean                  |
  | `choice`  | option id or option name (case-insensitive)  | `{"id": …, "name": …}`   |

- **Units.**
  - Quantities, unit families and units are global (seeded, see [seed/units.md](seed/units.md), and imported by the operator) or a tenant's own (imported from model files, [seed/model-format.md](seed/model-format.md)). A tenant turns quantities and families on and off. Every quantity's base unit is one of its units.
  - An attribute (for values and defaults) or an item (for stock amounts) may have a unit; its numbers are then measurements of the unit's quantity. Counts are integers; every other quantity is decimal.
  - Numbers are stored, and must be given, in the base unit of the quantity (metres, kilograms, ohms, kelvin, …). Answers give the number in the base unit and a `display`: `{"value": 1.2, "unit": "<the id of mm>"}`. Without Unit lock, the display unit is the largest unit of the family in which |value| ≥ 1, else the smallest; zero is shown in the unit itself; with `unit_lock`, always in the unit itself. `display` is `null` without a unit.
  - Clients convert by themselves with each unit's `base_factor` and `base_offset`: `base = value × base_factor + base_offset`. There is no conversion call.

## Errors

Each error keeps its standard SQLSTATE, raised through the `error` schema's functions so the messages are alike. `wtfd` maps them to problems ([WTFD.md](WTFD.md)):

| SQLSTATE | Raised by | When | HTTP |
|----------|-----------|------|------|
| `P0002` | `error.not_found`, `error.unknown_host` | The object named by the URL doesn't exist (or is another tenant's) | 404 |
| `22023` | `error.invalid` | Bad input: wrong type of value, bad paging, an invalid move | 400 |
| `22P02`, `22003`, `22008`, `23502` | PostgreSQL | A malformed id, a number too large, an impossible date, a missing value | 400 |
| `23514` | the rules | A rule of the schema (a cycle, the wrong datatype, a value its class doesn't take, …) | 422 |
| `23503` | `error.bad_reference` | A body refers to something that doesn't exist | 422 |
| `23505` | `error.duplicate` | A name that is taken | 409 |
| `23001` | `error.in_use` | Deleting something that live objects still depend on | 409 |
| `55000` | `error.deleted`, `error.not_deleted`, `error.wrong_state` | The object, or one it needs, is deleted; restoring something that isn't; a merged row | 409 (`/problems/wrong-state`) |
| `WT001` | `error.restore_into_deleted` | Restoring into something deleted; the `DETAIL` names the place to give instead (`class`, `parent` or `location`) | 409 (`/problems/restore-into-deleted`) |
| `28000` | `error.unauthenticated` | Not logged in, or the session has ended | 401 |
| `42501` | `error.forbidden`, the role check | The account's role doesn't allow it | 403 |

An error raised by `history.record` (a change without an action, or of another tenant's row) is a plain error, and a 500: it means a bug, not a user without rights.

## JSON shapes

```text
deleted    null | { action, at, account: { id, email } | null }
display    { value, unit: <unit id> }
node       { id, name, parent, container, photo }               (locations also code; wtfd adds children)
quantity   { id, name, datatype, base_unit: <unit id>, global, available, standard, choice }
           unit.quantity_get adds  families: [ unit family ]
unit       { id, name, symbol, base_factor, base_offset, global, family: { id, name }, quantity }
           (in a family's units: without family and quantity)
unit_family { id, name, quantity, global, available, standard, choice, units: [ unit ] }   (units smallest first)
attribute  { id, name, datatype, unit: <unit id> | null, unit_lock, deleted }
           attribute.get adds  options: [ option ]   (choice attributes)
option     { id, attribute, name, deleted }
class      { id, name, parent, container, path: [ { id, name } ], deleted }
           class.get adds  attributes: [ { attribute, assigned_to, inherited, default, default_display, scope, required } ],
                           photo, attachments
location   { id, code, name, parent, container, path: [ { id, name } ], deleted }
           location.get adds  photo, attachments
attachment { id, title, media_type, size, hash, deleted }   (size: bytes; hash: hex SHA-256)
item       (list) { id, code, name, class: <class id>, unit, unit_lock, photo, deleted,
                    stock: { total, display, uncounted }, incomplete }
           (get)  { id, code, name, class: class, unit, unit_lock, photo, attachments, deleted,
                    values: [ value ], missing: [ { id, name } ],
                    stock: [ { id, code, location: <location id>, amount, display, values, missing, photo, attachments } ] }
value      { attribute: attribute, value, display, is_default }
stock      { id, code, item: item (list form), location: <location id>, amount: number | null, display,
             values: [ value ], missing: [ { id, name } ], photo, attachments, deleted, merged_into: { id, code } | null }
history    { rows: [ { id, action: { id, at, account: { id, email, deleted } | null },
                       table, operation, data, changes } ], more }
```

## Function index

The 83 functions the API calls, and the routes that call them (under `/api/v1`). `wtfd`'s own work (tenants, accounts of the operator, purging, `gc`) uses the tables directly, as the schema owner ([WTFD.md](WTFD.md)).

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
| `account.history(p_account, p_before, p_limit)` | history | `GET /accounts/{id}/history` |
| `unit.quantity_list()` | [quantity] | `GET /quantities` |
| `unit.quantity_get(p_quantity)` | quantity (+ families) | `GET /quantities/{id}` |
| `unit.quantity_patch(p_quantity, p_patch)` | quantity | `PATCH /quantities/{id}` |
| `unit.family_list(p_known_version, p_quantity)` | `{version, families}` | `GET /unit-families` (ETag) |
| `unit.family_get(p_family)` | unit family | `GET /unit-families/{id}` |
| `unit.family_patch(p_family, p_patch)` | unit family | `PATCH /unit-families/{id}` |
| `unit.list(p_quantity, p_family)` | [unit] | `GET /units` |
| `unit.get(p_unit)` | unit | `GET /units/{id}` |
| `attribute.list()` | [attribute] | `GET /attributes` |
| `attribute.get(p_attribute)` | attribute (+ options) | `GET /attributes/{id}` |
| `attribute.create(p_name, p_datatype, p_unit, p_unit_lock)` | attribute | `POST /attributes` |
| `attribute.patch(p_attribute, p_patch)` | attribute | `PATCH /attributes/{id}` |
| `attribute.delete(p_attribute)` | void | `DELETE /attributes/{id}` |
| `attribute.restore(p_attribute, p_options)` | attribute | `POST /attributes/{id}/restore` |
| `attribute.history(p_attribute, p_before, p_limit)` | history | `GET /attributes/{id}/history` |
| `attribute.list_history(p_before, p_limit)` | history | `GET /attributes/history` |
| `attribute.option_get(p_option)` | option | `GET /options/{id}` |
| `attribute.option_create(p_attribute, p_name)` | option | `POST /attributes/{id}/options` |
| `attribute.option_patch(p_option, p_patch)` | option | `PATCH /options/{id}` |
| `attribute.option_delete(p_option)` | void | `DELETE /options/{id}` |
| `attribute.option_restore(p_option, p_options)` | option | `POST /options/{id}/restore` |
| `class.list(p_known_version)` | `{version, nodes}` | `GET /classes` (ETag; nested by wtfd) |
| `class.get(p_class)` | class (+ attributes) | `GET /classes/{id}` |
| `class.create(p_name, p_parent, p_container)` | class | `POST /classes` |
| `class.patch(p_class, p_patch)` | class | `PATCH /classes/{id}` |
| `class.delete(p_class)` | void | `DELETE /classes/{id}` |
| `class.delete_tree(p_class, p_force, p_dry_run)` | `{classes, items, stock}` | `DELETE /classes/{id}?recursive=true[&force=true]`; preview `GET /classes/{id}/deletion` |
| `class.restore(p_class, p_options)` | class | `POST /classes/{id}/restore` |
| `class.assign(p_class, p_attribute, p_default, p_scope, p_required)` | class | `PUT /classes/{id}/attributes/{attribute}` |
| `class.unassign(p_class, p_attribute)` | class | `DELETE /classes/{id}/attributes/{attribute}` |
| `class.history(p_class, p_before, p_limit)` | history | `GET /classes/{id}/history` |
| `class.list_history(p_before, p_limit)` | history | `GET /classes/history` |
| `location.list(p_known_version)` | `{version, nodes}` | `GET /locations` (ETag; nested by wtfd) |
| `location.get(p_location)` | location | `GET /locations/{id}` |
| `location.create(p_name, p_parent, p_container, p_columns, p_rows, p_confirm)` | location | `POST /locations` (the body's `grid` gives the last three) |
| `location.patch(p_location, p_patch)` | location | `PATCH /locations/{id}` |
| `location.delete(p_location)` | void | `DELETE /locations/{id}` |
| `location.delete_tree(p_location, p_force, p_dry_run)` | `{locations, stock}` | `DELETE /locations/{id}?recursive=true[&force=true]`; preview `GET /locations/{id}/deletion` |
| `location.restore(p_location, p_options)` | location | `POST /locations/{id}/restore` |
| `location.history(p_location, p_before, p_limit)` | history | `GET /locations/{id}/history` |
| `location.list_history(p_before, p_limit)` | history | `GET /locations/history` |
| `stock.list(p_item, p_location, p_limit, p_offset)` | page of stock | `GET /stock` |
| `stock.get(p_stock)` | stock | `GET /stock/{id}` |
| `stock.create(p_item, p_location, p_amount, p_values)` | stock | `POST /stock` |
| `stock.patch(p_stock, p_patch)` | stock | `PATCH /stock/{id}` |
| `stock.move(p_stock, p_location, p_amount)` | stock (where it went) | `POST /stock/{id}/move` |
| `stock.delete(p_stock)` | void | `DELETE /stock/{id}` |
| `stock.restore(p_stock, p_options)` | stock | `POST /stock/{id}/restore` |
| `stock.value_set(p_stock, p_attribute, p_value)` | stock | `PUT /stock/{id}/values/{attribute}` |
| `stock.value_delete(p_stock, p_attribute)` | stock | `DELETE /stock/{id}/values/{attribute}` |
| `stock.history(p_stock, p_before, p_limit)` | history | `GET /stock/{id}/history` |
| `item.list(p_class, p_search, p_where, p_limit, p_offset)` | page of items (list form) | `GET /items` |
| `item.get(p_item)` | item | `GET /items/{id}` |
| `item.create(p_class, p_name, p_unit, p_unit_lock, p_values)` | item | `POST /items` |
| `item.patch(p_item, p_patch)` | item | `PATCH /items/{id}` |
| `item.delete(p_item)` | void | `DELETE /items/{id}` |
| `item.restore(p_item, p_options)` | item | `POST /items/{id}/restore` |
| `item.value_set(p_item, p_attribute, p_value)` | item | `PUT /items/{id}/values/{attribute}` |
| `item.value_delete(p_item, p_attribute)` | item | `DELETE /items/{id}/values/{attribute}` |
| `item.history(p_item, p_before, p_limit)` | history | `GET /items/{id}/history` |
| `attachment.lock(p_hash)` | void | `POST /{kind}/{id}/attachments` (multipart; wtfd stores the file between the two calls) |
| `attachment.create(p_kind, p_owner, p_hash, p_media_type, p_size, p_title, p_photo)` | attachment | the same |
| `attachment.get(p_kind, p_owner, p_attachment)` | attachment | `GET /{kind}/{id}/attachments/{attachment}` (the file: `…/content`) |
| `attachment.patch(p_kind, p_owner, p_attachment, p_patch)` | attachment | `PATCH /{kind}/{id}/attachments/{attachment}` |
| `attachment.delete(p_kind, p_owner, p_attachment)` | void | `DELETE /{kind}/{id}/attachments/{attachment}` |
| `attachment.restore(p_kind, p_owner, p_attachment, p_options)` | attachment | `POST /{kind}/{id}/attachments/{attachment}/restore` |
| `model.import(p_data, p_parent, p_dry_run)` | report | `POST /model/import?parent=&dry_run=` |
| `model.export(p_class)` | a model file | `GET /classes/{id}/model` |
| `code.resolve(p_code)` | `{type, object}` | `GET /codes/{code}` |
| `meta.schema_version()` | `{version, repeatables}` | – (wtfd at startup; takes no request) |

`{kind}` is `items`, `stock`, `locations` or `classes`.

## Deferred

- **Search indexes.** Trigram indexes (`pg_trgm`) for substring search on large data. Not needed at household scale; they can be added in a migration without changing the API.
