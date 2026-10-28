# wtfd – design

`wtfd` is the WtF server: a single, self-contained Go binary. It is invoked with an *action* as its first argument:

```sh
wtfd <action> [flags]
```

| Action   | Purpose                                                              | Status   |
|----------|----------------------------------------------------------------------|----------|
| `schema` | Create or upgrade the database schema, and bring function grants up to date | implemented |
| `serve`  | Run the REST API                                                     | implemented |
| `gc`     | Remove attachment files that nothing references any more             | implemented |
| `account`| Create an account, or set a lost password (`create`, `password`)     | implemented |
| `history`| Delete old history entries (`purge`)                                 | implemented |
| `deleted`| Remove what was deleted long ago (`purge`)                           | implemented |

## Configuration

Every setting is a command-line flag. Each flag can also come from an environment variable; the flag wins when both are given. Passwords are only accepted from environment variables, because command-line arguments are visible to other users on the machine (`ps`).

| Flag                      | Environment variable          | Default     | Meaning                                       |
|---------------------------|-------------------------------|-------------|-----------------------------------------------|
| `--database-host`         | `WTFD_DATABASE_HOST`          | `localhost` | Host name, IP address, or Unix socket directory |
| `--database-port`         | `WTFD_DATABASE_PORT`          | `5432`      | Port                                          |
| `--database-name`         | `WTFD_DATABASE_NAME`          | `wtf`       | Database name                                 |
| `--database-sslmode`      | `WTFD_DATABASE_SSLMODE`       | `prefer`    | `disable`, `allow`, `prefer`, `require`, `verify-ca` or `verify-full`, as in libpq |
| `--dba-database-user`     | `WTFD_DBA_DATABASE_USER`      | `wtf_dba`   | Role that owns the schema; used by `schema`   |
| `--api-database-user`     | `WTFD_API_DATABASE_USER`      | `wtf_api`   | Role the REST API connects as; `schema` grants it `EXECUTE` |
| –                         | `WTFD_DBA_DATABASE_PASSWORD`  | none        | Password of the DBA role                      |
| –                         | `WTFD_API_DATABASE_PASSWORD`  | none        | Password of the API role (used by `serve`)    |

Flags specific to `schema`:

| Flag        | Environment variable | Default | Meaning                                                    |
|-------------|----------------------|---------|------------------------------------------------------------|
| `--dry-run` | –                    | off     | Report what would be done, change nothing                   |
| `--verbose` | –                    | off     | Log every migration, script and grant as it is applied      |

If a password variable is unset, the connection is attempted without a password. That works with `peer` or `trust` authentication.

Command-line parsing uses the standard library (`flag`) with a small action dispatcher. The only external dependency is the PostgreSQL driver, [pgx v5](https://github.com/jackc/pgx). Logging uses `log/slog` and goes to stderr.

### Exit codes

| Code | Meaning                                                         |
|------|-----------------------------------------------------------------|
| 0    | Success; with `--dry-run`: the database is up to date            |
| 1    | Only with `--dry-run`: changes are pending                      |
| 2    | Usage error (unknown action, bad flag)                          |
| 3    | Failure (connection, verification, or a migration failed)       |

## Repository layout

```text
go.mod                         module github.com/radiohyperactivity/wtf
cmd/wtfd/main.go               action dispatch, configuration
internal/config/               flags + environment variables
internal/schema/               the schema action (migration runner)
internal/serve/                the serve action (REST API)
internal/files/                attachment file store and the gc action
internal/admin/                the account, history and deleted actions
openapi/openapi.yaml           OpenAPI description, embedded and served at /api/v1/openapi.yaml
db/embed.go                    //go:embed migrations/*.sql repeatable/*.sql
db/migrations/0001_schema.sql  versioned migrations
db/migrations/0002_units.sql
db/repeatable/10_util.sql      repeatable scripts
db/repeatable/20_attribute.sql
db/repeatable/30_class.sql
db/repeatable/40_item.sql
db/repeatable/50_location.sql
db/repeatable/60_meta.sql
db/repeatable/70_code.sql
db/repeatable/80_attachment.sql
db/repeatable/90_account.sql
db/repeatable/95_history.sql
.gitattributes                 *.sql text eol=lf
README.md, SCHEMA.md, API.md, … documentation
```

`go:embed` can only embed files in or below the package's directory, so the SQL lives in a `db` package with an `embed.go`.

The SQL moves out of the Markdown files. `SCHEMA.md`, `API.md` and `seed/units.md` keep their explanations and link to the `.sql` files, so there is a single source of truth.

## Migrations

There are two kinds of SQL scripts.

### Versioned migrations (`db/migrations/`)

- **What:** everything that holds data or that data depends on: types, tables, indexes, constraints, the view, trigger functions and triggers, seed data.
- **Naming:** `NNNN_description.sql`. The number is the version. Versions start at 1 and have no gaps, so a missing or misnumbered file is detected.
- **Applied once:** each migration runs exactly once, in version order, each in its own transaction. DDL in PostgreSQL is transactional, so a failing migration leaves nothing half-done.
- **Immutable once applied:** its SHA-256 checksum is recorded, and a changed file is refused. A change to an applied migration goes into a new migration.
- **Initial setup:** `0001_schema.sql` (from `SCHEMA.md`) and `0002_units.sql` (from `seed/units.md`) create today's schema. A fresh database and an existing one are handled by the same mechanism.

### Repeatable scripts (`db/repeatable/`)

- **What:** the `util` helpers and the API functions. Nothing stores data in them, so they can be thrown away and recreated at any time.
- **Naming:** `NN_description.sql`, applied in file-name order (`util` first).
- **Rebuilt as a whole:** if any repeatable script was added, changed or removed, or if any migration was applied in this run, all repeatables are rebuilt in one transaction:
  1. `DROP SCHEMA util CASCADE`
  2. drop every `SECURITY DEFINER` function in `public` (the API functions)
  3. run all repeatable scripts in order
  4. record their checksums
  5. refresh the grants (below)

  Rebuilding everything means changed signatures, renames and removals need no special handling. It takes a fraction of a second for ~70 functions. API calls that are in flight see either the old or the new set of functions, never a mix.

### Checksums

Checksums are SHA-256 of the file content, with CRLF line endings normalised to LF. A Windows checkout with `core.autocrlf` then gives the same checksum as a Linux one. `.gitattributes` also forces LF for `*.sql`.

### Bookkeeping

`wtfd schema` creates its own schema on first run (`CREATE ... IF NOT EXISTS`):

```sql
CREATE SCHEMA IF NOT EXISTS wtfd;

CREATE TABLE IF NOT EXISTS wtfd.migration (
    version    integer     NOT NULL PRIMARY KEY,
    name       text        NOT NULL,
    checksum   bytea       NOT NULL,
    applied_at timestamptz NOT NULL DEFAULT now(),
    applied_by name        NOT NULL DEFAULT current_user
);

CREATE TABLE IF NOT EXISTS wtfd.repeatable (
    name       text        NOT NULL PRIMARY KEY,
    checksum   bytea       NOT NULL,
    applied_at timestamptz NOT NULL DEFAULT now(),
    applied_by name        NOT NULL DEFAULT current_user
);
```

`wtf_api` has no privileges on the `wtfd` schema.

## The `schema` action

1. **Connect** as `--dba-database-user`, with `application_name = 'wtfd schema'` (visible in `pg_stat_activity`).
2. **Check preconditions** and stop with a clear message if any fails:
   - the server is PostgreSQL 15 or newer;
   - the connected role owns the database, so every object it creates is owned by the right role;
   - the API role exists.
3. **Lock:** `pg_advisory_lock` with a fixed key. A second `wtfd schema` waits instead of running concurrently. The lock is released when the session ends, even if `wtfd` crashes.
4. **Bootstrap** the `wtfd` schema and tables if they don't exist.
5. **Verify** the database against the embedded scripts, and refuse to continue if:
   - an applied migration is missing from the binary, or has a different name or checksum (edited after it was applied);
   - the database has a higher version than the binary (an old binary against a newer database).
6. **Plan:** the pending migrations (versions above the highest applied one), whether the repeatables need a rebuild, and which grants are wrong. With `--dry-run`, report the plan and exit (0 = nothing to do, 1 = changes pending).
7. **Apply** the pending migrations, in order, one transaction each, recording each in `wtfd.migration`.
8. **Rebuild** the repeatables if needed (see above).
9. **Grants**, checked on every run, and corrected if needed:
   - `wtf_api` has `EXECUTE` on exactly the `SECURITY DEFINER` functions in `public`;
   - nobody else (`PUBLIC`) has `EXECUTE` on any function in `public` or `util`;
   - `ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC` is in place for the DBA role. A role may set this for itself, so step 4 of the README's setup wouldn't strictly be needed any more, but keeping it there does no harm.
10. **Report** a summary and exit 0.

Session settings during the run:

- **`lock_timeout = '30s'`:** a migration that needs a table lock while long API transactions hold it fails after 30 seconds, instead of waiting indefinitely and blocking every other query behind it.
- **`statement_timeout = 0`:** large migrations aren't cut off.

Example output:

```text
$ WTFD_DBA_DATABASE_PASSWORD=… wtfd schema
schema: database wtf at version 0, binary has version 2
schema: applied 0001_schema.sql
schema: applied 0002_units.sql
schema: rebuilt 5 repeatable scripts (73 functions)
schema: granted EXECUTE on 41 functions to wtf_api
schema: up to date at version 2
```

## The `serve` action

`wtfd serve` runs the REST API. It is a thin layer over the database functions described in [API.md](API.md):

- it maps each request to one function call;
- it passes the `jsonb` the function returns straight through;
- it maps PostgreSQL errors to HTTP status codes.

There are no Go structs per entity. It uses the standard library's `net/http` (method and path patterns) and a `pgxpool` connection pool as `wtf_api`.

### Deployment assumptions

- **Logins** (see "Logins" below). Every request except `/api/health`, `/api/v1/openapi.yaml` and `/api/v1/login` needs the session cookie. Without it, `wtfd` answers 401 before touching the database. See [ACCOUNTS.md](ACCOUNTS.md).
- **The proxy handles TLS.** `wtfd` speaks plain HTTP. HTTPS is recommended, but not required, and the web app needs it in practice: browsers keep a secure cookie, and later the camera, only over HTTPS (localhost excepted). Tell `wtfd` about HTTPS with `X-Forwarded-Proto: https`, so the session cookie is marked Secure.
- **No CORS.** The web app is served by `wtfd` itself (`--web-root`), on the API's own hostname, so it needs none, and `wtfd` sends no CORS headers. The native apps and the CLI don't need CORS.
- **Localhost by default.** `wtfd` listens on `127.0.0.1:8080`, so only a local proxy can reach it unless you change `--listen`.
- **Paths.** The API is under `/api/v1/` (see "Versions"), `/api/health` is outside the versions, and everything outside `/api` is the web app.

### Flags

In addition to the database flags in [Configuration](#configuration):

| Flag                               | Environment variable                 | Default          | Meaning |
|------------------------------------|--------------------------------------|------------------|---------|
| `--listen`                         | `WTFD_LISTEN`                        | `127.0.0.1:8080` | Address and port to listen on |
| `--api-database-max-connections`   | `WTFD_API_DATABASE_MAX_CONNECTIONS`  | `10`             | Size of the connection pool. Keep it below the role's `CONNECTION LIMIT` (50 in the README). |
| `--max-request-body-size`          | `WTFD_MAX_REQUEST_BODY_SIZE`         | `1048576`        | Largest accepted request body, in bytes (1 MiB). Larger bodies get 413. |
| `--files-directory`                | `WTFD_FILES_DIRECTORY`               | (required)       | Where attachment contents are stored (see [api/attachment.md](api/attachment.md)). |
| `--max-attachment-size`            | `WTFD_MAX_ATTACHMENT_SIZE`           | `104857600`      | Largest accepted attachment, in bytes (100 MiB). Uploads and downloads get 15 minutes instead of the normal timeouts. |
| `--web-root`                       | `WTFD_WEB_ROOT`                      | (none)           | Directory of the web app, a Flutter web build; served outside `/api` (see "The web app"). It must contain `index.html`. |
| `--verbose`                        | –                                    | off              | Debug logging |

The password comes from `WTFD_API_DATABASE_PASSWORD`.

### Startup

1. Connect the pool as `--api-database-user`.
2. **Schema check:** call `schema_version()` (below) and compare the database's migration version and repeatable-script checksums with the scripts embedded in the binary. On any difference, exit with code 3 and the message "run `wtfd schema`". `serve` never changes the schema itself.
3. Start listening. On SIGTERM or Ctrl-C, stop accepting connections, let in-flight requests finish (up to 30 s), then close the pool.

`schema_version()` is a new API function in a new repeatable script, `db/repeatable/60_meta.sql`. It is `SECURITY DEFINER`, so `wtf_api` can read the bookkeeping through it without any access to the `wtfd` schema:

```json
{ "version": 2, "repeatables": { "10_util.sql": "<sha256 hex>", "20_attribute.sql": "…" } }
```

### Requests and responses

- **Bodies** are JSON objects with the field names shown below. Unknown fields are rejected (400), just like in PATCH. Bodies larger than `--max-request-body-size` are rejected with 413.
- **IDs in the path** must be UUIDs; anything else is a 400.
- **Success responses** are `application/json`, the function's result unchanged:

  | Method | Status |
  |--------|--------|
  | `GET`, `PATCH`, `PUT` | 200 |
  | `POST` (create) | 201 Created, with a `Location` header pointing at the new object |
  | `POST /stock/{id}/move` | 200 |
  | `POST /{…}/{id}/restore` | 200 with the restored object |
  | `DELETE` of an object | 204 No Content |
  | `DELETE` of a class attribute or value | 200 with the updated class or item |

- **Trees:** `GET /classes` and `GET /locations` send the tree version as a strong `ETag` (`"17"`). A request with `If-None-Match: "17"` gets `304 Not Modified` when nothing has changed. Responses carry `Cache-Control: no-cache`, so clients always revalidate.
- **Paged lists:** `GET /items` and `GET /stock` take `limit` and `offset` as query parameters and return the paging envelope from [API.md](API.md).

### Errors (RFC 9457)

Errors are `application/problem+json`:

```json
{
  "type": "/problems/unique-violation",
  "title": "Duplicate",
  "status": 409,
  "detail": "duplicate key value violates unique constraint \"class_sibling_name_unique\"",
  "sqlstate": "23505"
}
```

When the database knows what to do about an error, a `hint` says so (revision 2), e.g. how to restore something that is in a deleted location.

| Condition | `type` | Status |
|-----------|--------|--------|
| missing session cookie, `28000` (no or expired session), wrong login | `/problems/unauthenticated` | 401 (with `WWW-Authenticate: Cookie realm="WtF", cookie-name="wtf_session"`; an ended session's cookie is deleted) |
| a changing request whose `Origin` is another site | `/problems/cross-site` | 403 |
| an API version this server doesn't serve (`/api/v2/…`) | `/problems/unsupported-api-version` | 404, with `supported: [1]` |
| `42501` missing privilege | `/problems/forbidden` | 403 |
| too many failed logins | `/problems/too-many-attempts` | 429 (with `Retry-After: 60`) |
| `P0002` not found, or unknown route | `/problems/not-found` | 404 |
| `22023` invalid parameter, malformed JSON or body, bad UUID or query parameter | `/problems/invalid-input` | 400 |
| `22P02`, `22003`, `22008` (bad text, out of range, bad date) | `/problems/invalid-input` | 400 |
| `23502` a required field is null | `/problems/invalid-input` | 400 |
| `23514` integrity rule (check constraint or trigger) | `/problems/rule-violation` | 422 |
| `23505` duplicate | `/problems/unique-violation` | 409 |
| `23001` / `23503` on `DELETE`: still in use | `/problems/in-use` | 409 |
| `23001` / `23503` otherwise: a referenced object doesn't exist | `/problems/invalid-reference` | 422 |
| `55000` the object, or one it needs, is deleted; or restoring something that isn't | `/problems/deleted` | 409 |
| `57014` statement timeout | `/problems/timeout` | 503 |
| method not allowed on a route | `/problems/method-not-allowed` | 405 |
| request body too large | `/problems/body-too-large` | 413 |
| anything else | `/problems/internal` | 500 (details only in the log) |

### Versions

- **Paths:** the API is served under `/api/v1/`. The routes below are relative to it (`GET /items` is `GET /api/v1/items`), except `GET /api/health`.
- **Within a version the API only grows:** new routes, new optional fields, and new fields in answers. Nothing is renamed, removed or changes meaning, and clients ignore fields they don't know. Every addition increases the **revision**, which every answer of `/api/v1` carries as `API-Revision`, now 2. Revision 2 added marking deleted instead of removing (`deleted` in every object, the `restore` routes, the `hint` in problems; see [api/deleting.md](api/deleting.md)). It also changed what a delete means: a deleted object can still be fetched, where it used to answer 404. That exception was made while every client was still in development. A client knows the revision it was built for, and warns when a server's is older.
- **A breaking change becomes a new version,** `/api/v2/`, served next to `/api/v1/` for a while. Its revisions start again at 1. A version on its way out gets the standard `Deprecation` and `Sunset` headers on its answers (`apiSunset` in `internal/serve/api.go`).
- **Versions this server doesn't serve:** any request to them gets `/problems/unsupported-api-version`, with the list of versions it does serve (`supported`). The client can then say which side to update. A 404 without `API-Revision` at all comes from a server older than the versioned API.

### Logins

The session travels in a cookie, for every client: browsers keep it themselves, while the CLI and the apps store it and send it back.

- **`POST /api/v1/login`** sets the cookie `wtf_session`:
  - `HttpOnly`: scripts on a page can't read it;
  - `SameSite=Strict`: browsers don't send it with requests that come from other sites;
  - `Path=/api` and `Max-Age` 30 days;
  - `Secure` when the request came over HTTPS (TLS, or `X-Forwarded-Proto: https` from the proxy).

  The token is only in the cookie, never in the body.
- **Every authenticated answer renews the cookie,** because the session lasts 30 days from its last use. `POST /api/v1/logout` deletes it, and so does a 401 for an ended session.
- **Cross-site requests are refused:** a request that changes something (not GET or HEAD) is refused with 403 when its `Origin` header names another site. Together with `SameSite=Strict`, this prevents cross-site request forgery. Clients that send no `Origin` (the CLI, the apps) pass.
- **There is no `Authorization: Bearer` any more.**

### The web app

With `--web-root DIR`, `wtfd` serves the web app (a Flutter web build) outside `/api`:

- **Files** are served as they are, with `Cache-Control: no-cache`: a new build is picked up at once, and unchanged files cost a 304. That includes Flutter's `version.json`, which the app compares with its own version to reload itself after an update.
- **The app's own URLs** (`/locations/1A7K`) get `index.html` when they aren't a file, so links, bookmarks and reloads work. A missing file name with an extension (`/missing.js`) is a 404.
- **Not served:** hidden files (names starting with `.`) and directory listings.
- **Security headers:** a Content Security Policy that allows only this server (plus WebAssembly, which Flutter needs) and no framing by other sites (`frame-ancestors 'none'`, against clickjacking), plus `X-Content-Type-Options: nosniff` and `Referrer-Policy: same-origin`.
- **Building the app:** because of that policy, Flutter must not load its engine and fonts from Google's CDN. Build with `flutter build web --no-web-resources-cdn`, and bundle the fonts.

### Routes

| Method & path | Function | Body / query |
|---------------|----------|--------------|
| `GET /api/health` | `SELECT 1` | – (200, or 503 if the database is unreachable) |
| `GET /openapi.yaml` | – | – (the embedded OpenAPI description) |
| `GET /quantities` | `quantity_list()` | |
| `GET /quantities/{id}` | `quantity_get` | |
| `GET /unit-families` | `unit_family_list` | `?quantity=` |
| `GET /unit-families/{id}` | `unit_family_get` | |
| `GET /units` | `unit_list` | `?quantity=&family=` |
| `GET /units/{id}` | `unit_get` | |
| `POST /units/import` | `unit_import` | a unit file ([seed/units-format.md](seed/units-format.md)); `?dry_run=true` |
| `GET /attributes` | `attribute_list()` | |
| `POST /attributes` | `attribute_create` | `{name, datatype, unit?, unit_lock?}` |
| `GET /attributes/{id}` | `attribute_get` | |
| `PATCH /attributes/{id}` | `attribute_patch` | patch object |
| `DELETE /attributes/{id}` | `attribute_delete` | |
| `POST /attributes/{id}/restore` | `attribute_restore` | `{name?}` |
| `GET /attributes/{id}/options` | `attribute_option_list` | |
| `POST /attributes/{id}/options` | `attribute_option_create` | `{name}` |
| `GET /options/{id}` | `attribute_option_get` | |
| `PATCH /options/{id}` | `attribute_option_patch` | patch object |
| `DELETE /options/{id}` | `attribute_option_delete` | |
| `POST /options/{id}/restore` | `attribute_option_restore` | `{name?}` |
| `GET /classes` | `class_list` | `If-None-Match` |
| `POST /classes` | `class_create` | `{name, parent?}` |
| `GET /classes/{id}` | `class_get` | |
| `PATCH /classes/{id}` | `class_patch` | patch object |
| `DELETE /classes/{id}` | `class_delete`, or with `?recursive=true` `class_delete_tree` | `force`; recursive answers 200 with what was deleted |
| `GET /classes/{id}/deletion` | `class_delete_tree` with `p_dry_run` | `force`; what a recursive delete would delete |
| `POST /classes/{id}/restore` | `class_restore` | `{name?, parent?, with_parents?}` |
| `PUT /classes/{id}/attributes/{attribute}` | `class_attribute_set` | `{default?, per_unit?, required?}` |
| `DELETE /classes/{id}/attributes/{attribute}` | `class_attribute_remove` | |
| `GET /items` | `item_list` | `?class=&search=&where=&limit=&offset=` (`where`: JSON, see [api/item.md](api/item.md)) |
| `POST /items` | `item_create` | `{class, name, unit?, unit_lock?, values?}` |
| `GET /items/{id}` | `item_get` | |
| `PATCH /items/{id}` | `item_patch` | patch object |
| `DELETE /items/{id}` | `item_delete` | |
| `POST /items/{id}/restore` | `item_restore` | `{name?, class?, with_parents?}` |
| `PUT /items/{id}/values/{attribute}` | `value_set` | `{value}` |
| `DELETE /items/{id}/values/{attribute}` | `value_delete` | |
| `GET /locations` | `location_list` | `If-None-Match` |
| `POST /locations` | `location_create` | `{name, parent?}` |
| `GET /locations/{id}` | `location_get` | |
| `PATCH /locations/{id}` | `location_patch` | patch object |
| `DELETE /locations/{id}` | `location_delete`, or with `?recursive=true` `location_delete_tree` | `force`; recursive answers 200 with what was deleted |
| `GET /locations/{id}/deletion` | `location_delete_tree` with `p_dry_run` | `force`; what a recursive delete would delete |
| `POST /locations/{id}/restore` | `location_restore` | `{name?, parent?, with_parents?}` |
| `GET /stock` | `stock_list` | `?item=&location=&limit=&offset=` |
| `POST /stock` | `stock_create` | `{item, location, quantity?, values?}` |
| `GET /stock/{id}` | `stock_get` | |
| `PATCH /stock/{id}` | `stock_patch` | patch object |
| `DELETE /stock/{id}` | `stock_delete` | |
| `POST /stock/{id}/restore` | `stock_restore` | `{location?, with_parents?}` |
| `PUT /stock/{id}/values/{attribute}` | `stock_value_set` | `{value}` |
| `DELETE /stock/{id}/values/{attribute}` | `stock_value_delete` | |
| `POST /stock/{id}/move` | `stock_move` | `{location, quantity?}` |
| `GET /codes/{code}` | `code_resolve` | – (code: Crockford Base32; case and hyphens ignored) |
| `POST /items/{id}/attachments` (also `/stock/…`, `/locations/…`, `/classes/…`) | `attachment_lock`, `attachment_create` | multipart: `file`, `title?`, `photo?` |
| `GET /items/{id}/attachments/{attachment}` (also `/stock/…`, `/locations/…`, `/classes/…`) | `attachment_get` | |
| `PATCH …/attachments/{attachment}` | `attachment_patch` | `{title}` |
| `DELETE …/attachments/{attachment}` | `attachment_delete` | |
| `GET …/attachments/{attachment}/content` | `attachment_get` + files directory | `If-None-Match`, `Range` |
| `POST /login` | `login` | `{email, password}`; no session needed; sets the session cookie |
| `POST /logout` | `logout` | |
| `GET /me` | `me` | |
| `PUT /me/password` | `password_change` | `{current, new}` |
| `GET /accounts` | `account_list` | |
| `POST /accounts` | `account_create` | `{email, password?, data_privilege?, model_privilege?, account_privilege?}` |
| `GET /accounts/{id}` | `account_get` | |
| `PATCH /accounts/{id}` | `account_patch` | patch object |
| `DELETE /accounts/{id}` | `account_delete` (marks the account deleted) | |
| `GET /{items\|stock\|locations\|classes\|attributes\|accounts}/{id}/history` | `*_history` | `?limit=&offset=` |

### OpenAPI

An `openapi.yaml` (OpenAPI 3.1) describes every route, body and response shape. It is written by hand, embedded in the binary, and served at `GET /api/v1/openapi.yaml`. It is served as YAML only, because converting it to JSON would need a YAML library. Keeping it in sync with the routes is a manual step; a test checks that every route in the router appears in the spec.

### Logging and timeouts

- **Access log:** one `slog` line per request, with method, path, status and duration. Request bodies are never logged.
- **Login log:** every login attempt gets a line of its own, with the email and the client's address (`remote`).
  - **Success:** `level=INFO msg=login`, with the account id.
  - **Failure:** `level=WARN msg="login failed"`, with `reason=invalid` (unknown email or wrong password) or `reason=locked` (lockout).
  - Passwords are never logged. Behind a reverse proxy, `remote` is the proxy's address.
- **HTTP server timeouts:** 10 s to read the request header, 30 s to read the whole request, 60 s to write the response, and 120 s for idle keep-alive connections.
- **Database:** each call is limited by the role's `statement_timeout` (30 s in the README).

## Tenants

One installation holds many inventories, called tenants ([TENANTS.md](TENANTS.md)). The first label of a request's hostname picks one: `wtfd` lower-cases the `Host` header, drops the port, and looks up the label before the first dot (`bob` for `Bob.wtf.example:8443`). A hostname that picks no tenant gets 404, for the API and the web app alike, except `GET /api/health`, which answers on any hostname. A session belongs to its tenant: its cookie at another tenant's hostname gets 401.

## The `tenant` action

The operator creates, lists and renames tenants as the DBA role:

```sh
wtfd tenant create --host bob --email anna@example.com
wtfd tenant list
wtfd tenant rename --host bob --new-host robert --files-directory /var/lib/wtf/files
```

`create` makes the tenant and its first account, with every privilege, and prints the account's generated password once. `host` is a DNS label that starts with a letter: `a`–`z`, `0`–`9` and `-`, at most 63 characters. `rename` changes the host and moves the tenant's directory in the files directory along with it. Deleting a tenant isn't built yet.

## The `account` action

The operator creates an account with every privilege in a tenant, and recovers a lost password, as the DBA role:

```sh
wtfd account create --host bob --email anna@example.com
wtfd account password --host bob --email anna@example.com
```

`create` makes an account with every privilege. `password` gives an existing account a new password, lifts a lockout and ends its sessions. Both print the generated password once; the account should change it after logging in (`PUT /me/password`). Further accounts are made through the API (`POST /accounts`). See [ACCOUNTS.md](ACCOUNTS.md).

## The `unit` action

Global units, which every tenant sees, are the operator's (TENANTS.md, decisions 14–17). Tenants import their own through the API.

```sh
wtfd unit import --global more-units.json [--dry-run]
wtfd unit standard --family "Imperial length" --available false
wtfd unit standard --quantity Temperature --available true
```

`import` adds what isn't there yet, as `POST /units/import` does, and prints the same report; a name some tenant already has for its own is a conflict. `standard` sets whether a global quantity or family is available to tenants that haven't chosen themselves.

## The `history` action

History is kept until the operator deletes old entries (see [api/history.md](api/history.md)):

```sh
wtfd history purge --older-than 730d
wtfd history purge --older-than 365d --host bob --dry-run
```

`--older-than` takes days (`730d`) or a Go duration (`36h`). Every tenant's history, or with `--host` one tenant's. `--dry-run` only counts the entries. It connects as the DBA role.

## The `deleted` action

Deleted objects stay in the database until the operator purges them (see [api/deleting.md](api/deleting.md)):

```sh
wtfd deleted purge --older-than 730d
wtfd deleted purge --older-than 365d --host bob --dry-run
```

It removes what was deleted longer ago than `--older-than` (days or a Go duration), with what belongs to it, in every tenant or with `--host` in one, and reports how many of each kind. An object something else still refers to stays until that is purged too. `--dry-run` runs the purge in a transaction and rolls it back. It connects as the DBA role. Run `wtfd gc` afterwards to remove the files of purged attachments.

## The `gc` action

`wtfd gc` removes attachment files that nothing references any more: their attachments were deleted, or their objects purged (`wtfd deleted purge`). An upload whose database insert failed leaves a file nothing knows about.

```sh
wtfd gc --files-directory /var/lib/wtf/files --dry-run   # report only
wtfd gc --files-directory /var/lib/wtf/files
```

It connects as the DBA role and goes through every tenant's directory (`<files directory>/<host>/`), removing two kinds of file:

- files whose hash no attachment of that tenant (of any kind of object) has: their attachments were deleted, or an upload's database insert failed;
- abandoned uploads in the tenant's `tmp` directory.

A directory that belongs to no tenant is reported and left alone.

Files younger than `--min-age` (env `WTFD_GC_MIN_AGE`, default `1h`) are never removed, so uploads in progress are safe. Each removal takes the file's advisory lock, the same one an upload holds while it puts the file in place and records it, and re-checks that nothing references the file. `--dry-run` reports what would be removed, and `--verbose` logs every removed file. Run it from cron or a systemd timer, e.g. nightly.

## Open questions

1. **Non-transactional migrations.** Some statements can't run inside a transaction, e.g. `CREATE INDEX CONCURRENTLY`. If one is ever needed, a marker comment at the top of a migration (`-- wtfd:no-transaction`) could run it outside one. Not part of the first version.
