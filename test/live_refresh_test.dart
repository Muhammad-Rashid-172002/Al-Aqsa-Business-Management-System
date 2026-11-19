// Instant refresh across every module.
//
// Every page and detail dialog watches `liveServicesProvider`. This test
// drives the real provider (not a copy) with a real AppServices and checks,
// module by module, that each kind of change:
//   1. notifies the watching screens (the bug fixed here: the old plain
//      Provider returned the same object and so never notified), and
//   2. is visible in what those screens read: lists, search, filters,
//      sorting, stock, serial status, balances, ledgers and P&L figures.
import 'package:al_aqsa_cctv/core/money.dart';
import 'package:al_aqsa_cctv/data/store/data_store.dart';
import 'package:al_aqsa_cctv/domain/models/documents.dart';
import 'package:al_aqsa_cctv/domain/models/operations.dart';
import 'package:al_aqsa_cctv/domain/models/party.dart';
import 'package:al_aqsa_cctv/domain/models/product.dart';
import 'package:al_aqsa_cctv/domain/models/user.dart';
import 'package:al_aqsa_cctv/domain/services/app_services.dart';
import 'package:al_aqsa_cctv/domain/services/catalog_service.dart';
import 'package:al_aqsa_cctv/domain/services/purchase_service.dart';
import 'package:al_aqsa_cctv/domain/services/report_service.dart';
import 'package:al_aqsa_cctv/domain/services/report_tables.dart';
import 'package:al_aqsa_cctv/domain/services/technician_service.dart';
import 'package:al_aqsa_cctv/ui/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

/// A stand-in for an on-screen widget: listens to liveServicesProvider
/// exactly like `ref.watch` does and counts rebuild notifications.
class _Screen {
  final ProviderContainer c;
  int rebuilds = 0;
  _Screen(this.c) {
    c.listen<AppServices>(liveServicesProvider, (_, __) => rebuilds++, fireImmediately: false);
  }
  AppServices get app => c.read(liveServicesProvider);
}

final _report = <String>[];

Future<void> _settle() async {
  for (var i = 0; i < 3; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Runs [action], then checks the screen was notified and [visible] holds
/// on the data the screen reads.
Future<void> _step(_Screen s, String module, String change, Future<void> Function() action, bool Function(AppServices app) visible) async {
  final before = s.rebuilds;
  await action();
  await _settle();
  final notified = s.rebuilds > before;
  final ok = visible(s.app);
  _report.add('${notified && ok ? 'PASS' : 'FAIL'}  ${module.padRight(16)} $change${notified ? '' : '  [screen NOT notified]'}${ok ? '' : '  [data NOT visible/accurate]'}');
  expect(notified, isTrue, reason: '$module: $change did not notify the screen');
  expect(ok, isTrue, reason: '$module: $change not reflected in the data shown');
}

void main() {
  test('every module refreshes instantly and stays accurate after each kind of change', () async {
    final env = await TestEnv.create();
    final c = ProviderContainer(overrides: [servicesProvider.overrideWithValue(env.app)]);
    try {
      await _run(env, _Screen(c));
    } finally {
      c.dispose();
      await env.dispose();
      // Module-wise verification report.
      // ignore: avoid_print
      print('\n──── Instant-refresh verification (module-wise) ────\n${_report.join('\n')}\n');
    }
  });

  test('error-log-only writes do not rebuild screens (no needless work)', () async {
    final env = await TestEnv.create();
    final c = ProviderContainer(overrides: [servicesProvider.overrideWithValue(env.app)]);
    try {
      final s = _Screen(c);
      s.app; // start listening
      await _settle();
      final before = s.rebuilds;
      await env.app.ctx.store.commit([WriteOp(Boxes.errorLog, 'e1', {'id': 'e1', 'message': 'x'})]);
      await _settle();
      expect(s.rebuilds, before);
      await env.app.parties.create(kind: PartyKind.customer, name: 'Z');
      await _settle();
      expect(s.rebuilds, before + 1);
    } finally {
      c.dispose();
      await env.dispose();
    }
  });
}

Future<void> _run(TestEnv env, _Screen s) async {
  final app = env.app;
  s.app; // the screen is shown
  await _settle();
  env.clock.now = DateTime(2026, 5, 4, 10);
  final may = DateRange(DateTime(2026, 5, 1), DateTime(2026, 5, 31, 23, 59, 59));

  // ── Categories ──
  late ProductCategory cat;
  await _step(s, 'Categories', 'add', () async => cat = await app.catalog.saveCategory('Cameras'), (a) => a.catalog.categories().any((x) => x.name == 'Cameras'));
  await _step(s, 'Categories', 'rename', () => app.catalog.saveCategory('IP Cameras', id: cat.id), (a) => a.catalog.categories().single.name == 'IP Cameras');

  // ── Products ──
  late Product cam, nvr, cable;
  await _step(s, 'Products', 'add (search finds it)', () async {
    cam = await app.catalog.create(ProductInput(name: 'Dome Camera 4MP', categoryId: cat.id, purchasePrice: rs(4000), sellingPrice: rs(6000), minStock: Qty.units(2)));
  }, (a) => a.catalog.search('dome').single.id == cam.id && a.catalog.search('', categoryId: cat.id).length == 1);
  await _step(s, 'Products', 'add 2 more (sorted by name)', () async {
    nvr = await env.product('NVR 8CH', cost: 9000, price: 12000, serial: true, brand: 'Hik');
    cable = await env.product('Cable Roll', cost: 100, price: 150);
  }, (a) => a.catalog.products().map((p) => p.name).toList().join('|') == 'Cable Roll|Dome Camera 4MP|NVR 8CH');
  await _step(s, 'Products', 'edit price', () => app.catalog.update(cam.id, ProductInput(name: 'Dome Camera 4MP', categoryId: cat.id, purchasePrice: rs(4000), sellingPrice: rs(6500), minStock: Qty.units(2))),
      (a) => a.catalog.byId(cam.id)!.sellingPrice == rs(6500));
  final spare = await env.product('Spare Bracket');
  await _settle();
  await _step(s, 'Products', 'delete (no history)', () => app.catalog.deleteOrArchive(spare.id), (a) => a.catalog.byId(spare.id) == null && a.catalog.search('bracket').isEmpty);

  // ── Suppliers / Purchases / Stock / Serials ──
  late Party sup;
  await _step(s, 'Suppliers', 'add', () async => sup = await env.supplier('Hik Distributor'), (a) => a.parties.list(PartyKind.supplier, query: 'hik').single.id == sup.id);
  late Purchase p1;
  await _step(s, 'Purchases', 'complete purchase (part paid)', () async {
    p1 = await app.purchases.create(supplierId: sup.id, date: env.clock.now, paid: rs(20000), lines: [
      PurchaseLineInput(productId: cam.id, qty: q(5), unitCost: rs(4000)),
      PurchaseLineInput(productId: nvr.id, qty: q(3), unitCost: rs(9000), serials: const ['NV1', 'NV2', 'NV3']),
      PurchaseLineInput(productId: cable.id, qty: q(20), unitCost: rs(100)),
    ]);
  }, (a) => a.purchases.list(supplierId: sup.id).single.id == p1.id);
  _check(s, 'Stock', 'quantities after purchase', (a) => a.catalog.byId(cam.id)!.stockQty == q(5) && a.catalog.byId(nvr.id)!.stockQty == q(3));
  _check(s, 'Serial Numbers', 'units in stock after purchase', (a) => a.serials.inStockFor(nvr.id).length == 3);
  _check(s, 'Suppliers', 'balance = 20000+27000+2000-20000', (a) => a.parties.byId(PartyKind.supplier, sup.id)!.balance == rs(29000));
  await _step(s, 'Payments', 'pay supplier', () => app.parties.addPayment(kind: PartyKind.supplier, partyId: sup.id, amount: rs(9000), method: PaymentMethod.cash),
      (a) => a.parties.byId(PartyKind.supplier, sup.id)!.balance == rs(20000) && a.parties.statement(PartyKind.supplier, sup.id).closingBalance == rs(20000));
  await _step(s, 'Stock', 'adjust count', () => app.inventory.adjustTo(cable.id, q(18), 'Count'), (a) => a.catalog.byId(cable.id)!.stockQty == q(18));

  // ── Customers / POS / Sales ──
  late Party ali;
  await _step(s, 'Customers', 'add', () async => ali = await app.parties.create(kind: PartyKind.customer, name: 'Ali Traders', phone: '03001234567'),
      (a) => a.parties.list(PartyKind.customer, query: 'ali').single.id == ali.id);
  await _step(s, 'Customers', 'edit phone (search by new phone)', () => app.parties.update(app.parties.byId(PartyKind.customer, ali.id)!.copyWith(phone: '03219876543')),
      (a) => a.parties.list(PartyKind.customer, query: '0321').single.id == ali.id);
  late Sale s1;
  await _step(s, 'POS / Sales', 'complete sale on credit', () async {
    final d = app.sales.newDraft().copyWith(customerId: ali.id, customerName: ali.name, invoiceDiscount: rs(500), items: [
      app.sales.lineFor(env.reload(cam.id), qty: q(2)),
      app.sales.lineFor(env.reload(nvr.id), serials: const ['NV1']),
    ]);
    s1 = await app.sales.complete(d.copyWith(paidAtSale: rs(10000)));
  }, (a) => a.sales.list(customerId: ali.id).single.id == s1.id);
  _check(s, 'Stock', 'sold units left stock', (a) => a.catalog.byId(cam.id)!.stockQty == q(3) && a.catalog.byId(nvr.id)!.stockQty == q(2));
  _check(s, 'Serial Numbers', 'NV1 now sold to Ali', (a) => a.serials.search(query: 'NV1').single.customerId == ali.id && a.serials.inStockFor(nvr.id).length == 2);
  // 2 x 6500 + 12000 - 500 = 24500; paid 10000 -> owes 14500.
  _check(s, 'Customers', 'balance 14500 (ledger = cache)', (a) => a.parties.byId(PartyKind.customer, ali.id)!.balance == rs(14500) && a.parties.statement(PartyKind.customer, ali.id).closingBalance == rs(14500));
  _check(s, 'Customers', '"with balance" filter', (a) => a.parties.list(PartyKind.customer).where((p) => !p.balance.isZero).length == 1);
  _check(s, 'Profit & Loss', 'net sales 24500, gross profit 24500-17000', (a) {
    final f = a.reports.financials(may);
    return f.netSales == rs(24500) && f.cogs == rs(17000) && f.grossProfit == rs(7500);
  });
  late Payment pay;
  await _step(s, 'Payments', 'receive customer payment', () async => pay = await app.parties.addPayment(kind: PartyKind.customer, partyId: ali.id, amount: rs(4500), method: PaymentMethod.cash),
      (a) => a.parties.byId(PartyKind.customer, ali.id)!.balance == rs(10000) && a.parties.payments(kind: PartyKind.customer, partyId: ali.id).any((p) => p.id == pay.id));
  await _step(s, 'Ledgers', 'void payment', () => app.parties.voidPayment(pay.id, 'entered twice'),
      (a) => a.parties.byId(PartyKind.customer, ali.id)!.balance == rs(14500) && a.parties.payments().firstWhere((p) => p.id == pay.id).voided);
  _check(s, 'Profit & Loss', 'cash received = 10000 after void', (a) => a.reports.financials(may).cashReceived == rs(10000));

  // ── Returns ──
  await _step(s, 'Returns', 'customer returns 1 camera (account credit)', () => app.sales.createReturn(saleId: s1.id, reason: 'extra', lines: [ReturnLineInput(productId: cam.id, qty: q(1))], refundMode: RefundMode.accountCredit),
      (a) => a.sales.returns().length == 1 && a.catalog.byId(cam.id)!.stockQty == q(4));
  _check(s, 'Customers', 'balance reduced by the return', (a) => a.parties.byId(PartyKind.customer, ali.id)!.balance < rs(14500));
  _check(s, 'Profit & Loss', 'returns deducted from net sales', (a) => a.reports.financials(may).salesReturns.isPositive);
  await _step(s, 'Returns', 'return 2 cable rolls to supplier', () => app.purchases.createReturn(purchaseId: p1.id, reason: 'cut', lines: [ReturnLineInput(productId: cable.id, qty: q(2))]),
      (a) => a.purchases.returns().length == 1 && a.catalog.byId(cable.id)!.stockQty == q(16) && a.parties.byId(PartyKind.supplier, sup.id)!.balance == rs(19800));

  // ── Cancel a sale ──
  late Sale s2;
  final d2 = app.sales.newDraft().copyWith(items: [app.sales.lineFor(env.reload(cable.id), qty: q(2))]);
  s2 = await app.sales.complete(d2.copyWith(paidAtSale: d2.total));
  await _settle();
  await _step(s, 'Sales', 'cancel invoice (stock back)', () => app.sales.cancel(s2.id, 'mistake'),
      (a) => a.sales.byId(s2.id)!.status == DocStatus.cancelled && a.catalog.byId(cable.id)!.stockQty == q(16));

  // ── Technicians ──
  late Employee tech;
  await _step(s, 'Technicians', 'add', () async => tech = await app.technicians.create(name: 'Waqas', phone: '0333'), (a) => a.technicians.technicians().any((t) => t.id == tech.id));
  await _step(s, 'Technicians', 'issue material', () => app.technicians.issue(technicianId: tech.id, lines: [IssueLine(productId: cable.id, qty: q(5))]),
      (a) => a.technicians.summary(tech.id).remaining == q(5) && a.catalog.byId(cable.id)!.stockQty == q(11));
  await _step(s, 'Technicians', 'return unused', () => app.technicians.returnMaterial(technicianId: tech.id, productId: cable.id, qty: q(5), type: TechTxnType.returnUnused),
      (a) => a.technicians.summary(tech.id).remaining == q(0) && a.catalog.byId(cable.id)!.stockQty == q(16));
  await _step(s, 'Technicians', 'archive', () => app.technicians.deleteOrArchive(tech.id),
      (a) => !a.technicians.technicians().any((t) => t.id == tech.id) && a.technicians.technicians(includeInactive: true).any((t) => t.id == tech.id));
  await _step(s, 'Technicians', 'restore', () => app.technicians.update(app.technicians.technicians(includeInactive: true).firstWhere((t) => t.id == tech.id).copyWith(active: true)),
      (a) => a.technicians.technicians().any((t) => t.id == tech.id));

  // ── Warranty / Repairs ──
  await _step(s, 'Warranty', 'open claim on sold NV1', () => app.warranty.openClaim('NV1', 'No video'), (a) => a.warranty.claims().length == 1);
  late RepairJob job;
  await _step(s, 'Repairs', 'receive device', () async => job = await app.repairs.receive(customerName: 'Walk-in', productName: 'DVR', reportedIssue: 'No power'),
      (a) => a.repairs.list(openOnly: true).any((j) => j.id == job.id));
  await _step(s, 'Repairs', 'status -> repaired', () => app.repairs.updateStatus(job.id, RepairStatus.repaired, serviceCharges: rs(1500)),
      (a) => a.repairs.list().firstWhere((j) => j.id == job.id).status == RepairStatus.repaired);
  await _step(s, 'Repairs', 'deliver (paid)', () => app.repairs.deliver(job.id, paid: rs(1500)),
      (a) => !a.repairs.list(openOnly: true).any((j) => j.id == job.id) && a.reports.financials(may).repairCharges == rs(1500));

  // ── Quotations ──
  late Quotation qt;
  await _step(s, 'Quotations', 'add', () async => qt = await app.quotations.save(app.quotations.newDraft(customerId: ali.id, customerName: ali.name).copyWith(items: [QuotationItem(productId: cam.id, name: cam.name, qty: q(1), unitPrice: rs(6500))])),
      (a) => a.quotations.list().any((x) => x.id == qt.id));
  await _step(s, 'Quotations', 'approve', () => app.quotations.setStatus(qt.id, QuotationStatus.approved), (a) => a.quotations.byId(qt.id)!.status == QuotationStatus.approved);
  await _step(s, 'Quotations', 'delete', () => app.quotations.delete(qt.id), (a) => a.quotations.byId(qt.id) == null);

  // ── Expenses / Profit & Loss ──
  final gpBefore = app.reports.financials(may).grossProfit;
  late String expId;
  await _step(s, 'Expenses', 'add rent', () async => expId = (await app.expenses.create(category: 'Shop rent', title: 'May rent', amount: rs(30000), date: DateTime(2026, 5, 1))).id,
      (a) => a.reports.financials(may).expenses == rs(30000) && a.reports.financials(may).netOperatingProfit == a.reports.financials(may).grossProfit + a.reports.financials(may).repairProfit - rs(30000));
  await _step(s, 'Expenses', 'edit amount', () => app.expenses.update(expId, category: 'Shop rent', title: 'May rent', amount: rs(32000), date: DateTime(2026, 5, 1)),
      (a) => a.reports.financials(may).expenses == rs(32000) && a.reports.financials(may).grossProfit == gpBefore);
  await _step(s, 'Expenses', 'delete', () => app.expenses.delete(expId), (a) => a.reports.financials(may).expenses == const Money.zero() && a.expenses.list().isEmpty);
  await _step(s, 'Expenses', 'restore', () => app.expenses.restore(expId), (a) => a.reports.financials(may).expenses == rs(32000));

  // ── Archive / restore with history ──
  await _step(s, 'Customers', 'archive (has invoices)', () => app.parties.deleteOrArchive(PartyKind.customer, ali.id),
      (a) => a.parties.list(PartyKind.customer).isEmpty && a.parties.list(PartyKind.customer, includeInactive: true).single.id == ali.id && a.parties.byId(PartyKind.customer, ali.id)!.balance.isPositive);
  await _step(s, 'Customers', 'restore', () => app.parties.restore(PartyKind.customer, ali.id), (a) => a.parties.list(PartyKind.customer).single.id == ali.id);
  await _step(s, 'Products', 'archive (has history)', () => app.catalog.deleteOrArchive(cable.id),
      (a) => a.catalog.search('cable').isEmpty && a.catalog.search('cable', includeArchived: true).single.stockQty == q(16));
  await _step(s, 'Products', 'restore', () => app.catalog.restore(cable.id), (a) => a.catalog.search('cable').single.id == cable.id);

  // ── Reports / Dashboard ──
  _check(s, 'Reports', 'Sales Register: completed invoice in, cancelled out', (a) {
    final t = ReportBuilder(a).build(ReportKind.salesInvoices, may);
    return t.rows.length == 1 && t.rows.single.first == s1.number && !t.rows.any((r) => r.first == s2.number);
  });
  _check(s, 'Reports', 'Customer Outstanding = ledger balance', (a) {
    final t = ReportBuilder(a).build(ReportKind.receivables, may);
    return t.rows.length == 1 && t.rows.single.contains(a.parties.byId(PartyKind.customer, ali.id)!.balance.paisa / 100);
  });
  _check(s, 'Reports', 'Product Stock matches stock', (a) {
    final t = ReportBuilder(a).build(ReportKind.stockCurrent, may);
    return t.rows.any((r) => r.contains('Cable Roll'));
  });

  // ── Settings ──
  await _step(s, 'Settings', 'change business name', () => app.settings.save({'businessName': 'AL-AQSA CCTV & SOLAR SYSTEM (Test)'}), (a) => a.ctx.settings.businessName.endsWith('(Test)'));
}

/// A check on data already changed by the previous step (no new action).
void _check(_Screen s, String module, String what, bool Function(AppServices) ok) {
  final r = ok(s.app);
  _report.add('${r ? 'PASS' : 'FAIL'}  ${module.padRight(16)} $what');
  expect(r, isTrue, reason: '$module: $what');
}
