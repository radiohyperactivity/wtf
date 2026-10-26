# Quantities, units, unit groups, attributes and options

Quantities, units and unit groups are system data (see [seed/units.md](../seed/units.md)). The API only reads them. Clients use the `base_factor` and `base_offset` of each unit to convert numbers themselves.

The SQL is in [`db/repeatable/20_attribute.sql`](../db/repeatable/20_attribute.sql).
