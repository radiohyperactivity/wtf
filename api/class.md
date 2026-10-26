# Classes and class attributes

The SQL is in [`db/repeatable/30_class.sql`](../db/repeatable/30_class.sql).

## Deleting a subtree

`class_delete` deletes one class, which must have no subclasses or items (409 otherwise). `class_delete_tree(p_id, p_force, p_dry_run)` (`DELETE /classes/{id}?recursive=true`) deletes a class and every class below it in one transaction, deepest first:

- **Items block it:** if any of the classes has items, nothing is deleted (23001, 409), and the message names the classes and their item counts (`MCU/Intel/No (3 items)`).
- **`p_force`** (`force=true`) deletes those items too, with their values, stock rows and attachments. This needs the data write privilege as well as model write.
- **`p_dry_run`** deletes nothing; it only reports. Its route is a `GET`, `GET /classes/{id}/deletion?force=…`, so a server that doesn't know recursive deletes answers 404 rather than mistaking a preview for a delete. Unlike the delete, the preview reports items without `force` instead of failing.
- **The result** is what was (or would be) deleted: `{classes: [{id, path}], items: [{id, code, name, class}], stock: <number of stock rows>}`, classes deepest first.

## Containers

A class created or patched with `container: true` holds only other classes: an item can't be put in it, and `class_patch` refuses to make a class with items a container (23514, 422). Containers organise the tree, e.g. *Hardware* above *Screws* and *Nuts*. `class_create(p_name, p_parent, p_container)` takes the flag, `class_patch` the key `container`, and `class_get`, `class_list` and the tree nodes include it.
