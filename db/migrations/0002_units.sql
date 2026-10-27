-- System data: the bootstrap set of quantities, unit families and units.
-- Explained in seed/units.md. Ids are given in order from 1000, so every
-- installation has the same ids for the same units.

INSERT INTO quantity (name, datatype) VALUES
    ('Length',      'float'),
    ('Weight',      'float'),
    ('Volume',      'float'),
    ('Voltage',     'float'),
    ('Current',     'float'),
    ('Resistance',  'float'),
    ('Capacitance', 'float'),
    ('Inductance',  'float'),
    ('Frequency',   'float'),
    ('Power',       'float'),
    ('Energy',      'float'),
    ('Charge',      'float'),
    ('Temperature', 'float'),
    ('Bytes',       'float'),
    ('Bits',        'float'),
    ('Count',       'integer');

INSERT INTO unit_family (quantity, name)
SELECT q.id, f.name
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
    (18, 'Charge',      'Battery capacity'),
    (19, 'Temperature', 'Celsius'),
    (20, 'Temperature', 'Fahrenheit'),
    (21, 'Temperature', 'Kelvin'),
    (22, 'Bytes',       'Decimal bytes'),
    (23, 'Bytes',       'Binary bytes'),
    (24, 'Bits',        'Bits'),
    (25, 'Count',       'Pieces')
) AS f (ord, quantity, name)
JOIN quantity q ON q.name = f.quantity
ORDER BY f.ord;

-- Base units: metre, kilogram, cubic metre, volt, ampere, ohm, farad, henry,
-- hertz, watt, joule, coulomb, kelvin, byte, bit, piece. Factors are exact
-- where the unit is defined exactly (inch = 0.0254 m, pound = 0.45359237 kg).
INSERT INTO unit (family, name, symbol, base_factor, base_offset)
SELECT f.id, u.name, u.symbol, u.base_factor, u.base_offset
FROM (VALUES
    (1,  'Metric length',    'nanometre',            'nm',          0.000000001::numeric,     0::numeric),
    (2,  'Metric length',    'micrometre',           'µm',          0.000001,                 0),
    (3,  'Metric length',    'millimetre',           'mm',          0.001,                    0),
    (4,  'Metric length',    'centimetre',           'cm',          0.01,                     0),
    (5,  'Metric length',    'metre',                'm',           1,                        0),
    (6,  'Metric length',    'kilometre',            'km',          1000,                     0),

    (7,  'Imperial length',  'thou',                 'mil',         0.0000254,                0),
    (8,  'Imperial length',  'inch',                 'in',          0.0254,                   0),
    (9,  'Imperial length',  'foot',                 'ft',          0.3048,                   0),
    (10, 'Imperial length',  'mile',                 'mi',          1609.344,                 0),

    (11, 'Metric weight',    'microgram',            'µg',          0.000000001,              0),
    (12, 'Metric weight',    'milligram',            'mg',          0.000001,                 0),
    (13, 'Metric weight',    'gram',                 'g',           0.001,                    0),
    (14, 'Metric weight',    'kilogram',             'kg',          1,                        0),
    (15, 'Metric weight',    'tonne',                't',           1000,                     0),

    (16, 'Imperial weight',  'grain',                'gr',          0.00006479891,            0),
    (17, 'Imperial weight',  'ounce',                'oz',          0.028349523125,           0),
    (18, 'Imperial weight',  'pound',                'lb',          0.45359237,               0),

    (19, 'Metric volume',    'microlitre',           'µL',          0.000000001,              0),
    (20, 'Metric volume',    'millilitre',           'mL',          0.000001,                 0),
    (21, 'Metric volume',    'litre',                'L',           0.001,                    0),
    (22, 'Metric volume',    'cubic metre',          'm³',          1,                        0),

    (23, 'US volume',        'US fluid ounce',       'fl oz (US)',  0.0000295735295625,       0),
    (24, 'US volume',        'US pint',              'pt (US)',     0.000473176473,           0),
    (25, 'US volume',        'US quart',             'qt (US)',     0.000946352946,           0),
    (26, 'US volume',        'US gallon',            'gal (US)',    0.003785411784,           0),

    (27, 'Imperial volume',  'imperial fluid ounce', 'fl oz (imp)', 0.0000284130625,          0),
    (28, 'Imperial volume',  'imperial pint',        'pt (imp)',    0.00056826125,            0),
    (29, 'Imperial volume',  'imperial quart',       'qt (imp)',    0.0011365225,             0),
    (30, 'Imperial volume',  'imperial gallon',      'gal (imp)',   0.00454609,               0),

    (31, 'Voltage',          'microvolt',            'µV',          0.000001,                 0),
    (32, 'Voltage',          'millivolt',            'mV',          0.001,                    0),
    (33, 'Voltage',          'volt',                 'V',           1,                        0),
    (34, 'Voltage',          'kilovolt',             'kV',          1000,                     0),

    (35, 'Current',          'nanoampere',           'nA',          0.000000001,              0),
    (36, 'Current',          'microampere',          'µA',          0.000001,                 0),
    (37, 'Current',          'milliampere',          'mA',          0.001,                    0),
    (38, 'Current',          'ampere',               'A',           1,                        0),
    (39, 'Current',          'kiloampere',           'kA',          1000,                     0),

    (40, 'Resistance',       'milliohm',             'mΩ',          0.001,                    0),
    (41, 'Resistance',       'ohm',                  'Ω',           1,                        0),
    (42, 'Resistance',       'kilohm',               'kΩ',          1000,                     0),
    (43, 'Resistance',       'megohm',               'MΩ',          1000000,                  0),
    (44, 'Resistance',       'gigohm',               'GΩ',          1000000000,               0),

    (45, 'Capacitance',      'picofarad',            'pF',          0.000000000001,           0),
    (46, 'Capacitance',      'nanofarad',            'nF',          0.000000001,              0),
    (47, 'Capacitance',      'microfarad',           'µF',          0.000001,                 0),
    (48, 'Capacitance',      'millifarad',           'mF',          0.001,                    0),
    (49, 'Capacitance',      'farad',                'F',           1,                        0),

    (50, 'Inductance',       'nanohenry',            'nH',          0.000000001,              0),
    (51, 'Inductance',       'microhenry',           'µH',          0.000001,                 0),
    (52, 'Inductance',       'millihenry',           'mH',          0.001,                    0),
    (53, 'Inductance',       'henry',                'H',           1,                        0),

    (54, 'Frequency',        'hertz',                'Hz',          1,                        0),
    (55, 'Frequency',        'kilohertz',            'kHz',         1000,                     0),
    (56, 'Frequency',        'megahertz',            'MHz',         1000000,                  0),
    (57, 'Frequency',        'gigahertz',            'GHz',         1000000000,               0),

    (58, 'Power',            'microwatt',            'µW',          0.000001,                 0),
    (59, 'Power',            'milliwatt',            'mW',          0.001,                    0),
    (60, 'Power',            'watt',                 'W',           1,                        0),
    (61, 'Power',            'kilowatt',             'kW',          1000,                     0),
    (62, 'Power',            'megawatt',             'MW',          1000000,                  0),

    (63, 'Joules',           'millijoule',           'mJ',          0.001,                    0),
    (64, 'Joules',           'joule',                'J',           1,                        0),
    (65, 'Joules',           'kilojoule',            'kJ',          1000,                     0),
    (66, 'Joules',           'megajoule',            'MJ',          1000000,                  0),
    (67, 'Joules',           'gigajoule',            'GJ',          1000000000,               0),

    (68, 'Watt hours',       'milliwatt hour',       'mWh',         3.6,                      0),
    (69, 'Watt hours',       'watt hour',            'Wh',          3600,                     0),
    (70, 'Watt hours',       'kilowatt hour',        'kWh',         3600000,                  0),
    (71, 'Watt hours',       'megawatt hour',        'MWh',         3600000000,               0),

    (72, 'Calories',         'calorie',              'cal',         4.184,                    0),
    (73, 'Calories',         'kilocalorie',          'kcal',        4184,                     0),

    (74, 'Battery capacity', 'milliampere hour',     'mAh',         3.6,                      0),
    (75, 'Battery capacity', 'ampere hour',          'Ah',          3600,                     0),

    (76, 'Celsius',          'degree Celsius',       '°C',          1,                        273.15),
    (77, 'Fahrenheit',       'degree Fahrenheit',    '°F',          0.55555555555555555556,   255.37222222222222222),
    (78, 'Kelvin',           'kelvin',               'K',           1,                        0),

    (79, 'Decimal bytes',    'byte',                 'B',           1,                        0),
    (80, 'Decimal bytes',    'kilobyte',             'kB',          1000,                     0),
    (81, 'Decimal bytes',    'megabyte',             'MB',          1000000,                  0),
    (82, 'Decimal bytes',    'gigabyte',             'GB',          1000000000,               0),
    (83, 'Decimal bytes',    'terabyte',             'TB',          1000000000000,            0),
    (84, 'Decimal bytes',    'petabyte',             'PB',          1000000000000000,         0),

    (85, 'Binary bytes',     'byte',                 'B',           1,                        0),
    (86, 'Binary bytes',     'kibibyte',             'KiB',         1024,                     0),
    (87, 'Binary bytes',     'mebibyte',             'MiB',         1048576,                  0),
    (88, 'Binary bytes',     'gibibyte',             'GiB',         1073741824,               0),
    (89, 'Binary bytes',     'tebibyte',             'TiB',         1099511627776,            0),
    (90, 'Binary bytes',     'pebibyte',             'PiB',         1125899906842624,         0),

    (91, 'Bits',             'bit',                  'bit',         1,                        0),
    (92, 'Bits',             'kilobit',              'kbit',        1000,                     0),
    (93, 'Bits',             'megabit',              'Mbit',        1000000,                  0),
    (94, 'Bits',             'gigabit',              'Gbit',        1000000000,               0),

    (95, 'Pieces',           'piece',                'pcs',         1,                        0)
) AS u (ord, family, name, symbol, base_factor, base_offset)
JOIN unit_family f ON f.name = u.family
ORDER BY u.ord;
