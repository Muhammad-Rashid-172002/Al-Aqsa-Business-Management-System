import 'dart:io';

import 'package:al_aqsa_cctv/core/password_hasher.dart';
import 'package:al_aqsa_cctv/data/store/memory_store.dart';
import 'package:al_aqsa_cctv/domain/models/documents.dart';
import 'package:al_aqsa_cctv/domain/models/user.dart';
import 'package:al_aqsa_cctv/data/store/data_store.dart';
import 'package:al_aqsa_cctv/domain/services/app_services.dart';
import 'package:al_aqsa_cctv/domain/services/purchase_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

/// Startup without login: AuthService.openLocalSession().
void main() {
  test('reuses the existing owner and keeps all existing data', () async {
    final env = await TestEnv.create();
    final app = env.app;
    final p = await env.product('Dahua 8CH DVR');
    final cust = await env.customer();
    final owner = app.auth.findByUsername('owner')!;
    app.auth.logout();

    final u = await app.auth.openLocalSession();
    expect(u.id, owner.id);
    expect(app.ctx.session.user!.id, owner.id);
    expect(app.auth.users().length, 1);
    expect(app.catalog.byId(p.id), isNotNull);
    expect(app.parties.list(cust.kind).any((x) => x.id == cust.id), isTrue);

    // Opening again (next launch) never creates duplicates.
    app.auth.logout();
    await app.auth.openLocalSession();
    expect(app.auth.users().length, 1);
    await env.dispose();
  });

  test(
    'fresh install creates exactly one owner and opens the session',
    () async {
      final tmp = await Directory.systemTemp.createTemp('aqsa_fresh');
      final app = AppServices(
        MemoryStore(),
        localBackupDir: '${tmp.path}/local',
        hasher: const PasswordHasher(iterations: 10),
      );
      expect(app.auth.users(), isEmpty);
      final u = await app.auth.openLocalSession();
      expect(u.role, UserRole.owner);
      expect(u.displayName, 'Owner');
      expect(app.ctx.can(Permission.approveCredit), isTrue);
      expect(app.ctx.can(Permission.approveInspection), isTrue);
      expect(app.ctx.can(Permission.backupRestore), isTrue);
      app.auth.logout();
      await app.auth.openLocalSession();
      expect(app.auth.users().length, 1, reason: 'second launch reuses it');
      await tmp.delete(recursive: true);
    },
  );

  test(
    'a database whose owners were all deactivated still opens (owner reactivated)',
    () async {
      final env = await TestEnv.create();
      final app = env.app;
      final owner = app.auth.findByUsername('owner')!;
      // Simulate legacy data: the only owner record is inactive.
      await app.ctx.store.commit([
        WriteOp(Boxes.users, owner.id, owner.copyWith(active: false).toJson()),
      ]);
      app.auth.logout();
      final u = await app.auth.openLocalSession();
      expect(u.id, owner.id);
      expect(u.active, isTrue);
      expect(app.auth.users().length, 1);
      await env.dispose();
    },
  );

  test(
    'credit sale is approved by the owner session (no password prompt)',
    () async {
      final env = await TestEnv.create();
      final app = env.app;
      app.auth.logout();
      await app.auth.openLocalSession();
      final sup = await env.supplier();
      final p = await env.product('HDD 2TB', cost: 10000, price: 14000);
      await app.purchases.create(
        supplierId: sup.id,
        date: env.clock.now,
        lines: [
          PurchaseLineInput(productId: p.id, qty: q(2), unitCost: rs(10000)),
        ],
      );
      final cust = await env.customer();
      final draft = app.sales.newDraft().copyWith(
        customerId: cust.id,
        items: [
          SaleItem(
            productId: p.id,
            name: p.name,
            qty: q(1),
            unitPrice: rs(14000),
          ),
        ],
        paidAtSale: rs(4000),
      );
      expect(
        app.sales.needsCreditApproval(draft),
        isFalse,
        reason: 'owner session holds approveCredit',
      );
      final approval = app.auth.selfAuthorization(Permission.approveCredit);
      expect(approval, isNotNull);
      final sale = await app.sales.complete(draft, creditApproval: approval);
      expect(sale.creditApprovedBy, app.ctx.session.user!.id);
      expect(app.parties.byId(cust.kind, cust.id)!.balance, rs(10000));
      await env.dispose();
    },
  );
}
