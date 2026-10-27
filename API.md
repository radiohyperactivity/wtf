# WtF Database API

All access to the data goes through the PL/pgSQL functions described here. They are the basis for the REST API. The tables are described in [SCHEMA.md](SCHEMA.md).

## Files

| Documentation                            | SQL                                                        | Contents |
|------------------------------------------|------------------------------------------------------------|----------|
| [SCHEMA.md](SCHEMA.md)                   | [db/migrations/0001_schema.sql](db/migrations/0001_schema.sql) | Types, tables, views, integrity triggers |
| [seed/units.md](seed/units.md)           | [db/migrations/0002_units.sql](db/migrations/0002_units.sql)   | System data: quantities, unit families and units |
| [api/helpers.md](api/helpers.md)         | [db/repeatable/10_util.sql](db/repeatable/10_util.sql)         | Schema `util`: internal helpers for errors, paging, paths, typed values, JSON builders |
| [api/attribute.md](api/attribute.md)     | [db/repeatable/20_attribute.sql](db/repeatable/20_attribute.sql) | `quantity_*`, `unit_family_*`, `unit_*`, `attribute_*`, `attribute_option_*` |
| [api/class.md](api/class.md)             | [db/repeatable/30_class.sql](db/repeatable/30_class.sql)       | `class_*`, `class_attribute_*` |
| [api/item.md](api/item.md)               | [db/repeatable/40_item.sql](db/repeatable/40_item.sql)         | `item_*`, `value_*` |
| [api/location.md](api/location.md)       | [db/repeatable/50_location.sql](db/repeatable/50_location.sql) | `location_*`, `stock_*` |
| [api/code.md](api/code.md)               | [db/repeatable/70_code.sql](db/repeatable/70_code.sql)         | `code_resolve()` |
| [api/attachment.md](api/attachment.md)   | [db/repeatable/80_attachment.sql](db/repeatable/80_attachment.sql) | `attachment_*` |
| [api/account.md](api/account.md)         | [db/repeatable/90_account.sql](db/repeatable/90_account.sql)   | `login`, `session_use`, `logout`, `me`, `password_change`, `account_*` |
| [api/history.md](api/history.md)         | [db/repeatable/95_history.sql](db/repeatable/95_history.sql)   | `*_history` |
| [api/deleting.md](api/deleting.md)       | [db/migrations/0001_schema.sql](db/migrations/0001_schema.sql) | Marking deleted, `*_restore`, purging |
| [api/meta.md](api/meta.md)               | [db/repeatable/60_meta.sql](db/repeatable/60_meta.sql)         | `schema_version()` |

The files are applied by `wtfd schema` (see [WTFD.md](WTFD.md)). Migrations run once, in order; the repeatable scripts are rebuilt as a whole whenever one of them changes.

## Conventions

- **Functions, not procedures.** Every API entry point is a `FUNCTION` returning `jsonb` (or `void` for deletes, which mark objects deleted).
- **History.** Every change to the data is logged by a trigger: who, when, what changed. It can be read per object with the history privilege; see [api/history.md](api/history.md).
- **Deleting marks objects** instead of removing them; see [api/deleting.md](api/deleting.md). Lists and trees leave deleted objects out; `_get` and `code_resolve` still return them, with `deleted: true`. A deleted object can't be changed, only restored (`<entity>_restore(p_id, p_options)`) or purged by the operator.
- **Logins.** Every API function works on behalf of a logged-in account (see [ACCOUNTS.md](ACCOUNTS.md) and [api/account.md](api/account.md)).
  - `wtfd` calls `session_use(token)` first in each transaction.
  - The function checks the account's privilege (`data`, `model`, `account` or `history`; read or write).
- **Access.**
  - API functions are `SECURITY DEFINER`: they run with the privileges of their owner, `wtf_dba`, not those of the caller.
  - Each one pins `search_path = public, pg_temp`, so a caller can't redirect table or function names to objects of its own.
  - The REST layer connects as `wtf_api`. That role may only `EXECUTE` the API functions; it has no access to tables, views, the `util` schema or other functions. See [README.md](README.md).
- **Naming.**
  - API functions are `<entity>_<verb>` in schema `public`: `list`, `get`, `create`, `patch`, `delete`, `restore`, plus a few domain verbs (`class_attribute_set`, `stock_move`).
  - Internal helpers live in schema `util` and are not called by the REST layer.
  - Parameters start with `p_`, local variables with `v_`. This keeps them apart from column names such as `class` or `item`.
- **Create and patch.**
  - Create functions take every field as a parameter.
  - Changes go through `<entity>_patch(p_id, p_patch jsonb)`, with PATCH semantics: only the keys present in `p_patch` change, and a key set to `null` clears a nullable field (e.g. `{"parent": null}` makes a class a root).
  - Unknown keys, and `null` for a required field, are rejected (22023).
  - Both return the object in the same shape as the matching `get`.
- **Names are trimmed** before they are stored.
- **No `/` in class and location names.** The `create` and `patch` functions reject them with 22023 (400), because `/` separates the names in a path.
- **Lists.**
  - The class and location trees sort numbers inside names by their value (`A2` before `A10`, `Shelf 2` before `Shelf 10`), ignoring case (`util.natural_key`).
  - Lists are sorted alphabetically by name, case-insensitively, with `id` as a tie-breaker.
  - Lists of system data and of things defined once (quantities, unit families, units, attributes, options) are small, and return a plain JSON array of everything.
  - Only the lists that grow with the inventory, `item_list` and `stock_list`, are paged, with `p_limit` (1–1000, default 100) and `p_offset` (default 0). They return this envelope:

    ```json
    { "total": 42, "limit": 100, "offset": 0, "rows": [ ... ] }
    ```
- **Trees.**
  - `class_list` and `location_list` always return the whole tree, as nested `{id, name, parent, children}` nodes.
  - Each tree has a version counter that changes with every change to that table. The response is `{version, unchanged, tree}`.
  - A client that sends the version it already has (`p_known_version`) gets `{version, unchanged: true}` without the tree. This costs a single row lookup.
  - The REST layer maps this to `ETag` / `If-None-Match` and `304 Not Modified`.
  - Other objects refer to classes and locations by id; the client resolves them from its cached trees. `class_get` and `location_get` still include the `path` from the root.
- **Search.** `item_list`'s `p_search` (`GET /items?search=`) is split into words at spaces. Every word must occur, as a case-insensitive substring, in at least one of:
  - the item name;
  - the name of a class in the item's class path ("resistor" also finds items in *Resistors → SMD*);
  - a text or URL value;
  - the name of a choice value.

  Values include class defaults the item shows. Different words may match in different places, so "resistor 0805" finds 0805 resistors. Results stay alphabetical, and the search combines with the `p_class` filter.
- **Attribute filters.** `item_list`'s `p_where` (`GET /items?where=`, JSON) is a list of conditions on attribute values, all of which must match; see [api/item.md](api/item.md). For example `[{"attribute": "<Resistance>", "op": ">=", "value": 32000}]`. They combine with `p_search` and `p_class`.
- **Per-unit attributes.** A class assignment with `per_unit` puts the attribute's values on stock rows (`stock_value_set`, or `values` in `stock_create`) instead of on the item, e.g. a serial number or purchase date. Defaults work the same way for both scopes.
  - **Splitting** a row with `stock_move` copies its per-unit values.
  - **Merging** only happens when both rows have exactly the same per-unit values; otherwise the moved part becomes a row of its own.
  - **Search** also finds items by the text and choice values of their stock rows.
- **Required attributes.** A `required` assignment must be satisfied, by a value or a default, when an item or stock row is created. A required value can't be removed. Requirements added later are only reported:
  - `item_get` and `stock_get` list `missing` attributes, for the item and for each stock row;
  - `item_list` rows have `incomplete: true` when the item or one of its stock rows lacks a required value.
- **Attachments.** Files on items, stock rows, locations and classes; see [api/attachment.md](api/attachment.md). They are listed as `attachments` in the `_get` responses of those objects. Items also show their primary photo as `photo` in `item_get` and `item_list`.
- **Defaults are fallbacks.** A class attribute's default is never stored on an item. `item_get` lists the item's own values, plus the current default for every effective attribute that has no value of its own. Those entries are marked `"is_default": true`, so changing a default affects every item that relies on it.
- **Typed values.** Values and defaults are passed as `jsonb`. The function converts them using the attribute's datatype:

  | Datatype  | JSON input                                   | JSON output              |
  |-----------|----------------------------------------------|--------------------------|
  | `text`    | string                                       | string                   |
  | `url`     | string starting with `http://` or `https://` | string                   |
  | `integer` | whole number                                 | number                   |
  | `float`   | number                                       | number                   |
  | `date`    | string `"YYYY-MM-DD"`                        | string `"YYYY-MM-DD"`    |
  | `boolean` | `true` / `false`                             | boolean                  |
  | `choice`  | option id or option name (case-insensitive)  | `{"id": …, "name": …}`   |

- **Units.**
  - **System data:** quantities, unit families and units are seeded and read-only (see [seed/units.md](seed/units.md)). They have integer ids; everything else has UUIDs.
  - **Units:** an attribute (for values and defaults) or an item (for stock quantities) may have a unit. That makes its numbers measurements of the unit's quantity. Each unit belongs to one family, such as Metric length.
  - **Unit lock:** with `unit_lock`, numbers are always shown in the unit itself. Without it (the default), they are scaled within the unit's family.
  - **Storage and input:** such numbers are stored, and must be given, in the base unit of the quantity (metres, kilograms, ohms, kelvin, …). Counts use the integer datatype; every other quantity uses float.
  - **Output:** the number is returned in the base unit, plus a `display` version:

    ```json
    { "value": 0.0012, "display": { "value": 1.2, "unit": { "symbol": "mm", … } } }
    ```

    Without Unit lock, the display unit is the largest unit of the family in which |value| ≥ 1. If there is none, the smallest unit is used. Zero is always shown in the unit itself. `display` is `null` when there is no unit.
  - **Client conversion:** every unit includes its `base_factor` and `base_offset`, so the client can convert input to the base unit, and output to any unit, by itself:

    ```text
    base = value × base_factor + base_offset
    ```

    There is no conversion API call.

## Errors

Functions raise standard SQLSTATEs. Suggested HTTP mapping for the REST layer:

| SQLSTATE | Name                            | Raised when                                                 | HTTP  |
|----------|---------------------------------|-------------------------------------------------------------|-------|
| `P0002`  | `no_data_found`                 | The object named by the URL doesn't exist                   | 404   |
| `22023`  | `invalid_parameter_value`       | Bad input: wrong value type, bad paging, invalid move       | 400   |
| `22P02`, `22003`, `22008` | invalid text / out of range / bad date | Malformed uuid, number too large, impossible date | 400 |
| `23514`  | `check_violation`               | Integrity rule from a CHECK or trigger (cycle, wrong datatype, orphaned values, …) | 422 |
| `23505`  | `unique_violation`              | Duplicate name                                              | 409   |
| `23001`  | `restrict_violation`            | On delete: something live still depends on the object | 409   |
| `55000`  | `object_not_in_prerequisite_state` | The object, or one it needs, is deleted; or a restore of something that isn't deleted (the `hint` names the ways out) | 409   |
| `23503`  | `foreign_key_violation`         | On create/update: a referenced object doesn't exist | 422   |
| `23502`  | `not_null_violation`            | A required parameter was NULL                               | 400   |
| `28000`  | `invalid_authorization_specification` | Not logged in, or the session has expired              | 401   |
| `42501`  | `insufficient_privilege`        | The account lacks the privilege                             | 403   |

## JSON shapes

```text
display    { value, unit: unit }    -- a base-unit number as shown: scaled within the family, or in the unit with unit_lock
tree       { version, unchanged: false, tree: [ node ] }  or  { version, unchanged: true }
node       { id, name, parent, container, children: [ node ] }   (location nodes also have code)
quantity   { id, name, datatype }
           quantity_get adds   families: [ { id, name, units: [ unit ] } ]
unit       { id, name, symbol, family: { id, name }, quantity: quantity, base_factor, base_offset }
unit_family { id, name, quantity: quantity, units: [ unit ] }  (units smallest to largest)
attribute  { id, name, datatype, unit: unit | null, unit_lock, deleted }
           attribute_get adds  options: [ { id, name } ]  for choice attributes
option     { id, attribute, name, deleted }
class      { id, name, parent, container, path: [ { id, name } ], deleted }
           class_get adds  attributes: [ { attribute, defined_on_class, inherited, default, default_display: display | null, per_unit, required } ], attachments: [ attachment ]
location   { id, code, name, parent, container, path: [ { id, name } ], deleted }
           location_get adds  attachments: [ attachment ]
attachment { id, file_name, content_type, size, sha256, caption, primary_photo, deleted }
item       (list)  { id, code, name, class: <class id>, unit: unit | null, unit_lock, deleted,
                     stock: { total, display: display | null, uncounted }, incomplete }
           (get)   { id, code, name, deleted, class: class, unit: unit | null, unit_lock,
                     values: [ value ], missing: [ { id, name } ],
                     stock: [ { id, code, location: <location id>, quantity, display: display | null,
                                values: [ value ], missing: [ { id, name } ] } ] }
value      { attribute, value, display: display | null, is_default }
stock      { id, code, item: item (list form, without stock total), location: <location id>,
             quantity: number | null, display: display | null,
             deleted, merged_into: { id, code } | null,
             values: [ value ], missing: [ { id, name } ] }   (values and missing not in stock_list rows)
```

## Function index

Suggested REST routes are only there to show intent. The REST design comes later.

| Function | Returns | Suggested route |
|----------|---------|-----------------|
| `quantity_list()` | [quantity] | `GET /quantities` |
| `quantity_get(p_id)` | quantity (+ families with their units) | `GET /quantities/{id}` |
| `unit_family_list(p_quantity)` | [unit family (+ units)] | `GET /unit-families?quantity=` |
| `unit_family_get(p_id)` | unit family (+ units) | `GET /unit-families/{id}` |
| `unit_list(p_quantity, p_family)` | [unit] | `GET /units?quantity=&family=` |
| `unit_get(p_id)` | unit | `GET /units/{id}` |
| `attribute_list()` | [attribute] | `GET /attributes` |
| `attribute_get(p_id)` | attribute (+ options) | `GET /attributes/{id}` |
| `attribute_create(p_name, p_datatype, p_unit, p_unit_lock)` | attribute | `POST /attributes` |
| `attribute_patch(p_id, p_patch)` | attribute | `PATCH /attributes/{id}` |
| `attribute_delete(p_id)` | void | `DELETE /attributes/{id}` |
| `attribute_restore(p_id, p_options)` | attribute (+ options) | `POST /attributes/{id}/restore` |
| `attribute_option_list(p_attribute)` | [option] | `GET /attributes/{id}/options` |
| `attribute_option_get(p_id)` | option | `GET /options/{id}` |
| `attribute_option_create(p_attribute, p_name)` | option | `POST /attributes/{id}/options` |
| `attribute_option_patch(p_id, p_patch)` | option | `PATCH /options/{id}` |
| `attribute_option_delete(p_id)` | void | `DELETE /options/{id}` |
| `attribute_option_restore(p_id, p_options)` | option | `POST /options/{id}/restore` |
| `class_list(p_known_version)` | tree | `GET /classes` (ETag) |
| `class_get(p_id)` | class (+ attributes) | `GET /classes/{id}` |
| `class_create(p_name, p_parent)` | class (+ attributes) | `POST /classes` |
| `class_patch(p_id, p_patch)` | class (+ attributes) | `PATCH /classes/{id}` |
| `class_delete(p_id)` | void | `DELETE /classes/{id}` |
| `class_delete_tree(p_id, p_force, p_dry_run)` | `{classes, items, stock}` deleted | `DELETE /classes/{id}?recursive=true[&force=true]`; preview `GET /classes/{id}/deletion` |
| `class_restore(p_id, p_options)` | class (+ attributes) | `POST /classes/{id}/restore` |
| `class_attribute_set(p_class, p_attribute, p_default, p_per_unit, p_required)` | class (+ attributes) | `PUT /classes/{id}/attributes/{attribute}` |
| `class_attribute_remove(p_class, p_attribute)` | class (+ attributes) | `DELETE /classes/{id}/attributes/{attribute}` |
| `item_list(p_class, p_search, p_limit, p_offset, p_where)` | page of item (list form, with stock total) | `GET /items?class=&search=&where=` |
| `item_get(p_id)` | item | `GET /items/{id}` |
| `item_create(p_class, p_name, p_unit, p_unit_lock, p_values)` | item | `POST /items` |
| `item_patch(p_id, p_patch)` | item | `PATCH /items/{id}` |
| `item_delete(p_id)` | void | `DELETE /items/{id}` |
| `item_restore(p_id, p_options)` | item | `POST /items/{id}/restore` |
| `value_set(p_item, p_attribute, p_value)` | item | `PUT /items/{id}/values/{attribute}` |
| `value_delete(p_item, p_attribute)` | item | `DELETE /items/{id}/values/{attribute}` |
| `location_list(p_known_version)` | tree | `GET /locations` (ETag) |
| `location_get(p_id)` | location | `GET /locations/{id}` |
| `location_create(p_name, p_parent)` | location | `POST /locations` |
| `location_patch(p_id, p_patch)` | location | `PATCH /locations/{id}` |
| `location_delete(p_id)` | void | `DELETE /locations/{id}` |
| `location_delete_tree(p_id, p_force, p_dry_run)` | `{locations, stock}` deleted | `DELETE /locations/{id}?recursive=true[&force=true]`; preview `GET /locations/{id}/deletion` |
| `location_restore(p_id, p_options)` | location | `POST /locations/{id}/restore` |
| `stock_list(p_item, p_location, p_limit, p_offset)` | page of stock | `GET /stock?item=&location=` |
| `stock_get(p_id)` | stock | `GET /stock/{id}` |
| `stock_create(p_item, p_location, p_quantity, p_values)` | stock | `POST /stock` |
| `stock_patch(p_id, p_patch)` | stock | `PATCH /stock/{id}` |
| `stock_move(p_id, p_location, p_quantity)` | stock (at destination) | `POST /stock/{id}/move` |
| `stock_delete(p_id)` | void | `DELETE /stock/{id}` |
| `stock_restore(p_id, p_options)` | stock | `POST /stock/{id}/restore` |
| `stock_value_set(p_stock, p_attribute, p_value)` | stock | `PUT /stock/{id}/values/{attribute}` |
| `stock_value_delete(p_stock, p_attribute)` | stock | `DELETE /stock/{id}/values/{attribute}` |
| `attachment_lock(p_sha256)`, `attachment_create(…)` | attachment | `POST /items\|stock\|locations\|classes/{id}/attachments` (multipart, via wtfd) |
| `attachment_get(p_id)` | attachment | `GET /attachments/{id}` (content: `GET /attachments/{id}/content`, via wtfd) |
| `attachment_patch(p_id, p_patch)` | attachment | `PATCH /attachments/{id}` |
| `attachment_delete(p_id)` | void | `DELETE /attachments/{id}` |
| `attachment_restore(p_id, p_options)` | attachment | `POST /attachments/{id}/restore` |
| `login(p_email, p_password)` | `{ok, token, account}` or `{ok: false, reason}` | `POST /api/v1/login` (the token becomes the session cookie) |
| `session_use(p_token)` | void | – (called by wtfd before every function) |
| `logout()` | void | `POST /logout` |
| `me()` | account | `GET /me` |
| `password_change(p_current, p_new)` | void | `PUT /me/password` |
| `account_list()` | [account] | `GET /accounts` |
| `account_get(p_id)` | account | `GET /accounts/{id}` |
| `account_create(p_email, p_password, p_data_privilege, p_model_privilege, p_account_privilege, p_history_privilege)` | account | `POST /accounts` |
| `account_patch(p_id, p_patch)` | account | `PATCH /accounts/{id}` |
| `account_delete(p_id)` | void | `DELETE /accounts/{id}` |
| `item_history(p_id, p_limit, p_offset)` | page of history entries | `GET /items/{id}/history` |
| `stock_history(p_id, p_limit, p_offset)` | page of history entries | `GET /stock/{id}/history` |
| `location_history(p_id, p_limit, p_offset)` | page of history entries | `GET /locations/{id}/history` |
| `class_history(p_id, p_limit, p_offset)` | page of history entries | `GET /classes/{id}/history` |
| `attribute_history(p_id, p_limit, p_offset)` | page of history entries | `GET /attributes/{id}/history` |
| `account_history(p_id, p_limit, p_offset)` | page of history entries | `GET /accounts/{id}/history` |
| `location_list_history(p_limit, p_offset)` | page of history entries | `GET /locations/history` |
| `class_list_history(p_limit, p_offset)` | page of history entries | `GET /classes/history` |
| `attribute_list_history(p_limit, p_offset)` | page of history entries | `GET /attributes/history` |
| `code_resolve(p_code)` | `{type, object}` | `GET /codes/{code}` |
| `schema_version()` | `{version, repeatables}` | – (used by `wtfd serve` at startup) |

## Open questions

1. **Naming.** Function and parameter names follow the conventions above until we go through your naming preferences.

### Deferred

- **Search filters.** Structured filters on attribute values (e.g. Resistance between 9 and 11 kΩ). Text search exists; see "Search" above.
- **Search indexes.** Trigram indexes (`pg_trgm`) for substring search on large data. Not needed at household scale; they can be added in a migration without changing the API.
