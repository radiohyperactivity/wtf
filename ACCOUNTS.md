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

  A new account gets the role it is given (the API requires one; `wtf account add` makes a viewer unless told otherwise). The account's own information and sessions (`account.me`, `account.password_change`, `account.logout`, `account.session_…`) need only a login.

## Schema

- **`account`** (`user` is a reserved word in SQL):
  - `id` and `tenant`;
  - `email`, unique case-insensitively among the tenant's live accounts;
  - `password_hash` (`NULL` = can't log in, e.g. until a future reset link is used);
  - `role`, of the enum `role` (`viewer`, `user`, `admin`, in that order);
  - `failed_logins` and `last_failed_login`, for the lockout;
  - `deleted`, the action that deleted it: a deleted account keeps its row, so history can still say who did what.
- **`session`:** `token_hash` (SHA-256 of the token; the token itself is never stored, and its hex is the session's id in the API), `account`, `client` (the device's name), `created`, `last_used`, `max_idle` (how long it may sit unused; NULL: until logging out) and `usage` (the addresses it was used from, and when).
- **`pgcrypto`** is installed in its own schema, `extensions`, which `wtf_api` can't use. Passwords are hashed with bcrypt at cost 12 (`crypt` + `gen_salt('bf', 12)`).

## Enforcement in the database

1. **Per request,** `wtfd` makes one call: the API function, with the request (token, host label, client address) as its first argument, in one statement.
2. **Every API function** starts with `util.session(p_request, 'viewer' | 'user' | 'admin')`. It hashes the token and finds the session in the tenant of the request's host; checks that it hasn't sat unused for longer than its `max_idle`, that the account is live, and that its role is at least the one named; and renews it (`last_used` and the address, at most once a minute, to avoid a write on every request). It returns the session, its tenant, its account and the role, and every function then works in that tenant (TENANTS.md, "Isolation").
3. **Defence in depth:** someone with the `wtf_api` password but no valid token can't act as any user. Without a session, the API functions refuse to work.

## API

| Method & path | Function | Who |
|---------------|----------|-----|
| `POST /api/v1/login` `{email, password, client, max_idle}` | `account.login` → `{token, account}`, in the tenant of the request's host, a session for that client that may sit unused for `max_idle` seconds (null: until logging out); `wtfd` sends the token as the session cookie | anonymous |
| `POST /logout` | `account.logout` (ends the current session) | logged in |
| `GET /me` | `account.me` → the account with its role | logged in |
| `PUT /me/password` `{current, new, end_other_sessions}` | `account.password_change`: with `end_other_sessions`, the account's other sessions end | logged in |
| `GET /me/sessions` | `account.session_list`: the account's sessions | logged in |
| `DELETE /me/sessions/{id}` | `account.session_logout`: ends one of them | logged in |
| `POST /me/sessions/logout-others` | `account.session_logout_others`: ends all but the current one | logged in |
| `GET /accounts` | `account.list` | admin |
| `POST /accounts` `{email, password, role}` | `account.create` | admin |
| `GET /accounts/{id}` | `account.get` | admin |
| `PATCH /accounts/{id}` `{email?, password?, end_sessions?, role?}` | `account.patch`: with a password, `end_sessions` says whether the account's sessions end | admin |
| `DELETE /accounts/{id}` | `account.delete`: marks the account deleted (history keeps referring to it), ends its sessions; its email can be reused | admin |

- **Anonymous routes:** only `/api/health`, `/api/v1/openapi` and `/api/v1/login` work without a session. Every other request needs the session cookie `wtf_session` (see WTFD.md, "Logins").
- **Tokens** are 32 random bytes (from `pgcrypto`), base64url-encoded. A session expires after its `max_idle` without use, or never; `wtfd gc` removes expired sessions.
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
- **"Log out everywhere":** left out at first, as changing your own password revoked all other sessions. Since the refactor of November 2026, a user sees their sessions and ends them (`/me/sessions`), and a new password asks whether the others end.
- **Tenants:** dropped once, and brought back, with accounts per tenant, in [TENANTS.md](TENANTS.md).
