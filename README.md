# WtF – Where the Fuck

Keeping your shit organised: a database of the things you own (from tiny electronic components to tools, cars and boats) and where they are.

| Document                     | Contents                                                     |
|------------------------------|--------------------------------------------------------------|
| [SCHEMA.md](SCHEMA.md)       | Tables, types, integrity rules and triggers                   |
| [SCHEMA.html](SCHEMA.html)   | Entity-relationship diagram                                   |
| [seed/units.md](seed/units.md) | The global units: quantities, unit families and units       |
| [seed/model-format.md](seed/model-format.md) | Model files: units, attributes and classes for one use, such as [MCUs](seed/models/mcu.json); importing and exporting |
| [API.md](API.md)             | The PL/pgSQL functions all data access goes through           |
| [CLI.md](CLI.md)             | `wtf`, the command-line client                                |
| [TODO.md](TODO.md)           | Things to come back to later                                  |

## Database setup

The examples use these names:

| Name      | What                                                                                 |
|-----------|--------------------------------------------------------------------------------------|
| `wtf`     | The database.                                                                        |
| `wtf_dba` | Owner of the database and every object in it. Used for DDL, upgrades and maintenance. |
| `wtf_api` | Used by the REST API server. May only execute the API functions.                     |

### 1. Install PostgreSQL

Follow the installation instructions for your platform at <https://www.postgresql.org/download/>. WtF needs **PostgreSQL 15 or newer**, so use the newest release available.

The rest of this section assumes an interactive `psql` session as a superuser (usually `postgres`), connected to the `template1` database:

```sh
psql -U postgres -d template1
```

### 2. Create the roles

```sql
CREATE ROLE wtf_dba
    LOGIN
    NOSUPERUSER
    NOCREATEDB
    NOCREATEROLE
    NOREPLICATION
    NOBYPASSRLS;

CREATE ROLE wtf_api
    LOGIN
    NOSUPERUSER
    NOCREATEDB
    NOCREATEROLE
    NOREPLICATION
    NOBYPASSRLS
    CONNECTION LIMIT 50;

\password wtf_dba
\password wtf_api
```

- **`LOGIN`** lets the role connect. (A role without it can only be used as a group.)
- **`NOSUPERUSER`, `NOCREATEDB`, `NOCREATEROLE`, `NOREPLICATION`, `NOBYPASSRLS`** are the defaults. They are spelled out to make clear that neither role has any power beyond what is granted below. In particular, `wtf_dba` doesn't need to be a superuser: owning the database and its objects is enough for DDL and maintenance.
- **`CONNECTION LIMIT 50`** caps the number of simultaneous connections of `wtf_api`. A misbehaving API server then can't exhaust the server's `max_connections`, which would also lock out `wtf_dba`. Size it to the API server's connection pool, plus some headroom.
- **`\password`** is a `psql` command. It prompts for the password and sends it already hashed (SCRAM-SHA-256, the default since PostgreSQL 14). The plain-text password therefore never ends up in the `psql` history or the server log. This is safer than `PASSWORD '...'` in `CREATE ROLE`.

### 3. Create the database

```sql
CREATE DATABASE wtf
    OWNER           wtf_dba
    TEMPLATE        template0
    ENCODING        'UTF8'
    LOCALE_PROVIDER icu
    ICU_LOCALE      'und';
```

- **`OWNER wtf_dba`** makes `wtf_dba` the owner. The owner may create schemas in the database and owns the `public` schema (PostgreSQL 15+). It also implicitly has every privilege on the database itself.
- **`TEMPLATE template0`** copies the pristine template that ships with PostgreSQL, instead of `template1`, which may have been customised. It is also required whenever the encoding or locale differs from the template's.
- **`ENCODING 'UTF8'`** is required. Unit symbols (µ, Ω, °, ², ³, ‰) and names in any language must be stored correctly.
- **`LOCALE_PROVIDER icu`, `ICU_LOCALE 'und'`** use ICU's root collation ("und" = undetermined language) for sorting and comparing text. Lists are sorted with `lower(name)`, and ICU gives the same, language-neutral order on Linux, macOS and Windows. The operating system's locale libraries differ between platforms. All standard PostgreSQL packages include ICU. To sort for a specific language instead, use its tag, e.g. `'nb'` or `'de'`.

### 4. Restrict access to the database

Connect to the new database, still as the superuser:

```sql
\c wtf
```

```sql
REVOKE ALL ON DATABASE wtf FROM PUBLIC;
GRANT CONNECT ON DATABASE wtf TO wtf_api;
```

`PUBLIC` means every role on the server. By default, every role may connect to a new database and create temporary tables in it. This takes those rights away from everyone, and then lets `wtf_api` connect. `wtf_dba` doesn't need a grant, because it is the owner.

```sql
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO wtf_api;
```

`USAGE` on a schema only allows looking up the names in it. It doesn't grant access to any table or function. `wtf_api` needs it to find the API functions. (Since PostgreSQL 15, `PUBLIC` can no longer *create* objects in `public`; this also removes its `USAGE`.) `wtf_api` gets no privileges at all on the `util` schema, which holds the internal helpers.

```sql
ALTER DEFAULT PRIVILEGES FOR ROLE wtf_dba
    REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
```

By default, every role may execute every newly created function. This default-privilege rule removes that for all functions `wtf_dba` creates from now on, in any schema. Functions are then executable only by their owner and by roles that are explicitly granted access (step 6). **It must be in place before the DDL is loaded.** It doesn't affect functions that already exist.

```sql
ALTER ROLE wtf_api IN DATABASE wtf SET search_path = public;
ALTER ROLE wtf_api IN DATABASE wtf SET statement_timeout = '30s';
ALTER ROLE wtf_api IN DATABASE wtf SET idle_in_transaction_session_timeout = '60s';

ALTER ROLE wtf_dba IN DATABASE wtf SET search_path = public;
```

These are per-role defaults, applied whenever the role connects to `wtf`:

- **`search_path = public`** lets the API server call functions without a schema prefix (`item_get(...)`). It also keeps `wtf_dba`'s objects in `public` unless a schema is given explicitly. The API functions don't depend on the caller's `search_path`: each pins its own.
- **`statement_timeout`** cancels any single call that runs longer than 30 seconds, so one runaway request can't hold locks and connections indefinitely.
- **`idle_in_transaction_session_timeout`** closes connections that opened a transaction and then went quiet for 60 seconds. Such connections hold locks and block the version-counter rows of `data_version`.

Adjust the values to taste; they can be overridden per session with `SET`.

### 5. Allow connections (`pg_hba.conf`)

Which roles may connect from where is controlled by `pg_hba.conf`. Find it with:

```sql
SHOW hba_file;
```

Add lines like these **above** any more general lines (the first matching line wins):

```text
# TYPE  DATABASE  USER     ADDRESS         METHOD
host    wtf       wtf_api  127.0.0.1/32    scram-sha-256
host    wtf       wtf_api  ::1/128         scram-sha-256
host    wtf       wtf_dba  127.0.0.1/32    scram-sha-256
host    wtf       wtf_dba  ::1/128         scram-sha-256
```

- **`host`** covers TCP/IP connections. Use `hostssl` instead to require TLS when connecting over a network.
- **`ADDRESS`**: these lines only allow connections from the machine itself. If the API server runs on another host, add its address (e.g. `192.0.2.10/32`). Also check `listen_addresses` in `postgresql.conf`, which defaults to `localhost`.
- **`scram-sha-256`** requires the password, in the safest password method PostgreSQL offers.

Then reload the configuration (no restart needed):

```sql
SELECT pg_reload_conf();
```

### 6. Create the schema with `wtfd`

`wtfd schema` creates the schema on a fresh database and upgrades it later. It also keeps `wtf_api`'s grants correct, so the old manual `GRANT` step is gone. It connects as `wtf_dba`. That matters because whoever creates an object owns it, and the API functions run with their owner's privileges (`SECURITY DEFINER`).

Build it (Go 1.26 or newer):

```sh
go build -o wtfd ./cmd/wtfd
```

Check what it would do, then run it:

```sh
export WTFD_DBA_DATABASE_PASSWORD='…'
./wtfd schema --dry-run
./wtfd schema
```

Run `./wtfd schema -h` for all flags, and see [WTFD.md](WTFD.md) for how migrations work. Run it again after every upgrade of `wtfd`. When nothing has changed, it does nothing.

### 7. Run the API

```sh
export WTFD_API_DATABASE_PASSWORD='…'
./wtfd serve --files-directory /var/lib/wtf/files
```

By default it listens on `127.0.0.1:8080`, for a reverse proxy on the same machine. It refuses to start if the database schema doesn't match the binary; run `wtfd schema` first. Run `./wtfd serve -h` for all flags, and see [WTFD.md](WTFD.md) and `GET /api/v1/openapi.yaml` for the API itself. With `--web-root DIR` it also serves the web app.

**TLS is recommended but not required:** passwords travel to `wtfd` and on to PostgreSQL, which hashes them. Whether to use HTTPS at the proxy and `hostssl` / `--database-sslmode require` for the database connection is the administrator's decision.

### 8. Create the first tenant

One installation holds many inventories, called tenants ([TENANTS.md](TENANTS.md)). The first label of the hostname a request comes to picks the tenant: `smith` for `smith.wtf.example`. Point a wildcard DNS name (`*.wtf.example`) at the server, and use a wildcard certificate at the proxy, and a new tenant needs nothing but this:

```sh
export WTFD_DBA_DATABASE_PASSWORD='…'
./wtfd tenant create --host smith --email anna@example.com
```

This creates the tenant and its first account, and prints the account's password once. On a home network without DNS names, [nip.io](https://nip.io) names reach the server by its address with the tenant in front: `http://smith.192.168.1.10.nip.io:8080`. An IP address alone picks no tenant, and gets 404. Log in and change it, with `wtf login` and `wtf password` (see [CLI.md](CLI.md)), or by hand. The session comes back as the cookie `wtf_session`, which curl keeps in a file:

```sh
curl -s -c cookies -H 'Host: smith.wtf.example' -H 'Content-Type: application/json' \
     -d '{"email": "anna@example.com", "password": "…"}' http://127.0.0.1:8080/api/v1/login
curl -s -b cookies -H 'Host: smith.wtf.example' http://127.0.0.1:8080/api/v1/me
```

The first account has every privilege and can create more accounts (`POST /accounts`). A lost password is replaced with `./wtfd account password --host smith --email …`. See [ACCOUNTS.md](ACCOUNTS.md).

### 9. Check

Connected as `wtf_api`:

```sql
SELECT schema_version();          -- works: an API function that needs no login
SELECT quantity_list();           -- ERROR: Not logged in (API functions need a session)
SELECT * FROM item;               -- ERROR: permission denied for table item
SELECT util.item_json(NULL);      -- ERROR: permission denied for schema util
CREATE TABLE test (id int);       -- ERROR: permission denied for schema public
```

### Summary of privileges

| Role      | Database             | Schema `public` | Schema `util` | Tables       | API functions | Other functions |
|-----------|----------------------|-----------------|---------------|--------------|---------------|-----------------|
| `wtf_dba` | owner                | owner           | owner         | owner        | owner         | owner           |
| `wtf_api` | `CONNECT`            | `USAGE`         | –             | –            | `EXECUTE`     | –               |
| `PUBLIC`  | –                    | –               | –             | –            | –             | –               |

## Command-line client

```sh
go build -o wtf ./cmd/wtf
wtf login --server http://localhost:8080 --email anna@example.com
wtf find drill
```

See [CLI.md](CLI.md).

## Backups

A database dump contains everything in `wtf`: the schema, the data, the grants and `wtfd`'s bookkeeping. Roles are global to the server and not part of a dump. They are recreated with steps 2 and 4 of the setup.

### Making a backup

```sh
pg_dump --host=localhost --username=wtf_dba --dbname=wtf \
        --format=custom --file="wtf-$(date +%F).dump"
```

- **`--username=wtf_dba`**: the DBA role owns every object, so it can read everything. `wtf_api` couldn't, because it can't read the tables.
- **`--format=custom`**: a compressed archive for `pg_restore`, which can restore everything or only selected parts. Plain SQL (`--format=plain`) is easier to read but less flexible.
- **Password:** set `PGPASSWORD`, or better, use a password file (`~/.pgpass`, one line `localhost:5432:wtf:wtf_dba:<password>`, mode 600). `pg_dump` reads it automatically, and the password stays out of scripts and process lists.
- **Version:** use a `pg_dump` at least as new as the server (18). An older `pg_dump` refuses to dump a newer server.

The dump is consistent: it is taken in a single snapshot, while `wtfd serve` keeps running.

**Scheduled backups**, e.g. daily at 03:00 with 30 days kept (cron of a user with a `~/.pgpass`):

```cron
0 3 * * *  pg_dump -h localhost -U wtf_dba -d wtf -Fc -f /var/backups/wtf/wtf-$(date +\%F).dump && find /var/backups/wtf -name 'wtf-*.dump' -mtime +30 -delete
```

Copy the dumps to another machine as well; a backup on the same disk doesn't survive that disk.

### Attachment files

Attachment contents live in the files directory (`--files-directory`), not in the database, so back that directory up as well. Files are stored under their content hash and never change, so incremental copies are cheap:

```sh
rsync -a /var/lib/wtf/files/ backup-host:/backups/wtf/files/
```

Take the database dump first and copy the files afterwards. Then every file the dump refers to is in the copy. Files that arrive in between are harmless; `wtfd gc` removes any that nothing references.

Run `wtfd gc` regularly (e.g. nightly) to remove files that no attachment refers to any more (see [WTFD.md](WTFD.md)).

History grows with every change. If it should not be kept forever, purge old entries regularly as well, e.g. `wtfd history purge --older-than 730d` (see [WTFD.md](WTFD.md)).

Deleted things stay in the database, so they can be restored, until they are purged: e.g. `wtfd deleted purge --older-than 365d`, followed by `wtfd gc` for their files. When and whether to purge is your choice.

### Restoring

Restore into a new, empty database prepared exactly like the original, so that ownership and grants come out right:

1. **Prepare the database**, as a superuser: steps 3 and 4 of the setup, with a new database name such as `wtf_restored` (or `wtf` after dropping or renaming the old one). The roles from step 2 must exist.
2. **Restore it** as `wtf_dba`:

   ```sh
   pg_restore --host=localhost --username=wtf_dba --dbname=wtf_restored \
              --single-transaction --exit-on-error wtf-2026-10-24.dump
   ```

   - **`--single-transaction`**: the restore either completes fully or leaves the database empty.
   - **`--exit-on-error`**: stop at the first error instead of carrying on.
3. **Restore the attachment files** into the files directory, e.g. with `rsync` from the backup.
4. **Check it:** `wtfd schema --database-name wtf_restored --dry-run` must report "up to date". After that, `wtfd serve` can use it.

Test a restore now and then. A backup that has never been restored is only a hope.

## Tests

```sh
go test ./...
```

runs the unit tests. The integration tests in `internal/integration` run the whole stack against a real database: the schema scripts, the database functions and triggers, and the HTTP layer. Without a test database, they are skipped.

### Test database

The integration tests need a separate database whose name ends in `_test`, because **they delete all its data**. The name check makes it impossible to point them at `wtf` by accident. Create it once, as a superuser, like steps 3 and 4 of the setup:

```sql
CREATE DATABASE wtf_test
    OWNER           wtf_dba
    TEMPLATE        template0
    ENCODING        'UTF8'
    LOCALE_PROVIDER icu
    ICU_LOCALE      'und';

\c wtf_test

REVOKE ALL ON DATABASE wtf_test FROM PUBLIC;
GRANT CONNECT ON DATABASE wtf_test TO wtf_api;
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO wtf_api;
ALTER ROLE wtf_api IN DATABASE wtf_test SET search_path = public;
ALTER ROLE wtf_dba IN DATABASE wtf_test SET search_path = public;
```

Also add `wtf_test` to the `pg_hba.conf` lines of step 5, and reload.

### Running the integration tests

```sh
export WTFD_TEST_DATABASE_NAME=wtf_test
export WTFD_TEST_DATABASE_HOST=localhost        # default localhost
export WTFD_DBA_DATABASE_PASSWORD='…'
export WTFD_API_DATABASE_PASSWORD='…'
go test ./internal/integration/ -v
```

`WTFD_TEST_DATABASE_PORT` and `WTFD_TEST_DATABASE_SSLMODE` are optional. The roles default to `wtf_dba` and `wtf_api` and can be overridden with `WTFD_DBA_DATABASE_USER` and `WTFD_API_DATABASE_USER`.

Each run first empties the test database, then brings its schema up to date with the same code as `wtfd schema`. It creates the first account, `admin@test.local`, and logs it in. Each test then empties the user data, leaving the quantities, unit families, units and accounts.

### The same checks as CI

The scripts in `scripts/` are what CI runs. They are bash scripts, which also run in Git Bash on Windows:

| Script | Does |
|--------|------|
| `scripts/test.sh` | checks the formatting (`gofmt`), runs `go vet` for Linux, Windows and macOS, and runs all tests; the integration tests only with the variables above |
| `scripts/test-db.sh` | creates the roles and the test database on a *fresh* PostgreSQL server, as described above; CI uses it for its throw-away server |
| `scripts/build.sh` | builds `wtf` and `wtfd` for Linux, Windows and macOS (amd64 and arm64) into `dist/` |
| `scripts/wtfd-env.example.ps1` | a template for setting the `WTFD_…` variables in PowerShell |

On GitHub, `.github/workflows/ci.yml` runs `test.sh` (with a throw-away PostgreSQL 18) and `build.sh` on every push and pull request.

## Licence

WtF is free software under the GNU Affero General Public Licence, version 3 (AGPL-3.0); see [LICENSE](LICENSE). In short: you may use, change and share it, and if you run a changed version as a service for others, you must offer them its source code too.
