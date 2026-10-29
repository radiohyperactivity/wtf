// What people type, turned into what the API takes: numbers with units,
// yes/no, dates, label codes and compartment grids. The same rules as the
// CLI (internal/cli/units.go, resolve.go, cmd_model.go).

import 'models.dart';

/// Input that can't be used, with a message for the person who typed it.
class InputError implements Exception {
  const InputError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// An exact fraction, so that 2.5 in → mm is exact, as in the CLI.
class Rational {
  Rational(BigInt numer, [BigInt? denom])
    : this._normal(numer, denom ?? BigInt.one);

  Rational._normal(BigInt numer, BigInt denom)
    : numer = (denom.isNegative ? -numer : numer) ~/ _gcd(numer, denom),
      denom = denom.abs() ~/ _gcd(numer, denom);

  final BigInt numer;
  final BigInt denom;

  static BigInt _gcd(BigInt a, BigInt b) {
    final g = a.gcd(b);
    return g == BigInt.zero ? BigInt.one : g;
  }

  static final _decimal = RegExp(
    r'^([+-]?)(\d*)(?:\.(\d*))?(?:[eE]([+-]?\d+))?$',
  );

  /// Parses a decimal such as "12", "-2.5", ".5", "1e-9"; null if it isn't one.
  static Rational? tryParse(String s) {
    final m = _decimal.firstMatch(s.trim());
    if (m == null) return null;
    final whole = m[2]!, fraction = m[3] ?? '';
    if (whole.isEmpty && fraction.isEmpty) return null;
    var numer = BigInt.parse(
      '$whole$fraction'.isEmpty ? '0' : '$whole$fraction',
    );
    var denom = BigInt.from(10).pow(fraction.length);
    final exp = int.parse(m[4] ?? '0');
    if (exp.abs() > 400) return null;
    if (exp > 0) numer *= BigInt.from(10).pow(exp);
    if (exp < 0) denom *= BigInt.from(10).pow(-exp);
    if (m[1] == '-') numer = -numer;
    return Rational(numer, denom);
  }

  /// A number from JSON, by its shortest decimal form (as the server wrote it).
  static Rational fromNum(num n) => tryParse(n.toString())!;

  Rational operator *(Rational o) => Rational(numer * o.numer, denom * o.denom);
  Rational operator +(Rational o) =>
      Rational(numer * o.denom + o.numer * denom, denom * o.denom);
  Rational operator -(Rational o) =>
      Rational(numer * o.denom - o.numer * denom, denom * o.denom);
  Rational operator /(Rational o) => Rational(numer * o.denom, denom * o.numer);

  Rational abs() => Rational(numer.abs(), denom);

  /// Whether this is at least [o].
  bool operator >=(Rational o) => numer * o.denom >= o.numer * denom;

  @override
  bool operator ==(Object other) =>
      other is Rational && other.numer == numer && other.denom == denom;

  @override
  int get hashCode => Object.hash(numer, denom);

  bool get isInteger => denom == BigInt.one;
  bool get isZero => numer == BigInt.zero;

  /// The decimal form: exact when it has at most [places] decimals, else
  /// rounded to that many (halves away from zero), without trailing zeros.
  String toDecimal([int places = 30]) {
    if (isInteger) return numer.toString();
    final scale = BigInt.from(10).pow(places);
    final scaled = numer.abs() * scale;
    var digits = scaled ~/ denom;
    if ((scaled % denom) * BigInt.two >= denom) digits += BigInt.one;
    var text = digits.toString().padLeft(places + 1, '0');
    var intPart = text.substring(0, text.length - places);
    var frac = text
        .substring(text.length - places)
        .replaceFirst(RegExp(r'0+$'), '');
    final sign = numer.isNegative && (intPart != '0' || frac.isNotEmpty)
        ? '-'
        : '';
    return frac.isEmpty ? '$sign$intPart' : '$sign$intPart.$frac';
  }

  @override
  String toString() => isInteger ? '$numer' : '$numer/$denom';
}

/// A number for a JSON body, written exactly as [text] (jsonEncode would
/// round it to a double). See encodeBody in client.dart.
class Decimal {
  const Decimal(this.text);

  final String text;

  @override
  bool operator ==(Object other) => other is Decimal && other.text == text;

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() => text;
}

final _numberPattern = RegExp(
  r'^\s*([+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)\s*(.*?)\s*$',
);

/// Splits "12.5mm", "-3 °C" or "1e3" into the number and the (maybe empty) unit.
(Rational, String) splitMeasure(String input) {
  final m = _numberPattern.firstMatch(input);
  final r = m == null ? null : Rational.tryParse(m[1]!);
  if (r == null) throw InputError('"$input" is not a number');
  return (r, m![2]!);
}

/// Splits a number as the server shows it ("64 kHz") into its number and
/// unit symbol, as written; null when it isn't a number.
(String, String)? splitShown(String text) {
  final m = _numberPattern.firstMatch(text);
  return m == null ? null : (m[1]!, m[2]!);
}

/// Unit symbols that are hard to type.
String _aliases(String s) => s
    .replaceAll('μ', 'µ') // Greek mu → micro sign
    .replaceAll('Ω', 'Ω') // ohm sign → Greek omega
    .replaceAll('ohm', 'Ω')
    .replaceAll('Ohm', 'Ω')
    .replaceAll('OHM', 'Ω')
    .replaceAll('deg', '°');

/// Finds a unit by symbol or name: exactly, then with ASCII spellings ("um",
/// "kohm", "degC"), then ignoring case if that is unique. Units that convert
/// the same count as one, such as the B of decimal and of binary bytes; the
/// first of them is returned.
Unit matchUnit(List<Unit> units, String s) {
  s = s.trim();
  final candidates = [s, _aliases(s)];
  if (s.startsWith('u') && s.length > 1) {
    candidates.add('µ${_aliases(s.substring(1))}');
  }
  for (final c in candidates) {
    for (final u in units) {
      if (u.symbol == c) return u;
    }
  }
  final lower = candidates.map((c) => c.toLowerCase()).toList();
  final folded = units
      .where(
        (u) =>
            lower.contains(u.symbol.toLowerCase()) ||
            lower.contains(u.name.toLowerCase()),
      )
      .toList();
  if (folded.isEmpty) throw InputError('unknown unit "$s"');
  if (folded.every((u) => sameConversion(u, folded.first))) {
    return folded.first;
  }
  throw InputError(
    '"$s" is ambiguous: ${folded.map((u) => '${u.symbol} (${u.name})').join(', ')}',
  );
}

bool sameConversion(Unit a, Unit b) =>
    a.baseFactor == b.baseFactor && a.baseOffset == b.baseOffset;

/// The symbols of [units], each once.
String unitSymbols(List<Unit> units) =>
    units.map((u) => u.symbol).toSet().join(', ');

/// A base-unit number as the server's `display` shows it: with [lock] in
/// [unit] itself; otherwise in the unit of its family that scales best, the
/// largest in which it is at least 1, else the smallest. Zero is shown in
/// [unit]. Six decimals at most: "1.2 mm".
String displayIn(
  Rational base,
  Unit unit,
  List<Unit> familyUnits, {
  bool lock = false,
}) {
  Rational inUnit(Unit u) => (base - u.baseOffset) / u.baseFactor;
  var best = unit;
  if (!lock && !base.isZero && familyUnits.isNotEmpty) {
    Unit? found;
    for (final u in familyUnits) {
      if (inUnit(u).abs() >= Rational(BigInt.one) &&
          (found == null || u.baseFactor >= found.baseFactor)) {
        found = u;
      }
    }
    best =
        found ??
        familyUnits.reduce((a, b) => b.baseFactor >= a.baseFactor ? a : b);
  }
  return '${inUnit(best).toDecimal(6)} ${best.symbol}';
}

/// The units a measure may be typed in: a plain number is in [unit], and a
/// symbol is looked up in its family first, then in the whole quantity.
class UnitChoice {
  const UnitChoice({
    required this.unit,
    required this.familyUnits,
    required this.quantityUnits,
  });

  final Unit unit;

  /// The units of [unit]'s family, smallest first: what the unit menu of a
  /// number field offers.
  final List<Unit> familyUnits;
  final List<Unit> quantityUnits;

  Quantity get quantity => unit.quantity;
}

/// Converts input such as "12mm" to the base unit of the unit's quantity. A
/// plain number is in [plainIn] if given (a unit picked next to the field),
/// else in the attribute's or item's unit. Without units (pieces) only plain
/// numbers are accepted. [integer] demands a whole result.
Decimal parseMeasure(
  String input,
  UnitChoice? units, {
  bool integer = false,
  Unit? plainIn,
}) {
  var (r, symbol) = splitMeasure(input);
  if (units == null) {
    if (symbol.isNotEmpty) throw InputError('"$input": no unit expected here');
  } else {
    var u = plainIn ?? units.unit;
    if (symbol.isNotEmpty) {
      try {
        u = matchUnit(units.familyUnits, symbol);
      } on InputError {
        try {
          u = matchUnit(units.quantityUnits, symbol);
        } on InputError catch (e) {
          throw InputError(
            '${e.message}; ${units.quantity.name} is measured in ${unitSymbols(units.quantityUnits)}',
          );
        }
      }
    }
    r = r * u.baseFactor + u.baseOffset;
    integer = integer || units.quantity.datatype == 'integer';
  }
  if (integer && !r.isInteger) {
    throw InputError('"$input" is not a whole number');
  }
  return Decimal(r.toDecimal());
}

/// Converts typed text to the JSON value the API expects for an attribute:
/// numbers in the base unit ([units] must be given for attributes with a
/// unit, [plainIn] is the unit picked for a plain number), yes/no, dates;
/// choices by their option's name, ignoring case; text and url as they are.
Object parseValue(
  Attribute a,
  String input, [
  UnitChoice? units,
  Unit? plainIn,
]) {
  input = input.trim();
  try {
    switch (a.datatype) {
      case 'integer' || 'float':
        return parseMeasure(
          input,
          units,
          integer: a.datatype == 'integer',
          plainIn: plainIn,
        );
      case 'boolean':
        return parseYesNo(input) ??
            (throw InputError('"$input" is not yes or no'));
      case 'date':
        return parseDate(input);
      // An option, ignoring case, as the server takes it; by its own name.
      case 'choice' when a.options.isNotEmpty:
        return a.options
                .map((o) => o.name)
                .where((o) => o.toLowerCase() == input.toLowerCase())
                .firstOrNull ??
            (throw InputError('"$input" is not one of the options'));
    }
  } on InputError catch (e) {
    throw InputError('${a.name}: ${e.message}');
  }
  return input;
}

final _condition = RegExp(r'^\s*(>=|<=|>|<|=)?\s*(.*?)\s*$');

/// Reads a condition on a number or date attribute, as typed in the search
/// form: "32k" (exactly), "> 32kohm", ">= 32 kohm", "<= today", or a range
/// "10k..47k" with both ends included. Numbers take units as [parseMeasure]
/// does ([plainIn]: the unit picked for plain numbers). Returns the filter
/// for GET /items?where= (see api/item.md), or null when [input] is empty.
Map<String, Object>? parseCondition(
  Attribute a,
  String input, [
  UnitChoice? units,
  Unit? plainIn,
]) {
  if (input.trim().isEmpty) return null;
  final m = _condition.firstMatch(input)!;
  final op = m[1] ?? '=';
  final text = m[2]!;
  Object one(String s) {
    if (s.trim().isEmpty) throw InputError('${a.name}: a value is missing');
    return parseValue(a, s, units, plainIn);
  }

  final range = text.indexOf('..');
  if (range >= 0) {
    if (m[1] != null && op != '=') {
      throw InputError('${a.name}: a range LOW..HIGH goes without < or >');
    }
    return {
      'attribute': a.id,
      'op': 'between',
      'value': [one(text.substring(0, range)), one(text.substring(range + 2))],
    };
  }
  return {'attribute': a.id, 'op': op, 'value': one(text)};
}

/// Reads yes/no, true/false, y/n, 1/0 and on/off.
bool? parseYesNo(String input) => switch (input.trim().toLowerCase()) {
  'true' || 'yes' || 'y' || '1' || 'on' => true,
  'false' || 'no' || 'n' || '0' || 'off' => false,
  _ => null,
};

final _relativeDate = RegExp(r'^([+-]\d+)\s*([dwmy]?)$');
final _isoDate = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

/// Accepts YYYY-MM-DD, today, yesterday, tomorrow, and a date relative to
/// today: +3 or +3d (days), -2w (weeks), +1m (months), -1y (years). A month
/// step that lands past the end of a month stops at its last day.
String parseDate(String input, [DateTime? now]) {
  now ??= DateTime.now();
  final today = DateTime.utc(now.year, now.month, now.day);
  final text = input.trim().toLowerCase();
  switch (text) {
    case 'today':
      return _formatDate(today);
    case 'yesterday':
      return _formatDate(today.subtract(const Duration(days: 1)));
    case 'tomorrow':
      return _formatDate(today.add(const Duration(days: 1)));
  }
  final rel = _relativeDate.firstMatch(text);
  if (rel != null) {
    final n = int.parse(rel[1]!);
    return _formatDate(switch (rel[2]) {
      'w' => DateTime.utc(today.year, today.month, today.day + 7 * n),
      'm' => _addMonths(today, n),
      'y' => _addMonths(today, 12 * n),
      _ => DateTime.utc(today.year, today.month, today.day + n),
    });
  }
  final iso = _isoDate.firstMatch(input.trim());
  if (iso != null) {
    final d = DateTime.utc(
      int.parse(iso[1]!),
      int.parse(iso[2]!),
      int.parse(iso[3]!),
    );
    if (_formatDate(d) == input.trim()) return input.trim();
  }
  throw InputError(
    '"$input" is not a date (YYYY-MM-DD, today, yesterday, tomorrow, or +/-N[d|w|m|y])',
  );
}

DateTime _addMonths(DateTime t, int n) {
  final last = DateTime.utc(t.year, t.month + n + 1, 0).day;
  return DateTime.utc(t.year, t.month + n, t.day < last ? t.day : last);
}

String _formatDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// A label code in its normal form ("1a-7k" → "1A7K", I and L → 1, O → 0),
/// or null when the text can't be one.
String? normalizeCode(String s) {
  s = s
      .trim()
      .replaceAll('-', '')
      .toUpperCase()
      .replaceAll('I', '1')
      .replaceAll('L', '1')
      .replaceAll('O', '0');
  if (s.length < 4 || s.length > 7) return null;
  const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  return s.split('').every(alphabet.contains) ? s : null;
}

/// The spreadsheet name of column n: 1 → A, 27 → AA.
String columnLabel(int n) {
  var label = '';
  while (n > 0) {
    n--;
    label = String.fromCharCode(65 + n % 26) + label;
    n ~/= 26;
  }
  return label;
}

/// The number of locations above which a grid must be confirmed.
const gridConfirmLimit = 1000;
