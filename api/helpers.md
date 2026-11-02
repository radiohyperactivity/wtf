# Errors and shared helpers (schemas `error` and `util`)

The building blocks the API functions share. They are not part of the API: `wtf_api` may execute only the `SECURITY DEFINER` functions of [API.md](../API.md), so only those (which run as their owner) can call them.

- **[`10_error.sql`](../db/repeatable/10_error.sql), schema `error`:** one function per kind of error, so that each keeps its SQLSTATE and the messages are alike: `error.invalid`, `error.not_found`, `error.bad_reference`, `error.duplicate`, `error.in_use`, `error.not_allowed`, `error.wrong_state`, `error.gone` (`WT001`, 410), `error.unauthenticated`, `error.forbidden`. `error.row_label` names a row as people know it ("Stock row 1026 of "Drill"").
- **[`11_util.sql`](../db/repeatable/11_util.sql), schema `util`:**
  - `util.session(p_request, p_role)`, the session and role check every API function starts with;
  - label codes: `util.take_codes`, the next codes, taken in one write of the meta row, and `util.code_text` and `util.code_value` ([code.md](code.md));
  - the trees: `util.check_move`, which refuses a move below itself, and `util.bump_version`, which moves a tree's version on, last in every change of it;
  - checks of input: names (`util.trim_and_check`, `util.trim_and_check_path_name`), patches (`util.check_patch`), page sizes (`util.check_limit`), the values of a request (`util.given_values`);
  - dry runs: `util.end_dry_run` and `util.dry_run_answer` (see [class.md](class.md));
  - paths as text (`util.path_text`).

The schemas named after what they belong to (`class`, `item`, `stock`, …) hold their own helpers beside their API functions: JSON builders such as `item.json` and `stock.detail_json`, and the checks. The checking of values against a class, which items and stock rows share, is in `class`: [attribute.md](attribute.md).

Every name in a function is written with its schema (`public.item`, `util.session`), as the API functions run with `search_path = pg_catalog, pg_temp`.

There are no triggers: nothing checks a row behind the accessors' backs. The foreign keys, `NOT NULL` and `CHECK` constraints are the guarantees; every rule that reads another row is in the accessor that writes ([2026-11-02-attributes-in-json.md](../2026-11-02-attributes-in-json.md), decisions 11 and 25).
