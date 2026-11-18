import 'dart:io';

import 'package:al_aqsa_cctv/core/errors.dart';
import 'package:al_aqsa_cctv/data/store/data_store.dart';
import 'package:al_aqsa_cctv/data/store/hive_store.dart';
import 'package:al_aqsa_cctv/domain/models/party.dart';
import 'package:al_aqsa_cctv/domain/services/purchase_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'helpers.dart';

void main() {
  test('Backup creation, validation and restore round-trip', () async {
    final env = await TestEnv.create();
    final app = env.app;
    final s = await env.supplier();
    final p = await env.product('NVR 16CH', cost: 20000, price: 26000);
    await app.purchases.create(supplierId: s.id, date: env.clock.now, lines: [PurchaseLineInput(productId: p.id, qty: q(3), unitCost: rs(20000))]);

    final files = await app.backup.backupNow();
    expect(files, hasLength(1));
    final (manifest, _) = await app.backup.validate(files.first.path);
    expect(manifest.counts['products'], 1);
    expect(manifest.schemaVersion, greaterThanOrEqualTo(1));

    // Change data after the backup
    await app.inventory.adjustTo(p.id, q(0), 'test');
    await app.parties.create(kind: PartyKind.customer, name: 'Later Customer');
    expect(env.reload(p.id).stockQty, q(0));

    // Restore → data is back, a safety backup of the newer data exists
    final safety = (await app.backup.restore(files.first.path)).safetyBackup;
    expect(await safety.exists(), isTrue);
    expect(app.ctx.session.isLoggedIn, isFalse);
    // Backups never contain password hashes; the app opens the restored
    // owner account directly (there is no login screen).
    await app.auth.openLocalSession();
    expect(env.reload(p.id).stockQty, q(3));
    expect(app.parties.list(PartyKind.customer), isEmpty);
    expect(app.integrity.check(), isEmpty);

    // Damaged backup is rejected
    final bytes = await files.first.readAsBytes();
    final bad = File('${env.tmp.path}/AL-AQSA_Backup_bad.zip')..writeAsBytesSync(bytes.sublist(0, bytes.length ~/ 2));
    await expectLater(() => app.backup.validate(bad.path), throwsA(isA<BusinessException>()));
    final history = await app.backup.history('${env.tmp.path}/local');
    expect(history.length, greaterThanOrEqualTo(2));
    await env.dispose();
  });

  test('Hive store replays an interrupted transaction on next open', () async {
    final dir = await Directory.systemTemp.createTemp('aqsa_hive');
    var store = await HiveStore.open(dir.path);
    await store.commit([const WriteOp(Boxes.customers, 'c1', {'id': 'c1', 'name': 'A'})]);
    expect(store.read(Boxes.customers, 'c1')!['name'], 'A');
    await store.close();

    // Simulate a crash: journal written, boxes not yet updated.
    Hive.init(dir.path);
    final journal = await Hive.openBox<Map>('_journal');
    await journal.put('00000000000000000001', {
      'ops': [
        {'b': Boxes.customers, 'k': 'c2', 'v': {'id': 'c2', 'name': 'B'}},
        {'b': Boxes.customers, 'k': 'c1', 'v': null},
      ]
    });
    await Hive.close();

    store = await HiveStore.open(dir.path);
    expect(store.recoveredTransactions, 1);
    expect(store.read(Boxes.customers, 'c2')!['name'], 'B');
    expect(store.read(Boxes.customers, 'c1'), isNull);
    await store.close();
    await dir.delete(recursive: true);
  });
}
