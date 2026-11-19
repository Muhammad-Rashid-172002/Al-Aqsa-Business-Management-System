// Permanent delete: erased from the current (Hive) database for good, with
// relationship checks, file handling, audit scrubbing, restart, and the
// separate, verified purge from backup files.
import 'dart:convert';
import 'dart:io';

import 'package:al_aqsa_cctv/core/errors.dart';
import 'package:al_aqsa_cctv/core/money.dart';
import 'package:al_aqsa_cctv/core/password_hasher.dart';
import 'package:al_aqsa_cctv/data/migrations.dart';
import 'package:al_aqsa_cctv/data/store/data_store.dart';
import 'package:al_aqsa_cctv/data/store/hive_store.dart';
import 'package:al_aqsa_cctv/domain/models/documents.dart';
import 'package:al_aqsa_cctv/domain/models/party.dart';
import 'package:al_aqsa_cctv/domain/services/app_services.dart';
import 'package:al_aqsa_cctv/domain/services/catalog_service.dart';
import 'package:al_aqsa_cctv/domain/services/permanent_delete_service.dart';
import 'package:al_aqsa_cctv/domain/services/purchase_service.dart';
import 'package:al_aqsa_cctv/domain/services/report_service.dart';
import 'package:al_aqsa_cctv/domain/services/technician_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'helpers.dart';

final _png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

/// A computer with a real Hive database (so "after restart" is real).
class _Pc {
  final Directory root;
  final TestClock clock = TestClock()..now = DateTime(2026, 3, 10, 10);
  late HiveStore store;
  late AppServices app;
  _Pc(this.root);
  String get backupDir => p.join(root.path, 'D_AL-AQSA_Backups');
  String get media => p.join(root.path, 'media');

  Future<void> open() async {
    store = await HiveStore.open(p.join(root.path, 'data'));
    await Migrator.run(store);
    app = AppServices(store,
        localBackupDir: p.join(root.path, 'backups'), mediaDir: media, defaultBackupDir: backupDir, clock: clock.call, hasher: const PasswordHasher(iterations: 10));
    if (app.auth.findByUsername('owner') == null) {
      await app.auth.createOwner(username: 'owner', password: 'secret123', displayName: 'Owner');
    }
    await app.auth.openLocalSession();
  }

  Future<void> restart() async {
    await store.close();
    await open();
  }

  String file(String name) {
    final f = File(p.join(media, name))..createSync(recursive: true);
    f.writeAsBytesSync(_png);
    return f.path;
  }
}

/// No audit entry, nor any other record, still holds [text].
void _noTrace(AppServices app, String text) {
  for (final box in Boxes.all) {
    for (final v in app.ctx.store.values(box)) {
      expect(jsonEncode(v).contains(text), isFalse, reason: '"$text" still found in $box');
    }
  }
}

void main() {
  late _Pc pc;
  setUp(() async {
    pc = _Pc(await Directory.systemTemp.createTemp('aqsa_purge'));
    await pc.open();
  });
  tearDown(() async {
    await pc.store.close();
    await pc.root.delete(recursive: true);
  });

  Future<Object?> err(Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      return e;
    }
    return null;
  }

  test('customer without history: erased, name scrubbed from audit, still gone after restart', () async {
    final app = pc.app;
    final keep = await app.parties.create(kind: PartyKind.customer, name: 'Keep Me Traders');
    final c = await app.parties.create(kind: PartyKind.customer, name: 'Zubair Secret Name', phone: '03001234567');
    final chk = app.erase.check(DeletableKind.customer, c.id);
    expect(chk.allowed, isTrue);
    expect(chk.name, 'Zubair Secret Name');
    final r = await app.erase.deletePermanently(DeletableKind.customer, c.id);
    expect(r.auditEntriesScrubbed, 1);
    expect(app.parties.byId(PartyKind.customer, c.id), isNull);
    expect(app.parties.list(PartyKind.customer, includeInactive: true).map((x) => x.id), [keep.id]);
    _noTrace(app, 'Zubair Secret Name');
    _noTrace(app, '03001234567');
    final log = app.ctx.store.values(Boxes.auditLogs).firstWhere((a) => a['action'] == 'permanent_delete');
    expect(log['entityId'], c.id);
    expect((log['details'] as String).contains('Zubair'), isFalse);

    await pc.restart();
    expect(pc.app.parties.byId(PartyKind.customer, c.id), isNull);
    expect(pc.app.parties.byId(PartyKind.customer, keep.id)!.name, 'Keep Me Traders');
    _noTrace(pc.app, 'Zubair Secret Name');
    expect(pc.app.integrity.check(), isEmpty);
  });

  test('DEMO customer with invoices, payments, ledger and balance: everything erased; totals recalculated; stock unchanged', () async {
    final app = pc.app;
    final march = DateRange(DateTime(2026, 3), DateTime(2026, 3, 31, 23));
    final cam = await app.catalog.create(ProductInput(name: 'Dome Camera', brand: 'Hik', purchasePrice: rs(4000), sellingPrice: rs(6000), requiresSerial: true));
    final cable = await app.catalog.create(ProductInput(name: 'Cable', purchasePrice: rs(100), sellingPrice: rs(200)));
    final sup = await app.parties.create(kind: PartyKind.supplier, name: 'Supplier A');
    await app.purchases.create(supplierId: sup.id, date: pc.clock.now, lines: [
      PurchaseLineInput(productId: cam.id, qty: q(5), unitCost: rs(4000), serials: const ['S1', 'S2', 'S3', 'S4', 'S5']),
      PurchaseLineInput(productId: cable.id, qty: q(50), unitCost: rs(100)),
    ]);
    // Another customer who must not be touched.
    final other = await app.parties.create(kind: PartyKind.customer, name: 'Other Customer');
    final dO = app.sales.newDraft().copyWith(customerId: other.id, customerName: other.name, items: [app.sales.lineFor(app.catalog.byId(cam.id)!, serials: const ['S5'])]);
    final otherSale = await app.sales.complete(dO.copyWith(paidAtSale: rs(2000)));

    final before = app.reports.financials(march);
    final otherBalance = app.parties.byId(PartyKind.customer, other.id)!.balance;

    // DEMO customer: opening balance, 3 invoices, 3 payments, a quotation, a repair.
    final demo = await app.parties.create(kind: PartyKind.customer, name: 'DEMO Delete Customer', phone: '03009998887', openingBalance: rs(1500));
    Future<Sale> sell(List<SaleItem> items, Money paid) async {
      final d = app.sales.newDraft().copyWith(customerId: demo.id, customerName: demo.name, items: items);
      return app.sales.complete(d.copyWith(paidAtSale: paid));
    }

    final inv1 = await sell([app.sales.lineFor(app.catalog.byId(cam.id)!, serials: const ['S1'])], rs(2000));
    final inv2 = await sell([app.sales.lineFor(app.catalog.byId(cam.id)!, qty: q(2), serials: const ['S2', 'S3'])], rs(5000));
    final inv3 = await sell([app.sales.lineFor(app.catalog.byId(cable.id)!, qty: q(10))], rs(0));
    await app.parties.addPayment(kind: PartyKind.customer, partyId: demo.id, amount: rs(3000), method: PaymentMethod.cash);
    await app.parties.addPayment(kind: PartyKind.customer, partyId: demo.id, amount: rs(1000), method: PaymentMethod.bankTransfer);
    await app.quotations.save(app.quotations.newDraft(customerId: demo.id, customerName: demo.name).copyWith(items: [QuotationItem(productId: cable.id, name: 'Cable', qty: q(1), unitPrice: rs(200))]));
    await app.repairs.receive(customerId: demo.id, customerName: demo.name, productName: 'DVR', reportedIssue: 'No power');
    final demoBalance = app.parties.byId(PartyKind.customer, demo.id)!.balance;
    expect(demoBalance, rs(1500 + 6000 + 12000 + 2000 - 2000 - 5000 - 3000 - 1000)); // 10,500 outstanding
    final stockCam = app.catalog.byId(cam.id)!.stockQty;
    final stockCable = app.catalog.byId(cable.id)!.stockQty;

    final chk = app.erase.check(DeletableKind.customer, demo.id);
    expect(chk.allowed, isTrue);
    expect(chk.erase[Boxes.customers], 1);
    expect(chk.erase[Boxes.sales], 3);
    expect(chk.erase[Boxes.payments], 4); // 2 at sale (inv1, inv2) + 2 on account
    expect(chk.erase[Boxes.ledger]! >= 8, isTrue); // opening + 3 invoices + 4 payments
    expect(chk.erase[Boxes.quotations], 1);
    expect(chk.erase[Boxes.repairs], 1);
    expect(chk.unlink[Boxes.serials], 3); // S1-S3 stay sold, without the customer
    expect(chk.effects.first.contains('3 completed invoice(s)'), isTrue);

    final r = await app.erase.deletePermanently(DeletableKind.customer, demo.id);
    expect(r.recordsRemoved, chk.eraseTotal);

    // Nothing of the customer is left.
    for (final x in [demo.id, inv1.id, inv2.id, inv3.id]) {
      expect(app.erase.references({x}), isEmpty);
    }
    expect(app.sales.list().map((s) => s.id), [otherSale.id]);
    expect(app.parties.payments().where((p) => p.partyId == demo.id), isEmpty);
    expect(app.quotations.list(), isEmpty);
    expect(app.repairs.list(), isEmpty);
    _noTrace(app, 'DEMO Delete Customer');
    _noTrace(app, '03009998887');

    // Totals recalculated = exactly as before the demo customer existed.
    final after = app.reports.financials(march);
    expect(after.netSales, before.netSales);
    expect(after.grossProfit, before.grossProfit);
    expect(after.cashReceived, before.cashReceived);
    expect(after.customerOutstanding, before.customerOutstanding);
    expect(app.parties.byId(PartyKind.customer, other.id)!.balance, otherBalance);
    expect(app.sales.list(customerId: demo.id), isEmpty);
    // Stock stays sold (owner's choice): quantities unchanged; serials Sold, no customer.
    expect(app.catalog.byId(cam.id)!.stockQty, stockCam);
    expect(app.catalog.byId(cable.id)!.stockQty, stockCable);
    final s1 = app.serials.find('S1')!;
    expect(s1.status.name, 'sold');
    expect(s1.customerId, isNull);
    expect(s1.saleId, isNull);
    expect(app.serials.find('S5')!.customerId, other.id); // other customer's unit untouched
    expect(app.integrity.check(), isEmpty);

    // Survives a restart.
    await pc.restart();
    expect(pc.app.parties.byId(PartyKind.customer, demo.id), isNull);
    expect(pc.app.sales.list().length, 1);
    expect(pc.app.reports.financials(march).netSales, before.netSales);
    _noTrace(pc.app, 'DEMO Delete Customer');
    expect(pc.app.integrity.check(), isEmpty);
  });

  test('supplier cascade: purchases, payments, ledger erased; stock and per-batch serial cost kept', () async {
    final app = pc.app;
    final cam = await app.catalog.create(ProductInput(name: 'Dome', brand: 'Hik', purchasePrice: rs(4000), sellingPrice: rs(7000), requiresSerial: true));
    final keepSup = await app.parties.create(kind: PartyKind.supplier, name: 'Kept Supplier');
    final sup = await app.parties.create(kind: PartyKind.supplier, name: 'DEMO Delete Supplier');
    await app.purchases.create(supplierId: sup.id, date: pc.clock.now, paid: rs(1000), lines: [PurchaseLineInput(productId: cam.id, qty: q(2), unitCost: rs(4000), serials: const ['A1', 'A2'])]);
    await app.purchases.create(supplierId: sup.id, date: pc.clock.now, lines: [PurchaseLineInput(productId: cam.id, qty: q(2), unitCost: rs(6000), serials: const ['B1', 'B2'])]);
    await app.purchases.create(supplierId: keepSup.id, date: pc.clock.now, lines: [PurchaseLineInput(productId: cam.id, qty: q(1), unitCost: rs(5000), serials: const ['K1'])]);
    await app.parties.addPayment(kind: PartyKind.supplier, partyId: sup.id, amount: rs(2000), method: PaymentMethod.cash);
    final stock = app.catalog.byId(cam.id)!.stockQty;
    final value = app.inventory.stockValuation(productId: cam.id);

    final chk = app.erase.check(DeletableKind.supplier, sup.id);
    expect(chk.allowed, isTrue);
    expect(chk.erase[Boxes.purchases], 2);
    expect(chk.erase[Boxes.payments], 2);
    await app.erase.deletePermanently(DeletableKind.supplier, sup.id);
    _noTrace(app, 'DEMO Delete Supplier');
    expect(app.purchases.list().length, 1);
    expect(app.catalog.byId(cam.id)!.stockQty, stock);
    expect(app.inventory.stockValuation(productId: cam.id), value);
    expect(app.serials.find('B1')!.supplierId, isNull);
    expect(app.serials.find('K1')!.supplierId, keepSup.id);
    // Selling B1 still costs its own batch (6000), not 4000.
    final d = app.sales.newDraft().copyWith(items: [app.sales.lineFor(app.catalog.byId(cam.id)!, serials: const ['B1'])]);
    final s = await app.sales.complete(d.copyWith(paidAtSale: d.total));
    expect(s.items.single.cogs, rs(6000));
    expect(app.integrity.check(), isEmpty);
  });

  test('product with transactions is protected; product with only its own stock-in is erased with its serials', () async {
    final app = pc.app;
    final cam = await app.catalog.create(ProductInput(name: 'Camera', purchasePrice: rs(4000), sellingPrice: rs(6000)));
    final sup = await app.parties.create(kind: PartyKind.supplier, name: 'Supplier A');
    await app.purchases.create(supplierId: sup.id, date: pc.clock.now, lines: [PurchaseLineInput(productId: cam.id, qty: q(3), unitCost: rs(4000))]);
    final c = app.erase.check(DeletableKind.product, cam.id);
    expect(c.allowed, isFalse);
    expect(c.blockers.single.contains('purchases'), isTrue);
    expect(await err(() => app.erase.deletePermanently(DeletableKind.product, cam.id)) is BusinessException, isTrue);

    final nvr = await app.catalog.create(ProductInput(name: 'Old NVR', brand: 'Dahua', purchasePrice: rs(9000), sellingPrice: rs(12000), requiresSerial: true));
    await app.purchases.addSerialStock(productId: nvr.id, serials: const ['N1', 'N2'], unitCost: rs(9000), date: pc.clock.now, reason: 'Opening stock');
    final valueBefore = app.inventory.stockValuation();
    final chk = app.erase.check(DeletableKind.product, nvr.id);
    expect(chk.allowed, isTrue);
    expect(chk.erase[Boxes.serials], 2);
    expect(chk.erase[Boxes.costLayers], 1);
    await app.erase.deletePermanently(DeletableKind.product, nvr.id);
    expect(app.serials.find('N1'), isNull);
    expect(app.catalog.lookup('N1'), isNull);
    expect(app.inventory.stockValuation(), valueBefore - rs(18000));
    expect(app.integrity.check(), isEmpty);
  });

  test('product: barcode index and its own image erased; a shared image is kept', () async {
    final app = pc.app;
    final img = pc.file('products/a.png');
    final shared = pc.file('products/shared.png');
    final a = await app.catalog.create(ProductInput(name: 'Spare Bracket', purchasePrice: rs(1), sellingPrice: rs(2), companyBarcodes: const ['BR-555'], imagePath: img));
    final b = await app.catalog.create(ProductInput(name: 'Mount A', purchasePrice: rs(1), sellingPrice: rs(2), imagePath: shared));
    final c2 = await app.catalog.create(ProductInput(name: 'Mount B', purchasePrice: rs(1), sellingPrice: rs(2), imagePath: shared));
    expect(app.catalog.lookup('BR-555')?.product.id, a.id);
    final r = await app.erase.deletePermanently(DeletableKind.product, a.id);
    expect(r.recordsRemoved, 3); // product + 2 index rows (internal code AQ…, company barcode)
    expect(r.filesDeleted, [img]);
    expect(File(img).existsSync(), isFalse);
    expect(app.catalog.lookup('BR-555'), isNull);
    expect(app.catalog.search('bracket', includeArchived: true), isEmpty);

    final r2 = await app.erase.deletePermanently(DeletableKind.product, b.id);
    expect(r2.filesKept, [shared]);
    expect(File(shared).existsSync(), isTrue); // Mount B still uses it
    expect(app.catalog.byId(c2.id), isNotNull);
    expect(app.integrity.check(), isEmpty);
  });

  test('category: erased; its products stay, uncategorised; empty category erased', () async {
    final app = pc.app;
    final used = await app.catalog.saveCategory('Cameras');
    final empty = await app.catalog.saveCategory('Old category');
    final cam = await app.catalog.create(ProductInput(name: 'Cam', categoryId: used.id, purchasePrice: rs(1), sellingPrice: rs(2)));
    final chk = app.erase.check(DeletableKind.category, used.id);
    expect(chk.allowed, isTrue);
    expect(chk.unlink[Boxes.products], 1);
    expect(chk.effects.single.contains('1 product(s) in it stay'), isTrue);
    await app.erase.deletePermanently(DeletableKind.category, used.id);
    expect(app.catalog.byId(cam.id)!.categoryId, isNull);
    await app.erase.deletePermanently(DeletableKind.category, empty.id);
    expect(app.catalog.categories(), isEmpty);
    expect(app.catalog.products().length, 1);
  });

  test('expense: erased with its receipt; Profit & Loss recalculates', () async {
    final app = pc.app;
    final rec = pc.file('receipts/r1.png');
    final rent = await app.expenses.create(category: 'Shop rent', title: 'March rent', amount: rs(30000), date: DateTime(2026, 3, 1), receiptPath: rec);
    await app.expenses.create(category: 'Electricity bill', title: 'Bill', amount: rs(5000), date: DateTime(2026, 3, 2));
    final march = DateRange(DateTime(2026, 3), DateTime(2026, 3, 31, 23));
    expect(app.reports.financials(march).expenses, rs(35000));
    final c = app.erase.check(DeletableKind.expense, rent.id);
    expect(c.effects.single.contains('Rs 30,000.00'), isTrue);
    await app.erase.deletePermanently(DeletableKind.expense, rent.id);
    expect(app.reports.financials(march).expenses, rs(5000));
    expect(app.expenses.list(includeDeleted: true).length, 1);
    expect(File(rec).existsSync(), isFalse);
    _noTrace(app, 'March rent');
  });

  test('technician: unused -> erased with its login and login history; with history -> protected', () async {
    final app = pc.app;
    final idle = await app.technicians.create(name: 'Temp Helper', phone: '0300', username: 'helper', password: 'helper123');
    await err(() => app.auth.login('helper', 'wrong-pass')); // a failed login leaves a history row
    expect(app.ctx.store.values(Boxes.loginHistory).any((e) => e['username'] == 'helper'), isTrue);
    await app.auth.openLocalSession();
    final r = await app.erase.deletePermanently(DeletableKind.technician, idle.id);
    expect(r.recordsRemoved >= 3, isTrue); // employee + login + login history
    expect(app.auth.findByUsername('helper'), isNull);
    expect(app.ctx.store.values(Boxes.loginHistory).any((e) => e['username'] == 'helper'), isFalse);
    _noTrace(app, 'Temp Helper');

    final cable = await app.catalog.create(ProductInput(name: 'Cable', purchasePrice: rs(1), sellingPrice: rs(2)));
    final sup = await app.parties.create(kind: PartyKind.supplier, name: 'S');
    await app.purchases.create(supplierId: sup.id, date: pc.clock.now, lines: [PurchaseLineInput(productId: cable.id, qty: q(5), unitCost: rs(1))]);
    final t = await app.technicians.create(name: 'Waqas', phone: '0333');
    await app.technicians.issue(technicianId: t.id, lines: [IssueLine(productId: cable.id, qty: q(1))]);
    expect(app.erase.check(DeletableKind.technician, t.id).allowed, isFalse);
  });

  test('quotation and draft invoice erased; converted quotation and completed invoice protected; double run refused', () async {
    final app = pc.app;
    final p0 = await app.catalog.create(ProductInput(name: 'NVR', purchasePrice: rs(1000), sellingPrice: rs(1500)));
    final sup = await app.parties.create(kind: PartyKind.supplier, name: 'S');
    await app.purchases.create(supplierId: sup.id, date: pc.clock.now, lines: [PurchaseLineInput(productId: p0.id, qty: q(5), unitCost: rs(1000))]);
    final qt = await app.quotations.save(app.quotations.newDraft(customerName: 'Hotel').copyWith(items: [QuotationItem(productId: p0.id, name: p0.name, qty: q(1), unitPrice: rs(1500))]));
    final draft = await app.sales.saveDraft(app.sales.newDraft().copyWith(items: [app.sales.lineFor(app.catalog.byId(p0.id)!)]));
    // Both at once: the second is refused, never run twice.
    final results = await Future.wait([
      err(() => app.erase.deletePermanently(DeletableKind.quotation, qt.id)),
      err(() => app.erase.deletePermanently(DeletableKind.quotation, qt.id)),
    ]);
    expect(results.where((e) => e == null).length, 1);
    expect(results.whereType<BusinessException>().length, 1);
    expect(app.quotations.byId(qt.id), isNull);
    await app.erase.deletePermanently(DeletableKind.draftInvoice, draft.id);
    expect(app.sales.byId(draft.id), isNull);
    final d = app.sales.newDraft().copyWith(items: [app.sales.lineFor(app.catalog.byId(p0.id)!)]);
    final sale = await app.sales.complete(d.copyWith(paidAtSale: d.total));
    expect(app.erase.check(DeletableKind.draftInvoice, sale.id).allowed, isFalse);
    expect(app.integrity.check(), isEmpty);
  });

  test('backups: untouched by a normal permanent delete; purge rewrites, verifies, and blocks stale restores', () async {
    final app = pc.app;
    final img = pc.file('products/gone.png');
    final keep = await app.parties.create(kind: PartyKind.customer, name: 'Keep Me Traders');
    final gone = await app.catalog.create(ProductInput(name: 'Discontinued Widget', purchasePrice: rs(1), sellingPrice: rs(2), imagePath: img));
    final files = await app.backup.backupNow(); // one in "D:", one local copy
    expect(files.length, 2);
    final stale = File(p.join(pc.root.path, 'usb_copy.zip'));
    files.first.copySync(stale.path); // a copy the app cannot see (USB)
    final before = {for (final f in files) f.path: f.readAsBytesSync()};

    final chk = app.erase.check(DeletableKind.product, gone.id);
    final spec = app.erase.purgeSpecFor(chk);
    await app.erase.deletePermanently(DeletableKind.product, gone.id);
    // Backups were NOT modified by the delete itself.
    for (final f in files) {
      expect(f.readAsBytesSync(), before[f.path]);
    }
    final scan = await app.backup.findRecord(spec);
    expect(scan.containing.length, 2);
    expect(scan.unreadable, isEmpty);

    expect(await err(() => app.backup.purgeRecord(spec, confirmation: 'yes')) is ValidationException, isTrue);
    final report = await app.backup.purgeRecord(spec, confirmation: 'PURGE');
    expect(report.rewritten, 2);
    expect(report.complete, isTrue);
    expect((await app.backup.findRecord(spec)).containing, isEmpty);
    for (final f in files) {
      final (m, data) = await app.backup.validate(f.path); // still a valid, checked backup
      expect(data[Boxes.products]!.containsKey(gone.id), isFalse);
      expect(data[Boxes.customers]!.containsKey(keep.id), isTrue); // unrelated data kept
      expect(m.fileCount, 0); // the purged product's image is gone from the backup
      expect(utf8.decode(f.readAsBytesSync(), allowMalformed: true).contains('Discontinued Widget'), isFalse);
    }
    final purgeLog = app.ctx.store.values(Boxes.auditLogs).firstWhere((a) => a['action'] == 'backup_purge');
    expect((purgeLog['details'] as String).contains('2 backup file(s) rewritten'), isTrue);
    _noTrace(app, 'Discontinued Widget');

    // Restoring the stale USB copy does not bring the purged record back.
    await app.backup.restore(stale.path);
    await pc.app.auth.openLocalSession();
    expect(pc.app.catalog.byId(gone.id), isNull);
    expect(pc.app.parties.byId(PartyKind.customer, keep.id), isNotNull);
    _noTrace(pc.app, 'Discontinued Widget');
    await pc.restart();
    expect(pc.app.catalog.byId(gone.id), isNull);
    expect(pc.app.backup.tombstones().length, 1);
  });

  test('without a purge, an older backup can still restore the record (recovery copy kept)', () async {
    final app = pc.app;
    final c = await app.parties.create(kind: PartyKind.customer, name: 'Recoverable');
    final f = (await app.backup.backupNow()).first;
    await app.erase.deletePermanently(DeletableKind.customer, c.id);
    expect(app.parties.byId(PartyKind.customer, c.id), isNull);
    await app.backup.restore(f.path);
    await pc.app.auth.openLocalSession();
    expect(pc.app.parties.byId(PartyKind.customer, c.id)!.name, 'Recoverable');
  });

  test('customer cascade + backup purge: invoices and payments leave every backup; stale copy cannot restore them', () async {
    final app = pc.app;
    final cable = await app.catalog.create(ProductInput(name: 'Cable', purchasePrice: rs(100), sellingPrice: rs(200)));
    final sup = await app.parties.create(kind: PartyKind.supplier, name: 'S');
    await app.purchases.create(supplierId: sup.id, date: pc.clock.now, lines: [PurchaseLineInput(productId: cable.id, qty: q(20), unitCost: rs(100))]);
    final demo = await app.parties.create(kind: PartyKind.customer, name: 'DEMO Backup Customer');
    final d = app.sales.newDraft().copyWith(customerId: demo.id, customerName: demo.name, items: [app.sales.lineFor(app.catalog.byId(cable.id)!, qty: q(4))]);
    final inv = await app.sales.complete(d.copyWith(paidAtSale: rs(300)));
    await app.parties.addPayment(kind: PartyKind.customer, partyId: demo.id, amount: rs(200), method: PaymentMethod.cash);
    final files = await app.backup.backupNow();
    final stale = File(p.join(pc.root.path, 'usb_copy.zip'));
    files.first.copySync(stale.path);

    final chk = app.erase.check(DeletableKind.customer, demo.id);
    await app.erase.deletePermanently(DeletableKind.customer, demo.id);
    expect((await app.backup.findRecord(chk.spec)).containing.length, 2); // backups untouched so far
    final report = await app.backup.purgeRecord(chk.spec, confirmation: 'PURGE');
    expect(report.rewritten, 2);
    expect(report.complete, isTrue);
    for (final f in files) {
      final (_, data) = await app.backup.validate(f.path);
      expect(data[Boxes.sales]!.containsKey(inv.id), isFalse);
      expect(data[Boxes.payments]!.values.any((x) => x['partyId'] == demo.id), isFalse);
      expect(data[Boxes.ledger]!.values.any((x) => x['partyId'] == demo.id), isFalse);
      // No dangling link inside the backup (the audit log keeps only the bare id, no details).
      expect(jsonEncode({...data}..remove(Boxes.auditLogs)).contains(demo.id), isFalse);
      expect(jsonEncode(data).contains('DEMO Backup Customer'), isFalse);
    }
    await app.backup.restore(stale.path);
    await pc.app.auth.openLocalSession();
    expect(pc.app.parties.byId(PartyKind.customer, demo.id), isNull);
    expect(pc.app.sales.byId(inv.id), isNull);
    expect(pc.app.erase.references({demo.id, inv.id}), isEmpty);
    _noTrace(pc.app, 'DEMO Backup Customer');
    expect(pc.app.integrity.check(), isEmpty);
  });
}
