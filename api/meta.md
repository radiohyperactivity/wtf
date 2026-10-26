# Database information

The SQL is in [`db/repeatable/60_meta.sql`](../db/repeatable/60_meta.sql).

- **`schema_version()`** returns the applied migration version and the checksums of the applied repeatable scripts, taken from the bookkeeping of `wtfd schema` (see [WTFD.md](../WTFD.md)):

  ```json
  { "version": 2, "repeatables": { "10_util.sql": "<sha256 hex>", "20_attribute.sql": "…" } }
  ```

  `wtfd serve` compares this with the scripts embedded in its binary at startup, and refuses to start if they differ. It is `SECURITY DEFINER`, so `wtf_api` can call it without having any access to the `wtfd` schema.
