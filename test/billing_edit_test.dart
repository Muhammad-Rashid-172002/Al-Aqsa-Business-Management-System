// Non-stock items (clips, screws), services / labour, editing a completed
// invoice (stock, serials, payments, ledger, history), return settlement
// (cash refund / account adjustment, customer credit), receipts, statement,
// and data after restart.
import 'dart:io';

import 'package:al_aqsa_cctv/core/money.dart';
import 'package:al_aqsa_cctv/core/password_hasher.dart';
import 'package:al_aqsa_cctv/data/migrations.dart';
import 'package:al_aqsa_cctv/data/store/data_store.dart';
import 'package:al_aqsa_cctv/data/store/hive_store.dart';
import 'package:al_aqsa_cctv/domain/models/documents.dart';
import 'package:al_aqsa_cctv/domain/models/labour.dart';
import 'package:al_aqsa_cctv/domain/models/party.dart';
import 'package:al_aqsa_cctv/domain/models/product.dart';
import 'package:al_aqsa_cctv/domain/models/user.dart';
import 'package:al_aqsa_cctv/domain/services/app_services.dart';
import 'package:al_aqsa_cctv/domain/services/catalog_service.dart';
import 'package:al_aqsa_cctv/domain/services/customer_statement.dart';
import 'package:al_aqsa_cctv/domain/services/purchase_service.dart';
import 'package:al_aqsa_cctv/domain/services/report_service.dart';
import 'package:al_aqsa_cctv/printing/pdf_docs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:path/path.dart' as p;

import 'helpers.dart';

SaleItem clips(num n, {num rate = 2}) => SaleItem.custom(kind: SaleLineKind.nonStock, name: 'Cable Clips', qty: q(n), unitPrice: rs(rate), unit: 'pcs');
SaleItem service(String name, num qty, num rate, {String unit = 'job'}) => SaleItem.custom(kind: SaleLineKind.service, name: name, qty: q(qty), unitPrice: rs(rate), unit: unit);

Future<Object?> err(Future<Object?> Function() f) async {
  try {
    await f();
    return null;
  } catch (e) {
    return e;
  }
}

void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() async => env.dispose());

  Future<(Product, Product)> stock() async {
    final cam = await env.product('Dahua 4MP Dome', cost: 4000, price: 6500, serial: true);
    final cable = await env.product('CCTV Cable (metre)', cost: 20, price: 50);
    final sup = await env.supplier();
    await env.app.purchases.create(supplierId: sup.id, date: env.clock.now, lines: [
      PurchaseLineInput(productId: cam.id, qty: q(5), unitCost: rs(4000), serials: ['ED001', 'ED002', 'ED003', 'ED004', 'ED005']),
      PurchaseLineInput(productId: cable.id, qty: q(300), unitCost: rs(20)),
    ]);
    return (env.reload(cam.id), env.reload(cable.id));
  }

  test('1-4: 500 and 1000 clips, installation and labour on the bill (no stock, in ledger and payable, reports, PDF); labour not shop profit', () async {
    final app = env.app;
    final (cam, cable) = await stock();
    final c = await env.customer('DEMO Clips Grahak');
    final stockBefore = {for (final x in app.catalog.products()) x.id: x.stockQty};

    final d1 = app.sales.newDraft().copyWith(customerId: c.id, customerName: c.name, items: [
      app.sales.lineFor(env.reload(cable.id), qty: q(40)),
      clips(500),
    ]);
    final inv1 = await app.sales.complete(d1.copyWith(paidAtSale: rs(3000)));
    expect(inv1.total, rs(40 * 50 + 500 * 2));
    final d2 = app.sales.newDraft().copyWith(customerId: c.id, customerName: c.name, items: [
      clips(1000),
      service('CCTV Installation', 1, 5000).copyWith(worker: 'Karegar Aslam'),
      service('Labour charges (mazdoori)', 2, 1500, unit: 'day'),
    ]);
    final inv2 = await app.sales.complete(d2);
    expect(inv2.total, rs(2000 + 5000 + 3000));
    expect(inv2.labourRevenue, rs(8000));

    // Stock: only the cable moved; clips and services never touch stock.
    expect(env.reload(cable.id).stockQty, stockBefore[cable.id]! - q(40));
    expect(env.reload(cam.id).stockQty, stockBefore[cam.id]);
    expect(app.catalog.products().length, stockBefore.length); // no product record created
    final saved = app.sales.byId(inv2.id)!;
    expect(saved.items.map((e) => (e.kind, e.productId, e.cogs)).toList(), [
      (SaleLineKind.nonStock, '', const Money.zero()),
      (SaleLineKind.service, '', const Money.zero()),
      (SaleLineKind.service, '', const Money.zero()),
    ]);
    expect(saved.items[1].worker, 'Karegar Aslam');

    // Ledger: the customer owes the whole invoice, labour included.
    expect(app.parties.byId(PartyKind.customer, c.id)!.balance, rs(3000 + 10000 - 3000));
    expect(app.parties.totalReceivables(), rs(10000));

    // Reports: clips from both bills are one non-stock row, not in product profit.
    final range = DateRange.thisMonth(env.clock.now);
    expect(app.reports.productSales(range).any((x) => x.name == 'Cable Clips'), isFalse);
    final clipRow = app.reports.nonStockSales(range).singleWhere((x) => x.name == 'Cable Clips');
    expect(clipRow.qty, q(1500));
    expect(clipRow.revenue, rs(3000));
    expect(clipRow.profit, const Money.zero());
    final inst = app.reports.nonStockSales(range).singleWhere((x) => x.name == 'CCTV Installation');
    expect((inst.kind, inst.revenue, inst.profit), (SaleLineKind.service, rs(5000), const Money.zero()));
    final fin = app.reports.financials(range);
    expect(fin.grossSales, rs(2000)); // the cable only
    expect(fin.nonStockSales, rs(3000));
    expect(fin.cogs, rs(40 * 20)); // only the cable has a cost
    expect(fin.grossProfit, rs(2000 - 800));
    expect(fin.labourOnInvoices, rs(8000));
    expect(fin.invoicedTotal, rs(3000 + 10000));
    expect(app.reports.salesTotal(range), rs(3000 + 10000 - 8000)); // shop sales: no labour

    // Statement.
    final s = app.customerStatements.build(c.id);
    expect(s.rows.any((x) => x.kind == StmtRowKind.saleItem && x.description.startsWith('Cable Clips (non-stock item, pcs)') && x.qty == q(500)), isTrue);
    expect(s.rows.any((x) => x.kind == StmtRowKind.saleItem && x.description.startsWith('CCTV Installation (labour / installation, job, Karegar Aslam)') && x.totalPrice == rs(5000)), isTrue);
    expect(s.closingBalance, rs(10000));

    // Invoices with stock and non-stock lines print (A4 and thermal).
    for (final paper in PaperKind.values) {
      final pdf = await invoicePdf(app.ctx.settings, saved, customer: c, paper: paper, paid: app.sales.paidAgainst(saved.id));
      expect(String.fromCharCodes(pdf.take(4)), '%PDF');
    }

    // Validation: description and quantity required.
    expect(await err(() => app.sales.complete(app.sales.newDraft().copyWith(items: [SaleItem.custom(kind: SaleLineKind.nonStock, name: ' ', qty: q(1), unitPrice: rs(1))]))), isNotNull);
    expect(await err(() => app.sales.complete(app.sales.newDraft().copyWith(items: [SaleItem.custom(kind: SaleLineKind.nonStock, name: 'Fitting', qty: q(0), unitPrice: rs(1))]))), isNotNull);

    // Presets.
    await app.sales.savePreset(BillingPreset(kind: SaleLineKind.nonStock, name: 'Cable Clips', unitPrice: Money.rupees(2), unit: 'pcs'));
    await app.sales.savePreset(BillingPreset(kind: SaleLineKind.service, name: 'CCTV Installation', unitPrice: Money.rupees(5000), unit: 'job'));
    await app.sales.savePreset(BillingPreset(kind: SaleLineKind.nonStock, name: 'cable clips', unitPrice: Money.rupees(3), unit: 'pcs')); // replaces
    expect(app.sales.presets().map((e) => (e.name, e.unitPrice)).toList(), [('cable clips', rs(3)), ('CCTV Installation', rs(5000))]);
    await app.sales.deletePreset(SaleLineKind.service, 'CCTV Installation');
    expect(app.sales.presets().length, 1);
  });

  test('5-6: editing a partly paid invoice: payments kept, stock and serials follow, ledger, history, statement, P&L', () async {
    final app = env.app;
    final (cam, cable) = await stock();
    final c = await env.customer('DEMO Edit Grahak');
    final d = app.sales.newDraft().copyWith(customerId: c.id, customerName: c.name, items: [
      app.sales.lineFor(env.reload(cam.id), qty: q(2), serials: ['ED001', 'ED002']),
      app.sales.lineFor(env.reload(cable.id), qty: q(50)),
      clips(500),
    ]);
    final sale = await app.sales.complete(d.copyWith(paidAtSale: rs(10000))); // 13,000 + 2,500 + 1,000 = 16,500
    expect(sale.total, rs(16500));
    env.clock.advance(const Duration(hours: 2));
    await app.parties.addPayment(kind: PartyKind.customer, partyId: c.id, amount: rs(4000), method: PaymentMethod.cash, againstDocId: sale.id, againstDocNumber: sale.number);
    final paysBefore = app.parties.payments().length;
    final cogsBefore = app.sales.byId(sale.id)!.cogs; // 8,000 + 1,000

    env.clock.advance(const Duration(days: 1));
    final edited = await app.sales.editInvoice(sale.id,
        items: [
          SaleItem(productId: cam.id, name: cam.name, qty: q(2), unitPrice: rs(6500), serials: ['ED001', 'ED003']), // ED002 swapped for ED003
          SaleItem(productId: cable.id, name: cable.name, qty: q(30), unitPrice: rs(50)), // 50 -> 30
          clips(1000), // 500 -> 1000
          SaleItem.custom(kind: SaleLineKind.nonStock, name: 'Wall plugs', qty: q(20), unitPrice: rs(150), unit: 'pcs'),
        ],
        invoiceDiscount: rs(500),
        reason: 'Customer changed order');
    // 13,000 + 1,500 + 2,000 + 3,000 - 500 = 19,000
    expect(edited.total, rs(19000));
    expect(edited.number, sale.number);
    expect(edited.date, sale.date);

    // Payments untouched; paid against invoice 14,000; balance = 5,000.
    expect(app.parties.payments().length, paysBefore);
    expect(app.sales.paidAgainst(sale.id), rs(14000));
    expect(app.parties.byId(PartyKind.customer, c.id)!.balance, rs(5000));
    expect(app.parties.ledgerBalance(PartyKind.customer, c.id), rs(5000));
    final adj = app.parties.entries(PartyKind.customer, c.id).singleWhere((e) => e.refType == 'sale_edit');
    expect(adj.debit, rs(2500));

    // Stock and serials.
    expect(env.reload(cable.id).stockQty, q(300 - 30));
    expect(env.reload(cam.id).stockQty, q(3));
    expect(app.serials.find('ED002')!.status, SerialStatus.inStock);
    expect(app.serials.find('ED002')!.saleId, isNull);
    expect(app.serials.find('ED003')!.status, SerialStatus.sold);
    expect(app.serials.find('ED003')!.saleId, sale.id);
    expect(app.serials.find('ED001')!.status, SerialStatus.sold);

    // Cost: camera 2 x 4,000 kept, cable 30 x 20.
    final saved = app.sales.byId(sale.id)!;
    expect(saved.cogs, rs(8000 + 600));
    expect(cogsBefore, rs(8000 + 1000));
    final fin = app.reports.financials(DateRange.thisMonth(env.clock.now));
    expect(fin.cogs, rs(8600));
    expect(fin.grossSales, rs(13000 + 1500)); // stock products only
    expect(fin.nonStockSales, rs(2000 + 3000)); // clips + wall plugs; the bill discount is taken from products
    expect(fin.discounts, rs(500));
    expect(fin.grossProfit, rs(13000 + 1500 - 500 - 8600));

    // History.
    expect(saved.edits.length, 1);
    final ed = saved.edits.single;
    expect((ed.beforeTotal, ed.afterTotal, ed.reason), (rs(16500), rs(19000), 'Customer changed order'));
    expect(ed.beforeItems.length, 3);
    expect(ed.afterItems.length, 4);
    expect(ed.at, env.clock.now);
    expect(app.ctx.all(Boxes.auditLogs, AuditLog.fromJson).any((a) => a.action == 'edit' && a.entityId == sale.id), isTrue);

    // Statement: original bill, then the edit (line changes add up to the difference).
    final s = app.customerStatements.build(c.id);
    expect(s.rows.singleWhere((r) => r.kind == StmtRowKind.invoiceTotal).debit, rs(16500));
    final editRow = s.rows.singleWhere((r) => r.kind == StmtRowKind.invoiceEdit);
    expect(editRow.debit, rs(2500));
    final lines = s.rows.where((r) => r.kind == StmtRowKind.editItem).toList();
    expect(Money.sum(lines.map((r) => r.totalPrice!)), rs(2500));
    expect(lines.any((r) => r.description.contains('S/N removed: ED002') && r.description.contains('S/N added: ED003')), isTrue);
    expect(lines.any((r) => r.description.startsWith('Added: Wall plugs')), isTrue);
    expect(s.closingBalance, rs(5000));
    expect(s.invoices.single.state, InvoiceState.partlyPaid);
    expect(s.invoices.single.due, rs(5000));

    // Lower than paid: the excess becomes customer credit, no payment deleted.
    env.clock.advance(const Duration(hours: 1));
    await app.sales.editInvoice(sale.id,
        items: [SaleItem(productId: cam.id, name: cam.name, qty: q(1), unitPrice: rs(6500), serials: ['ED001'])], invoiceDiscount: const Money.zero(), reason: 'Only one camera');
    expect(app.parties.byId(PartyKind.customer, c.id)!.balance, rs(6500 - 14000));
    expect(app.parties.payments().length, paysBefore);
    expect(env.reload(cable.id).stockQty, q(300));
    expect(app.serials.find('ED003')!.status, SerialStatus.inStock);
    expect(app.sales.byId(sale.id)!.edits.length, 2);
    final s2 = app.customerStatements.build(c.id);
    expect(s2.closingBalance, rs(-7500));
    expect(s2.invoices.single.state, InvoiceState.paid);

    // Not allowed: without a reason, by staff, after a return.
    expect(await err(() => app.sales.editInvoice(sale.id, items: saved.items, invoiceDiscount: const Money.zero(), reason: ' ')), isNotNull);
  });

  test('edit rules: walk-in must stay paid (receive more / refund back), staff cannot edit, returns block editing', () async {
    final app = env.app;
    final (_, cable) = await stock();
    final walkIn = await app.sales.complete(app.sales.newDraft().copyWith(items: [app.sales.lineFor(env.reload(cable.id), qty: q(10))], paidAtSale: rs(500)));
    final more = [SaleItem(productId: cable.id, name: cable.name, qty: q(12), unitPrice: rs(50))];
    expect(await err(() => app.sales.editInvoice(walkIn.id, items: more, invoiceDiscount: const Money.zero(), reason: 'two more')), isNotNull);
    await app.sales.editInvoice(walkIn.id, items: more, invoiceDiscount: const Money.zero(), reason: 'two more', receivedNow: rs(100));
    expect(app.sales.paidAgainst(walkIn.id), rs(600));
    final less = [SaleItem(productId: cable.id, name: cable.name, qty: q(8), unitPrice: rs(50))];
    await app.sales.editInvoice(walkIn.id, items: less, invoiceDiscount: const Money.zero(), reason: 'returned four unused');
    final refund = app.parties.payments().singleWhere((x) => x.refType == 'sale_edit');
    expect((refund.direction, refund.amount), (PaymentDirection.paid, rs(200)));
    expect(app.sales.paidAgainst(walkIn.id), rs(400));
    expect(env.reload(cable.id).stockQty, q(300 - 8));

    // Staff cannot edit invoices.
    await app.auth.createUser(username: 'cashier', password: 'secret123', displayName: 'Cashier', role: UserRole.staff);
    await app.auth.login('cashier', 'secret123');
    expect(await err(() => app.sales.editInvoice(walkIn.id, items: less, invoiceDiscount: const Money.zero(), reason: 'x')), isNotNull);
    await app.auth.login('owner', 'secret123');

    // After a return the invoice cannot be edited.
    final c = await env.customer('DEMO Rule Grahak');
    final s0 = await app.sales.complete(app.sales.newDraft().copyWith(customerId: c.id, customerName: c.name, items: [app.sales.lineFor(env.reload(cable.id), qty: q(5))]));
    await app.sales.createReturn(saleId: s0.id, lines: [ReturnLineInput(productId: cable.id, qty: q(1))], reason: 'extra', refundMode: RefundMode.accountCredit);
    expect(await err(() => app.sales.editInvoice(s0.id, items: less, invoiceDiscount: const Money.zero(), reason: 'x')), isNotNull);
  });

  test('7-11: return with cash refund (amount entered), with account adjustment, customer credit used on the next bill', () async {
    final app = env.app;
    final (cam, cable) = await stock();
    final c = await env.customer('DEMO Return Grahak');
    final sale = await app.sales.complete(app.sales.newDraft().copyWith(customerId: c.id, customerName: c.name, items: [
      app.sales.lineFor(env.reload(cam.id), qty: q(3), serials: ['ED001', 'ED002', 'ED003']),
      clips(500),
    ]).copyWith(paidAtSale: rs(20500))); // fully paid: 19,500 + 1,000
    expect(app.parties.byId(PartyKind.customer, c.id)!.balance, const Money.zero());

    // 7. Cash refund, damaged unit, 1,000 deducted: refund 5,500.
    env.clock.advance(const Duration(days: 1));
    final r1 = await app.sales.createReturn(
        saleId: sale.id,
        lines: [ReturnLineInput(productId: cam.id, qty: q(1), serials: ['ED001'], condition: 'damaged')],
        reason: 'Dropped by customer',
        refundMode: RefundMode.cash,
        amount: rs(5500));
    expect(r1.total, rs(5500));
    final refund = app.parties.payments().singleWhere((x) => x.refType == 'sales_return' && x.refId == r1.id);
    expect((refund.direction, refund.amount, refund.method), (PaymentDirection.paid, rs(5500), PaymentMethod.cash));
    final fin = app.reports.financials(DateRange.thisMonth(env.clock.now));
    expect(fin.refundsPaid, rs(5500)); // cash out of the drawer
    expect(app.parties.byId(PartyKind.customer, c.id)!.balance, const Money.zero()); // credit and refund cancel out
    expect(app.sales.customerBalanceAfterReturn(r1), const Money.zero());
    expect(app.serials.find('ED001')!.status, SerialStatus.damaged);
    expect(env.reload(cam.id).damagedQty, q(1));
    expect(await err(() => app.sales.createReturn(saleId: sale.id, lines: [ReturnLineInput(productId: cam.id, qty: q(1), serials: ['ED002'])], reason: 'x', amount: rs(7000))), isNotNull,
        reason: 'more than charged');

    // 8-9. Account adjustment with nothing outstanding: customer credit, no cash.
    env.clock.advance(const Duration(days: 1));
    final paysBefore = app.parties.payments().length;
    final r2 = await app.sales.createReturn(
        saleId: sale.id, lines: [ReturnLineInput(productId: cam.id, qty: q(1), serials: ['ED002'])], reason: 'Not needed', refundMode: RefundMode.accountCredit);
    expect(r2.total, rs(6500));
    expect(app.parties.payments().length, paysBefore); // no cash refund
    expect(app.parties.byId(PartyKind.customer, c.id)!.balance, rs(-6500)); // credit held
    expect(app.sales.customerBalanceAfterReturn(r2), rs(-6500));
    expect(app.serials.find('ED002')!.status, SerialStatus.inStock);
    expect(env.reload(cam.id).stockQty, q(3)); // 5 - 3 sold + 1 saleable back

    // 10. The same serial or quantity cannot be returned twice.
    expect(await err(() => app.sales.createReturn(saleId: sale.id, lines: [ReturnLineInput(productId: cam.id, qty: q(1), serials: ['ED002'])], reason: 'again')), isNotNull);
    expect(await err(() => app.sales.createReturn(saleId: sale.id, lines: [ReturnLineInput(productId: cam.id, qty: q(2), serials: ['ED003', 'ED002'])], reason: 'again')), isNotNull);

    // The credit is used by the next invoice.
    env.clock.advance(const Duration(days: 1));
    await app.sales.complete(app.sales.newDraft().copyWith(customerId: c.id, customerName: c.name, items: [app.sales.lineFor(env.reload(cable.id), qty: q(100))])); // 5,000
    expect(app.parties.byId(PartyKind.customer, c.id)!.balance, rs(-1500));

    // 11. Statement, ledger, dashboard agree.
    final s = app.customerStatements.build(c.id);
    expect(s.totalReturns, rs(12000));
    expect(s.returns.map((r) => (r.number, r.refundMode)).toList(), [(r1.number, RefundMode.cash), (r2.number, RefundMode.accountCredit)]);
    expect(s.rows.singleWhere((r) => r.kind == StmtRowKind.refund).debit, rs(5500));
    expect(s.closingBalance, rs(-1500));
    expect(s.closingBalance, app.parties.ledgerBalance(PartyKind.customer, c.id));
    expect(app.parties.totalReceivables(), const Money.zero()); // a credit is not a receivable

    // Receipts.
    for (final r in [r1, r2]) {
      final pdf = await returnReceiptPdf(app.ctx.settings, r, customer: c, balanceAfter: app.sales.customerBalanceAfterReturn(r));
      expect(String.fromCharCodes(pdf.take(4)), '%PDF');
    }
  });

  test('12: edited invoice, non-stock lines, presets and returns are all still there after a restart', () async {
    // Start from a closed Hive, whatever another test left open.
    await Hive.close();
    final root = await Directory.systemTemp.createTemp('aqsa_edit_restart');
    final clock = TestClock();
    Future<(HiveStore, AppServices)> open() async {
      final store = await HiveStore.open(p.join(root.path, 'data'));
      await Migrator.run(store);
      final app = AppServices(store, localBackupDir: p.join(root.path, 'backups'), clock: clock.call, hasher: const PasswordHasher(iterations: 10));
      if (app.auth.findByUsername('owner') == null) await app.auth.createOwner(username: 'owner', password: 'secret123', displayName: 'Owner');
      await app.auth.openLocalSession();
      return (store, app);
    }

    var (store, app) = await open();
    final pr = await app.catalog.create(ProductInput(name: 'Cable', purchasePrice: rs(20), sellingPrice: rs(50)));
    final sup = await app.parties.create(kind: PartyKind.supplier, name: 'S', phone: '1');
    await app.purchases.create(supplierId: sup.id, date: clock.now, lines: [PurchaseLineInput(productId: pr.id, qty: q(100), unitCost: rs(20))]);
    final c = await app.parties.create(kind: PartyKind.customer, name: 'Restart Grahak', phone: '0300');
    final sale = await app.sales.complete(app.sales.newDraft().copyWith(customerId: c.id, customerName: c.name, items: [
      app.sales.lineFor(app.catalog.byId(pr.id)!, qty: q(10)),
      clips(500),
    ]).copyWith(paidAtSale: rs(500)));
    clock.advance(const Duration(hours: 1));
    await app.sales.editInvoice(sale.id,
        items: [SaleItem(productId: pr.id, name: 'Cable', qty: q(20), unitPrice: rs(50)), clips(1000), SaleItem.custom(kind: SaleLineKind.nonStock, name: 'Screws box', qty: q(1), unitPrice: rs(2000))],
        invoiceDiscount: const Money.zero(),
        reason: 'more work');
    await app.labour.create(lines: [LabourLine(description: 'Labour', qty: q(1), rate: rs(2000))], customerId: c.id, saleId: sale.id, saleNumber: sale.number, workerName: 'Aslam', receivedNow: rs(500));
    clock.advance(const Duration(hours: 1));
    await app.sales.createReturn(saleId: sale.id, lines: [ReturnLineInput(productId: pr.id, qty: q(5))], reason: 'extra', refundMode: RefundMode.accountCredit);
    await app.sales.savePreset(BillingPreset(kind: SaleLineKind.service, name: 'Labour', unitPrice: Money.rupees(2000)));
    final balance = app.parties.byId(PartyKind.customer, c.id)!.balance;
    final closing = app.customerStatements.build(c.id).closingBalance;

    await store.close();
    (store, app) = await open();
    final again = app.sales.byId(sale.id)!;
    expect(again.total, rs(1000 + 2000 + 2000));
    expect(again.items.map((e) => e.kind).toList(), [SaleLineKind.product, SaleLineKind.nonStock, SaleLineKind.nonStock]);
    final lbAgain = app.labour.forSale(sale.id).single;
    expect((lbAgain.total, lbAgain.collected, lbAgain.workerName), (rs(2000), rs(500), 'Aslam'));
    expect(again.edits.single.beforeTotal, rs(1500));
    expect(app.catalog.byId(pr.id)!.stockQty, q(100 - 20 + 5));
    expect(app.parties.byId(PartyKind.customer, c.id)!.balance, balance);
    expect(balance, rs(5000 - 500 - 250));
    expect(app.customerStatements.build(c.id).closingBalance, closing);
    expect(app.sales.presets().single.name, 'Labour');
    await store.close();
    await root.delete(recursive: true);
  });
}
