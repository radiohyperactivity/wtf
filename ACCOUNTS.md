# Accounts and authentication – design

Status: **implemented** (migrations `0001_schema.sql` and `0004_roles.sql`, [api/account.md](api/account.md), `wtfd account`).

## Concepts

- One installation holds many inventories, called **tenants** ([TENANTS.md](TENANTS.md)), each with its classes, attributes, items, locations, stock, attachments and accounts. Global units are shared; each tenant can import its own.
- An **account** is a user of one tenant. The email address is the user name, unique case-insensitively among the tenant's accounts that aren't deleted. The same email in two tenants means two unrelated accounts.
- Every account has a **role**, one of `viewer`, `user` and `admin`. Each role can do what the ones before it can. Users keep the inventory; admins set it up:

  | | viewer | user | admin |
  |---|---|---|---|
  | See items, stock, locations, classes, attributes, units and attachments; search; label codes | ✓ | ✓ | ✓ |
  | History of items and stock rows | ✓ | ✓ | ✓ |
  | Add, change, delete and restore items and stock rows, with their values and attachments | | ✓ | ✓ |
  | Set up locations (with compartment grids), classes (with their attributes), attributes and options, and units for the tenant, with their attachments | | | ✓ |
  | Import and export model files | | | ✓ |
  | History of locations, classes, attributes and accounts, and of the top-level lists | | | ✓ |
  | Accounts | | | ✓ |

  A new account is a viewer unless it is given another role. The account's own information (`me`, `password_change`, `logout`) needs only a login.

## Schema

- **`account`** (`user` is a reserved word in SQL):
  - `id` and `tenant`;
  - `email`, unique case-insensitively among the tenant's live accounts;
  - `password_hash` (`NULL` = can't log in, e.g. until a future reset link is used);
  - `role`, of the enum `role` (`viewer`, `user`, `admin`, in that order), `viewer` by default;
  - `failed_logins` and `last_failed_login`, for the lockout;
  - `deleted`: a deleted account keeps its row, so history can still say who did what.
- **`session`:** `token_hash` (SHA-256 of the token; the token itself is never stored), `tenant`, `account` and `last_used`.
- **`pgcrypto`** is installed in its own schema, `extensions`, which `wtf_api` can't use. Passwords are hashed with bcrypt (`crypt` + `gen_salt('bf')`).

## Enforcement in the database

1. **Per request,** `wtfd` runs one transaction: `session_use(p_token, p_host)`, then the API function.
   - `session_use` hashes the token and finds the session. It checks that the session is of the tenant of the request's host and hasn't been unused for 30 days, and sets `last_used` (at most once a minute, to avoid a write on every request).
   - It then stores the token for the transaction: `set_config('wtf.token', …, true)`.
2. **Every API function** starts with `util.require('viewer' | 'user' | 'admin')`, or `util.require_login()` for the account's own information. That looks the token up again (by hash), finds the account and its tenant, and checks that the account's role is at least the one named. Every function then filters by that tenant (TENANTS.md, "Isolation").
3. **Defence in depth:** someone with the `wtf_api` password but no valid token can't act as any user. Without a session, the API functions refuse to work.

## API

| Method & path | Function | Who |
|---------------|----------|-----|
| `POST /api/v1/login` `{email, password}` | `login(p_host, p_email, p_password)` → `{token, account}`, in the tenant of the request's host; `wtfd` sends the token as the session cookie | anonymous |
| `POST /logout` | `logout()` (revokes the current token) | logged in |
| `GET /me` | `me()` → the account with its role | logged in |
| `PUT /me/password` `{current, new}` | `password_change(…)`: revokes all other sessions of the user | logged in |
| `GET /accounts` | `account_list()` | admin |
| `POST /accounts` `{email, password?, role?}` | `account_create(…)` | admin |
| `GET /accounts/{id}` | `account_get` | admin |
| `PATCH /accounts/{id}` `{email?, password?, role?}` | `account_patch`: changing the password revokes the account's sessions | admin |
| `DELETE /accounts/{id}` | `account_delete`: marks the account deleted (history keeps referring to it), revokes its sessions; its email can be reused | admin |

- **Anonymous routes:** only `/api/health`, `/api/v1/openapi.yaml` and `/api/v1/login` work without a session. Every other request needs the session cookie `wtf_session` (see WTFD.md, "Logins").
- **Tokens** are 32 random bytes (from `pgcrypto`), base64url-encoded. They expire after 30 days without use.
- **Passwords** have at least 8 characters and at most 72 bytes (bcrypt's limit).
- **Lockout:** after 5 failed logins for an account, only one attempt per minute is accepted until a login succeeds; others get 429. A successful login resets the count.
- **Admins can't lock themselves out:** you can't change your own role or delete your own account, so there is always at least one admin.
- **Error mappings:**

  | SQLSTATE | Meaning | HTTP |
  |----------|---------|------|
  | `28000` (`invalid_authorization_specification`) | missing, invalid or expired session; wrong email or password | 401, with `WWW-Authenticate: Cookie …` |
  | `42501` (`insufficient_privilege`) | not allowed | 403 |
  | `P0001` with a lockout message (a custom code) | too many attempts | 429 |

## CLI

Run by the operator as the DBA role:

- **`wtfd tenant create --host smith --email anna@example.com`** creates a tenant and its first account, an admin, and **`wtfd account create --host smith --email … [--role viewer|user|admin]`** another account in it, an admin unless `--role` says otherwise. Both print a generated password once.
- **`wtfd account password --email anna@example.com`** gives an account a new generated password, when it is lost. It also lifts a lockout and ends the account's sessions.

## TLS

Passwords travel from the client to `wtfd`, and from `wtfd` to PostgreSQL, because hashing happens there. TLS on both connections is **recommended** (`hostssl` in `pg_hba.conf`, `--database-sslmode require`, HTTPS at the proxy). Whether to use it is the administrator's decision; nothing enforces it.

## Decisions

- **Naming:** the table is `account` (`user` is a reserved word in SQL). The term "member" is not used.
- **Roles, not privileges** (2026-10-30, your decision): the four privileges (`data`, `model`, `account`, `history`, each `none`, `read_only` or `read_write`) became one role, to keep it simple for those who only keep the inventory (users) and those who set it up (admins); viewers look. Model exports are for admins, since they couldn't import them again. Migration `0004_roles.sql` made accounts that could write the model or the accounts admins, those that could write the data users, and the rest viewers. Locations moved from the data to the setup: users put stock in them, admins make them.
- **"Log out everywhere":** left out. Changing your own password already revokes all other sessions.
- **Tenants:** dropped once, and brought back, with accounts per tenant, in [TENANTS.md](TENANTS.md).
