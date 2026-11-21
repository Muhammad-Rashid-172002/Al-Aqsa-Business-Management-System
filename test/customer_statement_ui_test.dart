// UI: "Print Customer Statement" from the Customers toolbar, the row menu
// and the customer window; period choices and the summary shown.
import 'package:al_aqsa_cctv/domain/models/party.dart';
import 'package:al_aqsa_cctv/domain/services/purchase_service.dart';
import 'package:al_aqsa_cctv/ui/customer_statement_flow.dart';
import 'package:al_aqsa_cctv/ui/providers.dart';
import 'package:al_aqsa_cctv/ui/shell/app_shell.dart';
import 'package:al_aqsa_cctv/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

Future<void> _show(WidgetTester tester, TestEnv env) async {
  await tester.binding.setSurfaceSize(const Size(1600, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ProviderScope(
    overrides: [servicesProvider.overrideWithValue(env.app)],
    child: MaterialApp(theme: AppTheme.build(AppColors.darkPalette), home: const Root()),
  ));
  final c = ProviderScope.containerOf(tester.element(find.byType(Root)));
  c.read(currentUserProvider.notifier).state = env.app.auth.findByUsername('owner');
  await tester.pump();
  c.read(navProvider.notifier).state = NavItem.customers;
  await tester.pump(const Duration(milliseconds: 600));
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pump();
  await tester.tap(f);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('Print Customer Statement: toolbar, row menu and customer window open the statement with its summary', (tester) async {
    final env = (await tester.runAsync(TestEnv.create))!;
    late Party cust;
    await tester.runAsync(() async {
      final cable = await env.product('Cable Roll', cost: 100, price: 1000);
      final sup = await env.supplier();
      await env.app.purchases.create(supplierId: sup.id, date: env.clock.now, lines: [PurchaseLineInput(productId: cable.id, qty: q(10), unitCost: rs(100))]);
      cust = await env.app.parties.create(kind: PartyKind.customer, name: 'Statement Grahak', phone: '03001112223', openingBalance: rs(500));
      final d = env.app.sales.newDraft().copyWith(customerId: cust.id, customerName: cust.name, items: [env.app.sales.lineFor(env.reload(cable.id), qty: q(3))]);
      await env.app.sales.complete(d.copyWith(paidAtSale: rs(1000)));
    });
    await _show(tester, env);

    // Toolbar: pick the customer, then the dialog.
    await _tap(tester, find.byKey(const ValueKey('print-customer-statement')));
    await _tap(tester, find.text('Statement Grahak').last);
    expect(find.byType(CustomerStatementDialog), findsOneWidget);
    expect(find.byKey(const ValueKey('cs-period-complete')), findsOneWidget);
    expect(find.byKey(const ValueKey('cs-preview')), findsOneWidget);
    expect(find.byKey(const ValueKey('cs-print')), findsOneWidget);
    expect(find.byKey(const ValueKey('cs-pdf')), findsOneWidget);
    final summary = find.byKey(const ValueKey('cs-summary'));
    expect(find.descendant(of: summary, matching: find.text(rs(2500).format())), findsOneWidget); // 500 + 3,000 - 1,000
    expect(find.descendant(of: summary, matching: find.textContaining('1 partly paid')), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('cs-period-custom')));
    expect(find.byKey(const ValueKey('cs-from')), findsOneWidget);
    expect(find.byKey(const ValueKey('cs-to')), findsOneWidget);
    await _tap(tester, find.text('Close'));

    // Row menu.
    await _tap(tester, find.byKey(const ValueKey('row-menu')).first);
    await _tap(tester, find.byKey(const ValueKey('row-statement')));
    expect(find.byType(CustomerStatementDialog), findsOneWidget);
    await _tap(tester, find.text('Close'));

    // Customer window.
    await _tap(tester, find.text('Statement Grahak').first);
    await _tap(tester, find.byKey(const ValueKey('detail-customer-statement')));
    expect(find.byType(CustomerStatementDialog), findsOneWidget);
    await _tap(tester, find.text('Close'));

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(env.dispose);
  });
}
