// End-to-end business scenarios A–F from the project brief.
import 'dart:io';

import 'package:al_aqsa_cctv/core/password_hasher.dart';
import 'package:al_aqsa_cctv/data/migrations.dart';
import 'package:al_aqsa_cctv/data/store/data_store.dart';
import 'package:al_aqsa_cctv/data/store/hive_store.dart';
import 'package:al_aqsa_cctv/domain/models/documents.dart';
import 'package:al_aqsa_cctv/domain/models/json_utils.dart';
import 'package:al_aqsa_cctv/domain/models/operations.dart';
import 'package:al_aqsa_cctv/domain/models/party.dart';
import 'package:al_aqsa_cctv/domain/models/product.dart';
import 'package:al_aqsa_cctv/domain/models/user.dart';
import 'package:al_aqsa_cctv/domain/services/app_services.dart';
import 'package:al_aqsa_cctv/domain/services/catalog_service.dart';
import 'package:al_aqsa_cctv/domain/services/purchase_service.dart';
import 'package:al_aqsa_cctv/domain/services/report_service.dart';
import 'package:al_aqsa_cctv/domain/services/technician_service.dart';
import 'package:al_aqsa_cctv/domain/services/warranty_repair_service.dart';
import 'package:al_aqsa_cctv/printing/pdf_docs.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

bool _isPdf(List<int> b) => b.length > 500 && String.fromCharCodes(b.sublist(0, 5)) == '%PDF-';

void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() async => env.dispose());

  test('Scenario A: purchase → scan barcode → POS sale with partial payment → invoice', () async {
    final app = env.app;
    final sup = await app.parties.create(kind: PartyKind.supplier, name: 'Rawalpindi CCTV Wholesale', phone: '0512345678');
    final cam = await app.catalog.create(ProductInput(
        name: 'Hikvision 4MP Bullet', brand: 'Hikvision', purchasePrice: rs(5200), sellingPrice: rs(7500), requiresSerial: true, warrantyMonths: 12, companyBarcodes: ['6954273698123']));
    final pur = await app.purchases.create(
      supplierId: sup.id,
      supplierInvoiceNo: 'RW-5531',
      date: env.clock.now,
      lines: [PurchaseLineInput(productId: cam.id, qty: q(5), unitCost: rs(5200), serials: ['HK01', 'HK02', 'HK03', 'HK04', 'HK05'])],
      paid: rs(10000),
    );
    expect(env.reload(cam.id).stockQty, q(5));
    expect(app.parties.byId(PartyKind.supplier, sup.id)!.balance, rs(16000));
    await expectLater(() => app.purchases.create(supplierId: sup.id, supplierInvoiceNo: 'rw-5531', date: env.clock.now, lines: [PurchaseLineInput(productId: cam.id, qty: q(1), unitCost: rs(1), serials: ['X9'])]),
        throwsA(isA<Exception>()), reason: 'same supplier invoice cannot be entered twice');

    // Scan the company barcode and a unit serial, as the POS does.
    expect(app.catalog.lookup('6954273698123')!.product.id, cam.id);
    final unit = app.catalog.lookup('hk03')!;
    expect(unit.serial!.status, SerialStatus.inStock);

    final cust = await app.parties.create(kind: PartyKind.customer, name: 'Bismillah Store', phone: '03001112233');
    final sale = await app.sales.complete(app.sales.newDraft().copyWith(
      customerId: cust.id,
      items: [SaleItem(productId: cam.id, name: cam.name, qty: q(2), unitPrice: rs(7500), serials: [unit.serial!.key, 'HK01'])],
      invoiceDiscount: rs(500),
      paidAtSale: rs(10000),
      method: PaymentMethod.cash,
    ));
    expect(sale.total, rs(14500));
    expect(sale.remaining, rs(4500));
    expect(env.reload(cam.id).stockQty, q(3));
    expect(app.parties.byId(PartyKind.customer, cust.id)!.balance, rs(4500));
    expect(app.serials.find('HK03')!.status, SerialStatus.sold);
    expect(sale.cogs, rs(10400));
    for (final paper in PaperKind.values) {
      expect(_isPdf(await invoicePdf(app.ctx.settings, sale, customer: cust, paper: paper)), isTrue);
    }
    expect(_isPdf(await purchasePdf(app.ctx.settings, pur, sup)), isTrue);
    expect(app.integrity.check(), isEmpty);
  });

  test('Scenario B: technician issue → install → used/faulty returns → inspection queue', () async {
    final app = env.app;
    final sup = await env.supplier();
    final cam = await env.product('Dahua Dome 2MP', serial: true, brand: 'Dahua', cost: 3000, price: 4500);
    final cable = await env.product('Cat6 Cable (m)', decimal: true, cost: 40, price: 70);
    await app.purchases.create(supplierId: sup.id, date: env.clock.now, lines: [
      PurchaseLineInput(productId: cam.id, qty: q(4), unitCost: rs(3000), serials: ['DH1', 'DH2', 'DH3', 'DH4']),
      PurchaseLineInput(productId: cable.id, qty: q(305), unitCost: rs(40)),
    ]);
    final tech = await app.technicians.create(name: 'Waqas', phone: '03331234567', username: 'waqas', password: 'waqas123');
    expect(app.auth.findByUsername('waqas')!.role, UserRole.technician);
    await app.technicians.issue(technicianId: tech.id, jobRef: 'F-7 House', lines: [
      IssueLine(productId: cam.id, qty: q(3), serials: ['DH1', 'DH2', 'DH3']),
      IssueLine(productId: cable.id, qty: Qty.parse('50')),
    ]);
    final cust = await env.customer();
    await app.technicians.recordInstalled(technicianId: tech.id, productId: cam.id, qty: q(1), serialNumbers: ['DH1'], customerId: cust.id, jobRef: 'F-7 House');
    await app.technicians.recordInstalled(technicianId: tech.id, productId: cable.id, qty: Qty.parse('42.5'), customerId: cust.id, jobRef: 'F-7 House');

    // Technician logs in and records the rest themselves.
    app.auth.logout();
    await app.auth.login('waqas', 'waqas123');
    expect(app.technicians.summary(tech.id).remaining, Qty.parse('9.5'));
    await app.technicians.returnMaterial(technicianId: tech.id, productId: cable.id, qty: Qty.parse('5'), type: TechTxnType.returnUnused);
    await app.technicians.returnMaterial(technicianId: tech.id, productId: cable.id, qty: Qty.parse('2.5'), type: TechTxnType.returnUsed, reason: 'Cut pieces');
    await app.technicians.returnMaterial(technicianId: tech.id, productId: cam.id, qty: q(1), type: TechTxnType.returnFaulty, serialNumbers: ['DH2'], reason: 'IR not working');
    await expectLater(() => app.inspections.decide(app.inspections.list().first.id, InspectionDecision.sellable), throwsA(isA<Exception>()), reason: 'technician cannot approve');
    app.auth.logout();
    await app.auth.login('owner', 'secret123');

    var c = env.reload(cable.id);
    expect(c.stockQty, Qty.parse('260')); // 305 - 50 + 5
    expect(c.issuedQty, Qty.parse('0'));
    expect(c.inspectionQty, Qty.parse('2.5'));
    var k = env.reload(cam.id);
    expect(k.stockQty, q(1));
    expect(k.issuedQty, q(1)); // DH3 still with technician
    expect(k.inspectionQty, q(1));
    expect(app.serials.find('DH2')!.status, SerialStatus.pendingInspection);
    expect(app.serials.find('DH1')!.status, SerialStatus.installed);
    expect(app.inspections.list().length, 2);

    final usedCable = app.inspections.list().firstWhere((x) => x.productId == cable.id);
    await app.inspections.decide(usedCable.id, InspectionDecision.damaged, note: 'Too short to sell');
    final faulty = app.inspections.list().firstWhere((x) => x.productId == cam.id);
    await app.inspections.decide(faulty.id, InspectionDecision.repairable, note: 'Send to Dahua service');
    c = env.reload(cable.id);
    k = env.reload(cam.id);
    expect(c.damagedQty, Qty.parse('2.5'));
    expect(k.repairableQty, q(1));
    expect(app.technicians.pendingInstallations(customerId: cust.id).length, 2);
    final s = app.technicians.summary(tech.id);
    expect(s.issued, Qty.parse('53'));
    expect(s.installed, Qty.parse('43.5'));
    expect(s.returnedUnused, Qty.parse('5'));
    expect(s.returnedForInspection, Qty.parse('3.5'));
    expect(s.remaining, q(1));
    expect(app.integrity.check(), isEmpty);
  });

  test('Scenario C: customer credit → second payment → statement', () async {
    final app = env.app;
    final sup = await env.supplier();
    final nvr = await env.product('NVR 8CH', cost: 14000, price: 18500);
    await app.purchases.create(supplierId: sup.id, date: env.clock.now, lines: [PurchaseLineInput(productId: nvr.id, qty: q(3), unitCost: rs(14000))]);
    final cust = await app.parties.create(kind: PartyKind.customer, name: 'Al Noor School', phone: '0519876543', openingBalance: rs(2000));
    await app.sales.complete(app.sales.newDraft().copyWith(customerId: cust.id, items: [SaleItem(productId: nvr.id, name: nvr.name, qty: q(2), unitPrice: rs(18500))], paidAtSale: rs(15000)));
    expect(app.parties.byId(PartyKind.customer, cust.id)!.balance, rs(24000)); // 2000 + 37000 - 15000
    env.clock.advance(const Duration(days: 5));
    final pay = await app.parties.addPayment(kind: PartyKind.customer, partyId: cust.id, amount: rs(20000), method: PaymentMethod.bankTransfer, note: 'HBL ref 7781');
    final bal = app.parties.byId(PartyKind.customer, cust.id)!.balance;
    expect(bal, rs(4000));
    expect(app.parties.ledgerBalance(PartyKind.customer, cust.id), bal);
    final st = app.parties.statement(PartyKind.customer, cust.id);
    expect(st.closingBalance, rs(4000));
    expect(st.lines.map((l) => l.entry.type), [LedgerType.opening, LedgerType.sale, LedgerType.payment, LedgerType.payment]);
    final period = app.parties.statement(PartyKind.customer, cust.id, from: env.clock.now);
    expect(period.openingBalance, rs(24000));
    expect(period.lines.single.entry.refId, pay.id);
    expect(_isPdf(await statementPdf(app.ctx.settings, st)), isTrue);
    expect(_isPdf(await paymentReceiptPdf(app.ctx.settings, pay, party: cust, balanceAfter: bal)), isTrue);
    expect(app.parties.totalReceivables(), rs(4000));
    expect(app.integrity.check(), isEmpty);
  });

  test('Scenario D: warranty lookup → claim → repair job with parts → deliver', () async {
    final app = env.app;
    final sup = await env.supplier();
    final dvr = await env.product('DVR 16CH', serial: true, brand: 'Hikvision', cost: 12000, price: 16000, warrantyMonths: 24);
    final psu = await env.product('12V 5A Adapter', cost: 450, price: 800);
    await app.purchases.create(supplierId: sup.id, date: env.clock.now, lines: [
      PurchaseLineInput(productId: dvr.id, qty: q(1), unitCost: rs(12000), serials: ['DVR777']),
      PurchaseLineInput(productId: psu.id, qty: q(10), unitCost: rs(450)),
    ]);
    final cust = await env.customer();
    await app.sales.complete(app.sales.newDraft().copyWith(customerId: cust.id, items: [SaleItem(productId: dvr.id, name: dvr.name, qty: q(1), unitPrice: rs(16000), serials: ['DVR777'])], paidAtSale: rs(16000)));
    env.clock.advance(const Duration(days: 200));
    final w = app.warranty.check('dvr777')!;
    expect(w.state, WarrantyState.active);
    expect(w.serial.warrantyExpiry, addMonths(DateTime(2026, 3, 10, 10), 24));
    final claim = await app.warranty.openClaim('DVR777', 'Restarts every few minutes');
    expect(app.serials.find('DVR777')!.status, SerialStatus.underRepair);
    final job = await app.repairs.receive(customerId: cust.id, customerName: cust.name, productId: dvr.id, productName: dvr.name, serial: 'DVR777', reportedIssue: 'Restarts', serviceCharges: rs(0));
    expect(job.underWarranty, isTrue);
    final tech = await app.technicians.create(name: 'Repair Tech');
    await app.repairs.updateStatus(job.id, RepairStatus.diagnosing, technicianId: tech.id, note: 'Power supply faulty');
    await app.repairs.addPart(job.id, psu.id, q(1), rs(0)); // free under warranty
    await app.repairs.updateStatus(job.id, RepairStatus.repaired, repairNotes: 'Replaced adapter', serviceCharges: rs(300)); // non-warranty cleaning
    await app.repairs.updateStatus(job.id, RepairStatus.readyForCollection);
    final done = await app.repairs.deliver(job.id, paid: rs(300));
    await app.warranty.resolveRepaired(claim.id, 'Adapter replaced under warranty');
    expect(done.status, RepairStatus.delivered);
    expect(env.reload(psu.id).stockQty, q(9));
    expect(app.serials.find('DVR777')!.status, SerialStatus.sold);
    expect(app.parties.byId(PartyKind.customer, cust.id)!.balance, rs(0));
    final p = app.reports.profit(DateRange(DateTime(2026), env.clock.now));
    expect(p.repairRevenue, rs(300));
    expect(p.repairPartsCost, rs(450));
    expect(_isPdf(await repairReceiptPdf(app.ctx.settings, done, technicianName: tech.name)), isTrue);
    expect(app.integrity.check(), isEmpty);
  });

  test('Scenario E: customer, supplier and technician returns with reversals', () async {
    final app = env.app;
    final sup = await env.supplier();
    final hdd = await env.product('HDD 2TB', serial: true, brand: 'Seagate', cost: 9000, price: 11500);
    final bnc = await env.product('BNC Connector', cost: 20, price: 50);
    final pur = await app.purchases.create(supplierId: sup.id, date: env.clock.now, lines: [
      PurchaseLineInput(productId: hdd.id, qty: q(3), unitCost: rs(9000), serials: ['SG1', 'SG2', 'SG3']),
      PurchaseLineInput(productId: bnc.id, qty: q(100), unitCost: rs(20)),
    ]);
    expect(app.parties.byId(PartyKind.supplier, sup.id)!.balance, rs(29000));
    final cust = await env.customer();
    final sale = await app.sales.complete(app.sales.newDraft().copyWith(customerId: cust.id, items: [
      SaleItem(productId: hdd.id, name: hdd.name, qty: q(1), unitPrice: rs(11500), serials: ['SG1']),
      SaleItem(productId: bnc.id, name: bnc.name, qty: q(20), unitPrice: rs(50)),
    ]));
    expect(app.parties.byId(PartyKind.customer, cust.id)!.balance, rs(12500));

    // Customer returns the HDD (to inspection) and 5 connectors (good).
    await app.sales.createReturn(saleId: sale.id, refundMode: RefundMode.accountCredit, reason: 'Clicking noise', lines: [
      ReturnLineInput(productId: hdd.id, qty: q(1), serials: ['SG1'], condition: 'inspect'),
      ReturnLineInput(productId: bnc.id, qty: q(5)),
    ]);
    expect(app.parties.byId(PartyKind.customer, cust.id)!.balance, rs(750)); // 12500 - 11500 - 250
    expect(env.reload(hdd.id).inspectionQty, q(1));
    expect(env.reload(bnc.id).stockQty, q(85));
    await app.inspections.decide(app.inspections.list().single.id, InspectionDecision.damaged, note: 'Bad sectors');

    // Damaged HDD goes back to the supplier for credit.
    await app.purchases.createReturn(purchaseId: pur.id, lines: [ReturnLineInput(productId: hdd.id, qty: q(1), serials: ['SG1'])], reason: 'Faulty unit');
    expect(app.parties.byId(PartyKind.supplier, sup.id)!.balance, rs(20000));
    expect(env.reload(hdd.id).damagedQty, q(0));
    expect(app.serials.find('SG1')!.status, SerialStatus.returnedToSupplier);

    // Technician returns unused connectors.
    final t = await app.technicians.create(name: 'Naveed');
    await app.technicians.issue(technicianId: t.id, lines: [IssueLine(productId: bnc.id, qty: q(30))]);
    await app.technicians.returnMaterial(technicianId: t.id, productId: bnc.id, qty: q(10), type: TechTxnType.returnUnused);
    expect(env.reload(bnc.id).stockQty, q(65));
    expect(env.reload(bnc.id).issuedQty, q(20));

    final moveTypes = app.inventory.history(bnc.id).map((m0) => m0.type).toSet();
    expect(moveTypes.containsAll({'purchase', 'sale', 'salesReturn', 'techIssue', 'techReturn'}), isTrue);
    final pr = app.reports.profit(DateRange.today(env.clock.now));
    expect(pr.salesReturns, rs(11750));
    expect(pr.netSales, rs(750));
    expect(app.integrity.check(), isEmpty);
  });

  test('Scenario F: data survives restart; backup → close → restore on real Hive files', () async {
    final dir = await Directory.systemTemp.createTemp('aqsa_f');
    final clock = TestClock();
    Future<(HiveStore, AppServices)> openApp() async {
      final store = await HiveStore.open('${dir.path}/data');
      await Migrator.run(store);
      final app = AppServices(store, localBackupDir: '${dir.path}/backups', clock: clock.call, hasher: const PasswordHasher(iterations: 10));
      return (store, app);
    }

    var (store, app) = await openApp();
    await app.auth.createOwner(username: 'owner', password: 'owner123', displayName: 'Owner');
    await app.auth.login('owner', 'owner123');
    final sup = await app.parties.create(kind: PartyKind.supplier, name: 'Supplier F');
    final cust = await app.parties.create(kind: PartyKind.customer, name: 'Customer F');
    final cam = await app.catalog.create(ProductInput(name: 'Cam F', brand: 'Uniview', purchasePrice: rs(2000), sellingPrice: rs(3000), requiresSerial: true, warrantyMonths: 12));
    await app.purchases.create(supplierId: sup.id, date: clock.now, lines: [PurchaseLineInput(productId: cam.id, qty: q(2), unitCost: rs(2000), serials: ['UV1', 'UV2'])]);
    final sale = await app.sales.complete(app.sales.newDraft().copyWith(customerId: cust.id, items: [SaleItem(productId: cam.id, name: cam.name, qty: q(1), unitPrice: rs(3000), serials: ['UV1'])], paidAtSale: rs(1000)));
    final backups = await app.backup.backupNow();
    await store.close(); // application closed

    // Restart: everything is still there.
    (store, app) = await openApp();
    await app.auth.login('owner', 'owner123');
    expect(app.sales.byId(sale.id)!.number, sale.number);
    expect(app.serials.find('UV1')!.status, SerialStatus.sold);
    expect(app.parties.byId(PartyKind.customer, cust.id)!.balance, rs(2000));
    expect(app.catalog.byId(cam.id)!.stockQty, q(1));

    // More work after the backup, then restore the backup.
    await app.sales.complete(app.sales.newDraft().copyWith(items: [SaleItem(productId: cam.id, name: cam.name, qty: q(1), unitPrice: rs(3000), serials: ['UV2'])], paidAtSale: rs(3000)));
    expect(app.catalog.byId(cam.id)!.stockQty, q(0));
    await app.backup.restore(backups.single.path);
    await store.close();

    (store, app) = await openApp();
    // The restored owner account is opened directly (backups hold no password hashes).
    await app.auth.openLocalSession();
    expect(app.catalog.byId(cam.id)!.stockQty, q(1));
    expect(app.serials.find('UV2')!.status, SerialStatus.inStock);
    expect(app.sales.list(status: DocStatus.completed).single.id, sale.id);
    expect(app.parties.ledgerBalance(PartyKind.customer, cust.id), rs(2000));
    expect(app.parties.payments().length, 1);
    expect(store.count(Boxes.auditLogs), greaterThanOrEqualTo(5));
    expect(app.integrity.check(), isEmpty);
    await store.close();
    await dir.delete(recursive: true);
  });
}
