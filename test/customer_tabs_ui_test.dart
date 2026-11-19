// UI: Customers tabs (balance due / paid up / advance) with billed and paid
// columns; a name typed at the POS saves the customer with the bill.
import 'package:al_aqsa_cctv/domain/models/party.dart';
import 'package:al_aqsa_cctv/domain/services/purchase_service.dart';
import 'package:al_aqsa_cctv/ui/providers.dart';
import 'package:al_aqsa_cctv/ui/shell/app_shell.dart';
import 'package:al_aqsa_cctv/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

Future<ProviderContainer> _show(WidgetTester tester, TestEnv env, NavItem page) async {
  await tester.binding.setSurfaceSize(const Size(1600, 1000));
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

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pump();
  await tester.tap(f);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('tabs split customers by balance; columns show billed, paid and balance', (tester) async {
    final env = (await tester.runAsync(TestEnv.create))!;
    await tester.runAsync(() async {
      await env.app.parties.create(kind: PartyKind.customer, name: 'Owes Money', openingBalance: rs(500));
      await env.app.parties.create(kind: PartyKind.customer, name: 'All Paid');
      final adv = await env.app.parties.create(kind: PartyKind.customer, name: 'Gave Advance');
      await env.app.parties.addPayment(kind: PartyKind.customer, partyId: adv.id, amount: rs(300), method: PaymentMethod.cash);
    });
    await _show(tester, env, NavItem.customers);
    expect(find.text('Total billed'), findsOneWidget);
    expect(find.text('Paid'), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('ptab-due')));
    expect(find.text('Owes Money'), findsOneWidget);
    expect(find.text('All Paid'), findsNothing);
    await _tap(tester, find.byKey(const ValueKey('ptab-paid')));
    expect(find.text('All Paid'), findsOneWidget);
    expect(find.text('Owes Money'), findsNothing);
    await _tap(tester, find.byKey(const ValueKey('ptab-advance')));
    expect(find.text('Gave Advance'), findsOneWidget);
    expect(find.text('${rs(300).format()} adv.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(env.dispose);
  });

  testWidgets('POS: a typed customer name and mobile are saved to Customers with a credit bill', (tester) async {
    final env = (await tester.runAsync(TestEnv.create))!;
    await tester.runAsync(() async {
      final cable = await env.product('Cable Roll', cost: 100, price: 1000);
      final sup = await env.supplier();
      await env.app.purchases.create(supplierId: sup.id, date: env.clock.now, lines: [PurchaseLineInput(productId: cable.id, qty: q(5), unitCost: rs(100))]);
    });
    await _show(tester, env, NavItem.pos);
    await _tap(tester, find.text('Cable Roll').first);
    await tester.enterText(find.byKey(const ValueKey('pos-qc-name')), 'Naya Grahak');
    await tester.enterText(find.byKey(const ValueKey('pos-qc-phone')), '03214445556');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.f9); // complete (nothing received: on credit)
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 500));
    final c = env.app.parties.list(PartyKind.customer).single;
    expect(c.name, 'Naya Grahak');
    expect(c.phone, '03214445556');
    expect(c.balance, rs(1000));
    expect(env.app.sales.list(customerId: c.id).length, 1);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(env.dispose);
  });
}
