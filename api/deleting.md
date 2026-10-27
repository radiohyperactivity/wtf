# Deleting and restoring

The schema is in [`db/migrations/0010_deleted.sql`](../db/migrations/0010_deleted.sql). The functions are in the repeatable scripts of each kind, with the shared helpers in [`10_util.sql`](../db/repeatable/10_util.sql).

Deleting an item, stock row, location, class, attribute, option or attachment doesn't remove its row; it sets `deleted`. Accounts have worked this way since migration 0007 (see [account.md](account.md)). A deleted object can still be fetched, scanned and restored. Only an operator's purge removes it for good.

## What is marked, and what is removed

| Table | On delete | Why |
|-------|-----------|-----|
| `item`, `stock`, `location`, `class`, `attribute`, `attribute_option`, `attachment` | **marked deleted** | They have an identity: a label code, a name in a tree, a photo. They can be scanned, linked to and restored. |
| `account` | marked deleted | See [account.md](account.md). |
| `value`, `stock_value`, `class_attribute` | **removed** | They belong to their owner. Clearing a value or unassigning an attribute is a change to the owner, recorded in history. When the owner is marked deleted, they stay as they are, so a restore brings them back. The options of a deleted attribute and the attachments of a deleted object stay unmarked in the same way. |
| `quantity`, `unit`, `unit_group`, `unit_group_unit` | not deletable | Seeded system data. |
| `session` | removed | Not tenant data. |
| `history` | only purged by age | See [history.md](history.md). |
| `file` | removed by `wtfd gc` once no attachment refers to it | A deleted attachment still refers to its file, so the file stays until the attachment is purged. |

`deleted` is a flag, not a date: when and by whom is in history, and a date column would store it twice. History records a delete as an update with `changes: {"deleted": {"old": false, "new": true}}`, and everything one call deleted shares its `transaction`.

## Rules apply to live rows

A row that isn't deleted is **live**. Every rule of [SCHEMA.md](../SCHEMA.md) applies between live rows only:

- **Names** are unique among live siblings only (classes, locations), as are attribute names, option names within an attribute and an object's primary photo. A deleted object's name is free again. **Label codes** stay unique across all rows and are never reused, so an old label always finds its object.
- **Live rows only refer to live rows** (triggers, which lock the referenced row `FOR SHARE`): a stock row's item and location, an item's class, a location's or class's parent, an option's attribute. A value, default or assignment needs a live owner, a live attribute and, for a choice, a live option; an attachment needs a live owner.
- **Something can only be deleted while nothing live depends on it** (triggers, 23001 as before): an item without live stock, a location or class with nothing live in it, an attribute or option that no live value, default or assignment uses.
- **The existing checks count live rows only:** containers, required attributes, values matching their attribute's scope, an attribute's datatype change. So values of deleted items never block a change to the model.

**Deleted rows are frozen.** Changing one, or its values, assignments or attachments, is refused with 55000 (`object_not_in_prerequisite_state`, 409): "Item "Drill" is deleted". The only changes are restoring it and purging it. Deleting it again changes nothing.

## Deleting

| Function | Marks | Refused while |
|----------|-------|---------------|
| `item_delete` | the item | it has live stock |
| `stock_delete` | the row | — |
| `location_delete` | the location | it has live locations or stock in it |
| `location_delete_tree` | the location, every live location below it, and with `force` their live stock rows | without `force`: there is live stock |
| `class_delete` | the class | it has live subclasses or items |
| `class_delete_tree` | the class, every live class below it, and with `force` their live items and those items' live stock rows | without `force`: there are live items |
| `attribute_delete` | the attribute | live values, defaults or assignments to live classes use it |
| `attribute_option_delete` | the option | live values or defaults use it |
| `attachment_delete` | the attachment | — |

Below a deleted node every row is marked explicitly, so a query only ever checks one row's flag. The previews (`…/deletion`) count live rows only.

**A stock row merged by a move** (`stock_move` of a whole row into an identical one) is marked deleted, with `merged_into` pointing to the row its quantity went into. Its label code still answers, with `merged_into`, so the app and CLI can lead to that row. It can't be restored: its quantity is in the other row now.

## Reading

- **Lists, search, trees, stock totals, `missing` and previews** leave deleted rows out.
- **Fetching one** (`item_get`, `stock_get`, `location_get`, `class_get`, `attribute_get`, `attribute_option_get`, `attachment_get`, `code_resolve`) still returns it, with `deleted: true`. Stock rows also have `merged_into` (`{id, code}` or null). Every object's JSON carries `deleted`.
- **A deleted item lists the stock rows deleted together with it,** which restoring it brings back. A live item lists its live rows.
- **Attachment content** of a deleted attachment, or of a deleted object, is still served.

## Restoring

| Function | Route | Restores | `p_options` keys |
|----------|-------|----------|------------------|
| `item_restore(p_id, p_options)` | `POST /items/{id}/restore` | the item, with its stock rows deleted together with it | `name`, `class`, `with_parents` |
| `stock_restore(p_id, p_options)` | `POST /stock/{id}/restore` | the row | `location`, `with_parents` |
| `location_restore(p_id, p_options)` | `POST /locations/{id}/restore` | the location, with the locations below it and their stock rows deleted together with it | `name`, `parent`, `with_parents` |
| `class_restore(p_id, p_options)` | `POST /classes/{id}/restore` | the class, with the classes below it, their items and those items' stock rows deleted together with it | `name`, `parent`, `with_parents` |
| `attribute_restore(p_id, p_options)` | `POST /attributes/{id}/restore` | the attribute, with its options (except those deleted on their own) | `name` |
| `attribute_option_restore(p_id, p_options)` | `POST /options/{id}/restore` | the option | `name` |
| `attachment_restore(p_id, p_options)` | `POST /attachments/{id}/restore` | the attachment | — |

`p_options` is a JSON object, the request body; all keys are optional.

- **What goes together** comes from history: the rows marked deleted in the same transaction as the object, below it or belonging to it. Restoring a box brings back the compartments and stock deleted with it; a compartment deleted earlier, on its own, stays deleted. If history no longer has the deletion (purged), only the object itself comes back.
- **Rules are checked again,** as if everything were new: names, live references, containers, values matching their attributes, required values (at commit). It all happens in one transaction, so either everything comes back or nothing does, with the message of the rule that failed. The functions "touch" the rows that belong to a restored one (`UPDATE … SET x = x`), so the triggers run again; history records nothing for that.
- **`name`** gives the top object a new name, for when its old one has been taken since.
- **Privileges** are those of deleting: data write for items, stock rows and locations; model write for classes, attributes and options. Restoring a class with items needs data write too, and restoring an item `with_parents` needs model write too.
- **The result** is the restored object, as its `_get` returns it.
- **A primary photo** comes back as the primary photo, unless its object has another one by then; then it comes back as an ordinary attachment.

### Restoring into something that is deleted

A stock row can only be restored at a live location, a location or class only under a live parent, and an item only in a live class. If that is deleted, the restore is refused (55000, 409), naming what is deleted, with a `hint` naming the two ways out:

- **`with_parents: true`** also restores the deleted location, parent or class, and the deleted ones above it. Only that chain comes back, not what else was deleted with them.
- **Somewhere else:** `location` for a stock row, `parent` for a location or class (null: at the top), `class` for an item, naming a live place. Everything below a restored location or class comes back under it.

An option of a deleted attribute, an attachment of a deleted object and a stock row of a deleted item have no other place: their restore is refused, naming what to restore first. Restoring the item also restores the stock rows deleted with it.

## Purging

```sh
wtfd deleted purge --older-than 730d [--tenant NAME] [--dry-run]
```

Removes for good what was deleted longer ago than that, by the date of the history entry that marked it. An object whose deletion is no longer in history counts as deleted long ago.

- **What belongs to a purged object goes with it** (the foreign keys cascade): values, assignments, the options of an attribute, attachments.
- **An object that something else still refers to stays** until that is purged too: an item while it has stock rows, a location or class while something is in it, an attribute or option while values or classes of deleted objects use it. Trees are purged from the leaves up.
- **A merged stock row** loses its `merged_into` when the row it points to is purged.
- **Afterwards** `wtfd gc` removes the files no attachment refers to any more. The history of purged objects stays until `wtfd history purge` removes it.
- **`--dry-run`** does the whole purge in a transaction, reports the counts and rolls it back.

Nothing purges by itself; when and how much is the operator's choice, as with history.

## Decisions

Agreed on 27 October 2026, when this replaced deleting rows:

1. **No "Recently deleted" list for now.** Deleted objects are reached through history, label codes and links. It can come later, since history already holds what it would need.
2. **Merged stock rows** are marked deleted with `merged_into`, so an old label leads to the row it went into.
3. **Fetching a deleted object** returns it, marked `deleted: true`.
4. **Restoring into something deleted** offers both: restoring what it was in as well, or restoring it somewhere else.
5. **No default age for purging:** the operator chooses it, as with history.
6. **A flag, not a date,** because history already says when and by whom (normalisation).
7. **Values, assignments and attachments of a deleted object aren't marked themselves;** they stay with their owner and come back with it.
