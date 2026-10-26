# Internal helpers (schema `util`)

Shared building blocks for the API functions. They live in the `util` schema and are not part of the API. `wtf_api` has no access to this schema, so only the API functions (which run as their owner, `wtf_dba`) can call them.

Helpers reference tables unqualified. They always run inside an API function, whose `search_path` is pinned to `public, pg_temp`.

The SQL is in [`db/repeatable/10_util.sql`](../db/repeatable/10_util.sql).
