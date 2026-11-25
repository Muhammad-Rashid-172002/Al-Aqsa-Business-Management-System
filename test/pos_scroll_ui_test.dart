// POS scrolling with many products and a long bill, at a tall, a laptop
// (1366x768 at 125%) and a very short window: the mouse wheel scrolls the
// bill and the product grid, the last bill line can be reached and its
// quantity / remove buttons work, Complete stays reachable, a line with 20
// serial numbers is collapsed, and nothing overflows.
// Widget test: runs on the Mac / Windows (`flutter test`).
import 'package:al_aqsa_cctv/domain/services/purchase_service.dart';
import 'package:al_aqsa_cctv/ui/pages/pos_page.dart';
import 'package:al_aqsa_cctv/ui/providers.dart';
import 'package:al_aqsa_cctv/ui/shell/app_shell.dart';
import 'package:al_aqsa_cctv/ui/theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

const _windows = [
  ('tall 1920x1080', Size(1920, 1080), 1.0),
  ('laptop 1366x768 @125%', Size(1366, 768), 1.25),
  ('short 800x500', Size(800, 500), 1.0),
];

ScrollableState _scrollableIn(WidgetTester tester, Finder area) =>
    tester.state<ScrollableState>(find.descendant(of: area, matching: find.byType(Scrollable)).first);

Future<void> _wheel(WidgetTester tester, Finder over, double dy) async {
  final at = tester.getCenter(over);
  final pointer = TestPointer(1, PointerDeviceKind.mouse);
  await tester.sendEventToBinding(pointer.hover(at));
  await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  for (final (label, physical, dpr) in _windows) {
    testWidgets('POS scrolls with 80 products and a 30-line bill at $label', (tester) async {
      final env = (await tester.runAsync(TestEnv.create))!;
      late List<String> ids;
      late String camId;
      await tester.runAsync(() async {
        final sup = await env.supplier();
        ids = [];
        for (var i = 0; i < 80; i++) {
          final p = await env.product('Item ${i.toString().padLeft(2, '0')} Cable', cost: 10, price: 20);
          ids.add(p.id);
        }
        final cam = await env.product('Bulk Camera', cost: 3000, price: 3600, serial: true);
        camId = cam.id;
        await env.app.purchases.create(supplierId: sup.id, date: env.clock.now, lines: [
          for (final id in ids) PurchaseLineInput(productId: id, qty: q(100), unitCost: rs(10)),
          PurchaseLineInput(productId: cam.id, qty: q(20), unitCost: rs(3000), serials: [for (var k = 0; k < 20; k++) 'BULK${k.toString().padLeft(3, '0')}']),
        ]);
      });

      tester.view.physicalSize = physical * dpr;
      tester.view.devicePixelRatio = dpr;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        overrides: [servicesProvider.overrideWithValue(env.app)],
        child: MaterialApp(theme: AppTheme.build(AppColors.darkPalette), home: const Root()),
      ));
      final c = ProviderScope.containerOf(tester.element(find.byType(Root)));
      c.read(currentUserProvider.notifier).state = env.app.auth.findByUsername('owner');
      await tester.pump();
      c.read(navProvider.notifier).state = NavItem.pos;
      await tester.pump(const Duration(milliseconds: 600));

      // A long bill: 29 cable lines and one camera line with 20 serials.
      final app = env.app;
      final keys = [for (final r in app.serials.inStockFor(camId)) r.key];
      c.read(posDraftProvider.notifier).state = app.sales.newDraft().copyWith(items: [
        app.sales.lineFor(env.reload(camId), qty: q(20), serials: keys),
        for (final id in ids.take(29)) app.sales.lineFor(env.reload(id)),
      ]);
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.takeException(), isNull, reason: 'layout error at $label');

      // Long serial list collapsed, can be expanded.
      expect(find.text('+16 more'), findsOneWidget);

      // Bill area: the mouse wheel scrolls it.
      final billArea = find.byKey(const ValueKey('pos-bill-scroll')).evaluate().isNotEmpty
          ? find.byKey(const ValueKey('pos-bill-scroll'))
          : find.byKey(const ValueKey('pos-cart'));
      expect(billArea, findsOneWidget);
      final bill = _scrollableIn(tester, billArea);
      expect(bill.position.maxScrollExtent > 0, isTrue, reason: 'a 30-line bill must scroll at $label');
      final before = bill.position.pixels;
      await _wheel(tester, billArea, 400);
      expect(bill.position.pixels > before, isTrue, reason: 'mouse wheel did not scroll the bill at $label');

      // The last line is reachable and its + button works.
      final last = find.descendant(of: billArea, matching: find.text('Item 28 Cable'));
      await tester.scrollUntilVisible(last, 200, scrollable: find.descendant(of: billArea, matching: find.byType(Scrollable)).first);
      await tester.pump();
      final row = find.ancestor(of: last, matching: find.byType(InkWell)).first;
      final plus = find.descendant(of: row, matching: find.byIcon(Icons.add_circle_outline));
      await tester.tap(plus);
      await tester.pump(const Duration(milliseconds: 300));
      expect(c.read(posDraftProvider)!.items.last.qty, q(2));
      // ...and remove works.
      await tester.tap(find.descendant(of: row, matching: find.byIcon(Icons.close)));
      await tester.pump(const Duration(milliseconds: 300));
      expect(c.read(posDraftProvider)!.items.length, 29);

      // Complete is reachable (pinned, or at the end of the one scroll area).
      final complete = find.text('Complete (F9)');
      await tester.ensureVisible(complete);
      await tester.pump(const Duration(milliseconds: 300));
      final r = tester.getRect(complete);
      final win = tester.view.physicalSize / tester.view.devicePixelRatio;
      expect(r.bottom <= win.height + 0.5 && r.top >= 0, isTrue, reason: 'Complete off screen at $label: $r');

      // Totals are still right.
      final d = c.read(posDraftProvider)!;
      expect(d.total, rs(20 * 3600 + 28 * 20));

      // Product grid: the wheel scrolls it independently.
      final grid = find.byKey(const ValueKey('pos-grid'));
      final g = _scrollableIn(tester, grid);
      final gBefore = g.position.pixels;
      final billPos = bill.position.pixels;
      await _wheel(tester, grid, 500);
      expect(g.position.pixels > gBefore, isTrue, reason: 'grid did not scroll at $label');
      expect(bill.position.pixels, billPos, reason: 'scrolling the grid moved the bill at $label');
      expect(tester.takeException(), isNull);

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(env.dispose);
    });
  }
}
