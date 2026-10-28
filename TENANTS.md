# Tenants – design

Status: **built** (agreed and built 2026-10-28; migrations `0001`–`0003`, API revision 11). One installation holds many independent inventories, called **tenants**. Setting one up is adding a few rows to the database, with no new DNS entries, databases, processes or directories to create by hand.

Decisions marked *(yours)* were made by you; the rest are mine, made while you were away, and are open to change.

## Tenants and hostnames

1. **A tenant is a row in `tenant`:** `id`, `host` and `code` *(yours)*. It has no name of its own, and nothing tells users that other tenants exist: `/me` doesn't mention one *(yours)*.
2. **The first label of the request's hostname picks the tenant** *(yours)*. `bob.wtf.example`, `bob.example.org` and `bob.192.168.1.10.nip.io` all reach the tenant whose `host` is `bob`. `wtfd` lower-cases the `Host` header, drops the port, and takes what comes before the first dot.
3. **`host` is a DNS label that starts with a letter:** `a`–`z`, `0`–`9` and `-`, at most 63 characters, lower case, unique. Because it starts with a letter, an IP address (`192.168.1.10`) never matches a tenant. A single-label name does: `localhost` is a valid `host`.
4. **A request whose hostname matches no tenant gets 404** *(yours)*, for the API and the web app alike. The one exception is `GET /api/health`, which answers on any hostname, so monitoring and load balancers can check the server by IP address.
5. **Wildcard DNS** (`*.wtf.example`) and a **wildcard certificate**, or Caddy's on-demand TLS, mean a new tenant needs nothing outside the database. On a home network, [nip.io](https://nip.io) names (`bob.192.168.1.10.nip.io`) reach a server by IP address with a tenant label in front.

## Isolation: explicit filters *(yours)*

6. **Every table of tenant data has `tenant uuid NOT NULL`,** and `UNIQUE (tenant, id)`. Every reference between those tables is a composite foreign key `(tenant, x) → (tenant, id)`, so a row can never point into another tenant.
7. **The tenant of a request comes from its session,** never from a value the caller can set: `util.tenant()` finds the session by its token, as `util.current_session()` finds the account. The session belongs to one tenant, and `session_use(token, host)` checks that it is the tenant of the request's hostname.
8. **The rule for API functions:**
   - **Every id that comes from the request is checked against the tenant where it enters:** `WHERE id = p_id AND tenant = v_tenant`. Anything else answers 404, as if it didn't exist.
   - **Every query that starts from a table, not from a checked id, filters by tenant:** lists, searches, trees, look-ups by name or code, uniqueness checks.
   - **Every insert writes the tenant.**
   - **Queries that only follow references from checked rows need no filter,** because the composite foreign keys keep those references inside the tenant. Most `util.*_json` helpers are of this kind.
9. **Unique names are unique per tenant:** sibling classes and locations, attributes, options within their attribute, account emails, codes.
10. **An isolation test** runs two tenants side by side and checks that one can't see, find, change or delete the other's things, by id, code, list, search or tree.

## Codes

11. **Codes are per tenant** *(yours).* `tenant.code` holds the next one *(yours; first named `next_code`)*. `next_code(tenant)` takes it for every new item, location and stock row: `UPDATE tenant SET code = code + 1 … RETURNING`. New codes within one tenant wait for each other until commit, which is no problem at this scale. Codes start at 32768 ("1000") in every tenant, so two tenants have the same codes for different things. Looking a code up searches only your own tenant.

## Accounts

12. **Accounts are per tenant** *(yours)*, as before tenants were dropped. An email is unique within a tenant, and the same email in two tenants means two unrelated accounts. Lockout and sessions are per tenant. A session cookie is limited to its hostname by the browser anyway, and `session_use` refuses a session from another tenant (401).
13. **Privileges are unchanged.** Running the tenant (users, units, the model) is done by its own accounts with the account and model privileges. Creating and removing tenants is the operator's job.

## Units

14. **Global units, and each tenant's own** *(yours)*. Quantities, unit families and units have `tenant uuid NULL`, where NULL means global. A tenant sees the global ones and its own.
    - **Global units** are installed with the schema (the bootstrap set) and imported by the operator: `wtfd unit import --global FILE`. They are only ever added to: changing a global unit's factor would change every tenant's numbers.
    - **A tenant's own** come from importing a unit file through the API, as today (model write privilege). Their families can belong to a global quantity, and their units to a global family: a tenant can add "hand" to Imperial length.
    - **Names and symbols** must be unique among what a tenant sees. A tenant can't import a family named like a global one, and the operator can't add a global one named like some tenant's (the import says which tenants are in the way).
15. **Keys are UUIDs** *(yours)*, for quantities, families and units alike, as for everything else. Unit files refer to units by name and symbol, so their format doesn't change. The API's ids become strings (a new API revision).
16. **Turning units on and off, per quantity and per family** *(yours)*:
    - **Global quantities and families have `standard`** *(yours; first named `default_available`)*: whether a tenant has them without having chosen. A new global quantity or family shows up in every tenant, or not, according to this flag, with nothing else to set.
    - **A tenant stores only its choices**, in `tenant_quantity` and `tenant_unit_family`: (tenant, quantity or family, `available`). A choice that is the default anyway isn't kept, so a choice always differs from the default, and the app offers a way back to the default only then.
    - **A quantity is available** by the tenant's choice, otherwise by its `standard`. A tenant's own quantities are available unless it turns them off.
    - **A family is available** when its quantity is, and then by the tenant's choice, otherwise by its `standard`.
    - **A new tenant needs no unit rows:** the defaults are its starting point.
    - **Choosing a unit** for an attribute or an item takes only available units. Units of quantities or families that were turned off still show and convert wherever they are already used.
    - **A quantity or family in use can't be turned off.** The refusal (409) names the attributes and items that use it. Otherwise numbers would show in a unit nobody can choose.
    - **The API:** units, families and quantities say `global`, `available` and (global ones) `standard`. `PATCH /quantities/{id}` and `PATCH /unit-families/{id}` with `{"available": true | false | null}` set the tenant's choice; `null` goes back to the default.
17. **The bootstrap set is global and available by default,** all of it. The operator can change `standard` with `wtfd unit standard`.

## Files

18. **Each tenant has its own directory** in the files directory, named after its `host` *(yours)*: `<files directory>/<host>/<first two hex characters>/<hash>`, with uploads staged in `<host>/tmp`. Identical files are stored once per tenant. `wtfd` creates the directory at the first upload, so creating a tenant still needs only rows.
19. **`wtfd gc`** goes through every tenant's directory. A directory that belongs to no tenant is reported, never removed.
20. **Renaming a tenant** (`wtfd tenant rename`) changes `host` and moves the directory together. A bare `UPDATE` would leave the files behind.

## History, versions, purging

21. **History is per tenant:** every entry has its tenant, and the history calls show only your own.
22. **Tree versions** (`data_version`, the ETag of the class and location trees) are per tenant: `(tenant, name)`.
23. **`wtfd history purge` and `wtfd deleted purge`** work on every tenant, or on one with `--host`.

## Operator commands

Run as the DBA role, like the other `wtfd` actions:

| Command | What it does |
|---|---|
| `wtfd tenant create --host bob --email anna@example.com` | Creates the tenant and its first account, with every privilege, and prints a generated password once. |
| `wtfd tenant list` | Lists the tenants: host, accounts, items, files. |
| `wtfd tenant rename --host bob --new-host robert --files-directory DIR` | Changes the host, and moves its directory in the files directory with it. |
| `wtfd account create --host bob --email …` | Another account with every privilege (as today, now in a tenant). |
| `wtfd account password --host bob --email …` | A new password for a lost one (as today, now in a tenant). |
| `wtfd unit import --global FILE [--dry-run]` | Adds global units from a unit file. |
| `wtfd unit standard --quantity NAME | --family NAME --available true|false` | Changes whether a global quantity or family is available as standard. |\| --family NAME --available true\|false` | Changes whether a global quantity or family is available by default. |

`wtfd tenant create` is the convenient way; three `INSERT`s (tenant, account, with a bcrypt password) do the same.

**Not built yet:** deleting a tenant. Its rows are spread over every table, and the history triggers would log the deletion of each one; a later `wtfd tenant delete` will remove it all and its directory.

## The schema

24. **The migrations start again at `0001`** *(yours)*, and existing databases are recreated: they held only test data.
25. **`0001_schema.sql`** is everything before plus tenants; **`0002_units.sql`** is the global bootstrap set; **`0003_renames.sql`** renames `tenant.next_code` to `code` and `default_available` to `standard` (your names), and stays as a migration because the dev database already had `0001`.

## What changes for clients

- **The CLI and the apps** keep using one address per inventory, as before: the hostname in the address picks the tenant. Nothing about logging in changes.
- **Unit ids are strings** (UUIDs), and unit lists say what is global and what is available. Pickers offer only available units.
- **Manage → Units** in the app, and `wtf quantity` / `wtf unit-family` in the CLI, can turn quantities and families on and off.
- **The API revision** goes to 11.

## Decided while building

26. **A missing reference in a request's body is 422, a missing object in the path 404,** as before tenants. Another tenant's things count as missing either way. The explicit checks raise `foreign_key_violation` (`util.raise_bad_reference`) for body references, so `POST /items` with another tenant's class is 422, while `GET /items/{another tenant's item}` is 404.
27. **"Still in use" is 409 for every method,** not only DELETE: turning off a family that attributes use is `PATCH`. A `restrict_violation` always means in use; a foreign key error outside DELETE stays 422.
28. **Tree versions** start at 1 for a tenant that has no row in `data_version` yet; its row appears with the first change. The triggers are per row now (a statement can't tell which tenants it touched), which only means more increments.
29. **The advisory lock of a file** is keyed by its hash alone, shared by all tenants: at worst two uploads of the same content in different tenants wait for each other.
30. **Importing units** is one function, `util.unit_import(tenant, file, dry_run)`, for the API (the session's tenant) and for `wtfd unit import --global` (no tenant).
31. **Lists of units are ordered by name** (quantities, then families, then units by size). The old integer ids happened to keep the seed's order; UUIDs don't, so "Imperial length" now comes before "Metric length".
32. **Units of a family that is off** still show and convert where they are used. The app's number fields accept units typed from available families and from the unit's own family; the CLI completes only available units; the server refuses the rest.
33. **The tests** run one tenant, `test` (`test.wtf.example`), and the isolation test adds a second for each run. The CLI tests reach the server through a test server at an IP address, which picks no tenant, so it sets the hostname on each request.
34. **Your dev database** was recreated with one tenant, host `bbj`, and your account `bbj@bbj.io`. The old files are in `_before-tenants` in the files directory.
