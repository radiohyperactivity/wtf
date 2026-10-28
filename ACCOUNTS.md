# Accounts and authentication – design

Status: **implemented** (migration `0001_schema.sql`, [api/account.md](api/account.md), `wtfd account`).

## Concepts

- One installation holds many inventories, called **tenants** ([TENANTS.md](TENANTS.md)), each with its classes, attributes, items, locations, stock, attachments and accounts. Global units are shared; each tenant can import its own.
- An **account** is a user of one tenant. The email address is the user name, unique case-insensitively among the tenant's accounts that aren't deleted. The same email in two tenants means two unrelated accounts.
- Accounts have four **privileges**, each `none`, `read_only` or `read_write`:

  | Privilege | Covers |
  |-----------|--------|
  | `data`    | items, values, stock, locations, attachments, label codes, search |
  | `model`   | classes, class attributes, attributes, options |
  | `account` | the accounts (users) |
  | `history` | reading history (see [history](api/history.md); `read_write` counts as `read_only`) |

  Reading the model also works with the `data` read privilege, since entering data needs to see it. Quantities, unit families and units are readable by every logged-in account; turning them on and off for the tenant, and importing its own, needs model write.

## Schema

- **`account`** (`user` is a reserved word in SQL):
  - `id` and `tenant`;
  - `email`, unique case-insensitively among the tenant's live accounts;
  - `password_hash` (`NULL` = can't log in, e.g. until a future reset link is used);
  - `data_privilege`, `model_privilege`, `account_privilege` and `history_privilege`, of the enum `privilege`;
  - `failed_logins` and `last_failed_login`, for the lockout;
  - `deleted`: a deleted account keeps its row, so history can still say who did what.
- **`session`:** `token_hash` (SHA-256 of the token; the token itself is never stored), `tenant`, `account` and `last_used`.
- **`pgcrypto`** is installed in its own schema, `extensions`, which `wtf_api` can't use. Passwords are hashed with bcrypt (`crypt` + `gen_salt('bf')`).

## Enforcement in the database

1. **Per request,** `wtfd` runs one transaction: `session_use(p_token, p_host)`, then the API function.
   - `session_use` hashes the token and finds the session. It checks that the session is of the tenant of the request's host and hasn't been unused for 30 days, and sets `last_used` (at most once a minute, to avoid a write on every request).
   - It then stores the token for the transaction: `set_config('wtf.token', …, true)`.
2. **Every API function** starts with `util.require('data' | 'model' | 'account' | 'history', 'read' | 'write')`, or `util.require_login()` for system data. That looks the token up again (by hash), finds the account and its tenant, and checks the privilege. Every function then filters by that tenant (TENANTS.md, "Isolation").
3. **Defence in depth:** someone with the `wtf_api` password but no valid token can't act as any user. Without a session, the API functions refuse to work.

## API

| Method & path | Function | Who |
|---------------|----------|-----|
| `POST /api/v1/login` `{email, password}` | `login(p_host, p_email, p_password)` → `{token, account}`, in the tenant of the request's host; `wtfd` sends the token as the session cookie | anonymous |
| `POST /logout` | `logout()` (revokes the current token) | logged in |
| `GET /me` | `me()` → the account with its privileges | logged in |
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
- **Account admins can't lock themselves out:** you can't remove your own `account` write privilege or delete your own account, so there is always at least one account admin.
- **Error mappings:**

  | SQLSTATE | Meaning | HTTP |
  |----------|---------|------|
  | `28000` (`invalid_authorization_specification`) | missing, invalid or expired session; wrong email or password | 401, with `WWW-Authenticate: Cookie …` |
  | `42501` (`insufficient_privilege`) | not allowed | 403 |
  | `P0001` with a lockout message (a custom code) | too many attempts | 429 |

## CLI

Run by the operator as the DBA role:

- **`wtfd tenant create --host smith --email anna@example.com`** creates a tenant and its first account, and **`wtfd account create --host smith --email …`** another account in it, with every privilege `read_write`. Both print a generated password once.
- **`wtfd account password --email anna@example.com`** gives an account a new generated password, when it is lost. It also lifts a lockout and ends the account's sessions.

## TLS

Passwords travel from the client to `wtfd`, and from `wtfd` to PostgreSQL, because hashing happens there. TLS on both connections is **recommended** (`hostssl` in `pg_hba.conf`, `--database-sslmode require`, HTTPS at the proxy). Whether to use it is the administrator's decision; nothing enforces it.

## Decisions

- **Naming:** the table is `account` (`user` is a reserved word in SQL), and the privilege area for managing accounts is `account`. The term "member" is not used.
- **"Log out everywhere":** left out. Changing your own password already revokes all other sessions.
- **Tenants:** dropped once, and brought back, with accounts per tenant, in [TENANTS.md](TENANTS.md).
