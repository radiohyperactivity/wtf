# Items and values

The SQL is in [`db/repeatable/40_item.sql`](../db/repeatable/40_item.sql).

## Attribute filters

`item_list`'s `p_where` (`GET /items?where=`, URL-encoded JSON) is a list of conditions, all of which must match:

```json
[
  {"attribute": "<Resistance id>", "op": "between", "value": [10000, 47000]},
  {"attribute": "<Package id>", "op": "in", "value": ["0603", "0805"]}
]
```

| Datatype | `op` | `value` |
|----------|------|---------|
| `integer`, `float` | `=`, `>`, `>=`, `<`, `<=` | a number, in the base unit (32 kΩ is `32000`) |
| | `between` | `[low, high]`, both included |
| `date` | as for numbers | `"YYYY-MM-DD"`, or `[low, high]` for `between` |
| `text`, `url` | `=` (the whole text), `contains` | text; both ignore case |
| `choice` | `=` | an option, by id or name (ignoring case) |
| | `in` | a list of options: any of them |
| `boolean` | `=` | `true` or `false` |

- **What is compared** is what the item shows: its own value, or else the class default. A per-unit attribute matches when any of the item's live stock rows does, so an item without stock never matches one.
- **An attribute that doesn't apply** to the item's class matches nothing.
- **Bad filters** are refused with 22023 (400): an operator that doesn't fit the datatype, a value of the wrong type, an option the attribute doesn't have. An unknown attribute is 404.
- **Clients convert units:** numbers are in the base unit, as everywhere in the API. The CLI and the app read "> 32kohm" or "10k..47k" and send the base-unit numbers.
