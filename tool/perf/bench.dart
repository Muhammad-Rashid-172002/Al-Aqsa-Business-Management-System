// ignore_for_file: avoid_print
// Performance benchmark: runs the app's real services on a real Hive
// database, timing what each screen / action does (no Flutter engine needed).
// The database is COPIED to a temp folder first; the source is never written.
//
//   dart run tool/perf/seed.dart  <empty-dir> 10000 50000 10000
//   dart run tool/perf/bench.dart <that-dir> large
//
// "UI freeze" = longest time the main isolate could not run (window frozen).
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:al_aqsa_cctv/core/qty.dart';
import 'package:al_aqsa_cctv/data/migrations.dart';
import 'package:al_aqsa_cctv/data/store/hive_store.dart';
import 'package:al_aqsa_cctv/domain/models/documents.dart';
import 'package:al_aqsa_cctv/domain/models/operations.dart';
import 'package:al_aqsa_cctv/domain/models/party.dart';
import 'package:al_aqsa_cctv/domain/services/app_services.dart';
import 'package:al_aqsa_cctv/domain/services/report_service.dart';
import 'package:al_aqsa_cctv/domain/services/report_tables.dart';
import 'package:al_aqsa_cctv/export/tabular.dart';
import 'package:al_aqsa_cctv/printing/pdf_docs.dart';

Future<List<int>> encode(ExportTable t, String f) => Isolate.run(() => f == 'csv' ? buildCsv(t).codeUnits : buildXlsx([t]));

final results = <String, double>{};
void rssMark(String at) { results['RSS MB: $at'] = ProcessInfo.currentRss / 1048576; print('RSS $at: ${mb(ProcessInfo.currentRss)}'); }
String mb(int b) => '${(b / 1048576).toStringAsFixed(0)} MB';

/// Longest stretch (ms) the main isolate could not run anything (= the UI
/// would be frozen) while [f] runs: a 1 ms ticker records its largest gap.
Future<double> freeze(String name, Object? Function() f) async {
  var last = Stopwatch()..start();
  var maxGap = 0;
  final tick = Timer.periodic(const Duration(milliseconds: 1), (_) {
    final g = last.elapsedMicroseconds;
    if (g > maxGap) maxGap = g;
    last = Stopwatch()..start();
  });
  await Future<void>.delayed(const Duration(milliseconds: 5));
  maxGap = 0;
  last = Stopwatch()..start();
  final sw = Stopwatch()..start();
  final r = f();
  if (r is Future) await r;
  final wall = sw.elapsedMicroseconds / 1000;
  final g = last.elapsedMicroseconds;
  if (g > maxGap) maxGap = g;
  tick.cancel();
  final ms = maxGap / 1000;
  results['freeze: $name'] = ms;
  results['wall: $name'] = wall;
  print('${'UI freeze: $name'.padRight(46)} ${ms.toStringAsFixed(1).padLeft(9)} ms   (total ${wall.toStringAsFixed(0)} ms)');
  return ms;
}

/// Median of [n] runs, in ms.
Future<double> timeit(String name, Object? Function() f, {int n = 5}) async {
  final xs = <double>[];
  for (var i = 0; i < n; i++) {
    final sw = Stopwatch()..start();
    final r = f();
    if (r is Future) await r;
    xs.add(sw.elapsedMicroseconds / 1000);
  }
  xs.sort();
  final m = xs[xs.length ~/ 2];
  results[name] = m;
  print('${name.padRight(46)} ${m.toStringAsFixed(1).padLeft(9)} ms');
  return m;
}

Future<void> main(List<String> a) async {
  final src = Directory(a[0]);
  final work = Directory('${Directory.systemTemp.path}/bench_work_${a[1]}');
  if (work.existsSync()) work.deleteSync(recursive: true);
  work.createSync();
  for (final f in src.listSync().whereType<File>()) {
    f.copySync('${work.path}/${f.uri.pathSegments.last}');
  }
  final rss0 = ProcessInfo.currentRss;
  print('== ${a[1]}  (RSS before open ${mb(rss0)})');

  // ── Startup: what main() + splash do before the Dashboard can show.
  final sw = Stopwatch()..start();
  final store = await HiveStore.open(work.path);
  final tOpen = sw.elapsedMicroseconds / 1000;
  await Migrator.run(store);
  final app = AppServices(store, localBackupDir: '${work.path}/backups');
  await app.auth.openLocalSession();
  final tStart = sw.elapsedMicroseconds / 1000;
  results['startup: open Hive (all boxes)'] = tOpen;
  results['startup: total until session ready'] = tStart;
  print('${'startup: open Hive (all boxes)'.padRight(46)} ${tOpen.toStringAsFixed(1).padLeft(9)} ms');
  print('${'startup: total until session ready'.padRight(46)} ${tStart.toStringAsFixed(1).padLeft(9)} ms');
  print('RSS after open: ${mb(ProcessInfo.currentRss)}');

  final now = DateTime(2026, 11, 16, 12);
  final month = DateRange(DateTime(2026, 11, 1), DateTime(2026, 11, 30, 23, 59, 59));
  final year = DateRange(DateTime(2025, 11, 17), now);

  // ── Dashboard build (exact calls of DashboardPage.build + top bar notifications).
  Object? dashboard() {
    app.reports.profit(month);
    app.reports.salesTotal(DateRange(DateTime(2026, 11, 16), DateTime(2026, 11, 16, 23, 59, 59)));
    app.reports.salesTotal(month);
    app.reports.purchaseTotal(month);
    final stock = app.reports.stock();
    app.inventory.stockValuation();
    stock.where((r) => r.product.isLowStock).length;
    app.reports.monthly(6);
    app.reports.productSales(month).take(6).toList();
    app.reports.stockValueByCategory();
    app.sales.list(status: DocStatus.completed).take(6).toList();
    app.purchases.list(includeCancelled: false).take(6).toList();
    app.technicians.holdings();
    app.repairs.list(openOnly: true);
    app.warranty.claims();
    app.parties.totalReceivables();
    app.parties.totalPayables();
    app.parties.payments(from: month.from, to: month.to);
    app.sales.returns(from: month.from, to: month.to);
    app.purchases.returns(from: month.from, to: month.to);
    return null;
  }

  Object? topBar() {
    app.inspections.list();
    app.backup.lastBackupAt;
    app.ctx.settings;
    app.catalog.products().where((p) => p.isLowStock || p.isOutOfStock).length;
    app.repairs.list(openOnly: true);
    app.warranty.expiringWithin(30);
    return null;
  }

  await timeit('startup: warm-up behind splash', () => app.warmUp(), n: 1);
  final tFirstDash = await timeit('dashboard: first build (after splash)', dashboard, n: 1);
  await timeit('dashboard: rebuild', dashboard);
  // Per-call breakdown of the dashboard
  for (final e in <String, Object? Function()>{
    'dash.profit(month)': () => app.reports.profit(month),
    'dash.salesTotal(month)': () => app.reports.salesTotal(month),
    'dash.purchaseTotal(month)': () => app.reports.purchaseTotal(month),
    'dash.stock()': () => app.reports.stock(),
    'dash.stockValuation()': () => app.inventory.stockValuation(),
    'dash.monthly(6)': () => app.reports.monthly(6),
    'dash.productSales(month)': () => app.reports.productSales(month),
    'dash.stockValueByCategory()': () => app.reports.stockValueByCategory(),
    'dash.sales.list(completed)': () => app.sales.list(status: DocStatus.completed),
    'dash.purchases.list()': () => app.purchases.list(includeCancelled: false),
    'dash.holdings()': () => app.technicians.holdings(),
    'dash.totalReceivables()': () => app.parties.totalReceivables(),
    'dash.payments(month)': () => app.parties.payments(from: month.from, to: month.to),
  }.entries) {
    await timeit(e.key, e.value, n: 3);
  }
  await timeit('top bar notifications (every change + 20 s)', topBar);
  results['_dash_first'] = tFirstDash;

  rssMark('after dashboard');
  // ── Product search (Products page / POS search / global search)
  await timeit('product search "dome" (full list filter)', () => app.catalog.search('dome'));
  await timeit('product search "model 9876"', () => app.catalog.search('model 9876'));
  // ── Scanner
  final nP = app.catalog.products().length;
  final code = 'AQ${(nP ~/ 2).toString().padLeft(8, '0')}';
  final sn = 'SN${(nP ~/ 10).toString().padLeft(9, '0')}';
  if (app.catalog.lookup(code) == null || app.catalog.lookup(sn)?.serial == null) throw StateError('bench codes missing');
  await timeit('barcode scan (indexed barcode)', () => app.catalog.lookup(code), n: 21);
  await timeit('barcode scan (serial number)', () => app.catalog.lookup(sn), n: 21);
  await timeit('scan: unknown code (falls back to SKU scan)', () => app.catalog.lookup('ZZ-NOT-FOUND'), n: 5);

  // ── POS bill update: add a product and recompute totals for a 20-line bill.
  final prods = app.catalog.products().where((p) => !p.requiresSerial).take(20).toList();
  var draft = app.sales.newDraft();
  await timeit('POS: add product to 20-line bill + totals', () {
    final p = app.catalog.byId(prods[draft.items.length % prods.length].id)!;
    draft = draft.copyWith(items: [...draft.items.take(19), SaleItem(productId: p.id, name: p.name, qty: Qty.units(1), unitPrice: p.sellingPrice)]);
    return draft.total;
  }, n: 21);

  // ── Complete a 3-line cash sale (FIFO, ledger, movements, journal + flush).
  var k = 0;
  await timeit('POS: complete 3-line sale (commit to disk)', () async {
    final items = [for (var i = 0; i < 3; i++) prods[(k * 3 + i) % prods.length]];
    k++;
    final d = app.sales.newDraft().copyWith(items: [for (final p in items) SaleItem(productId: p.id, name: p.name, qty: Qty.units(1), unitPrice: p.sellingPrice)]);
    final total = d.total;
    return app.sales.complete(d.copyWith(paidAtSale: total));
  });

  // ── Navigation: data each page's build() loads.
  await timeit('page: Products (all products)', () => app.catalog.products());
  await timeit('page: Invoices (all sales)', () => app.sales.list());
  await timeit('page: Customers', () => app.parties.list(PartyKind.customer));
  await timeit('page: Serial Numbers', () => app.serials.search());
  await timeit('page: Inventory stock', () => app.reports.stock());
  await timeit('page: Ledgers (month payments)', () => app.parties.payments(from: month.from, to: month.to));
  final big = app.parties.list(PartyKind.customer).reduce((a, b) => a.balance > b.balance ? a : b);
  await timeit('customer ledger statement (largest)', () => app.parties.statement(PartyKind.customer, big.id));

  rssMark('after page navigation');
  // ── Reports (1 year) + exports
  final rb = ReportBuilder(app);
  final swr = Stopwatch()..start();
  ExportTable? biggest;
  for (final kind in ReportKind.values) {
    final t = rb.build(kind, year);
    if (biggest == null || t.rows.length > biggest.rows.length) biggest = t;
  }
  results['reports: all 29 kinds (1 year)'] = swr.elapsedMicroseconds / 1000;
  print('${'reports: all 29 kinds (1 year)'.padRight(46)} ${results['reports: all 29 kinds (1 year)']!.toStringAsFixed(1).padLeft(9)} ms');
  await timeit('report: sales register (1 year)', () => rb.build(ReportKind.values.first, year), n: 3);
  print('largest report: "${biggest!.title}" ${biggest.rows.length} rows');
  await timeit('export: XLSX of largest report', () => buildXlsx([biggest!]), n: 3);
  await timeit('export: CSV of largest report', () => buildCsv(biggest!), n: 3);
  final pdfTable = ExportTable(biggest.title, biggest.headers, biggest.rows.take(2000).toList());
  await timeit('export: PDF (2,000 rows)', () => reportPdfInBackground(const AppSettings(), pdfTable), n: 1);
  await timeit('backup now (zip all data)', () => app.backup.backupNow(), n: 1);
  rssMark('after reports + exports');
  await freeze('PDF (2,000 rows)', () => reportPdfInBackground(const AppSettings(), pdfTable));
  await freeze('XLSX export (largest report)', () => encode(biggest!, 'xlsx'));
  await freeze('CSV export (largest report)', () => encode(biggest!, 'csv'));
  await freeze('backup now', () => app.backup.backupNow());
  await freeze('dashboard rebuild', dashboard);
  await freeze('reports: all 29 kinds (1 year)', () { for (final kind in ReportKind.values) { rb.build(kind, year); } return null; });
  print('RSS at end: ${mb(ProcessInfo.currentRss)}');
  results['_rss_end_mb'] = ProcessInfo.currentRss / 1048576;
  final out = File('${Directory.systemTemp.path}/bench_${a[1]}.tsv');
  out.writeAsStringSync(results.entries.map((e) => '${e.key}\t${e.value.toStringAsFixed(2)}').join('\n'));
  await store.close();
  work.deleteSync(recursive: true);
  exit(0);
}
