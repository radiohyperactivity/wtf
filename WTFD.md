# wtfd – design

`wtfd` is the WtF server: a single, self-contained Go binary. It is invoked with an *action* as its first argument:

```sh
wtfd <action> [flags]
```

| Action   | Purpose                                                              | Status   |
|----------|----------------------------------------------------------------------|----------|
| `schema` | Create or upgrade the database schema, and bring function grants up to date | implemented |
| `serve`  | Run the REST API                                                     | implemented |
| `gc`     | Remove files that nothing references any more, and expired sessions | implemented |
| `account`| Create an account, or set a lost password (`create`, `password`)     | implemented |
| `database` | Make the database and its roles on a PostgreSQL server (`create`) | implemented |
| `install`  | Set WtF up on this machine: programs, data, database (Windows only) | implemented |
| `service`  | Run `wtfd serve` as a Windows service (`install`, `uninstall`)      | implemented |

## Configuration

Every setting is a command-line flag. Each flag can also come from an environment variable, and from the config file; a flag wins over its environment variable, which wins over the file, which wins over the built-in default. Passwords are only accepted from environment variables and PostgreSQL's password file, because command-line arguments are visible to other users on the machine (`ps`).

**The config file,** `wtfd.conf`, has a setting on each line, with the flags' names as keys, and `#` for comments:

```text
# wtfd's settings
database-host = 127.0.0.1
files-directory = C:\ProgramData\WtF\files
listen = 127.0.0.1:8080
```

- **Where:** `--config FILE` or `WTFD_CONFIG`; otherwise `%ProgramData%\WtF\wtfd.conf` on Windows (`wtfd install` writes it), `/etc/wtf/wtfd.conf` on Linux and `/Library/Application Support/WtF/wtfd.conf` on macOS. `--config=` reads none.
- **A file at the default place may be missing.** One named with `--config` or `WTFD_CONFIG` must be there. One that can't be read (ProgramData's is for administrators only) is reported, and the action goes on without it.
- **Keys** are the flags of the table below and of `serve` and `gc`; an action takes those that are its own flags and passes over the others, but a key that is no action's setting is an error, so a typo doesn't go unnoticed. An action's own switches (`--dry-run`, `--verbose`) aren't settings.
- **Passwords are never in it.** When the file is read and `PGPASSFILE` isn't set, the PostgreSQL password file beside it (`pgpass.conf`) is used.
- `wtfd database create` reads neither the file nor the environment: they describe a database that exists.

| Flag                      | Environment variable          | Default     | Meaning                                       |
|---------------------------|-------------------------------|-------------|-----------------------------------------------|
| `--database-host`         | `WTFD_DATABASE_HOST`          | `127.0.0.1` | Host name, IP address, or Unix socket directory |
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

If a password variable is unset, the connection is attempted without a password. The password then comes from PostgreSQL's password file (`PGPASSFILE`, `~/.pgpass`, `%APPDATA%\postgresql\pgpass.conf`), as for every PostgreSQL client, or isn't needed, with `peer` or `trust` authentication.

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
internal/files/                file store and the gc action
internal/admin/                the account and database actions
internal/webapp/               the web app built into wtfd (build tag webapp)
openapi/openapi.json           OpenAPI description, embedded and served at /api/v1/openapi
db/embed.go                    //go:embed migrations/*.sql repeatable/*.sql
db/migrations/0001_schema.sql  versioned migrations
db/repeatable/10_error.sql     repeatable scripts, one per function schema:
db/repeatable/11_util.sql        error, util, attachment, account, class,
db/repeatable/…                  location, stock, item, model, meta, code
.gitattributes                 *.sql text eol=lf
README.md, SCHEMA.md, API.md, … documentation
```

`go:embed` can only embed files in or below the package's directory, so the SQL lives in a `db` package with an `embed.go`.

The SQL is in the `.sql` files only. `SCHEMA.md` and `API.md` keep their explanations and link to the files, so there is a single source of truth.

## Migrations

There are two kinds of SQL scripts.

### Versioned migrations (`db/migrations/`)

- **What:** everything that holds data: types, domains, tables, indexes, constraints, and the meta row.
- **Naming:** `NNNN_description.sql`. The number is the version. Versions start at 1 and have no gaps, so a missing or misnumbered file is detected.
- **Applied once:** each migration runs exactly once, in version order, each in its own transaction. DDL in PostgreSQL is transactional, so a failing migration leaves nothing half-done.
- **Immutable once applied:** its SHA-256 checksum is recorded, and a changed file is refused. A change to an applied migration goes into a new migration.
- **Initial setup:** `0001_schema.sql` creates today's schema. A fresh database and an existing one are handled by the same mechanism.

### Repeatable scripts (`db/repeatable/`)

- **What:** every function: the helpers and the functions the API calls. There are no triggers. Each script makes one schema, named after what its functions belong to (`item`, `class`, …; `error` for the errors raised on purpose, `util` for what belongs to nothing in particular). These schemas hold only functions, so they can be thrown away and recreated at any time. Nothing that holds data may use one of their functions: a constraint that needs one calls it through a function in a migration.
- **Naming:** `NN_description.sql`, applied in file-name order (`error` and `util` first, as everything uses them; a SQL function's body must only name what already exists).
- **Rebuilt as a whole:** if any repeatable script was added, changed or removed, or if any migration was applied in this run, all repeatables are rebuilt in one transaction:
  1. check that dropping the function schemas would take nothing but functions, triggers and views: no table in them, and nothing outside them (a default, a constraint, an index) that uses one of their functions; otherwise refuse, naming what is in the way
  2. `DROP SCHEMA … CASCADE` for every function schema (every schema the DBA role owns but `public`, `extensions` and `wtfd`)
  3. run all repeatable scripts in order
  4. record their checksums
  5. refresh the grants (below), and log the API functions per schema, so a change in the list shows

  Rebuilding everything means changed signatures, renames and removals need no special handling. API calls that are in flight see either the old or the new set of functions, never a mix.

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
   - the server is PostgreSQL 18 or newer;
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
   - `wtf_api` has `USAGE` on every function schema, and `EXECUTE` on exactly the `SECURITY DEFINER` functions in them (the functions the API calls);
   - nobody else (`PUBLIC`) has `EXECUTE` on any of our functions;
   - `ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC` is in place for the DBA role. A role may set this for itself, so step 4 of the README's setup wouldn't strictly be needed any more, but keeping it there does no harm.
10. **Report** a summary and exit 0.

Session settings during the run:

- **`lock_timeout = '30s'`:** a migration that needs a table lock while long API transactions hold it fails after 30 seconds, instead of waiting indefinitely and blocking every other query behind it.
- **`statement_timeout = 0`:** large migrations aren't cut off.

Example output:

```text
$ WTFD_DBA_DATABASE_PASSWORD=… wtfd schema
schema: database wtf at version 0, binary has version 1
schema: applied 0001_schema.sql
schema: rebuilt 11 repeatable scripts (130 functions)
schema: granted EXECUTE on 50 functions to wtf_api
schema: up to date at version 1
```

## The `serve` action

`wtfd serve` runs the REST API. It is a thin layer over the database functions described in [API.md](API.md):

- it maps each request to one function call;
- it passes the `jsonb` the function returns straight through;
- it maps PostgreSQL errors to HTTP status codes.

There are no Go structs per entity. It uses the standard library's `net/http` (method and path patterns) and a `pgxpool` connection pool as `wtf_api`.

### Deployment assumptions

- **Logins** (see "Logins" below). Every request except `/api/health`, `/api/v1/openapi` and `/api/v1/login` needs the session cookie. Without it, `wtfd` answers 401 before touching the database. See [ACCOUNTS.md](ACCOUNTS.md).
- **The proxy handles TLS.** `wtfd` speaks plain HTTP. HTTPS is recommended, but not required, and the web app needs it in practice: browsers keep a secure cookie, and later the camera, only over HTTPS (localhost excepted). Tell `wtfd` about HTTPS with `X-Forwarded-Proto: https`, so the session cookie is marked Secure. The proxy must pass on the `Host` the browser used, which the check against other sites compares with `Origin`. [PROXY.md](PROXY.md) sets up nginx with Let's Encrypt.
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
| `--files-directory`                | `WTFD_FILES_DIRECTORY`               | (required)       | Where the files of photos and attachment attributes are stored (see [api/attachment.md](api/attachment.md)). |
| `--max-attachment-size`            | `WTFD_MAX_ATTACHMENT_SIZE`           | `104857600`      | Largest accepted file, in bytes (100 MiB). Uploads and downloads get 15 minutes instead of the normal timeouts. |
| `--web-root`                       | `WTFD_WEB_ROOT`                      | (none)           | Directory of the web app, a Flutter web build; served outside `/api` (see "The web app"). It must contain `index.html`. |
| `--trusted-proxies`                | `WTFD_TRUSTED_PROXIES`               | (none)           | The reverse proxies, as addresses or networks separated by commas (`127.0.0.1, 10.0.0.0/8`), whose `X-Forwarded-For` is believed for the client's address. Without it, the address is the connection's. |
| `--verbose`                        | –                                    | off              | Debug logging |

The password comes from `WTFD_API_DATABASE_PASSWORD`.

### Startup

1. Connect the pool as `--api-database-user`.
2. **Schema check:** call `meta.schema_version()` (below) and compare the database's migration version and repeatable-script checksums with the scripts embedded in the binary. On any difference, exit with code 3 and the message "run `wtfd schema`". `serve` never changes the schema itself.
3. Start listening. On SIGTERM or Ctrl-C, stop accepting connections, let in-flight requests finish (up to 30 s), then close the pool.

`meta.schema_version()`, in `db/repeatable/80_meta.sql`, is `SECURITY DEFINER`, so `wtf_api` can read the bookkeeping through it without any access to the `wtfd` schema ([api/meta.md](api/meta.md)):

```json
{ "version": 2, "repeatables": { "10_error.sql": "<sha256 hex>", "11_util.sql": "…" } }
```

### Requests and responses

- **One statement per request:** `wtfd` calls the route's function with the request (session token, client address) as its first argument, in the same statement ([API.md](API.md)). It holds no transaction open and sets nothing on the connection.
- **Bodies** are JSON objects with the field names shown below. Every field a create or a call takes is required (null where none is meant); unknown fields are rejected (400), just like in PATCH. Bodies larger than `--max-request-body-size` are rejected with 413.
- **IDs in the path** must be UUIDs; anything else is a 400.
- **Success responses** are `application/json`, the function's result unchanged:

  | Method | Status |
  |--------|--------|
  | `GET`, `PATCH`, `PUT` | 200 |
  | `POST` (create) | 201 Created, with a `Location` header pointing at the new object |
  | `POST /stock/{id}/move`, `POST /stock/{id}/merge` | 200 |
  | `DELETE` of an object | 204 No Content |
  | `DELETE` of a class attribute or choice | 200 with the change (`{class, items, stock, dry_run}`) |
  | `PUT` of a photo or a file | 200 with the item or stock row |

- **Versions:** `GET /classes` and `GET /locations` send their version as a strong `ETag` (`"17"`). A request with `If-None-Match: "17"` gets `304 Not Modified` when nothing has changed. Responses carry `Cache-Control: no-cache`, so clients always revalidate. They answer `{version, tree}`: the tree, which the database gives as a flat list and `wtfd` nests, each node with its `children`.
- **Paged lists:** `GET /items` and `GET /stock` take `limit` and `after` as query parameters and answer `{rows, more, next}` ([API.md](API.md)).
- **Names in the path:** an attribute or a choice in a path is its name, URL-encoded (`/classes/{id}/attributes/Supply%20voltage`).
- **Query flags** (`force`, `dry_run`, `recursive`) are `true` or `false`; absent is false.

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

When the database knows what to do about an error, a `hint` says so, e.g. what to delete first.

| Condition | `type` | Status |
|-----------|--------|--------|
| missing session cookie, `28000` (no or expired session), wrong login | `/problems/unauthenticated` | 401 (with `WWW-Authenticate: Cookie realm="WtF", cookie-name="wtf_session"`; an ended session's cookie is deleted) |
| a changing request whose `Origin` is another site | `/problems/cross-site` | 403 |
| an API version this server doesn't serve (`/api/v2/…`) | `/problems/unsupported-api-version` | 404, with `supported: [1]` |
| `42501` not allowed for the role | `/problems/forbidden` | 403 |
| too many failed logins | `/problems/too-many-attempts` | 429 (with `Retry-After: 60`) |
| `P0002` not found, or unknown route | `/problems/not-found` | 404 |
| `22023` invalid parameter, malformed JSON or body, bad UUID or query parameter | `/problems/invalid-input` | 400 |
| `22P02`, `22003`, `22008` (bad text, out of range, bad date) | `/problems/invalid-input` | 400 |
| `23502` a required field is null | `/problems/invalid-input` | 400 |
| `23514` integrity rule (a check constraint, or a rule an accessor checks) | `/problems/rule-violation` | 422 |
| `23505` duplicate | `/problems/unique-violation` | 409 |
| `23001` / `23503` on `DELETE`: still in use | `/problems/in-use` | 409 |
| `23001` / `23503` otherwise: a referenced object doesn't exist | `/problems/invalid-reference` | 422 |
| `55000` not possible in this state (an item moved just as it was written; trying again works) | `/problems/wrong-state` ("Not possible in this state") | 409 |
| `WT001` a label code whose item, stock row or location has been deleted | `/problems/gone` | 410 |
| `57014` statement timeout | `/problems/timeout` | 503 |
| method not allowed on a route | `/problems/method-not-allowed` | 405 |
| request body too large | `/problems/body-too-large` | 413 |
| anything else | `/problems/internal` | 500 (details only in the log) |

### Which build runs

`GET /api/health` says which build answers, and since when, besides that the database is reachable. It needs no login, like the rest of `/api/health`:

```json
{"status": "ok", "build": "2026-11-06T14:02:11Z", "commit": "2026-11-05T09:00:00Z",
 "revision": "a188ffbd98669db5ec5af31263844213c1f62c14", "started": "2026-11-06T15:30:00Z"}
```

- **`build`:** when `wtfd` was built. Go doesn't record that, so `scripts/build.sh` stamps it (`-ldflags -X …/internal/buildinfo.date=…`); a plain `go build` or `go install` has none, and says null.
- **`commit`** and **`revision`:** when the commit it was built from was made, and its ID, as Go records them when it builds in a git checkout (`vcs.time`, `vcs.revision`); null outside one.
- **`started`:** when this `wtfd serve` started.
- Times are RFC 3339 in UTC, to the second (`internal/buildinfo`, `healthAnswer` in `internal/serve`).

### Versions

- **Paths:** the API is served under `/api/v1/`. The routes below are relative to it (`GET /items` is `GET /api/v1/items`), except `GET /api/health`.
- **Within a version the API only grows:** new routes, new optional fields, and new fields in answers. Nothing is renamed, removed or changes meaning, and clients ignore fields they don't know. Every addition increases the **revision**, which every answer of `/api/v1` carries as `API-Revision`, now 1. A client knows the revision it was built for, and warns when a server's is older.
- **One exception, the refactor of November 2026:** `/api/v1` changed in place, with the database's names (`amount`, `scope`, `media_type`, `decimal`), units by id, and required fields required, then without "mark as deleted", restore and history, and with merging stock as its own route ([2026-11-01-dropping-deleted-and-history.md](2026-11-01-dropping-deleted-and-history.md)), and then with attributes in JSON, labels for units, files as attributes, paging by key, and no tenants ([2026-11-02-attributes-in-json.md](2026-11-02-attributes-in-json.md)); its revision started again at 1. Every client was rebuilt with it, while all of them were still in development, so a second version served beside the first would have had no one to serve. A client built before it misreads the answers rather than saying it is too old, which only happens to a copy not updated.
- **A breaking change becomes a new version,** `/api/v2/`, served next to `/api/v1/` for a while. Its revisions start again at 1. A version on its way out gets the standard `Deprecation` and `Sunset` headers on its answers (`apiSunset` in `internal/serve/api.go`).
- **Versions this server doesn't serve:** any request to them gets `/problems/unsupported-api-version`, with the list of versions it does serve (`supported`). The client can then say which side to update. A 404 without `API-Revision` at all comes from a server older than the versioned API.

### Logins

The session travels in a cookie, for every client: browsers keep it themselves, while the CLI and the apps store it and send it back.

- **`POST /api/v1/login`** takes `{email, password, client, max_idle}`: the client's name ("WtF on Pixel 9", or null) and how many seconds the session may sit unused before it expires (null: until logging out), both required. It sets the cookie `wtf_session`:
  - `HttpOnly`: scripts on a page can't read it;
  - `SameSite=Strict`: browsers don't send it with requests that come from other sites;
  - `Path=/api` and `Max-Age` 400 days, the longest browsers keep a cookie: the database decides whether the session is still valid;
  - `Secure` when the request came over HTTPS (TLS, or `X-Forwarded-Proto: https` from the proxy).

  The token is only in the cookie, never in the body.
- **Every authenticated answer renews the cookie.** `POST /api/v1/logout` deletes it, and so does a 401 for an ended session.
- **One's own sessions:** `GET /me/sessions` lists them (most recently used first, with the client, the addresses and when each expires), `DELETE /me/sessions/{id}` ends one (the current one logs out), `POST /me/sessions/logout-others` ends all but the current one and answers `{"ended": n}`.
- **A new password says whether the other sessions end:** `PUT /me/password` takes `{current, new, end_other_sessions}`; an admin's `PATCH /accounts/{id}` with `password` takes `end_sessions` with it.
- **The client's address** is the connection's, or behind a proxy named in `--trusted-proxies`, the last address in `X-Forwarded-For` that isn't a trusted proxy. It is kept in the session's trail and logged.
- **Cross-site requests are refused:** a request that changes something (not GET or HEAD) is refused with 403 when its `Origin` header names another site. Together with `SameSite=Strict`, this prevents cross-site request forgery. Clients that send no `Origin` (the CLI, the apps) pass.
- **There is no `Authorization: Bearer` any more.**

### The web app

`wtfd` serves the web app (a Flutter web build) outside `/api`: the one built into it, or the one in `--web-root DIR`, which wins when given.

- **Built in:** `scripts/build.sh` builds the web app once, copies it to `internal/webapp/dist` (not in git) and builds `wtfd` with the tag `webapp`, which embeds it (`internal/webapp`). The server and its web app are then always of the same version, and one file is all there is to install; it makes `wtfd` about 40 MB larger. A `wtfd` built without the tag, as by `go install`, has none, and `serve` logs which it serves, if any. `--web-root` is for development: a fresh `flutter build web` without building `wtfd` again.
- **Files** are served as they are, with `Cache-Control: no-cache`: a new build is picked up at once, and unchanged files cost a 304, by their modification time, or, for the built-in ones, which have none, by an ETag of their contents. That includes Flutter's `version.json`, which the app compares with its own version to reload itself after an update.
- **The app's own URLs** (`/locations/1A7K`) get `index.html` when they aren't a file, so links, bookmarks and reloads work. A missing file name with an extension (`/missing.js`) is a 404.
- **Not served:** hidden files (names starting with `.`) and directory listings.
- **Security headers:** a Content Security Policy that allows only this server (plus WebAssembly, which Flutter needs) and no framing by other sites (`frame-ancestors 'none'`, against clickjacking), plus `X-Content-Type-Options: nosniff` and `Referrer-Policy: same-origin`.
- **Building the app:** because of that policy, Flutter must not load its engine and fonts from Google's CDN. Build with `flutter build web --no-web-resources-cdn`, and bundle the fonts.

### Routes

Every route calls one function ([API.md](API.md) has them all); a body's fields are its arguments, all required (null where none is meant), unless the table says otherwise.

| Method & path | Function | Body / query |
|---------------|----------|--------------|
| `GET /api/health` | `SELECT 1` | – (200 with `{status, build, commit, revision, started}`, or 503 if the database is unreachable) |
| `GET /openapi` | – | – (the embedded OpenAPI description, JSON or YAML) |
| `POST /model/import` | `model.import` | a model file ([seed/model-format.md](seed/model-format.md)); `?parent=&dry_run=true` |
| `GET /classes` | `class.list` | `If-None-Match` |
| `POST /classes` | `class.create` | `{name, parent, container}` |
| `GET /classes/{id}` | `class.get` | |
| `PATCH /classes/{id}` | `class.patch` | patch object |
| `DELETE /classes/{id}` | `class.delete`, or with `?recursive=true` `class.delete_tree` | `force`; recursive answers 200 with what was deleted |
| `GET /classes/{id}/model` | `model.export` | the class with everything below it, as a model file |
| `GET /classes/{id}/deletion` | `class.delete_tree` with `p_dry_run` | `force`; what a recursive delete would delete |
| `POST /classes/{id}/attributes` | `class.attribute_add` | `{name, definition}`; `?dry_run=true` |
| `PATCH /classes/{id}/attributes/{attribute}` | `class.attribute_change` | patch object; `?dry_run=true` |
| `POST /classes/{id}/attributes/{attribute}/rename` | `class.attribute_rename` | `{name}`; `?dry_run=true` |
| `DELETE /classes/{id}/attributes/{attribute}` | `class.attribute_remove` | `?dry_run=true` |
| `POST /classes/{id}/attributes/{attribute}/choices` | `class.choice_add` | `{choice}`; `?dry_run=true` |
| `POST /classes/{id}/attributes/{attribute}/choices/{choice}/rename` | `class.choice_rename` | `{choice}`; `?dry_run=true` |
| `DELETE /classes/{id}/attributes/{attribute}/choices/{choice}` | `class.choice_remove` | `?dry_run=true` |
| `GET /items` | `item.list` | `?class=&search=&where=&limit=&after=` (`where`: JSON, see [api/item.md](api/item.md)) |
| `POST /items` | `item.create` | `{class, name, unit, values}` |
| `GET /items/{id}` | `item.get` | |
| `PATCH /items/{id}` | `item.patch` | patch object |
| `DELETE /items/{id}` | `item.delete` | |
| `GET /items/{id}/photo`, `GET /items/{id}/files/{attribute}` | `attachment.get` + files directory | `If-None-Match`, `Range` |
| `PUT /items/{id}/photo`, `PUT /items/{id}/files/{attribute}` | `attachment.lock`, `attachment.set` | multipart: `file` |
| `GET /locations` | `location.list` | `If-None-Match` |
| `POST /locations` | `location.create` | `{name, parent, container, grid}`, `grid` being `{columns, rows, confirm?}` or null |
| `GET /locations/{id}` | `location.get` | |
| `PATCH /locations/{id}` | `location.patch` | patch object |
| `DELETE /locations/{id}` | `location.delete`, or with `?recursive=true` `location.delete_tree` | `force`; recursive answers 200 with what was deleted |
| `GET /locations/{id}/deletion` | `location.delete_tree` with `p_dry_run` | `force`; what a recursive delete would delete |
| `GET /stock` | `stock.list` | `?item=&location=&search=&limit=&after=` |
| `POST /stock` | `stock.create` | `{item, location, amount, reference, serial, values}` |
| `GET /stock/{id}` | `stock.get` | |
| `PATCH /stock/{id}` | `stock.patch` | patch object |
| `DELETE /stock/{id}` | `stock.delete` | |
| `GET /stock/{id}/photo`, `GET /stock/{id}/files/{attribute}` | `attachment.get` + files directory | `If-None-Match`, `Range` |
| `PUT /stock/{id}/photo`, `PUT /stock/{id}/files/{attribute}` | `attachment.lock`, `attachment.set` | multipart: `file` |
| `POST /stock/{id}/move` | `stock.move` | `{location, amount}` (`amount` null: all of it); never merges |
| `POST /stock/{id}/merge` | `stock.merge` | `{into, amount, resolve}` (`amount` null: all of it, and the row is deleted; `resolve` says which row's to keep where they differ) |
| `GET /codes/{code}` | `code.resolve` | – (code: Crockford Base32; case and hyphens ignored); 410 for a deleted thing's code |
| `POST /login` | `account.login` | `{email, password, client, max_idle}`; no session needed; sets the session cookie |
| `POST /logout` | `account.logout` | |
| `GET /me` | `account.me` | |
| `PUT /me/password` | `account.password_change` | `{current, new, end_other_sessions}` |
| `GET /me/sessions` | `account.session_list` | |
| `DELETE /me/sessions/{id}` | `account.session_logout` | (the current session's id logs out, and clears the cookie) |
| `POST /me/sessions/logout-others` | `account.session_logout_others` | answers `{"ended": n}` |
| `GET /accounts` | `account.list` | |
| `POST /accounts` | `account.create` | `{email, password, role}` |
| `GET /accounts/{id}` | `account.get` | |
| `PATCH /accounts/{id}` | `account.patch` | patch object; `end_sessions` with `password` |
| `DELETE /accounts/{id}` | `account.delete` (with its sessions) | |

### OpenAPI

`openapi/openapi.json` (OpenAPI 3.1) describes every route, body and response shape. It is written by hand, embedded in the binary, and served at `GET /api/v1/openapi`: as JSON, or with the same bytes as `application/yaml` when the client asks for YAML (JSON is valid YAML). Keeping it in sync with the routes is a manual step; a test checks that every route in the router appears in the spec, and the other way round.

### Logging and timeouts

- **Access log:** one `slog` line per request, with method, path, status and duration. Request bodies are never logged.
- **Login log:** every login attempt gets a line of its own, with the email, the client's name (`client`) and its address (`address`).
  - **Success:** `level=INFO msg=login`, with the account id.
  - **Failure:** `level=WARN msg="login failed"`, with `reason=invalid` (unknown email or wrong password) or `reason=locked` (lockout).
  - Passwords are never logged. Behind a reverse proxy not named in `--trusted-proxies`, `address` is the proxy's.
- **HTTP server timeouts:** 10 s to read the request header, 30 s to read the whole request, 60 s to write the response, and 120 s for idle keep-alive connections.
- **Database:** each call is limited by the role's `statement_timeout` (30 s in the README).

## The `account` action

The operator creates the first account, and recovers a lost password, as the DBA role:

```sh
wtfd account create --email anna@example.com [--role viewer|user|admin]
wtfd account password --email anna@example.com
```

`create` makes an account, an admin unless `--role` says viewer or user. `password` gives an existing account a new password, lifts a lockout and ends its sessions. Both print the generated password once; the account should change it after logging in (`PUT /me/password`). Further accounts are made through the API (`POST /accounts`). See [ACCOUNTS.md](ACCOUNTS.md).

## The `database` action

`wtfd database create` makes WtF's database on a PostgreSQL server that has none: the roles, the database, its privileges and the roles' settings (README.md, steps 2–4), then the schema, as `wtfd schema` does (step 6), and optionally the first account (step 8).

```sh
wtfd database create                                  # asks, on a terminal
wtfd database create --database-host db.example.lan --first-account anna@example.com
wtfd database create --print-sql                      # the same as a psql script; does nothing
```

It has the database flags above, for the new database and roles, but **reads none of the environment variables**: they describe a database that exists, and taking their values as defaults would aim it at that one. Its defaults are the built-in ones. Flags of its own:

| Flag                     | Default    | Meaning |
|--------------------------|------------|---------|
| `--admin-user`           | `postgres` | The administrator it connects as: a superuser, or a role with `CREATEROLE` and `CREATEDB` |
| `--admin-database`       | `postgres` | The database the administrator connects to |
| `--icu-locale`           | `und`      | The new database's collation, an ICU locale; `und` sorts language-neutral |
| `--api-connection-limit` | `50`       | The API role's `CONNECTION LIMIT` |
| `--first-account`        | none       | Email of an admin account to create at the end |
| `--print-sql`            | off        | Print the steps as a psql script for a superuser, and do nothing |

- **On a terminal it asks** for the server, the administrator, the names, the roles' passwords and the first account, each with the flag's value as its default; a flag given on the command line isn't asked for. Without a terminal it asks nothing and takes the flags.
- **Passwords:** the administrator's comes from PostgreSQL's password file, else it is asked for. The roles' are asked for on a terminal; an empty answer, or no terminal, generates them. Before creating anything it says which were typed in and which generated; generated ones are printed once at the end, as lines for the password file. A role's password is sent as a SCRAM-SHA-256 hash made by `wtfd` (as psql's `\password` does), so the server's log never sees it; for that it must be printable ASCII, at least 8 characters.
- **It checks first,** changing nothing: PostgreSQL 18 or newer, built with ICU; an administrator that may create roles and databases; no database or role of the new names.
- **A failure while making the roles and the database removes them again** (`DROP DATABASE … WITH (FORCE)`, `DROP ROLE`), and says so. After that, the database stays: when the schema or the API role's test connection fails, typically for want of a `pg_hba.conf` line, it says what to add and to run `wtfd schema` once that works.
- **An administrator that isn't a superuser** (as on managed PostgreSQL services) makes itself a member of the DBA role while it works (`WITH INHERIT FALSE, SET TRUE`), since only a member may make a role a database's owner, and leaves it again at the end.
- **The test connections run from where `wtfd` runs.** When `wtfd serve` will run on another machine, `pg_hba.conf` must let that one in too.

## The `install` action

`wtfd install` sets WtF up on a Windows machine (README.md, "Installing on Windows"). It must run as an administrator, and refuses otherwise, saying how. On other systems it isn't there yet.

1. **The programs:** run from the installed copy (`Program Files\WtF\bin\wtfd.exe`), it says there is nothing new to install, and how to upgrade, and goes on with the rest. Otherwise it stops the `wtfd` service if it runs, and copies `wtfd.exe`, and `wtf.exe` from the same folder, to `Program Files\WtF\bin`. A program in the way is renamed (`wtfd.exe.old-…`), as Windows lets a running program be renamed but not overwritten; the next run removes those. It adds the folder to the machine's PATH, and tells running programs so.
2. **The data:** it makes `ProgramData\WtF` and the files directory (`--files-directory`, default `ProgramData\WtF\files`), open to Administrators and SYSTEM only, in place of ProgramData's permissions, which let every user create files. The service's own access is for setting up the service.
3. **The database.** When `wtfd.conf` has its settings already (host, port, database and both roles), it takes them without asking, says which, and goes on as for one that is there, below; this works without a terminal too, as long as `pgpass.conf` has the passwords. Otherwise, on a terminal only, it asks whether it is there already, and its default is yes when `pgpass.conf` is there.
   - **There:** it asks for the server, the database and both roles, connects as each, asking for a password only when `pgpass.conf` hasn't the right one, and brings the schema up to date, as `wtfd schema` does.
   - **Not there:** it makes it, as `wtfd database create` does, with the same flags.
4. **`ProgramData\WtF\pgpass.conf`** gets the passwords typed in or generated, both roles'. A line for the same server, database and role replaces the old one; other lines stay.
5. **`ProgramData\WtF\wtfd.conf`,** the config file, gets what it knows: the database's server, name and roles, the files directory, and the address `serve` listens on, which it asks for (`--listen`; `127.0.0.1:8080`, this machine only, unless told otherwise). Keys it doesn't write, and comments, stay. On the next run, what the file has isn't asked for again, and the environment is ignored; `--reconfigure` asks for everything, with the file's values as the defaults, and a flag on the command line sets one value without asking.
6. **It starts the service again** if it stopped it; when a step fails, the service stays stopped, and it says so.

Both Program Files and ProgramData are asked of Windows (known folders), not assumed to be on `C:`.

At the end, when there is no `wtfd` service yet, it offers to set one up, as `wtfd service install` does.

## The `service` action

`wtfd service install` runs `wtfd serve` as a Windows service, after `wtfd install`; `wtfd service uninstall` takes it away again. Both must run as an administrator. On other systems the action isn't there yet.

`install`:

1. **Checks** that `Program Files\WtF\bin\wtfd.exe` and `ProgramData\WtF\wtfd.conf` are there; the service always runs the installed program.
2. **Registers the Event Log source** `wtfd` (with `EventCreate.exe` as its message file), so Event Viewer shows the entries as they are.
3. **Creates the service,** or brings an existing one up to date, stopping it first: `wtfd`, "WtF server", running `"…\wtfd.exe" serve`; automatic, delayed start; as the virtual account `NT SERVICE\wtfd` (unrestricted service SID); restarted 5 s, 5 s and 60 s after a failure, counted afresh after a day, also when it stops with an error of its own (recovery actions on non-crash failures).
4. **Gives the account its access,** in place of any it had: traverse (no listing) on `ProgramData\WtF`, read on `wtfd.conf` and `pgpass.conf`, and modify on the files directory and all in it. A DACL protected from inheritance (ProgramData\WtF's, a files directory elsewhere) stays protected.
5. **The firewall:** when `listen` isn't a loopback address, it asks whether to add the inbound rule "WtF server" (TCP, that port, for `wtfd.exe`), replacing one from an earlier run; without a terminal, it prints the `netsh` command.
6. **Starts the service,** waits until it runs, and asks `http://<listen>/api/health` (127.0.0.1 for a listen on all addresses) for up to 20 seconds. When that fails, it shows wtfd's last five Event Log entries.

`uninstall` asks first, then stops the service, takes the account's access away (while the account still exists to be named), removes the service, the firewall rule and the Event Log source, and leaves the programs, the settings, the data and the log's entries.

**The passwords:** for now, the service can read all of `pgpass.conf`, the DBA's password too. Whether `serve` should have only the API role's, and how `wtfd gc` is run on a schedule, is still open.

## The `gc` action

`wtfd gc` removes files that nothing references any more: the items or stock rows they were on were deleted or given another file, or an upload's database change failed and left a file nothing knows about. It also removes the sessions that have expired (unused for longer than their `max_idle`), in one statement, and reports how many.

```sh
wtfd gc --files-directory /var/lib/wtf/files --dry-run   # report only
wtfd gc --files-directory /var/lib/wtf/files
```

It connects as the DBA role, reads the hashes in use once (the photos of items and stock rows, and the values of their attachment attributes), and removes two kinds of file:

- files whose hash nothing has;
- abandoned uploads in the `tmp` directory.

Files younger than `--min-age` (env `WTFD_GC_MIN_AGE`, default `1h`) are never removed, so uploads in progress are safe. Each removal takes the file's advisory lock (`attachment.file_lock_key`), the same one an upload holds while it puts the file in place and records it, and checks again that nothing references the file. `--dry-run` reports what would be removed, and `--verbose` logs every removed file. Run it from cron or a systemd timer, e.g. nightly.

## Open questions

1. **Non-transactional migrations.** Some statements can't run inside a transaction, e.g. `CREATE INDEX CONCURRENTLY`. If one is ever needed, a marker comment at the top of a migration (`-- wtfd:no-transaction`) could run it outside one. Not part of the first version.
