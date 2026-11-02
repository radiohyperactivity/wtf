# Attributes and values

A class's attributes are in the class row, and an item's or stock row's values in its own row, both in JSON. The checks are in [`db/repeatable/31_class.sql`](../db/repeatable/31_class.sql) (schema `class`). Why it is so is [2026-11-02-attributes-in-json.md](../2026-11-02-attributes-in-json.md).

## An attribute

`class.attributes` holds every attribute the class has, by name: its own, and those it inherits from the classes above it. Each entry names the class that defines it:

```json
{
  "Length":  {"class": "<id of Tools>", "scope": "item", "type": "decimal",
              "unit": "mm", "required": true, "default": 100, "order": 1},
  "Colour":  {"class": "<id of Tools>", "scope": "item", "type": "choice",
              "choices": ["Red", "Green", "Blue"], "default": "Red", "order": 2},
  "Manual":  {"class": "<id of Drills>", "scope": "item", "type": "attachment",
              "media": ["application/pdf"], "order": 3},
  "Bought":  {"class": "<id of Tools>", "scope": "stock", "type": "date", "order": 1}
}
```

| Field | |
|-------|---|
| `scope` | `item` (the value is on the item) or `stock` (on each stock row: a purchase date, a lot number) |
| `type` | `text`, `integer`, `decimal`, `date`, `boolean`, `url`, `choice` or `attachment` |
| `required` | every item (or stock row) must have a value; `false` when left out |
| `unit` | a label for the values ("mm"), or none. Nothing converts: the user keeps to the unit |
| `default` | a value that fits; none for an attachment |
| `choices` | a choice's texts, each once, at least one |
| `media` | the media types an attachment takes, such as `["application/pdf", "image/*"]`; any when left out |
| `order` | its place on screen among the class's attributes of its scope |

- **Names** are unique in a class, with what it inherits: a class can't define a name it inherits, nor can a class above it add one that a class below defines itself.
- **A name can't be a fixed field's:** `id`, `code`, `name`, `class`, `unit`, `photo`, `item`, `location`, `amount`, `reference` or `serial`, letter case ignored. So a name means one thing everywhere: in the JSON, in filters, in file routes, and as a CLI flag.
- **`class.get`** lists the attributes as a list, the item attributes first, each by `order`, with its `name` and whether it is `inherited`.

## Values

An item's values are a JSON object by attribute name, in `item.values`; an attribute without a value is left out. Beside them, `item.defaulted` names the values that follow their class's default. Stock rows have `values` and `defaulted` the same way, for the attributes with scope `stock`.

| Type | A value |
|------|---------|
| `text`, `url` | a string, not blank; a url starts with `http://` or `https://` |
| `integer`, `decimal` | a JSON number; an integer is whole |
| `date` | a string `"YYYY-MM-DD"` |
| `boolean` | `true` or `false` |
| `choice` | one of its choices' texts |
| `attachment` | the SHA-256 of a file, as hex, put there by an upload ([attachment.md](attachment.md)) |

`class.check_values` checks a row's values against its class, for every write:

- every value is of one of the class's attributes of its scope, and fits it;
- a value that follows the default takes the class's default; when the attribute has none any more, the row has no value for it;
- an attribute without a value gets its default, and follows it, when the row is new, or when the attribute is required; a required one without a default is refused.

## Writing values

- **Creating:** `item.create(…, p_values)` and `stock.create(…, p_values)` take `{"<name>": <value>, …}`; a JSON null gives no value. Every attribute not given gets its default, and follows it.
- **Changing:** a patch (`item.patch`, `stock.patch`) takes `"values": {"<name>": <value>, …}`, where null removes a value, and `"default": ["<name>", …]`, which gives each its default and makes it follow the default again. Either way, a value set or removed no longer follows the default. The patch is one transaction, checked as a whole ([item.md](item.md)).
- **Removing a required value** gives it its default back, and refuses it when there is none.
- **A file** is uploaded, not set as a value; removing it is a patch with null.
- An item or stock row write locks its class row for sharing, its class first and then itself, so that a class change waits for it, or it for the class change.

## Changing a class's attributes

Each change is a function of its own, on the class that defines the attribute (an inherited one is changed there). Each rewrites the classes below it, and checks, and where needed rewrites, the items and stock rows below it. Each answers `{class, items, stock, dry_run}`: the class, and how many items and stock rows it wrote. With `p_dry_run`, it does all its work, undoes it, and answers what it would have done; it is refused as the change would be.

| Function | What it costs below the class |
|----------|-------------------------------|
| `class.attribute_add(p_class, p_name, p_definition)` | nothing for an optional one; a required one gets its default on every row of its scope that lacks it, and is refused without a default while there are any |
| `class.attribute_change(p_class, p_name, p_patch)` | `required`, `default`, `unit`, `order`, `media` (null removes a default, a unit or media types). A new default rewrites the values that follow it; making it required is refused while a row lacks it and there is no default. Its `type` and `scope` never change: remove it and add it again |
| `class.attribute_rename(p_class, p_name, p_new_name)` | rewrites every row that has a value for it |
| `class.attribute_remove(p_class, p_name)` | removes its values from every row |
| `class.choice_add(p_class, p_name, p_choice)` | nothing |
| `class.choice_rename(p_class, p_name, p_choice, p_new_choice)` | rewrites the rows that have it, and the default |
| `class.choice_remove(p_class, p_name, p_choice)` | refused while a row has it (409, saying how many), or while it is the default or the last choice |

Moving a class to another parent gives it and the classes below it what they inherit from their new place, and checks every row below it the same way (`class.patch`, [class.md](class.md)).
