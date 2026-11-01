# Errors and shared helpers (schemas `error`, `util` and `tenant`)

The building blocks the API functions share. They are not part of the API: `wtf_api` may execute only the `SECURITY DEFINER` functions of [API.md](../API.md), so only those (which run as their owner) can call them.

- **[`10_error.sql`](../db/repeatable/10_error.sql), schema `error`:** one function per kind of error, so that each keeps its SQLSTATE and the messages are alike: `error.invalid`, `error.not_found`, `error.bad_reference`, `error.duplicate`, `error.in_use`, `error.wrong_state`, `error.deleted`, `error.not_deleted`, `error.restore_into_deleted` (`WT001`, with the place key in `DETAIL`), `error.unauthenticated`, `error.forbidden`. `error.row_label` names a row as people know it ("Stock row 1026 of "Drill"").
- **[`11_util.sql`](../db/repeatable/11_util.sql), schema `util`:**
  - `util.session(p_request, p_role)`, the session and role check every API function starts with;
  - `util.begin_action`, the action a change is part of (who, when, which tenant), which history entries and deleted rows refer to;
  - the rules shared by several tables: a deleted row is frozen (`util.block_change_when_deleted`), trees have no cycles (`util.prevent_tree_cycle`), a tree's version changes with it (`util.bump_tree_version`), a reference is to a live row (`util.check_live`);
  - checks of input: names (`util.trim_and_check`, `util.trim_and_check_path_name`), patches (`util.check_patch`), paging (`util.check_paging`, `util.check_limit`), values (`util.check_values`, `util.typed_value_fits`);
  - JSON pieces: typed values (`util.typed_value_json`), `deleted` (`util.deleted_json`), paths (`util.path_text`);
  - label codes: `util.code_text` and `util.code_value` ([code.md](code.md)).
- **[`12_tenant.sql`](../db/repeatable/12_tenant.sql), schema `tenant`:** `tenant.take_codes`, the next label codes of a tenant, taken in one write.

The schemas named after what they belong to (`item`, `stock`, …) hold their own helpers beside their API functions: JSON builders such as `item.json` and `stock.detail_json`, and their rules.

Every name in a function is written with its schema (`public.item`, `util.session`), as the API functions run with `search_path = pg_catalog, pg_temp`.
