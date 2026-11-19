// UI: "Add More Serial Numbers" on the product row menu; adding a product
// that already exists offers to restock the existing one instead.
import 'package:al_aqsa_cctv/domain/services/purchase_service.dart';
import 'package:al_aqsa_cctv/ui/providers.dart';
import 'package:al_aqsa_cctv/ui/shell/app_shell.dart';
import 'package:al_aqsa_cctv/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pump();
  await tester.tap(f);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  testWidgets('same product again -> "Buy more stock" opens a purchase for the existing product', (tester) async {
    final env = (await tester.runAsync(TestEnv.create))!;
    await tester.runAsync(() async {
      final cam = await env.product('Dahua 4MP Dome', serial: true, brand: 'Dahua');
      final sup = await env.supplier();
      await env.app.purchases.create(supplierId: sup.id, date: env.clock.now, lines: [PurchaseLineInput(productId: cam.id, qty: q(1), unitCost: rs(4000), serials: const ['A1'])]);
    });
    await tester.binding.setSurfaceSize(const Size(1500, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [servicesProvider.overrideWithValue(env.app)],
      child: MaterialApp(theme: AppTheme.build(AppColors.darkPalette), home: const Root()),
    ));
    final c = ProviderScope.containerOf(tester.element(find.byType(Root)));
    c.read(currentUserProvider.notifier).state = env.app.auth.findByUsername('owner');
    await tester.pump();
    c.read(navProvider.notifier).state = NavItem.products;
    await tester.pump(const Duration(milliseconds: 600));

    // Row menu offers "Add More Serial Numbers": read-only product details.
    await _tap(tester, find.byKey(const ValueKey('row-menu')).first);
    await _tap(tester, find.byKey(const ValueKey('row-add-serials')));
    expect(find.text('Add More Serial Numbers'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('as-name')), matching: find.text('Dahua 4MP Dome')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('as-brand')), matching: find.text('Dahua')), findsOneWidget);
    expect(find.text('Required 0 • Entered 0 • Remaining 0'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('as-qty')), '2');
    await tester.pump();
    expect(find.text('Required 2 • Entered 0 • Remaining 2'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('as-save'))).onPressed, isNull); // no serials yet
    // Batch value follows the cost typed (5200 x 2).
    await tester.enterText(find.widgetWithText(TextField, 'Cost per unit (Rs) *'), '5200');
    await tester.pump();
    expect(find.textContaining('Batch value: Rs 10,400.00'), findsOneWidget);
    await _tap(tester, find.text('Cancel').last);

    await _tap(tester, find.text('Add Product'));
    await tester.enterText(find.widgetWithText(TextFormField, 'Product name *'), 'Dahua 4MP Dome');
    await tester.enterText(find.widgetWithText(TextFormField, 'Brand (e.g. Hikvision, Dahua)'), 'Dahua');
    await tester.enterText(find.widgetWithText(TextFormField, 'Purchase price (Rs) *'), '5000');
    await tester.enterText(find.widgetWithText(TextFormField, 'Selling price (Rs) *'), '6500');
    await _tap(tester, find.text('Save Product'));
    expect(find.byKey(const ValueKey('product-exists')), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('product-exists-buy')));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Add More Serial Numbers'), findsOneWidget); // restock dialog for the existing product
    expect(env.app.catalog.products(includeArchived: true).length, 1); // no duplicate product
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(env.dispose);
  });
}
