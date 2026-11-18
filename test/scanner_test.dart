import 'package:al_aqsa_cctv/core/errors.dart';
import 'package:al_aqsa_cctv/core/scan_detector.dart';
import 'package:al_aqsa_cctv/domain/models/operations.dart';
import 'package:al_aqsa_cctv/domain/models/product.dart';
import 'package:al_aqsa_cctv/domain/services/catalog_service.dart';
import 'package:al_aqsa_cctv/domain/services/purchase_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

Duration ms(int v) => Duration(milliseconds: v);

/// Types [text] into [d] starting at [start] ms, one character every [gap] ms,
/// and returns the time of the last character.
int type(ScanDetector d, String text, {required int start, required int gap}) {
  var t = start;
  for (var i = 0; i < text.length; i++) {
    if (i > 0) t += gap;
    d.addChar(text[i], ms(t));
  }
  return t;
}

void main() {
  group('scan detector (keyboard-mode USB scanner)', () {
    test('a fast burst ending with Enter is a scan', () {
      final d = ScanDetector();
      final end = type(d, '8964000123456', start: 1000, gap: 6);
      expect(d.suffix(SuffixKey.enter, ms(end + 4)), '8964000123456');
      expect(d.isEmpty, isTrue);
    });

    test('Tab suffix is accepted in automatic mode and in Tab mode only', () {
      final auto = ScanDetector();
      expect(auto.suffix(SuffixKey.tab, ms(type(auto, 'AQ00001234', start: 0, gap: 5) + 3)), 'AQ00001234');
      final tabOnly = ScanDetector(const ScannerConfig(suffix: ScanSuffix.tab));
      expect(tabOnly.suffix(SuffixKey.enter, ms(type(tabOnly, 'AQ00001234', start: 0, gap: 5) + 3)), isNull);
      expect(tabOnly.suffix(SuffixKey.tab, ms(type(tabOnly, 'AQ00001234', start: 100, gap: 5) + 3)), 'AQ00001234');
      final enterOnly = ScanDetector(const ScannerConfig(suffix: ScanSuffix.enter));
      expect(enterOnly.suffix(SuffixKey.tab, ms(type(enterOnly, 'AQ00001234', start: 0, gap: 5) + 3)), isNull);
    });

    test('normal human typing is never a scan', () {
      final d = ScanDetector();
      final end = type(d, 'dome camera', start: 0, gap: 120);
      expect(d.suffix(SuffixKey.enter, ms(end + 150)), isNull);
      // Even quick typists have some gaps above 40 ms.
      final end2 = type(d, 'nvr', start: 5000, gap: 70);
      expect(d.suffix(SuffixKey.enter, ms(end2 + 80)), isNull);
    });

    test('a short fast burst (key rollover) is not a scan', () {
      final d = ScanDetector();
      final end = type(d, 'ab', start: 0, gap: 10);
      expect(d.suffix(SuffixKey.enter, ms(end + 10)), isNull);
    });

    test('Enter long after a fast burst is a normal Enter', () {
      final d = ScanDetector();
      final end = type(d, 'AQ00001234', start: 0, gap: 5);
      expect(d.suffix(SuffixKey.enter, ms(end + 500)), isNull);
    });

    test('a scan right after typing keeps only the scanned characters', () {
      final d = ScanDetector();
      var t = type(d, 'abc', start: 0, gap: 150); // typed
      t = type(d, 'SN000123', start: t + 400, gap: 4); // scanned
      expect(d.suffix(SuffixKey.enter, ms(t + 3)), 'SN000123');
    });

    test('rapid consecutive scans are reported separately', () {
      final d = ScanDetector();
      final out = <String?>[];
      var t = 0;
      for (final code in ['AQ00000001', 'AQ00000002', 'SN000000099']) {
        t = type(d, code, start: t + 30, gap: 3);
        out.add(d.suffix(SuffixKey.enter, ms(t + 2)));
      }
      expect(out, ['AQ00000001', 'AQ00000002', 'SN000000099']);
    });

    test('no-suffix scanners: the code ends at the pause', () {
      final d = ScanDetector(const ScannerConfig(suffix: ScanSuffix.none));
      type(d, '8964000123456', start: 0, gap: 5);
      expect(d.pause(), '8964000123456');
      type(d, 'ab', start: 1000, gap: 5);
      expect(d.pause(), isNull, reason: 'shorter than the minimum length');
      final auto = ScanDetector();
      type(auto, '8964000123456', start: 0, gap: 5);
      expect(auto.pause(), isNull, reason: 'automatic mode waits for Enter/Tab');
      final none = ScanDetector(const ScannerConfig(suffix: ScanSuffix.none));
      expect(none.suffix(SuffixKey.enter, ms(type(none, '8964000123456', start: 0, gap: 5) + 2)), isNull);
    });

    test('the key speed and minimum length are configurable', () {
      final slow = ScanDetector(const ScannerConfig(maxKeyGap: Duration(milliseconds: 80), minLength: 2));
      expect(slow.suffix(SuffixKey.enter, ms(type(slow, 'A1', start: 0, gap: 60) + 50)), 'A1');
      final strict = ScanDetector(const ScannerConfig(maxKeyGap: Duration(milliseconds: 10)));
      expect(strict.suffix(SuffixKey.enter, ms(type(strict, 'AQ00001234', start: 0, gap: 20) + 5)), isNull);
    });
  });

  group('duplicate scans', () {
    test('the same code again within the window is ignored, later it counts', () {
      final g = DuplicateScanGuard(ms(700));
      final t0 = DateTime(2026, 11, 17, 10);
      expect(g.accept('AQ00001234', t0), isTrue);
      expect(g.accept('aq00001234 ', t0.add(ms(150))), isFalse, reason: 'double read');
      expect(g.accept('AQ00001234', t0.add(ms(600))), isFalse);
      expect(g.accept('AQ00001234', t0.add(ms(900))), isTrue, reason: 'a deliberate second scan');
    });

    test('a different code is never blocked; window 0 turns the check off', () {
      final g = DuplicateScanGuard(ms(700));
      final t0 = DateTime(2026, 11, 17, 10);
      expect(g.accept('A1', t0), isTrue);
      expect(g.accept('B2', t0.add(ms(10))), isTrue);
      expect(g.accept('A1', t0.add(ms(20))), isTrue);
      final off = DuplicateScanGuard(Duration.zero);
      expect(off.accept('A1', t0), isTrue);
      expect(off.accept('A1', t0), isTrue);
    });
  });

  group('scanner settings', () {
    late TestEnv env;
    setUp(() async => env = await TestEnv.create());
    tearDown(() async => env.dispose());

    test('defaults, saving and validation', () async {
      final s = env.app.ctx.settings.scanner;
      expect(s.suffix, ScanSuffix.auto);
      expect(s.maxKeyGap, ms(40));
      expect(s.minLength, 4);
      expect(s.duplicateWindow, ms(700));
      // Settings saved before this feature (no scanner keys) load the defaults.
      expect(AppSettings.fromJson({'businessName': 'X'}).scanner.suffix, ScanSuffix.auto);
      await env.app.settings.save({'scannerSuffix': 'tab', 'scannerKeyGapMs': 60, 'scannerMinLength': 6, 'scannerDuplicateMs': 0});
      final s2 = env.app.ctx.settings.scanner;
      expect(s2.suffix, ScanSuffix.tab);
      expect(s2.maxKeyGap, ms(60));
      expect(s2.minLength, 6);
      expect(s2.duplicateWindow, Duration.zero);
      await expectLater(env.app.settings.save({'scannerKeyGapMs': 5}), throwsA(isA<ValidationException>()));
      await expectLater(env.app.settings.save({'scannerMinLength': 0}), throwsA(isA<ValidationException>()));
      await expectLater(env.app.settings.save({'scannerDuplicateMs': -1}), throwsA(isA<ValidationException>()));
      expect(AppSettings.fromJson({'scannerSuffix': 'bogus'}).scanner.suffix, ScanSuffix.auto);
    });
  });

  group('scanned code lookup', () {
    late TestEnv env;
    setUp(() async => env = await TestEnv.create());
    tearDown(() async => env.dispose());

    test('company barcode, QR text, internal code, SKU, serial unit, unknown', () async {
      final app = env.app;
      final cable = await app.catalog.create(ProductInput(
        name: 'Cat6 Cable',
        sku: 'CBL-CAT6',
        purchasePrice: rs(50),
        sellingPrice: rs(80),
        companyBarcodes: const ['8964000123456', 'https://example.pk/p/CAT6-305M'],
      ));
      final cam = await env.product('Hik 4MP Dome', serial: true, brand: 'Hikvision');
      final sup = await env.supplier();
      await app.purchases.create(
        supplierId: sup.id,
        date: env.clock.now,
        lines: [PurchaseLineInput(productId: cam.id, qty: q(2), unitCost: rs(4000), serials: const ['DS2CD-0001', 'DS2CD-0002'])],
      );

      expect(app.catalog.lookup('8964000123456')!.product.id, cable.id);
      expect(app.catalog.lookup(' 8964000123456\n')!.product.id, cable.id, reason: 'spaces / line ends from the scanner');
      expect(app.catalog.lookup('https://example.pk/p/CAT6-305M')!.product.id, cable.id, reason: 'QR text');
      expect(app.catalog.lookup(cable.internalCode)!.product.id, cable.id, reason: 'printed label');
      expect(app.catalog.lookup('cbl-cat6')!.product.id, cable.id, reason: 'SKU, any case');
      final unit = app.catalog.lookup('ds2cd-0002')!;
      expect(unit.product.id, cam.id);
      expect(unit.serial!.serial, 'DS2CD-0002', reason: 'the individual unit is identified');
      expect(unit.serial!.status, SerialStatus.inStock);
      expect(app.catalog.lookup('NOT-A-CODE-999'), isNull);
      expect(app.catalog.lookup(''), isNull);
      expect(app.catalog.lookup('   '), isNull);
    });

    test('the same serial under two brands returns both units', () async {
      final app = env.app;
      final a = await env.product('Dahua NVR', serial: true, brand: 'Dahua');
      final b = await env.product('Hik NVR', serial: true, brand: 'Hikvision');
      final sup = await env.supplier();
      await app.purchases.create(supplierId: sup.id, date: env.clock.now, lines: [PurchaseLineInput(productId: a.id, qty: q(1), unitCost: rs(9000), serials: const ['NVR777'])]);
      await app.purchases.create(
        supplierId: sup.id,
        date: env.clock.now,
        lines: [PurchaseLineInput(productId: b.id, qty: q(1), unitCost: rs(9000), serials: const ['NVR777'])],
        approvedSerialConflicts: const {'NVR777'},
      );
      final r = app.catalog.lookup('NVR777')!;
      final units = [r.serial!, ...r.otherMatches];
      expect(units.length, 2);
      expect(units.map((u) => u.productId).toSet(), {a.id, b.id});
    });
  });
}
