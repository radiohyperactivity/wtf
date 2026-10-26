# Tenants and authentication – design

Status: **implemented** (migration `0006_tenants.sql`, [api/account.md](api/account.md), `wtfd tenant`).

## Concepts

- A **tenant** is an independent inventory, with its own classes, attributes, items, locations, stock and attachments. Tenants share nothing except the system data: quantities, units and unit groups.
- A tenant is reached through its own **hostname**, e.g. `smith.wtf.example`. `wtfd` finds the tenant from the request's `Host` header. The reverse proxy must preserve that header: Caddy does by default, while nginx needs `proxy_set_header Host $host;`.
- A **user** belongs to exactly one tenant. The email address is the user name, unique per tenant, so the same address can exist in two tenants as two unrelated users.
- Users have three **privileges**, each `none`, `read_only` or `read_write`:

  | Privilege | Covers |
  |-----------|--------|
  | `data`    | items, values, stock, locations, attachments, label codes, search |
  | `model`   | classes, class attributes, attributes, options |
  | `account` | the tenant's accounts (users) |
  | `history` | reading history (added with [history](api/history.md); `read_write` counts as `read_only`) |

  Quantities, units and unit groups are readable by every logged-in user.

## Schema (migration `0006_tenants.sql`)

- **New tables:**
  - **`tenant`:** `id`, `name` (unique), `hostname` (unique, case-insensitive).
  - **`account`** (`user` is a reserved word in SQL):
    - `id` and `tenant`;
    - `email`, unique per tenant, case-insensitively;
    - `password_hash` (`NULL` = can't log in, e.g. until a future reset link is used);
    - `data_privilege`, `model_privilege` and `account_privilege`, of the new enum `privilege`;
    - `failed_logins` and `last_failed_login`, for the lockout.
  - **`session`:** `token_hash` (SHA-256 of the token; the token itself is never stored), `tenant`, `account` and `last_used`.
- **Tenant column everywhere:** `tenant uuid NOT NULL` on class, attribute, attribute_option, class_attribute, item, value, location, stock, stock_value, attachment and session. Each of these tables gets `UNIQUE (tenant, id)`, and every reference between them becomes a composite foreign key `(tenant, x) → (tenant, id)`. A reference can then never cross tenants, declaratively.
- **Uniqueness becomes per tenant:** class and location sibling names, attribute names, and user emails.
- **Shared between tenants:**
  - `file`: the same content uploaded in two tenants is stored once. The API never reveals another tenant's attachments.
  - `code_sequence`: codes stay globally unique, and resolving them is restricted to the caller's tenant.
- **Tree versions per tenant:** `data_version` becomes `(tenant, name)`.
- **`pgcrypto`** is installed in its own schema, `extensions`, which `wtf_api` can't use. Passwords are hashed with bcrypt (`crypt` + `gen_salt('bf')`).
- **Empty data required:** the migration refuses to run while tenant-scoped data exists. For the development database we empty it explicitly first.

## Enforcement in the database

1. **Per request,** `wtfd` runs one transaction: `session_use(p_token, p_hostname)`, then the API function.
   - `session_use` hashes the token and finds the session. It checks that the session belongs to the tenant of that hostname and hasn't been unused for 30 days, and sets `last_used` (at most once a minute, to avoid a write on every request).
   - It then stores the token for the transaction: `set_config('wtf.token', …, true)`.
2. **Every API function** starts with `util.require('data' | 'model' | 'account', 'read' | 'write')`. That looks the token up again (by hash), finds the account and tenant, and checks the privilege.
   - **Every query is restricted** to that tenant, and new rows get it.
   - **Objects of another tenant don't exist** from the caller's point of view (404), so nothing about them leaks.
3. **Defence in depth:** someone with the `wtf_api` password but no valid token can't act as any user. Without a session, the API functions refuse to work.

## API

| Method & path | Function | Who |
|---------------|----------|-----|
| `POST /api/v1/login` `{email, password}` | `login(p_hostname, p_email, p_password)` → `{token, account}`; `wtfd` sends the token as the session cookie | anonymous |
| `POST /logout` | `logout()` (revokes the current token) | logged in |
| `GET /me` | `me()` → account, tenant, privileges | logged in |
| `PUT /me/password` `{current, new}` | `password_change(…)`: revokes all other sessions of the user | logged in |
| `GET /accounts` | `account_list()` | account ≥ read |
| `POST /accounts` `{email, password?, privileges…}` | `account_create(…)` | account = write |
| `GET /accounts/{id}` | `account_get` | account ≥ read |
| `PATCH /accounts/{id}` `{email?, password?, privileges…}` | `account_patch`: changing the password revokes the account's sessions | account = write |
| `DELETE /accounts/{id}` | `account_delete`: marks the account deleted (history keeps referring to it), revokes its sessions; its email can be reused | account = write |

- **Anonymous routes:** only `/api/health`, `/api/v1/openapi.yaml` and `/api/v1/login` work without a session. Every other request needs the session cookie `wtf_session` (see WTFD.md, "Logins").
- **Tokens** are 32 random bytes (from `pgcrypto`), base64url-encoded. They expire after 30 days without use.
- **Passwords** have at least 8 characters and at most 72 bytes (bcrypt's limit).
- **Lockout:** after 5 failed logins for an account, only one attempt per minute is accepted until a login succeeds; others get 429. A successful login resets the count.
- **Account admins can't lock themselves out:** you can't remove your own `account` write privilege or delete your own account, so a tenant always keeps at least one account admin.
- **New error mappings:**

  | SQLSTATE | Meaning | HTTP |
  |----------|---------|------|
  | `28000` (`invalid_authorization_specification`) | missing, invalid or expired session; wrong email or password | 401, with `WWW-Authenticate: Cookie …` |
  | `42501` (`insufficient_privilege`) | not allowed | 403 |
  | `P0001` with a lockout message (a custom code) | too many attempts | 429 |

## CLI

Run by the operator as the DBA role:

- **`wtfd tenant create --name smith-home --hostname smith.wtf.example --email anna@example.com`** creates the tenant and its first user, with every privilege `read_write`. It prints a generated password once.
- **`wtfd tenant list`** lists the tenants with their hostnames.
- **`wtfd tenant update --name smith-home [--new-name …] [--hostname …]`** renames a tenant or changes its hostname.

## TLS

Passwords travel from the client to `wtfd`, and from `wtfd` to PostgreSQL, because hashing happens there. TLS on both connections is **recommended** (`hostssl` in `pg_hba.conf`, `--database-sslmode require`, HTTPS at the proxy). Whether to use it is the administrator's decision; nothing enforces it.

## Decisions

- **Naming:** the table is `account` (`user` is a reserved word in SQL), and the privilege area for managing accounts is `account`. The term "member" is not used.
- **"Log out everywhere":** left out. Changing your own password already revokes all other sessions.
