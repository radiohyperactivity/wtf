# Dropping "mark as deleted", restore and history – plan

**Status: done (steps 1–7, 2026-11-01); not committed yet.** A follow-up to the three refactor plans of 31 October ([database](2026-10-31-database-refactor.md), [accessors](2026-10-31-pl-pgsql-accessor-refactor.md), [API](2026-10-31-api-refactor.md)), before the apps ([2026-10-31-changes-to-the-apps.md](2026-10-31-changes-to-the-apps.md)).

## How we work

As for the refactor: decisions written down here first, no rewrites until the plan is complete.

## Why now

- **Nothing is live yet.** The refactor's database is reset when it goes live (database decision 6), so `0001_schema.sql` can still change in place, with no migration and no data to carry over.
- **The apps haven't moved to the new API.** If this is done before the apps plan, the apps are changed once, and their plan gets smaller instead of larger.
- **`/api/v1` is at revision 1 and has no released client,** so it can change in place again (API decision 1).

## What it is today

Measured on `main` at `18b702d`.

**In the database** (`db/`, about 9,300 lines of SQL; 232 functions, 6,436 lines):

| What | Size |
|------|------|
| `deleted` columns (the action that deleted the row) | 8 tables: item, stock, location, class, attribute, attribute_option, attachment, account; plus `stock.merged_into` |
| `public.action` (who, when, which tenant) | a table; one row per changing call; `util.begin_action` in every changing function; the setting `wtf.action` |
| `public.history` | a table with three indexes, one of them GIN on `about`; written by `history.record`, a trigger on 11 tables |
| Restore functions | 10 functions, 429 lines |
| History pages and `history.record` | 11 functions, 361 lines (`70_history.sql`, 462 lines with the triggers) |
| Helpers for deleted rows and actions | 9 functions, 104 lines (`util.check_live`, `util.block_change_when_deleted`, `util.deleted_json`, `util.begin_action`, `error.deleted`, `error.not_deleted`, `error.restore_into_deleted`, …) |
| Triggers that exist for deleted rows, or re-check a row when it is restored | 26 of 121 triggers: 8 "frozen when deleted", 5 "refers only to live rows", 5 "deletable while nothing live uses it", and 8 that run again when `deleted` goes back to null |
| History triggers | 11 |
| Functions that mention `deleted` | 108 of 232; `deleted IS NULL` appears 119 times; 5 partial unique indexes (`WHERE deleted IS NULL`) |

**In `wtfd` and the CLI:** `internal/admin/deleted.go` (151 lines) and `history.go` (57) for `wtfd deleted purge` and `wtfd history purge`; 16 of about 90 routes (9 history pages, 7 restores); the problems `/problems/wrong-state` and `/problems/restore-into-deleted` (`WT001`); `internal/cli/restore.go` (205 lines), the history command and its formatting, and about 100 other lines that handle `deleted`, `merged_into` or restoring.

**Tests:** `deleted_test.go` (371 lines), `history_test.go` (148), `cli_deleted_test.go` (97), and parts of `rules_test.go`, `accessors_test.go` and `delete_tree_test.go`.

**Documents:** `api/deleting.md` (113 lines), `api/history.md` (55), and sections of API.md, SCHEMA.md, WTFD.md, ACCOUNTS.md, TENANTS.md and CLI.md.

**In the apps** (not changed yet): `lib/api/history_text.dart` (934 lines), `lib/screens/history_screen.dart` (256), `lib/widgets/restore.dart` (257), the "Deleted" banner on four screens, and about a third of the apps plan's sections.

## What we gain

### Less complexity

- **One state per row instead of two.** Today every rule has to ask "between live rows?", and every query has to leave deleted rows out. After: a row exists or it doesn't, and the foreign keys say what may refer to what. They are already shaped for it (values, assignments and attachments cascade with their owner; items, stock rows, units and options are `RESTRICT`; a photo is `SET NULL` when its attachment goes).
- **About 900 lines of SQL go outright** (restore, history, the deleted-row helpers), and **108 functions get simpler**: the `deleted IS NULL` filters, the `p_deleted` argument of every JSON helper, the "is deleted" checks at the top of every change.
- **26 + 11 triggers go,** and with them the hardest rules to reason about: that a restore must re-check values, required attributes and containers, that a deleted row is frozen, that a live row may only refer to live rows (with its `FOR SHARE` locks). The cross-cutting machinery of `action` and `wtf.action` (and the rule that a change without an action is refused) goes too.
- **Restoring was the most complex behaviour in the system:** "what was deleted together", restoring into something deleted (`with_parents`, or another place), merged rows that can't come back, an item's stock rows that only come back with it. All of it goes.
- **Operator chores go:** `wtfd deleted purge`, `wtfd history purge` and the purge of unreferenced actions. `wtfd gc` stays, for files and expired sessions.
- **Deleting a tenant becomes simple.** TENANTS.md says it isn't built because the history triggers would log every row; without them it is a few deletes in order and the tenant's files directory (decision 10).
- **The API, CLI and apps shrink with it:** 16 routes, two problem types, `deleted` and `merged_into` in every object, and the restore and history screens.

My estimate: about 15 % of the SQL, a similar share of the API's routes, and roughly 1,500 lines of the apps.

### Less runtime overhead

I haven't measured this; these are the operations the database does, counted from the code.

- **Writes about halve.** Every changing call now writes an action row, and every changed row also writes a history row, with two `to_jsonb` conversions, a comparison of every column, and three index entries (one in a GIN index). Creating an item with three values writes 9 rows today (the action, the item, 3 values, 4 history entries); after, 4. A stock move that splits a row with values and attachments roughly doubles its writes today in the same way.
- **The extra locks go:** "refers only to live rows" takes a `FOR SHARE` lock on every referenced row, on top of the lock the foreign key already takes.
- **Storage stops growing by itself.** History keeps every version of every row as JSON until someone purges it, so over time it becomes the largest table, with a GIN index to match. Deleted rows also stay until purged.
- **Reads gain little.** The `deleted IS NULL` filters are cheap with the partial indexes, and `deleted` is only looked up for rows that are deleted. The read-side gain is in simpler queries, not speed.
- **Bulk loads get faster.** The overnight `item.list` benchmark didn't finish loading its 50,000 items in 30 minutes. I suspect the row-level rules and history triggers, but haven't confirmed it.

## New challenges

- **A delete can't be undone.** That is the real cost. What helps:
  - deleting what has dependants stays refused unless asked for (an item with stock, a class or location with things in it), and a recursive delete still shows its preview first (`…/deletion`, `--yes`, the app's confirmation);
  - **backups are the safety net:** the README's nightly `pg_dump` and copy of the files directory (decision 8). Bringing one thing back from a backup is manual work, and that is the trade.
- **Nobody can see who changed what, or when.** "Who moved the drill?" has no answer any more, and neither does an account's activity. For a household that is probably fine; for a club or a workshop, less so (decision 7).
- **Old labels of deleted things don't resolve.** A scanned code answers 410 Gone, told from a code never handed out by the tenant's counter (decision 5), but not what it was. Codes are never reused, so a label never finds the wrong thing.
- **A stock row merged into another is gone.** Its label used to lead to the row it went into (`merged_into`); now it answers 410 like any deleted row. Merging is the user's own action now (decision 6), so they see where it went.
- **Deleting is final for attachments too,** and the file goes at the next `wtfd gc` (after `--min-age`). Nothing else about uploads and `gc` changes.
- **Error messages for "in use"** come from foreign keys unless we keep our own checks, and a foreign key's message names a constraint, not the things that use it; our own checks keep the messages (decision 3).
- **The API changes in place once more,** before any client is released (decision 11). Every client is rebuilt anyway.

Not a challenge, but worth saying: **nothing about tenants, sessions, label codes, versions (ETags), units or model files changes.** Deletes still bump the tree versions.

## Topics

All decided; the decisions below say what was chosen.

- **A. Scope**
  - ~~**A1. Both, or one of them.**~~ *Decided: 1.*
- **B. Deleting**
  - ~~**B1. Something still in use: refused, as today.**~~ *Decided: 2.*
  - ~~**B2. "In use" messages: our own checks, run before deleting.**~~ *Decided: 3, in the delete functions.*
  - ~~**B3. Recursive deletes in one statement per kind.**~~ *Decided: 4, with the parent keys `RESTRICT` as they are.*
- **C. Labels and stock rows**
  - ~~**C1. A deleted thing's code answers 404.**~~ *Decided: 5, 410 Gone for a code that was handed out.*
  - ~~**C2. A merged stock row is deleted outright.**~~ *Decided: 6, moving and merging are two actions.*
- **D. History**
  - ~~**D1. Nothing replaces it.**~~ *Decided: 7.*
- **E. Operations**
  - ~~**E1. The README gets a "Backups" section.**~~ *Decided: 8; it has one already, which changes.*
  - ~~**E2. `wtfd deleted purge` and `wtfd history purge` are removed.**~~ *Decided: 9.*
  - ~~**E3. `wtfd tenant delete`.**~~ *Decided: 10, later.*
- **F. API**
  - ~~**F1. `/api/v1` changes in place, revision stays 1.**~~ *Decided: 11.*
  - ~~**F2. Accounts are deleted for real.**~~ *Decided: 12.*

## Decisions

1. **Both go** *(yours)*. Topic A1. "Mark as deleted" with restore, and history, are dropped together, and with them `public.action`, `util.begin_action` and the setting `wtf.action`.
2. **Deleting something in use is refused, as today** *(yours)*. Topic B1. An item with stock rows, a location with stock or locations in it, a class with items or classes below it, an attribute that values or assignments use, an option that values or defaults use: 409, naming what is in the way. The recursive deletes, with `force` and the `…/deletion` preview, stay as they are. A delete takes along only what belongs to the thing alone: its values, attachments and assignments, an attribute's unused options.
3. **The "in use" messages come from the delete functions** *(yours)*. Topic B2. Each delete (`item.delete`, `location.delete`, `class.delete`, `attribute.delete`, `attribute.option_delete`) checks first and names what is in the way ("Location "Shelf 2" still has stock", 23001, 409); the foreign keys stay as the guarantee underneath. The five `check_deletable` triggers go, and no `BEFORE DELETE` trigger takes their place.
4. **The parent keys stay `RESTRICT`, and a subtree goes in one `DELETE` per kind** *(yours)*. Topic B3. `class.delete_tree` and `location.delete_tree` delete, with `force`, the subtree's stock, then its items (for classes), then all its classes or locations, each in one statement, and answer with what went (`RETURNING`). Tried on PostgreSQL 18: a `RESTRICT` key allows a parent and its child to go in one statement, as it is checked after the statement's rows are gone; it refuses the parent first in two statements, also when declared `DEFERRABLE INITIALLY DEFERRED` (only `NO ACTION` can be deferred). One statement per kind needs no deferral.
5. **A deleted thing's code answers 410 Gone** *(yours)*. Topic C1. Every code from `1000` (32768) up to the tenant's `code` was given to an item, location or stock row that was committed: `tenant.take_codes` is an `UPDATE` of the tenant's row, so a transaction that fails gives its codes back, and every caller uses all the codes it takes (one each, or `1 + columns × rows` for a location with a grid). So `code.resolve` answers:
    - a code a live item, location or stock row has: 200, as today;
    - a code from `1000` up to the tenant's `code` that nothing has: **410**, `/problems/gone`, "This label's item, stock row or location has been deleted" (a stock row merged away by a move included);
    - a code above the tenant's `code`, or below `1000`: 404, never handed out; a malformed code stays 400.

    Nothing is stored for it, and so it can't say what the label was. The rule it rests on, that whatever takes codes uses them all, is written on `tenant.take_codes` and tested. A new SQLSTATE of our own carries it to `wtfd`, as `WT001` did for the restore problem (the code is chosen in the accessors' step).
6. **Moving and merging stock are two actions** *(yours)*. Topic C2. The user decides which.
    - **`stock.move(p_stock, p_location, p_amount)` only moves:** a whole row keeps its code and changes location; a part (`p_amount`) is split off into a new row with a code of its own and copies of the values and attachments. It never merges, so a location may hold two rows of the same item.
    - **`stock.merge(p_stock, p_into, p_amount)`, new** (`POST /stock/{id}/merge`, `{into, amount}`): adds `p_amount` of the row (null: all of it) to row `p_into`, which may be at another location. Both rows must be of the same item and counted, and not the same row; their values must be the same, or it is refused (422, naming the attributes that differ). A whole merge deletes the source, whose label then answers 410 (decision 5), and its attachments move to the target, which keeps its own photo. A partial merge leaves the source with the rest, and its attachments stay with it. It returns the target row.
7. **Nothing replaces history** *(yours)*. Topic D1. Rows carry only their data: no `created` or `updated` columns, no activity log. If one is ever wanted, it is designed then, from what people ask of it.
8. **Backups are the way back, in the README only** *(yours)*. Topic E1. The README's "Backups" already has the scheduled `pg_dump`, the copy of the files directory and the restore into a new database. It changes:
    - the paragraphs on `wtfd history purge` and `wtfd deleted purge` go;
    - it says that a delete is final and a backup is the way back, and how to get one thing back: restore the backup beside the live database (`wtf_restored`), look the thing up there, and enter it again or copy it across by hand;
    - it says why the copy of the files directory has no `--delete`: the files of deleted attachments stay in the backup after `wtfd gc` removes them.

    No recovery command; if mistakes turn out to happen, that is a plan of its own.
9. **`wtfd deleted purge` and `wtfd history purge` are removed** *(yours)*. Topic E2. Anything still calling them fails with "unknown command"; nothing on the new schema schedules them yet.
10. **`wtfd tenant delete` is a later, separate step** *(yours)*. Topic E3. Without history it is simple: one transaction of deletes in order, as the keys to the tenant are mostly `RESTRICT` (stock, items, locations, classes, attributes, the tenant's own units, families and quantities, accounts, the tenant), then the tenant's files directory, after a confirmation. TENANTS.md says so in place of "the history triggers would log every row".
11. **`/api/v1` changes in place, and stays at revision 1** *(yours)*. Topic F1. Revision 1 has never been released: this goes live with the refactor and its database reset, as part of the same change as API decision 1. WTFD.md's "Versions" counts it in that one exception.
12. **Accounts are deleted for real** *(yours)*. Topic F2. `account.delete` removes the row, and its sessions with it; nothing else refers to an account any more. You still can't delete your own account, so a tenant keeps an admin. To shut someone out without deleting them, remove the password (`--no-password`), which keeps the account and its role.

## Plan

On `main`, before the apps, in the same order as the refactor; each step kept working and tested as before.

1. **The database** (`db/migrations/0001_schema.sql`, `0002` unchanged): the `deleted` columns, `merged_into`, `public.action`, `public.history`, the type `history_operation` and the partial indexes' conditions go; the parent keys stay `RESTRICT` (decision 4). The repeatable scripts lose `70_history.sql`, the deleted-row helpers in `11_util.sql` and `10_error.sql`, and the 26 + 11 triggers; the `check_deletable` triggers go, their checks moving into the delete functions (decision 3). SCHEMA.md follows.
2. **The accessors:** the 7 restore and 9 history functions the API calls go, with their helpers (83 API functions become 67); deletes become `DELETE`, each checking first what is in the way (decision 3), recursive deletes as decision 4; `util.begin_action` and `p_deleted` go from every function; reads lose their `deleted IS NULL` filters; `stock.move` no longer merges, and `stock.merge` is new (decision 6); `code.resolve` answers 410 for a code handed out that nothing has (decision 5), and the `get` functions 404 for what is gone; `account.delete` deletes (F2).
3. **`wtfd`:** the 16 routes, the two problem types and `deleted`/`merged_into` in the JSON go from `internal/serve/` and `openapi.json`; `POST /stock/{id}/merge` and `/problems/gone` (410) are new; `wtfd deleted purge` and `wtfd history purge` go (E2); `wtfd tenant create` and the operator's account commands lose their action.
4. **The CLI:** `restore`, `history`, `resolveDeleted` and the deleted notes go; `wtf stock merge <stock> <into> [amount]` is new, and `wtf code` says when a label's thing has been deleted; deleting asks for confirmation where it doesn't yet, as it can't be undone.
5. **Tests:** `deleted_test.go`, `history_test.go` and `cli_deleted_test.go` become tests of deleting (refused while in use, recursive with and without `force`, codes of deleted things, attachments and their files); the rules and accessor tests lose their deleted and history cases.
6. **The documents:** `api/deleting.md` becomes a short "Deleting", `api/history.md` goes, and API.md, WTFD.md, ACCOUNTS.md, TENANTS.md, CLI.md and the README ("Backups", decision 8) follow.
7. **The apps plan** loses its history and restore sections, and gains "a delete can't be undone" (confirmations); then the apps, as planned.

## Log

- **2026-11-01:** document started: what exists measured on `main` at `18b702d`; gains, challenges and topics proposed.
- **2026-11-01:** topics A1–F2 gone through one by one; decisions 1–12. Decision 4 corrects the first draft (the parent keys stay `RESTRICT`; tried on PostgreSQL 18). Decision 6 splits merging off from moving; decision 5 tells deleted labels (410) from unknown ones (404) by the tenant's code counter.
- **2026-11-01:** steps 1 to 7 done: the schema, the rules and the accessors (68 API functions: 83 less 7 restores and 9 history pages, plus `stock.merge`); `wtfd serve`, `openapi.json` and `wtfd`'s own commands; the CLI; the tests (all pass against `wtf_test`); the documents; the apps plan. Decided on my own along the way:
  - **`error.not_allowed`** (23514, 422) is new, for the merge's refusals, which decision 6 makes 422: said before anything changes, as the rules would.
  - **`error.gone` uses `WT001`,** the code the restore problem had: nothing was released with it.
  - **`model.import_file` lost its `p_account`,** which only named the action's account; `wtfd unit import --global` calls it with one argument fewer.
  - **A single delete asks on a terminal** ("Delete stock 1A7K? This can't be undone. [y/N]", or `--yes`), and doesn't ask without one, so scripts delete as before: a single delete is refused while anything is in or uses what it deletes. A recursive delete still needs `--yes` in a script, as before.
  - **A partial merge leaves the source's attachments with it;** only a whole merge moves them.
  - **`SCHEMA.html`** (the ER diagram) shows the schema from before the refactor of 31 October, so it was stale already; it isn't redrawn here. **`APP.md`** describes the apps, and changes with them.
- **2026-11-01 (evening):** the performance test (`TestPerformance`, off by default) replaces the old item list benchmark, and ran on 1,000 to 200,000 items; the results and the changes it led to are in `PERFORMANCE.md`. Bulk loads now take about 0.6 ms per item or stock row, so 50,000 items load in under 3 minutes, where the old benchmark didn't finish in 30. Every API function now has `SET jit = off`; `item.list` matches filters and words by joining and sorts its page as a top-N; `stock.list` sorts only ids and names.
