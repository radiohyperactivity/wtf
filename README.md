# WtF – Where to Find

Keeping your stuff organised.

| Document                     | Contents                                                     |
|------------------------------|--------------------------------------------------------------|
| [SCHEMA.md](SCHEMA.md)       | Tables, types, indexes, and what the database enforces        |
| [SCHEMA.html](SCHEMA.html)   | Entity-relationship diagram                                   |
| [seed/model-format.md](seed/model-format.md) | Model files: classes with their attributes for one use, such as [MCUs](seed/models/mcu.json); importing and exporting |
| [API.md](API.md)             | The PL/pgSQL functions all data access goes through           |
| [WTFD.md](WTFD.md)           | `wtfd`, the server: its actions, routes and configuration     |
| [PERFORMANCE.md](PERFORMANCE.md) | How fast it is, measured                                  |
| [CLI.md](CLI.md)             | `wtf`, the command-line client                                |
| [TODO.md](TODO.md)           | Things to come back to later                                  |

## Database setup

**The short way:** once PostgreSQL is installed (step 1) and lets you connect (step 5), `wtfd database create` does steps 2, 3, 4 and 6, and step 8 if you want it. It connects as an administrator (a superuser such as `postgres`, or a role with `CREATEROLE` and `CREATEDB`), asks for what it needs, and checks the server first: PostgreSQL 18 or newer, with ICU, and none of the names in use. When something fails along the way, it removes what it made. It never sends the roles' passwords themselves, only their hashes, as psql's `\password` does. Passwords it generates are shown once, as lines for PostgreSQL's password file.

```sh
./wtfd database create
```

Every question is also a flag (`./wtfd database create -h`), so it can run without a terminal; the administrator's password then comes from PostgreSQL's password file, and the roles' are generated. It reads none of `wtfd`'s environment variables (`WTFD_…`): they describe a database that exists, not the one to make. `./wtfd database create --print-sql` prints the same steps as a psql script, for doing them by hand. The steps below explain what it does and why.

The examples use these names:

| Name      | What                                                                                 |
|-----------|--------------------------------------------------------------------------------------|
| `wtf`     | The database.                                                                        |
| `wtf_dba` | Owner of the database and every object in it. Used for DDL, upgrades and maintenance. |
| `wtf_api` | Used by the REST API server. May only execute the API functions.                     |

### 1. Install PostgreSQL

Follow the installation instructions for your platform at <https://www.postgresql.org/download/>. WtF needs **PostgreSQL 18 or newer**, built with ICU (the usual packages are), so use the newest release available.

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

`USAGE` on a schema only allows looking up the names in it. It doesn't grant access to any table or function. `wtf_api` needs it to find the API functions. (Since PostgreSQL 15, `PUBLIC` can no longer *create* objects in `public`; this also removes its `USAGE`.) `wtfd schema` gives `wtf_api` `USAGE` on the schemas that hold the functions (`item`, `class`, …), and `EXECUTE` on only the functions the API calls.

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
- **`idle_in_transaction_session_timeout`** closes connections that opened a transaction and then went quiet for 60 seconds. Such connections hold locks and block the version counters in `meta`.

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

That `wtfd` has no web app in it; [BUILDING.md](BUILDING.md) has building for every system, the apps included. `scripts/release.sh` builds a release into `dist/release/`: for each system `wtfd` runs on, an archive with `wtf`, `wtfd` (with the web app), the licence and a short README; `.zip` for Windows, `.tar.gz` for Linux and macOS. `scripts/build.sh` builds `wtf` and `wtfd` for every system into `dist/`, with the web app built into `wtfd`; it needs Flutter as well (`FLUTTER=…` names it when `flutter` isn't on the PATH). By hand, the same is:

```sh
(cd app && flutter build web --release --no-web-resources-cdn)
rm -rf internal/webapp/dist && cp -r app/build/web internal/webapp/dist
go build -tags webapp -o wtfd ./cmd/wtfd
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

By default it listens on `127.0.0.1:8080`, for a reverse proxy on the same machine; name the proxy with `--trusted-proxies 127.0.0.1` (or `WTFD_TRUSTED_PROXIES`), so that the logs and the session list show the client's address, not the proxy's. It refuses to start if the database schema doesn't match the binary; run `wtfd schema` first. Run `./wtfd serve -h` for all flags, and see [WTFD.md](WTFD.md) and `GET /api/v1/openapi` for the API itself. It also serves the web app, when it has one built in (below), or one in `--web-root DIR`.

Instead of the environment variable, the password can come from PostgreSQL's password file, as for every PostgreSQL client: `~/.pgpass` (mode 600), `%APPDATA%\postgresql\pgpass.conf` on Windows, or the file `PGPASSFILE` names. To run `wtfd` as a service, see [Running as a service](#running-as-a-service).

**TLS is recommended but not required:** passwords travel to `wtfd` and on to PostgreSQL, which hashes them. Whether to use HTTPS at the proxy and `hostssl` / `--database-sslmode require` for the database connection is the administrator's decision. [PROXY.md](PROXY.md) shows how to set up nginx with a Let's Encrypt certificate on Ubuntu.

### 8. Create the first account

One database is one installation of WtF: one inventory. Another inventory is another database, with its own `wtfd`.

```sh
export WTFD_DBA_DATABASE_PASSWORD='…'
./wtfd account create --email anna@example.com
```

This creates the first account, an admin, and prints its password once. Log in and change it, with `wtf login` and `wtf password` (see [CLI.md](CLI.md)), or by hand. The session comes back as the cookie `wtf_session`, which curl keeps in a file:

```sh
curl -s -c cookies -H 'Content-Type: application/json' \
     -d '{"email": "anna@example.com", "password": "…"}' http://127.0.0.1:8080/api/v1/login
curl -s -b cookies http://127.0.0.1:8080/api/v1/me
```

The first account can create more accounts (`POST /accounts`). A lost password is replaced with `./wtfd account password --email …`. See [ACCOUNTS.md](ACCOUNTS.md).

### 9. Check

Connected as `wtf_api`:

```sql
SELECT schema_version();          -- works: an API function that needs no login
SELECT class.list(ROW(NULL, NULL)::public.request);  -- ERROR: Not logged in (API functions need a session)
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

## Installing on Windows

`wtfd install`, in PowerShell or Windows Terminal opened as an administrator, sets WtF up on the machine, from the folder that has `wtfd.exe` and `wtf.exe`:

```powershell
.\wtfd.exe install
```

- **The programs** go in `C:\Program Files\WtF\bin`, which is added to the machine's PATH (for windows opened from then on).
- **The data** goes in `C:\ProgramData\WtF`, which only administrators and SYSTEM can open: the files in `files\` (`--files-directory` puts them elsewhere, such as on another drive), and `pgpass.conf`, PostgreSQL's password file, with both roles' passwords.
- **The database:** it asks whether WtF's database is there already. If so, it asks for its server, names and passwords, checks that both roles can connect, and brings the schema up to date. If not, it makes it, as `wtfd database create` does (see [Database setup](#database-setup)).
- **The settings** go in `C:\ProgramData\WtF\wtfd.conf`: the database's server, name and roles, the files directory, and the address `wtfd serve` listens on, which it asks for (`127.0.0.1:8080` serves this machine only; `0.0.0.0:8080` the network). See [WTFD.md](WTFD.md#configuration) for the file.
- **Running it again** with a newer `wtfd.exe` upgrades: it stops the `wtfd` service while it replaces the programs, takes the settings from `wtfd.conf` and the passwords from `pgpass.conf`, asking only for what they don't have, brings the schema up to date, and starts the service again. `--reconfigure` asks for every setting again, with the file's as the defaults; a flag (`--listen 127.0.0.1:8080`) changes one without asking.

Afterwards `wtfd serve`, `schema`, `gc` and `account` need no flags or environment variables: they read `wtfd.conf`, and the passwords from the `pgpass.conf` beside it. Both are for administrators only, so run them in an administrator's window; elsewhere `wtfd` says it can't read the file, and goes on without it.

## Running as a service

### Windows

`wtfd` runs as a Windows service of its own: when the Service Control Manager starts it, it reports to it, stops on Stop and on shutdown (waiting up to 30 seconds for requests to finish), and logs to the Event Log (Application, source `wtfd`). The service's command line is an ordinary `wtfd serve`, which takes its settings from `wtfd.conf` and its password from `pgpass.conf` (see [Installing on Windows](#installing-on-windows)).

`wtfd install` offers to set the service up at its end; otherwise, in an administrator's PowerShell:

```powershell
wtfd service install
```

- **The service** is `wtfd` ("WtF server"), running `C:\Program Files\WtF\bin\wtfd.exe serve`, never another copy. It starts at boot, delayed until the rest of Windows is up, so the network and PostgreSQL are more likely to be ready. It runs as its own virtual account, `NT SERVICE\wtfd`, which needs no password and may do only what it is given.
- **When it fails** it is restarted, after 5 seconds, 5 seconds again, and then a minute, counted afresh after a day; also when `serve` stops with an error of its own, such as a database that isn't up yet.
- **Its access:** read on `wtfd.conf` and `pgpass.conf`, modify on the files directory, and through `ProgramData\WtF` to them, which is otherwise for administrators only. Nothing goes in the service's environment in the registry, which every local user can read.
- **The firewall:** when `listen` is open to the network, it asks whether to add the inbound rule "WtF server" for that port. With a reverse proxy on the same machine, `wtfd` listens on `127.0.0.1` and needs none.
- **It starts the service and checks it,** by asking `/api/health`; when that fails, it shows wtfd's last entries in the Event Log. `Get-EventLog -LogName Application -Source wtfd -Newest 20` shows them any time.
- **Running it again** brings the service up to date and restarts it. `wtfd service uninstall` stops and removes the service, its access, the firewall rule and the Event Log source, and leaves the programs, the settings and the data.

**Upgrading:** run `wtfd install` again with the new `wtfd.exe`: it stops the service, replaces the programs, brings the schema up to date and starts the service again. `serve` refuses to start on a schema that doesn't match it.

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

**A delete is final.** WtF keeps no deleted things and no history, so a backup is the way back from a mistake. That is also why the copy of the files directory above has no `--delete`: the files of deleted attachments stay in the backup after `wtfd gc` removes them from the server. Keep it that way.

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

### Getting one thing back

To get back something deleted by mistake, without losing what changed since, restore the backup *beside* the live database, as `wtf_restored` (steps 1 and 2 above), and look the thing up there, e.g. with `psql` as `wtf_dba`. Then enter it again through the app or the CLI, or copy its rows across by hand. Its attachments' files are in the backup of the files directory, under their hash. Drop `wtf_restored` afterwards.

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

Each run first empties the test database, then brings its schema up to date with the same code as `wtfd schema`. It creates the first account, `admin@test.local`, and logs it in. Each test then empties the data, leaving the accounts.

The performance test (`TestPerformance`, in `performance_test.go`) runs only when asked. It loads data of each size given, times the common reads and writes and the changes of a class's attributes, and can write its tables to a Markdown file. [PERFORMANCE.md](PERFORMANCE.md) has the results so far.

```sh
export WTFD_TEST_PERF=1000,10000,50000          # the item counts, smallest first
export WTFD_TEST_PERF_REPORT=perf.md            # optional
go test ./internal/integration/ -run TestPerformance -v -timeout 120m
```

### The same checks as CI

The scripts in `scripts/` are what CI runs. They are bash scripts, which also run in Git Bash on Windows:

| Script | Does |
|--------|------|
| `scripts/test.sh` | checks the formatting (`gofmt`), runs `go vet` for Linux, Windows and macOS, and runs all tests; the integration tests only with the variables above |
| `scripts/test-db.sh` | creates the roles and the test database on a *fresh* PostgreSQL server, as described above; CI uses it for its throw-away server |
| `scripts/build.sh` | builds `wtf` and `wtfd` (with the web app) for Linux, Windows and macOS (amd64 and arm64) into `dist/` |
| `scripts/release.sh` | builds a release: an archive for each system, with `wtf`, `wtfd`, the licence and a README |
| `scripts/wtfd-env.example.ps1` | a template for setting the `WTFD_…` variables in PowerShell |

On GitHub, `.github/workflows/ci.yml` runs `test.sh` (with a throw-away PostgreSQL 18) and `build.sh` on every push and pull request.

## Licence

WtF is free software under the GNU Affero General Public Licence, version 3 (AGPL-3.0); see [LICENSE](LICENSE). In short: you may use, change and share it, and if you run a changed version as a service for others, you must offer them its source code too.
