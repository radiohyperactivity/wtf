# Model files

A model file describes attributes and a tree of classes that use them, set up for one use: an "MCU" model with clock, RAM, flash, GPIO pins and timers, say. Importing one sets up that part of the model in one go: Classes → Import in the app, `wtf model import FILE` in the CLI, or `POST /api/v1/model/import`. An example: [models/mcu.json](models/mcu.json).

"Model" is WtF's word for classes and attributes (the model privilege), as against the data: items, stock and locations. A model file carries no data.

## An example

```json
{
  "format": "wtf-model",
  "version": 1,
  "name": "Microcontrollers",
  "description": "MCUs by family, with what tells them apart.",
  "attributes": [
    { "name": "Clock", "unit": "MHz" },
    { "name": "Flash", "unit": "KiB" },
    { "name": "RAM", "unit": "KiB" },
    { "name": "GPIO pins", "datatype": "integer" },
    { "name": "Package", "datatype": "choice", "options": ["DIP", "SOIC", "TQFP", "QFN"] },
    { "name": "Datasheet", "datatype": "url" }
  ],
  "classes": [
    {
      "name": "MCU",
      "container": true,
      "attributes": [
        { "attribute": "Clock", "required": true },
        { "attribute": "Flash" },
        { "attribute": "RAM" },
        { "attribute": "GPIO pins" },
        { "attribute": "Package", "default": "DIP" },
        { "attribute": "Datasheet" }
      ],
      "classes": [
        { "name": "AVR", "attributes": [{ "attribute": "Clock", "required": true, "default": 16 }] },
        { "name": "ARM" }
      ]
    }
  ]
}
```

Importing it adds the six attributes and the classes MCU, MCU/AVR and MCU/ARM. AVR and ARM inherit MCU's attributes, and AVR has its own assignment of Clock, with a default of 16 MHz.

## The file

The file is a JSON object (UTF-8):

| Key | | |
|-----|-|-|
| `format` | required | Always `"wtf-model"`. Tells a model file from any other JSON. |
| `version` | required | The version of this format: `1`. |
| `name` | optional | What the file is, for people: "Microcontrollers". |
| `description` | optional | More about it. |
| `attributes` | optional | The attributes it defines, below. |
| `classes` | optional | The top classes it defines, below; each may have classes of its own. |

### An attribute

| Key | | |
|-----|-|-|
| `name` | required | Its name. |
| `datatype` | see below | `text`, `integer`, `float`, `date`, `boolean`, `url` or `choice`. Without a unit it is required; with one it may be left out, and must otherwise be the unit's quantity's (`float`, or `integer` for counts). |
| `unit` | optional | For numbers: the unit they are entered and shown in, by symbol (`"MHz"`) or name (`"megahertz"`). A symbol that several families share needs its family: `"B (Binary bytes)"`. It must be a unit the inventory has available. |
| `unit_lock` | optional | `true`: always show values in the unit, instead of scaling them within its family. Only with a unit. |
| `options` | for `choice` | The options, as text. Only for choice attributes. |

### A class

| Key | | |
|-----|-|-|
| `name` | required | Its name, without "/". |
| `container` | optional | `true`: it holds only other classes, no items. |
| `attributes` | optional | Its attribute assignments, below. |
| `classes` | optional | The classes below it, of the same form. |

### An assignment

| Key | | |
|-----|-|-|
| `attribute` | required | An attribute's name: one in the file, or one the inventory has. |
| `per_unit` | optional | `true`: values live on stock rows instead of items. |
| `required` | optional | `true`: new items (or stock rows) need a value, unless there is a default. |
| `default` | optional | The class's default: text, `true`/`false`, a date as `"YYYY-MM-DD"`, an option's name, or a number in the attribute's unit (16 for 16 MHz). |

Keys of your own start with `x-` and are ignored anywhere, as in [unit files](units-format.md). Any other key is refused.

## Importing

- **Matching by name:** an attribute whose name the inventory has (ignoring case) is that attribute. A class whose name its parent already has below it is that class. The file's top classes go at the top of the class tree, or below a class you choose.
- **What is there and the same is used as it is.** Importing a file twice changes nothing the second time.
- **What isn't there yet is added:** attributes, their options, classes, and assignments.
- **What is there must agree, or it is a conflict:**
  - an attribute's datatype, and whether it has a unit and of which quantity;
  - a class's `container`;
  - an assignment the class already has of that attribute: `per_unit`, `required` and `default`.
- **Other conflicts:** a unit that isn't there, isn't available, or needs its family named; an assignment of an attribute that neither the file nor the inventory has; a default that doesn't fit its attribute; and whatever else the model's rules refuse.
- **All or nothing.** With any conflict nothing in the file is imported, and every conflict is reported, so a file can be fixed in one go.
- **A dry run** tells what would be added, what is there already and what conflicts, without keeping anything.
- **Who:** an account with the model write privilege.
- **A file that isn't valid** is refused (400), saying where: a missing key, an unknown key, a name that appears twice, or a version this WtF doesn't read.

## Decisions to discuss

Made while you were asleep (2026-10-28); each is easy to change.

1. **The name is "model file"** (yours, from my suggestions), with `"format": "wtf-model"`, after unit files (`"wtf-units"`).
2. **Attributes are defined once, at the top, and classes refer to them by name.** An attribute belongs to the inventory, not to a class: the same Clock can be on MCUs and on crystals. Assignments are where a class says how it uses it (per unit, required, default).
3. **An assignment may name an attribute the file doesn't define** but the inventory has. A file can then build on what is there ("Colour"), without repeating it. If neither has it, that is a conflict, not an invalid file, so it is reported with the rest.
4. **Units are named as the CLI takes them:** a symbol or a name, with the family in brackets where a symbol is in several families. Unit ids differ between installations, so files can't use them. The unit must be available; a file can't bring units of its own (that is what unit files are for).
5. **An existing attribute agrees** when its datatype is the same and its unit is of the same quantity. A different unit of the same quantity (mm against cm), or a different unit lock, is not a conflict: the existing attribute stays as it is, since that only changes how values are shown. The file's unit is still the one its numbers (defaults) are in.
6. **Choice options are added to an existing attribute** when the file has options it lacks. Options aren't removed, and an option the attribute has but the file doesn't is fine.
7. **Defaults are in the file's units** (16 for 16 MHz), not in the base unit as the API takes them. That is how people write them; the import converts.
8. **Existing classes are reused and added to,** not refused: importing "MCU" when there is an MCU class adds what it lacks below it and in its assignments. That is what makes importing twice a no-op, and lets a second file extend what a first set up. A class that differs in `container` is a conflict.
9. **An assignment on a class whose parent assigns the same attribute** is allowed: it overrides the inherited one, as in the example (AVR's own Clock).
10. **Nothing that exists changes,** apart from added options and added assignments. Names keep their case as they are; a class isn't moved; nothing is deleted.
11. **Conflicts are found by trying,** in a subtransaction that is rolled back when there are any (or for a dry run). The database's own rules then decide, exactly as for the API, and nothing is kept. To you this is the same as checking first: nothing starts unless everything fits.
12. **Where to import:** at the top of the class tree, or below a class (`parent`): the class's menu has "Import a model here" in the app, and the CLI has `--parent CLASS`.
13. **Everything is in history,** as if it had been made by hand by the account that imported the file.
14. **Not built:** exporting classes as a model file, and model files that bring their own units (a unit file imported first does that).
