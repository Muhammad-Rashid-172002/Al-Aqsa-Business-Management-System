// Detailed customer statement: every invoice with product lines, payments
// (at sale, against an invoice, on account, voided), a return, an
// adjustment, the running balance, the summary, invoice status, periods,
// and the A4 PDF.
import 'dart:io';

import 'package:al_aqsa_cctv/core/money.dart';
import 'package:al_aqsa_cctv/domain/models/documents.dart';
import 'package:al_aqsa_cctv/domain/models/party.dart';
import 'package:al_aqsa_cctv/domain/models/product.dart';
import 'package:al_aqsa_cctv/domain/services/customer_statement.dart';
import 'package:al_aqsa_cctv/domain/services/purchase_service.dart';
import 'package:al_aqsa_cctv/printing/pdf_docs.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() async => env.dispose());

  /// The demo customer from the requirement: opening balance, three
  /// invoices (paid / partly paid / unpaid) with several products,
  /// separate payments, a return, an adjustment and a voided payment.
  Future<(Party, Map<String, Sale>)> demo() async {
    final app = env.app;
    final cam = await env.product('Dahua 4MP Dome Camera', cost: 4000, price: 6500);
    final dvr = await env.product('Hikvision 8CH DVR', cost: 8000, price: 12000);
    final cable = await env.product('CCTV Cable (metre)', cost: 20, price: 50);
    final hdd = await env.product('1TB Surveillance Hard Disk', cost: 6000, price: 9000);
    final sup = await env.supplier();
    env.clock.now = DateTime(2026, 1, 2, 10);
    await app.purchases.create(supplierId: sup.id, date: env.clock.now, lines: [
      PurchaseLineInput(productId: cam.id, qty: q(20), unitCost: rs(4000)),
      PurchaseLineInput(productId: dvr.id, qty: q(5), unitCost: rs(8000)),
      PurchaseLineInput(productId: cable.id, qty: q(500), unitCost: rs(20)),
      PurchaseLineInput(productId: hdd.id, qty: q(5), unitCost: rs(6000)),
    ]);
    env.clock.now = DateTime(2026, 1, 5, 11);
    final c = await app.parties.create(kind: PartyKind.customer, name: 'DEMO Statement Customer', phone: '0300 5550001', address: 'Main Bazar, Rawalpindi', openingBalance: rs(5000));
    Product p(Product x) => env.reload(x.id);
    Future<Sale> sell(DateTime at, List<SaleItem> items, {int discount = 0, int paid = 0}) async {
      env.clock.now = at;
      final d = app.sales.newDraft().copyWith(customerId: c.id, customerName: c.name, items: items, invoiceDiscount: rs(discount));
      return app.sales.complete(d.copyWith(paidAtSale: rs(paid)));
    }

    final inv1 = await sell(DateTime(2026, 2, 3, 12), [
      app.sales.lineFor(p(cam), qty: q(2)),
      app.sales.lineFor(p(dvr)),
      app.sales.lineFor(p(cable), qty: q(100)),
    ], discount: 1000, paid: 29000); // 30,000 - 1,000 = 29,000, fully paid
    final inv2 = await sell(DateTime(2026, 2, 15, 12), [
      app.sales.lineFor(p(cam), qty: q(4)),
      app.sales.lineFor(p(hdd)),
    ], paid: 10000); // 35,000, 10,000 at sale
    env.clock.now = DateTime(2026, 2, 20, 16);
    await app.parties.addPayment(kind: PartyKind.customer, partyId: c.id, amount: rs(5000), method: PaymentMethod.bankTransfer, againstDocId: inv2.id, againstDocNumber: inv2.number);
    final inv3 = await sell(DateTime(2026, 3, 2, 12), [
      app.sales.lineFor(p(dvr)),
      app.sales.lineFor(p(cable), qty: q(50)),
    ]); // 14,500 unpaid
    env.clock.now = DateTime(2026, 3, 4, 10);
    await app.parties.addPayment(kind: PartyKind.customer, partyId: c.id, amount: rs(3000), method: PaymentMethod.cash);
    env.clock.now = DateTime(2026, 3, 6, 10);
    await app.parties.addPayment(kind: PartyKind.customer, partyId: c.id, amount: rs(2000), method: PaymentMethod.mobileWallet, note: 'JazzCash');
    env.clock.now = DateTime(2026, 3, 7, 10);
    await app.sales.createReturn(
        saleId: inv3.id, lines: [ReturnLineInput(productId: cable.id, qty: q(20))], reason: 'Extra cable returned', refundMode: RefundMode.accountCredit);
    env.clock.now = DateTime(2026, 3, 8, 10);
    await app.parties.adjust(kind: PartyKind.customer, partyId: c.id, amount: rs(500), increaseBalance: false, note: 'Discount on old balance');
    env.clock.now = DateTime(2026, 3, 9, 10);
    final wrong = await app.parties.addPayment(kind: PartyKind.customer, partyId: c.id, amount: rs(700), method: PaymentMethod.cash);
    await app.parties.voidPayment(wrong.id, 'Entered twice');
    env.clock.now = DateTime(2026, 3, 10, 18);
    return (app.parties.byId(PartyKind.customer, c.id)!, {'1': inv1, '2': inv2, '3': inv3});
  }

  test('complete history: every line, debit, credit and running balance; closing = ledger = dashboard', () async {
    final app = env.app;
    final (c, inv) = await demo();
    final s = app.customerStatements.build(c.id);

    // Opening row.
    expect(s.rows.first.kind, StmtRowKind.opening);
    expect(s.openingBalance, rs(5000));

    // Every posting row: balance = previous + debit - credit; one row per ledger entry.
    var bal = s.openingBalance;
    final posting = s.rows.where((r) => r.isPosting).skip(1).toList();
    for (final r in posting) {
      bal = bal + r.debit - r.credit;
      expect(r.balance, bal, reason: r.description);
    }
    final ledger = app.parties.entries(PartyKind.customer, c.id).where((e) => e.type != LedgerType.opening).toList();
    expect(posting.length, ledger.length);
    expect(Money.sum(posting.map((r) => r.debit)), Money.sum(ledger.map((e) => e.debit)));
    expect(Money.sum(posting.map((r) => r.credit)), Money.sum(ledger.map((e) => e.credit)));

    // Product lines of invoice 1, with the invoice discount.
    final i1 = s.rows.where((r) => r.voucher == inv['1']!.number).toList();
    expect(i1.where((r) => r.kind == StmtRowKind.saleItem).map((r) => (r.qty, r.unitPrice, r.totalPrice)).toList(), [
      (q(2), rs(6500), rs(13000)),
      (q(1), rs(12000), rs(12000)),
      (q(100), rs(50), rs(5000)),
    ]);
    expect(i1.singleWhere((r) => r.kind == StmtRowKind.invoiceDiscount).totalPrice, rs(-1000));
    final t1 = i1.singleWhere((r) => r.kind == StmtRowKind.invoiceTotal);
    expect(t1.debit, rs(29000));
    expect(t1.totalPrice, rs(29000));
    expect(s.rows.any((r) => r.kind == StmtRowKind.payment && r.credit == rs(29000) && r.description.contains('paid at sale, invoice ${inv['1']!.number}')), isTrue);
    expect(s.rows.any((r) => r.kind == StmtRowKind.payment && r.credit == rs(5000) && r.description.contains('against invoice ${inv['2']!.number}')), isTrue);
    expect(s.rows.where((r) => r.kind == StmtRowKind.payment && r.description.contains('on account')).length, 3); // 3,000, 2,000, 700 (voided)
    expect(s.rows.any((r) => r.kind == StmtRowKind.payment && r.credit == rs(700) && r.description.contains('voided later')), isTrue);
    expect(s.rows.singleWhere((r) => r.kind == StmtRowKind.paymentVoid).debit, rs(700));
    final ret = s.rows.singleWhere((r) => r.kind == StmtRowKind.returnTotal);
    expect(ret.credit, rs(1000));
    expect(ret.description.contains('credited to account'), isTrue);
    expect(s.rows.singleWhere((r) => r.kind == StmtRowKind.returnItem).qty, q(20));
    final adj = s.rows.singleWhere((r) => r.kind == StmtRowKind.adjustment);
    expect(adj.credit, rs(500));
    expect(adj.description.contains('Discount on old balance'), isTrue);

    // Summary: Closing = Opening + Debit - Credit, each payment counted once.
    expect(s.totalDebit, rs(29000 + 35000 + 14500 + 700));
    expect(s.totalPayments, rs(29000 + 10000 + 5000 + 3000 + 2000 + 700));
    expect(s.totalReturnsAdjustments, rs(1000 + 500));
    expect(s.closingBalance, s.openingBalance + s.totalDebit - s.totalPayments - s.totalReturnsAdjustments);
    expect(s.closingBalance, rs(33000));
    expect(s.onAccountPayments, rs(5000)); // the voided 700 is not counted

    // Same as the customer's ledger balance and the dashboard receivable.
    expect(s.closingBalance, c.balance);
    expect(s.closingBalance, app.parties.ledgerBalance(PartyKind.customer, c.id));
    expect(s.accountBalance, c.balance);
    expect(app.parties.totalReceivables(), rs(33000)); // the only customer with a balance
    expect(app.parties.statement(PartyKind.customer, c.id).closingBalance, s.closingBalance);

    // Invoice status.
    final st = {for (final i in s.invoices) i.number: i};
    expect(st[inv['1']!.number]!.state, InvoiceState.paid);
    expect(st[inv['2']!.number]!.state, InvoiceState.partlyPaid);
    expect(st[inv['2']!.number]!.paid, rs(15000));
    expect(st[inv['2']!.number]!.due, rs(20000));
    expect(st[inv['3']!.number]!.state, InvoiceState.unpaid);
    expect(st[inv['3']!.number]!.returns, rs(1000));
    expect(st[inv['3']!.number]!.due, rs(13500));
  });

  test('periods: previous month, this month and a custom range carry the balance forward', () async {
    final app = env.app;
    final (c, _) = await demo(); // "today" is 10 March 2026
    final feb = app.customerStatements.build(c.id, period: StatementPeriod.previousMonth);
    expect(feb.from, DateTime(2026, 2, 1));
    expect(feb.to, DateTime(2026, 2, 28));
    expect(feb.openingBalance, rs(5000));
    expect(feb.closingBalance, rs(5000 + 29000 + 35000 - 29000 - 10000 - 5000));
    expect(feb.invoices.length, 2);
    expect(feb.rows.every((r) => r.date == null || !r.date!.isBefore(DateTime(2026, 2, 1))), isTrue);

    final mar = app.customerStatements.build(c.id, period: StatementPeriod.thisMonth);
    expect(mar.openingBalance, feb.closingBalance);
    expect(mar.closingBalance, c.balance);
    expect(mar.invoices.length, 1);

    final custom = app.customerStatements.build(c.id, period: StatementPeriod.custom, from: DateTime(2026, 2, 16), to: DateTime(2026, 3, 3));
    expect(custom.openingBalance, rs(5000 + 29000 + 35000 - 29000 - 10000));
    expect(custom.closingBalance, custom.openingBalance - rs(5000) + rs(14500));
    expect(custom.coversToday, isFalse);

    Object? err;
    try {
      app.customerStatements.build(c.id, period: StatementPeriod.custom, from: DateTime(2026, 3, 5), to: DateTime(2026, 3, 1));
    } catch (e) {
      err = e;
    }
    expect(err, isNotNull);
  });

  test('A4 PDF: builds for the demo customer and spans several numbered pages for a long history', () async {
    final app = env.app;
    final (c, _) = await demo();
    final s = app.customerStatements.build(c.id);
    final bytes = await customerStatementPdf(app.ctx.settings, s);
    expect(String.fromCharCodes(bytes.take(4)), '%PDF');
    final out = Platform.environment['STATEMENT_PDF_OUT'];
    if (out != null) await File(out).writeAsBytes(bytes);

    // A long history: 60 more invoices must flow onto more pages.
    final cable = app.catalog.products().firstWhere((p) => p.name.startsWith('CCTV Cable'));
    for (var i = 0; i < 60; i++) {
      env.clock.now = DateTime(2026, 3, 10, 18, i);
      final d = app.sales.newDraft().copyWith(customerId: c.id, customerName: c.name, items: [app.sales.lineFor(env.reload(cable.id), qty: q(2))]);
      await app.sales.complete(d.copyWith(paidAtSale: rs(i.isEven ? 100 : 0)));
    }
    final big = app.customerStatements.build(c.id);
    expect(big.closingBalance, app.parties.byId(PartyKind.customer, c.id)!.balance);
    final bigBytes = await customerStatementPdf(app.ctx.settings, big);
    final pages = RegExp(r'/Type\s*/Page[^s]').allMatches(String.fromCharCodes(bigBytes)).length;
    expect(pages >= 3, isTrue, reason: '$pages pages');
    final outBig = Platform.environment['STATEMENT_PDF_OUT_BIG'];
    if (outBig != null) await File(outBig).writeAsBytes(bigBytes);
  });

  test('returns: saleable / faulty / damaged go to the right stock; each is one credit in the statement, PDF and summary', () async {
    final app = env.app;
    final cam = await env.product('Hikvision 2MP Bullet', cost: 4000, price: 6000, serial: true);
    final cable = await env.product('CAT6 Cable (metre)', cost: 20, price: 60);
    final sup = await env.supplier();
    await app.purchases.create(supplierId: sup.id, date: env.clock.now, lines: [
      PurchaseLineInput(productId: cam.id, qty: q(4), unitCost: rs(4000), serials: ['RT001', 'RT002', 'RT003', 'RT004']),
      PurchaseLineInput(productId: cable.id, qty: q(100), unitCost: rs(20)),
    ]);
    final c = await app.parties.create(kind: PartyKind.customer, name: 'DEMO Return Customer', phone: '0300 5550002');
    env.clock.advance(const Duration(hours: 1));
    final d = app.sales.newDraft().copyWith(customerId: c.id, customerName: c.name, items: [
      app.sales.lineFor(env.reload(cam.id), qty: q(4), serials: ['RT001', 'RT002', 'RT003', 'RT004']),
      app.sales.lineFor(env.reload(cable.id), qty: q(50)),
    ]);
    final sale = await app.sales.complete(d.copyWith(paidAtSale: rs(10000))); // 24,000 + 3,000 = 27,000
    expect(env.reload(cam.id).stockQty, q(0));

    env.clock.advance(const Duration(days: 1));
    final r1 = await app.sales.createReturn(saleId: sale.id, lines: [
      ReturnLineInput(productId: cam.id, qty: q(1), serials: ['RT001'], condition: 'resellable'),
      ReturnLineInput(productId: cable.id, qty: q(10), condition: 'resellable'),
    ], reason: 'Not needed', refundMode: RefundMode.accountCredit);
    env.clock.advance(const Duration(days: 1));
    final r2 = await app.sales.createReturn(saleId: sale.id, lines: [
      ReturnLineInput(productId: cam.id, qty: q(1), serials: ['RT002'], condition: 'faulty'),
    ], reason: 'No night vision', refundMode: RefundMode.accountCredit);
    env.clock.advance(const Duration(days: 1));
    final r3 = await app.sales.createReturn(saleId: sale.id, lines: [
      ReturnLineInput(productId: cam.id, qty: q(1), serials: ['RT003'], condition: 'damaged'),
    ], reason: 'Broken in transit', refundMode: RefundMode.cash);

    // Stock follows the condition.
    final p = env.reload(cam.id);
    expect(p.stockQty, q(1)); // saleable unit only
    expect(p.inspectionQty, q(1)); // faulty, kept aside
    expect(p.damagedQty, q(1));
    expect(app.serials.find('RT001')!.status, SerialStatus.inStock);
    expect(app.serials.find('RT002')!.status, SerialStatus.pendingInspection);
    expect(app.serials.find('RT003')!.status, SerialStatus.damaged);
    expect(app.serials.find('RT004')!.status, SerialStatus.sold);
    final faulty = app.inspections.list().singleWhere((i) => i.sourceId == r2.id);
    expect(faulty.reportedCondition, 'Faulty');
    expect(env.reload(cable.id).stockQty, q(100 - 50 + 10));

    // Unknown conditions are refused.
    Object? err;
    try {
      await app.sales.createReturn(saleId: sale.id, lines: [ReturnLineInput(productId: cable.id, qty: q(1), condition: 'broken')], reason: 'x');
    } catch (e) {
      err = e;
    }
    expect(err, isNotNull);

    final s = app.customerStatements.build(c.id);
    // Register: every returned line with date, voucher, invoice, qty, amount, reason, condition.
    expect(s.returns.map((r) => (r.number, r.invoiceNumber, r.productName, r.qty, r.amount, r.reason, r.condition)).toList(), [
      (r1.number, sale.number, 'Hikvision 2MP Bullet', q(1), rs(6000), 'Not needed', 'resellable'),
      (r1.number, sale.number, 'CAT6 Cable (metre)', q(10), rs(600), 'Not needed', 'resellable'),
      (r2.number, sale.number, 'Hikvision 2MP Bullet', q(1), rs(6000), 'No night vision', 'faulty'),
      (r3.number, sale.number, 'Hikvision 2MP Bullet', q(1), rs(6000), 'Broken in transit', 'damaged'),
    ]);
    expect(s.returns.first.date, r1.date);
    // Each return is exactly one credit row; total = the return documents, counted once.
    final credits = s.rows.where((r) => r.kind == StmtRowKind.returnTotal).toList();
    expect(credits.map((r) => r.credit).toList(), [rs(6600), rs(6000), rs(6000)]);
    expect(s.totalReturns, rs(18600));
    expect(Money.sum(s.returns.map((r) => r.amount)), s.totalReturns);
    expect(s.totalOtherCredits, const Money.zero());
    expect(credits[1].description.contains('Reason: No night vision'), isTrue);
    expect(s.rows.any((r) => r.kind == StmtRowKind.returnItem && r.description.contains('Condition: Faulty')), isTrue);
    // The cash refund of the damaged return is a debit (money paid back).
    expect(s.rows.singleWhere((r) => r.kind == StmtRowKind.refund).debit, rs(6000));
    // 27,000 - 10,000 paid - 18,600 returns + 6,000 refunded = 4,400.
    expect(s.closingBalance, rs(4400));
    expect(s.closingBalance, app.parties.byId(PartyKind.customer, c.id)!.balance);
    expect(s.closingBalance, app.parties.ledgerBalance(PartyKind.customer, c.id));
    expect(s.closingBalance, s.openingBalance + s.totalDebit - s.totalPayments - s.totalReturns - s.totalOtherCredits);
    final inv = s.invoices.single;
    expect(inv.returns, rs(18600));
    expect(inv.due, rs(27000 - 18600 - (10000 - 6000)));

    final bytes = await customerStatementPdf(app.ctx.settings, s);
    expect(String.fromCharCodes(bytes.take(4)), '%PDF');
    final out = Platform.environment['STATEMENT_PDF_OUT_RETURNS'];
    if (out != null) await File(out).writeAsBytes(bytes);
  });
}

