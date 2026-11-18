import 'package:al_aqsa_cctv/core/errors.dart';
import 'package:al_aqsa_cctv/data/migrations.dart';
import 'package:al_aqsa_cctv/core/money.dart';
import 'package:al_aqsa_cctv/data/store/data_store.dart';
import 'package:al_aqsa_cctv/data/store/memory_store.dart';
import 'package:al_aqsa_cctv/domain/models/documents.dart';
import 'package:al_aqsa_cctv/domain/models/json_utils.dart';
import 'package:al_aqsa_cctv/domain/models/operations.dart';
import 'package:al_aqsa_cctv/domain/models/party.dart';
import 'package:al_aqsa_cctv/domain/models/product.dart';
import 'package:al_aqsa_cctv/domain/models/user.dart';
import 'package:al_aqsa_cctv/domain/services/purchase_service.dart';
import 'package:al_aqsa_cctv/domain/services/serial_service.dart';
import 'package:al_aqsa_cctv/domain/services/technician_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() async => env.dispose());

  group('1. Decimal quantities', () {
    test('cable can be bought, sold and issued in fractions with exact money', () async {
      final app = env.app;
      final s = await env.supplier();
      final cable = await env.product('CCTV Cable (per metre)', cost: 40, price: 70, decimal: true);
      await app.purchases.create(supplierId: s.id, date: env.clock.now, lines: [PurchaseLineInput(productId: cable.id, qty: Qty.parse('305'), unitCost: rs(40))]);
      final sale = await app.sales.complete(app.sales.newDraft().copyWith(
            items: [SaleItem(productId: cable.id, name: cable.name, qty: Qty.parse('1.5'), unitPrice: rs(70))],
            paidAtSale: rs(105),
          ));
      expect(sale.total, rs(105));
      expect(sale.cogs, rs(60));
      final t = await app.technicians.create(name: 'Asif');
      await app.technicians.issue(technicianId: t.id, lines: [IssueLine(productId: cable.id, qty: Qty.parse('2.75'))]);
      await app.technicians.recordInstalled(technicianId: t.id, productId: cable.id, qty: Qty.parse('2.25'), jobRef: 'House 12');
      await app.technicians.returnMaterial(technicianId: t.id, productId: cable.id, qty: Qty.parse('0.5'), type: TechTxnType.returnUnused);
      final p = env.reload(cable.id);
      expect(p.stockQty, Qty.parse('301.25'));
      expect(p.issuedQty, q(0));
      expect(app.inventory.stockValuation(productId: cable.id), rs(12050)); // 301.25 x 40
      expect(app.integrity.check(), isEmpty);
    });

    test('whole-unit products and serial devices reject decimals', () async {
      final s = await env.supplier();
      final dvr = await env.product('DVR 4CH');
      await expectLater(
          () => env.app.purchases.create(supplierId: s.id, date: env.clock.now, lines: [PurchaseLineInput(productId: dvr.id, qty: Qty.parse('1.5'), unitCost: rs(1))]),
          throwsA(isA<ValidationException>()));
      expect(Qty.parse('2.75').format(), '2.75');
      expect(Qty.parse('3.000').format(), '3');
      expect(Qty.tryParse('1.2345'), isNull);
      expect(rs(70).timesQty(Qty.parse('0.333')), Money(2331)); // 23.31
    });
  });

  group('2. Serial identity = brand + serial', () {
    Future<(Party, Product, Product)> twoBrands() async {
      final s = await env.supplier();
      final hik = await env.product('Hik Dome', serial: true, brand: 'Hikvision');
      final dah = await env.product('Dahua Dome', serial: true, brand: 'Dahua');
      await env.app.purchases.create(supplierId: s.id, date: env.clock.now, lines: [PurchaseLineInput(productId: hik.id, qty: q(1), unitCost: rs(3000), serials: ['ABC123'])]);
      return (s, hik, dah);
    }

    test('same serial under another brand needs owner approval, then both units are tracked', () async {
      final (s, hik, dah) = await twoBrands();
      final line = PurchaseLineInput(productId: dah.id, qty: q(1), unitCost: rs(2800), serials: ['abc123']);
      expect(env.app.purchases.previewConflicts([line]).single.kind, SerialConflictKind.otherBrand);
      await expectLater(() => env.app.purchases.create(supplierId: s.id, date: env.clock.now, lines: [line]), throwsA(isA<SerialConflictException>()));
      await env.app.purchases.create(supplierId: s.id, date: env.clock.now, lines: [line], approvedSerialConflicts: {'ABC123'});
      final all = env.app.serials.findAll('ABC123');
      expect(all.map((r) => r.key).toSet(), {'HIKVISION|ABC123', 'DAHUA|ABC123'});
      expect(all.firstWhere((r) => r.brandKey == 'DAHUA').duplicateApprovedBy, isNotNull);
      // Selling resolves by product, so the right physical unit is used.
      await env.app.sales.complete(env.app.sales.newDraft().copyWith(
            items: [SaleItem(productId: dah.id, name: dah.name, qty: q(1), unitPrice: rs(4000), serials: ['ABC123'])],
            paidAtSale: rs(4000),
          ));
      expect(env.app.serials.byKey('DAHUA|ABC123')!.status, SerialStatus.sold);
      expect(env.app.serials.byKey('HIKVISION|ABC123')!.status, SerialStatus.inStock);
      expect(env.app.serials.duplicates().length, 1);
      expect(env.app.integrity.check(), isEmpty);
    });

    test('same brand duplicate is blocked; owner can approve a genuine manufacturer duplicate', () async {
      final (s, hik, _) = await twoBrands();
      final line = PurchaseLineInput(productId: hik.id, qty: q(1), unitCost: rs(3000), serials: ['ABC123']);
      await expectLater(() => env.app.purchases.create(supplierId: s.id, date: env.clock.now, lines: [line]), throwsA(isA<SerialConflictException>()));
      await env.app.purchases.create(supplierId: s.id, date: env.clock.now, lines: [line], approvedSerialConflicts: {'ABC123'});
      expect(env.reload(hik.id).stockQty, q(2));
      expect(env.app.serials.findAll('ABC123').map((r) => r.key).toSet(), {'HIKVISION|ABC123', 'HIKVISION|ABC123|2'});
      // Plain serial is now ambiguous for this product; the exact key must be chosen.
      await expectLater(
          () => env.app.sales.complete(env.app.sales.newDraft().copyWith(
                items: [SaleItem(productId: hik.id, name: hik.name, qty: q(1), unitPrice: rs(1), serials: ['ABC123'])],
                paidAtSale: rs(1),
              )),
          throwsA(isA<BusinessException>()));
      await env.app.sales.complete(env.app.sales.newDraft().copyWith(
            items: [SaleItem(productId: hik.id, name: hik.name, qty: q(1), unitPrice: rs(1), serials: ['HIKVISION|ABC123|2'])],
            paidAtSale: rs(1),
          ));
      expect(env.app.integrity.check(), isEmpty);
    });

    test('only the owner role may resolve serial conflicts', () {
      expect(rolePermissions[UserRole.owner]!.contains(Permission.resolveSerialConflicts), isTrue);
      expect(rolePermissions[UserRole.staff]!.contains(Permission.resolveSerialConflicts), isFalse);
      expect(rolePermissions[UserRole.technician]!.contains(Permission.resolveSerialConflicts), isFalse);
    });

    test('unit returned to the supplier can be bought back under the same identity', () async {
      final (s, hik, _) = await twoBrands();
      final pur = env.app.purchases.list().first;
      await env.app.purchases.createReturn(purchaseId: pur.id, lines: [ReturnLineInput(productId: hik.id, qty: q(1), serials: ['ABC123'])], reason: 'DOA');
      expect(env.app.serials.find('ABC123')!.status, SerialStatus.returnedToSupplier);
      await env.app.purchases.create(supplierId: s.id, date: env.clock.now, lines: [PurchaseLineInput(productId: hik.id, qty: q(1), unitCost: rs(3000), serials: ['ABC123'])]);
      final r = env.app.serials.find('ABC123')!;
      expect(r.status, SerialStatus.inStock);
      expect(r.history.length, 3);
      expect(env.app.integrity.check(), isEmpty);
    });
  });

  group('3. Inspection / quality control', () {
    test('used and faulty returns are not sellable until the owner approves', () async {
      final app = env.app;
      final s = await env.supplier();
      final cam = await env.product('Bullet Cam', serial: true, brand: 'Hikvision');
      await app.purchases.create(supplierId: s.id, date: env.clock.now, lines: [PurchaseLineInput(productId: cam.id, qty: q(3), unitCost: rs(2500), serials: ['B1', 'B2', 'B3'])]);
      final t = await app.technicians.create(name: 'Kashif');
      await app.technicians.issue(technicianId: t.id, lines: [IssueLine(productId: cam.id, qty: q(2), serials: ['B1', 'B2'])]);
      await app.technicians.returnMaterial(technicianId: t.id, productId: cam.id, qty: q(1), type: TechTxnType.returnUsed, serialNumbers: ['B1'], reason: 'Opened box, works');
      await app.technicians.returnMaterial(technicianId: t.id, productId: cam.id, qty: q(1), type: TechTxnType.returnFaulty, serialNumbers: ['B2'], reason: 'No IR');
      var p = env.reload(cam.id);
      expect(p.stockQty, q(1));
      expect(p.inspectionQty, q(2));
      expect(app.serials.find('B1')!.status, SerialStatus.pendingInspection);
      // Not sellable while pending
      await expectLater(
          () => app.sales.complete(app.sales.newDraft().copyWith(
                items: [SaleItem(productId: cam.id, name: cam.name, qty: q(1), unitPrice: rs(4000), serials: ['B1'])],
                paidAtSale: rs(4000),
              )),
          throwsA(isA<BusinessException>()));

      final items = app.inspections.list();
      final used = items.firstWhere((x) => x.reportedCondition == 'used');
      final faulty = items.firstWhere((x) => x.reportedCondition == 'faulty');
      await app.inspections.decide(used.id, InspectionDecision.sellable, note: 'Tested OK');
      await app.inspections.decide(faulty.id, InspectionDecision.repairable, note: 'IR board');
      p = env.reload(cam.id);
      expect(p.stockQty, q(2));
      expect(p.inspectionQty, q(0));
      expect(p.repairableQty, q(1));
      expect(app.serials.find('B2')!.status, SerialStatus.awaitingRepair);
      // Repaired later → owner approves as sellable
      await app.inspections.decide(faulty.id, InspectionDecision.sellable, note: 'Repaired');
      p = env.reload(cam.id);
      expect(p.stockQty, q(3));
      expect(p.repairableQty, q(0));
      expect(app.inventory.stockValuation(productId: cam.id), rs(7500), reason: 'cost carried through inspection');
      expect(app.inspections.list(), isEmpty);
      expect(app.integrity.check(), isEmpty);
    });

    test('partial decision on a decimal quantity and staff cannot decide', () async {
      final app = env.app;
      final s = await env.supplier();
      final cable = await env.product('Power Cable', cost: 20, price: 35, decimal: true);
      await app.purchases.create(supplierId: s.id, date: env.clock.now, lines: [PurchaseLineInput(productId: cable.id, qty: q(10), unitCost: rs(20))]);
      final t = await app.technicians.create(name: 'Imran');
      await app.technicians.issue(technicianId: t.id, lines: [IssueLine(productId: cable.id, qty: q(4))]);
      await app.technicians.returnMaterial(technicianId: t.id, productId: cable.id, qty: Qty.parse('3.5'), type: TechTxnType.returnUsed, reason: 'Leftover pieces');
      final item = app.inspections.list().single;
      await app.auth.createUser(username: 'counter', password: 'counter1', displayName: 'Counter', role: UserRole.staff);
      app.auth.logout();
      await app.auth.login('counter', 'counter1');
      await expectLater(() => app.inspections.decide(item.id, InspectionDecision.sellable), throwsA(isA<PermissionException>()));
      app.auth.logout();
      await app.auth.login('owner', 'secret123');
      await app.inspections.decide(item.id, InspectionDecision.sellable, qty: Qty.parse('2'));
      await app.inspections.decide(item.id, InspectionDecision.damaged);
      final p = env.reload(cable.id);
      expect(p.stockQty, q(8));
      expect(p.damagedQty, Qty.parse('1.5'));
      expect(p.inspectionQty, q(0));
      expect(app.integrity.check(), isEmpty);
    });

    test('customer returns can be sent to inspection', () async {
      final app = env.app;
      final s = await env.supplier();
      final p0 = await env.product('Adapter');
      await app.purchases.create(supplierId: s.id, date: env.clock.now, lines: [PurchaseLineInput(productId: p0.id, qty: q(3), unitCost: rs(300))]);
      final sale = await app.sales.complete(app.sales.newDraft().copyWith(items: [SaleItem(productId: p0.id, name: p0.name, qty: q(2), unitPrice: rs(500))], paidAtSale: rs(1000)));
      await app.sales.createReturn(saleId: sale.id, lines: [ReturnLineInput(productId: p0.id, qty: q(1), condition: 'inspect')], reason: 'Customer says not working');
      expect(env.reload(p0.id).inspectionQty, q(1));
      expect(env.reload(p0.id).stockQty, q(1));
      expect(app.integrity.check(), isEmpty);
    });
  });

  group('4. Warranty start policy', () {
    test('defaults to invoice date; installation-date option uses install date', () async {
      final app = env.app;
      expect(app.ctx.settings.warrantyStartPolicy, WarrantyStartPolicy.saleDate);
      await app.ctx.store.commit([WriteOp(Boxes.settings, 'app', app.ctx.settings.merge({'warrantyStartPolicy': 'installationDate'}).toJson())]);
      final s = await env.supplier();
      final c = await env.customer();
      final cam = await env.product('Turret', serial: true, warrantyMonths: 12);
      await app.purchases.create(supplierId: s.id, date: env.clock.now, lines: [PurchaseLineInput(productId: cam.id, qty: q(1), unitCost: rs(1000), serials: ['T1'])]);
      final t = await app.technicians.create(name: 'Zain');
      await app.technicians.issue(technicianId: t.id, lines: [IssueLine(productId: cam.id, qty: q(1), serials: ['T1'])]);
      final installDay = env.clock.now;
      final usage = await app.technicians.recordInstalled(technicianId: t.id, productId: cam.id, qty: q(1), serialNumbers: ['T1'], customerId: c.id);
      env.clock.advance(const Duration(days: 10));
      await app.sales.complete(app.sales.newDraft().copyWith(
            customerId: c.id,
            items: [SaleItem(productId: cam.id, name: cam.name, qty: q(1), unitPrice: rs(2000), techUsageId: usage.id)],
          ));
      expect(app.serials.find('T1')!.warrantyStart, installDay);
      expect(app.serials.find('T1')!.warrantyExpiry, addMonths(installDay, 12));
    });
  });

  group('5. Credit sales need a customer account and owner approval', () {
    test('walk-in: full payment OK, credit needs account; staff needs owner approval', () async {
      final app = env.app;
      final s = await env.supplier();
      final p = await env.product('Hard Disk 1TB', cost: 8000, price: 10500);
      await app.purchases.create(supplierId: s.id, date: env.clock.now, lines: [PurchaseLineInput(productId: p.id, qty: q(5), unitCost: rs(8000))]);
      await app.auth.createUser(username: 'cashier', password: 'cash1234', displayName: 'Cashier', role: UserRole.staff);
      app.auth.logout();
      await app.auth.login('cashier', 'cash1234');

      Sale draft({String? customerId, required num paid}) => app.sales.newDraft().copyWith(
            customerId: customerId,
            items: [SaleItem(productId: p.id, name: p.name, qty: q(1), unitPrice: rs(10500))],
            paidAtSale: rs(paid),
          );

      await app.sales.complete(draft(paid: 10500)); // walk-in full payment
      await expectLater(() => app.sales.complete(draft(paid: 5000)), throwsA(isA<ValidationException>()));

      // Quick-create a customer account for the walk-in (staff may do this)
      final walkIn = await app.parties.create(kind: PartyKind.customer, name: 'Bilal (walk-in)', phone: '03001234567');
      expect(app.sales.needsCreditApproval(draft(customerId: walkIn.id, paid: 5000)), isTrue);
      await expectLater(() => app.sales.complete(draft(customerId: walkIn.id, paid: 5000)), throwsA(isA<PermissionException>()));
      await expectLater(() => app.auth.authorize('owner', 'wrong', Permission.approveCredit), throwsA(isA<PermissionException>()));
      await expectLater(() => app.auth.authorize('cashier', 'cash1234', Permission.approveCredit), throwsA(isA<PermissionException>()));
      final ok = await app.auth.authorize('owner', 'secret123', Permission.approveCredit);
      final sale = await app.sales.complete(draft(customerId: walkIn.id, paid: 5000), creditApproval: ok);
      expect(sale.creditApprovedBy, app.auth.findByUsername('owner')!.id);
      expect(app.parties.byId(PartyKind.customer, walkIn.id)!.balance, rs(5500));
      expect(app.ctx.store.values(Boxes.auditLogs).any((j) => j['action'] == 'approval_granted'), isTrue);
    });
  });

  test('Schema migration v1 -> v2 converts quantities and serial keys', () async {
    final store = MemoryStore();
    final v1 = <String, Map<String, Json>>{
      Boxes.meta: {'schema': {'version': 1}},
      Boxes.users: {'u1': {'id': 'u1', 'username': 'owner', 'displayName': 'O', 'passwordHash': 'x', 'role': 'owner', 'createdAt': '2026-01-01T00:00:00.000'}},
      Boxes.products: {
        'p1': {'id': 'p1', 'name': 'Cam', 'sku': 'S', 'brand': 'Hik Vision', 'purchasePrice': 100, 'sellingPrice': 200, 'stockQty': 3, 'issuedQty': 1, 'damagedQty': 0, 'minStock': 2, 'internalCode': 'AQ1', 'requiresSerial': true, 'createdAt': '2026-01-01T00:00:00.000', 'updatedAt': '2026-01-01T00:00:00.000'}
      },
      Boxes.serials: {'X1': {'serial': 'X1', 'productId': 'p1', 'cost': 100, 'status': 'inStock', 'history': []}},
      Boxes.sales: {
        's1': {'id': 's1', 'number': 'INV-1', 'date': '2026-01-01T00:00:00.000', 'createdAt': '2026-01-01T00:00:00.000', 'status': 'completed', 'items': [{'productId': 'p1', 'name': 'Cam', 'qty': 2, 'unitPrice': 200, 'serials': ['X1'], 'returnedQty': 0}]}
      },
    };
    await Migrator.replaceAll(store, v1);
    await Migrator.run(store);
    expect(Migrator.schemaOf(store), Migrator.currentSchema);
    final p = Product.fromJson(store.read(Boxes.products, 'p1')!);
    expect(p.stockQty, q(3));
    expect(p.minStock, q(2));
    final sr = SerialRecord.fromJson(store.read(Boxes.serials, 'HIKVISION|X1')!);
    expect(sr.serial, 'X1');
    expect(store.read(Boxes.serialIndex, 'X1')!['keys'], ['HIKVISION|X1']);
    final sale = Sale.fromJson(store.read(Boxes.sales, 's1')!);
    expect(sale.items.single.qty, q(2));
    expect(sale.items.single.serials, ['HIKVISION|X1']);
  });

  test('Purchase cancel refunds the amount paid at purchase', () async {
    final s = await env.supplier();
    final p = await env.product('Rack');
    final pur = await env.app.purchases.create(supplierId: s.id, date: env.clock.now, lines: [PurchaseLineInput(productId: p.id, qty: q(2), unitCost: rs(1000))], paid: rs(500));
    expect(env.app.parties.byId(PartyKind.supplier, s.id)!.balance, rs(1500));
    await env.app.purchases.cancel(pur.id, 'Wrong supplier');
    expect(env.app.parties.byId(PartyKind.supplier, s.id)!.balance, rs(0));
    expect(env.reload(p.id).stockQty, q(0));
  });
}
