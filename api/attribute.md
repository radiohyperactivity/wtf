# Quantities, unit families, units, attributes and options

The SQL is in [`db/repeatable/21_unit.sql`](../db/repeatable/21_unit.sql) (schema `unit`) and [`db/repeatable/30_attribute.sql`](../db/repeatable/30_attribute.sql) (schema `attribute`).

## Units

Quantities, unit families and units are global (see [seed/units.md](../seed/units.md)) or the tenant's own, from `model.import`, which adds them from the `quantities` of a model file ([seed/model-format.md](../seed/model-format.md)) by an admin. A tenant sees the global ones and its own (`global` says which). Every quantity's base unit is one of its units.

- **Turning them on and off:** `unit.quantity_patch` and `unit.family_patch` take `{"available": true | false | null}` (null follows the default again), refused (409) while live attributes or items use their units. The lists say `available`, `standard` and the tenant's `choice`. Only units of available families can be chosen for an attribute or an item ([TENANTS.md](../TENANTS.md), decision 16).
- **The families, by version:** `unit.family_list(p_known_version, p_quantity)` returns `{version, families}`, every family the tenant sees with its units, smallest first; with the current version it answers `{version, unchanged: true}` (304 through the API). Clients keep the list and look units up in it by id, as everywhere else a unit is its id.
- **Conversion:** each unit has `base_factor` and `base_offset`, and clients convert numbers themselves.

## Attributes

- **An attribute's unit** is set with `attribute.create(p_name, p_datatype, p_unit, p_unit_lock)`. The datatype must be the unit's quantity's datatype: `integer` for Count, `decimal` otherwise.
- **Changing the unit** with `attribute.patch` is allowed to any other unit of the same quantity, in any of its families. Numbers are stored in the base unit, so nothing is converted. A unit can't be added where there was none, or removed.
- **Unit lock** (`unit_lock`) shows values and defaults always in the unit itself, instead of scaling them within its family. It can be changed at any time.
- **Options** of a choice attribute come with it: `attribute.get` lists the live ones. `attribute.option_create`, `option_patch`, `option_delete` and `option_restore` change them; an option of a deleted attribute can't be changed.
