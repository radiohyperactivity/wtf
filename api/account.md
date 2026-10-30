# Sessions and accounts

The SQL is in [`db/repeatable/90_account.sql`](../db/repeatable/90_account.sql), with the session helpers in [`db/repeatable/10_util.sql`](../db/repeatable/10_util.sql). The design is described in [ACCOUNTS.md](../ACCOUNTS.md).

## Sessions

- **`login(p_host, p_email, p_password)`** logs in to the tenant whose host is `p_host`, the first label of the request's hostname (TENANTS.md).
  - **On success** it returns `{ok: true, token, account}`.
  - **On failure** it returns `{ok: false, reason}`, where `reason` is `invalid` (unknown email or wrong password) or `locked`. It returns these rather than raising an error, so the count of failed logins is committed.
  - **Lockout:** after 5 failed logins, only one attempt per minute is accepted until a login succeeds.
  - `wtfd` answers 200, 401 or 429 (with `Retry-After`).
- **`session_use(p_token, p_host)`** starts using a session for the current transaction. It checks the token, and that the session is of the tenant of `p_host`, renews the session at most once a minute, and remembers the token until the end of the transaction. `wtfd` calls it before every API function except `login`.
- **`tenant_known(p_host)`** tells whether a tenant has that host; `wtfd` answers 404 to a hostname that picks none.
- **`logout()`** ends the current session.
- **`me()`** returns the logged-in account.
- **`password_change(p_current, p_new)`** changes the own password, and ends the account's other sessions.

Tokens are 32 random bytes, base64url-encoded. The database stores only their SHA-256 hash. A session expires after 30 days without use.

## Roles

Every API function checks the logged-in account's role with `util.require(p_role)`: the account's role must be at least `p_role`, in the order `viewer`, `user`, `admin` ([ACCOUNTS.md](../ACCOUNTS.md) has the table).

- **Viewer:** reading, and the history of items and stock rows.
- **User:** also items and stock rows, with their values and attachments.
- **Admin:** also locations, classes, attributes, options, units for the tenant, model files, the accounts, and the rest of the history.
- The account's own information (`me`, `password_change`, `logout`) needs only a login.
- **Not allowed:** the function raises 42501, which `wtfd` turns into a 403.

## Accounts

These are for admins.

- **`account_list()`** and **`account_get(p_id)`**.
- **`account_create(p_email, p_password, p_role)`**:
  - the email is unique among accounts that aren't deleted, case-insensitively;
  - a password needs at least 8 characters and at most 72 bytes;
  - without a password, the account can't log in;
  - the role is `viewer` unless `p_role` says `user` or `admin`.
- **`account_patch(p_id, p_patch)`** takes the keys `email`, `password` (null removes it) and `role`. Deleted accounts can't be changed.
  - Changing the password ends the account's sessions, except the caller's own.
  - You can't change your own role (422), so there is always an admin.
- **`account_delete(p_id)`** marks an account deleted, so history keeps referring to it.
  - It can't log in; it loses its password and sessions, and becomes a viewer.
  - Its email can be used again.
  - `account_list` leaves it out, while `account_get` still shows it (`deleted: true`).
  - You can't delete your own account (422).
- **`account_history(p_id, …)`** shows the changes to an account.

The first account of a tenant is created with `wtfd tenant create`; `wtfd account create` adds another, and `wtfd account password` sets a lost password (see [WTFD.md](../WTFD.md)).
