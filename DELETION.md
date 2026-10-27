# Deleting by marking as deleted

**Status:** agreed on 27 October 2026 (see [Decisions](#decisions)); nothing is built yet. Once it is agreed and built, its rules move into [SCHEMA.md](SCHEMA.md), [API.md](API.md) and the files in [api/](api/), and this file goes.

Today, deleting an item, stock row, location, class, attribute, option or attachment removes its row. History keeps a copy of the row (see [api/history.md](api/history.md)), but the object can't be restored, opened or found any more. Accounts already work differently: they are only marked `deleted` (migration 0007).

This design does the same for everything with an identity of its own. Deleted objects stay in the database and can be restored. Only an operator's purge removes them for good.

## What gets marked, and what is still removed

| Table | On delete | Why |
|-------|-----------|-----|
| `item`, `stock`, `location`, `class`, `attribute`, `attribute_option`, `attachment` | **marked deleted** | They have an identity: a label code, a name in a tree, a photo. They can be scanned, linked to and restored. |
| `account` | marked deleted, as today | Unchanged. |
| `value`, `stock_value`, `class_attribute` | **removed**, as today | They belong to their owner. Clearing a value or unassigning an attribute is a change to the owner, recorded in history. When the owner is marked deleted, they stay as they are, so a restore brings them back. |
| `quantity`, `unit`, `unit_group`, `unit_group_unit` | not deletable | Seeded system data. |
| `session` | removed, as today | Not tenant data. |
| `history` | only purged by age, as today | Unchanged. |
| `file` | removed by `wtfd files gc` once no attachment refers to it, as today | A deleted attachment still refers to its file, so the file stays until the attachment is purged. |

## The column

Each of the seven tables gets `deleted boolean NOT NULL DEFAULT false`, like `account`.

It's a flag, not a date. When and by whom something was deleted is already in history, and a date column would store it a second time.

**Stock rows merged by a move** also get `merged_into uuid NULL`, a reference to the row they were merged into (see [Merged stock rows](#merged-stock-rows)). A CHECK ensures `merged_into` is only set on a deleted row.

## The principle: rules apply to live rows

A row that isn't deleted is **live**. Every rule the database enforces today keeps applying, but only between live rows. **Deleted rows are frozen:** they can't be changed, only restored or purged. **Restoring** makes a row live again and checks it against every rule, exactly as if it were inserted. If a rule fails, the restore fails with that rule's message.

That keeps deleted rows from blocking anything that is still in use. It also means a restore can fail. For example, the restore fails if a new box has taken the old box's name.

### Uniqueness

These unique indexes become partial (`WHERE NOT deleted`), so a deleted object's name is free again:

- sibling names of classes and of locations;
- attribute names;
- option names within an attribute;
- the primary photo of an object.

Label codes stay unique across all rows, deleted or not. A code is never reused, so an old label always points to the same thing.

### References between rows

Foreign keys stay as they are. Rows aren't removed, so every reference still points to a row. Purging needs the cascades (see [Purging](#purging)).

What foreign keys can't express is "a live row may only refer to live rows". Triggers check it on insert and update:

- **A live stock row** needs a live item and a live location.
- **A live item** needs a live class.
- **A live location or class** needs a live parent, or none.
- **A live value or default** needs a live attribute, and for a choice, a live option.
- **A live class assignment** needs a live attribute.
- **A live attachment** needs a live owner (item, stock row, location or class).

The checks lock the referenced row (`FOR SHARE`), as the datatype triggers do, so a concurrent delete can't slip past them.

### The existing rules

Each trigger and check that looks at other rows only counts live ones:

- **Containers:** "holds no items or stock" counts live items and stock rows only.
- **Required attributes:** checked for live items and stock rows. A deleted item missing a required value is checked again when it's restored.
- **Values must match an attribute of the right scope:** applies to live items and stock rows. Removing an assignment, moving a class or changing an item's class is no longer blocked by values of deleted items. Restoring such an item fails, naming the values that no longer fit.
- **An attribute's datatype can't change while values, defaults or options exist:** counts the live ones. Deleted values of the old type would block a restore.
- **Whole-number stock:** applies to live rows.
- **Trees can't have cycles:** unchanged. Deleted nodes keep their parent, so a restore can't create a cycle either.
- **Data version:** marking and restoring are updates, so the tree counter changes as it does today.

## Deleting

Each delete function marks rows instead of removing them. All marks of one call happen in one transaction, as today. History then shows them as updates with `deleted: false → true`, sharing one transaction id.

| Function | Marks | Refused while |
|----------|-------|---------------|
| `item_delete` | the item | it has live stock (as today) |
| `stock_delete` | the row | — |
| `location_delete` | the location | it has live sublocations or stock (as today) |
| `location_delete_tree` | the location, every live location below it, and with `force` their live stock rows | without `force`: there is live stock (as today) |
| `class_delete` | the class | it has live subclasses or items (as today) |
| `class_delete_tree` | the class, every live class below it, and with `force` their live items and those items' live stock rows | without `force`: there are live items (as today) |
| `attribute_delete` | the attribute | live values, defaults or assignments to live classes use it (as today, but live only) |
| `attribute_option_delete` | the option | live values or defaults use it (as today, but live only) |
| `attachment_delete` | the attachment | — |
| `account_delete` | unchanged | — |

Below a deleted node, every row is marked explicitly, not just the top one. Every query then only has to check one row's flag, not its ancestors.

The deletion previews (`dry_run`) report the same as today, counting only live rows.

## Merged stock rows

`stock_move` merges a whole row into an identical row at the destination. Today the moved row is removed. With this design it's marked deleted, with `merged_into` set to the row it went into.

- **Scanning its label** answers "1C03 was merged into 1C05" and leads to 1C05. Old labels on bags and boxes keep working.
- **Restoring** it is refused, since its quantity now belongs to the other row. Splitting the quantity off again is a move.

## Restoring

A new function per kind restores an object, together with what was deleted with it:

| Function | Route | Restores | Where it is deleted |
|----------|-------|----------|---------------------|
| `item_restore(p_id, p_name, p_class, p_with_parents)` | `POST /items/{id}/restore` | the item, with its stock rows deleted in the same transaction | its class |
| `stock_restore(p_id, p_location, p_with_parents)` | `POST /stock/{id}/restore` | the row | its location |
| `location_restore(p_id, p_name, p_parent, p_with_parents)` | `POST /locations/{id}/restore` | the location, and everything below it that was deleted in the same transaction | its parent |
| `class_restore(p_id, p_name, p_parent, p_with_parents)` | `POST /classes/{id}/restore` | the class, and everything below it that was deleted in the same transaction, with the items and stock rows deleted with them | its parent |
| `attribute_restore(p_id, p_name)` | `POST /attributes/{id}/restore` | the attribute | — |
| `attribute_option_restore(p_id, p_name)` | `POST /options/{id}/restore` | the option | its attribute |
| `attachment_restore(p_id)` | `POST /attachments/{id}/restore` | the attachment | its owner |

- **What goes together** comes from history: the rows marked deleted in the same transaction as the object, below it or belonging to it. Restoring a box brings back the compartments and stock deleted with it. Compartments deleted earlier, on their own, stay deleted.
- **Rules:** everything is checked as described in [The principle](#the-principle-rules-apply-to-live-rows), in one transaction. Either all of it comes back or none of it does.
- **Name clashes:** `p_name` is an optional new name for the top object, for when its old name is taken.
- **Privileges:** the same as for deleting.
- **Return value:** the restored object, as its `_get` function returns it.

### Restoring into something that is deleted

A stock row can only be restored at a live location, a location or class only under a live parent, and an item only in a live class. If that's deleted, the restore offers two ways out:

- **Restore it there, with what it's in:** `p_with_parents` also restores the deleted location, parent or class, and any deleted ones above it. Only that chain is restored, not everything else that was deleted with them. Their other contents can then be restored one by one.
- **Restore it somewhere else:** `p_location` for a stock row, `p_parent` for a location or class, `p_class` for an item. It names a live place, and the object is restored there. With a top level location or class (`p_parent` given as null), it is restored at the top.

Without either, the restore is refused with 409, naming the deleted parent and both choices. The CLI asks which one, and so does the app, with a picker for the other place. Everything below a restored location or class comes back under it, wherever it is put.

An option of a deleted attribute and an attachment of a deleted owner have no alternative place. Their restore is refused, naming the attribute or owner to restore first.

## Reading

| What | Today | With this design |
|------|-------|------------------|
| Lists, search, trees, stock totals, `missing`, previews | all rows | live rows only |
| `item_get`, `stock_get`, `location_get`, `class_get`, `attribute_get`, `attachment_get` | 404 when removed | the object with `deleted: true` (stock rows also with `merged_into`), as `account_get` does today |
| `code_resolve` | 404 when removed | the object with `deleted: true` |
| Changing a deleted object (patch, move, values, attachments) | 404 | refused with `55000` (`object_not_in_prerequisite_state`), mapped to **409** "This … is deleted." |
| Attachment content of a deleted attachment | 404 | still served, so a deleted object's screen and history can show the photo |
| History | unchanged | unchanged; a delete is now an update of `deleted` |

Deleted values, assignments and attachments of a deleted object come with its `_get`, so a deleted item's screen can show everything it had.

## Purging

`wtfd deleted purge --older-than 730d [--tenant NAME] [--dry-run]`, like `wtfd history purge`, really removes rows that were deleted longer ago than that. It goes by the date of the history entry that marked them.

- It removes the top objects, and the cascades remove what belongs to them: values, assignments, options, attachments.
- Purge order is children before parents, as the tree deletes do today.
- Afterwards, `wtfd files gc` can remove files that no attachment refers to any more.
- Their history stays until `wtfd history purge` removes it.

Nothing purges by itself. When and how much is the operator's choice, as with history.

## Migration

Migration `0010_deleted.sql`:

1. Adds the columns, and the CHECK on `merged_into`.
2. Replaces the four kinds of unique indexes with partial ones.
3. Adds the live-reference triggers, and changes the existing triggers to count live rows.

There's no data to convert, because nothing is marked deleted yet. What was removed before this migration stays removed, and history keeps its copy.

The repeatable functions change throughout: every read filters `NOT deleted`, every delete becomes an update, and the restore and purge functions are new.

## Clients

- **wtfd:** the restore routes, the 409 mapping, `wtfd deleted purge`, and `openapi.yaml`.
- **CLI:**
  - `wtf <kind> restore <id or code>`, with `--name`, and `--with-parents` or `--to <place>` (asked for when needed and not given);
  - `wtf code` shows deleted and merged objects as such;
  - showing a deleted object marks it **deleted**.
- **App:**
  - a deleted object's screen shows it greyed, with a "Deleted on … by …" banner and Restore;
  - Restore asks, when needed, whether to restore what it was in too, or where else to put it;
  - a scanned or typed code of a merged row leads to the row it went into;
  - the history screen gets readable entries, with links to deleted objects, which is how you reach them.

## Tests

- **SQL, against `wtf_test` (Go integration tests):** for every table and rule:
  - deleting marks rows;
  - lists and trees leave deleted rows out;
  - names are free again;
  - live rows can't refer to deleted ones;
  - each existing rule ignores deleted rows;
  - restore with and without clashes;
  - restoring a whole tree in one go;
  - restoring into a deleted parent: refused, with the parents, and somewhere else;
  - merged rows;
  - purge.
- **API:** the new routes and the 409 mapping.
- **CLI and app:** restore, including both ways of restoring into something deleted.

## Decisions

Agreed on 27 October 2026:

1. **No "Recently deleted" list for now.** Deleted objects are reached through history, label codes and links. It can come later, since history already holds what it would need.
2. **Merged stock rows** are marked deleted with `merged_into`, so an old label leads to the row it went into.
3. **Fetching a deleted object** returns it, marked `deleted: true`.
4. **Restoring into something deleted** offers both: restore what it was in as well, or restore it somewhere else (see [Restoring into something that is deleted](#restoring-into-something-that-is-deleted)).
5. **No default for purging:** the operator chooses the age, as with history.
