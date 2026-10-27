-- Every quantity names its base unit: the unit with factor 1 and offset 0
-- that numbers are stored in and all factors refer to. A unit file (see
-- seed/units-format.md) states it too, so units imported into an existing
-- quantity are known to mean the same base.

ALTER TABLE quantity
    ADD COLUMN base_symbol text NULL CHECK (btrim(base_symbol) <> ''),
    ADD COLUMN base_name   text NULL CHECK (btrim(base_name) <> '');

UPDATE quantity q
SET base_symbol = b.symbol, base_name = b.name
FROM (VALUES
    ('Length',      'm',    'metre'),
    ('Weight',      'kg',   'kilogram'),
    ('Volume',      'm³',   'cubic metre'),
    ('Voltage',     'V',    'volt'),
    ('Current',     'A',    'ampere'),
    ('Resistance',  'Ω',    'ohm'),
    ('Capacitance', 'F',    'farad'),
    ('Inductance',  'H',    'henry'),
    ('Frequency',   'Hz',   'hertz'),
    ('Power',       'W',    'watt'),
    ('Energy',      'J',    'joule'),
    ('Charge',      'C',    'coulomb'),
    ('Temperature', 'K',    'kelvin'),
    ('Bytes',       'B',    'byte'),
    ('Bits',        'bit',  'bit'),
    ('Count',       'pcs',  'piece')
) AS b (quantity, symbol, name)
WHERE q.name = b.quantity;

ALTER TABLE quantity
    ALTER COLUMN base_symbol SET NOT NULL,
    ALTER COLUMN base_name   SET NOT NULL;

-- A unit with the base unit's symbol must be the base unit.
CREATE FUNCTION unit_check_base() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.symbol = (SELECT q.base_symbol FROM unit_family f JOIN quantity q ON q.id = f.quantity
                     WHERE f.id = NEW.family)
       AND (NEW.base_factor <> 1 OR NEW.base_offset <> 0)
    THEN
        RAISE EXCEPTION 'Unit "%" is the base unit of its quantity, so its factor must be 1 and its offset 0', NEW.symbol
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER unit_check_base
    BEFORE INSERT OR UPDATE OF family, symbol, base_factor, base_offset ON unit
    FOR EACH ROW EXECUTE FUNCTION unit_check_base();
