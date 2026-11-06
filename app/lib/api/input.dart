// What people type, turned into what the API takes: numbers (with the
// label of what they are counted in), yes/no, dates, choices, label codes
// and compartment grids. The same rules as the CLI (internal/cli/values.go).

import 'models.dart';

/// Input that can't be used, with a message for the person who typed it.
class InputError implements Exception {
  const InputError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// An exact fraction, so that a number typed in is sent as it was typed,
/// and two ways of writing one number ("1.50", "1.5") compare equal.
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

  @override
  bool operator ==(Object other) =>
      other is Rational && other.numer == numer && other.denom == denom;

  @override
  int get hashCode => Object.hash(numer, denom);

  bool get isInteger => denom == BigInt.one;

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

/// Reads a number, which may be followed by [unit], the label of what it is
/// counted in ("12 mm" when the unit is "mm"). Another label is refused, as
/// nothing converts. [integer] demands an integer.
Decimal parseNumber(String input, {String? unit, bool integer = false}) {
  final m = _numberPattern.firstMatch(input);
  final r = m == null ? null : Rational.tryParse(m[1]!);
  if (r == null) throw InputError('"${input.trim()}" is not a number');
  final label = m![2]!;
  if (label.isNotEmpty && label.toLowerCase() != (unit ?? '').toLowerCase()) {
    throw InputError(
      unit == null || unit.isEmpty
          ? '"${input.trim()}": a number without a unit is wanted'
          : '"${input.trim()}": the number is in $unit, and nothing converts',
    );
  }
  if (integer && !r.isInteger) {
    throw InputError('"${input.trim()}" is not an integer');
  }
  return Decimal(r.toDecimal());
}

/// Whether [a] (typed, or null) and [b] (from the server, or null) are the
/// same number.
bool sameNumber(Decimal? a, num? b) => a == null || b == null
    ? a == null && b == null
    : Rational.tryParse(a.text) == Rational.fromNum(b);

/// Converts typed text to the JSON value the API takes for attribute [a]:
/// numbers (with its unit's label, if any), yes/no, dates, a choice by its
/// text (ignoring case), text and urls as they are. A file is uploaded, not
/// typed.
Object parseValue(Attribute a, String input) {
  input = input.trim();
  try {
    switch (a.type) {
      case 'integer' || 'decimal':
        return parseNumber(input, unit: a.unit, integer: a.type == 'integer');
      case 'boolean':
        return parseYesNo(input) ??
            (throw InputError('"$input" is not yes or no'));
      case 'date':
        return parseDate(input);
      case 'choice':
        return a.choices
                .where((c) => c.toLowerCase() == input.toLowerCase())
                .firstOrNull ??
            (throw InputError(
              '"$input" is not one of ${a.choices.join(', ')}',
            ));
      case 'url':
        if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(input)) {
          throw const InputError('a link starts with http:// or https://');
        }
      case 'attachment':
        throw const InputError('a file is uploaded, not typed');
    }
  } on InputError catch (e) {
    throw InputError('${a.name}: ${e.message}');
  }
  if (input.isEmpty) throw InputError("${a.name} can't be empty");
  return input;
}

final _condition = RegExp(r'^\s*(>=|<=|>|<|=)?\s*(.*?)\s*$');

/// Reads a condition on a number or date attribute, as typed in the search
/// form: "32" (exactly), "> 32", ">= 32 mm", "<= today", or a range "10..47"
/// with both ends included. Returns the filter for GET /items?where= (see
/// api/item.md), or null when [input] is empty.
Map<String, Object>? parseCondition(Attribute a, String input) {
  if (input.trim().isEmpty) return null;
  final m = _condition.firstMatch(input)!;
  final op = m[1] ?? '=';
  final text = m[2]!;
  Object one(String s) {
    if (s.trim().isEmpty) throw InputError('${a.name}: a value is missing');
    return parseValue(a, s);
  }

  final range = text.indexOf('..');
  if (range >= 0) {
    if (m[1] != null && op != '=') {
      throw InputError('${a.name}: a range LOW..HIGH goes without < or >');
    }
    return {
      'attribute': a.name,
      'op': 'between',
      'value': [one(text.substring(0, range)), one(text.substring(range + 2))],
    };
  }
  return {'attribute': a.name, 'op': op, 'value': one(text)};
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
      return formatDate(today);
    case 'yesterday':
      return formatDate(today.subtract(const Duration(days: 1)));
    case 'tomorrow':
      return formatDate(today.add(const Duration(days: 1)));
  }
  final rel = _relativeDate.firstMatch(text);
  if (rel != null) {
    final n = int.parse(rel[1]!);
    return formatDate(switch (rel[2]) {
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
    if (formatDate(d) == input.trim()) return input.trim();
  }
  throw InputError(
    '"$input" is not a date (YYYY-MM-DD, today, yesterday, tomorrow, or +/-N[d|w|m|y])',
  );
}

DateTime _addMonths(DateTime t, int n) {
  final last = DateTime.utc(t.year, t.month + n + 1, 0).day;
  return DateTime.utc(t.year, t.month + n, t.day < last ? t.day : last);
}

/// YYYY-MM-DD.
String formatDate(DateTime d) =>
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
