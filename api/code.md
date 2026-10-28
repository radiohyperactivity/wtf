# Label codes

The SQL is in [`db/repeatable/70_code.sql`](../db/repeatable/70_code.sql), with the encoding helpers `util.code_text` and `util.code_value` in [`db/repeatable/10_util.sql`](../db/repeatable/10_util.sql).

Every location, item and stock row has a short code for labels (QR codes, barcodes or printed text), e.g. `1A7K`. Codes are:

- **Generated:** each new location, item or stock row gets the next number of its tenant (`tenant.next_code`), one counter for all three types. Codes are never chosen or changed by users.
- **Unique within the tenant:** a code identifies exactly one object of any of the three types. Every tenant's codes start at `1000`, so two tenants have the same codes for different things; looking a code up searches only your own tenant ([TENANTS.md](../TENANTS.md)).
- **Crockford Base32:** the digits `0-9` and the letters `A-Z` without `I`, `L`, `O` and `U`. The first code is `1000` (32768). Codes have four characters until `ZZZZ`, about a million codes later, and five after that.

In the database a code is stored as the number (`code bigint`). Every location, item and stock object in the API carries it as text in `code`, and so does every node of the location tree.

- **`code_resolve(p_code)`** (`GET /codes/{code}`) returns what a code belongs to:

  ```json
  { "type": "location", "object": { "id": "…", "code": "1A7K", "name": "Bin 4", … } }
  ```

  `type` is `location`, `item` or `stock`, and `object` is what the matching `_get` function returns. Lower case and hyphens are accepted (`1a-7k`). The letters `I`, `L`, `O` and `U` are rejected (400). Clients map `I` and `L` to `1`, and `O` to `0`, before sending, as Crockford's scheme intends. An unknown code is a 404.

A deleted object's code still resolves, to the object with `deleted: true` (see [deleting.md](deleting.md)); a code is never reused. A stock row that `stock_move` merges into another row is deleted, and its code resolves to it with `merged_into`, the row it went into. A row split off by a partial move is new, and gets a new code.
