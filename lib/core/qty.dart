import 'money.dart';

/// Decimal-safe quantity with 3 decimal places (stored as integer thousandths),
/// e.g. 1.5 m of cable = Qty(1500). Serial-numbered products always use whole
/// quantities.
class Qty implements Comparable<Qty> {
  final int milli;
  const Qty(this.milli);
  const Qty.zero() : milli = 0;
  const Qty.one() : milli = 1000;

  factory Qty.units(num units) => Qty((units * 1000).round());

  /// Parses "2", "1.5", "2.75", "0.125". Throws [FormatException].
  factory Qty.parse(String input) {
    var s = input.trim().replaceAll(',', '');
    if (s.isEmpty) return const Qty.zero();
    final neg = s.startsWith('-');
    if (neg) s = s.substring(1);
    if (!RegExp(r'^\d+(\.\d{0,3})?$').hasMatch(s) && !RegExp(r'^\.\d{1,3}$').hasMatch(s)) {
      throw FormatException('Invalid quantity: $input');
    }
    final parts = s.split('.');
    final whole = parts[0].isEmpty ? 0 : int.parse(parts[0]);
    final frac = (parts.length > 1 ? parts[1] : '').padRight(3, '0');
    final v = whole * 1000 + int.parse(frac.isEmpty ? '0' : frac);
    return Qty(neg ? -v : v);
  }

  static Qty? tryParse(String input) {
    try {
      return Qty.parse(input);
    } on FormatException {
      return null;
    }
  }

  Qty operator +(Qty o) => Qty(milli + o.milli);
  Qty operator -(Qty o) => Qty(milli - o.milli);
  Qty operator -() => Qty(-milli);
  bool operator >(Qty o) => milli > o.milli;
  bool operator <(Qty o) => milli < o.milli;
  bool operator >=(Qty o) => milli >= o.milli;
  bool operator <=(Qty o) => milli <= o.milli;

  bool get isZero => milli == 0;
  bool get isPositive => milli > 0;
  bool get isNegative => milli < 0;
  bool get isWhole => milli % 1000 == 0;

  /// Whole number of units. Throws if the quantity has a fraction.
  int get wholeUnits {
    if (!isWhole) throw StateError('Quantity $this is not a whole number');
    return milli ~/ 1000;
  }

  double get asDouble => milli / 1000;

  static Qty sum(Iterable<Qty> v) => v.fold(const Qty.zero(), (a, b) => a + b);
  static Qty min(Qty a, Qty b) => a <= b ? a : b;
  static Qty max(Qty a, Qty b) => a >= b ? a : b;

  @override
  int compareTo(Qty other) => milli.compareTo(other.milli);
  @override
  bool operator ==(Object other) => other is Qty && other.milli == milli;
  @override
  int get hashCode => milli.hashCode;

  /// "3", "1.5", "2.75" (no trailing zeros).
  String format() {
    final neg = milli < 0;
    final a = milli.abs();
    var s = (a ~/ 1000).toString();
    final f = a % 1000;
    if (f != 0) s += '.${f.toString().padLeft(3, '0').replaceFirst(RegExp(r'0+$'), '')}';
    return neg ? '-$s' : s;
  }

  @override
  String toString() => format();

  int toJson() => milli;
  static Qty fromJson(Object? v) => Qty((v as num?)?.toInt() ?? 0);
}

extension MoneyQty on Money {
  /// Unit price × quantity, half-up rounded to the paisa.
  Money timesQty(Qty q) => Money(paisa * q.milli).divide(1000);

  /// Price per one unit when this amount covers [q] units.
  Money perUnit(Qty q) => q.isZero ? const Money.zero() : Money(paisa * 1000).divide(q.milli);

  /// Proportional share of this amount for [part] out of [whole].
  Money shareQty(Qty part, Qty whole) => whole.isZero ? const Money.zero() : share(part.milli, whole.milli);
}
