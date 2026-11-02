# Model files

A model file describes part of an installation's model in JSON: a tree of classes with their attributes, set up for one use. An "MCU" model, say, has clock, RAM, flash, GPIO pins and timers. Importing one sets up that part of the model in one go. Exporting a class writes one, with everything below the class, so that another installation can import it.

- **Import:** Manage → Import in the app; `wtf model import FILE` in the CLI; `POST /api/v1/model/import`.
- **Export:** a class's menu → Export as a model file in the app; `wtf model export CLASS` in the CLI; `GET /api/v1/classes/{id}/model`.
- **Example:** [models/mcu.json](models/mcu.json), a model of microcontrollers.

"Model" is WtF's word for classes and their attributes, as against the data: items, stock and locations. A model file carries no data. Version 2 of the format, from 2 November 2026, has a class's attributes in the same JSON as the database keeps them ([2026-11-02-attributes-in-json.md](../2026-11-02-attributes-in-json.md), decision 31); version 1, with units and separate attributes, is no longer read.

## An example

```json
{
  "format": "wtf-model",
  "version": 2,
  "meta": { "name": "Microcontrollers", "description": "MCUs by family, with what tells them apart." },
  "classes": [
    {
      "name": "MCU",
      "container": true,
      "attributes": {
        "Clock":     { "scope": "item", "type": "decimal", "unit": "MHz", "required": true, "order": 1 },
        "Flash":     { "scope": "item", "type": "integer", "unit": "KiB", "order": 2 },
        "Package":   { "scope": "item", "type": "choice", "choices": ["DIP", "SOIC", "TQFP", "QFN"],
                       "default": "DIP", "order": 3 },
        "Datasheet": { "scope": "item", "type": "url", "order": 4 },
        "Programmed with": { "scope": "stock", "type": "text", "order": 1 }
      },
      "classes": [
        { "name": "AVR" },
        { "name": "ARM" }
      ]
    }
  ]
}
```

Importing it adds the classes MCU, MCU/AVR and MCU/ARM, and MCU's five attributes, which AVR and ARM inherit. "Programmed with" is on each stock row: what a chip was programmed with.

## The file

The file is a JSON object (UTF-8):

| Key | | |
|-----|-|-|
| `format` | required | Always `"wtf-model"`. Tells a model file from any other JSON. |
| `version` | required | The version of this format: `2`. |
| `meta` | optional | About the file, for people: never read by an import. Apps show its `name` and `description`; an export writes the class's `name`. |
| `classes` | optional | The top classes it defines, below; each may have classes of its own. |

### A class

| Key | | |
|-----|-|-|
| `name` | required | Its name, without "/". |
| `container` | optional | `true`: it holds only other classes, no items. |
| `attributes` | optional | The attributes it defines, by name, each a definition as [api/attribute.md](../api/attribute.md) describes: `scope`, `type`, `required`, `unit`, `default`, `choices`, `media` and `order`. |
| `classes` | optional | The classes below it, of the same form. |

A class's attributes are inherited by the classes below it, and a class can't define a name it inherits. An attribute's name can't be that of a fixed field (`name`, `class`, `unit`, `photo`, `amount`, `reference`, `serial`, …). Any key that isn't in these tables is refused.

## Importing

- **Where:** at the top of the class tree, or below a class (`parent`).
- **Matching by name:** a class by its name below its parent, ignoring case; an attribute by its name in the class.
- **A class that is there already is imported into:** it gets the attributes it hasn't got, and its classes from the file, the same way. Its `container` stays as it is.
- **An attribute that is there already must be the same** (all but its `order`), or the import is refused (409, saying which).
- **What is there and the same is used as it is.** Importing a file twice changes nothing the second time.
- **Into a class with items:** a required attribute with a default gives its default to every item (or stock row) below the class, and one without a default is refused while there are any, as a change of the class is ([api/attribute.md](../api/attribute.md)).
- **All or nothing.** The first problem refuses the whole file; nothing is kept.
- **A dry run** tells what would be added and what is there already, without keeping anything.
- **The answer:** `{classes: {added, existing}, attributes: {added, existing}, items, stock, dry_run}`, `items` and `stock` being how many rows below classes that were there already it wrote.
- **Who:** an admin ([ACCOUNTS.md](../ACCOUNTS.md)).
- **A file that isn't valid** is refused (400), saying where: a missing key, an unknown key, a definition that doesn't hold, or a version this WtF doesn't read.

## Exporting

An export is of one class, with everything below it:

- **The class** is the file's only top class, with every attribute it has: its own, and the ones it inherits, as its own, so that the file stands on its own.
- **The classes below it** have their own attributes.
- **Who:** an admin, as only admins can import the file again.

So importing the file where the class is changes nothing, and importing it elsewhere sets up the same classes and attributes: exported again from there, the file is the same.

## Future-proofing

1. **`format` and `version`** come first in every file. A WtF reads the versions it knows, and refuses others, rather than misreading them.
2. **Unknown keys are refused,** outside `meta`. A later version might add a key that changes what an attribute means; an older WtF that ignored it would import something else without saying so.
3. **Names, not ids,** connect a file to what is already there, so a file works in every installation.
