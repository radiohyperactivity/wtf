# Model files

A model file describes part of an inventory's model in JSON: quantities and units, attributes, and a tree of classes that use them, set up for one use. An "MCU" model, say, has clock, RAM, flash, GPIO pins and timers. Importing one sets up that part of the model in one go. Exporting a class writes one, with everything below the class and everything it needs, so that another inventory can import it.

- **Import:** Manage → Import in the app; `wtf model import FILE` in the CLI; `POST /api/v1/model/import`.
- **Export:** a class's menu → Export as a model file in the app; `wtf model export CLASS` in the CLI; `GET /api/v1/classes/{id}/model`.
- **Examples:** [models/mcu.json](models/mcu.json), a model of microcontrollers; [units.json](units.json), the units every WtF starts with.

"Model" is WtF's word for units, classes and attributes, as against the data: items, stock and locations. A model file carries no data. What units are, and how numbers are stored and shown, is explained in [units.md](units.md).

## An example

```json
{
  "format": "wtf-model",
  "version": 1,
  "meta": { "name": "Microcontrollers", "description": "MCUs by family, with what tells them apart." },
  "quantities": [
    {
      "name": "Data rate",
      "base_unit": { "symbol": "bit/s", "name": "bit per second" },
      "families": [
        {
          "name": "Bit rates",
          "units": [
            { "symbol": "bit/s", "name": "bit per second", "factor": "1" },
            { "symbol": "kbit/s", "name": "kilobit per second", "factor": "1000" },
            { "symbol": "Mbit/s", "name": "megabit per second", "factor": "1000000" }
          ]
        }
      ]
    }
  ],
  "attributes": [
    { "name": "Clock", "unit": "MHz" },
    { "name": "Flash", "unit": "KiB" },
    { "name": "RAM", "unit": "KiB" },
    { "name": "GPIO pins", "datatype": "integer" },
    { "name": "Package", "datatype": "choice", "options": ["DIP", "SOIC", "TQFP", "QFN"] },
    { "name": "USB speed", "unit": "Mbit/s" },
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
        { "attribute": "USB speed" },
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

Importing it adds the quantity Data rate with its units, then the seven attributes and the classes MCU, MCU/AVR and MCU/ARM. USB speed is in one of the new units. AVR and ARM inherit MCU's attributes, and AVR has its own assignment of Clock, with a default of 16 MHz.

## The file

The file is a JSON object (UTF-8). Every key is optional except `format` and `version`:

| Key | | |
|-----|-|-|
| `format` | required | Always `"wtf-model"`. Tells a model file from any other JSON. |
| `version` | required | The version of this format: `1`. |
| `meta` | optional | About the file, for people: never read by an import. See below. |
| `quantities` | optional | Quantities with their unit families and units, below. They are imported first, so attributes can use them. |
| `attributes` | optional | The attributes the file defines, below. |
| `classes` | optional | The top classes it defines, below; each may have classes of its own. |

### `meta`

Anything about the file that isn't to be imported goes in `meta`: who made it, from what, when. An import never reads it, and anything may be in it. Every object of the file (a quantity, a unit, an attribute, a class, an assignment) may have a `meta` of its own as well, for notes: `"meta": {"source": "NIST SP 811"}`.

Apps show these keys of the top `meta` when there are any:

| Key | |
|-----|-|
| `name` | What the file is: "Microcontrollers". The app's import dialog shows it. |
| `description` | More about it. |

An export writes:

| Key | |
|-----|-|
| `name` | The exported class's name. |
| `class` | Its path where it was exported from: "MCU/AVR". |
| `exported_from` | The tenant it was exported from, by host. |
| `exported_at` | When, to the second. |

### A quantity

| Key | | |
|-----|-|-|
| `name` | required | "Length", "Pressure". Unique, ignoring case. |
| `datatype` | optional | `"float"` (the default) or `"integer"`, for quantities that are counted, such as pieces. |
| `base_unit` | required | `{"symbol", "name"}` of the unit that numbers are stored in. Every factor in the file is relative to it. |
| `families` | optional | A list of unit families. |

The base unit doesn't have to be in a family. Charge is stored in coulombs, but its only family, Battery capacity, has mAh and Ah. When a unit has the base unit's symbol, its factor must be 1 and its offset 0.

### A unit family

| Key | | |
|-----|-|-|
| `name` | required | "Metric length", "Pascals". Unique among all families, ignoring case. |
| `units` | optional | A list of units. |

A family is the set of units that a number is scaled between on output: 1500 Pa is shown as 1.5 kPa. Put units in a family only when they are naturally used together (see [units.md](units.md)).

### A unit

| Key | | |
|-----|-|-|
| `symbol` | required | "kPa". Unique within its family, and case matters (`mS` isn't `ms`). |
| `name` | required | "kilopascal". Unique within its family, ignoring case. |
| `factor` | required | How many base units one of this unit is. More than 0. |
| `offset` | optional | Added after the factor; only temperatures need it. Default 0. |

A number in this unit converts to the base unit as `base = value × factor + offset`. °C has factor 1 and offset 273.15, because the base unit of temperature is the kelvin.

Factors and offsets are decimals, preferably written as text: `"0.55555555555555555556"`. JSON numbers work too, but many programs read them into a double and lose digits. Units within a family may be in any order; WtF sorts them by size.

### An attribute

| Key | | |
|-----|-|-|
| `name` | required | Its name. |
| `datatype` | see below | `text`, `integer`, `float`, `date`, `boolean`, `url` or `choice`. Without a unit it is required; with one it may be left out, and must otherwise be the unit's quantity's (`float`, or `integer` for counts). |
| `unit` | optional | For numbers: the unit they are entered and shown in, by symbol (`"MHz"`) or name (`"megahertz"`). A symbol that several families share needs its family: `"B (Binary bytes)"`. It must be a unit the inventory has available, or one the file brings. |
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

Any key that isn't in these tables (or `meta`) is refused.

## Importing

- **In order:** the quantities and units first, then the attributes, then the classes, so that each can use what came before.
- **Matching by name:**
  - quantities and unit families by name, ignoring case, among the global ones and the tenant's own;
  - a unit by its symbol, within its family;
  - an attribute by name, ignoring case;
  - a class by its name below its parent. The file's top classes go at the top of the class tree, or below a class you choose.
- **What is there and the same is used as it is.** Importing a file twice changes nothing the second time.
- **What isn't there yet is added,** as the tenant's own: quantities, families, units, attributes, options, classes and assignments. A family may be added to a global quantity, and a unit to a global family.
- **An assignment that is the same as one the class inherits** is there already. One that differs is added to the class, and overrides the inherited one.
- **What is there must agree, or it is a conflict:**
  - a quantity's datatype and base unit; the quantity a family belongs to; a unit's name, factor and offset;
  - an attribute's datatype, and whether it has a unit and of which quantity;
  - a class's `container`;
  - an assignment the class itself has of that attribute: `per_unit`, `required` and `default`.
- **Other conflicts:**
  - a unit that isn't there, isn't available, or needs its family named;
  - a unit name that another unit of the family has already;
  - a symbol that means a different unit in another family of the same quantity. `B` is in both byte families, but only because both mean one byte;
  - an assignment of an attribute that neither the file nor the inventory has;
  - a default that doesn't fit its attribute;
  - whatever else the model's rules refuse.
- **All or nothing.** With any conflict nothing in the file is imported, and every conflict is reported, so a file can be fixed in one go.
- **A dry run** tells what would be added, what is there already and what conflicts, without keeping anything.
- **Who:** an admin (ACCOUNTS.md).
- **A file that isn't valid** is refused (400), saying where: a missing key, an unknown key, a name that appears twice, a factor that isn't a number, or a version this WtF doesn't read.
- **Global units:** the operator imports a file of only quantities as units every tenant sees, with `wtfd unit import --global FILE` ([WTFD.md](../WTFD.md)). A name that some tenant already has for its own is a conflict.

## Exporting

An export is of one class, with everything below it:

- **Classes:** the class and the live classes below it. The class is the file's only top class; where it was is in `meta`.
- **Assignments:** each class's own. The top class also has the ones it inherits, as its own, so that the file stands on its own.
- **Attributes:** every attribute the assignments use, with its datatype, unit, unit lock and live options.
- **Units:** the tenant's own units that the attributes need, with the family they are in and its quantity. All of the tenant's units in such a family go in, not only the one used: the family decides how values are shown. A family that is global is named, with only the tenant's units in it. Units every WtF has are left out.
- **Defaults** are in the attribute's unit, as an import reads them.
- **Who:** an admin, as only admins can import the file again (ACCOUNTS.md).

So importing the file where the class is changes nothing, and importing it into another inventory sets up the same classes, attributes and units: exported again from there, the file is the same apart from `meta`.

## Future-proofing

How the format is meant to grow without breaking old files or old servers:

1. **`format` and `version`** come first in every file. A WtF reads the versions it knows, and refuses newer ones with "made for a newer WtF", rather than misreading them.
2. **Unknown keys are refused,** outside `meta`. Refusing them is deliberate: a later version might add a key that changes what a unit means, such as a scale that isn't linear (dB). An older WtF that ignored that key would import wrong numbers without saying so.
3. **Additions that change nothing old** can stay at version 1, but only once every WtF that might read them knows them. Anything an older WtF must not ignore raises the version. While WtF is being developed, the format changes at version 1.
4. **Names, not ids,** connect a file to what is already there, so a file works in every installation.
5. **Exact decimals as text,** so no factor loses digits on the way.
6. **The base unit is in the file,** so a file can't add units to a quantity it measures differently. One that counts Length in mm would turn every stored metre into a millimetre.
7. **Version 1 leaves room** for things that may come later, without guessing at them now: translated names (`"names": {"nb": "meter"}`), other spellings of a symbol (`"aliases": ["ohm"]`), non-linear units.

## Decisions to discuss

Made while you were away; each is easy to change.

### Unit files (2026-10-27)

These were made for unit files, which are now the `quantities` of a model file.

1. **The quantity's base unit is stored** (migration `0003_base_units.sql`, `base_unit` in the API's quantities). Without it, an import couldn't check point 6 above.
2. **A unit is matched by symbol, not name,** within its family. Symbols are what people type; a unit whose name differs in more than case is a conflict.
3. **Family names are unique across all quantities,** as they already were in the database. A file can't have two families both named "Imperial" for different quantities; they must be "Imperial length" and "Imperial weight".
4. **Adding units to an existing family is allowed** (a hand to Imperial length). Nothing existing changes. Note that it changes how numbers are scaled on output: with yards in Imperial length, 4 ft would show as 1.33 yd. That is why the bootstrap set leaves them out ([units.md](units.md)).
5. **An imported unit can't be removed** through the API, the same as the bootstrap units. If that turns out to be needed, it would be a "delete unit, if nothing uses it" action, outside the file format.
6. **Conflicts are reported in the answer (200, `applied: false`), not as an error,** so a client can show all of them. Only a file that isn't valid is an error (400).
7. **The bootstrap set as a file** ([units.json](units.json)) is generated from migration `0002_units.sql`. A test imports it and checks that it changes nothing, so the two can't drift apart.

### Model files (2026-10-28)

8. **The name is "model file"** (yours, from my suggestions), with `"format": "wtf-model"`.
9. **Attributes are defined once, at the top, and classes refer to them by name.** An attribute belongs to the inventory, not to a class: the same Clock can be on MCUs and on crystals. Assignments are where a class says how it uses it (per unit, required, default).
10. **An assignment may name an attribute the file doesn't define** but the inventory has. A file can then build on what is there ("Colour"), without repeating it. If neither has it, that is a conflict, not an invalid file, so it is reported with the rest.
11. **Units are named as the CLI takes them:** a symbol or a name, with the family in brackets where a symbol is in several families. Unit ids differ between installations, so files can't use them. The unit must be available, or in the file.
12. **An existing attribute agrees** when its datatype is the same and its unit is of the same quantity. A different unit of the same quantity (mm against cm), or a different unit lock, is not a conflict: the existing attribute stays as it is, since that only changes how values are shown. The file's unit is still the one its numbers (defaults) are in.
13. **Choice options are added to an existing attribute** when the file has options it lacks. Options aren't removed, and an option the attribute has but the file doesn't is fine.
14. **Defaults are in the file's units** (16 for 16 MHz), not in the base unit as the API takes them. That is how people write them; the import converts.
15. **Existing classes are reused and added to,** not refused: importing "MCU" when there is an MCU class adds what it lacks below it and in its assignments. That is what makes importing twice a no-op, and lets a second file extend what a first set up. A class that differs in `container` is a conflict.
16. **An assignment on a class whose parent assigns the same attribute** is allowed: it overrides the inherited one, as in the example (AVR's own Clock).
17. **Nothing that exists changes,** apart from added options and added assignments. Names keep their case as they are; a class isn't moved; nothing is deleted.
18. **Conflicts are found by trying,** in a subtransaction that is rolled back when there are any (or for a dry run). The database's own rules then decide, exactly as for the API, and nothing is kept. To you this is the same as checking first: nothing starts unless everything fits.
19. **Where to import:** at the top of the class tree, or below a class (`parent`): the app's preview has Change… for it (APP.md decision 67), and the CLI has `--parent CLASS`.
20. **Everything is in history,** as if it had been made by hand by the account that imported the file.

### Units in model files, and exporting (2026-10-29)

21. **Unit files are gone; model files hold units** (your idea), in `quantities`, of the form unit files had. A file of only quantities is how units are imported now. There is one import, `POST /model/import`: `POST /units/import` and `wtf unit import` are gone, and the Units screen's Import imports a model file. The operator's `wtfd unit import --global` takes a model file of only quantities.
22. **`meta` instead of `x-` keys** (your idea): one key for what isn't to be imported, at the top and on any object. `name` and `description` moved into it, since an import never kept them. `x-` keys are refused like any other unknown key.
23. **The version stays 1** while WtF is being developed (yours).
24. **Export is of one class and everything below it** (yours; "single root" for now). The file's one top class is that class.
25. **The top class's inherited assignments are written as its own,** so the file holds everything the class has. To make that round-trip, import now treats an assignment that is the same as an inherited one as there already (point "An assignment that is the same as one the class inherits" above). Before, it added it as an override that changed nothing.
26. **Only the tenant's own units go in the file.** Global units are in every WtF; a global unit that the other inventory has turned off is a conflict there, which tells what to turn on.
27. **All of the tenant's units in a needed family go in,** not just the used one, because together they decide how values are scaled when shown.
28. **Every attribute has its `datatype` in an export,** also with a unit, where an import lets it be left out: explicit is easier to read.
29. **A unit is named by symbol,** with its family in brackets only where the symbol alone could mean another unit in the exporting inventory ("B (Binary bytes)").
30. **Options are exported in natural order** (DIP4 before DIP10), as the API lists them; options have no order of their own.
31. **The keys come in the order of this document,** by building the export as `json`, not `jsonb` (which sorts keys by length). `wtf model export` indents it.
32. **Defaults are rounded to 15 significant digits** when converted to the attribute's unit, so that 16 MHz comes out as 16 and not 15.999999999999998.
33. **The app saves an export as "CLASS.json"**, through the same save dialog (or browser download) as attachments. Anyone who sees the class can export it, so the class's menu is there for read-only accounts too, with only Export in it.
34. **API revision 12:** `GET /classes/{id}/model` is new, and `POST /units/import` is gone. Removing a route is against the "only ever adds" rule for revisions; while nothing outside this repository uses the API, I took that to be fine.
35. **Not built:** exporting the whole class tree, or units on their own (from the Units screen).
