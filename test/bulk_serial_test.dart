import 'package:al_aqsa_cctv/core/errors.dart';
import 'package:al_aqsa_cctv/core/money.dart';
import 'package:al_aqsa_cctv/domain/models/documents.dart';
import 'package:al_aqsa_cctv/domain/models/party.dart';
import 'package:al_aqsa_cctv/domain/models/product.dart';
import 'package:al_aqsa_cctv/domain/services/catalog_service.dart';
import 'package:al_aqsa_cctv/domain/services/purchase_service.dart';
import 'package:al_aqsa_cctv/domain/services/serial_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

List<String> sns(String prefix, int from, int n) => [for (var i = from; i < from + n; i++) '$prefix${i.toString().padLeft(4, '0')}'];

/// The business scenario: 50 identical cameras = ONE product + 50 serials.
void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() async => env.dispose());

  const camInput = ProductInput(
    name: 'Hikvision CCTV Camera',
    brand: 'Hikvision',
    model: 'DS-2CE16D0T',
    description: '2MP bullet, IR 20 m',
    purchasePrice: Money(400000),
    sellingPrice: Money(600000),
    requiresSerial: true,
    warrantyMonths: 12,
  );

  Future<(Product, Party)> receive50() async {
    final sup = await env.supplier();
    final (p, pur) = await env.app.createProductWithStock(
      camInput,
      supplierId: sup.id,
      qty: q(50),
      unitCost: rs(4000),
      serials: sns('HKC', 1, 50),
      supplierInvoiceNo: 'HK-1001',
    );
    expect(pur.items.single.serials.length, 50);
    return (p, sup);
  }

  Future<Sale> sell(Product p, List<String> serials, {Party? customer}) async {
    final app = env.app;
    final d = app.sales.newDraft().copyWith(
      customerId: customer?.id,
      customerName: customer?.name,
      items: [app.sales.lineFor(env.reload(p.id), qty: q(serials.length), serials: serials)],
    );
    return app.sales.complete(d.copyWith(paidAtSale: d.total));
  }

  test('one product with 50 serials: one catalog record, stock 50, 50 units in stock', () async {
    final (p, sup) = await receive50();
    final app = env.app;
    expect(app.catalog.products().length, 1, reason: 'no duplicate products');
    final cam = env.reload(p.id);
    expect(cam.stockQty, q(50));
    expect(app.serials.statusCounts(cam.id), {SerialStatus.inStock: 50});
    final units = app.serials.search(productId: cam.id);
    expect(units.length, 50);
    expect(units.every((u) => u.productId == cam.id && u.supplierId == sup.id && u.purchaseId != null), isTrue);
    expect(units.first.purchaseDate, isNotNull);
    expect(app.purchases.list().single.supplierInvoiceNo, 'HK-1001');
    expect(app.parties.byId(PartyKind.supplier, sup.id)!.balance, rs(200000));
  });

  test('product and stock are saved together or not at all', () async {
    final sup = await env.supplier();
    // 49 serials for 50 units: nothing is saved, not even the product.
    await expectLater(
      env.app.createProductWithStock(camInput, supplierId: sup.id, qty: q(50), unitCost: rs(4000), serials: sns('HKC', 1, 49)),
      throwsA(isA<ValidationException>()),
    );
    expect(env.app.catalog.products(), isEmpty);
    // Repeated serial in the list.
    await expectLater(
      env.app.createProductWithStock(camInput, supplierId: sup.id, qty: q(3), unitCost: rs(4000), serials: const ['A100', 'A101', 'a100']),
      throwsA(isA<DuplicateException>()),
    );
    expect(env.app.catalog.products(), isEmpty);
    expect(env.app.serials.search(), isEmpty);
  });

  test('duplicate serial numbers are rejected; live check explains each entry', () async {
    final (p, sup) = await receive50();
    final app = env.app;
    // Buying a unit whose serial is already registered for the brand needs approval.
    await expectLater(
      app.purchases.create(
        supplierId: sup.id,
        date: env.clock.now,
        lines: [PurchaseLineInput(productId: p.id, qty: q(1), unitCost: rs(4000), serials: const ['HKC0007'])],
      ),
      throwsA(isA<SerialConflictException>()),
    );
    expect(env.reload(p.id).stockQty, q(50));
    final checks = app.serials.checkNew(['HKC9001', 'hkc0007', 'HKC9001', '', 'x', 'BAD SERIAL!', env.reload(p.id).internalCode], brandKey: p.brandKey, productId: p.id);
    expect(checks[0].ok, isTrue);
    expect(checks[1].issue, SerialIssue.alreadyRegistered);
    expect(checks[2].issue, SerialIssue.repeated);
    expect(checks[3].issue, SerialIssue.invalid, reason: 'empty');
    expect(checks[4].issue, SerialIssue.invalid, reason: 'too short');
    expect(checks[5].issue, SerialIssue.invalid, reason: '! is not a serial character');
    expect(checks[6].issue, SerialIssue.productBarcode);
    expect(SerialService.splitEntries('A1\r\nA2, A3;A4\tA5\n\n'), ['A1', 'A2', 'A3', 'A4', 'A5']);
  });

  test('selling one unit: that serial is Sold and stock goes to 49', () async {
    final (p, _) = await receive50();
    final cust = await env.customer();
    final sale = await sell(p, const ['HKC0010'], customer: cust);
    final app = env.app;
    expect(env.reload(p.id).stockQty, q(49));
    final u = app.serials.find('HKC0010')!;
    expect(u.status, SerialStatus.sold);
    expect(u.customerId, cust.id);
    expect(u.saleId, sale.id);
    expect(u.warrantyExpiry, isNotNull);
    expect(app.serials.statusCounts(p.id), {SerialStatus.inStock: 49, SerialStatus.sold: 1});
  });

  test('selling several units updates exactly those serials; unavailable units are refused', () async {
    final (p, _) = await receive50();
    final other = await env.product('Dahua NVR', serial: true, brand: 'Dahua');
    final sup = await env.supplier('Dahua Dist');
    await env.app.purchases.create(
        supplierId: sup.id, date: env.clock.now, lines: [PurchaseLineInput(productId: other.id, qty: q(1), unitCost: rs(9000), serials: const ['DHN0001'])]);
    await sell(p, const ['HKC0001', 'HKC0002', 'HKC0003']);
    final app = env.app;
    expect(env.reload(p.id).stockQty, q(47));
    for (final s in ['HKC0001', 'HKC0002', 'HKC0003']) {
      expect(app.serials.find(s)!.status, SerialStatus.sold);
    }
    expect(app.serials.find('HKC0004')!.status, SerialStatus.inStock);
    // Already sold.
    await expectLater(sell(p, const ['HKC0002']), throwsA(isA<BusinessException>()));
    // Belongs to another product.
    await expectLater(sell(p, const ['DHN0001']), throwsA(isA<BusinessException>()));
    // Same unit twice on one bill.
    await expectLater(sell(p, const ['HKC0005', 'HKC0005']), throwsA(isA<BusinessException>()));
    expect(env.reload(p.id).stockQty, q(47));
    expect(app.serials.find('HKC0005')!.status, SerialStatus.inStock);
  });

  test('buying 20 more reuses the product: stock 69, old serials and history kept', () async {
    final (p, sup) = await receive50();
    final sale = await sell(p, const ['HKC0050']); // 49 left
    final app = env.app;
    final firstPurchase = app.purchases.list().single;
    await app.purchases.create(
      supplierId: sup.id,
      supplierInvoiceNo: 'HK-1002',
      date: env.clock.now.add(const Duration(days: 3)),
      lines: [PurchaseLineInput(productId: p.id, qty: q(20), unitCost: rs(4500), serials: sns('HKC', 51, 20))],
    );
    expect(app.catalog.products().length, 1);
    expect(env.reload(p.id).stockQty, q(69));
    expect(app.serials.search(productId: p.id).length, 70);
    expect(app.serials.statusCounts(p.id), {SerialStatus.inStock: 69, SerialStatus.sold: 1});
    expect(app.serials.find('HKC0001')!.purchaseId, firstPurchase.id, reason: 'old records unchanged');
    expect(app.serials.find('HKC0060')!.cost, rs(4500));
    expect(app.serials.find('HKC0001')!.cost, rs(4000));
    // History: both purchase invoices, the first one unchanged; the earlier sale keeps its cost.
    final purchases = app.purchases.list();
    expect(purchases.length, 2);
    final again = app.purchases.byId(firstPurchase.id)!;
    expect(again.total, rs(200000));
    expect(again.items.single.unitCost, rs(4000));
    expect(app.sales.byId(sale.id)!.items.single.cogs, rs(4000));
    expect(app.parties.byId(PartyKind.supplier, sup.id)!.balance, rs(200000 + 90000));
  });

  test('returns and faulty units keep their identity and do not become sellable stock', () async {
    final (p, _) = await receive50();
    final cust = await env.customer();
    final sale = await sell(p, const ['HKC0001', 'HKC0002'], customer: cust);
    final app = env.app;
    expect(env.reload(p.id).stockQty, q(48));
    // Customer returns one faulty and one good camera.
    await app.sales.createReturn(saleId: sale.id, reason: 'Customer return', lines: [
      ReturnLineInput(productId: p.id, qty: q(1), serials: const ['HKC0001'], condition: 'damaged'),
      ReturnLineInput(productId: p.id, qty: q(1), serials: const ['HKC0002'], condition: 'resellable'),
    ]);
    final faulty = app.serials.find('HKC0001')!;
    final good = app.serials.find('HKC0002')!;
    expect(faulty.key, SerialRecord.keyFor(p.brandKey, 'HKC0001'), reason: 'same identity');
    expect(faulty.status == SerialStatus.inStock, isFalse, reason: 'faulty is not available');
    expect(faulty.history.length >= 3, isTrue, reason: 'purchase, sale and return are all in its history');
    expect(good.status, SerialStatus.inStock);
    expect(env.reload(p.id).stockQty, q(49), reason: 'only the good unit is sellable again');
    expect(app.serials.inStockFor(p.id).any((u) => u.serial == 'HKC0001'), isFalse);
    // Return a unit to the supplier.
    final pur = app.purchases.list().single;
    await app.purchases.createReturn(purchaseId: pur.id, reason: 'Dead on arrival', lines: [
      ReturnLineInput(productId: p.id, qty: q(1), serials: const ['HKC0030']),
    ]);
    expect(app.serials.find('HKC0030')!.status, SerialStatus.returnedToSupplier);
    expect(env.reload(p.id).stockQty, q(48));
  });

  test('backup and restore keep every serial record', () async {
    final (p, _) = await receive50();
    await sell(p, const ['HKC0003']);
    final app = env.app;
    final before = {for (final u in app.serials.search()) u.key: u.toJson()};
    final files = await app.backup.backupNow();
    // Change data after the backup, then restore.
    await sell(p, const ['HKC0004']);
    await app.backup.restore(files.last.path);
    await app.auth.openLocalSession();
    final after = {for (final u in app.serials.search()) u.key: u.toJson()};
    expect(after.length, 50);
    expect(after, before);
    expect(env.reload(p.id).stockQty, q(49));
    expect(app.catalog.products().length, 1);
  });
}
