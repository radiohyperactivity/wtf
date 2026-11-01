# API refactor – plan

**Status: planned; principles confirmed, topics decided, routes reviewed.** Part 3 of 3, after the database model ([2026-10-31-database-refactor.md](2026-10-31-database-refactor.md)) and the PL/pgSQL accessor functions ([2026-10-31-pl-pgsql-accessor-refactor.md](2026-10-31-pl-pgsql-accessor-refactor.md)).

## How we work

As for the database: no rewrites until the plan is complete, decisions written down here, and going back to an earlier part is fine.

## Principles

Confirmed.

1. **A thin layer:** each route calls one accessor, in one database call, and passes its answer on. `wtfd` shapes an answer only where a decision says so (the trees, decision 6 of the accessors), and takes a request's JSON apart into typed arguments (accessor decision 31).
2. **One vocabulary:** the JSON uses the database's names (`amount`, `scope`, `media_type`), so a word means the same in the schema, the accessors, the API, the CLI and the apps.
3. **Said, not assumed:** a field the accessor takes without a default is required in the request; the API adds no defaults of its own.
4. **`openapi/openapi.json` is the contract,** written with the routes, and checked against them by a test.
5. **Errors are problem documents** (RFC 9457), from the SQLSTATE in one place (`internal/serve/problem.go`, accessor decision 20).

## The API today

The REST service in `wtfd serve` (`internal/serve/`), which maps requests to the accessor functions, described by [openapi/openapi.yaml](openapi/openapi.yaml). Its clients are the CLI (`internal/cli/`, `internal/client/`) and the apps (`app/`).

Surveyed 2026-11-01: `internal/serve/` (2,017 lines in nine files), about 90 routes under `/api/v1` (revision 13), each mapped to an accessor with named arguments (`call.go`); uploads and downloads of attachments handled by `wtfd` itself (`attachments.go`); `openapi/openapi.yaml` (2,152 lines). Its clients: the CLI (`internal/cli/`, `internal/client/`) and the apps (`app/`), which recognise an old server and an unsupported API version.

## Topics

To decide, in this order (the notes below are where most come from):

- **A. Shape:** ~~A1 the API's version~~ *(decision 1)*; ~~A2 calling the accessors~~ *(decision 2)*; ~~A3 the host, the session and the address~~ *(decision 3)*.
- **B. Names and JSON:** ~~B1 the names the database changed~~ *(decision 4)*; ~~B2 units by id, and a quantity's base unit~~ *(decision 5)*; ~~B3 the unit families by version~~ *(decision 6)*; ~~B4 what `deleted` says~~ *(decision 7)*; ~~B5 duplicates~~ *(decisions 5, 8)*.
- **C. Routes:** ~~C1 history pages by `before`~~ *(decision 9)*; ~~C2 the trees nested by `wtfd`~~ *(decision 10)*; ~~C3 the user's sessions~~ *(decision 11)*; ~~C4 logging in~~ *(decision 12)*; ~~C5 passwords and ending sessions~~ *(decision 13)*.
- **D. Errors:** ~~D1 the problem types for 55000~~ *(decision 14)*.
- **E. `wtfd`'s own work:** ~~E1 the purge and the first account~~ *(decision 15)*; ~~E2 `wtfd gc`~~ *(decision 16)*.

Noted while planning the database and the accessors:

- **JSON with a fixed shape is taken apart by `wtfd`** (accessor decision 31): a location's `grid` becomes `p_columns`, `p_rows` and `p_confirm`; the API's JSON may stay.
- **Argument names** (accessor decision 26): `wtfd` calls the functions with named arguments, which become `p_quantity`, `p_item`, `p_account` and so on in place of `p_id`.
- **Units in a quantity's page repeat their quantity** (accessor function 14), as today; whether the JSON trims that is decided here.
- **`GET /unit-families` by version** (accessor decision 27): an `ETag` and `304`, as for the trees, through the same handler.
- **An attribute's options are in two places:** `attribute.get` (for choice attributes) and `attribute.option_list`. Whether the API needs both is decided here.
- **Units by id** (accessor decision 28): items, attributes, values, stock rows and `display` carry the unit's id; the apps and the CLI look it up in the families they keep (the CLI fetching `/unit-families` once per command that shows units, or keeping a copy by version).
- **The caller in every call** (accessor decision 22): `wtfd` passes `ROW(token, host, address)::public.request` as the first argument of every API function, in one call per request, in place of calling `session_use` first (`internal/serve/session.go`) and the function after.
- **The client's address for the session trail** (database decision 25): `wtfd` passes it to the database in `request`. Behind a reverse proxy it comes from `X-Forwarded-For`, which may only be trusted from a proxy the operator configures.
- **Logging in** takes the client's name and the user's choice of session lifetime (`max_idle`, none = never expires).
- **A quantity's base unit** is a unit now (database decision 26): its JSON can say so, as a unit, in place of a base symbol and name; and unit files keep stating the base symbol.
- **Names in the JSON that the database changed:** `amount` (decision 3), `scope` (2), `deleted` (15), `media_type` (9), an assignment's `assigned_to` (in place of `defined_on_class`, database R13), `decimal` (24), history's `action` with its `at` and `account` (28, 37; the apps and CLI read `happened_at`, `transaction` and `account` on each entry today). Whether the JSON follows each is decided here.
- **`wtfd gc` removes expired sessions** (accessor decision 17): `DELETE FROM session WHERE max_idle IS NOT NULL AND last_used <= now() - max_idle`, beside the attachment files.
- **`wtfd gc` calls `file_lock_key`** (`internal/files/gc.go`), which becomes `attachment.file_lock_key` (database decision 30).
- **`wtfd`'s own changes begin an action** (database decisions 36 and 37): the purge of deleted objects (`internal/admin/deleted.go`) runs one tenant at a time, each after `util.begin_action(<tenant>)`, and so does creating a tenant's first account; history refuses a change without an action. The purge also removes actions nothing refers to any more, neither a deleted row nor a history entry (database decision 37).
- **The tree handler nests the trees** (accessor decision 6): `class.list` and `location.list` return their nodes flat, sorted, each with its `parent`; the handler in `internal/serve/routes.go` builds `children` from them in one pass, keeping the database's order, so the API's JSON is unchanged.
- **History pages take `before`, not `offset`, and say `more`, not `total`** (accessor decision 8): the `…/history` routes and the CLI follow.
- **SQLSTATE 55000 is `/problems/wrong-state`** (accessor decision 20), "Not possible in this state", 409, in place of `/problems/deleted`. The CLI (`internal/cli/restore.go`, `intoDeleted`) and the app (`lib/api/client.dart`, `intoDeleted`) recognise a restore into something deleted by that type and the hint's text `with_parents`; whether that case gets a problem type of its own is decided here.
- **No per-request host check** (accessor decision 21): `withTenant` (`internal/serve/tenant.go`) and its call of `tenant_known` go; an unknown host is found by `account.session_use` or `account.login` (404); a request without a session cookie to a route that needs one gets 401 without the database; `openapi.yaml` is served for any host. TENANTS.md follows.
- **Changing one's password** takes whether to end the other sessions (accessor decision 24), with no default; an admin's patch of another account's password takes `end_sessions` with it (decision 25), and can't change the admin's own.
- **The user's sessions** (accessor decision 16): routes for `account.session_list`, `account.session_logout` (by the session's id, its token hash in hex) and `account.session_logout_others`; the CLI may show them too.

## Decisions

1. **`/api/v1` changes in place, and its revision starts again at 1** *(yours)*. Topic A1. Every client is rebuilt for the refactor, as is the database. Clients record the server's revision but refuse no mismatch, so a client built before it would misread answers rather than say it is too old; that only happens to a copy not updated. WTFD.md's "Versions" says that this one reset broke the rule that a version only adds, and why.
2. **One statement per request** *(yours)*. Topic A2. `SELECT <accessor>(p_request => ROW($1, $2, $3)::public.request, …)`, its own transaction: one round trip in place of `BEGIN`, `session_use`, the call and `COMMIT`; `inSession` goes. `request` is the session cookie's token (NULL without one), the host's first label, and the address (decision 3). Named arguments with the accessors' new names; `optional` only for parameters with a default in the accessor (filters, a known version). JSON with a fixed shape is taken apart into typed arguments (a location's `grid` into `p_columns`, `p_rows`, `p_confirm`). Uploads stay a transaction of their own (the file lock, the file, `attachment.create`).
3. **The host and the session are the accessor's to check; the address is believed from named proxies only** *(yours)*. Topic A3. `withTenant` goes: a route that needs a session gets 401 without one, at once; an unknown host is 404 from `util.session` or `account.login`; `/api/health`, `openapi.yaml` and the web app's static files are served for any host. The address is `r.RemoteAddr`'s, or, when the connection comes from one of `WTFD_TRUSTED_PROXIES` (addresses or networks, empty by default), the last entry of `X-Forwarded-For` that isn't a trusted proxy; logs use the same. `X-Forwarded-Proto` is left as it is: a forged one only makes the forger's cookie `Secure`.
4. **The JSON uses the database's names** *(yours)*. Topic B1, by principle 2: a stock row's `amount`, an assignment's `scope` (`"item"` or `"stock"`) and `assigned_to`, an attachment's `media_type`, the datatype `"decimal"`, history's `item_value` and `attachment` tables, its typed columns (`text`, `number`, … and `default_…`), and each entry's `action: {id, at, account}`. In answers and in requests (`scope` when assigning, `amount` for stock). `deleted` is topic B4.
5. **The unit lists are the tidy version clients keep** *(yours)*. Topic B2. A unit inside a family carries no `family` or `quantity`; a quantity's `base_unit` is the unit's id, found in the same list; `unit.get` and `unit.list` (units outside a family) keep `family: {id, name}` and the quantity. Unit and model files still name the base unit by its symbol. The accessors' `unit.json` and `unit.family_entries` follow; the apps' `lib/api/units.dart` and the CLI's `internal/cli/units.go` build their look-ups from the list once.
6. **`GET /unit-families` is revalidated by version, as the trees are** *(yours)*. Topic B3. Through the trees' handler, with a flag for whether to nest (only the trees are nested): `ETag` the tenant's `unit` version, `If-None-Match` passed in, `304` when unchanged; `?quantity=` stays, under the same version. The CLI keeps the families in its cache directory and revalidates them on every use, as it does the trees (`internal/cli/cache.go`), in place of a minute while completing.
7. **`deleted` says when and by whom** *(yours)*. Topic B4. `"deleted": null` for a live object, and for a deleted one `{action, at, account: {id, email}}`, the action that deleted it: the apps' and the CLI's "Deleted" says by whom and when, and the action's id is what a restore goes by. Lists show live objects, so only a get of a deleted object joins the action and its account (two primary-key look-ups); the accessors' JSON helpers take the action's row as they do the photo's.
8. **An attribute's options are listed in one place** *(yours)*. Topic B5. `GET /attributes/{id}/options` goes, and with it `attribute.option_list` (accessor function 27; the accessors are 83): `GET /attributes/{id}` gives a choice attribute's live options, and is what the app uses already; the CLI's `wtf model` (`internal/cli/cmd_model.go`) reads them from there too. Adding an option (`POST /attributes/{id}/options`) and `/options/{id}` stay.
9. **History pages go by `before`** *(yours)*. Topic C1. The `…/history` routes take `?before=<entry id>&limit=<n>` (no `before`: from the newest) and answer `{rows, more}`; an `offset` is refused with "History pages go by before, not offset". The CLI's `wtf history` shows one page and, when there are more, says how to see them (`--before <id>`).
10. **The tree handler nests the nodes** *(yours)*. Topic C2. In one pass with a map from id to node, children in the database's order; answers `{version, tree}` as today, so clients keep reading `children`. A node whose parent isn't in the list (a bug, as no live node has a deleted parent) is logged and put at the top. No flat form for clients (`?flat=`), as none wants one.
11. **The user's sessions under `/me/sessions`** *(yours)*. Topic C3. `GET /me/sessions` (most recently used first), `DELETE /me/sessions/{id}` (`204`; the current one's id logs out as `POST /logout` does, and clears the cookie), `POST /me/sessions/logout-others` (`{"ended": n}`). `max_idle` is seconds, or null for never, here and at login; `expires` a timestamp or null. The CLI: `wtf sessions`, `wtf sessions logout <id>`, `wtf sessions logout --others`.
12. **Logging in says the client and the lifetime** *(yours)*. Topic C4. `POST /login` takes `email`, `password`, `client` (required, may be null) and `max_idle` (seconds, or null for never; required); the answer is as today, and the log of a login has the client and the address of decision 3. The cookie's `Max-Age` is 400 days, the longest browsers keep one; the server decides validity. The app's login screen asks how long to stay logged in (until logging out, 30 days unused, 1 day unused, the last choice remembered) and sends its device's name; the CLI has `wtf login --stay <duration|forever>`, with a default in its configuration. No cap per tenant.
13. **A new password says whether sessions end** *(yours)*. Topic C5. `PUT /me/password` takes `{current, new, end_other_sessions}`, all required; `PATCH /accounts/{id}` takes `end_sessions` with `password` and only with it, and not for the admin's own account. The CLI asks (`wtf password`: "Log out your other devices too?"; an admin's `wtf account edit … --password`: the account's sessions), or takes `--log-out-others` / `--keep-others` and `--log-out` / `--keep-sessions`.
14. **A restore into something deleted has a problem type of its own** *(yours)*. Topic D1. `/problems/restore-into-deleted`, 409, with `place_key` (the option to restore elsewhere: `class`, `parent` or `location`) and `with_parents: true` as fields, where clients today match the hint's text for `with_parents`. `error.restore_into_deleted` raises its own SQLSTATE, `WT001` (outside PostgreSQL's classes), with `place_key` in the error's `DETAIL`, which `problem.go` reads into the field: the one exception to standard codes (accessor decision 20), as a client acts on it. Everything else of 55000 is `/problems/wrong-state`. The CLI's `intoDeleted` and the app's follow.
15. **`wtfd`'s own changes begin an action, one tenant at a time** *(yours)*. Topic E1. The purge of deleted objects (`internal/admin/deleted.go`) runs per tenant (looping over them without `--host`), each in its own transaction after `util.begin_action(<tenant>)`, an action without an account; its statements find the tenant through the joins of accessor decision 11. At the end it removes the tenant's actions that no deleted row and no history entry refers to. `wtfd tenant create` begins an action for the new tenant before its first account. History shows them as by wtfd (no account), as `account NULL` does today. `history (action)` gets an index (database plan).
16. **`wtfd gc` finds a file's tenant through its attachments' owners, and removes expired sessions** *(yours)*. Topic E2. Whether a tenant still has a file is one `EXISTS` on `attachment` by `hash`, joined to the four owners for their tenant (in place of four tables with `tenant`), served by an index on `attachment (hash)` (database plan); deleted attachments still count. The lock's key is `attachment.file_lock_key`. Expired sessions are removed in the same run, in one statement, and the result counts them.
17. **The API's description is at `/api/v1/openapi`, in JSON, also served as YAML** *(yours, in the review of the routes)*. Without an ending, like every other route; `Content-Type` says what it is. JSON is the master: `openapi/openapi.json`, converted once from today's `openapi.yaml` (its 3 comments dropped), and written by hand from then on. As JSON is valid YAML (YAML 1.2 is a superset of JSON), the same bytes are sent as `application/json` or, when `Accept` asks for it, `application/yaml`: no YAML library, no conversion in `wtfd`. ACCOUNTS.md's list of routes without a session follows, and the app's test that reads the file (`app/test/client_test.dart`) reads `openapi.json`.

## The routes

Reviewed by area (2026-11-01): each route calls one accessor, and changes as the decisions say and no further: the accessors' new names and argument names, `p_request` first (decision 2), the database's names (4), units by id (5), `deleted` as when and by whom (7), required fields required (principle 3). Apart from those: `GET /attributes/{id}/options` goes (8); `/me/sessions` is new (11); history goes by `before` (9); `/api/v1/openapi` replaces `/api/v1/openapi.yaml` (17). Accepted as they are *(yours)*.

## Plan

Part 3 is written on the same branch as parts 1 and 2, after them, and the three go live together, with the database reset (database decision 6) and every client rebuilt (decision 1).

1. **`internal/serve/`:**
    - **Calling** (`call.go`): `p_request` built from the request in every call, one statement per request, `inSession` gone (decision 2); `optional` only for the accessors' defaults.
    - **The host, the session and the address** (`tenant.go`, `session.go`, `serve.go`): `withTenant` gone, 401 at once without a cookie, `WTFD_TRUSTED_PROXIES` and the address from `X-Forwarded-For` (decision 3); login with `client` and `max_idle`, the cookie's 400 days (decision 12).
    - **The routes** (`routes.go`): the new names, the new and removed routes, `grid` taken apart, history by `before`, the tree handler nesting (decision 10) and serving the unit families by version (decision 6).
    - **Problems** (`problem.go`): 55000 as `/problems/wrong-state`, `WT001` as `/problems/restore-into-deleted` with its fields (decision 14).
    - **The description:** `openapi/openapi.json`, converted once from `openapi.yaml` and rewritten for the new API, served at `/api/v1/openapi` (decision 17); `apiRevision` 1 (decision 1).
2. **`wtfd`'s own work** (`internal/admin/`, `internal/files/`): the purge per tenant with an action, removing actions nothing refers to (decision 15); `wtfd tenant create` with an action; `wtfd gc` finding a file's tenant through its owners, and removing expired sessions (decision 16).
3. **The CLI** (`internal/cli/`, `internal/client/`): the new names and JSON, units looked up in the families it keeps and revalidates (decisions 5, 6), history by `--before` (9), `wtf sessions` (11), `wtf login --stay` (12), the password choices (13), the restore problem's fields (14).
4. **Tests:** the API's integration tests (`internal/integration/`) rewritten for the new API; a test that every route is in `openapi.json` and every path in it is a route (principle 4); the parts' own tests (database plan step 4, accessor plan steps 3 and 4) kept.
5. **The documents:** `API.md` and `api/*.md` rewritten for the new API and its accessors; WTFD.md ("Versions", "Logins", the new setting), ACCOUNTS.md, TENANTS.md and SCHEMA.md where the decisions touch them.
6. **Then the apps** ([2026-10-31-changes-to-the-apps.md](2026-10-31-changes-to-the-apps.md)), against the new API.

## Log

- **2026-10-31:** document started.
- **2026-11-01:** the API surveyed; principles proposed; topics listed.
- **2026-11-01:** decision 1, `/api/v1` changed in place, revision 1 (A1).
- **2026-11-01:** principles confirmed; decisions 2 and 3 (A2, A3).
- **2026-11-01:** decisions 4 and 5 (B1, B2).
- **2026-11-01:** decision 6 (B3).
- **2026-11-01:** decision 7 (B4).
- **2026-11-01:** decision 8 (B5).
- **2026-11-01:** decision 9 (C1).
- **2026-11-01:** decision 10 (C2).
- **2026-11-01:** decision 11 (C3).
- **2026-11-01:** decision 12 (C4).
- **2026-11-01:** decision 13 (C5).
- **2026-11-01:** decision 14 (D1).
- **2026-11-01:** decision 15 (E1).
- **2026-11-01:** decision 16 (E2); the topics are decided.
- **2026-11-01:** decision 17, `/api/v1/openapi` in YAML or JSON.
- **2026-11-01:** decision 17 revised: JSON as the master, served as YAML too.
- **2026-11-01:** the routes reviewed and accepted; the plan written. All three parts are planned.
- **2026-11-01 (overnight):** steps 1 to 3 done (`wtfd serve`, `wtfd`'s own work, the CLI); the API's integration tests are skipped until step 4 rewrites them. Decided on my own along the way, by what the plan implies:
  - An upload checks the session (`account.me`) before the file is staged, so that a request without a valid session stores nothing.
  - Query flags (`force`, `dry_run`) that are absent mean false; `parent` in a query that is absent means none (top level).
  - `GET /unit-families` answers `{version, families}`, as the other versioned answers do; nested tree nodes keep their `parent`.
  - The CLI fills in the units of an answer from the families it keeps (one walk over the decoded value, by field type), in place of a lookup at each place a unit is shown.
  - The CLI's sessions are `wtf sessions list` and `wtf sessions logout <id>` / `--others`: the CLI's groups have no default command, so the plan's bare `wtf sessions` is `wtf sessions list`.
  - `wtf login --stay` takes `forever`, a Go duration (`12h`) or days (`30d`); the configuration keeps the last one given, the default for the next login; without one it is `forever`. The client name is `wtf on <host name>`.
  - The CLI's `wtf class assign` keeps its `--per-unit` flag, sent as `scope: "stock"`; the stock commands' `--quantity` and their prompts and headings say "amount", by principle 2.
  - The CLI always sends every field creating requires (`unit` and `unit_lock`, `values`, `amount`, `parent`, `container`, `grid`, `password`, `role`, with null or the old default where none is given); `wtf account add` without `--role` is still a viewer.
  - An admin's `wtf account edit --password` or `--no-password` takes `--log-out` / `--keep-sessions`, or asks; the edit form asks too. Removing a password also says whether the sessions end, as `account.patch` wants `end_sessions` with any change of password.
