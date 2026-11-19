// Repeat purchases of the same serial-tracked product: stock that sold out
// is bought again into the SAME product, each purchase keeps its own cost
// and date, every sold serial is costed at its own batch, and serials stay
// unique across all purchases.
import 'package:al_aqsa_cctv/core/errors.dart';
import 'package:al_aqsa_cctv/data/store/data_store.dart';
import 'package:al_aqsa_cctv/domain/models/documents.dart';
import 'package:al_aqsa_cctv/domain/models/operations.dart';
import 'package:al_aqsa_cctv/domain/models/party.dart';
import 'package:al_aqsa_cctv/domain/models/product.dart';
import 'package:al_aqsa_cctv/domain/services/catalog_service.dart';
import 'package:al_aqsa_cctv/domain/services/purchase_service.dart';
import 'package:al_aqsa_cctv/domain/services/report_service.dart';
import 'package:al_aqsa_cctv/domain/services/serial_service.dart';
import 'package:al_aqsa_cctv/domain/services/technician_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() async => env.dispose());

  Future<Sale> sell(Product p, List<String> serials, {Party? customer}) async {
    final d = env.app.sales.newDraft().copyWith(
          customerId: customer?.id,
          customerName: customer?.name ?? '',
          items: [env.app.sales.lineFor(env.reload(p.id), qty: q(serials.length), serials: serials)],
        );
    return env.app.sales.complete(d.copyWith(paidAtSale: d.total));
  }

  Future<Purchase> buy(Party sup, Product p, int cost, List<String> serials, {String invoice = ''}) =>
      env.app.purchases.create(supplierId: sup.id, supplierInvoiceNo: invoice, date: env.clock.now, lines: [PurchaseLineInput(productId: p.id, qty: q(serials.length), unitCost: rs(cost), serials: serials)]);

  test('sold out -> bought again into the SAME product; old serials and history kept', () async {
    final app = env.app;
    final cam = await env.product('Dahua 4MP Dome', serial: true, brand: 'Dahua', price: 6500);
    final supA = await env.supplier('Lahore Distributor');
    final p1 = await buy(supA, cam, 4000, ['A1', 'A2', 'A3'], invoice: 'LD-101');
    await sell(cam, ['A1', 'A2', 'A3']);
    expect(env.reload(cam.id).stockQty, q(0));

    // The guard used by Add Product: the same product is found even at zero stock.
    expect(app.catalog.findDuplicates(ProductInput(name: 'dahua 4mp dome', brand: 'DAHUA', model: cam.model, purchasePrice: rs(1), sellingPrice: rs(1))).single.id, cam.id);

    env.clock.advance(const Duration(days: 10));
    final supB = await env.supplier('Karachi Importer');
    final p2 = await buy(supB, cam, 5000, ['B1', 'B2'], invoice: 'KI-77');

    expect(app.catalog.products().where((p) => p.name == 'Dahua 4MP Dome').length, 1); // no second product
    expect(env.reload(cam.id).stockQty, q(2));
    expect(env.reload(cam.id).purchasePrice, rs(5000)); // latest purchase price shown for new purchases
    expect(app.serials.statusCounts(cam.id), {SerialStatus.sold: 3, SerialStatus.inStock: 2});
    // Each purchase keeps its own supplier, invoice, date and cost.
    expect(app.purchases.byId(p1.id)!.items.single.unitCost, rs(4000));
    expect(app.purchases.byId(p2.id)!.items.single.unitCost, rs(5000));
    expect(app.purchases.byId(p2.id)!.supplierInvoiceNo, 'KI-77');
    expect(app.purchases.byId(p2.id)!.date.isAfter(app.purchases.byId(p1.id)!.date), isTrue);
    final a1 = app.serials.find('A1')!;
    expect(a1.purchaseId, p1.id);
    expect(a1.cost, rs(4000));
    expect(a1.status, SerialStatus.sold);
    expect(a1.history.length >= 2, isTrue); // purchased + sold kept
    final b1 = app.serials.find('B1')!;
    expect(b1.purchaseId, p2.id);
    expect(b1.supplierId, supB.id);
    expect(b1.cost, rs(5000));
    expect(app.integrity.check(), isEmpty);
  });

  test('serial numbers from earlier purchases cannot be bought again', () async {
    final app = env.app;
    final cam = await env.product('Dome', serial: true, brand: 'Dahua');
    final sup = await env.supplier();
    await buy(sup, cam, 4000, ['A1', 'A2']);
    await sell(cam, ['A1']);
    for (final dup in ['A1', 'a2']) {
      Object? err;
      try {
        await buy(sup, cam, 5000, [dup, 'NEW9']);
      } catch (e) {
        err = e;
      }
      expect(err is SerialConflictException, isTrue, reason: '$dup must be refused (sold or in stock)');
    }
    expect(env.reload(cam.id).stockQty, q(1)); // nothing was added
    expect(app.serials.find('NEW9'), isNull);
    // Live check in the serial window flags them before saving.
    final checks = app.serials.checkNew(['A1', 'A2', 'NEW9'], brandKey: env.reload(cam.id).brandKey, productId: cam.id);
    expect(checks[0].issue, SerialIssue.alreadyRegistered);
    expect(checks[0].message.contains('Already recorded for this product'), isTrue);
    expect(checks[1].issue, SerialIssue.alreadyRegistered);
    expect(checks[2].ok, isTrue);
  });

  test('each sold serial is costed at its own batch, not the oldest batch', () async {
    final app = env.app;
    final cam = await env.product('Dome', serial: true, brand: 'Dahua', price: 7000);
    final sup = await env.supplier();
    await buy(sup, cam, 4000, ['A1', 'A2']);
    await buy(sup, cam, 5000, ['B1', 'B2']);
    await buy(sup, cam, 6000, ['C1', 'C2']);

    // Sell the newest, dearest unit first: cost must be 6000 (FIFO would say 4000).
    final s1 = await sell(cam, ['C1']);
    expect(s1.items.single.cogs, rs(6000));
    final s2 = await sell(cam, ['A1', 'B1']);
    expect(s2.items.single.cogs, rs(9000));
    // Remaining stock value = exactly the serials still on the shelf.
    expect(app.inventory.stockValuation(productId: cam.id), rs(4000 + 5000 + 6000)); // A2, B2, C2

    final may = DateRange(env.clock.now.subtract(const Duration(days: 1)), env.clock.now.add(const Duration(days: 1)));
    final f = app.reports.financials(may);
    expect(f.cogs, rs(15000));
    expect(f.grossProfit, rs(3 * 7000 - 15000));
    expect(app.integrity.check(), isEmpty);
  });

  test('cancelled invoice and customer return put each unit back at its own batch cost', () async {
    final app = env.app;
    final cam = await env.product('Dome', serial: true, brand: 'Dahua', price: 7000);
    final sup = await env.supplier();
    await buy(sup, cam, 4000, ['A1']);
    await buy(sup, cam, 6000, ['C1', 'C2']);
    final s = await sell(cam, ['A1', 'C1']); // mixed batches on one line
    expect(s.items.single.cogs, rs(10000));
    await app.sales.cancel(s.id, 'wrong customer');
    // Resell C1 alone: still 6000, not the 5000 average of the cancelled line.
    final again = await sell(cam, ['C1']);
    expect(again.items.single.cogs, rs(6000));
    expect(app.inventory.stockValuation(productId: cam.id), rs(4000 + 6000)); // A1 + C2

    final cust = await env.customer();
    final s3 = await sell(cam, ['A1', 'C2'], customer: cust);
    await app.sales.createReturn(saleId: s3.id, reason: 'not needed', lines: [ReturnLineInput(productId: cam.id, qty: q(1), serials: const ['C2'])], refundMode: RefundMode.accountCredit);
    expect(app.serials.find('C2')!.status, SerialStatus.inStock);
    final s4 = await sell(cam, ['C2']);
    expect(s4.items.single.cogs, rs(6000));
    expect(app.integrity.check(), isEmpty);
  });

  test('technician issue, install and invoice use each serial\'s own batch cost', () async {
    final app = env.app;
    final cam = await env.product('Dome', serial: true, brand: 'Dahua', price: 7000);
    final sup = await env.supplier();
    await buy(sup, cam, 4000, ['A1']);
    await buy(sup, cam, 6000, ['C1']);
    final t = await app.technicians.create(name: 'Waqas', phone: '0333');
    await app.technicians.issue(technicianId: t.id, lines: [IssueLine(productId: cam.id, qty: q(1), serials: const ['C1'])]);
    expect(app.technicians.summary(t.id).holdings.single.cost, rs(6000));
    await app.technicians.issue(technicianId: t.id, lines: [IssueLine(productId: cam.id, qty: q(1), serials: const ['A1'])]);
    // Return A1 unused: it goes back at 4000, and C1 stays with the technician at 6000.
    await app.technicians.returnMaterial(technicianId: t.id, productId: cam.id, qty: q(1), serialNumbers: const ['A1'], type: TechTxnType.returnUnused);
    expect(app.technicians.summary(t.id).holdings.single.cost, rs(6000));
    expect(app.inventory.stockValuation(productId: cam.id), rs(4000));
    final inst = await app.technicians.recordInstalled(technicianId: t.id, productId: cam.id, qty: q(1), serialNumbers: const ['C1']);
    expect(inst.cost, rs(6000));
    expect(app.integrity.check(), isEmpty);
  });

  test('non-serial items keep FIFO batches with their own costs', () async {
    final app = env.app;
    final cable = await env.product('Cable', price: 200);
    final sup = await env.supplier();
    await app.purchases.create(supplierId: sup.id, date: env.clock.now, lines: [PurchaseLineInput(productId: cable.id, qty: q(10), unitCost: rs(100))]);
    await app.purchases.create(supplierId: sup.id, date: env.clock.now, lines: [PurchaseLineInput(productId: cable.id, qty: q(10), unitCost: rs(150))]);
    final d = app.sales.newDraft().copyWith(items: [app.sales.lineFor(env.reload(cable.id), qty: q(12))]);
    final s = await app.sales.complete(d.copyWith(paidAtSale: d.total));
    expect(s.items.single.cogs, rs(10 * 100 + 2 * 150));
    expect(app.inventory.stockValuation(productId: cable.id), rs(8 * 150));
    expect(env.app.ctx.store.values(Boxes.costLayers).length, 2);
  });
  group('Add More Serial Numbers (existing product, no new product record)', () {
    test('after stock reaches zero: purchase batch with its own cost, old serials untouched', () async {
      final app = env.app;
      final cam = await env.product('Hikvision Camera', serial: true, brand: 'Hikvision', price: 6000);
      final sup = await env.supplier();
      await buy(sup, cam, 4000, ['H1', 'H2']);
      await sell(cam, ['H1', 'H2']);
      expect(env.reload(cam.id).stockQty, q(0));
      final productsBefore = app.catalog.products(includeArchived: true).length;
      // The dialog saves a purchase line for the SAME product id.
      await buy(sup, cam, 4800, ['H3', 'H4', 'H5'], invoice: 'INV-9');
      expect(app.catalog.products(includeArchived: true).length, productsBefore);
      expect(env.reload(cam.id).stockQty, q(3));
      expect(app.serials.find('H1')!.status, SerialStatus.sold);
      expect(app.serials.find('H3')!.cost, rs(4800));
      final s = await sell(cam, ['H5']);
      expect(s.items.single.cogs, rs(4800));
      expect(app.integrity.check(), isEmpty);
    });

    test('opening / other stock: stock-in batch at its cost, partial stock, stock = old + added', () async {
      final app = env.app;
      final cam = await env.product('Hikvision Camera', serial: true, brand: 'Hikvision', price: 6000);
      final sup = await env.supplier();
      await buy(sup, cam, 4000, ['H1', 'H2', 'H3']);
      await sell(cam, ['H1']); // partial stock: 2 left
      final n = await app.purchases.addSerialStock(productId: cam.id, serials: const ['K1', 'K2'], unitCost: rs(4500), date: env.clock.now, reason: 'Opening stock');
      expect(n.startsWith('SIN'), isTrue);
      expect(env.reload(cam.id).stockQty, q(4));
      expect(app.serials.statusCounts(cam.id), {SerialStatus.sold: 1, SerialStatus.inStock: 4});
      final k1 = app.serials.find('K1')!;
      expect(k1.supplierId, isNull);
      expect(k1.cost, rs(4500));
      expect(k1.history.single.note.contains(n), isTrue);
      final s = await sell(cam, ['K2', 'H2']);
      expect(s.items.single.cogs, rs(4500 + 4000));
      expect(app.inventory.stockValuation(productId: cam.id), rs(4500 + 4000)); // K1 + H3
      expect(app.integrity.check(), isEmpty);
    });

    test('duplicates refused across the whole database; quantity must match; reason needed', () async {
      final app = env.app;
      final hik = await env.product('Hikvision Camera', serial: true, brand: 'Hikvision');
      final hikNvr = await env.product('Hikvision NVR', serial: true, brand: 'Hikvision');
      final dahua = await env.product('Dahua Camera', serial: true, brand: 'Dahua');
      final sup = await env.supplier();
      await buy(sup, hik, 4000, ['H1']);
      await buy(sup, hikNvr, 9000, ['N1']);
      await buy(sup, dahua, 3000, ['D1']);
      Future<Object?> err(Future<void> Function() f) async {
        try {
          await f();
        } catch (e) {
          return e;
        }
        return null;
      }

      // Same product earlier, other product of the brand, another brand.
      for (final dup in ['H1', 'N1', 'D1']) {
        expect(await err(() => app.purchases.addSerialStock(productId: hik.id, serials: [dup], unitCost: rs(1), date: env.clock.now, reason: 'x')) is SerialConflictException, isTrue, reason: dup);
      }
      expect(await err(() => app.purchases.addSerialStock(productId: hik.id, serials: const ['Z1', 'z1'], unitCost: rs(1), date: env.clock.now, reason: 'x')) is DuplicateException, isTrue);
      expect(await err(() => app.purchases.addSerialStock(productId: hik.id, serials: const ['Z1'], unitCost: rs(1), date: env.clock.now, reason: ' ')) is ValidationException, isTrue);
      final cable = await env.product('Cable');
      expect(await err(() => app.purchases.addSerialStock(productId: cable.id, serials: const ['Z1'], unitCost: rs(1), date: env.clock.now, reason: 'x')) is BusinessException, isTrue);
      // Purchase path: serial count must equal the quantity.
      expect(await err(() => app.purchases.create(supplierId: sup.id, date: env.clock.now, lines: [PurchaseLineInput(productId: hik.id, qty: q(2), unitCost: rs(1), serials: const ['Z1'])])) is ValidationException, isTrue);
      expect(env.reload(hik.id).stockQty, q(1)); // nothing changed
      expect(app.serials.find('Z1'), isNull);
    });
  });
}
