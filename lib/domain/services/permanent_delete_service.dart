// Permanent deletion with full cascade: a record AND everything that
// belongs only to it is erased from the current database, in one atomic
// commit, then verified.
//
// Rules per record type (owner's choices: stock stays where it physically is):
//  * Customer — erases the profile, ALL its invoices (draft, completed,
//    cancelled), all its payments, ledger entries, returns, quotations,
//    repair jobs and warranty claims. Goods on those invoices stay sold:
//    stock quantities do not change; sold serial units stay "Sold" and lose
//    the link to the customer/invoice; stock movements stay (stock history)
//    without the link. Technician installations billed on those invoices
//    stay "invoiced" so they are never billed again.
//  * Supplier — erases the supplier, ALL its purchases, payments, ledger
//    entries and supplier returns. Stock received stays in stock with its
//    cost: each purchase's cost batch is kept under a new anonymous batch
//    id, so every serial keeps its own batch cost for profit.
//  * Product — erases the product with its own serial units, cost batches,
//    stock movements, barcode index rows, zero technician holdings and its
//    image (if not shared). Refused while it appears on any invoice,
//    purchase, return, quotation, technician, repair or warranty record:
//    those documents belong to other customers/suppliers.
//  * Technician — erases the technician, its material records that no
//    invoice depends on, zero holdings, and its login (if never used) with
//    login history; a used login is kept, deactivated and anonymised.
//    Serial units, repairs and invoiced installations lose the link.
//    Refused while the technician still holds material.
//  * Category — erased; its products stay, uncategorised.
//  * Expense — erased with its receipt (Profit & Loss changes).
//  * Quotation, draft invoice — erased.
// Audit entries of every erased record keep only "[permanently deleted]";
// one new entry records type, id and counts — no names.
//
// Backups are NOT changed here. [BackupService.purgeRecord] applies the
// same plan to backup files only when the owner explicitly asks.
import 'dart:io';

import '../../core/errors.dart';
import '../../core/ids.dart';
import '../../data/store/data_store.dart';
import '../models/user.dart';
import 'backup_service.dart' show PurgeSpec;
import 'context.dart';

enum DeletableKind {
  product('Product', Boxes.products, Permission.manageProducts),
  customer('Customer', Boxes.customers, Permission.manageCustomers),
  supplier('Supplier', Boxes.suppliers, Permission.manageSuppliers),
  category('Category', Boxes.categories, Permission.manageProducts),
  expense('Expense', Boxes.expenses, Permission.manageExpenses),
  technician('Technician', Boxes.employees, Permission.manageTechnicians),
  quotation('Quotation', Boxes.quotations, Permission.manageQuotations),
  draftInvoice('Draft invoice', Boxes.sales, Permission.manageSales);

  final String label;
  final String box;
  final Permission permission;
  const DeletableKind(this.label, this.box, this.permission);
}

const boxLabels = {
  Boxes.customers: 'customer profile',
  Boxes.suppliers: 'supplier profile',
  Boxes.products: 'product',
  Boxes.categories: 'category',
  Boxes.expenses: 'expense',
  Boxes.labourBills: 'labour bill',
  Boxes.employees: 'technician profile',
  Boxes.sales: 'invoices',
  Boxes.purchases: 'purchases',
  Boxes.payments: 'payments',
  Boxes.ledger: 'ledger entries',
  Boxes.salesReturns: 'customer returns',
  Boxes.purchaseReturns: 'supplier returns',
  Boxes.quotations: 'quotations',
  Boxes.repairs: 'repair jobs',
  Boxes.warrantyClaims: 'warranty claims',
  Boxes.serials: 'serial numbers',
  Boxes.serialIndex: 'serial index rows',
  Boxes.techTxns: 'technician material records',
  Boxes.techHoldings: 'technician holdings',
  Boxes.costLayers: 'stock cost batches',
  Boxes.stockMovements: 'stock movements',
  Boxes.inspections: 'inspection items',
  Boxes.barcodes: 'barcode index rows',
  Boxes.users: 'login accounts',
  Boxes.loginHistory: 'login history entries',
};

/// The result of inspecting a record before a permanent delete.
class DeleteCheck {
  final DeletableKind kind;
  final String id;
  final String name; // shown to the user only
  final List<String> blockers; // empty = can be erased
  final List<String> safeAlternative;
  final Map<String, int> erase; // box -> records to erase (incl. the record)
  final Map<String, int> unlink; // box -> kept records that lose a link
  final List<String> exclusiveFiles;
  final List<String> sharedFiles;
  final List<String> effects; // money / stock consequences, in plain words
  final PurgeSpec spec;
  const DeleteCheck({
    required this.kind,
    required this.id,
    required this.name,
    required this.blockers,
    this.safeAlternative = const [],
    this.erase = const {},
    this.unlink = const {},
    this.exclusiveFiles = const [],
    this.sharedFiles = const [],
    this.effects = const [],
    required this.spec,
  });
  bool get allowed => blockers.isEmpty;
  int get eraseTotal => erase.values.fold(0, (a, b) => a + b);
  int get unlinkTotal => unlink.values.fold(0, (a, b) => a + b);
}

class PermanentDeleteResult {
  final DeletableKind kind;
  final String id;
  final Map<String, int> erased;
  final int unlinked;
  final int auditEntriesScrubbed;
  final List<String> filesDeleted;
  final List<String> filesKept;
  final List<String> fileErrors;
  const PermanentDeleteResult(this.kind, this.id, this.erased, this.unlinked, this.auditEntriesScrubbed, this.filesDeleted, this.filesKept, this.fileErrors);
  int get recordsRemoved => erased.values.fold(0, (a, b) => a + b);
}

const purgedDetails = '[permanently deleted]';

class PermanentDeleteService {
  final ServiceContext ctx;
  PermanentDeleteService(this.ctx);

  final _running = <String>{};

  Iterable<(String, Json)> _all(String box) sync* {
    for (final k in ctx.store.keys(box)) {
      final v = ctx.store.read(box, k);
      if (v != null) yield (k, v);
    }
  }

  static bool _mentions(Object? v, Set<String> needles) {
    if (v is String) return needles.contains(v);
    if (v is Map) return v.values.any((e) => _mentions(e, needles));
    if (v is List) return v.any((e) => _mentions(e, needles));
    return false;
  }

  /// Records outside the audit / error logs (and outside [skip], "box|key")
  /// whose data contains any of [values].
  Map<String, List<String>> references(Set<String> values, {Set<String> skip = const {}}) {
    final out = <String, List<String>>{};
    for (final box in Boxes.all) {
      if (box == Boxes.auditLogs || box == Boxes.errorLog) continue;
      for (final (k, v) in _all(box)) {
        if (skip.contains('$box|$k')) continue;
        if (box == Boxes.meta && k == 'purgedRecords') continue; // the restore block holds erased ids on purpose
        if (values.contains(k) || _mentions(v, values)) (out[box] ??= []).add(k);
      }
    }
    return out;
  }

  String _nameOf(DeletableKind kind, Json j) => switch (kind) {
        DeletableKind.expense => '${j['number'] ?? ''} ${j['title'] ?? ''}'.trim(),
        DeletableKind.quotation || DeletableKind.draftInvoice => '${j['number'] ?? ''} ${j['customerName'] ?? ''}'.trim(),
        _ => '${j['name'] ?? j['id']}',
      };

  static String _rs(num paisa) {
    final v = (paisa / 100).toStringAsFixed(2);
    final parts = v.split('.');
    final w = parts[0].replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
    return 'Rs $w.${parts[1]}';
  }

  /// Inspects the record and builds the complete deletion plan. Read-only.
  DeleteCheck check(DeletableKind kind, String id) {
    final j = ctx.store.read(kind.box, id);
    if (j == null) throw const NotFoundException('This record no longer exists.');
    final name = _nameOf(kind, j);
    final erase = <String, Set<String>>{kind.box: {id}};
    final relink = <String, String?>{};
    final blockers = <String>[];
    final alternative = <String>[];
    final effects = <String>[];
    final anonymize = <String>[];
    void add(String box, String key) => (erase[box] ??= {}).add(key);

    switch (kind) {
      case DeletableKind.customer:
        final sales = {for (final (k, s) in _all(Boxes.sales)) if (s['customerId'] == id) k};
        for (final k in sales) {
          add(Boxes.sales, k);
        }
        final completed = [for (final k in sales) ctx.store.read(Boxes.sales, k)!].where((s) => s['status'] == 'completed').toList();
        final pays = {
          for (final (k, p) in _all(Boxes.payments))
            if (p['partyId'] == id || (sales.contains(p['refId']))) k
        };
        for (final k in pays) {
          add(Boxes.payments, k);
        }
        final rets = {for (final (k, r) in _all(Boxes.salesReturns)) if (r['partyId'] == id || sales.contains(r['originalId'])) k};
        for (final k in rets) {
          add(Boxes.salesReturns, k);
        }
        for (final (k, l) in _all(Boxes.ledger)) {
          if (l['partyId'] == id || sales.contains(l['refId']) || pays.contains(l['refId']) || rets.contains(l['refId'])) add(Boxes.ledger, k);
        }
        for (final (k, q) in _all(Boxes.quotations)) {
          if (q['customerId'] == id || sales.contains(q['convertedSaleId'])) add(Boxes.quotations, k);
        }
        final jobs = {for (final (k, r) in _all(Boxes.repairs)) if (r['customerId'] == id) k};
        for (final k in jobs) {
          add(Boxes.repairs, k);
        }
        for (final (k, w) in _all(Boxes.warrantyClaims)) {
          if (w['customerId'] == id || sales.contains(w['saleId'])) add(Boxes.warrantyClaims, k);
        }
        for (final (k, lb) in _all(Boxes.labourBills)) {
          if (lb['customerId'] == id || sales.contains(lb['saleId'])) add(Boxes.labourBills, k);
        }
        final salesTotal = completed.fold<num>(0, (a, s) => a + ((s['total'] as num?) ?? 0));
        final received = [for (final k in pays) ctx.store.read(Boxes.payments, k)!].where((p) => p['voided'] != true).fold<num>(0, (a, p) => a + ((p['amount'] as num?) ?? 0));
        effects
          ..add('Sales reports, dashboard and Profit & Loss lose ${completed.length} completed invoice(s) worth ${_rs(salesTotal)}.')
          ..add('Payment summaries lose ${pays.length} payment(s) of ${_rs(received)}; receivables lose the balance of ${_rs((j['balance'] as num?) ?? 0)}.')
          ..add('Stock does not change: goods on these invoices stay sold. Sold serial numbers stay "Sold" without the customer link.');
      case DeletableKind.supplier:
        final purchases = {for (final (k, p) in _all(Boxes.purchases)) if (p['supplierId'] == id) k};
        for (final k in purchases) {
          add(Boxes.purchases, k);
        }
        final pays = {
          for (final (k, p) in _all(Boxes.payments))
            if (p['partyId'] == id || purchases.contains(p['refId'])) k
        };
        for (final k in pays) {
          add(Boxes.payments, k);
        }
        for (final (k, l) in _all(Boxes.ledger)) {
          if (l['partyId'] == id || purchases.contains(l['refId']) || pays.contains(l['refId'])) add(Boxes.ledger, k);
        }
        for (final (k, r) in _all(Boxes.purchaseReturns)) {
          if (r['partyId'] == id || purchases.contains(r['originalId'])) add(Boxes.purchaseReturns, k);
        }
        // Received stock stays, each purchase's cost batch under a new id.
        for (final pid in purchases) {
          relink[pid] = 'batch_${newId()}';
        }
        final total = [for (final k in purchases) ctx.store.read(Boxes.purchases, k)!].fold<num>(0, (a, p) => a + ((p['total'] as num?) ?? 0));
        effects
          ..add('Purchase reports lose ${purchases.length} purchase(s) worth ${_rs(total)}; payables lose the balance of ${_rs((j['balance'] as num?) ?? 0)}.')
          ..add('Stock received on them stays in stock with its cost, so stock value and profit on future sales stay correct.');
      case DeletableKind.product:
        final onDocs = <String, int>{};
        void doc(String box, bool Function(Json) uses) {
          final n = _all(box).where((e) => uses(e.$2)).length;
          if (n > 0) onDocs[box] = n;
        }
        bool inItems(Json d, String f) => ((d[f] as List?) ?? const []).any((x) => x is Map && x['productId'] == id);
        doc(Boxes.sales, (d) => inItems(d, 'items'));
        doc(Boxes.purchases, (d) => inItems(d, 'items'));
        doc(Boxes.salesReturns, (d) => inItems(d, 'lines'));
        doc(Boxes.purchaseReturns, (d) => inItems(d, 'lines'));
        doc(Boxes.quotations, (d) => inItems(d, 'items'));
        doc(Boxes.techTxns, (d) => d['productId'] == id);
        doc(Boxes.repairs, (d) => d['productId'] == id || _mentions(d['parts'], {id}));
        doc(Boxes.warrantyClaims, (d) => d['productId'] == id);
        for (final e in onDocs.entries) {
          blockers.add('It appears on ${e.value} ${boxLabels[e.key]} (records of other customers / suppliers).');
        }
        alternative.add('Archive the product instead, or first delete the customer / supplier those documents belong to.');
        final sers = {for (final (k, s) in _all(Boxes.serials)) if (s['productId'] == id) k};
        for (final k in sers) {
          add(Boxes.serials, k);
        }
        for (final (k, ix) in _all(Boxes.serialIndex)) {
          final keys = ((ix['keys'] as List?) ?? const []).map((e) => '$e').toSet();
          if (keys.isNotEmpty && keys.every(sers.contains)) add(Boxes.serialIndex, k);
        }
        for (final (k, l) in _all(Boxes.costLayers)) {
          if (l['productId'] == id) add(Boxes.costLayers, k);
        }
        for (final (k, m) in _all(Boxes.stockMovements)) {
          if (m['productId'] == id) add(Boxes.stockMovements, k);
        }
        for (final (k, b) in _all(Boxes.barcodes)) {
          if (b['productId'] == id) add(Boxes.barcodes, k);
        }
        for (final (k, h) in _all(Boxes.techHoldings)) {
          if (h['productId'] == id && ((h['qty'] as num?) ?? 0) == 0) add(Boxes.techHoldings, k);
        }
        for (final (k, i) in _all(Boxes.inspections)) {
          if (i['productId'] == id) add(Boxes.inspections, k);
        }
        // Serial index rows shared with other products: the erased keys are unlinked.
        for (final s in sers) {
          relink[s] = null;
        }
        final stock = ((j['stockQty'] as num?) ?? 0) / 1000;
        if (stock != 0 && blockers.isEmpty) effects.add('Its remaining stock (${stock.toStringAsFixed(stock % 1 == 0 ? 0 : 2)} ${j['unit'] ?? ''}) and its value are removed from stock reports.');
      case DeletableKind.technician:
        final holds = [for (final (k, h) in _all(Boxes.techHoldings)) if (h['technicianId'] == id) (k, h)];
        if (holds.any((h) => ((h.$2['qty'] as num?) ?? 0) != 0)) {
          blockers.add('The technician still holds material.');
          alternative.add('Record the material as returned or installed first, or archive (deactivate) the technician.');
        }
        for (final (k, _) in holds) {
          add(Boxes.techHoldings, k);
        }
        final billed = <String>{};
        for (final (_, s) in _all(Boxes.sales)) {
          for (final it in (s['items'] as List?) ?? const []) {
            if (it is Map && it['techUsageId'] != null) billed.add('${it['techUsageId']}');
          }
        }
        for (final (k, t) in _all(Boxes.techTxns)) {
          if (t['technicianId'] == id && !billed.contains(k)) add(Boxes.techTxns, k);
        }
        relink[id] = null;
        final uid = j['userId'] as String?;
        if (uid != null && ctx.store.read(Boxes.users, uid) != null) {
          final u = ctx.store.read(Boxes.users, uid)!;
          final used = ctx.store.values(Boxes.auditLogs).any((a) => a['userId'] == uid);
          if (u['role'] == UserRole.owner.name) {
            blockers.add('Its login is an owner account.');
          } else if (used) {
            anonymize.add(uid); // kept for the audit trail, without the person
            effects.add('Its login has activity in the audit log: it is kept, deactivated and anonymised.');
          } else {
            add(Boxes.users, uid);
            relink[uid] = null;
          }
          for (final (k, ev) in _all(Boxes.loginHistory)) {
            if (ev['userId'] == uid || (ev['username'] != null && ev['username'] == u['username'])) add(Boxes.loginHistory, k);
          }
        }
      case DeletableKind.category:
        final n = _all(Boxes.products).where((p) => p.$2['categoryId'] == id).length;
        if (n > 0) effects.add('$n product(s) in it stay, without a category.');
      case DeletableKind.expense:
        effects.add('Profit & Loss and expense reports will no longer include ${_rs((j['amount'] as num?) ?? 0)} (${'${j['date'] ?? ''}'.padRight(7).substring(0, 7)}).');
      case DeletableKind.quotation:
        break;
      case DeletableKind.draftInvoice:
        if (j['status'] != 'draft') {
          blockers.add('Completed and cancelled invoices are erased only together with their customer.');
          alternative.add('Use Cancel invoice, or permanently delete the customer with all its records.');
        }
    }

    // Every erased id: links to it are removed from the records that stay.
    final erasedIds = <String>{for (final e in erase.entries) ...e.value};
    for (final x in erasedIds) {
      relink.putIfAbsent(x, () => null);
    }
    final spec0 = PurgeSpec(kind: kind.name, keys: {for (final e in erase.entries) e.key: e.value.toList()}, relink: relink, ids: [...erasedIds], anonymizeUsers: anonymize);

    // Dry run on the records that stay: what loses a link.
    final unlink = <String, int>{};
    final skip = {for (final e in erase.entries) for (final k in e.value) '${e.key}|$k'};
    for (final box in Boxes.all) {
      if (box == Boxes.auditLogs || box == Boxes.errorLog) continue;
      for (final (k, v) in _all(box)) {
        if (skip.contains('$box|$k')) continue;
        if (!identical(spec0.relinkValue(v), v)) unlink[box] = (unlink[box] ?? 0) + 1;
      }
    }

    // Files: deleted only when no remaining record uses them.
    final exclusive = <String>[];
    final shared = <String>[];
    for (final e in erase.entries) {
      for (final k in e.value) {
        final r = ctx.store.read(e.key, k);
        for (final f in ['imagePath', 'receiptPath']) {
          final path = r?[f];
          if (path is! String || path.trim().isEmpty || exclusive.contains(path) || shared.contains(path)) continue;
          (references({path}, skip: skip).isEmpty ? exclusive : shared).add(path);
        }
      }
    }
    final spec = PurgeSpec(kind: spec0.kind, keys: spec0.keys, relink: relink, ids: spec0.ids, files: exclusive, anonymizeUsers: anonymize);
    return DeleteCheck(
      kind: kind,
      id: id,
      name: name,
      blockers: blockers,
      safeAlternative: blockers.isEmpty ? const [] : (alternative.isEmpty ? ['Remove or correct the linked records first.'] : alternative),
      erase: {for (final e in erase.entries) e.key: e.value.length},
      unlink: unlink,
      exclusiveFiles: exclusive,
      sharedFiles: shared,
      effects: effects,
      spec: spec,
    );
  }

  /// Kept for callers that build the backup plan before deleting.
  PurgeSpec purgeSpecFor(DeleteCheck c) => c.spec;

  /// Erases the record and everything planned with it, in one commit, then
  /// verifies. Throws if not allowed, already running, or verification fails.
  Future<PermanentDeleteResult> deletePermanently(DeletableKind kind, String id) async {
    ctx.require(Permission.permanentDelete);
    ctx.require(kind.permission);
    final lock = '${kind.box}|$id';
    if (!_running.add(lock)) throw const BusinessException('This record is already being deleted.');
    try {
      final c = check(kind, id); // always a fresh plan
      if (!c.allowed) throw BusinessException('Cannot permanently delete: ${c.blockers.join(' ')}');
      final spec = c.spec;
      final uow = ctx.uow();
      final skip = <String>{};
      for (final e in spec.keys.entries) {
        for (final k in e.value) {
          uow.delete(e.key, k);
          skip.add('${e.key}|$k');
        }
      }
      var unlinked = 0;
      var scrubbed = 0;
      final idSet = spec.ids.toSet();
      for (final box in Boxes.all) {
        if (box == Boxes.errorLog) continue;
        for (final (k, v) in _all(box)) {
          if (skip.contains('$box|$k')) continue;
          if (box == Boxes.auditLogs) {
            if (idSet.contains(v['entityId']) && v['details'] != purgedDetails) {
              uow.put(box, k, {...v, 'details': purgedDetails});
              scrubbed++;
            }
            continue;
          }
          var nv = spec.relinkValue(v) as Json;
          if (box == Boxes.users && spec.anonymizeUsers.contains(k)) nv = spec.anonymizedUser(nv);
          if (!identical(nv, v)) {
            uow.put(box, k, nv);
            unlinked++;
          }
        }
      }
      ctx.audit(uow, 'permanent_delete', kind.name, id, '${spec.recordCount} record(s) erased, $unlinked unlinked');
      await uow.commit();
      ctx.clearCache();

      final deleted = <String>[];
      final errors = <String>[];
      for (final f in spec.files) {
        try {
          final file = File(f);
          if (file.existsSync()) file.deleteSync();
          deleted.add(f);
        } catch (e) {
          errors.add('$f: $e');
        }
      }
      _verify(spec);
      return PermanentDeleteResult(kind, id, c.erase, unlinked, scrubbed, deleted, c.sharedFiles, errors);
    } finally {
      _running.remove(lock);
    }
  }

  /// Throws if any erased record or any link to one remains.
  void _verify(PurgeSpec spec) {
    for (final e in spec.keys.entries) {
      for (final k in e.value) {
        if (ctx.store.read(e.key, k) != null) throw BusinessException('Verification failed: a record is still in ${e.key}.');
      }
    }
    final refs = references(spec.ids.toSet());
    if (refs.isNotEmpty) throw BusinessException('Verification failed: still referenced in ${refs.keys.join(', ')}.');
    final ids = spec.ids.toSet();
    for (final a in ctx.store.values(Boxes.auditLogs)) {
      if (ids.contains(a['entityId']) && a['action'] != 'permanent_delete' && a['details'] != purgedDetails) {
        throw const BusinessException('Verification failed: audit details were not scrubbed.');
      }
    }
  }
}
