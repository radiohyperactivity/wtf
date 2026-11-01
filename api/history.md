# History

The SQL is in [`db/repeatable/70_history.sql`](../db/repeatable/70_history.sql): the rule `history.record` and the pages, which are in the schemas of what they are about (`item.history`, `class.list_history`, …). The `history` and `action` tables are in [`db/migrations/0001_schema.sql`](../db/migrations/0001_schema.sql).

## What is recorded

Every insert, update and delete of the data writes one entry: classes, attributes, options, class attributes, items, item values, locations, stock rows, stock values, attachments and accounts. A rule (`history.record`, a trigger) writes the entries, so nothing can bypass it, and no API function has to remember to log. Each change is part of an action (`util.begin_action`), and a change without one is refused. Each entry has:

| Field         | Meaning |
|---------------|---------|
| `id`          | the entry's number, which `before` pages by |
| `action`      | `{id, at, account}`: the action the change was part of, shared by all changes of one call (e.g. the two stock rows of a split), when it happened, and who: `{id, email, deleted}` of the logged-in account, or `null` for `wtfd`'s own work |
| `table`, `operation` | e.g. `stock` / `update`; values are in `item_value` and `stock_value` |
| `data`        | the row after the change (before it, for a delete) |
| `changes`     | updates only: `{column: {old, new}}` for every changed column |

Not recorded:

- **Sessions** (logins and logouts).
- **Account updates that only touch the lockout counters.**
- **Password hashes:** an account entry shows `has_password`, and a password change appears in `changes` as `"password": "changed"`.

## Reading

**Who:** the history of items and stock rows is for every account; that of locations, classes, attributes and accounts, and of the top-level lists, for admins. Entries come newest first, a page at a time: `p_before` is the id of the oldest entry the client has (none: from the newest), and the answer is `{rows, more}`, the `p_limit` entries (1–1000, default 100) older than that, and whether there are older ones still. Through the API: `?before=<id>&limit=<n>`; an `offset` is refused. They also work for deleted and purged objects, as each entry records what it is about (its own id and those of the rows it belongs to), found by one index. Deleting an item, stock row, location, class, attribute, option or attachment is an `update` that sets `deleted` to the action (see [deleting.md](deleting.md)). A `delete` entry is a cleared value, a removed class assignment, or a purge.

| Function | Route | Includes |
|----------|-------|----------|
| `item.history(p_item, …)` | `GET /items/{id}/history` | the item, its values, its stock rows and their per-unit values, and the attachments of the item and its stock rows |
| `stock.history(p_stock, …)` | `GET /stock/{id}/history` | the row, its per-unit values and its attachments |
| `location.history(p_location, …)` | `GET /locations/{id}/history` | the location, stock rows that were there (including arrivals and departures), its attachments, and the locations directly inside it being added, moved in or out, deleted, restored or purged |
| `class.history(p_class, …)` | `GET /classes/{id}/history` | the class, its attribute assignments, its attachments, and the classes directly below it and its items being added, moved in or out, deleted, restored or purged |
| `attribute.history(p_attribute, …)` | `GET /attributes/{id}/history` | the attribute and its options |
| `account.history(p_account, …)` | `GET /accounts/{id}/history` | changes to the account itself |
| `location.list_history(…)` | `GET /locations/history` | top-level locations being added, moved to or from the top level, deleted, restored or purged |
| `class.list_history(…)` | `GET /classes/history` | top-level classes, the same way |
| `attribute.list_history(…)` | `GET /attributes/history` | attributes being added, deleted, restored or purged |

The last three are the histories of the lists themselves, so that a deleted top-level location or class, or a deleted attribute, which has no parent whose history would show it, can still be found.

## Deleted accounts

Deleting an account doesn't remove it; it is marked `deleted`, so history can always say who did something.

- It can't log in; it loses its password and its sessions.
- Its email can be used for a new account.
- `account.list` leaves it out, while `account.get` still shows it, with its `deleted`; history entries show `deleted: true` on their account.

## Purging

History is kept until the operator purges it:

```sh
wtfd history purge --older-than 730d [--dry-run]
```
