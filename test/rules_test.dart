import 'package:al_aqsa_cctv/core/errors.dart';
import 'package:al_aqsa_cctv/domain/models/documents.dart';
import 'package:al_aqsa_cctv/domain/models/operations.dart';
import 'package:al_aqsa_cctv/domain/models/party.dart';
import 'package:al_aqsa_cctv/domain/models/product.dart';
import 'package:al_aqsa_cctv/domain/models/user.dart';
import 'package:al_aqsa_cctv/domain/services/catalog_service.dart';
import 'package:al_aqsa_cctv/domain/services/purchase_service.dart';
import 'package:al_aqsa_cctv/domain/services/report_service.dart';
import 'package:al_aqsa_cctv/domain/services/technician_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() async => env.dispose());

  Future<(Party, Product)> stocked({int qty = 5, bool serial = false, String prefix = 'SN'}) async {
    final s = await env.supplier();
    final p = await env.product('Item ${DateTime.now().microsecondsSinceEpoch}', cost: 1000, price: 1500, serial: serial);
    await env.app.purchases.create(
      supplierId: s.id,
      date: env.clock.now,
      lines: [
        PurchaseLineInput(productId: p.id, qty: q(qty), unitCost: rs(1000), serials: serial ? List.generate(qty, (k) => '$prefix$k') : const []),
      ],
    );
    return (s, env.reload(p.id));
  }

  test('Rule 1: cannot sell beyond available stock', () async {
    final (_, p) = await stocked(qty: 2);
    final draft = env.app.sales.newDraft().copyWith(items: [SaleItem(productId: p.id, name: p.name, qty: q(3), unitPrice: rs(1500))], paidAtSale: rs(4500));
    await expectLater(() => env.app.sales.complete(draft), throwsA(isA<StockException>()));
    expect(env.reload(p.id).stockQty, q(2), reason: 'failed sale leaves stock untouched');
    expect(env.app.sales.list(), isEmpty);
  });

  test('Rule 2: duplicate serial numbers are rejected', () async {
    final (s, p) = await stocked(qty: 2, serial: true, prefix: 'DUP');
    await expectLater(
      () => env.app.purchases.create(
          supplierId: s.id, date: env.clock.now, lines: [PurchaseLineInput(productId: p.id, qty: q(1), unitCost: rs(1000), serials: ['dup0'])]),
      throwsA(isA<DuplicateException>()),
    );
    await expectLater(
      () => env.app.purchases.create(
          supplierId: s.id, date: env.clock.now, lines: [PurchaseLineInput(productId: p.id, qty: q(2), unitCost: rs(1000), serials: ['X1', 'x1'])]),
      throwsA(isA<DuplicateException>()),
    );
    expect(env.reload(p.id).stockQty, q(2));
  });

  test('Rule 3: purchase return cannot exceed purchased quantity', () async {
    final (s, p) = await stocked(qty: 3);
    final pur = env.app.purchases.list().first;
    await expectLater(() => env.app.purchases.createReturn(purchaseId: pur.id, lines: [ReturnLineInput(productId: p.id, qty: q(4))], reason: 'x'),
        throwsA(isA<ValidationException>()));
    await env.app.purchases.createReturn(purchaseId: pur.id, lines: [ReturnLineInput(productId: p.id, qty: q(2))], reason: 'Defective batch');
    expect(env.reload(p.id).stockQty, q(1));
    expect(env.app.parties.byId(PartyKind.supplier, s.id)!.balance, rs(1000));
    await expectLater(() => env.app.purchases.createReturn(purchaseId: pur.id, lines: [ReturnLineInput(productId: p.id, qty: q(2))], reason: 'again'),
        throwsA(isA<ValidationException>()));
    expect(env.app.integrity.check(), isEmpty);
  });

  test('Rule 4: sales return cannot exceed sold quantity; refunds and profit update', () async {
    final (_, p) = await stocked(qty: 5);
    final c = await env.customer();
    final sale = await env.app.sales.complete(env.app.sales.newDraft().copyWith(
          customerId: c.id,
          items: [SaleItem(productId: p.id, name: p.name, qty: q(3), unitPrice: rs(1500))],
        ));
    expect(env.app.parties.byId(PartyKind.customer, c.id)!.balance, rs(4500));
    await expectLater(() => env.app.sales.createReturn(saleId: sale.id, lines: [ReturnLineInput(productId: p.id, qty: q(4))], reason: 'x'),
        throwsA(isA<ValidationException>()));
    await env.app.sales.createReturn(
        saleId: sale.id, lines: [ReturnLineInput(productId: p.id, qty: q(1))], reason: 'Wrong model', refundMode: RefundMode.accountCredit);
    expect(env.reload(p.id).stockQty, q(3));
    expect(env.app.parties.byId(PartyKind.customer, c.id)!.balance, rs(3000));
    final pr = env.app.reports.profit(DateRange.today(env.clock.now));
    expect(pr.grossSales, rs(4500));
    expect(pr.salesReturns, rs(1500));
    expect(pr.netSales, rs(3000));
    expect(pr.cogs, rs(2000));
    expect(pr.grossProfit, rs(1000));
    // damaged return goes to damaged stock, not sellable stock
    await env.app.sales.createReturn(
        saleId: sale.id, lines: [ReturnLineInput(productId: p.id, qty: q(1), condition: 'damaged')], reason: 'Broken', refundMode: RefundMode.cash);
    expect(env.reload(p.id).stockQty, q(3));
    expect(env.reload(p.id).damagedQty, q(1));
    expect(env.app.integrity.check(), isEmpty);
  });

  test('Rule 5: technician cannot return more than issued; damaged returns wait for owner inspection', () async {
    final (_, p) = await stocked(qty: 5);
    final t = await env.app.technicians.create(name: 'Bilal');
    await env.app.technicians.issue(technicianId: t.id, lines: [IssueLine(productId: p.id, qty: q(2))]);
    await expectLater(() => env.app.technicians.returnMaterial(technicianId: t.id, productId: p.id, qty: q(3), type: TechTxnType.returnUnused),
        throwsA(isA<StockException>()));
    await env.app.technicians.returnMaterial(technicianId: t.id, productId: p.id, qty: q(1), type: TechTxnType.returnDamaged, reason: 'Dropped');
    var prod = env.reload(p.id);
    expect(prod.stockQty, q(3));
    expect(prod.issuedQty, q(1));
    expect(prod.inspectionQty, q(1), reason: 'not sellable until inspected');
    expect(prod.damagedQty, q(0));
    expect(env.app.technicians.summary(t.id).returnedForInspection, q(1));
    final item = env.app.inspections.list().single;
    await env.app.inspections.decide(item.id, InspectionDecision.damaged, note: 'Cracked housing');
    prod = env.reload(p.id);
    expect(prod.inspectionQty, q(0));
    expect(prod.damagedQty, q(1));
    expect(env.app.integrity.check(), isEmpty);
  });

  test('Rule 6: quotations do not reduce stock; approved ones convert to a draft invoice', () async {
    final (_, p) = await stocked(qty: 5);
    final c = await env.customer();
    var quote = env.app.quotations.newDraft(customerId: c.id, customerName: c.name);
    quote = quote.copyWith(items: [QuotationItem(productId: p.id, name: p.name, qty: q(4), unitPrice: rs(1500))]);
    quote = await env.app.quotations.save(quote);
    expect(quote.number, startsWith('QT-'));
    expect(env.reload(p.id).stockQty, q(5));
    await expectLater(() => env.app.quotations.convertToInvoice(quote.id), throwsA(isA<BusinessException>()));
    await env.app.quotations.setStatus(quote.id, QuotationStatus.approved);
    final draft = await env.app.quotations.convertToInvoice(quote.id);
    expect(draft.status, DocStatus.draft);
    expect(env.reload(p.id).stockQty, q(5));
    await env.app.sales.complete(draft);
    expect(env.reload(p.id).stockQty, q(1));
    expect(env.app.quotations.byId(quote.id)!.status, QuotationStatus.converted);
    env.clock.advance(const Duration(days: 40));
    var q2 = env.app.quotations.newDraft(customerName: 'Walk-in').copyWith(items: [QuotationItem(productId: p.id, name: p.name, qty: q(1), unitPrice: rs(1))]);
    env.clock.advance(const Duration(days: 40));
    q2 = await env.app.quotations.save(q2);
    expect(q2.statusOn(env.clock.now), QuotationStatus.expired);
  });

  test('Rule 7: cancelled invoice keeps audit history and reverses stock and ledger', () async {
    final (_, p) = await stocked(qty: 5, serial: true, prefix: 'CX');
    final c = await env.customer();
    final sale = await env.app.sales.complete(env.app.sales.newDraft().copyWith(
          customerId: c.id,
          items: [SaleItem(productId: p.id, name: p.name, qty: q(1), unitPrice: rs(1500), serials: ['CX1'])],
          paidAtSale: rs(500),
        ));
    expect(env.app.parties.byId(PartyKind.customer, c.id)!.balance, rs(1000));
    await env.app.sales.cancel(sale.id, 'Customer changed mind');
    final saved = env.app.sales.byId(sale.id)!;
    expect(saved.status, DocStatus.cancelled);
    expect(saved.number, sale.number);
    expect(env.reload(p.id).stockQty, q(5));
    expect(env.app.serials.find('CX1')!.status, SerialStatus.inStock);
    expect(env.app.parties.byId(PartyKind.customer, c.id)!.balance, rs(0));
    expect(env.app.ctx.store.values('audit_logs').any((j) => j['action'] == 'cancel' && j['entityId'] == sale.id), isTrue);
    expect(env.app.integrity.check(), isEmpty);
  });

  test('Rule 8: voided payments are reversed, not deleted', () async {
    final c = await env.customer();
    final pay = await env.app.parties.addPayment(kind: PartyKind.customer, partyId: c.id, amount: rs(700), method: PaymentMethod.cash);
    expect(env.app.parties.byId(PartyKind.customer, c.id)!.balance, rs(-700));
    await env.app.parties.voidPayment(pay.id, 'Entered twice');
    expect(env.app.parties.byId(PartyKind.customer, c.id)!.balance, rs(0));
    expect(env.app.parties.payments().single.voided, isTrue);
    expect(env.app.parties.entries(PartyKind.customer, c.id).length, 2);
  });

  test('Rule 9: price changes do not alter historical invoices', () async {
    final (_, p) = await stocked(qty: 5);
    final sale = await env.app.sales.complete(env.app.sales.newDraft().copyWith(
          items: [SaleItem(productId: p.id, name: p.name, qty: q(1), unitPrice: rs(1500))],
          paidAtSale: rs(1500),
        ));
    await env.app.catalog.update(
        p.id, ProductInput(name: 'Renamed', purchasePrice: rs(1000), sellingPrice: rs(9999)));
    final again = env.app.sales.byId(sale.id)!;
    expect(again.items.single.unitPrice, rs(1500));
    expect(again.items.single.name, p.name);
    expect(again.total, rs(1500));
  });

  test('Rule 10: every stock change creates movement records', () async {
    final (_, p) = await stocked(qty: 5);
    await env.app.inventory.adjustTo(p.id, q(4), 'Stock count');
    final moves = env.app.inventory.history(p.id);
    expect(moves.length, 2);
    final adj = moves.firstWhere((m0) => m0.type == 'adjustment');
    expect(adj.before, q(5));
    expect(adj.after, q(4));
    expect(adj.reason, 'Stock count');
    await expectLater(() => env.app.inventory.adjustTo(p.id, q(3), ''), throwsA(isA<ValidationException>()));
  });

  test('Credit sale requires a customer; walk-in must pay in full', () async {
    final (_, p) = await stocked(qty: 5);
    final draft = env.app.sales.newDraft().copyWith(items: [SaleItem(productId: p.id, name: p.name, qty: q(1), unitPrice: rs(1500))], paidAtSale: rs(100));
    await expectLater(() => env.app.sales.complete(draft), throwsA(isA<ValidationException>()));
  });

  test('Products with transactions are archived, not deleted; barcodes are unique', () async {
    final (_, p) = await stocked(qty: 1);
    expect(await env.app.catalog.deleteOrArchive(p.id), isTrue);
    expect(env.app.catalog.byId(p.id)!.archived, isTrue);
    final fresh = await env.product('Unused', cost: 1, price: 2);
    expect(await env.app.catalog.deleteOrArchive(fresh.id), isFalse);
    expect(env.app.catalog.byId(fresh.id), isNull);
    await env.app.catalog.create(ProductInput(name: 'A', purchasePrice: rs(1), sellingPrice: rs(2), companyBarcodes: ['6901234567890']));
    await expectLater(() => env.app.catalog.create(ProductInput(name: 'B', purchasePrice: rs(1), sellingPrice: rs(2), companyBarcodes: ['6901234567890'])),
        throwsA(isA<DuplicateException>()));
    await expectLater(() => env.app.catalog.create(ProductInput(name: 'A', purchasePrice: rs(1), sellingPrice: rs(2))), throwsA(isA<DuplicateException>()));
    expect(env.app.catalog.lookup('UNKNOWN-CODE'), isNull);
  });

  test('Technician role permissions are enforced', () async {
    final (s, p) = await stocked(qty: 5);
    final t = await env.app.technicians.create(name: 'Hamza', username: 'hamza', password: 'pass1234');
    await env.app.technicians.issue(technicianId: t.id, lines: [IssueLine(productId: p.id, qty: q(2))]);
    env.app.auth.logout();
    await env.app.auth.login('hamza', 'pass1234');
    await expectLater(() => env.app.purchases.create(supplierId: s.id, date: env.clock.now, lines: [PurchaseLineInput(productId: p.id, qty: q(1), unitCost: rs(1))]),
        throwsA(isA<PermissionException>()));
    // own usage is allowed
    await env.app.technicians.recordInstalled(technicianId: t.id, productId: p.id, qty: q(1), jobRef: 'Site A');
    expect(env.app.technicians.summary(t.id).installed, q(1));
    env.app.auth.logout();
    await env.app.auth.login('owner', 'secret123');
    await env.app.auth.setActive(env.app.auth.findByUsername('hamza')!.id, false);
    env.app.auth.logout();
    await expectLater(() => env.app.auth.login('hamza', 'pass1234'), throwsA(isA<PermissionException>()));
    expect(env.app.auth.loginHistory().where((e) => !e.success).length, 1);
  });

  test('Warranty claim with replacement transfers warranty to the new unit', () async {
    final (_, p) = await stocked(qty: 3, serial: true, prefix: 'W');
    final c = await env.customer();
    await env.app.sales.complete(env.app.sales.newDraft().copyWith(
          customerId: c.id,
          items: [SaleItem(productId: p.id, name: p.name, qty: q(1), unitPrice: rs(1500), serials: ['W0'])],
        ));
    final w = env.app.warranty.check('w0')!;
    expect(w.state.name, 'active');
    final claim = await env.app.warranty.openClaim('W0', 'No video');
    expect(env.app.serials.find('W0')!.status, SerialStatus.underRepair);
    await env.app.warranty.replace(claim.id, 'W1', 'Replaced from stock');
    expect(env.app.serials.find('W0')!.status, SerialStatus.damaged);
    final w1 = env.app.serials.find('W1')!;
    expect(w1.status, SerialStatus.sold);
    expect(w1.customerId, c.id);
    expect(w1.warrantyExpiry, env.app.serials.find('W0')!.warrantyExpiry);
    expect(env.reload(p.id).stockQty, q(1));
    expect(env.reload(p.id).damagedQty, q(1));
    env.clock.advance(const Duration(days: 400));
    expect(env.app.warranty.check('W1')!.state.name, 'expired');
    expect(env.app.integrity.check(), isEmpty);
  });

  test('Repair job: parts consume stock, delivery posts charges', () async {
    final (_, part) = await stocked(qty: 4);
    final c = await env.customer();
    final job = await env.app.repairs.receive(customerId: c.id, customerName: c.name, productName: 'Old DVR', reportedIssue: 'No power', serviceCharges: rs(800));
    expect(job.number, startsWith('RJ-'));
    await env.app.repairs.updateStatus(job.id, RepairStatus.diagnosing);
    await env.app.repairs.addPart(job.id, part.id, q(1), rs(1500));
    await env.app.repairs.updateStatus(job.id, RepairStatus.repaired);
    final done = await env.app.repairs.deliver(job.id, paid: rs(1000));
    expect(done.status, RepairStatus.delivered);
    expect(done.history.length, 4);
    expect(env.reload(part.id).stockQty, q(3));
    expect(env.app.parties.byId(PartyKind.customer, c.id)!.balance, rs(1300));
    final pr = env.app.reports.profit(DateRange.today(env.clock.now));
    expect(pr.repairRevenue, rs(2300));
    expect(pr.repairPartsCost, rs(1000));
    await expectLater(() => env.app.repairs.deliver(job.id), throwsA(isA<BusinessException>()));
  });

  test('Supplier and customer opening balances and adjustments', () async {
    final s = await env.app.parties.create(kind: PartyKind.supplier, name: 'Dahua Co', openingBalance: rs(5000));
    expect(s.balance, rs(5000));
    await env.app.parties.addPayment(kind: PartyKind.supplier, partyId: s.id, amount: rs(2000), method: PaymentMethod.cash);
    expect(env.app.parties.byId(PartyKind.supplier, s.id)!.balance, rs(3000));
    final c = await env.app.parties.create(kind: PartyKind.customer, name: 'Old Client', openingBalance: rs(1200));
    await env.app.parties.adjust(kind: PartyKind.customer, partyId: c.id, amount: rs(200), increaseBalance: false, note: 'Goodwill discount');
    expect(env.app.parties.byId(PartyKind.customer, c.id)!.balance, rs(1000));
    expect(env.app.parties.totalReceivables(), rs(1000));
    expect(env.app.parties.totalPayables(), rs(3000));
    expect(env.app.integrity.check(), isEmpty);
  });

  test('User roles map correctly', () {
    expect(rolePermissions[UserRole.technician]!.contains(Permission.managePurchases), isFalse);
    expect(rolePermissions[UserRole.owner]!.containsAll(Permission.values), isTrue);
  });
}
