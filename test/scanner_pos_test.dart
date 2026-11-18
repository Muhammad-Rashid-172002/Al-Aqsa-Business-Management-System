// POS + USB scanner (keyboard mode), simulated with real key events through
// Flutter's HardwareKeyboard — the same path a HID scanner's keystrokes take.
// Hardware compatibility still has to be checked with a real scanner.
import 'package:al_aqsa_cctv/domain/models/documents.dart';
import 'package:al_aqsa_cctv/domain/models/product.dart';
import 'package:al_aqsa_cctv/domain/services/catalog_service.dart';
import 'package:al_aqsa_cctv/domain/services/purchase_service.dart';
import 'package:al_aqsa_cctv/ui/pages/pos_page.dart';
import 'package:al_aqsa_cctv/ui/providers.dart';
import 'package:al_aqsa_cctv/ui/shell/app_shell.dart';
import 'package:al_aqsa_cctv/ui/theme.dart';
import 'package:al_aqsa_cctv/ui/widgets/forms.dart';
import 'package:al_aqsa_cctv/ui/widgets/scanner_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

var _ms = 100000;

LogicalKeyboardKey _keyFor(String ch) {
  final lower = ch.toLowerCase();
  final k = LogicalKeyboardKey.findKeyByKeyId(lower.codeUnitAt(0));
  return k ?? LogicalKeyboardKey.keyA;
}

/// Sends [code] like a scanner: one key every [gap] ms, then [suffix].
Future<void> _scan(
  WidgetTester tester,
  String code, {
  int gap = 4,
  LogicalKeyboardKey? suffix = LogicalKeyboardKey.enter,
}) async {
  for (final ch in code.split('')) {
    _ms += gap;
    final k = _keyFor(ch);
    await tester.sendKeyDownEvent(k, character: ch);
    await tester.sendKeyUpEvent(k);
  }
  if (suffix != null) {
    _ms += gap;
    await tester.sendKeyDownEvent(suffix);
    await tester.sendKeyUpEvent(suffix);
  }
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200)); // pause + clean-up timers
}

class _Shop {
  final TestEnv env;
  final Product cable, hdd, cam;
  _Shop(this.env, this.cable, this.hdd, this.cam);
}

Future<_Shop> _seed() async {
  final env = await TestEnv.create();
  final app = env.app;
  final cable = await app.catalog.create(ProductInput(
    name: 'Cat6 Cable Roll',
    sku: 'CBL-CAT6',
    purchasePrice: rs(5000),
    sellingPrice: rs(7000),
    companyBarcodes: const ['8964000123456'],
  ));
  final hdd = await env.product('Seagate SkyHawk 2TB', cost: 12000, price: 15000);
  final cam = await env.product('Hik 4MP Dome', serial: true, brand: 'Hikvision', cost: 4000, price: 6000);
  final sup = await env.supplier();
  await app.purchases.create(
    supplierId: sup.id,
    date: env.clock.now,
    lines: [
      PurchaseLineInput(productId: cable.id, qty: q(20), unitCost: rs(5000)),
      PurchaseLineInput(productId: hdd.id, qty: q(10), unitCost: rs(12000)),
      PurchaseLineInput(productId: cam.id, qty: q(2), unitCost: rs(4000), serials: const ['DS2CD-0001', 'DS2CD-0002']),
    ],
  );
  return _Shop(env, cable, hdd, cam);
}

Future<(_Shop, ProviderContainer)> _openPos(WidgetTester tester) async {
  final shop = (await tester.runAsync(_seed))!;
  debugScannerClock = () => Duration(milliseconds: _ms);
  addTearDown(() => debugScannerClock = null);
  await tester.binding.setSurfaceSize(const Size(1600, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [servicesProvider.overrideWithValue(shop.env.app)],
      child: MaterialApp(
        theme: AppTheme.build(AppColors.darkPalette),
        home: const Root(),
      ),
    ),
  );
  final c = ProviderScope.containerOf(tester.element(find.byType(Root)));
  c.read(currentUserProvider.notifier).state = shop.env.app.auth.findByUsername('owner');
  await tester.pump();
  c.read(navProvider.notifier).state = NavItem.pos;
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(seconds: 1));
  expect(find.byType(ScannerField), findsWidgets);
  return (shop, c);
}

Future<void> _close(WidgetTester tester, _Shop shop) async {
  await tester.pump(const Duration(seconds: 6)); // let toasts time out
  await tester.pumpWidget(const SizedBox());
  await tester.runAsync(shop.env.dispose);
}

List<SaleItem> _items(ProviderContainer c) => c.read(posDraftProvider)?.items ?? const [];

Qty _qtyOf(ProviderContainer c, String productId) =>
    _items(c).where((e) => e.productId == productId).fold(const Qty.zero(), (a, e) => a + e.qty);

TextField _scanField(WidgetTester tester) => tester.widget<TextField>(
      find.descendant(of: find.byType(ScannerField).first, matching: find.byType(TextField)),
    );

void main() {
  testWidgets('a valid barcode scan adds the product to the bill', (tester) async {
    final (shop, c) = await _openPos(tester);
    await _scan(tester, '8964000123456');
    expect(_qtyOf(c, shop.cable.id), q(1));
    expect(_scanField(tester).controller!.text, '', reason: 'scan field is ready for the next scan');
    // SKU and printed internal-code labels work the same way.
    await _scan(tester, 'cbl-cat6');
    _ms += 2000;
    shop.env.clock.advance(const Duration(seconds: 2));
    await _scan(tester, shop.env.reload(shop.hdd.id).internalCode);
    expect(_qtyOf(c, shop.cable.id), q(2));
    expect(_qtyOf(c, shop.hdd.id), q(1));
    await _close(tester, shop);
  });

  testWidgets('scan works with nothing focused, and with a Tab suffix', (tester) async {
    final (shop, c) = await _openPos(tester);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await _scan(tester, '8964000123456', suffix: LogicalKeyboardKey.tab);
    expect(_qtyOf(c, shop.cable.id), q(1));
    expect(find.textContaining('Unknown code'), findsNothing);
    await _close(tester, shop);
  });

  testWidgets('unknown code shows a clear error and changes nothing', (tester) async {
    final (shop, c) = await _openPos(tester);
    await _scan(tester, '0000111122223333');
    expect(tester.takeException(), isNull);
    expect(_items(c), isEmpty);
    expect(find.textContaining('Unknown code "0000111122223333"'), findsOneWidget);
    // A scanned code that only partly matches a product is not guessed.
    await _scan(tester, 'SKYHAWK2TB99');
    expect(_items(c), isEmpty);
    await _close(tester, shop);
  });

  testWidgets('rapid scans of different items are all added', (tester) async {
    final (shop, c) = await _openPos(tester);
    _ms += 1000;
    await _scan(tester, '8964000123456', gap: 2);
    _ms += 15;
    await _scan(tester, shop.env.reload(shop.hdd.id).internalCode, gap: 2);
    _ms += 15;
    await _scan(tester, 'DS2CD-0001', gap: 2);
    expect(_qtyOf(c, shop.cable.id), q(1));
    expect(_qtyOf(c, shop.hdd.id), q(1));
    expect(_qtyOf(c, shop.cam.id), q(1));
    await _close(tester, shop);
  });

  testWidgets('a double read is ignored; a deliberate second scan adds one more', (tester) async {
    final (shop, c) = await _openPos(tester);
    await _scan(tester, '8964000123456');
    shop.env.clock.advance(const Duration(milliseconds: 150));
    await _scan(tester, '8964000123456'); // scanner read the label twice
    expect(_qtyOf(c, shop.cable.id), q(1));
    expect(find.textContaining('Ignored a repeated scan'), findsOneWidget);
    shop.env.clock.advance(const Duration(seconds: 2));
    _ms += 2000;
    await _scan(tester, '8964000123456');
    expect(_qtyOf(c, shop.cable.id), q(2));
    await _close(tester, shop);
  });

  testWidgets('scanning a serial adds that exact unit, once', (tester) async {
    final (shop, c) = await _openPos(tester);
    await _scan(tester, 'ds2cd-0002');
    final line = _items(c).single;
    expect(line.productId, shop.cam.id);
    expect(line.serials, [SerialRecord.keyFor(shop.env.reload(shop.cam.id).brandKey, 'DS2CD-0002')]);
    shop.env.clock.advance(const Duration(seconds: 2));
    _ms += 2000;
    await _scan(tester, 'DS2CD-0002');
    expect(_items(c).single.serials.length, 1);
    expect(find.textContaining('already on this bill'), findsOneWidget);
    await _close(tester, shop);
  });

  testWidgets('normal typing still searches and Enter still works', (tester) async {
    final (shop, c) = await _openPos(tester);
    // Slow key presses (a person) with nothing focused go into the search box.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await _scan(tester, 'sk', gap: 150, suffix: null);
    await tester.pump(const Duration(milliseconds: 300));
    // (In a test, keys typed into a focused field do not produce text, so
    // only the keys this listener moved into the search box are checked.)
    expect(_scanField(tester).controller!.text, 'sk');
    expect(_items(c), isEmpty);
    // Typing a name and pressing Enter keeps the old behaviour (single match is added).
    final field = find.descendant(of: find.byType(ScannerField).first, matching: find.byType(TextField));
    await tester.enterText(field, 'Seagate SkyHawk');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(_qtyOf(c, shop.hdd.id), q(1));
    await _close(tester, shop);
  });
}
