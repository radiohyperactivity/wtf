# Sessions and accounts

The SQL is in [`db/repeatable/20_account.sql`](../db/repeatable/20_account.sql), with the session check `util.session` in [`db/repeatable/11_util.sql`](../db/repeatable/11_util.sql). The design is described in [ACCOUNTS.md](../ACCOUNTS.md).

## Logging in and sessions

- **`account.login(p_request, p_email, p_password, p_client, p_max_idle)`** logs in to the tenant of the request's host (TENANTS.md) and starts a session for the client `p_client` (a device's name, such as "WtF on Pixel 9", or null), which may sit unused for `p_max_idle` before it expires (null: until logging out).
  - **On success** it returns `{ok: true, token, account}`.
  - **On failure** it returns `{ok: false, reason}`, where `reason` is `invalid` (unknown email or wrong password) or `locked`. It returns these rather than raising an error, so the count of failed logins is committed. An unknown host is a 404.
  - **Lockout:** after 5 failed logins, only one attempt per minute is accepted until a login succeeds.
  - `wtfd` answers 200, 401 or 429 (with `Retry-After`), and logs each login with its client and address.
- **`util.session(p_request, p_role)`**, at the start of every other function, finds the session by its token's hash in the tenant of the host, checks the role, renews the session at most once a minute (with the address it was used from), and returns the session, its tenant, its account and the role.
- **`account.logout()`** ends the session the call is made with.
- **`account.me()`** returns the account the call is made with.
- **`account.password_change(p_current, p_new, p_end_other_sessions)`** changes one's own password, which needs the current one. `p_end_other_sessions` says whether the account's other sessions end too; it has no default.
- **`account.session_list()`** returns the account's sessions, most recently used first: `{id, client, created, last_used, max_idle, expires, current, usage}`. `id` is the token's hash in hex, which can't be turned back into the token; `max_idle` is seconds or null; `expires` is `last_used + max_idle`, or null; `current` marks the session asking; `usage` lists the addresses it was used from, newest first.
- **`account.session_logout(p_session)`** ends one of the account's own sessions, by its id; another account's session is not found. Ending the current one is a logout.
- **`account.session_logout_others()`** ends every session of the account but the current one ("log out everywhere else"), and returns how many ended.

Tokens are 32 random bytes, base64url-encoded; the database stores only their SHA-256 hash. Sessions aren't in history. `wtfd gc` removes expired sessions.

## Roles

`util.session` checks the account's role: it must be at least the function's, in the order `viewer`, `user`, `admin` ([ACCOUNTS.md](../ACCOUNTS.md) has the table).

- **Viewer:** reading, and the history of items and stock rows.
- **User:** also items and stock rows, with their values and attachments.
- **Admin:** also locations, classes, attributes, options, units for the tenant, model files, the accounts, and the rest of the history.
- One's own account and sessions (`account.me`, `account.password_change`, `account.logout`, `account.session_…`) need only a login.
- **Not allowed:** 42501, which `wtfd` turns into a 403.

## Accounts

These are for admins.

- **`account.list()`** returns the live accounts, by email address; **`account.get(p_account)`** one account, also a deleted one (with `deleted` saying when and by whom, as history still refers to it).
- **`account.create(p_email, p_password, p_role)`**:
  - the email is unique among live accounts, ignoring letter case;
  - a password needs at least 8 characters and at most 72 bytes (bcrypt, cost 12);
  - without a password (null), the account can't log in until one is set;
  - the role is required.
- **`account.patch(p_account, p_patch)`** takes the keys `email`, `password` (null removes it) and `role`. With `password` comes `end_sessions` (true or false, and only with a password): whether the account's sessions end. Deleted accounts can't be changed (409).
  - An admin's own password is changed with `account.password_change`, which needs the current one.
  - You can't change your own role (400), so a tenant always has an admin.
- **`account.delete(p_account)`** marks an account deleted, so history keeps referring to it.
  - Its password hash is removed and its sessions end, so it can't log in.
  - Its email can be used again.
  - You can't delete your own account (400).
- **`account.history(p_account, p_before, p_limit)`** shows the changes to an account.

The first account of a tenant is created with `wtfd tenant create`; `wtfd account create` adds another, and `wtfd account password` sets a lost password (see [WTFD.md](../WTFD.md)).
