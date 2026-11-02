# Label codes

The SQL is in [`db/repeatable/81_code.sql`](../db/repeatable/81_code.sql), with `util.take_codes`, `util.code_text` and `util.code_value` in [`db/repeatable/11_util.sql`](../db/repeatable/11_util.sql).

Every location, item and stock row has a short code for labels (QR codes, barcodes or printed text), e.g. `1A7K`. Codes are:

- **Generated:** each new location, item or stock row gets the next number (`meta.code` is the last one handed out; `util.take_codes` takes the next ones in one write of the meta row), one counter for all three types. Codes are never chosen or changed by users.
- **Unique:** a code identifies exactly one object of any of the three types.
- **Crockford Base32:** the digits `0-9` and the letters `A-Z` without `I`, `L`, `O` and `U`. The first code is `1000` (32768). Codes have four characters until `ZZZZ`, about a million codes later, and five after that.

In the database a code is stored as the number (`code bigint`, unique per table). Every location, item and stock object in the API carries it as text in `code`, and so does every node of the location tree.

- **`code.resolve(p_code)`** (`GET /codes/{code}`) returns what a code belongs to:

  ```json
  { "type": "location", "object": { "id": "…", "code": "1A7K", "name": "Bin 4", … } }
  ```

  `type` is `location`, `item` or `stock`, and `object` is what the matching `get` function returns. Lower case and hyphens are accepted (`1a-7k`). The letters `I`, `L`, `O` and `U` are rejected (400). Clients map `I` and `L` to `1`, and `O` to `0`, before sending, as Crockford's scheme intends. An unknown code is a 404.

A deleted object's code answers 410 Gone (`/problems/gone`): every code from `1000` up to `meta.code` was given to an item, location or stock row, so a code up to it that nothing has belonged to something deleted. A code above it was never handed out, and is 404. A code is never reused. A stock row merged entirely into another (`stock.merge`) is deleted, so its code answers 410 too.
