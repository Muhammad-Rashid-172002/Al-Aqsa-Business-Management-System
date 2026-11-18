/// Decimal-safe money. Amounts are stored as integer paisa (1 PKR = 100 paisa),
/// so totals never suffer floating-point drift.
class Money implements Comparable<Money> {
  final int paisa;
  const Money(this.paisa);
  const Money.zero() : paisa = 0;

  factory Money.rupees(num rupees) => Money((rupees * 100).round());

  /// Parses user input such as "1,250", "1250.5", "Rs 1,250.50".
  /// Throws [FormatException] for invalid text.
  factory Money.parse(String input) {
    var s = input.trim().replaceAll(',', '').replaceAll(RegExp(r'^(Rs\.?|PKR)\s*', caseSensitive: false), '');
    if (s.isEmpty) return const Money.zero();
    final neg = s.startsWith('-');
    if (neg) s = s.substring(1);
    if (!RegExp(r'^\d+(\.\d{0,2})?$').hasMatch(s)) {
      throw FormatException('Invalid amount: $input');
    }
    final parts = s.split('.');
    final whole = int.parse(parts[0]);
    var frac = parts.length > 1 ? parts[1] : '';
    frac = frac.padRight(2, '0');
    final value = whole * 100 + (frac.isEmpty ? 0 : int.parse(frac));
    return Money(neg ? -value : value);
  }

  static Money? tryParse(String input) {
    try {
      return Money.parse(input);
    } on FormatException {
      return null;
    }
  }

  Money operator +(Money o) => Money(paisa + o.paisa);
  Money operator -(Money o) => Money(paisa - o.paisa);
  Money operator -() => Money(-paisa);
  Money times(int qty) => Money(paisa * qty);

  /// Integer division with half-up rounding (used for per-unit cost).
  Money divide(int by) {
    if (by == 0) throw ArgumentError('Division by zero');
    final q = paisa ~/ by;
    final r = paisa.remainder(by).abs() * 2;
    if (r >= by.abs()) return Money(paisa >= 0 ? q + 1 : q - 1);
    return Money(q);
  }

  /// Proportional share: this * numerator / denominator, half-up rounded.
  Money share(int numerator, int denominator) {
    if (denominator == 0) return const Money.zero();
    return Money(paisa * numerator).divide(denominator);
  }

  /// Percentage with basis points (e.g. 1250 = 12.50%).
  Money percentBp(int basisPoints) => Money(paisa * basisPoints).divide(10000);

  bool get isZero => paisa == 0;
  bool get isNegative => paisa < 0;
  bool get isPositive => paisa > 0;
  Money abs() => Money(paisa.abs());

  static Money sum(Iterable<Money> values) =>
      values.fold(const Money.zero(), (a, b) => a + b);

  static Money min(Money a, Money b) => a.paisa <= b.paisa ? a : b;
  static Money max(Money a, Money b) => a.paisa >= b.paisa ? a : b;

  bool operator >(Money o) => paisa > o.paisa;
  bool operator <(Money o) => paisa < o.paisa;
  bool operator >=(Money o) => paisa >= o.paisa;
  bool operator <=(Money o) => paisa <= o.paisa;

  @override
  int compareTo(Money other) => paisa.compareTo(other.paisa);

  @override
  bool operator ==(Object other) => other is Money && other.paisa == paisa;

  @override
  int get hashCode => paisa.hashCode;

  /// Plain decimal text, e.g. "1250.50".
  String toDecimalString() {
    final neg = paisa < 0;
    final a = paisa.abs();
    final s = '${a ~/ 100}.${(a % 100).toString().padLeft(2, '0')}';
    return neg ? '-$s' : s;
  }

  /// Display text with thousands separators, e.g. "Rs 1,250.50".
  String format({String symbol = 'Rs', bool showDecimals = true}) {
    final neg = paisa < 0;
    final a = paisa.abs();
    final whole = (a ~/ 100).toString();
    final buf = StringBuffer();
    for (var i = 0; i < whole.length; i++) {
      if (i > 0 && (whole.length - i) % 3 == 0) buf.write(',');
      buf.write(whole[i]);
    }
    var out = buf.toString();
    if (showDecimals) out += '.${(a % 100).toString().padLeft(2, '0')}';
    return '${neg ? '-' : ''}$symbol $out';
  }

  @override
  String toString() => format();

  int toJson() => paisa;
  static Money fromJson(Object? v) => Money((v as num?)?.toInt() ?? 0);
}
