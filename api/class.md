# Classes

The SQL is in [`db/repeatable/31_class.sql`](../db/repeatable/31_class.sql). A class's attributes, and how they are changed, are in [attribute.md](attribute.md).

## The tree

- **`class.list(p_known_version)`** is the class tree, flat, which `wtfd` nests (`GET /classes`, with `ETag` and `If-None-Match`): `{id, name, parent, container}` for every class. The tree's version is `meta.class_version`; any change of a class, its attributes included, moves it on.
- **`class.get(p_class)`** is a class with its path from the top and its attributes.
- **`class.create(p_name, p_parent, p_container)`** makes a class below `p_parent` (null: at the top), with the parent's attributes. Names are unique among siblings, letter case ignored, and can't contain "/".
- **`class.patch(p_class, p_patch)`** changes `name`, `parent` and `container`.
  - **A move** below itself is refused. Moving a class gives it and the classes below it what they inherit from the new place; every item and stock row below it is then checked, and refused as a whole if one doesn't fit (a value of an attribute it no longer has, a required value missing).
  - **A rename or a move** rewrites the search texts of the items below it, which have the names of their classes ([item.md](item.md)).

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
