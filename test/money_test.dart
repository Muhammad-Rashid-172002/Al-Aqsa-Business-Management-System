import 'package:al_aqsa_cctv/core/money.dart';
import 'package:al_aqsa_cctv/core/password_hasher.dart';
import 'package:al_aqsa_cctv/domain/models/json_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Money', () {
    test('parses user input safely', () {
      expect(Money.parse('1,250').paisa, 125000);
      expect(Money.parse('Rs 1,250.5').paisa, 125050);
      expect(Money.parse('0.05').paisa, 5);
      expect(Money.parse('-20').paisa, -2000);
      expect(Money.tryParse('12.345'), isNull);
      expect(Money.tryParse('abc'), isNull);
    });

    test('no floating point drift', () {
      var total = const Money.zero();
      for (var k = 0; k < 10; k++) {
        total += Money.parse('0.10');
      }
      expect(total, Money.parse('1.00'));
    });

    test('rounding half up on division and shares', () {
      expect(Money(1000).divide(3).paisa, 333);
      expect(Money(1001).divide(2).paisa, 501);
      expect(Money(10000).share(1, 3).paisa, 3333);
      expect(Money(10000).percentBp(1250).paisa, 1250);
    });

    test('formats with thousands separators', () {
      expect(Money.rupees(1234567.5).format(), 'Rs 1,234,567.50');
      expect(Money.rupees(-50).format(), '-Rs 50.00');
    });
  });

  test('addMonths clamps end of month', () {
    expect(addMonths(DateTime(2026, 1, 31), 1), DateTime(2026, 2, 28));
    expect(addMonths(DateTime(2026, 3, 10), 12), DateTime(2027, 3, 10));
  });

  test('password hashing verifies and never stores plain text', () {
    const h = PasswordHasher(iterations: 50);
    final stored = h.hash('myPass1');
    expect(stored.contains('myPass1'), isFalse);
    expect(h.verify('myPass1', stored), isTrue);
    expect(h.verify('wrong', stored), isFalse);
    expect(h.hash('myPass1') == stored, isFalse, reason: 'salted');
  });
}
