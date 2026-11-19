// UI: pages update in place after a change. No page switch, no reopen.
// Each case changes data through the services while the page is on screen
// and checks the page shows it after one frame.
import 'package:al_aqsa_cctv/domain/models/party.dart';
import 'package:al_aqsa_cctv/domain/services/purchase_service.dart';
import 'package:al_aqsa_cctv/ui/providers.dart';
import 'package:al_aqsa_cctv/ui/shell/app_shell.dart';
import 'package:al_aqsa_cctv/ui/theme.dart';
import 'package:al_aqsa_cctv/ui/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

Future<ProviderContainer> _show(WidgetTester tester, TestEnv env, NavItem page) async {
  await tester.binding.setSurfaceSize(const Size(1500, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ProviderScope(
    overrides: [servicesProvider.overrideWithValue(env.app)],
    child: MaterialApp(theme: AppTheme.build(AppColors.darkPalette), home: const Root()),
  ));
  final c = ProviderScope.containerOf(tester.element(find.byType(Root)));
  c.read(currentUserProvider.notifier).state = env.app.auth.findByUsername('owner');
  await tester.pump();
  c.read(navProvider.notifier).state = page;
  await tester.pump(const Duration(milliseconds: 600));
  return c;
}

/// Lets the change stream deliver, then draws one frame.
Future<void> _frame(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _close(WidgetTester tester, TestEnv env) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpWidget(const SizedBox());
  await tester.runAsync(env.dispose);
}

void main() {
  testWidgets('Customers: add / edit / archive / restore show at once; search text is kept', (tester) async {
    final env = (await tester.runAsync(TestEnv.create))!;
    final c = await _show(tester, env, NavItem.customers);
    final nav = c.read(navProvider);
    await tester.enterText(find.descendant(of: find.byType(SearchBox), matching: find.byType(TextField)).first, 'trad');
    await tester.pump(const Duration(milliseconds: 400));

    final ali = (await tester.runAsync(() => env.app.parties.create(kind: PartyKind.customer, name: 'Ali Traders', phone: '0300')))!;
    await tester.runAsync(() => env.app.parties.create(kind: PartyKind.customer, name: 'Bilal'));
    await _frame(tester);
    expect(find.text('Ali Traders'), findsOneWidget);
    expect(find.text('Bilal'), findsNothing); // the search filter still applies
    expect(c.read(navProvider), nav); // no page switch happened

    await tester.runAsync(() => env.app.parties.update(env.app.parties.byId(PartyKind.customer, ali.id)!.copyWith(name: 'Ali Traders & Sons')));
    await _frame(tester);
    expect(find.text('Ali Traders & Sons'), findsOneWidget);

    await tester.runAsync(() => env.app.parties.addPayment(kind: PartyKind.customer, partyId: ali.id, amount: rs(1000), method: PaymentMethod.cash));
    await _frame(tester);
    expect(find.text('${rs(1000).format()} adv.'), findsOneWidget); // balance column updated (an advance)

    await tester.runAsync(() => env.app.parties.deleteOrArchive(PartyKind.customer, ali.id));
    await _frame(tester);
    expect(find.text('Ali Traders & Sons'), findsNothing);
    await tester.runAsync(() => env.app.parties.restore(PartyKind.customer, ali.id));
    await _frame(tester);
    expect(find.text('Ali Traders & Sons'), findsOneWidget);
    await _close(tester, env);
  });

  testWidgets('Products: stock column follows purchases and sales; new product appears', (tester) async {
    final env = (await tester.runAsync(TestEnv.create))!;
    await _show(tester, env, NavItem.products);
    final cam = (await tester.runAsync(() => env.product('Dome Camera')))!;
    await _frame(tester);
    expect(find.text('Dome Camera'), findsOneWidget);
    await tester.runAsync(() async {
      final sup = await env.supplier();
      await env.app.purchases.create(supplierId: sup.id, date: env.clock.now, lines: [PurchaseLineInput(productId: cam.id, qty: q(7), unitCost: rs(1000))]);
    });
    await _frame(tester);
    expect(find.text('7'), findsWidgets);
    await tester.runAsync(() async {
      final d = env.app.sales.newDraft().copyWith(items: [env.app.sales.lineFor(env.reload(cam.id), qty: q(3))]);
      await env.app.sales.complete(d.copyWith(paidAtSale: d.total));
    });
    await _frame(tester);
    expect(find.text('4'), findsWidgets);
    await _close(tester, env);
  });

  testWidgets('Expenses and Profit & Loss update while open', (tester) async {
    final env = (await tester.runAsync(TestEnv.create))!;
    final c = await _show(tester, env, NavItem.expenses);
    await tester.runAsync(() => env.app.expenses.create(category: 'Shop rent', title: 'Live rent', amount: rs(25000), date: env.clock.now));
    await _frame(tester);
    expect(find.text('Live rent'), findsOneWidget);

    c.read(navProvider.notifier).state = NavItem.finance;
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text(rs(25000).format()), findsWidgets);
    await tester.runAsync(() => env.app.expenses.create(category: 'Electricity bill', title: 'Bill', amount: rs(5000), date: env.clock.now));
    await _frame(tester);
    await tester.pump(const Duration(seconds: 1)); // animated figures
    expect(find.text(rs(30000).format()), findsWidgets);
    await _close(tester, env);
  });

  testWidgets('Open customer details dialog refreshes after a payment is recorded', (tester) async {
    final env = (await tester.runAsync(TestEnv.create))!;
    final ali = (await tester.runAsync(() => env.app.parties.create(kind: PartyKind.customer, name: 'Ali Traders', openingBalance: rs(5000))))!;
    await _show(tester, env, NavItem.customers);
    await tester.tap(find.text('Ali Traders'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text(rs(5000).format()), findsWidgets);
    await tester.runAsync(() => env.app.parties.addPayment(kind: PartyKind.customer, partyId: ali.id, amount: rs(2000), method: PaymentMethod.cash));
    await _frame(tester);
    expect(find.text(rs(3000).format()), findsWidgets);
    await _close(tester, env);
  });
}
