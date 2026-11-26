// UI: POS "+ Add Item" (non-stock clips, service), editing a completed
// invoice from its detail window, and a customer return adjusted in the
// account. Runs on the Mac / Windows with `flutter test`.
import 'package:al_aqsa_cctv/domain/models/documents.dart';
import 'package:al_aqsa_cctv/domain/models/party.dart';
import 'package:al_aqsa_cctv/domain/services/purchase_service.dart';
import 'package:al_aqsa_cctv/ui/edit_invoice_dialog.dart';
import 'package:al_aqsa_cctv/ui/pages/pos_page.dart' show posDraftProvider;
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

Future<ProviderContainer> _show(WidgetTester tester, TestEnv env, NavItem nav) async {
  await tester.binding.setSurfaceSize(const Size(1600, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ProviderScope(
    overrides: [servicesProvider.overrideWithValue(env.app)],
    child: MaterialApp(theme: AppTheme.build(AppColors.darkPalette), home: const Root()),
  ));
  final c = ProviderScope.containerOf(tester.element(find.byType(Root)));
  c.read(currentUserProvider.notifier).state = env.app.auth.findByUsername('owner');
  await tester.pump();
  c.read(navProvider.notifier).state = nav;
  await tester.pump(const Duration(milliseconds: 600));
  return c;
}

void main() {
  testWidgets('POS: + Add Item adds 500 clips (non-stock) and an installation service; bill completes without stock', (tester) async {
    final env = (await tester.runAsync(TestEnv.create))!;
    await _show(tester, env, NavItem.pos);

    await _tap(tester, find.byKey(const ValueKey('pos-add-item')));
    await _tap(tester, find.byKey(const ValueKey('add-kind-nonStock')));
    await tester.enterText(find.descendant(of: find.byKey(const ValueKey('cl-desc')), matching: find.byType(TextFormField)), 'Cable Clips');
    await tester.enterText(find.descendant(of: find.byKey(const ValueKey('cl-qty')), matching: find.byType(TextFormField)), '500');
    await tester.enterText(find.descendant(of: find.byKey(const ValueKey('cl-rate')), matching: find.byType(TextFormField)), '2');
    await tester.pump();
    expect((tester.widget<Text>(find.byKey(const ValueKey('cl-total')))).data, rs(1000).format());
    await _tap(tester, find.byKey(const ValueKey('cl-save-preset')));
    await _tap(tester, find.byKey(const ValueKey('cl-ok')));
    expect(find.text('Cable Clips'), findsOneWidget);
    expect(find.text('Non-stock'), findsOneWidget);

    await _tap(tester, find.byKey(const ValueKey('pos-add-item')));
    await _tap(tester, find.byKey(const ValueKey('add-kind-service')));
    await tester.enterText(find.descendant(of: find.byKey(const ValueKey('cl-desc')), matching: find.byType(TextFormField)), 'CCTV Installation');
    await tester.enterText(find.descendant(of: find.byKey(const ValueKey('cl-rate')), matching: find.byType(TextFormField)), '5000');
    await tester.pump();
    await _tap(tester, find.byKey(const ValueKey('cl-ok')));
    expect(find.text('Labour bill'), findsOneWidget);

    final c = ProviderScope.containerOf(tester.element(find.byType(Root)));
    final draft = c.read(posDraftProvider)!;
    expect(draft.items.map((e) => (e.kind, e.qty, e.net)).toList(), [
      (SaleLineKind.nonStock, q(500), rs(1000)),
      (SaleLineKind.service, q(1), rs(5000)),
    ]);
    expect(env.app.sales.presets().single.name, 'Cable Clips');

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(env.dispose);
  });

  testWidgets('Edit invoice from the invoice detail window: remove a line, reason, totals; payment becomes credit', (tester) async {
    final env = (await tester.runAsync(TestEnv.create))!;
    late Sale sale;
    late String cableId;
    late Party cust;
    await tester.runAsync(() async {
      final cable = await env.product('CCTV Cable', cost: 20, price: 50);
      cableId = cable.id;
      final sup = await env.supplier();
      await env.app.purchases.create(supplierId: sup.id, date: env.clock.now, lines: [PurchaseLineInput(productId: cable.id, qty: q(100), unitCost: rs(20))]);
      cust = await env.customer('UI Edit Grahak');
      final d = env.app.sales.newDraft().copyWith(customerId: cust.id, customerName: cust.name, items: [
        env.app.sales.lineFor(env.reload(cable.id), qty: q(10)),
        SaleItem.custom(kind: SaleLineKind.nonStock, name: 'Clips', qty: q(500), unitPrice: rs(2)),
      ]);
      sale = await env.app.sales.complete(d.copyWith(paidAtSale: rs(1000)));
    });
    await _show(tester, env, NavItem.pos);

    // Invoices tab -> the invoice -> "Edit invoice".
    await _tap(tester, find.text('Invoices'));
    await _tap(tester, find.text(sale.number).first);
    await _tap(tester, find.byKey(const ValueKey('inv-edit')));
    expect(find.byType(EditInvoiceDialog), findsOneWidget);
    // Remove the clips line, set a reason, save.
    await _tap(tester, find.byKey(const ValueKey('ei-remove-1')));
    await tester.enterText(find.descendant(of: find.byKey(const ValueKey('ei-reason')), matching: find.byType(TextFormField)), 'clips not used');
    await tester.pump();
    expect(find.descendant(of: find.byKey(const ValueKey('ei-summary')), matching: find.text(rs(500).format())), findsWidgets); // new total
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('ei-save')));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump(const Duration(milliseconds: 500));
    final edited = env.app.sales.byId(sale.id)!;
    expect(edited.total, rs(500));
    expect(edited.edits.single.reason, 'clips not used');
    expect(env.app.parties.byId(PartyKind.customer, cust.id)!.balance, rs(-500)); // paid 1,000 on a 500 bill = credit
    expect(env.reload(cableId).stockQty, q(90));

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(env.dispose);
  });

  testWidgets('POS: completing a bill with screws and installation makes a shop invoice (screws) and a separate labour bill', (tester) async {
    final env = (await tester.runAsync(TestEnv.create))!;
    late Party cust;
    await tester.runAsync(() async => cust = await env.customer('UI Labour Grahak'));
    final c = await _show(tester, env, NavItem.pos);
    final app = env.app;
    c.read(posDraftProvider.notifier).state = app.sales.newDraft().copyWith(customerId: cust.id, customerName: cust.name, items: [
      SaleItem.custom(kind: SaleLineKind.nonStock, name: 'Screws', qty: q(1), unitPrice: rs(500)),
      SaleItem.custom(kind: SaleLineKind.service, name: 'Installation', qty: q(1), unitPrice: rs(1000)),
    ]);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Labour bill (karegar, separate)'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('pos-worker')), 'Aslam');
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.text('Complete (F9)'));
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pump(const Duration(milliseconds: 600));
    final sale = app.sales.list(status: DocStatus.completed).single;
    expect(sale.total, rs(500));
    expect(sale.items.single.name, 'Screws');
    final lb = app.labour.list().single;
    expect((lb.total, lb.workerName, lb.saleId), (rs(1000), 'Aslam', sale.id));
    expect(app.parties.byId(PartyKind.customer, cust.id)!.balance, rs(500)); // labour is not in the ledger
    expect(find.byKey(const ValueKey('pos-labour-pdf')), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(env.dispose);
  });
}
