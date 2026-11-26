import 'dart:convert';

import 'package:al_aqsa_cctv/core/errors.dart';
import 'package:al_aqsa_cctv/core/money.dart';
import 'package:al_aqsa_cctv/domain/models/documents.dart';
import 'package:al_aqsa_cctv/domain/models/party.dart';
import 'package:al_aqsa_cctv/domain/models/product.dart';
import 'package:al_aqsa_cctv/domain/services/purchase_service.dart';
import 'package:al_aqsa_cctv/domain/services/report_service.dart';
import 'package:al_aqsa_cctv/domain/services/report_tables.dart';
import 'package:al_aqsa_cctv/export/tabular.dart';
import 'package:al_aqsa_cctv/printing/pdf_docs.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

import 'helpers.dart';

final march = DateRange(DateTime(2026, 3, 1), DateTime(2026, 3, 31, 23, 59, 59));

class _Shop {
  late Product cam, nvr;
  late Party ali, bilal, sup1, sup2;
  late Sale s1, s2, s3;
  late Purchase p1, p2, p3;
}

void main() {
  late TestEnv env;
  late _Shop x;
  setUp(() async {
    env = await TestEnv.create();
    x = _Shop();
    final app = env.app;
    env.clock.now = DateTime(2026, 3, 2, 10);
    x.cam = await env.product('Dome Camera', cost: 4000, price: 6000);
    x.nvr = await env.product('NVR 8CH', cost: 9000, price: 12000, serial: true, brand: 'Hik');
    x.ali = await env.customer('Ali Traders');
    x.bilal = await env.customer('Bilal');
    x.sup1 = await env.supplier('Hik Distributor');
    x.sup2 = await env.supplier('Dahua House');
    // Two purchases of the camera at DIFFERENT costs (FIFO: 4000 first, then 5000).
    x.p1 = await app.purchases.create(supplierId: x.sup1.id, date: env.clock.now, lines: [PurchaseLineInput(productId: x.cam.id, qty: q(2), unitCost: rs(4000))], paid: rs(8000));
    x.p2 = await app.purchases.create(supplierId: x.sup2.id, date: env.clock.now, lines: [PurchaseLineInput(productId: x.cam.id, qty: q(2), unitCost: rs(5000))], paid: rs(3000));
    x.p3 = await app.purchases.create(
        supplierId: x.sup1.id, date: env.clock.now, lines: [PurchaseLineInput(productId: x.nvr.id, qty: q(3), unitCost: rs(9000), serials: const ['NV1', 'NV2', 'NV3'])]);
    // Sale 1 (Mar 10): 2 cameras, line discount 500 + invoice discount 300, part paid 5000.
    env.clock.now = DateTime(2026, 3, 10, 11);
    final d1 = app.sales.newDraft().copyWith(customerId: x.ali.id, customerName: x.ali.name, invoiceDiscount: rs(300), items: [
      app.sales.lineFor(env.reload(x.cam.id), qty: q(2)).copyWith(discount: rs(500)),
    ]);
    x.s1 = await app.sales.complete(d1.copyWith(paidAtSale: rs(5000)));
    // Sale 2 (Mar 11): 1 camera (cost 5000 by FIFO) + 1 NVR NV2, fully paid.
    env.clock.now = DateTime(2026, 3, 11, 12);
    final d2 = app.sales.newDraft().copyWith(customerId: x.bilal.id, customerName: x.bilal.name, items: [
      app.sales.lineFor(env.reload(x.cam.id)),
      app.sales.lineFor(env.reload(x.nvr.id), serials: const ['NV2']),
    ]);
    x.s2 = await app.sales.complete(d2.copyWith(paidAtSale: d2.total));
    // Sale 3 is cancelled: never counted.
    final d3 = app.sales.newDraft().copyWith(items: [app.sales.lineFor(env.reload(x.nvr.id), serials: const ['NV3'])]);
    x.s3 = await app.sales.complete(d3.copyWith(paidAtSale: d3.total));
    await app.sales.cancel(x.s3.id, 'Customer changed mind');
    // Mar 12: Ali returns one camera (cash refund).
    env.clock.now = DateTime(2026, 3, 12, 9);
    await app.sales.createReturn(saleId: x.s1.id, reason: 'Not needed', lines: [ReturnLineInput(productId: x.cam.id, qty: q(1))]);
    // Mar 20: Ali pays 2000 to his account (not against an invoice).
    env.clock.now = DateTime(2026, 3, 20, 15);
    await app.parties.addPayment(kind: PartyKind.customer, partyId: x.ali.id, amount: rs(2000), method: PaymentMethod.cash);
    // Expenses: three in March, one deleted, one in April.
    await app.expenses.create(category: 'Shop rent', title: 'March rent', amount: rs(30000), date: DateTime(2026, 3, 1));
    await app.expenses.create(category: 'Electricity bill', title: 'LESCO', amount: rs(8000), date: DateTime(2026, 3, 15));
    await app.expenses.create(category: 'Staff salaries', title: 'Helper salary', amount: rs(20000), date: DateTime(2026, 3, 31, 18));
    final wrong = await app.expenses.create(category: 'Other', title: 'Entered twice', amount: rs(9999), date: DateTime(2026, 3, 16));
    await app.expenses.delete(wrong.id, reason: 'duplicate');
    await app.expenses.create(category: 'Shop rent', title: 'April rent', amount: rs(30000), date: DateTime(2026, 4, 1));
    env.clock.now = DateTime(2026, 4, 5, 10);
  });
  tearDown(() async => env.dispose());

  test('monthly profit & loss: discounts, returns, FIFO costs, cancelled sales, expenses, cash', () async {
    final app = env.app;
    final f = app.reports.financials(march);
    final nvrPrice = rs(12000);
    expect(f.invoiceCount, 2, reason: 'cancelled invoice excluded');
    expect(f.grossSales, rs(12000) + rs(6000) + nvrPrice, reason: 'before discounts');
    expect(f.discounts, rs(800));
    final returned = app.sales.returns().single.total; // one of two cameras, after its share of discounts
    expect(returned, rs(5600));
    expect(f.salesReturns, returned);
    expect(f.netSales, f.grossSales - rs(800) - returned);
    expect(f.cogs, rs(4000 + 4000 + 5000 + 9000 - 4000), reason: 'actual purchase costs (FIFO), returned unit cost removed');
    expect(f.grossProfit, f.netSales - f.cogs);
    expect(f.expenses, rs(58000), reason: 'deleted and April expenses excluded');
    expect(f.expensesByCategory.first, ('Shop rent', rs(30000)));
    expect(f.netOperatingProfit, f.grossProfit - rs(58000));
    // Cash is not sales: part payment, full payment, account payment, minus the refund.
    expect(f.cashReceived, rs(5000) + x.s2.total + rs(2000));
    expect(f.refundsPaid, returned);
    expect(f.creditSales, x.s1.total - rs(5000));
    expect(f.customerOutstanding, app.parties.list(PartyKind.customer).fold<Money>(const Money.zero(), (a, p) => a + p.balance));
    // Same numbers in the printable report; labels never say "net profit" for gross profit.
    final t = ReportBuilder(app).workbook(ReportKind.profitLoss, march);
    expect(t.length, 3, reason: 'summary, expense list, expenses by category');
    double v(String label) => t.first.rows.firstWhere((r) => r[0] == label)[1] as double;
    expect(v('GROSS PROFIT'), f.grossProfit.paisa / 100);
    expect(v('Total Shop Expenses'), -58000.0);
    expect(v('NET OPERATING PROFIT'), f.netOperatingProfit.paisa / 100);
    expect(v('Net Product Sales'), f.netSales.paisa / 100);
    expect(t.first.rows.any((r) => '${r[0]}'.toLowerCase() == 'net profit'), isFalse);
    // The old gross profit report agrees.
    final gp = app.reports.profit(march);
    expect(gp.netSales, f.netSales);
    expect(gp.grossProfit, f.grossProfit);
    // Yearly summary: March row equals the monthly figures; no double counting.
    final year = ReportBuilder(app).build(ReportKind.yearlySummary, DateRange(DateTime(2026), DateTime(2026, 12, 31, 23, 59)));
    final mar = year.rows.firstWhere((r) => r[0] == 'Mar 2026');
    expect(mar[5], f.netSales.paisa / 100);
    expect(mar[7], f.grossProfit.paisa / 100);
    expect(mar[9], 580.0 * 100);
    expect(year.footer.single[9], 880.0 * 100, reason: 'March 58,000 + April 30,000');
  });

  test('expenses: validation, edit history, delete keeps the record, restore', () async {
    final app = env.app;
    await expectLater(app.expenses.create(category: 'Transport', title: 'Fuel', amount: rs(0), date: env.clock.now), throwsA(isA<ValidationException>()));
    await expectLater(app.expenses.create(category: '', title: 'Fuel', amount: rs(10), date: env.clock.now), throwsA(isA<ValidationException>()));
    await expectLater(app.expenses.create(category: 'Transport', title: ' ', amount: rs(10), date: env.clock.now), throwsA(isA<ValidationException>()));
    final e = await app.expenses.create(category: 'Transport', title: 'Fuel', amount: rs(1500), date: DateTime(2026, 4, 2), method: PaymentMethod.mobileWallet);
    final e2 = await app.expenses.update(e.id, category: 'Transport', title: 'Fuel for van', amount: rs(1800), date: DateTime(2026, 4, 2), method: PaymentMethod.mobileWallet);
    expect(e2.number, e.number);
    expect(e2.history.length, 2);
    expect(e2.history.last.summary.contains('amount'), isTrue);
    expect(app.expenses.total(from: DateTime(2026, 4), to: DateTime(2026, 4, 30, 23)), rs(31800));
    await app.expenses.delete(e.id, reason: 'paid by customer');
    expect(app.expenses.list().any((x0) => x0.id == e.id), isFalse);
    final kept = app.expenses.list(includeDeleted: true).firstWhere((x0) => x0.id == e.id);
    expect(kept.deleted, isTrue);
    expect(kept.history.last.action, 'deleted');
    await expectLater(app.expenses.update(e.id, category: 'Transport', title: 'x', amount: rs(1), date: env.clock.now), throwsA(isA<BusinessException>()));
    await app.expenses.restore(e.id);
    expect(app.expenses.byId(e.id)!.deleted, isFalse);
    final cats = ReportBuilder(app).build(ReportKind.expensesByCategory, DateRange(DateTime(2026, 4), DateTime(2026, 4, 30, 23, 59)));
    expect(cats.rows.map((r) => r[0]).toList(), ['Shop rent', 'Transport']);
    expect(cats.footer.single[2], 31800.0);
    final only = ReportBuilder(app).build(ReportKind.expenses, march, const ReportFilter(txnType: 'Shop rent'));
    expect(only.rows.length, 1);
    expect(only.footer.single[6], 30000.0);
  });

  test('discounts are separate from payments; payment status filter', () async {
    final b = ReportBuilder(env.app);
    final disc = b.build(ReportKind.discounts, march);
    expect(disc.rows.length, 1);
    expect(disc.rows.single[4], 500.0);
    expect(disc.rows.single[5], 300.0);
    expect(disc.rows.single[6], 800.0);
    expect(disc.rows.single[8], 5000.0, reason: 'payment received is not the discount');
    final reg = b.build(ReportKind.salesInvoices, march);
    expect(reg.rows.length, 2, reason: 'cancelled invoice not listed');
    expect(reg.footer.single[4], 800.0);
    final partial = b.build(ReportKind.salesInvoices, march, const ReportFilter(payment: PayStatus.partial));
    expect(partial.rows.single[0], x.s1.number);
    expect(partial.rows.single[8], 'Partly paid');
    expect(b.build(ReportKind.salesInvoices, march, const ReportFilter(payment: PayStatus.paid)).rows.single[0], x.s2.number);
    expect(b.build(ReportKind.salesInvoices, march, const ReportFilter(payment: PayStatus.unpaid)).rows, isEmpty);
  });

  test('filters return only matching records', () async {
    final b = ReportBuilder(env.app);
    final cam = b.build(ReportKind.salesByProduct, march, ReportFilter(productId: x.cam.id));
    expect(cam.rows.single[0], 'Dome Camera');
    expect(cam.rows.single[1], 2.0, reason: '3 sold − 1 returned');
    expect(b.build(ReportKind.salesInvoices, march, ReportFilter(customerId: x.bilal.id)).rows.single[0], x.s2.number);
    expect(b.build(ReportKind.salesInvoices, march, const ReportFilter(serial: 'nv2')).rows.single[0], x.s2.number);
    // Line-level: product filter counts only that product's revenue.
    final daily = b.build(ReportKind.salesDaily, march, ReportFilter(productId: x.nvr.id));
    expect(daily.footer.single[2], 12000.0);
    // Supplier / payment status on purchases.
    final pr = b.build(ReportKind.purchaseRegister, march, ReportFilter(supplierId: x.sup1.id));
    expect(pr.rows.length, 2);
    expect(b.build(ReportKind.purchaseRegister, march, const ReportFilter(payment: PayStatus.partial)).rows.single[0], x.p2.number);
    expect(b.build(ReportKind.purchaseRegister, march, const ReportFilter(payment: PayStatus.unpaid)).rows.single[0], x.p3.number);
    // Serial list by status and by serial number.
    expect(b.build(ReportKind.serials, march, const ReportFilter(txnType: 'sold')).rows.single[0], 'NV2');
    expect(b.build(ReportKind.serials, march, const ReportFilter(serial: 'NV3')).rows.single[3], 'In Stock', reason: 'cancelled sale returned it to stock');
    // Payments: direction + party.
    final pay = b.build(ReportKind.payments, march, ReportFilter(customerId: x.ali.id, txnType: 'received'));
    expect(pay.rows.length, 2);
    // Filters a report does not support are ignored, not half-applied.
    expect(b.build(ReportKind.receivables, march, ReportFilter(productId: x.cam.id)).rows.length, b.build(ReportKind.receivables, march).rows.length);
    // Product list / stock by category filter.
    expect(b.build(ReportKind.productList, march, const ReportFilter(categoryId: 'none')).rows, isEmpty);
    // The heading lists the filters used.
    expect(b.build(ReportKind.salesInvoices, march, ReportFilter(customerId: x.bilal.id)).info.any((l) => l.contains('Customer: Bilal')), isTrue);
  });

  test('ledgers: running balance ends at the account balance; bulk purchase sheet lists every serial', () async {
    final b = ReportBuilder(env.app);
    final led = b.build(ReportKind.customerLedger, DateRange(DateTime(2026, 1, 1), DateTime(2026, 12, 31, 23)), ReportFilter(customerId: x.ali.id));
    expect(led.rows.first[2], 'Opening balance');
    expect(led.rows.last[7], env.app.parties.byId(PartyKind.customer, x.ali.id)!.balance.paisa / 100);
    final sl = b.build(ReportKind.supplierLedger, march, ReportFilter(supplierId: x.sup2.id));
    expect(sl.rows.last[7], 7000.0, reason: '10,000 bought − 3,000 paid');
    final bulk = b.workbook(ReportKind.bulkPurchases, march);
    expect(bulk.length, 2);
    expect(bulk[1].rows.map((r) => r[3]).toList(), ['NV1', 'NV2', 'NV3']);
    expect(bulk[1].rows.firstWhere((r) => r[3] == 'NV2')[4], 'Sold');
    expect(b.workbook(ReportKind.bulkPurchases, march, const ReportFilter(serial: 'NV1'))[1].rows.length, 1);
    final monthly = b.build(ReportKind.businessMonthly, march);
    final f = env.app.reports.financials(march);
    expect(monthly.rows.single[5], f.netSales.paisa / 100);
    expect(monthly.rows.single[10], f.netOperatingProfit.paisa / 100);
    final weekly = b.build(ReportKind.businessWeekly, march);
    expect(weekly.footer.single[5], f.netSales.paisa / 100, reason: 'weeks add up to the month');
    final daily = b.build(ReportKind.businessDaily, march);
    expect(daily.rows.length, 31);
    expect(daily.footer.single[9], 58000.0);
  });

  test('every report builds, with and without filters, and on an empty shop', () async {
    final empty = await TestEnv.create();
    for (final app in [env.app, empty.app]) {
      final b = ReportBuilder(app);
      for (final k in ReportKind.values) {
        for (final f in [ReportFilter.none, ReportFilter(productId: x.cam.id, customerId: x.ali.id, supplierId: x.sup1.id, serial: 'NV1', payment: PayStatus.paid, txnType: 'x')]) {
          for (final t in b.workbook(k, march, f)) {
            expect(t.headers.isNotEmpty, isTrue, reason: k.name);
            for (final row in t.rows) {
              expect(row.length, t.headers.length, reason: '${k.name} row width');
            }
            expect(buildXlsx([t], heading: 'X').isNotEmpty, isTrue);
          }
        }
      }
    }
    await empty.dispose();
  });

  test('Excel workbook: valid parts, PKR and date formats, totals, several sheets', () async {
    final sheets = ReportBuilder(env.app).workbook(ReportKind.profitLoss, march);
    final bytes = buildXlsx(sheets, heading: env.app.ctx.settings.businessName, generated: DateTime(2026, 4, 5, 10, 30));
    final zip = ZipDecoder().decodeBytes(bytes);
    for (final f in zip.files) {
      if (f.name.endsWith('.xml') || f.name.endsWith('.rels')) XmlDocument.parse(utf8.decode(f.content)); // well-formed
    }
    final wb = utf8.decode(zip.findFile('xl/workbook.xml')!.content);
    expect('<sheet '.allMatches(wb).length, 3);
    expect(wb.contains('_xlnm.Print_Titles'), isTrue, reason: 'header row repeats on printed pages');
    final styles = utf8.decode(zip.findFile('xl/styles.xml')!.content);
    expect(styles.contains('PKR'), isTrue);
    final rows = readXlsx(bytes);
    expect(rows[0].single, 'AL-AQSA CCTV & SOLAR SYSTEM');
    expect(rows[1].single, 'Profit & Loss');
    expect(rows[2].single, 'Generated: 05/04/2026 10:30');
    expect(rows[3].single.startsWith('Period: 01/03/2026'), isTrue);
    final head = rows.indexWhere((r) => r.isNotEmpty && r[0] == 'Item');
    final gp = rows.skip(head).firstWhere((r) => r.isNotEmpty && r[0] == 'GROSS PROFIT');
    expect(double.parse(gp[1]), env.app.reports.financials(march).grossProfit.paisa / 100);
    // Money cells use the PKR format (style 6), dates are real Excel dates.
    final s1 = utf8.decode(zip.findFile('xl/worksheets/sheet2.xml')!.content);
    expect(s1.contains('s="6"'), isTrue);
    expect(RegExp(r's="8"><v>46\d{3}').hasMatch(s1), isTrue, reason: 'expense dates as Excel serial dates');
    expect(s1.contains('<autoFilter'), isTrue);
    expect(s1.contains('state="frozen"'), isTrue);
  });

  test('PDF: header on every page, page numbers, empty report, large report', () async {
    final big = ExportTable('Big', ['No', 'Date', 'Product', 'Amount'], [
      for (var i = 0; i < 1200; i++) [i, DateTime(2026, 3, 1 + i % 28), 'Product $i', i * 10.5]
    ], footer: [
      ['Total', null, null, 7550.0]
    ], info: const ['Period: test']);
    final sw = Stopwatch()..start();
    final pdf = await reportPdfMulti(env.app.ctx.settings, [big, const ExportTable('Empty', ['A', 'B'], [])]);
    expect(sw.elapsed.inSeconds < 30, isTrue);
    expect(latin1.decode(pdf.sublist(0, 5)), '%PDF-');
    final pages = RegExp(r'/Type\s*/Page[^s]').allMatches(latin1.decode(pdf)).length;
    expect(pages > 10, isTrue, reason: '1,200 rows span many pages');
    final x0 = buildXlsx([big]);
    expect(readXlsx(x0).length > 1200, isTrue);
  });
}
