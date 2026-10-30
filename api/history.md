# History

The SQL is in [`db/repeatable/95_history.sql`](../db/repeatable/95_history.sql). The `history` table and its trigger are in [`db/migrations/0001_schema.sql`](../db/migrations/0001_schema.sql).

## What is recorded

Every insert, update and delete of the data writes one entry: classes, attributes, options, class attributes, items, values, locations, stock rows, per-unit values, attachments and accounts. A trigger writes the entries, so nothing can bypass it, and no API function has to remember to log. Each entry has:

| Field         | Meaning |
|---------------|---------|
| `happened_at` | start of the transaction, the same for all changes of one API call |
| `transaction` | groups the entries of one API call (e.g. the two stock rows of a split) |
| `account`     | who: `{id, email, deleted}` of the logged-in account, or `null` for changes outside the API (CLI, migrations) |
| `table`, `operation` | e.g. `stock` / `update` |
| `data`        | the row after the change (before it, for a delete) |
| `changes`     | updates only: `{column: {old, new}}` for every changed column |

Not recorded:

- **Sessions** (logins and logouts).
- **Account updates that only touch the lockout counters.**
- **Password hashes:** an account entry shows `has_password`, and a password change appears in `changes` as `"password": "changed"`.

## Reading

**Who:** the history of items and stock rows is for every account; that of locations, classes, attributes and accounts, and of the top-level lists, for admins. Entries come newest first, paged with `p_limit` and `p_offset`. They also work for deleted objects. Deleting an item, stock row, location, class, attribute, option or attachment is an `update` that sets `deleted` (see [deleting.md](deleting.md)). A `delete` entry is a cleared value, a removed class assignment, or a purge.

| Function | Route | Includes |
|----------|-------|----------|
| `item_history(p_id, …)` | `GET /items/{id}/history` | the item, its values, its stock rows and their per-unit values, and the attachments of the item and its stock rows |
| `stock_history(p_id, …)` | `GET /stock/{id}/history` | the row, its per-unit values and its attachments |
| `location_history(p_id, …)` | `GET /locations/{id}/history` | the location, stock rows that were there (including arrivals and departures), its attachments, and the locations directly inside it being added, moved in or out, deleted, restored or purged |
| `class_history(p_id, …)` | `GET /classes/{id}/history` | the class, its attribute assignments, its attachments, and the classes directly below it and its items being added, moved in or out, deleted, restored or purged |
| `attribute_history(p_id, …)` | `GET /attributes/{id}/history` | the attribute and its options |
| `account_history(p_id, …)` | `GET /accounts/{id}/history` | changes to the account itself |
| `location_list_history(…)` | `GET /locations/history` | top-level locations being added, moved to or from the top level, deleted, restored or purged |
| `class_list_history(…)` | `GET /classes/history` | top-level classes, the same way |
| `attribute_list_history(…)` | `GET /attributes/history` | attributes being added, deleted, restored or purged |

The last three are the histories of the lists themselves, so that a deleted top-level location or class, or a deleted attribute, which has no parent whose history would show it, can still be found.

## Deleted accounts

Deleting an account doesn't remove it; it is marked `deleted`, so history can always say who did something.

- It can't log in; it loses its password and its sessions, and becomes a viewer.
- Its email can be used for a new account.
- `account_list` leaves it out, while `account_get` still shows it, with `deleted: true`.

## Purging

History is kept until the operator purges it:

```sh
wtfd history purge --older-than 730d [--dry-run]
```
