-- The bootstrap set of global quantities, unit families and units: every
-- tenant sees them, and has them available unless it turns them off
-- (TENANTS.md). Explained in seed/units.md.
--
-- Every quantity refers to its base unit: the unit with factor 1 and offset
-- 0 that numbers are stored in and all factors refer to: metre, kilogram,
-- cubic metre, volt, ampere, ohm, farad, henry, hertz, watt, joule, coulomb,
-- kelvin, byte, bit, piece.

-- Each quantity is given its base unit's id first, and the base unit is then
-- inserted with exactly that id. The foreign key is checked at commit, so a
-- quantity without its base unit fails the migration.
INSERT INTO public.quantity (name, datatype, base_unit, standard)
SELECT q.name, q.datatype::public.datatype, uuidv7(), true
FROM (VALUES
    (1,  'Length',      'decimal'),
    (2,  'Weight',      'decimal'),
    (3,  'Volume',      'decimal'),
    (4,  'Voltage',     'decimal'),
    (5,  'Current',     'decimal'),
    (6,  'Resistance',  'decimal'),
    (7,  'Capacitance', 'decimal'),
    (8,  'Inductance',  'decimal'),
    (9,  'Frequency',   'decimal'),
    (10, 'Power',       'decimal'),
    (11, 'Energy',      'decimal'),
    (12, 'Charge',      'decimal'),
    (13, 'Temperature', 'decimal'),
    (14, 'Bytes',       'decimal'),
    (15, 'Bits',        'decimal'),
    (16, 'Count',       'integer')
) AS q (ord, name, datatype)
ORDER BY q.ord;

INSERT INTO public.unit_family (quantity, name, standard)
SELECT q.id, f.name, true
FROM (VALUES
    (1,  'Length',      'Metric length'),
    (2,  'Length',      'Imperial length'),
    (3,  'Weight',      'Metric weight'),
    (4,  'Weight',      'Imperial weight'),
    (5,  'Volume',      'Metric volume'),
    (6,  'Volume',      'US volume'),
    (7,  'Volume',      'Imperial volume'),
    (8,  'Voltage',     'Voltage'),
    (9,  'Current',     'Current'),
    (10, 'Resistance',  'Resistance'),
    (11, 'Capacitance', 'Capacitance'),
    (12, 'Inductance',  'Inductance'),
    (13, 'Frequency',   'Frequency'),
    (14, 'Power',       'Power'),
    (15, 'Energy',      'Joules'),
    (16, 'Energy',      'Watt hours'),
    (17, 'Energy',      'Calories'),
    (18, 'Charge',      'Charge'),
    (19, 'Temperature', 'Celsius'),
    (20, 'Temperature', 'Fahrenheit'),
    (21, 'Temperature', 'Kelvin'),
    (22, 'Bytes',       'Decimal bytes'),
    (23, 'Bytes',       'Binary bytes'),
    (24, 'Bits',        'Bits'),
    (25, 'Count',       'Pieces')
) AS f (ord, quantity, name)
JOIN public.quantity q ON q.name = f.quantity
ORDER BY f.ord;

-- Factors are exact where the unit is defined exactly (inch = 0.0254 m,
-- pound = 0.45359237 kg). The rows marked true are the base units, which
-- take the id their quantity was given. Binary bytes' B means the same as
-- Decimal bytes' B, the base unit of Bytes, which a symbol shared within a
-- quantity must.
INSERT INTO public.unit (id, family, name, symbol, base_factor, base_offset)
SELECT CASE WHEN u.base THEN q.base_unit ELSE uuidv7() END,
       f.id, u.name, u.symbol, u.base_factor, u.base_offset
FROM (VALUES
    ('Metric length',   'nanometre',            'nm',          0.000000001,            0,                       false),
    ('Metric length',   'micrometre',           'µm',          0.000001,               0,                       false),
    ('Metric length',   'millimetre',           'mm',          0.001,                  0,                       false),
    ('Metric length',   'centimetre',           'cm',          0.01,                   0,                       false),
    ('Metric length',   'metre',                'm',           1,                      0,                       true),
    ('Metric length',   'kilometre',            'km',          1000,                   0,                       false),

    ('Imperial length', 'thou',                 'mil',         0.0000254,              0,                       false),
    ('Imperial length', 'inch',                 'in',          0.0254,                 0,                       false),
    ('Imperial length', 'foot',                 'ft',          0.3048,                 0,                       false),
    ('Imperial length', 'mile',                 'mi',          1609.344,               0,                       false),

    ('Metric weight',   'microgram',            'µg',          0.000000001,            0,                       false),
    ('Metric weight',   'milligram',            'mg',          0.000001,               0,                       false),
    ('Metric weight',   'gram',                 'g',           0.001,                  0,                       false),
    ('Metric weight',   'kilogram',             'kg',          1,                      0,                       true),
    ('Metric weight',   'tonne',                't',           1000,                   0,                       false),

    ('Imperial weight', 'grain',                'gr',          0.00006479891,          0,                       false),
    ('Imperial weight', 'ounce',                'oz',          0.028349523125,         0,                       false),
    ('Imperial weight', 'pound',                'lb',          0.45359237,             0,                       false),

    ('Metric volume',   'microlitre',           'µL',          0.000000001,            0,                       false),
    ('Metric volume',   'millilitre',           'mL',          0.000001,               0,                       false),
    ('Metric volume',   'litre',                'L',           0.001,                  0,                       false),
    ('Metric volume',   'cubic metre',          'm³',          1,                      0,                       true),

    ('US volume',       'US fluid ounce',       'fl oz (US)',  0.0000295735295625,     0,                       false),
    ('US volume',       'US pint',              'pt (US)',     0.000473176473,         0,                       false),
    ('US volume',       'US quart',             'qt (US)',     0.000946352946,         0,                       false),
    ('US volume',       'US gallon',            'gal (US)',    0.003785411784,         0,                       false),

    ('Imperial volume', 'imperial fluid ounce', 'fl oz (imp)', 0.0000284130625,        0,                       false),
    ('Imperial volume', 'imperial pint',        'pt (imp)',    0.00056826125,          0,                       false),
    ('Imperial volume', 'imperial quart',       'qt (imp)',    0.0011365225,           0,                       false),
    ('Imperial volume', 'imperial gallon',      'gal (imp)',   0.00454609,             0,                       false),

    ('Voltage',         'microvolt',            'µV',          0.000001,               0,                       false),
    ('Voltage',         'millivolt',            'mV',          0.001,                  0,                       false),
    ('Voltage',         'volt',                 'V',           1,                      0,                       true),
    ('Voltage',         'kilovolt',             'kV',          1000,                   0,                       false),

    ('Current',         'nanoampere',           'nA',          0.000000001,            0,                       false),
    ('Current',         'microampere',          'µA',          0.000001,               0,                       false),
    ('Current',         'milliampere',          'mA',          0.001,                  0,                       false),
    ('Current',         'ampere',               'A',           1,                      0,                       true),
    ('Current',         'kiloampere',           'kA',          1000,                   0,                       false),

    ('Resistance',      'milliohm',             'mΩ',          0.001,                  0,                       false),
    ('Resistance',      'ohm',                  'Ω',           1,                      0,                       true),
    ('Resistance',      'kilohm',               'kΩ',          1000,                   0,                       false),
    ('Resistance',      'megohm',               'MΩ',          1000000,                0,                       false),
    ('Resistance',      'gigohm',               'GΩ',          1000000000,             0,                       false),

    ('Capacitance',     'picofarad',            'pF',          0.000000000001,         0,                       false),
    ('Capacitance',     'nanofarad',            'nF',          0.000000001,            0,                       false),
    ('Capacitance',     'microfarad',           'µF',          0.000001,               0,                       false),
    ('Capacitance',     'millifarad',           'mF',          0.001,                  0,                       false),
    ('Capacitance',     'farad',                'F',           1,                      0,                       true),

    ('Inductance',      'nanohenry',            'nH',          0.000000001,            0,                       false),
    ('Inductance',      'microhenry',           'µH',          0.000001,               0,                       false),
    ('Inductance',      'millihenry',           'mH',          0.001,                  0,                       false),
    ('Inductance',      'henry',                'H',           1,                      0,                       true),

    ('Frequency',       'hertz',                'Hz',          1,                      0,                       true),
    ('Frequency',       'kilohertz',            'kHz',         1000,                   0,                       false),
    ('Frequency',       'megahertz',            'MHz',         1000000,                0,                       false),
    ('Frequency',       'gigahertz',            'GHz',         1000000000,             0,                       false),

    ('Power',           'microwatt',            'µW',          0.000001,               0,                       false),
    ('Power',           'milliwatt',            'mW',          0.001,                  0,                       false),
    ('Power',           'watt',                 'W',           1,                      0,                       true),
    ('Power',           'kilowatt',             'kW',          1000,                   0,                       false),
    ('Power',           'megawatt',             'MW',          1000000,                0,                       false),

    ('Joules',          'millijoule',           'mJ',          0.001,                  0,                       false),
    ('Joules',          'joule',                'J',           1,                      0,                       true),
    ('Joules',          'kilojoule',            'kJ',          1000,                   0,                       false),
    ('Joules',          'megajoule',            'MJ',          1000000,                0,                       false),
    ('Joules',          'gigajoule',            'GJ',          1000000000,             0,                       false),

    ('Watt hours',      'milliwatt hour',       'mWh',         3.6,                    0,                       false),
    ('Watt hours',      'watt hour',            'Wh',          3600,                   0,                       false),
    ('Watt hours',      'kilowatt hour',        'kWh',         3600000,                0,                       false),
    ('Watt hours',      'megawatt hour',        'MWh',         3600000000,             0,                       false),

    ('Calories',        'calorie',              'cal',         4.184,                  0,                       false),
    ('Calories',        'kilocalorie',          'kcal',        4184,                   0,                       false),

    ('Charge',          'coulomb',              'C',           1,                      0,                       true),
    ('Charge',          'milliampere hour',     'mAh',         3.6,                    0,                       false),
    ('Charge',          'ampere hour',          'Ah',          3600,                   0,                       false),

    ('Celsius',         'degree Celsius',       '°C',          1,                      273.15,                  false),

    ('Fahrenheit',      'degree Fahrenheit',    '°F',          0.55555555555555555556, 255.37222222222222222,   false),

    ('Kelvin',          'kelvin',               'K',           1,                      0,                       true),

    ('Decimal bytes',   'byte',                 'B',           1,                      0,                       true),
    ('Decimal bytes',   'kilobyte',             'kB',          1000,                   0,                       false),
    ('Decimal bytes',   'megabyte',             'MB',          1000000,                0,                       false),
    ('Decimal bytes',   'gigabyte',             'GB',          1000000000,             0,                       false),
    ('Decimal bytes',   'terabyte',             'TB',          1000000000000,          0,                       false),
    ('Decimal bytes',   'petabyte',             'PB',          1000000000000000,       0,                       false),

    ('Binary bytes',    'byte',                 'B',           1,                      0,                       false),
    ('Binary bytes',    'kibibyte',             'KiB',         1024,                   0,                       false),
    ('Binary bytes',    'mebibyte',             'MiB',         1048576,                0,                       false),
    ('Binary bytes',    'gibibyte',             'GiB',         1073741824,             0,                       false),
    ('Binary bytes',    'tebibyte',             'TiB',         1099511627776,          0,                       false),
    ('Binary bytes',    'pebibyte',             'PiB',         1125899906842624,       0,                       false),

    ('Bits',            'bit',                  'bit',         1,                      0,                       true),
    ('Bits',            'kilobit',              'kbit',        1000,                   0,                       false),
    ('Bits',            'megabit',              'Mbit',        1000000,                0,                       false),
    ('Bits',            'gigabit',              'Gbit',        1000000000,             0,                       false),

    ('Pieces',          'piece',                'pcs',         1,                      0,                       true)
) AS u (family, name, symbol, base_factor, base_offset, base)
JOIN public.unit_family f ON f.name = u.family
JOIN public.quantity q    ON q.id = f.quantity
ORDER BY f.id, u.base_factor;
