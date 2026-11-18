// UI flow: one product + quantity + one serial per unit, in the product form.
import 'package:al_aqsa_cctv/domain/models/product.dart';
import 'package:al_aqsa_cctv/ui/providers.dart';
import 'package:al_aqsa_cctv/ui/shell/app_shell.dart';
import 'package:al_aqsa_cctv/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

Future<(TestEnv, ProviderContainer)> _open(WidgetTester tester) async {
  final env = (await tester.runAsync(() async {
    final e = await TestEnv.create();
    await e.supplier('Hik Distributor');
    return e;
  }))!;
  await tester.binding.setSurfaceSize(const Size(1600, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ProviderScope(
    overrides: [servicesProvider.overrideWithValue(env.app)],
    child: MaterialApp(theme: AppTheme.build(AppColors.darkPalette), home: const Root()),
  ));
  final c = ProviderScope.containerOf(tester.element(find.byType(Root)));
  c.read(currentUserProvider.notifier).state = env.app.auth.findByUsername('owner');
  await tester.pump();
  c.read(navProvider.notifier).state = NavItem.products;
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  return (env, c);
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pump();
  await tester.tap(f);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> _scanSerial(WidgetTester tester, String serial) async {
  final field = find.byKey(const ValueKey('serial-scan'));
  await tester.enterText(field, serial);
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pump();
}

void main() {
  testWidgets('create one product with 3 units and 3 serial numbers from the product form', (tester) async {
    final (env, _) = await _open(tester);
    await _tap(tester, find.widgetWithText(FilledButton, 'Add Product').first);
    await tester.enterText(find.widgetWithText(TextFormField, 'Product name *'), 'Hikvision CCTV Camera');
    await tester.enterText(find.widgetWithText(TextFormField, 'Brand (e.g. Hikvision, Dahua)'), 'Hikvision');
    await tester.enterText(find.widgetWithText(TextFormField, 'Purchase price (Rs) *'), '4000');
    await tester.enterText(find.widgetWithText(TextFormField, 'Selling price (Rs) *'), '6000');
    await _tap(tester, find.text('Track individual serial numbers'));
    final qty = find.byKey(const ValueKey('receive-qty'));
    await tester.ensureVisible(qty);
    await tester.enterText(qty, '3');
    await tester.pump();
    await _tap(tester, find.byKey(const ValueKey('receive-supplier')));
    await _tap(tester, find.text('Hik Distributor').last);

    // Serial entry: required 3; a repeated serial is flagged and blocks.
    await _tap(tester, find.byKey(const ValueKey('receive-serials')));
    expect(find.text('Serial numbers • Hikvision CCTV Camera'), findsOneWidget);
    await _scanSerial(tester, 'ds-0001');
    await _scanSerial(tester, 'DS-0001');
    expect(find.text('Entered twice in this list'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('serial-done'))).onPressed, isNull);
    await _tap(tester, find.textContaining('Remove 1 invalid'));
    await _scanSerial(tester, 'DS-0002');
    await _scanSerial(tester, 'DS-0003');
    expect(find.descendant(of: find.byKey(const ValueKey('serial-count-remaining')), matching: find.text('0')), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('serial-done')));
    expect(find.text('Required 3 • Entered 3 • Remaining 0'), findsOneWidget);

    await _tap(tester, find.text('Save Product'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 500));
    final app = env.app;
    expect(app.catalog.products().length, 1);
    final p = app.catalog.products().single;
    expect(p.stockQty, q(3));
    expect(app.serials.search(productId: p.id).map((r) => r.serial).toList(), ['DS-0001', 'DS-0002', 'DS-0003']);
    expect(app.serials.statusCounts(p.id), {SerialStatus.inStock: 3});
    expect(app.purchases.list().single.items.single.serials.length, 3);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(env.dispose);
  });

  testWidgets('saving is refused while serial numbers are missing', (tester) async {
    final (env, _) = await _open(tester);
    await _tap(tester, find.widgetWithText(FilledButton, 'Add Product').first);
    await tester.enterText(find.widgetWithText(TextFormField, 'Product name *'), 'NVR 8CH');
    await tester.enterText(find.widgetWithText(TextFormField, 'Purchase price (Rs) *'), '9000');
    await tester.enterText(find.widgetWithText(TextFormField, 'Selling price (Rs) *'), '12000');
    await _tap(tester, find.text('Track individual serial numbers'));
    final qty = find.byKey(const ValueKey('receive-qty'));
    await tester.ensureVisible(qty);
    await tester.enterText(qty, '2');
    await tester.pump();
    await _tap(tester, find.byKey(const ValueKey('receive-supplier')));
    await _tap(tester, find.text('Hik Distributor').last);
    await _tap(tester, find.text('Save Product'));
    expect(find.textContaining('Enter one serial number per unit: 0 of 2'), findsOneWidget);
    expect(env.app.catalog.products(), isEmpty, reason: 'no stock without serial numbers');
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(env.dispose);
  });
}
