# Deleting

Deleting removes a row for good; there is no restore. A backup is the way back from a mistake ([README.md](../README.md), "Backups").

## What goes with it, and what stands in the way

An item's and a stock row's values and files are in their own rows, so they go with them. The foreign keys of [`db/migrations/0001_schema.sql`](../db/migrations/0001_schema.sql) decide the rest:

- **What others still use can't be deleted** (`RESTRICT`), and the delete function says what is in the way first (23001, 409, `/problems/in-use`):

  | Function | Refused while |
  |----------|---------------|
  | `item.delete` | the item has stock rows |
  | `location.delete` | locations or stock rows are in it |
  | `class.delete` | classes or items are in it |
  | `stock.delete`, `account.delete` | — (you can't delete your own account) |

- **An account's sessions** go with it (`ON DELETE CASCADE`).
- **An attribute or a choice** is removed with a change of its class ([attribute.md](attribute.md)): an attribute's values go with it, and a choice is refused while a row has it.

## Deleting a subtree

`class.delete_tree` and `location.delete_tree` (`DELETE /classes/{id}?recursive=true`, `DELETE /locations/{id}?recursive=true`) delete a class or location with everything below it, all or nothing:

- **Items or stock block it** (409, naming the classes or locations and how many each has), unless `force=true`, which deletes them too: a class's items with their stock rows, a location's stock rows (the items stay).
- **The preview** is a `GET`, `…/deletion?force=…`, so a server that doesn't know recursive deletes answers 404 rather than mistaking a preview for a delete.
- **The stock rows, the items and the classes or locations go in one statement each.** The parent keys are `RESTRICT`, which PostgreSQL checks once the statement's rows are gone, so a node and everything below it go together.

See [class.md](class.md) and [location.md](location.md) for what the answer holds.

## Labels of deleted things

A deleted item's, location's or stock row's label code answers **410 Gone** (`/problems/gone`): every code up to the last one handed out was given to something, so a code that nothing has belonged to something deleted. A code never handed out is 404. See [code.md](code.md).

## Files

A deleted item's or stock row's files stay on disk until `wtfd gc` finds that nothing has them any more, and removes them ([WTFD.md](../WTFD.md)).

## Decisions

Agreed on 1 November 2026 ([2026-11-01-dropping-deleted-and-history.md](../2026-11-01-dropping-deleted-and-history.md)), in place of marking things deleted and restoring them (27 October 2026):

1. **Deleting removes, and history goes with "mark as deleted":** they shared the record of who did what (`public.action`).
2. **Deleting something in use is refused, as before;** the recursive deletes with `force` stay.
3. **The delete functions name what is in the way;** the foreign keys are the guarantee.
4. **The parent keys stay `RESTRICT`,** and a subtree goes in one statement per kind.
5. **A deleted thing's label answers 410.**
6. **Moving and merging stock are two actions** (`stock.move`, `stock.merge`; see [location.md](location.md)).
