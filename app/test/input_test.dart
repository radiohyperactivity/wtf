// The same cases as the CLI's tests (internal/cli/cli_test.go).

import 'package:flutter_test/flutter_test.dart';
import 'package:wtf/api/client.dart';
import 'package:wtf/api/input.dart';
import 'package:wtf/api/models.dart';

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

  test('numbers, with the label of their unit', () {
    for (final (input, unit, want) in [
      ('12', null, '12'),
      ('2.50', null, '2.5'),
      ('-3', null, '-3'),
      ('12 mm', 'mm', '12'),
      ('12MM', 'mm', '12'),
      ('1e3', null, '1000'),
      ('.5', null, '0.5'),
    ]) {
      expect(parseNumber(input, unit: unit), Decimal(want), reason: input);
    }
    for (final (input, unit) in [
      ('12 cm', 'mm'),
      ('12 mm', null),
      ('twelve', null),
    ]) {
      expect(
        () => parseNumber(input, unit: unit),
        throwsA(isA<InputError>()),
        reason: input,
      );
    }
    expect(parseNumber('1e3', integer: true), const Decimal('1000'));
    expect(() => parseNumber('2.5', integer: true), throwsA(isA<InputError>()));
    expect(sameNumber(const Decimal('1.50'), 1.5), isTrue);
    expect(sameNumber(null, null), isTrue);
    expect(sameNumber(const Decimal('2'), null), isFalse);
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
    expect(Rational.tryParse('-0.5')!.toDecimal(), '-0.5');
    expect(Rational.fromNum(1e-9).toDecimal(), '0.000000001');
  });

  test('exact numbers in request bodies', () {
    expect(
      encodeBody({
        'amount': const Decimal('0.333333333333333333333333333333'),
        'name': 'x',
      }),
      '{"amount":0.333333333333333333333333333333,"name":"x"}',
    );
  });

  test('values by the type of their attribute', () {
    Attribute a(String type, {String? unit, List<String> choices = const []}) =>
        Attribute(
          name: 'A',
          scope: 'item',
          type: type,
          unit: unit,
          choices: choices,
        );
    expect(
      parseValue(a('decimal', unit: 'mm'), '2.5 mm'),
      const Decimal('2.5'),
    );
    expect(parseValue(a('integer'), ' 7 '), const Decimal('7'));
    expect(parseValue(a('boolean'), 'Yes'), true);
    expect(parseValue(a('date'), '2026-11-04'), '2026-11-04');
    expect(parseValue(a('choice', choices: ['Red', 'Blue']), 'blue'), 'Blue');
    expect(parseValue(a('url'), 'https://wtf.example.com'), isA<String>());
    expect(parseValue(a('text'), ' plain '), 'plain');
    for (final (attribute, input) in [
      (a('integer'), '2.5'),
      (a('decimal', unit: 'mm'), '3 in'),
      (a('choice', choices: ['Red']), 'Green'),
      (a('url'), 'wtf.example.com'),
      (a('boolean'), 'maybe'),
      (a('attachment'), 'x'),
    ]) {
      expect(
        () => parseValue(attribute, input),
        throwsA(
          isA<InputError>().having(
            (e) => e.message,
            'message',
            startsWith('A: '),
          ),
        ),
        reason: '${attribute.type} $input',
      );
    }
  });

  test('conditions, by attribute name', () {
    const length = Attribute(
      name: 'Length',
      scope: 'item',
      type: 'decimal',
      unit: 'mm',
    );
    expect(
      encodeBody([
        ?parseCondition(length, '>= 32'),
        ?parseCondition(length, '10..47 mm'),
        ?parseCondition(length, '12'),
      ]),
      '[{"attribute":"Length","op":">=","value":32},'
      '{"attribute":"Length","op":"between","value":[10,47]},'
      '{"attribute":"Length","op":"=","value":12}]',
    );
    expect(parseCondition(length, '  '), isNull);
    expect(() => parseCondition(length, '> 1..2'), throwsA(isA<InputError>()));
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

  test('counts and stock totals as shown', () {
    expect(count(1, 'item'), '1 item');
    expect(count(1204, 'item'), '1,204 items');
    expect(count(2, 'class', 'classes'), '2 classes');
    ItemListed listed(num total, bool uncounted, [String? unit]) =>
        ItemListed.fromJson({
          'id': 'i',
          'code': '1B00',
          'name': 'Wire',
          'class': 'c',
          'unit': unit,
          'photo': null,
          'stock': {'total': total, 'uncounted': uncounted},
        });
    expect(listed(12, false).stockText, '12');
    expect(listed(1.5, false, 'm').stockText, '1.5 m');
    expect(listed(3, true).stockText, '3 + uncounted');
    expect(listed(0, true).stockText, 'uncounted');
  });
}
