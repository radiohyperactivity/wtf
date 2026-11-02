# Items

The SQL is in [`db/repeatable/42_item.sql`](../db/repeatable/42_item.sql). Values, and how they are checked, are in [attribute.md](attribute.md).

## An item

`item.get` answers `{id, code, name, class, unit, photo}` with the class (`{id, name, path}`), `values`, `defaulted`, and the item's stock rows, by location name, each with its values.

- **`unit`** is what its stock is counted in, a label such as `"m"`; null for pieces, whose amounts are whole.
- **`photo`** is the hash of its photo's file, or null ([attachment.md](attachment.md)).
- **`item.create(p_class, p_name, p_unit, p_values)`** makes an item; its class can't be a container.
- **`item.patch(p_item, p_patch)`** changes `class`, `name`, `unit` (null: pieces, refused while a stock amount isn't whole), `photo` (null only: a photo is uploaded), and the values (`values` and `default`, [attribute.md](attribute.md)), in one transaction. In another class, its values and its stock rows' values are checked against the new class, and those that follow a default take the new class's.

## Lists

`item.list(p_class, p_search, p_where, p_limit, p_after)` (`GET /items`) is a page of the items, by name, each with its stock total: `{rows, more, next}`.

- **Paging by key:** `p_after` (`after`) is the last item of the page before; `next` is the one to give for the next page when `more` says there is one. There is no total. Every page costs about what the first one does.
- **`p_class`** (`class`): only the items of this class and the classes below it.
- **`p_search`** (`search`): words; each must occur, letter case ignored, as part of a word or whole, in the item's search text, `item.search`. It holds, in lower case, the item's name, the names of the classes in its path, and its text, url and choice values. The accessors write it with every change of the item, and a rename or a move of a class rewrites it for the items below.
- **`p_where`** (`where`, URL-encoded JSON): filters, all of which must pass.
- **What it reads:** the items in name order (the index on `item (name)`) until the page is full. A list most items pass costs little; one few pass reads more of them, at worst all.

## Filters

```json
[
  {"attribute": "Resistance", "op": "between", "value": [10000, 47000]},
  {"attribute": "Package", "op": "in", "value": ["0603", "0805"]}
]
```

| `op` | `value` |
|------|---------|
| `=` | a number, a text (letter case ignored), or `true` or `false` |
| `>`, `>=`, `<`, `<=` | a number, or a date as `"YYYY-MM-DD"` |
| `between` | `[low, high]`, both numbers or both dates, both included |
| `contains` | a text, letter case ignored |
| `in` | a list of texts (choices), letter case ignored |

- **The attribute is by name.** A filter passes when the item's value does, or one of its stock rows' values; an item without a value for it, or with a value of another kind (a text where the filter has a number), doesn't pass.
- **Bad filters** are refused with 22023 (400): an op that doesn't fit its value, a value of the wrong kind.
- **Numbers are as stored:** in the attribute's unit, which is only a label.
