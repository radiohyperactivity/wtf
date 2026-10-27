// The same cases as the CLI's tests (internal/cli/cli_test.go).

import 'package:flutter_test/flutter_test.dart';
import 'package:wtf/api/client.dart';
import 'package:wtf/api/models.dart';
import 'package:wtf/api/units.dart';

const length = Quantity(id: 1000, name: 'Length', datatype: 'float');

var _ids = 2000;

Unit unit(
  String symbol, {
  String name = '',
  String factor = '1',
  String offset = '0',
  String family = 'Family',
  int familyId = 1000,
  Quantity quantity = length,
}) => Unit(
  id: _ids++,
  name: name,
  symbol: symbol,
  familyId: familyId,
  familyName: family,
  quantity: quantity,
  baseFactor: Rational.tryParse(factor)!,
  baseOffset: Rational.tryParse(offset)!,
);

void main() {
  test('label codes', () {
    expect(normalizeCode('1a7k'), '1A7K');
    expect(normalizeCode('1a-7k'), '1A7K');
    expect(normalizeCode('IL0O'), '1100');
    expect(normalizeCode('abc'), isNull);
    expect(normalizeCode('1A7U'), isNull);
    expect(normalizeCode('Garage 2'), isNull);
    expect(normalizeCode('Tool'), 'T001');
  });

  test('splitMeasure', () {
    for (final (input, number, symbol) in [
      ('12mm', '12', 'mm'),
      ('2.5 m', '5/2', 'm'),
      ('-3 °C', '-3', '°C'),
      ('1e3', '1000', ''),
      ('.5kΩ', '1/2', 'kΩ'),
    ]) {
      final (r, u) = splitMeasure(input);
      expect('$r', number, reason: input);
      expect(u, symbol, reason: input);
    }
    expect(() => splitMeasure('mm'), throwsA(isA<InputError>()));
  });

  test('decimals', () {
    expect(Rational(BigInt.from(12)).toDecimal(), '12');
    expect(Rational.tryParse('0.0012')!.toDecimal(), '0.0012');
    expect(
      Rational(BigInt.one, BigInt.from(3)).toDecimal(),
      '0.333333333333333333333333333333',
    );
    expect(
      Rational(BigInt.from(2), BigInt.from(3)).toDecimal(),
      '0.666666666666666666666666666667',
    );
    expect(
      Rational(BigInt.from(25315), BigInt.from(100)).toDecimal(),
      '253.15',
    );
    expect(Rational.tryParse('-0.5')!.toDecimal(), '-0.5');
    expect(Rational.fromNum(1e-9).toDecimal(), '0.000000001');
    expect(Rational.fromNum(0.0254).toDecimal(), '0.0254');
  });

  test('matchUnit', () {
    final units = [
      unit('Ω', name: 'ohm'),
      unit('mΩ', name: 'milliohm', factor: '0.001'),
      unit('kΩ', name: 'kiloohm', factor: '1000'),
      unit('MΩ', name: 'megaohm', factor: '1000000'),
      unit('µm', name: 'micrometre', factor: '0.000001'),
      unit('°C', name: 'degree Celsius', offset: '273.15'),
      unit('B', name: 'byte'), // decimal bytes
      unit('B', name: 'byte'), // binary bytes
    ];
    for (final (input, want) in [
      ('kΩ', 'kΩ'),
      ('kohm', 'kΩ'),
      ('MOhm', 'MΩ'),
      ('mohm', 'mΩ'),
      ('um', 'µm'),
      ('μm', 'µm'),
      ('degC', '°C'),
      ('degree celsius', '°C'),
      ('KILOOHM', 'kΩ'),
      ('MOHM', 'MΩ'),
      ('byte', 'B'), // two units, but they convert the same
    ]) {
      expect(matchUnit(units, input).symbol, want, reason: input);
    }
    expect(
      () => matchUnit(units, 'mω'),
      throwsA(
        isA<InputError>().having(
          (e) => e.message,
          'message',
          contains('ambiguous'),
        ),
      ),
    );
    expect(() => matchUnit(units, 'ft'), throwsA(isA<InputError>()));
  });

  test('parseMeasure', () {
    final m = unit('m'),
        mm = unit('mm', factor: '0.001'),
        mil = unit('mil', factor: '0.0000254', familyId: 1001),
        inch = unit('in', factor: '0.0254', familyId: 1001);
    final metric = UnitChoice(
      unit: mm,
      familyUnits: [mm, m],
      quantityUnits: [mm, m, mil, inch],
    );
    // A plain number is in the attribute's unit, or in the one picked.
    expect(parseMeasure('12', metric), const Decimal('0.012'));
    expect(parseMeasure('12', metric, plainIn: m), const Decimal('12'));
    expect(parseMeasure('12mm', metric, plainIn: m), const Decimal('0.012'));
    // Units of another family are accepted too.
    expect(parseMeasure('1 in', metric), const Decimal('0.0254'));
    expect(() => parseMeasure('3kg', metric), throwsA(isA<InputError>()));

    const temperature = Quantity(
      id: 1001,
      name: 'Temperature',
      datatype: 'float',
    );
    final degC = unit('°C', offset: '273.15', quantity: temperature);
    final celsius = UnitChoice(
      unit: degC,
      familyUnits: [degC],
      quantityUnits: [
        degC,
        unit('K', quantity: temperature, familyId: 1002),
      ],
    );
    expect(parseMeasure('20', celsius), const Decimal('293.15'));
    expect(parseMeasure('-40 degC', celsius), const Decimal('233.15'));
    expect(parseMeasure('300 K', celsius), const Decimal('300'));

    // Without a unit: plain numbers only.
    expect(parseMeasure('3', null, integer: true), const Decimal('3'));
    expect(
      () => parseMeasure('2.5', null, integer: true),
      throwsA(isA<InputError>()),
    );
    expect(() => parseMeasure('3 m', null), throwsA(isA<InputError>()));
  });

  test('unit factors are read exactly, with more digits than a double', () {
    // °F as the dev database has it.
    final f = Unit.fromJson(
      decodeBody(
        '{"id": 1077, "name": "degree Fahrenheit", "symbol": "°F", '
        '"family": {"id": 1019, "name": "Fahrenheit"}, '
        '"quantity": {"id": 1012, "name": "Temperature", "datatype": "float"}, '
        '"base_factor": 0.55555555555555555556, "base_offset": 255.37222222222222222}',
      ) as Json,
    );
    expect(f.baseFactor.toDecimal(), '0.55555555555555555556');
    expect(f.familyName, 'Fahrenheit');
    final fahrenheit = UnitChoice(
      unit: f,
      familyUnits: [f],
      quantityUnits: [f],
    );
    // 100 × 0.55555555555555555556 + 255.37222222222222222, exactly.
    expect(
      parseMeasure('100', fahrenheit),
      const Decimal('310.927777777777777776'),
    );
    // Text values that look like it are left alone.
    expect(decodeBody(r'{"name": "\"base_factor\": 2"}'), {
      'name': '"base_factor": 2',
    });
  });

  test('exact numbers in request bodies', () {
    expect(
      encodeBody({
        'quantity': const Decimal('0.333333333333333333333333333333'),
        'name': 'x',
      }),
      '{"quantity":0.333333333333333333333333333333,"name":"x"}',
    );
  });

  test('parseDate', () {
    final now = DateTime(2026, 1, 31, 15, 4, 5);
    for (final (input, want) in [
      ('today', '2026-01-31'),
      ('Yesterday', '2026-01-30'),
      ('tomorrow', '2026-02-01'),
      ('+3', '2026-02-03'),
      ('-3d', '2026-01-28'),
      ('+2w', '2026-02-14'),
      ('+1m', '2026-02-28'),
      ('-2m', '2025-11-30'),
      ('+1y', '2027-01-31'),
      ('2024-02-29', '2024-02-29'),
    ]) {
      expect(parseDate(input, now), want, reason: input);
    }
    for (final bad in ['2024-02-30', '+3x', 'soon', '3']) {
      expect(
        () => parseDate(bad, now),
        throwsA(isA<InputError>()),
        reason: bad,
      );
    }
  });

  test('yes and no', () {
    expect(parseYesNo('Yes'), isTrue);
    expect(parseYesNo('off'), isFalse);
    expect(parseYesNo('maybe'), isNull);
  });

  test('grid columns', () {
    for (final (n, want) in [
      (1, 'A'),
      (8, 'H'),
      (26, 'Z'),
      (27, 'AA'),
      (28, 'AB'),
      (52, 'AZ'),
      (53, 'BA'),
      (702, 'ZZ'),
      (703, 'AAA'),
    ]) {
      expect(columnLabel(n), want);
    }
  });
}
