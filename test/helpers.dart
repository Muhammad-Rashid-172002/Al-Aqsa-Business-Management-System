import 'dart:io';

import 'package:al_aqsa_cctv/core/money.dart';
import 'package:al_aqsa_cctv/core/qty.dart';
export 'package:al_aqsa_cctv/core/qty.dart';
import 'package:al_aqsa_cctv/core/password_hasher.dart';
import 'package:al_aqsa_cctv/data/store/memory_store.dart';
import 'package:al_aqsa_cctv/domain/models/party.dart';
import 'package:al_aqsa_cctv/domain/models/product.dart';
import 'package:al_aqsa_cctv/domain/services/app_services.dart';
import 'package:al_aqsa_cctv/domain/services/catalog_service.dart';

Money rs(num v) => Money.rupees(v);

class TestClock {
  DateTime now = DateTime(2026, 3, 10, 10);
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
}

class TestEnv {
  final AppServices app;
  final TestClock clock;
  final Directory tmp;
  TestEnv(this.app, this.clock, this.tmp);

  static Future<TestEnv> create() async {
    final clock = TestClock();
    final tmp = await Directory.systemTemp.createTemp('aqsa_test');
    final app = AppServices(MemoryStore(),
        localBackupDir: '${tmp.path}/local', clock: clock.call, hasher: const PasswordHasher(iterations: 10));
    await app.auth.createOwner(username: 'owner', password: 'secret123', displayName: 'Owner');
    await app.auth.login('owner', 'secret123');
    return TestEnv(app, clock, tmp);
  }

  Future<Product> product(String name, {num cost = 1000, num price = 1500, bool serial = false, int warrantyMonths = 12, num minStock = 2, bool decimal = false, String brand = ''}) =>
      app.catalog.create(ProductInput(
          name: name, purchasePrice: rs(cost), sellingPrice: rs(price), requiresSerial: serial, warrantyMonths: warrantyMonths, minStock: Qty.units(minStock), allowDecimal: decimal, brand: brand));

  Future<Party> supplier([String name = 'Hikvision Distributor']) => app.parties.create(kind: PartyKind.supplier, name: name, phone: '0300');
  Future<Party> customer([String name = 'Ali Traders']) => app.parties.create(kind: PartyKind.customer, name: name, phone: '0311');

  Product reload(String id) => app.catalog.byId(id)!;

  Future<void> dispose() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  }
}

Qty q(num v) => Qty.units(v);
