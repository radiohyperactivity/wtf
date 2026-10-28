# Quantities, unit families, units, attributes and options

Quantities, unit families and units are global (see [seed/units.md](../seed/units.md)) or the tenant's own, from `unit_import`, which adds them from a unit file ([seed/units-format.md](../seed/units-format.md)) with the model write privilege. A tenant sees the global ones and its own (`global` says which). `quantity_patch` and `unit_family_patch` turn them on and off for the tenant (`{"available": true | false | null}`, null following the default again), refused (409) while live attributes or items use their units; the lists say `available`, `default_available` and the tenant's `choice`. Only units of available families can be chosen for an attribute or an item ([TENANTS.md](../TENANTS.md), decision 16). Clients use the `base_factor` and `base_offset` of each unit to convert numbers themselves.

- **An attribute's unit** is set with `attribute_create(p_name, p_datatype, p_unit, p_unit_lock)`. The datatype must be the unit's quantity's datatype: integer for Count, float otherwise.
- **Changing the unit** with `attribute_patch` is allowed to any other unit of the same quantity, in any of its families. Numbers are stored in the base unit, so nothing is converted. A unit can't be added where there was none, or removed.
- **Unit lock** (`unit_lock`, off by default) shows values and defaults always in the unit itself, instead of scaling them within its family. It can be changed at any time.

The SQL is in [`db/repeatable/20_attribute.sql`](../db/repeatable/20_attribute.sql).
