import 'dart:convert';
import 'dart:io';

import 'package:al_aqsa_cctv/data/migrations.dart';
import 'package:al_aqsa_cctv/data/store/data_store.dart';
import 'package:al_aqsa_cctv/data/store/hive_store.dart';
import 'package:al_aqsa_cctv/domain/models/party.dart';
import 'package:al_aqsa_cctv/domain/models/product.dart';
import 'package:al_aqsa_cctv/domain/services/app_services.dart';
import 'package:al_aqsa_cctv/domain/services/catalog_service.dart';
import 'package:al_aqsa_cctv/domain/services/purchase_service.dart';
import 'package:al_aqsa_cctv/domain/services/report_service.dart';
import 'package:al_aqsa_cctv/domain/services/report_tables.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

/// The read cache (performance work) must never change results: every
/// cached answer is compared with the same answer computed from freshly
/// decoded records, and changes must be visible right after each commit.
/// Report rows hold DateTime values (typed cells for Excel).
String _enc(Object o) => jsonEncode(o, toEncodable: (v) => v is DateTime ? v.toIso8601String() : v.toString());

void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() async => env.dispose());

  Future<void> seed() async {
    final app = env.app;
    final sup = await env.supplier();
    final cust = await env.customer();
    final prods = <Product>[];
    for (var i = 0; i < 30; i++) {
      prods.add(await env.product('Item ${String.fromCharCode(90 - i % 26)}$i', cost: 100 + i, price: 150 + i, brand: i.isEven ? 'Dahua' : 'Hik'));
    }
    for (var k = 0; k < 3; k++) {
      await app.purchases.create(
        supplierId: sup.id,
        supplierInvoiceNo: 'S-$k',
        date: env.clock.now,
        lines: [for (final p in prods.take(10 + k * 5)) PurchaseLineInput(productId: p.id, qty: q(5), unitCost: rs(90 + k * 10))],
        paid: rs(100),
      );
      env.clock.advance(const Duration(days: 1));
    }
    for (var k = 0; k < 6; k++) {
      final d = app.sales.newDraft().copyWith(customerId: cust.id, customerName: cust.name, items: [
        for (final p in prods.skip(k).take(3)) app.sales.lineFor(env.reload(p.id), qty: q(2)),
      ]);
      await app.sales.complete(d.copyWith(paidAtSale: d.total));
      env.clock.advance(const Duration(hours: 5));
    }
  }

  test('cached lists follow every commit immediately', () async {
    final app = env.app;
    expect(app.catalog.products(), isEmpty);
    final p = await env.product('Dome Camera');
    expect(app.catalog.products().map((x) => x.id), [p.id]);
    expect(app.catalog.search('dome').length, 1);
    await app.catalog.update(p.id, ProductInput(name: 'Bullet Camera', purchasePrice: rs(1000), sellingPrice: rs(1500)));
    expect(app.catalog.products().single.name, 'Bullet Camera');
    expect(app.catalog.search('dome'), isEmpty);
    expect(app.catalog.search('bullet').single.id, p.id);
    final before = app.ctx.settings.businessName;
    await app.settings.save({'businessName': '$before X'});
    expect(app.ctx.settings.businessName, '$before X');
  });

  test('cached results equal results from freshly decoded records', () async {
    await seed();
    final app = env.app;
    final store = app.ctx.store;
    List<T> fresh<T>(String box, T Function(Json) f) => store.values(box).map(f).toList();

    // Products: sort and search.
    final naive = fresh(Boxes.products, Product.fromJson).where((p) => !p.archived).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    expect(app.catalog.products().map((p) => p.id).toList(), naive.map((p) => p.id).toList());
    for (final q0 in ['item', 'dahua', 'z1', 'aq', '']) {
      final want = naive.where((p) {
        final q1 = q0.toLowerCase();
        return q1.isEmpty ||
            p.name.toLowerCase().contains(q1) ||
            p.sku.toLowerCase().contains(q1) ||
            p.model.toLowerCase().contains(q1) ||
            p.brand.toLowerCase().contains(q1) ||
            p.barcodes.any((c) => c.toLowerCase().contains(q1));
      }).map((p) => p.id);
      expect(app.catalog.search(q0).map((p) => p.id).toList(), want.toList(), reason: 'search "$q0"');
    }
    // Scan by SKU (fallback path) and by barcode.
    final some = naive[7];
    expect(app.catalog.lookup(some.sku.toLowerCase())!.product.id, some.id);
    expect(app.catalog.lookup(some.internalCode)!.product.id, some.id);
    expect(app.catalog.lookup('NO-SUCH-CODE'), isNull);

    // FIFO layers (as the engine sees them inside a unit of work).
    final uow = app.ctx.uow();
    for (final p in naive.take(20)) {
      final want = uow
          .values(Boxes.costLayers)
          .where((j) => j['productId'] == p.id && ((j['qtyRemaining'] as num?) ?? 0) > 0)
          .map(CostLayer.fromJson)
          .toList()
        ..sort((a, b) {
          final c = a.date.compareTo(b.date);
          return c != 0 ? c : a.id.compareTo(b.id);
        });
      expect(app.inventory.openLayers(uow, p.id).map((l) => '${l.id}:${l.qtyRemaining.milli}').toList(),
          want.map((l) => '${l.id}:${l.qtyRemaining.milli}').toList());
    }
    // Pending writes in the unit of work are seen too.
    final withStock = naive.firstWhere((p) => app.inventory.openLayers(uow, p.id).isNotEmpty);
    final first = app.inventory.openLayers(uow, withStock.id).first;
    uow.put(Boxes.costLayers, first.id, first.withRemaining(q(0)).toJson());
    expect(app.inventory.openLayers(uow, withStock.id).any((l) => l.id == first.id), isFalse);

    // Ledger per party.
    final cust = app.parties.list(PartyKind.customer).single;
    final wantLedger = fresh(Boxes.ledger, LedgerEntry.fromJson).where((e) => e.partyKind == PartyKind.customer && e.partyId == cust.id).map((e) => e.id).toSet();
    expect(app.parties.entries(PartyKind.customer, cust.id).map((e) => e.id).toSet(), wantLedger);

    // Every report gives the same table with a cold and a warm cache.
    final r = DateRange(env.clock.now.subtract(const Duration(days: 30)), env.clock.now.add(const Duration(days: 1)));
    final rb = ReportBuilder(app);
    final warm = {for (final k in ReportKind.values) k: _enc([rb.build(k, r).rows, rb.build(k, r).footer])};
    app.ctx.clearCache();
    for (final k in ReportKind.values) {
      expect(_enc([rb.build(k, r).rows, rb.build(k, r).footer]), warm[k], reason: k.name);
    }
  });

  test('backup data.json is identical to encoding the whole export at once', () async {
    await seed();
    final app = env.app;
    final export = Migrator.exportAll(app.ctx.store)..remove(Boxes.errorLog);
    for (final u in export[Boxes.users]!.values) {
      u['passwordHash'] = ''; // never stored in backups
    }
    final want = jsonEncode(export);
    final files = await app.backup.backupNow();
    final zip = ZipDecoder().decodeBytes(await files.single.readAsBytes());
    final data = zip.files.firstWhere((f) => f.name == 'data.json');
    expect(utf8.decode(data.content), want);
    final (manifest, restored) = await app.backup.validate(files.single.path);
    expect(manifest.counts[Boxes.sales], 6);
    expect(restored[Boxes.products]!.length, 30);
  });

  test('Hive store: revision changes on commit and cached reads see new data', () async {
    final dir = await Directory.systemTemp.createTemp('aqsa_rev');
    final store = await HiveStore.open(dir.path);
    final app = AppServices(store, localBackupDir: '${dir.path}/b');
    await app.auth.openLocalSession();
    final r0 = store.revision(Boxes.products);
    expect(app.catalog.products(), isEmpty);
    final p = await app.catalog.create(ProductInput(name: 'NVR 8CH', purchasePrice: rs(5000), sellingPrice: rs(7000)));
    expect(store.revision(Boxes.products) > r0, isTrue);
    expect(app.catalog.products().single.id, p.id);
    expect(app.catalog.lookup(p.internalCode)!.product.id, p.id);
    await store.close();
    await dir.delete(recursive: true);
  });
}
