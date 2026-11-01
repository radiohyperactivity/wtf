# Classes and their attributes

The SQL is in [`db/repeatable/31_class.sql`](../db/repeatable/31_class.sql).

## Assignments

`class.assign(p_class, p_attribute, p_default, p_scope, p_required)` gives a class, and the classes below it, an attribute, or changes the assignment; `class.unassign(p_class, p_attribute)` takes it away (refused while live items or stock rows have values that depend on it). `class.get` lists the class's attributes, its own and inherited, each with `assigned_to` (the class the assignment is on), `inherited`, `default` and `default_display`, `scope` (`"item"` or `"stock"`: where the values live) and `required`.

## Deleting a subtree

Deleting marks classes deleted; they can be restored (`class.restore`). See [deleting.md](deleting.md). `class.delete` deletes one class, which must have no live subclasses or items (409 otherwise). `class.delete_tree(p_class, p_force, p_dry_run)` (`DELETE /classes/{id}?recursive=true`) deletes a class and every live class below it in one action, deepest first:

- **Items block it:** if any of the classes has live items, nothing is deleted (23001, 409), and the message names the classes and their item counts (`MCU/Intel/No (3 items)`).
- **`p_force`** (`force=true`) deletes those items too, with their live stock rows.
- **`p_dry_run`** deletes nothing; it only reports. Its route is a `GET`, `GET /classes/{id}/deletion?force=…`, so a server that doesn't know recursive deletes answers 404 rather than mistaking a preview for a delete. Unlike the delete, the preview reports items without `force` instead of failing.
- **The result** is what was (or would be) deleted: `{classes: [{id, path}], items: [{id, code, name, class}], stock: <number of stock rows>}`, classes deepest first.

## Containers

A class created or patched with `container: true` holds only other classes: an item can't be put in it, and `class.patch` refuses to make a class with items a container (23514, 422). Containers organise the tree, e.g. *Hardware* above *Screws* and *Nuts*. `class.create(p_name, p_parent, p_container)` takes the flag, `class.patch` the key `container`, and `class.get` and the tree's nodes include it.
