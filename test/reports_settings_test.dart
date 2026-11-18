import 'package:al_aqsa_cctv/core/errors.dart';
import 'package:al_aqsa_cctv/domain/models/documents.dart';
import 'package:al_aqsa_cctv/domain/models/operations.dart';
import 'package:al_aqsa_cctv/domain/models/party.dart';
import 'package:al_aqsa_cctv/domain/services/purchase_service.dart';
import 'package:al_aqsa_cctv/domain/services/report_service.dart';
import 'package:al_aqsa_cctv/domain/services/report_tables.dart';
import 'package:al_aqsa_cctv/domain/services/technician_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() async => env.dispose());

  Future<void> seed() async {
    final app = env.app;
    final s = await env.supplier();
    final c = await env.customer();
    final cam = await env.product('Dome Camera', serial: true, brand: 'Hikvision', cost: 4000, price: 6000);
    final cable = await env.product('Cable', decimal: true, cost: 40, price: 70);
    final pur = await app.purchases.create(supplierId: s.id, date: env.clock.now, lines: [
      PurchaseLineInput(productId: cam.id, qty: q(3), unitCost: rs(4000), serials: ['R1', 'R2', 'R3']),
      PurchaseLineInput(productId: cable.id, qty: q(100), unitCost: rs(40)),
    ]);
    await app.purchases.createReturn(purchaseId: pur.id, lines: [ReturnLineInput(productId: cable.id, qty: q(10))], reason: 'Short roll');
    final sale = await app.sales.complete(app.sales.newDraft().copyWith(customerId: c.id, items: [
      SaleItem(productId: cam.id, name: cam.name, qty: q(1), unitPrice: rs(6000), serials: ['R1']),
      SaleItem(productId: cable.id, name: cable.name, qty: Qty.parse('20.5'), unitPrice: rs(70)),
    ], paidAtSale: rs(3000)));
    await app.sales.createReturn(saleId: sale.id, lines: [ReturnLineInput(productId: cable.id, qty: Qty.parse('0.5'))], reason: 'Extra', refundMode: RefundMode.accountCredit);
    final t = await app.technicians.create(name: 'Tariq');
    await app.technicians.issue(technicianId: t.id, lines: [IssueLine(productId: cable.id, qty: q(5))]);
    await app.technicians.recordInstalled(technicianId: t.id, productId: cable.id, qty: q(3), customerId: c.id);
    await app.technicians.returnMaterial(technicianId: t.id, productId: cable.id, qty: q(1), type: TechTxnType.returnUnused);
    await app.parties.addPayment(kind: PartyKind.customer, partyId: c.id, amount: rs(1000), method: PaymentMethod.cash);
    final claim = await app.warranty.openClaim('R1', 'No picture');
    await app.warranty.resolveRepaired(claim.id, 'Reset firmware');
    final job = await app.repairs.receive(customerName: 'Walk-in', productName: 'DVR', reportedIssue: 'Hangs', serviceCharges: rs(500));
    await app.repairs.deliver(job.id, paid: rs(500));
    await app.repairs.receive(customerName: 'Ahmed', productName: 'Camera', reportedIssue: 'Blurry');
  }

  test('Every report builds from real records with sensible totals', () async {
    await seed();
    final b = ReportBuilder(env.app);
    final r = DateRange.today(env.clock.now);
    for (final k in ReportKind.values) {
      final t = b.build(k, r);
      expect(t.headers.isNotEmpty, isTrue, reason: k.name);
      for (final row in t.rows) {
        expect(row.length, t.headers.length, reason: '${k.name} row width');
      }
    }
    final profit = b.build(ReportKind.profit, r);
    // Net sales: 6000 + 20.5*70 (=1435) - returned 0.5*70 (=35) = 7400; COGS 4000 + 820 - 20 = 4800
    expect(profit.rows.firstWhere((x) => x[0] == 'Net Sales')[1], 7400.0);
    expect(profit.rows.firstWhere((x) => x[0] == 'Less: Cost of Goods Sold (FIFO)')[1], -4800.0);
    expect(profit.rows.firstWhere((x) => x[0] == 'Gross Profit from Sales')[1], 2600.0);
    expect(profit.rows.firstWhere((x) => x[0] == 'Repair Revenue')[1], 500.0);
    expect(b.build(ReportKind.repairsPending, r).rows.length, 1);
    expect(b.build(ReportKind.repairsCompleted, r).rows.length, 1);
    expect(b.build(ReportKind.techPending, r).rows.single[2], 1.0);
    expect(b.build(ReportKind.salesByProduct, r).rows.length, 2);
    expect(b.build(ReportKind.warrantyClaims, r).rows.single[6], 'repaired');
    final recv = b.build(ReportKind.receivables, r);
    // 7435 total - 3000 paid - 35 credit - 1000 payment = 3400
    expect(recv.footer.single[2], 3400.0);
    expect(env.app.integrity.check(), isEmpty);
  });

  test('Settings validation and saving', () async {
    final s = env.app.settings;
    await expectLater(() => s.save({'invoicePrefix': 'IN V'}), throwsA(isA<ValidationException>()));
    await expectLater(() => s.save({'businessName': ' '}), throwsA(isA<ValidationException>()));
    await expectLater(() => s.save({'labelWidthMm': 5}), throwsA(isA<ValidationException>()));
    final saved = await s.save({'businessName': 'AL AQSA CCTV Islamabad', 'invoicePrefix': 'AQ', 'receiptFormat': 'thermal58'});
    expect(saved.invoicePrefix, 'AQ');
    final cable = await env.product('Cable2', decimal: true);
    final sup = await env.supplier();
    await env.app.purchases.create(supplierId: sup.id, date: env.clock.now, lines: [PurchaseLineInput(productId: cable.id, qty: q(5), unitCost: rs(1))]);
    final sale = await env.app.sales.complete(env.app.sales.newDraft().copyWith(items: [SaleItem(productId: cable.id, name: 'c', qty: q(1), unitPrice: rs(2))], paidAtSale: rs(2)));
    expect(sale.number, startsWith('AQ-'));
  });

  test('Held bills (drafts) never touch stock and can be deleted', () async {
    final sup = await env.supplier();
    final p = await env.product('Connector');
    await env.app.purchases.create(supplierId: sup.id, date: env.clock.now, lines: [PurchaseLineInput(productId: p.id, qty: q(10), unitCost: rs(10))]);
    final d = env.app.sales.newDraft().copyWith(items: [SaleItem(productId: p.id, name: p.name, qty: q(4), unitPrice: rs(20))], notes: 'Customer coming back');
    await env.app.sales.saveDraft(d);
    expect(env.reload(p.id).stockQty, q(10));
    expect(env.app.sales.list(status: DocStatus.draft).single.notes, 'Customer coming back');
    final done = await env.app.sales.complete(env.app.sales.byId(d.id)!.copyWith(paidAtSale: rs(80)));
    expect(done.status, DocStatus.completed);
    expect(env.reload(p.id).stockQty, q(6));
    await expectLater(() => env.app.sales.deleteDraft(d.id), throwsA(isA<BusinessException>()));
  });

  test('Expired quotation cannot be converted', () async {
    final p = await env.product('NVR');
    var quote = env.app.quotations.newDraft(customerName: 'Hotel').copyWith(items: [QuotationItem(productId: p.id, name: p.name, qty: q(1), unitPrice: rs(1))]);
    quote = await env.app.quotations.save(quote);
    await env.app.quotations.setStatus(quote.id, QuotationStatus.approved);
    env.clock.advance(const Duration(days: 30));
    await expectLater(() => env.app.quotations.convertToInvoice(quote.id), throwsA(isA<BusinessException>()));
  });
}
