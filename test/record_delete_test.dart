// Delete from the ⋮ row menu: records without history are removed; records
// with stock, money or job history are archived / cancelled / voided, so
// financial and stock history is preserved.
import 'package:al_aqsa_cctv/core/errors.dart';
import 'package:al_aqsa_cctv/data/store/data_store.dart';
import 'package:al_aqsa_cctv/domain/models/documents.dart';
import 'package:al_aqsa_cctv/domain/models/operations.dart';
import 'package:al_aqsa_cctv/domain/models/party.dart';
import 'package:al_aqsa_cctv/domain/services/purchase_service.dart';
import 'package:al_aqsa_cctv/domain/services/technician_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() async => env.dispose());

  test('customer: no history -> deleted; with an invoice -> archived and restorable, ledger intact', () async {
    final app = env.app;
    final empty = await env.customer('Never bought');
    expect(await app.parties.deleteOrArchive(PartyKind.customer, empty.id), isFalse);
    expect(app.parties.byId(PartyKind.customer, empty.id), isNull);

    final cam = await env.product('Camera', cost: 4000, price: 6000);
    final sup = await env.supplier();
    await app.purchases.create(supplierId: sup.id, date: env.clock.now, lines: [PurchaseLineInput(productId: cam.id, qty: q(3), unitCost: rs(4000))]);
    final ali = await env.customer('Ali');
    final d = app.sales.newDraft().copyWith(customerId: ali.id, customerName: ali.name, items: [app.sales.lineFor(env.reload(cam.id))]);
    await app.sales.complete(d.copyWith(paidAtSale: d.total));
    final ledgerBefore = env.app.ctx.store.values(Boxes.ledger).length;

    expect(app.parties.hasHistory(PartyKind.customer, ali.id), isTrue);
    expect(await app.parties.deleteOrArchive(PartyKind.customer, ali.id), isTrue);
    final archived = app.parties.byId(PartyKind.customer, ali.id)!;
    expect(archived.active, isFalse);
    expect(app.parties.list(PartyKind.customer).any((p) => p.id == ali.id), isFalse);
    expect(app.parties.list(PartyKind.customer, includeInactive: true).any((p) => p.id == ali.id), isTrue);
    expect(env.app.ctx.store.values(Boxes.ledger).length, ledgerBefore);
    expect(app.sales.list().length, 1);

    // A supplier with purchases is archived too.
    expect(await app.parties.deleteOrArchive(PartyKind.supplier, sup.id), isTrue);
    expect(app.parties.byId(PartyKind.supplier, sup.id)!.active, isFalse);

    await app.parties.restore(PartyKind.customer, ali.id);
    expect(app.parties.byId(PartyKind.customer, ali.id)!.active, isTrue);
  });

  test('customer with only an opening balance is archived, not erased', () async {
    final c = await env.app.parties.create(kind: PartyKind.customer, name: 'Old dues', openingBalance: rs(1500));
    expect(await env.app.parties.deleteOrArchive(PartyKind.customer, c.id), isTrue);
    expect(env.app.parties.byId(PartyKind.customer, c.id)!.balance, rs(1500));
  });

  test('technician: holding material -> refused; with history -> archived (login off); none -> deleted', () async {
    final app = env.app;
    final cable = await env.product('Cable');
    final sup = await env.supplier();
    await app.purchases.create(supplierId: sup.id, date: env.clock.now, lines: [PurchaseLineInput(productId: cable.id, qty: q(10), unitCost: rs(100))]);
    final waqas = await app.technicians.create(name: 'Waqas', phone: '0333', username: 'waqas', password: 'waqas123');
    await app.technicians.issue(technicianId: waqas.id, lines: [IssueLine(productId: cable.id, qty: q(4))]);
    await expectLater(() => app.technicians.deleteOrArchive(waqas.id), throwsA(isA<BusinessException>()));
    expect(app.technicians.technicians(includeInactive: true).any((t) => t.id == waqas.id), isTrue);

    await app.technicians.returnMaterial(technicianId: waqas.id, productId: cable.id, qty: q(4), type: TechTxnType.returnUnused);
    expect(await app.technicians.deleteOrArchive(waqas.id), isTrue);
    final t = app.technicians.technicians(includeInactive: true).firstWhere((t) => t.id == waqas.id);
    expect(t.active, isFalse);
    expect(app.auth.findByUsername('waqas')!.active, isFalse);
    expect(app.technicians.history(technicianId: waqas.id).isNotEmpty, isTrue);

    final idle = await app.technicians.create(name: 'New Helper', phone: '0300');
    expect(await app.technicians.deleteOrArchive(idle.id), isFalse);
    expect(app.technicians.technicians(includeInactive: true).any((t) => t.id == idle.id), isFalse);
  });

  test('quotation: deletable, but a converted quotation is kept', () async {
    final app = env.app;
    final p = await env.product('NVR');
    final sup = await env.supplier();
    await app.purchases.create(supplierId: sup.id, date: env.clock.now, lines: [PurchaseLineInput(productId: p.id, qty: q(2), unitCost: rs(1000))]);
    final a = await app.quotations.save(app.quotations.newDraft(customerName: 'Hotel').copyWith(items: [QuotationItem(productId: p.id, name: p.name, qty: q(1), unitPrice: rs(1500))]));
    await app.quotations.delete(a.id);
    expect(app.quotations.byId(a.id), isNull);

    final b = await app.quotations.save(app.quotations.newDraft(customerName: 'School').copyWith(items: [QuotationItem(productId: p.id, name: p.name, qty: q(1), unitPrice: rs(1500))]));
    await app.quotations.setStatus(b.id, QuotationStatus.approved);
    await app.quotations.convertToInvoice(b.id);
    await expectLater(() => app.quotations.delete(b.id), throwsA(isA<BusinessException>()));
    expect(app.quotations.byId(b.id), isNotNull);
  });

  test('product and category: history -> archive, empty -> delete; completed invoice is only cancelled', () async {
    final app = env.app;
    final cat = await app.catalog.saveCategory('Cameras');
    final unused = await env.product('Unused item');
    expect(await app.catalog.deleteOrArchive(unused.id), isFalse);

    final cam = await env.product('Camera', cost: 4000, price: 6000);
    final sup = await env.supplier();
    await app.purchases.create(supplierId: sup.id, date: env.clock.now, lines: [PurchaseLineInput(productId: cam.id, qty: q(2), unitCost: rs(4000))]);
    final d = app.sales.newDraft().copyWith(items: [app.sales.lineFor(env.reload(cam.id))]);
    final sale = await app.sales.complete(d.copyWith(paidAtSale: d.total));
    expect(await app.catalog.deleteOrArchive(cam.id), isTrue);
    expect(env.reload(cam.id).archived, isTrue);

    // Completed invoices cannot be erased, only cancelled (with a reason).
    final draft = await app.sales.saveDraft(app.sales.newDraft());
    await app.sales.deleteDraft(draft.id);
    expect(app.sales.byId(draft.id), isNull);
    await expectLater(() => app.sales.deleteDraft(sale.id), throwsA(isA<BusinessException>()));
    await expectLater(() => app.sales.cancel(sale.id, ''), throwsA(isA<ValidationException>()));
    await app.sales.cancel(sale.id, 'wrong customer');
    expect(app.sales.byId(sale.id)!.status, DocStatus.cancelled);

    await app.catalog.deleteCategory(cat.id);
    expect(app.catalog.categories().any((c) => c.id == cat.id), isFalse);
  });
}
