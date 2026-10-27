# Sessions and accounts

The SQL is in [`db/repeatable/90_account.sql`](../db/repeatable/90_account.sql), with the session helpers in [`db/repeatable/10_util.sql`](../db/repeatable/10_util.sql). The design is described in [ACCOUNTS.md](../ACCOUNTS.md).

## Sessions

- **`login(p_email, p_password)`** logs in.
  - **On success** it returns `{ok: true, token, account}`.
  - **On failure** it returns `{ok: false, reason}`, where `reason` is `invalid` (unknown email or wrong password) or `locked`. It returns these rather than raising an error, so the count of failed logins is committed.
  - **Lockout:** after 5 failed logins, only one attempt per minute is accepted until a login succeeds.
  - `wtfd` answers 200, 401 or 429 (with `Retry-After`).
- **`session_use(p_token)`** starts using a session for the current transaction. It checks the token, renews the session at most once a minute, and remembers the token until the end of the transaction. `wtfd` calls it before every API function except `login`.
- **`logout()`** ends the current session.
- **`me()`** returns the logged-in account.
- **`password_change(p_current, p_new)`** changes the own password, and ends the account's other sessions.

Tokens are 32 random bytes, base64url-encoded. The database stores only their SHA-256 hash. A session expires after 30 days without use.

## Privileges

Every API function checks the logged-in account's privileges. Each privilege is `none`, `read_only` or `read_write`:

| Privilege | Covers |
|-----------|--------|
| `data`    | items, values, stock, locations, attachments of those, label codes, search |
| `model`   | classes, class attributes, attributes, options, attachments of classes. Reading them is also allowed with `data` read. |
| `account` | the accounts |
| `history` | reading history ([api/history.md](history.md)); `read_write` counts as `read_only` |

- **System data** (quantities, unit families, units) and the account's own information (`me`, `password_change`, `logout`) need only a login.
- **Missing privilege:** the function raises 42501, which `wtfd` turns into a 403.

## Accounts

The account privilege is needed: `read` to list and get, `write` for everything else.

- **`account_list()`** and **`account_get(p_id)`**.
- **`account_create(p_email, p_password, p_data_privilege, p_model_privilege, p_account_privilege, p_history_privilege)`**:
  - the email is unique among accounts that aren't deleted, case-insensitively;
  - a password needs at least 8 characters and at most 72 bytes;
  - without a password, the account can't log in;
  - privileges default to `none`.
- **`account_patch(p_id, p_patch)`** takes the keys `email`, `password` (null removes it), `data_privilege`, `model_privilege`, `account_privilege` and `history_privilege`. Deleted accounts can't be changed.
  - Changing the password ends the account's sessions, except the caller's own.
  - You can't remove your own `account` privilege (422).
- **`account_delete(p_id)`** marks an account deleted, so history keeps referring to it.
  - It can't log in, and it loses its password, privileges and sessions.
  - Its email can be used again.
  - `account_list` leaves it out, while `account_get` still shows it (`deleted: true`).
  - You can't delete your own account (422).
- **`account_history(p_id, …)`** shows the changes to an account (history privilege).

The first account is created with `wtfd account create`, which can also set a lost password (see [WTFD.md](../WTFD.md)).
