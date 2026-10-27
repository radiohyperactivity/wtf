# Unit files

A unit file describes quantities, unit families and units in JSON, for importing them into WtF: Manage → Units → Import in the app, `wtf unit import FILE` in the CLI, or `POST /api/v1/units/import`. The units WtF starts with are in this format too: [units.json](units.json).

What units are, and how numbers are stored and shown, is explained in [units.md](units.md).

## An example

```json
{
  "format": "wtf-units",
  "version": 1,
  "name": "Pressure",
  "description": "Pascals and bars, for tyres and compressors.",
  "quantities": [
    {
      "name": "Pressure",
      "base_unit": { "symbol": "Pa", "name": "pascal" },
      "families": [
        {
          "name": "Pascals",
          "units": [
            { "symbol": "Pa", "name": "pascal", "factor": "1" },
            { "symbol": "kPa", "name": "kilopascal", "factor": "1000" },
            { "symbol": "MPa", "name": "megapascal", "factor": "1000000" }
          ]
        },
        {
          "name": "Bar",
          "units": [
            { "symbol": "mbar", "name": "millibar", "factor": "100" },
            { "symbol": "bar", "name": "bar", "factor": "100000" }
          ]
        }
      ]
    },
    {
      "name": "Length",
      "base_unit": { "symbol": "m", "name": "metre" },
      "families": [
        {
          "name": "Imperial length",
          "units": [{ "symbol": "yd", "name": "yard", "factor": "0.9144" }]
        }
      ]
    }
  ]
}
```

The second quantity, Length, exists already, and so does its family Imperial length. Importing the file adds the quantity Pressure with its two families, and the yard to Imperial length.

## The file

The file is a JSON object (UTF-8):

| Key | | |
|-----|-|-|
| `format` | required | Always `"wtf-units"`. Tells a unit file from any other JSON. |
| `version` | required | The version of this format: `1`. |
| `name` | optional | What the file is, for people. |
| `description` | optional | More about it, for people. |
| `quantities` | required | A list of quantities. |

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

## Importing

- **Matching by name:** a quantity or family whose name is already in WtF (ignoring case) is that quantity or family. A unit is matched by its symbol within its family.
- **What isn't there yet is added,** with new ids. Ids aren't in the file, because they differ between installations.
- **What is there already must be the same:**
  - a quantity's datatype and base unit symbol;
  - the quantity a family belongs to;
  - a unit's name (ignoring case), factor and offset.

  If something differs, that is a conflict.
- **Other conflicts:**
  - a unit name that another unit of the family has already;
  - a symbol that means a different unit in another family of the same quantity. `B` is in both byte families, but only because both mean one byte.
- **Nothing that exists is ever changed or removed.** Stored numbers depend on factors, and attributes and items depend on units.
- **All or nothing.** With any conflict, nothing in the file is imported, and every conflict is reported, so a file can be fixed in one go.
- **A dry run** tells what would be added, what is there already and what conflicts, without keeping anything.
- **Who:** an account with the model write privilege.
- **A file that isn't valid** is refused, saying where: a missing key, an unknown key, a factor that isn't a number, or a version this WtF doesn't read.

## Future-proofing

How the format is meant to grow without breaking old files or old servers:

1. **`format` and `version`** come first in every file. A WtF reads the versions it knows, and refuses newer ones with "made for a newer WtF", rather than misreading them.
2. **Unknown keys are refused,** except keys of your own, which start with `x-` (`"x-source": "NIST SP 811"`). Those are ignored, anywhere in the file. Refusing the rest is deliberate: a later version might add a key that changes what a unit means, such as a scale that isn't linear (dB). An older WtF that ignored that key would import wrong numbers without saying so.
3. **Additions that change nothing old** can stay at version 1, but only once every WtF that might read them knows them. Anything an older WtF must not ignore raises the version.
4. **Names, not ids,** connect a file to what is already there, so a file works in every installation.
5. **Exact decimals as text,** so no factor loses digits on the way.
6. **The base unit is in the file,** so a file can't add units to a quantity it measures differently. One that counts Length in mm would turn every stored metre into a millimetre.
7. **Version 1 leaves room** for things that may come later, without guessing at them now:
   - translated names (`"names": {"nb": "meter"}`);
   - other spellings of a symbol (`"aliases": ["ohm"]`; the clients already accept a few by themselves);
   - non-linear units;
   - exporting what an installation has, as a unit file.

## Decisions to discuss

Made while you were away; each is easy to change.

1. **The quantity's base unit is now stored** (migration `0003_base_units.sql`, `base_unit` in the API's quantities, API revision 5). Without it, an import couldn't check point 6 above.
2. **A unit is matched by symbol, not name,** within its family. Symbols are what people type; a unit whose name differs in more than case is a conflict.
3. **Family names are unique across all quantities,** as they already were in the database. A file can't have two families both named "Imperial" for different quantities; they must be "Imperial length" and "Imperial weight".
4. **Adding units to an existing family is allowed** (the yard in the example). Nothing existing changes. Note that it changes how numbers are scaled on output: with yards in Imperial length, 4 ft would show as 1.33 yd. That is why the bootstrap set leaves them out ([units.md](units.md)).
5. **An imported unit can't be removed** through the API, the same as the bootstrap units. If that turns out to be needed, it would be a "delete unit, if nothing uses it" action, outside the file format.
6. **Conflicts are reported in the answer (200, `applied: false`), not as an error,** so a client can show all of them. Only a file that isn't a valid unit file is an error (400).
7. **The bootstrap set as a file** ([units.json](units.json)) is generated from migration `0002_units.sql`. A test imports it and checks that it changes nothing, so the two can't drift apart.
