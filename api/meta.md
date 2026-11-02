# Database information

The SQL is in [`db/repeatable/80_meta.sql`](../db/repeatable/80_meta.sql).

- **`meta.schema_version()`** returns the applied migration version and the checksums of the applied repeatable scripts, taken from the bookkeeping of `wtfd schema` (see [WTFD.md](../WTFD.md)):

  ```json
  { "version": 2, "repeatables": { "10_error.sql": "<sha256 hex>", "11_util.sql": "…" } }
  ```

  `wtfd serve` compares this with the scripts embedded in its binary at startup, and refuses to start if they differ. It is `SECURITY DEFINER`, so `wtf_api` can call it without having any access to the `wtfd` schema. It is the one API function without a request: `wtfd` calls it for itself, before any request, and it tells nothing about the data.
