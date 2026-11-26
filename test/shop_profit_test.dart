// Shop profit counts only stock products (revenue after discounts minus
// actual purchase cost). Non-stock items are billed but not profit. Labour /
// installation is on the customer's invoice and payable (ledger, balance,
// payments), but it is the worker's money: not shop sales, income or profit.
// Separate labour bills saved earlier are kept and still work.
import 'dart:io';

import 'package:al_aqsa_cctv/core/money.dart';
import 'package:al_aqsa_cctv/data/store/data_store.dart';
import 'package:al_aqsa_cctv/domain/models/documents.dart';
import 'package:al_aqsa_cctv/domain/models/labour.dart';
import 'package:al_aqsa_cctv/domain/models/party.dart';
import 'package:al_aqsa_cctv/domain/models/user.dart';
import 'package:al_aqsa_cctv/domain/services/purchase_service.dart';
import 'package:al_aqsa_cctv/domain/services/report_service.dart';
import 'package:al_aqsa_cctv/domain/services/report_tables.dart';
import 'package:al_aqsa_cctv/printing/pdf_docs.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

Future<Object?> err(Future<Object?> Function() f) async {
  try {
    await f();
    return null;
  } catch (e) {
    return e;
  }
}

SaleItem screws(num rate) => SaleItem.custom(kind: SaleLineKind.nonStock, name: 'Screws', qty: q(1), unitPrice: rs(rate), unit: 'box');

void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() async => env.dispose());

  Future<String> camera() async {
    final cam = await env.product('CCTV Camera', cost: 8000, price: 10000);
    final sup = await env.supplier();
    await env.app.purchases.create(supplierId: sup.id, date: env.clock.now, lines: [PurchaseLineInput(productId: cam.id, qty: q(10), unitCost: rs(8000))]);
    return cam.id;
  }

  test('the example: camera Rs 10,000 (cost 8,000) + screws Rs 500 + installation Rs 1,000 on one invoice', () async {
    final app = env.app;
    final camId = await camera();
    final c = await env.customer('DEMO Profit Grahak');
    final sale = await app.sales.complete(app.sales.newDraft().copyWith(customerId: c.id, customerName: c.name, items: [
      app.sales.lineFor(env.reload(camId)),
      screws(500),
      SaleItem.custom(kind: SaleLineKind.service, name: 'Installation Labour', qty: q(1), unitPrice: rs(1000), unit: 'job', worker: 'Karegar Aslam'),
    ]));

    // The customer's invoice: labour is a separate line, all of it payable.
    expect(sale.total, rs(11500));
    expect(sale.items.map((e) => (e.kind, e.net)).toList(), [
      (SaleLineKind.product, rs(10000)),
      (SaleLineKind.nonStock, rs(500)),
      (SaleLineKind.service, rs(1000)),
    ]);
    // Ledger / outstanding: 11,500, once (one ledger entry for the invoice).
    final saleEntries = app.parties.entries(PartyKind.customer, c.id).where((e) => e.refType == 'sale').toList();
    expect(saleEntries.single.debit, rs(11500));
    expect(app.parties.byId(PartyKind.customer, c.id)!.balance, rs(11500));
    expect(app.parties.totalReceivables(), rs(11500));
    expect(app.customerStatements.build(c.id).closingBalance, rs(11500));
    // A payment of 11,500 settles the whole invoice.
    await app.parties.addPayment(kind: PartyKind.customer, partyId: c.id, amount: rs(11500), method: PaymentMethod.cash, againstDocId: sale.id, againstDocNumber: sale.number);
    expect(app.parties.byId(PartyKind.customer, c.id)!.balance, const Money.zero());
    expect(app.sales.paidAgainst(sale.id), rs(11500));
    expect(app.customerStatements.build(c.id).invoices.single.state.name, 'paid');

    // Separate totals.
    expect((sale.productRevenue, sale.nonStockRevenue, sale.labourRevenue, sale.shopSales), (rs(10000), rs(500), rs(1000), rs(10500)));
    final range = DateRange.thisMonth(env.clock.now);
    final p = app.reports.profit(range);
    expect((p.grossSales, p.netSales, p.cogs, p.grossProfit), (rs(10000), rs(10000), rs(8000), rs(2000)));
    expect((p.nonStockSales, p.labourOnInvoices, p.invoicedTotal), (rs(500), rs(1000), rs(11500)));
    final f = app.reports.financials(range);
    expect((f.grossSales, f.discounts, f.netSales, f.cogs, f.grossProfit), (rs(10000), const Money.zero(), rs(10000), rs(8000), rs(2000)));
    expect(f.netOperatingProfit, rs(2000));
    expect((f.nonStockSales, f.labourOnInvoices, f.invoicedTotal), (rs(500), rs(1000), rs(11500)));
    expect(f.cashReceived, rs(11500)); // cash in hand includes the labour collected for the worker
    // Dashboard: shop sales 10,500 (no labour), gross profit 2,000 (no labour).
    expect(app.reports.salesTotal(range), rs(10500));
    expect(app.reports.monthly(1).last.grossProfit, rs(2000));
    expect(app.reports.productSales(range).map((r) => (r.name, r.revenue, r.profit)).toList(), [('CCTV Camera', rs(10000), rs(2000))]);
    final labour = app.reports.labourLines(range).single;
    expect((labour.$2.name, labour.$2.worker, labour.$3), ('Installation Labour', 'Karegar Aslam', rs(1000)));

    // Stock: only the camera.
    expect(env.reload(camId).stockQty, q(9));

    // Expenses come off the product profit.
    await app.expenses.create(category: 'Shop rent', title: 'Rent', amount: rs(500), date: env.clock.now);
    expect(app.reports.financials(range).netOperatingProfit, rs(1500));

    // Reports.
    final b = ReportBuilder(app);
    final pl = b.build(ReportKind.profitLoss, range);
    double v(String label) => pl.rows.firstWhere((r) => r[0] == label)[1] as double;
    expect(v('Net Product Sales'), 10000.0);
    expect(v('GROSS PROFIT'), 2000.0);
    expect(v('Non-stock items billed (screws, clips, accessories; no recorded cost)'), 500.0);
    expect(v("Labour / installation on invoices (worker's money, payable by customers)"), 1000.0);
    final inv = b.build(ReportKind.salesInvoices, range);
    final h = inv.headers;
    expect(inv.rows.single[h.indexOf('Net Total')], 11500.0);
    expect(inv.rows.single[h.indexOf('Product Gross Profit')], 2000.0);
    expect(inv.rows.single[h.indexOf('Non-stock Items')], 500.0);
    expect(inv.rows.single[h.indexOf('Labour (worker)')], 1000.0);
    final byProduct = b.workbook(ReportKind.salesByProduct, range);
    expect(byProduct.first.rows.single[0], 'CCTV Camera');
    expect(byProduct[1].rows.map((r) => (r[0], r[1])).toList(), [('Installation Labour', 'Labour (worker)'), ('Screws', 'Non-stock item')]);
    final daily = b.build(ReportKind.salesDaily, range);
    expect(daily.footer.single[daily.headers.indexOf('Net Product Sales')], 10000.0);
    expect(daily.footer.single[daily.headers.indexOf("Labour / Installation (worker's money)")], 1000.0);
    expect(daily.footer.single[daily.headers.indexOf('Gross Profit (products)')], 2000.0);
    for (final k in ReportKind.values) {
      final t = b.build(k, range);
      for (final row in t.rows) {
        expect(row.length, t.headers.length, reason: '${k.name} row width');
      }
    }

    // Invoice prints with the labour line (A4 and thermal).
    for (final paper in PaperKind.values) {
      final pdf = await invoicePdf(app.ctx.settings, app.sales.byId(sale.id)!, customer: c, paper: paper, paid: app.sales.paidAgainst(sale.id));
      expect(String.fromCharCodes(pdf.take(4)), '%PDF');
      final out = Platform.environment['LABOUR_PDF_OUT'];
      if (out != null) await File('$out/invoice_${paper.name}.pdf').writeAsBytes(pdf);
    }
  });

  test('bill discounts are taken from stock products first, so product profit is never overstated', () async {
    final app = env.app;
    final camId = await camera();
    final s1 = await app.sales.complete(app.sales.newDraft().copyWith(items: [app.sales.lineFor(env.reload(camId)), screws(500)], invoiceDiscount: rs(700)).copyWith(paidAtSale: rs(9800)));
    expect((s1.total, s1.productRevenue, s1.nonStockRevenue), (rs(9800), rs(9300), rs(500)));
    final s2 = await app.sales.complete(app.sales.newDraft().copyWith(items: [app.sales.lineFor(env.reload(camId)), screws(500)], invoiceDiscount: rs(10200)).copyWith(paidAtSale: rs(300)));
    expect((s2.total, s2.productRevenue, s2.nonStockRevenue), (rs(300), rs(0), rs(300)));
    final f = app.reports.financials(DateRange.thisMonth(env.clock.now));
    expect(f.grossProfit, rs(9300 - 8000 + 0 - 8000));
    expect(f.discounts, rs(700 + 10000));
    expect(f.nonStockSales, rs(800));
    // Line revenues always add up to the invoice total.
    for (final s in [s1, s2]) {
      expect(Money.sum(s.lineRevenues()), s.total);
    }

    // A return of the camera from s1 refunds its revenue after the discount, and its cost.
    final r = await app.sales.createReturn(saleId: s1.id, lines: [ReturnLineInput(productId: camId, qty: q(1))], reason: 'x');
    expect(r.total, rs(9300));
    final f2 = app.reports.financials(DateRange.thisMonth(env.clock.now));
    expect(f2.netSales, rs(0));
    expect(f2.grossProfit, rs(-8000) + rs(8000) - rs(8000) + rs(0)); // only s2's camera remains: 0 - 8,000
    expect(f2.nonStockSales, rs(800)); // screws not returned
  });

  test('invoices saved before this change keep their lines and balances; labour can be edited on an invoice', () async {
    final app = env.app;
    final camId = await camera();
    final c = await env.customer('DEMO Old Labour');
    final sale = await app.sales.complete(app.sales.newDraft().copyWith(customerId: c.id, customerName: c.name, items: [app.sales.lineFor(env.reload(camId)), screws(500)]));
    // Simulate an invoice saved before labour bills: add a labour line to the stored record and its ledger entry.
    final j = app.sales.byId(sale.id)!;
    final legacy = j.copyWith(items: [...j.items, SaleItem.custom(kind: SaleLineKind.service, name: 'Installation', qty: q(1), unitPrice: rs(1000))]);
    final entry = app.parties.entries(PartyKind.customer, c.id).singleWhere((e) => e.refType == 'sale');
    await app.ctx.store.commit([
      WriteOp(Boxes.sales, sale.id, legacy.toJson()),
      WriteOp(Boxes.ledger, entry.id, {...entry.toJson(), 'debit': rs(11500).paisa}),
      WriteOp(Boxes.customers, c.id, {...c.toJson(), 'balance': rs(11500).paisa}),
    ]);
    final old = app.sales.byId(sale.id)!;
    expect(old.total, rs(11500)); // invoice unchanged
    expect((old.productRevenue, old.nonStockRevenue, old.labourRevenue, old.shopSales), (rs(10000), rs(500), rs(1000), rs(10500)));
    final range = DateRange.thisMonth(env.clock.now);
    final f = app.reports.financials(range);
    expect((f.grossProfit, f.nonStockSales, f.labourOnInvoices, f.invoicedTotal), (rs(2000), rs(500), rs(1000), rs(11500)));
    expect(app.reports.salesTotal(range), rs(10500));
    expect(app.customerStatements.build(c.id).closingBalance, rs(11500)); // the customer still owes all of it
    expect(app.parties.ledgerBalance(PartyKind.customer, c.id), rs(11500));

    // Editing keeps, adds or removes labour lines; the ledger follows once.
    final kept = await app.sales.editInvoice(sale.id, items: old.items, invoiceDiscount: const Money.zero(), reason: 'note only', notes: 'checked');
    expect(kept.labourRevenue, rs(1000));
    final more = await app.sales.editInvoice(sale.id, items: [...old.items, SaleItem.custom(kind: SaleLineKind.service, name: 'Wiring', qty: q(1), unitPrice: rs(300))], invoiceDiscount: const Money.zero(), reason: 'wiring');
    expect((more.total, more.labourRevenue), (rs(11800), rs(1300)));
    expect(app.parties.byId(PartyKind.customer, c.id)!.balance, rs(11800));
    expect(app.reports.financials(range).grossProfit, rs(2000));
    final removed = await app.sales.editInvoice(sale.id, items: old.items.where((e) => e.kind != SaleLineKind.service).toList(), invoiceDiscount: const Money.zero(), reason: 'labour moved to a labour bill');
    expect(removed.total, rs(10500));
    expect(app.parties.byId(PartyKind.customer, c.id)!.balance, rs(10500));
  });

  test('separate labour bills saved earlier still work: collect, pay the worker, cancel; nothing touches shop accounts', () async {
    final app = env.app;
    final c = await env.customer('DEMO Labour Grahak');
    final balance0 = app.parties.byId(PartyKind.customer, c.id)!.balance;
    final pays0 = app.parties.payments().length;
    final lb = await app.labour.create(
      lines: [
        LabourLine(description: 'CCTV Installation', qty: q(4), rate: rs(500), unit: 'camera'),
        LabourLine(description: 'Wiring labour', qty: q(1), rate: rs(1500), unit: 'job'),
      ],
      customerId: c.id,
      workerName: 'Karegar Bilal',
      discount: rs(500),
      receivedNow: rs(1000),
    );
    expect(lb.number, startsWith('LB-'));
    expect((lb.total, lb.collected, lb.due), (rs(3000), rs(1000), rs(2000)));
    expect(await err(() => app.labour.collect(lb.id, rs(2500))), isNotNull);
    var b = await app.labour.collect(lb.id, rs(2000), method: PaymentMethod.mobileWallet);
    expect(b.due, const Money.zero());
    b = await app.labour.payWorker(lb.id, rs(2500));
    expect((b.paidToWorker, b.heldForWorker), (rs(2500), rs(500)));
    expect(await err(() => app.labour.payWorker(lb.id, rs(1000))), isNotNull);
    // Separate from shop accounts.
    expect(app.parties.byId(PartyKind.customer, c.id)!.balance, balance0);
    expect(app.parties.payments().length, pays0);
    final range = DateRange.thisMonth(env.clock.now);
    expect(app.reports.financials(range).cashReceived, const Money.zero());
    expect(app.reports.salesTotal(range), const Money.zero());
    final s = app.labour.summary();
    expect((s.bills, s.billed, s.collected, s.due, s.paidToWorkers, s.heldForWorkers), (1, rs(3000), rs(3000), const Money.zero(), rs(2500), rs(500)));
    expect(app.labour.byWorker().single, ('Karegar Bilal', rs(3000), rs(3000), rs(2500)));
    expect(app.labour.list(query: 'bilal').length, 1);

    // Validation and permissions.
    expect(await err(() => app.labour.create(lines: const [])), isNotNull);
    expect(await err(() => app.labour.create(lines: [LabourLine(description: ' ', qty: q(1), rate: rs(1))])), isNotNull);
    expect(await err(() => app.labour.cancel(lb.id, ' ')), isNotNull);
    await app.auth.createUser(username: 'cashier', password: 'secret123', displayName: 'Cashier', role: UserRole.staff);
    await app.auth.login('cashier', 'secret123');
    expect(await err(() => app.labour.cancel(lb.id, 'wrong')), isNotNull);
    await app.auth.login('owner', 'secret123');
    final x = await app.labour.cancel(lb.id, 'entered twice');
    expect((x.cancelled, x.due), (true, const Money.zero()));
    expect(app.labour.summary().bills, 0);
    expect(await err(() => app.labour.collect(lb.id, rs(1))), isNotNull);
  });
}
