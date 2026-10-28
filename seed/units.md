# Seed data: quantities, unit families and units

The global units, loaded after [SCHEMA.md](../SCHEMA.md): every tenant sees them, and has them available unless it turns them off ([TENANTS.md](../TENANTS.md)). This is a bootstrap set, so it only covers what most inventories need. More quantities, families and units are imported from unit files ([units-format.md](units-format.md)): global ones by the operator (`wtfd unit import --global`), a tenant's own through the API. The bootstrap set itself is one too: [units.json](units.json).

- A **quantity** is what is measured: Length, Weight, Voltage, …
- A **unit family** is a set of units of one quantity that are used together, and that a number is scaled between on output: Metric length is nm … km, Imperial length is mil … mi. A quantity can have several families.
- A **unit** belongs to exactly one family.

Numbers of every quantity are stored in its base unit, which the quantity names (`base_unit` in the API). Count is stored as integer, every other quantity as float. Every unit converts to the base unit as:

```text
base = value × base_factor + base_offset
```

The base unit of each quantity has factor 1 and offset 0. Factors are exact where the unit is defined exactly (inch = 0.0254 m, pound = 0.45359237 kg, calorie = 4.184 J). Otherwise they are given to 20 significant digits (°F).

Quantities, families and units have UUIDs, which differ between installations; unit files name them instead. Everything here is available by default (`default_available`); the operator can change that with `wtfd unit default`.

The SQL is in [`db/migrations/0002_units.sql`](../db/migrations/0002_units.sql).

## The bootstrap set

| Quantity (base unit) | Family: units |
|----------------------|---------------|
| Length (m) | **Metric length:** nm, µm, mm, cm, m, km · **Imperial length:** mil, in, ft, mi |
| Weight (kg) | **Metric weight:** µg, mg, g, kg, t · **Imperial weight:** gr, oz, lb |
| Volume (m³) | **Metric volume:** µL, mL, L, m³ · **US volume:** fl oz (US), pt (US), qt (US), gal (US) · **Imperial volume:** fl oz (imp), pt (imp), qt (imp), gal (imp) |
| Voltage (V) | **Voltage:** µV, mV, V, kV |
| Current (A) | **Current:** nA, µA, mA, A, kA |
| Resistance (Ω) | **Resistance:** mΩ, Ω, kΩ, MΩ, GΩ |
| Capacitance (F) | **Capacitance:** pF, nF, µF, mF, F |
| Inductance (H) | **Inductance:** nH, µH, mH, H |
| Frequency (Hz) | **Frequency:** Hz, kHz, MHz, GHz |
| Power (W) | **Power:** µW, mW, W, kW, MW |
| Energy (J) | **Joules:** mJ, J, kJ, MJ, GJ · **Watt hours:** mWh, Wh, kWh, MWh · **Calories:** cal, kcal |
| Charge (C) | **Battery capacity:** mAh, Ah |
| Temperature (K) | **Celsius:** °C · **Fahrenheit:** °F · **Kelvin:** K |
| Bytes (B) | **Decimal bytes:** B, kB, MB, GB, TB, PB · **Binary bytes:** B, KiB, MiB, GiB, TiB, PiB |
| Bits (bit) | **Bits:** bit, kbit, Mbit, Gbit |
| Count (pcs) | **Pieces:** pcs |

Notes:
- Names use the SI (BIPM) spelling: metre, litre. Mass is called Weight, the common if less correct term.
- Where US and imperial units differ, both are included and marked in the symbol: `gal (US)`, `gal (imp)`.
- Bytes and bits are separate quantities, which can't be converted into each other: a byte isn't always 8 bits.
- Both byte families have a unit `B`. They convert the same, so either may be meant.
- Units with an odd ratio to their neighbours, or that are normally used on their own, are left out of the families (yd, st, cL, dL). With yards in Imperial length, 4 ft would show as 1.33 yd.
- Non-linear units (dB, dBm, AWG) are out of scope.

## Scaling and Unit lock

An attribute (for values and defaults) or an item (for stock quantities) may have a unit. A plain number is read in that unit, and a number with any other unit of the same quantity is converted, whichever family that unit is in.

On output, a number is shown in the largest unit of the unit's family in which |value| ≥ 1, or else in the smallest. Zero is shown in the unit itself. With **Unit lock** set, numbers are always shown in the unit itself. Unit lock is off by default.
