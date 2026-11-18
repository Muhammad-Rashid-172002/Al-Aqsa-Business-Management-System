import 'dart:convert';
import 'dart:io';

import 'package:al_aqsa_cctv/core/errors.dart';
import 'package:al_aqsa_cctv/core/password_hasher.dart';
import 'package:al_aqsa_cctv/data/migrations.dart';
import 'package:al_aqsa_cctv/data/store/data_store.dart';
import 'package:al_aqsa_cctv/data/store/hive_store.dart';
import 'package:al_aqsa_cctv/data/windows_backup_task.dart';
import 'package:al_aqsa_cctv/domain/models/documents.dart';
import 'package:al_aqsa_cctv/domain/models/party.dart';
import 'package:al_aqsa_cctv/domain/models/product.dart';
import 'package:al_aqsa_cctv/domain/services/app_services.dart';
import 'package:al_aqsa_cctv/domain/services/backup_service.dart';
import 'package:al_aqsa_cctv/domain/services/catalog_service.dart';
import 'package:al_aqsa_cctv/domain/services/purchase_service.dart';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'helpers.dart';

/// A tiny valid PNG (1x1) so image files are real files with real bytes.
final _png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

/// One "computer": its own app data folder (Hive database, media) and a
/// backup folder standing in for drive D:.
class _Pc {
  final Directory root;
  final String backupDir;
  final TestClock clock;
  late HiveStore store;
  late AppServices app;
  _Pc(this.root, this.backupDir, this.clock);

  String get data => p.join(root.path, 'data');
  String get media => p.join(root.path, 'media');

  Future<void> open() async {
    store = await HiveStore.open(data);
    await Migrator.run(store);
    app = AppServices(store,
        localBackupDir: p.join(root.path, 'backups'),
        mediaDir: media,
        defaultBackupDir: backupDir,
        clock: clock.call,
        hasher: const PasswordHasher(iterations: 10));
    await app.auth.openLocalSession();
  }

  Future<void> close() => store.close();
}

Future<Map<String, Object?>> _fingerprint(AppServices app) async => {
      'products': app.catalog.products(includeArchived: true).map((x) => x.toJson()).toList(),
      'serials': app.serials.search().map((x) => x.toJson()).toList(),
      'sales': app.sales.list().map((x) => x.toJson()).toList(),
      'purchases': app.purchases.list().map((x) => x.toJson()).toList(),
      'customers': app.parties.list(PartyKind.customer, includeInactive: true).map((x) => x.toJson()).toList(),
      'suppliers': app.parties.list(PartyKind.supplier, includeInactive: true).map((x) => x.toJson()).toList(),
      'payments': app.parties.payments().map((x) => x.toJson()).toList(),
    };

void main() {
  late Directory tmp;
  late TestClock clock;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('aqsa_recovery');
    clock = TestClock()..now = DateTime(2026, 11, 18, 10);
  });
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  /// A shop with products (one with an image), serials, a credit sale, a
  /// purchase with a part payment and a logo kept outside the app folder.
  Future<_Pc> shop() async {
    final pc = _Pc(Directory(p.join(tmp.path, 'pc1')), p.join(tmp.path, 'D', 'AL-AQSA_Backups'), clock);
    await pc.open();
    final app = pc.app;
    final src = File(p.join(tmp.path, 'camera.png'))..writeAsBytesSync(_png);
    final img = await app.importMedia(src.path, folder: 'products');
    final logo = File(p.join(tmp.path, 'Desktop', 'shop logo.png'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(_png);
    await app.settings.save({'logoPath': logo.path});
    final sup = await app.parties.create(kind: PartyKind.supplier, name: 'Hik Distributor');
    final cust = await app.parties.create(kind: PartyKind.customer, name: 'Ali Traders');
    final (cam, _) = await app.createProductWithStock(
      ProductInput(name: 'Hikvision CCTV Camera', brand: 'Hikvision', purchasePrice: rs(4000), sellingPrice: rs(6000), requiresSerial: true, warrantyMonths: 12, imagePath: img),
      supplierId: sup.id,
      qty: q(5),
      unitCost: rs(4000),
      serials: const ['HK1', 'HK2', 'HK3', 'HK4', 'HK5'],
      paid: rs(5000),
    );
    final d = app.sales.newDraft().copyWith(customerId: cust.id, customerName: cust.name, items: [app.sales.lineFor(app.catalog.byId(cam.id)!, qty: q(2), serials: const ['HK1', 'HK2'])]);
    await app.sales.complete(d.copyWith(paidAtSale: rs(4000)));
    return pc;
  }

  test('manual backup: dated name, never overwritten, verified, no passwords', () async {
    final pc = await shop();
    final a = await pc.app.backup.backupNow();
    final b = await pc.app.backup.backupNow();
    final names = [for (final f in [...a, ...b]) p.basename(f.path)];
    expect(names.where((n) => n == 'AL-AQSA_Backup_2026-11-18.zip').length, 2, reason: 'one in D:, one local');
    expect(names.where((n) => n == 'AL-AQSA_Backup_2026-11-18_2.zip').length, 2, reason: 'second backup of the day gets _2');
    expect(a.first.path.startsWith(pc.backupDir), isTrue, reason: 'default folder = D:\\AL-AQSA_Backups');
    expect(await Directory(pc.backupDir).list().length, 2);
    final (m, data) = await pc.app.backup.validate(a.first.path);
    expect(m.app, 'AL-AQSA CCTV & SOLAR SYSTEM');
    expect(m.format, 2);
    expect(m.fileCount, 2, reason: 'product image + logo');
    expect(data[Boxes.users]!.values.every((u) => u['passwordHash'] == ''), isTrue, reason: 'no credentials in backups');
    expect(pc.app.backup.lastBackupAt, clock.now);
    expect(pc.app.backup.lastBackupError, isNull);
    await pc.close();
  });

  test('missing backup drive: clear error, local copy kept, never reported as success', () async {
    final pc = await shop();
    // A "drive" that cannot be written (its parent is a file).
    final blocker = File(p.join(tmp.path, 'X'))..writeAsStringSync('not a folder');
    await pc.app.settings.save({'backupDirectory': p.join(blocker.path, 'AL-AQSA_Backups')});
    expect(await BackupService.folderProblem(p.join(blocker.path, 'AL-AQSA_Backups')), isNotNull);
    BackupFolderUnavailable? err;
    try {
      await pc.app.backup.backupNow();
    } on BackupFolderUnavailable catch (e) {
      err = e;
    }
    expect(err, isNotNull);
    expect(err!.message.contains('NOT saved'), isTrue);
    expect(err.localCopy!.existsSync(), isTrue);
    expect(pc.app.backup.lastBackupAt, isNull, reason: 'no false success');
    expect(pc.app.backup.lastBackupError, isNotNull);
    // Automatic backup to the missing drive fails the same way, retried after an hour.
    await pc.app.settings.save({'autoBackup': true, 'backupHour': 9, 'backupMinute': 0});
    final r = await pc.app.backup.runAutoBackupIfDue();
    expect(r!.ok, isFalse);
    expect(pc.app.backup.lastAutoBackupAt, isNull);
    expect(pc.app.backup.autoBackupDue, isFalse, reason: 'not every minute');
    clock.advance(const Duration(minutes: 61));
    expect(pc.app.backup.autoBackupDue, isTrue);
    // Owner picks another location: next backup succeeds and clears the error.
    await pc.app.settings.save({'backupDirectory': p.join(tmp.path, 'USB')});
    expect((await pc.app.backup.runAutoBackupIfDue())!.ok, isTrue);
    expect(pc.app.backup.lastBackupError, isNull);
    expect(pc.app.backup.lastAutoBackupAt, clock.now);
    await pc.close();
  });

  test('daily schedule: runs at the set time, catches up after the app was closed, survives restart', () async {
    final pc = await shop();
    final b = pc.app.backup;
    await pc.app.settings.save({'autoBackup': false, 'backupHour': 22, 'backupMinute': 30});
    expect(b.autoBackupDue, isFalse, reason: 'OFF');
    await pc.app.settings.save({'autoBackup': true});
    // Never backed up: yesterday's 22:30 was missed -> catch up now.
    expect(b.lastScheduledTime(), DateTime(2026, 11, 17, 22, 30));
    expect(b.autoBackupDue, isTrue);
    expect((await b.runAutoBackupIfDue())!.ok, isTrue);
    expect(b.autoBackupDue, isFalse);
    expect(await b.runAutoBackupIfDue(), isNull);
    clock.now = DateTime(2026, 11, 18, 22, 29);
    expect(b.autoBackupDue, isFalse);
    clock.now = DateTime(2026, 11, 18, 22, 31);
    expect(b.autoBackupDue, isTrue, reason: 'scheduled time reached');
    expect((await b.runAutoBackupIfDue())!.ok, isTrue);
    // Close the app; reopen the next afternoon: today's 22:30 not reached, done for yesterday.
    await pc.close();
    clock.now = DateTime(2026, 11, 19, 15);
    await pc.open();
    expect(pc.app.backup.autoBackupDue, isFalse, reason: 'state is saved in the database');
    expect(pc.app.backup.nextScheduledTime(), DateTime(2026, 11, 19, 22, 30));
    // Computer was off at 22:30 on the 19th; started on the 20th at 08:00 -> runs at start.
    await pc.close();
    clock.now = DateTime(2026, 11, 20, 8);
    await pc.open();
    expect(pc.app.backup.autoBackupDue, isTrue);
    expect((await pc.app.backup.runAutoBackupIfDue())!.ok, isTrue);
    final auto = (await pc.app.backup.history(pc.backupDir)).where((e) => e.manifest.label == 'auto').toList();
    expect(auto.length, 3);
    await pc.close();
  });

  test('retention deletes only old automatic backups', () async {
    final pc = await shop();
    await pc.app.settings.save({'autoBackup': true, 'backupKeep': 3, 'backupHour': 0});
    await pc.app.backup.backupNow(); // manual
    for (var d = 0; d < 5; d++) {
      clock.now = DateTime(2026, 11, 19 + d, 1);
      expect((await pc.app.backup.runAutoBackupIfDue())!.ok, isTrue);
    }
    final h = await pc.app.backup.history(pc.backupDir);
    expect(h.where((e) => e.manifest.label == 'auto').length, 3);
    expect(h.where((e) => e.manifest.label == 'manual').length, 1);
    await pc.close();
  });

  test('corrupted and incomplete backups are rejected and current data stays', () async {
    final pc = await shop();
    final file = (await pc.app.backup.backupNow()).first;
    final before = await _fingerprint(pc.app);
    final bytes = await file.readAsBytes();
    // Truncated download / copy.
    final cut = File(p.join(tmp.path, 'AL-AQSA_Backup_cut.zip'))..writeAsBytesSync(bytes.sublist(0, bytes.length - 200));
    // Records changed inside the zip (checksum no longer matches).
    final zip = ZipDecoder().decodeBytes(bytes);
    Archive rebuild({String? drop, String? replace, List<int>? withBytes}) {
      final out = Archive();
      for (final f in zip.files) {
        if (f.name == drop) continue;
        final c = f.name == replace ? withBytes! : f.content;
        out.addFile(ArchiveFile(f.name, c.length, c));
      }
      return out;
    }

    final data = utf8.decode(zip.findFile('data.json')!.content).replaceFirst('Hikvision CCTV Camera', 'Hikvision CCTV Camerx');
    final tampered = File(p.join(tmp.path, 'AL-AQSA_Backup_tampered.zip'))..writeAsBytesSync(ZipEncoder().encode(rebuild(replace: 'data.json', withBytes: utf8.encode(data))));
    final imgName = zip.files.firstWhere((f) => f.name.startsWith('files/')).name;
    final noImage = File(p.join(tmp.path, 'AL-AQSA_Backup_noimage.zip'))..writeAsBytesSync(ZipEncoder().encode(rebuild(drop: imgName)));
    final notZip = File(p.join(tmp.path, 'AL-AQSA_Backup_text.zip'))..writeAsStringSync('hello');
    for (final bad in [cut, tampered, noImage, notZip]) {
      await expectLater(pc.app.backup.inspect(bad.path), throwsA(isA<BusinessException>()), reason: p.basename(bad.path));
      await expectLater(pc.app.backup.restore(bad.path), throwsA(isA<BusinessException>()), reason: p.basename(bad.path));
    }
    expect(await _fingerprint(pc.app), before);
    await pc.close();
  });

  test('Windows reinstall: fresh install restores records, serials, balances and images; repeat restore adds no duplicates', () async {
    final pc1 = await shop();
    final backup = (await pc1.app.backup.backupNow()).firstWhere((f) => f.path.startsWith(pc1.backupDir));
    final want = await _fingerprint(pc1.app);
    final custBal = pc1.app.parties.list(PartyKind.customer).single.balance;
    final supBal = pc1.app.parties.list(PartyKind.supplier).single.balance;
    final oldImage = pc1.app.catalog.products().single.imagePath!;
    await pc1.close();
    // Windows reinstalled: C: (app data) is gone, D: kept.
    await Directory(pc1.root.path).delete(recursive: true);
    await Directory(p.join(tmp.path, 'Desktop')).delete(recursive: true); // logo source gone too

    final pc2 = _Pc(Directory(p.join(tmp.path, 'pc2')), pc1.backupDir, clock);
    await pc2.open(); // fresh install, empty database
    expect(pc2.app.catalog.products(), isEmpty);
    final listed = await pc2.app.backup.history(pc2.backupDir);
    expect(listed.any((e) => e.file.path == backup.path), isTrue, reason: 'the D: backups are found');
    final preview = await pc2.app.backup.inspect(backup.path);
    expect(preview.manifest.count(Boxes.serials), 5);
    expect(preview.files.length, 2);
    final r = await pc2.app.backup.restore(backup.path);
    expect(r.files, 2);
    await pc2.app.auth.openLocalSession();

    final got = await _fingerprint(pc2.app);
    final cam = pc2.app.catalog.products().single;
    // Image references now point at this computer's media folder.
    expect(cam.imagePath == oldImage, isFalse);
    expect(p.isWithin(pc2.media, cam.imagePath!), isTrue);
    expect(File(cam.imagePath!).readAsBytesSync(), _png);
    final logo = pc2.app.ctx.settings.logoPath!;
    expect(p.isWithin(pc2.media, logo), isTrue);
    expect(sha256.convert(File(logo).readAsBytesSync()), sha256.convert(_png));
    // Everything else identical.
    (want['products'] as List).cast<Map>().single['imagePath'] = cam.imagePath;
    expect(got, want);
    expect(pc2.app.serials.find('HK1')!.status, SerialStatus.sold);
    expect(pc2.app.serials.inStockFor(cam.id).length, 3);
    expect(cam.stockQty, q(3));
    expect(pc2.app.parties.list(PartyKind.customer).single.balance, custBal);
    expect(pc2.app.parties.list(PartyKind.supplier).single.balance, supBal);
    expect(pc2.app.sales.list(status: DocStatus.completed).length, 1);
    expect(pc2.app.integrity.check(), isEmpty);

    // Restoring the same backup again: still exactly one of everything.
    await pc2.app.backup.restore(backup.path);
    await pc2.app.auth.openLocalSession();
    expect(pc2.app.catalog.products().length, 1);
    expect(pc2.app.serials.search().length, 5);
    expect(pc2.app.sales.list().length, 1);
    expect(pc2.app.parties.list(PartyKind.customer).length, 1);
    // After a restart the restored data is still there.
    await pc2.close();
    await pc2.open();
    expect(pc2.app.catalog.products().single.name, 'Hikvision CCTV Camera');
    expect(pc2.app.serials.search().length, 5);
    await pc2.close();
  });

  test('backups from the previous version (.aqbak, no images) still restore', () async {
    final pc = await shop();
    final data = Migrator.exportAll(pc.store)..remove(Boxes.errorLog);
    final dataBytes = utf8.encode(jsonEncode(data));
    final manifest = {
      'app': 'AL AQSA CCTV',
      'format': 1,
      'schemaVersion': Migrator.currentSchema,
      'appVersion': '1.0.0',
      'createdAt': DateTime(2026, 11, 1).toIso8601String(),
      'sha256': sha256.convert(dataBytes).toString(),
      'counts': {for (final e in data.entries) e.key: e.value.length},
      'label': 'manual',
    };
    final mBytes = utf8.encode(jsonEncode(manifest));
    final old = File(p.join(pc.backupDir, 'alaqsa_manual_20261101_100000.aqbak'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(ZipEncoder().encode(Archive()
        ..addFile(ArchiveFile('manifest.json', mBytes.length, mBytes))
        ..addFile(ArchiveFile('data.json', dataBytes.length, dataBytes))));
    final listed = await pc.app.backup.history(pc.backupDir);
    expect(listed.any((e) => e.file.path == old.path), isTrue);
    await pc.app.backup.backupNow(); // a newer one exists now
    final preview = await pc.app.backup.inspect(old.path);
    expect(preview.olderThanLatest, isTrue, reason: 'owner is warned');
    await pc.app.parties.create(kind: PartyKind.customer, name: 'Added later');
    await pc.app.backup.restore(old.path);
    await pc.app.auth.openLocalSession();
    expect(pc.app.parties.list(PartyKind.customer).length, 1);
    expect(pc.app.serials.search().length, 5);
    await pc.close();
  });

  test('buying more units of an existing product reuses it', () async {
    final pc = await shop();
    final app = pc.app;
    final sup = app.parties.list(PartyKind.supplier).single;
    await app.purchases.create(
      supplierId: sup.id,
      date: clock.now,
      lines: [PurchaseLineInput(productId: app.catalog.products().single.id, qty: q(1), unitCost: rs(4100), serials: const ['HK6'])],
    );
    expect(app.catalog.products().single.stockQty, q(4));
    await pc.close();
  });

  test('Windows task definition starts the app hidden, daily, and catches up', () {
    final x = WindowsBackupTask.xml(exePath: r'C:\Program Files\AL-AQSA CCTV & SOLAR SYSTEM\al_aqsa_cctv.exe', hour: 21, minute: 5, from: DateTime(2026, 11, 18));
    expect(x.contains('<StartBoundary>2026-11-18T21:05:00</StartBoundary>'), isTrue);
    expect(x.contains('<StartWhenAvailable>true</StartWhenAvailable>'), isTrue);
    expect(x.contains('<Arguments>--backup-now</Arguments>'), isTrue);
    expect(x.contains('AL-AQSA CCTV &amp; SOLAR SYSTEM\\al_aqsa_cctv.exe'), isTrue, reason: 'path is XML-escaped');
  });
}
