import 'package:al_aqsa_cctv/domain/models/documents.dart';
import 'package:al_aqsa_cctv/domain/models/json_utils.dart';
import 'package:al_aqsa_cctv/domain/models/operations.dart';
import 'package:al_aqsa_cctv/domain/models/party.dart';
import 'package:al_aqsa_cctv/domain/models/product.dart';
import 'package:al_aqsa_cctv/domain/services/purchase_service.dart';
import 'package:al_aqsa_cctv/domain/services/report_service.dart';
import 'package:al_aqsa_cctv/domain/services/technician_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() async => env.dispose());

  test('End-to-end: purchase → technician → install → invoice → payment', () async {
    final app = env.app;

    // 1. Create supplier
    final supplier = await env.supplier();

    // 2-3. Purchase 10 CCTV cameras with serial numbers
    final cam = await env.product('Hikvision 2MP Dome Camera', cost: 4000, price: 6000, serial: true, warrantyMonths: 12);
    final serials = List.generate(10, (k) => 'cam${(k + 1).toString().padLeft(3, '0')}'); // lower-case on purpose
    final pur = await app.purchases.create(
      supplierId: supplier.id,
      supplierInvoiceNo: 'HK-991',
      date: env.clock.now,
      lines: [PurchaseLineInput(productId: cam.id, qty: q(10), unitCost: rs(4000), serials: serials)],
      paid: rs(20000),
    );
    expect(pur.total, rs(40000));
    expect(env.reload(cam.id).stockQty, q(10));
    expect(app.parties.byId(PartyKind.supplier, supplier.id)!.balance, rs(20000));
    expect(app.serials.find('CAM001')!.status, SerialStatus.inStock);

    // 4. Product without company barcode has a generated internal code that scans
    final scanned = app.catalog.lookup(cam.internalCode);
    expect(scanned!.product.id, cam.id);
    // scanning a unit serial identifies product + unit
    final unitScan = app.catalog.lookup(' cam007 ');
    expect(unitScan!.serial!.serial, 'CAM007');

    // 5. Issue 4 cameras to a technician
    final tech = await app.technicians.create(name: 'Usman', username: 'usman', password: 'tech1234');
    await app.technicians.issue(technicianId: tech.id, lines: [
      IssueLine(productId: cam.id, qty: q(4), serials: ['CAM001', 'CAM002', 'CAM003', 'CAM004']),
    ], jobRef: 'JOB-1');
    var p = env.reload(cam.id);
    expect(p.stockQty, q(6));
    expect(p.issuedQty, q(4));
    expect(app.serials.find('CAM002')!.status, SerialStatus.issuedToTechnician);

    // 6. Technician returns 1 unused camera
    await app.technicians.returnMaterial(
        technicianId: tech.id, productId: cam.id, qty: q(1), type: TechTxnType.returnUnused, serialNumbers: ['CAM004'], reason: 'Not needed');
    p = env.reload(cam.id);
    expect(p.stockQty, q(7));
    expect(p.issuedQty, q(3));
    expect(app.serials.find('CAM004')!.status, SerialStatus.inStock);

    // 7. Record 3 installed cameras against a customer job
    final customer = await env.customer();
    final usage = await app.technicians.recordInstalled(
        technicianId: tech.id, productId: cam.id, qty: q(3), serialNumbers: ['CAM001', 'CAM002', 'CAM003'], customerId: customer.id, jobRef: 'JOB-1');
    p = env.reload(cam.id);
    expect(p.issuedQty, q(0));
    expect(p.stockQty, q(7), reason: 'installed material is not sold and not back in stock');
    expect(usage.cost, rs(12000));
    final summary = app.technicians.summary(tech.id);
    expect(summary.issued, q(4));
    expect(summary.returnedUnused, q(1));
    expect(summary.installed, q(3));
    expect(summary.remaining, q(0));
    expect(app.technicians.pendingInstallations(customerId: customer.id).length, 1);

    // 8. Sales invoice: the 3 installed cameras + 1 more from shop stock
    final draft = app.sales.newDraft().copyWith(
      customerId: customer.id,
      items: [
        SaleItem(productId: cam.id, name: cam.name, qty: q(3), unitPrice: rs(6000), serials: ['CAM001', 'CAM002', 'CAM003'], techUsageId: usage.id),
        SaleItem(productId: cam.id, name: cam.name, qty: q(1), unitPrice: rs(6000), serials: ['CAM005']),
      ],
      invoiceDiscount: rs(1000),
      paidAtSale: rs(10000), // 9. partial payment
    );
    final sale = await app.sales.complete(draft);
    expect(sale.number, startsWith('INV-'));
    expect(sale.total, rs(23000));

    // 10. Verify stock and customer ledger
    p = env.reload(cam.id);
    expect(p.stockQty, q(6));
    expect(p.issuedQty, q(0));
    expect(app.parties.byId(PartyKind.customer, customer.id)!.balance, rs(13000));
    expect(app.parties.ledgerBalance(PartyKind.customer, customer.id), rs(13000));
    expect(app.technicians.pendingInstallations(customerId: customer.id), isEmpty);

    await app.parties.addPayment(kind: PartyKind.customer, partyId: customer.id, amount: rs(5000), method: PaymentMethod.bankTransfer);
    expect(app.parties.byId(PartyKind.customer, customer.id)!.balance, rs(8000));
    final st = app.parties.statement(PartyKind.customer, customer.id);
    expect(st.closingBalance, rs(8000));
    expect(st.lines.map((l) => l.entry.type), [LedgerType.sale, LedgerType.payment, LedgerType.payment]);

    // 11. Serial history
    final c1 = app.serials.find('CAM001')!;
    expect(c1.status, SerialStatus.sold);
    expect(c1.customerId, customer.id);
    expect(c1.history.map((h) => h.status), [SerialStatus.inStock, SerialStatus.issuedToTechnician, SerialStatus.installed, SerialStatus.sold]);
    expect(c1.warrantyExpiry, addMonths(sale.date, 12));

    // 12. Profit: net sales 23,000 - FIFO COGS (4 x 4,000) = 7,000 gross profit
    final profit = app.reports.profit(DateRange.today(env.clock.now));
    expect(profit.netSales, rs(23000));
    expect(profit.cogs, rs(16000));
    expect(profit.grossProfit, rs(7000));

    // Everything reconciles
    expect(app.integrity.check(), isEmpty);
  });

  test('FIFO costing uses oldest layers first', () async {
    final app = env.app;
    final s = await env.supplier();
    final cable = await env.product('Cat6 Cable Roll', cost: 100, price: 300);
    await app.purchases.create(supplierId: s.id, date: env.clock.now, lines: [PurchaseLineInput(productId: cable.id, qty: q(2), unitCost: rs(100))]);
    env.clock.advance(const Duration(days: 1));
    await app.purchases.create(supplierId: s.id, date: env.clock.now, lines: [PurchaseLineInput(productId: cable.id, qty: q(2), unitCost: rs(200))]);
    final sale = await app.sales.complete(app.sales.newDraft().copyWith(
          items: [SaleItem(productId: cable.id, name: cable.name, qty: q(3), unitPrice: rs(300))],
          paidAtSale: rs(900),
        ));
    expect(sale.cogs, rs(400)); // 100 + 100 + 200
    expect(app.inventory.stockValuation(productId: cable.id), rs(200));
    expect(app.integrity.check(), isEmpty);
  });

  test('Purchase line discount and tax flow into landed cost', () async {
    final app = env.app;
    final s = await env.supplier();
    final dvr = await env.product('8CH DVR', cost: 10000, price: 14000);
    final pur = await app.purchases.create(supplierId: s.id, date: env.clock.now, lines: [
      PurchaseLineInput(productId: dvr.id, qty: q(2), unitCost: rs(10000), discount: rs(1000), tax: rs(500)),
    ]);
    expect(pur.total, rs(19500));
    expect(app.inventory.stockValuation(productId: dvr.id), rs(19500));
    expect(app.parties.byId(PartyKind.supplier, s.id)!.balance, rs(19500));
  });

  test('Monthly report uses database figures', () async {
    final app = env.app;
    final s = await env.supplier();
    final pr = await env.product('Power Supply', cost: 500, price: 800);
    await app.purchases.create(supplierId: s.id, date: env.clock.now, lines: [PurchaseLineInput(productId: pr.id, qty: q(5), unitCost: rs(500))]);
    await app.sales.complete(app.sales.newDraft().copyWith(
          items: [SaleItem(productId: pr.id, name: pr.name, qty: q(2), unitPrice: rs(800))],
          paidAtSale: rs(1600),
        ));
    final months = app.reports.monthly(3);
    expect(months.length, 3);
    expect(months.last.sales, rs(1600));
    expect(months.last.purchases, rs(2500));
    expect(months.last.grossProfit, rs(600));
    expect(months.first.sales, rs(0));
    final top = app.reports.productSales(DateRange.thisMonth(env.clock.now));
    expect(top.single.qty, q(2));
  });
}
