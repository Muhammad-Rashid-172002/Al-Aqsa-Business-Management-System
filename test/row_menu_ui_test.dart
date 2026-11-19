// UI: the ⋮ row menu and the Delete confirmation in each module.
import 'package:al_aqsa_cctv/domain/models/party.dart';
import 'package:al_aqsa_cctv/domain/services/purchase_service.dart';
import 'package:al_aqsa_cctv/ui/providers.dart';
import 'package:al_aqsa_cctv/ui/shell/app_shell.dart';
import 'package:al_aqsa_cctv/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

Future<void> _show(WidgetTester tester, TestEnv env, NavItem page, {Size size = const Size(1600, 1000)}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ProviderScope(
    overrides: [servicesProvider.overrideWithValue(env.app)],
    child: MaterialApp(theme: AppTheme.build(AppColors.darkPalette), home: const Root()),
  ));
  final c = ProviderScope.containerOf(tester.element(find.byType(Root)));
  c.read(currentUserProvider.notifier).state = env.app.auth.findByUsername('owner');
  await tester.pump();
  c.read(navProvider.notifier).state = page;
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pump();
  await tester.tap(f);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// Opens the ⋮ menu of the first row and returns the labels shown.
Future<void> _openMenu(WidgetTester tester) => _tap(tester, find.byKey(const ValueKey('row-menu')).first);

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _close(WidgetTester tester, TestEnv env) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpWidget(const SizedBox());
  await tester.runAsync(env.dispose);
}

/// Second step of the owner's permanent delete: tick "I understand", confirm.
Future<void> _confirmPermanent(WidgetTester tester) async {
  expect(find.byKey(const ValueKey('pd-final')), findsOneWidget);
  expect(tester.widget<FilledButton>(find.byKey(const ValueKey('pd-final-delete'))).onPressed, isNull); // not before ticking
  await _tap(tester, find.byKey(const ValueKey('pd-understand')));
  await _tap(tester, find.byKey(const ValueKey('pd-final-delete')));
  await _settle(tester);
}

void main() {
  testWidgets('customer: ⋮ shows View/Edit/Delete; Cancel keeps it; Delete -> Permanently Delete erases it', (tester) async {
    final env = (await tester.runAsync(TestEnv.create))!;
    final cust = (await tester.runAsync(() => env.customer('Zubair Electric')))!;
    await _show(tester, env, NavItem.customers);
    await _openMenu(tester);
    expect(find.byKey(const ValueKey('row-view')), findsOneWidget);
    expect(find.byKey(const ValueKey('row-edit')), findsOneWidget);
    expect(find.byKey(const ValueKey('row-delete')), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('row-delete')));
    expect(find.byKey(const ValueKey('pd-impact')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('pd-impact')), matching: find.text('Zubair Electric')), findsOneWidget);
    expect(find.text('Customer'), findsWidgets); // record type shown
    await _tap(tester, find.byKey(const ValueKey('pd-cancel')));
    expect(env.app.parties.byId(PartyKind.customer, cust.id), isNotNull);

    await _openMenu(tester);
    await _tap(tester, find.byKey(const ValueKey('row-delete')));
    await _tap(tester, find.byKey(const ValueKey('pd-delete')));
    expect(find.textContaining('This cannot be undone.'), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('pd-final-cancel')));
    expect(env.app.parties.byId(PartyKind.customer, cust.id), isNotNull); // cancel at step 2 changes nothing

    await _openMenu(tester);
    await _tap(tester, find.byKey(const ValueKey('row-delete')));
    await _tap(tester, find.byKey(const ValueKey('pd-delete')));
    await _confirmPermanent(tester);
    expect(env.app.parties.byId(PartyKind.customer, cust.id), isNull);
    expect(find.textContaining('permanently deleted and verified'), findsWidgets);
    expect(find.text('Zubair Electric'), findsNothing); // gone from the list at once
    await _close(tester, env);
  });

  testWidgets('product with stock cannot be erased: explained, archive offered instead; narrow window', (tester) async {
    final env = (await tester.runAsync(TestEnv.create))!;
    await tester.runAsync(() async {
      final cam = await env.product('Dome Camera');
      final sup = await env.supplier();
      await env.app.purchases.create(supplierId: sup.id, date: env.clock.now, lines: [PurchaseLineInput(productId: cam.id, qty: q(3), unitCost: rs(1000))]);
    });
    await _show(tester, env, NavItem.products, size: const Size(900, 760));
    await _openMenu(tester);
    await _tap(tester, find.byKey(const ValueKey('row-delete')));
    expect(find.text('This record cannot be permanently deleted:'), findsOneWidget);
    expect(find.byKey(const ValueKey('pd-delete')), findsNothing);
    await _tap(tester, find.byKey(const ValueKey('pd-archive')));
    await _settle(tester);
    final p = env.app.catalog.products(includeArchived: true).single;
    expect(p.archived, isTrue);
    expect(p.stockQty, q(3));
    await _close(tester, env);
  });

  testWidgets('expense is erased permanently (P&L drops); category menu has Edit/Delete only', (tester) async {
    final env = (await tester.runAsync(TestEnv.create))!;
    await tester.runAsync(() async {
      await env.app.expenses.create(category: 'Shop rent', title: 'Rent', amount: rs(30000), date: env.clock.now);
      await env.app.catalog.saveCategory('Cables');
    });
    await _show(tester, env, NavItem.expenses);
    await _openMenu(tester);
    expect(find.byKey(const ValueKey('row-view')), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('row-delete')));
    expect(find.textContaining('Profit & Loss and expense reports will no longer include Rs 30,000.00'), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('pd-delete')));
    await _confirmPermanent(tester);
    expect(env.app.expenses.list(includeDeleted: true), isEmpty);

    final c = ProviderScope.containerOf(tester.element(find.byType(Root)));
    c.read(navProvider.notifier).state = NavItem.categories;
    await tester.pump(const Duration(milliseconds: 600));
    await _openMenu(tester);
    expect(find.byKey(const ValueKey('row-view')), findsNothing);
    expect(find.byKey(const ValueKey('row-edit')), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('row-delete')));
    await _tap(tester, find.byKey(const ValueKey('pd-delete')));
    await _confirmPermanent(tester);
    expect(env.app.catalog.categories(), isEmpty);
    await _close(tester, env);
  });
}
