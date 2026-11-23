# Classes

The SQL is in [`db/repeatable/31_class.sql`](../db/repeatable/31_class.sql). A class's attributes, and how they are changed, are in [attribute.md](attribute.md).

## The tree

- **`class.list(p_known_version)`** is the class tree, flat, which `wtfd` nests (`GET /classes`, with `ETag` and `If-None-Match`): `{id, name, parent, container}` for every class. The tree's version is `meta.class_version`; any change of a class, its attributes included, moves it on.
- **`class.get(p_class)`** is a class with its path from the top, its attributes, and its rule for counting stock, `stock: {counting, unit, from}`.
- **`class.create(p_name, p_parent, p_container)`** makes a class below `p_parent` (null: at the top), with the parent's attributes and rule for counting stock. Names are unique among siblings, letter case ignored, and can't contain "/".
- **`class.patch(p_class, p_patch)`** changes `name`, `parent` and `container`.
  - **A move** below itself is refused. Moving a class gives it and the classes below it what they inherit from the new place; every item and stock row below it is then checked, and refused as a whole if one doesn't fit (a value of an attribute it no longer has, a required value missing).
  - **A move** that changes the rule for counting stock it inherits is checked against the stock below it too, and refused when a row doesn't fit the new rule, or when counted stock would get another unit (nothing converts: give the class a rule of its own first).
  - **A rename or a move** rewrites the search texts of the items below it, which have the names of their classes ([item.md](item.md)).

## How stock is counted

A class says how the stock of its items is counted ([2026-11-22-stock-rules-on-classes.md](../2026-11-22-stock-rules-on-classes.md)):

- **`counting`:** `none`, not counted (a stock row says it is there, and has no amount); `optional`, an amount may be left out ("not counted yet"); `required`, every stock row has one.
- **`unit`:** what amounts are counted in, a label such as `m` (nothing converts); null for pieces, whose amounts are whole. None when nothing is counted.
- **Inherited:** a class has a rule of its own, or its parent's; a top-level class without one of its own has the default, `optional` in pieces. `from` says whose rule it is: the class's own id, an ancestor's, or null for the default. The rule is stored resolved on every class (`class.counting`, `class.unit`, `class.stock_from`), as its attributes are, and `class.rebuild` makes it again when it changes above.
- **`class.stock_set(p_class, p_counting, p_unit, p_dry_run)`** (`PUT /classes/{id}/stock`, `{counting, unit}`) gives the class a rule of its own; **`class.stock_inherit(p_class, p_dry_run)`** (`DELETE /classes/{id}/stock`) makes it inherit again. The classes below that inherit it follow. Every stock row below is then checked against its class's new rule (`class.check_stock`), and the change is refused (23514, 422) when one doesn't fit, with how many and one of them. Counted stock that gets another unit keeps its amounts: the answer, as for an attribute change, has `relabelled`, how many such rows, and a dry run says so first, for the client to ask.
- **Stock rows are checked when written** (`stock.check_amount`): no amount where nothing is counted, one where it is required, whole in pieces, never below 0. A stock row given to an item of a class that counts in another unit keeps its amount only when the change gives it too.

## Containers

A class created or patched with `container: true` holds only other classes: an item can't be put in it, and `class.patch` refuses to make a class with items a container (23514, 422). Containers organise the tree, e.g. *Hardware* above *Screws* and *Nuts*.

## Deleting a subtree

Deleting removes a class for good; see [deleting.md](deleting.md). `class.delete` deletes one class, which must have no subclasses or items (409 otherwise, saying which). `class.delete_tree(p_class, p_force, p_dry_run)` (`DELETE /classes/{id}?recursive=true`) deletes a class and every class below it, all or nothing:

- **Items block it:** if any of the classes has items, nothing is deleted (23001, 409), and the message names the classes and their item counts (`MCU/Intel/No (3 items)`).
- **`p_force`** (`force=true`) deletes those items too, with their stock rows.
- **`p_dry_run`** deletes nothing; it only reports. Its route is a `GET`, `GET /classes/{id}/deletion?force=…`, so a server that doesn't know recursive deletes answers 404 rather than mistaking a preview for a delete. Unlike the delete, the preview reports items without `force` instead of failing.
- **The result** is what was (or would be) deleted: `{classes: [{id, path}], items: [{id, code, name, class}], stock: <number of stock rows>}`, classes deepest first.

## Model files

`model.export(p_class)` (`GET /classes/{id}/model`) is a model file of a class and the classes below it, and `model.import(p_data, p_parent, p_dry_run)` (`POST /model/import`) imports one; see [seed/model-format.md](../seed/model-format.md). The SQL is in [`db/repeatable/60_model.sql`](../db/repeatable/60_model.sql).
