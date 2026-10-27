# Quantities, unit families, units, attributes and options

Quantities, unit families and units are system data (see [seed/units.md](../seed/units.md)). The API only reads them, apart from `unit_import`, which adds them from a unit file ([seed/units-format.md](../seed/units-format.md)) with the model write privilege. Clients use the `base_factor` and `base_offset` of each unit to convert numbers themselves.

- **An attribute's unit** is set with `attribute_create(p_name, p_datatype, p_unit, p_unit_lock)`. The datatype must be the unit's quantity's datatype: integer for Count, float otherwise.
- **Changing the unit** with `attribute_patch` is allowed to any other unit of the same quantity, in any of its families. Numbers are stored in the base unit, so nothing is converted. A unit can't be added where there was none, or removed.
- **Unit lock** (`unit_lock`, off by default) shows values and defaults always in the unit itself, instead of scaling them within its family. It can be changed at any time.

The SQL is in [`db/repeatable/20_attribute.sql`](../db/repeatable/20_attribute.sql).
