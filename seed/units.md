# Seed data: quantities, units and unit groups

System data loaded after [SCHEMA.md](../SCHEMA.md). It can't be changed through the API.

Numbers of every quantity are stored in its SI coherent base unit. Count is stored as integer, every other quantity as float. Every unit converts to the base unit as:

```text
base = value × base_factor + base_offset
```

The base unit of each quantity has factor 1 and offset 0. Factors are exact where the unit is defined exactly (inch = 0.0254 m, pound = 0.45359237 kg, calorie = 4.184 J). Otherwise they are given to 20 significant digits, e.g. for angles, which involve π.

Notes:
- Names use the SI (BIPM) spelling: metre, litre.
- Where US and imperial units differ, both are included and marked in the symbol: `gal (US)`, `gal (imp)`.
- Data sizes include both decimal (kB = 1000 B) and binary (KiB = 1024 B) prefixes.
- `g/L` is not included. It equals the base unit `kg/m³` exactly, and each quantity can only have one unit with factor 1.
- Non-linear units (dB, dBm, AWG) are out of scope.

The SQL is in [`db/migrations/0002_units.sql`](../db/migrations/0002_units.sql).

## Unit groups

A unit group is the set of units a number is scaled between on output. The API picks the largest unit in the group in which |value| ≥ 1. Groups only combine units that are naturally used together: metric units with metric, imperial with imperial. Units that are normally used on their own (°C, rpm, psi, …) get a group of their own, so an attribute can use them as a fixed display unit.

The unit groups follow the units in the same file.
