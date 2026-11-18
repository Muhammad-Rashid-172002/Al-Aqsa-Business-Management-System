import '../../core/money.dart';
import '../../core/qty.dart';
import '../../data/store/data_store.dart';
import '../models/operations.dart';
import '../models/party.dart';
import '../models/product.dart';
import 'context.dart';

class IntegrityIssue {
  final String area;
  final String message;
  const IntegrityIssue(this.area, this.message);
  @override
  String toString() => '[$area] $message';
}

/// Cross-checks cached values against their source records.
class IntegrityService {
  final ServiceContext ctx;
  IntegrityService(this.ctx);

  List<IntegrityIssue> check() {
    final issues = <IntegrityIssue>[];
    final store = ctx.store;

    // 1. Party balances == ledger sums.
    final ledger = store.values(Boxes.ledger).map(LedgerEntry.fromJson).toList();
    for (final kind in PartyKind.values) {
      final box = kind == PartyKind.customer ? Boxes.customers : Boxes.suppliers;
      for (final p in store.values(box).map(Party.fromJson)) {
        final sum = Money.sum(ledger.where((e) => e.partyKind == kind && e.partyId == p.id).map((e) => e.balanceEffect));
        if (sum != p.balance) issues.add(IntegrityIssue('ledger', '${p.name}: cached ${p.balance} vs ledger $sum'));
      }
    }

    // 2. Product stock == FIFO layers remaining; movements reconcile.
    final layers = store.values(Boxes.costLayers).map(CostLayer.fromJson).toList();
    final moves = store.values(Boxes.stockMovements).map(StockMovement.fromJson).toList();
    final holdings = store.values(Boxes.techHoldings).map(TechHolding.fromJson).toList();
    final inspections = store.values(Boxes.inspections).map(InspectionItem.fromJson).toList();
    final serials = store.values(Boxes.serials).map(SerialRecord.fromJson).toList();
    for (final p in store.values(Boxes.products).map(Product.fromJson)) {
      final layerQty = Qty.sum(layers.where((l) => l.productId == p.id).map((l) => l.qtyRemaining));
      if (!p.stockQty.isNegative && layerQty != p.stockQty) issues.add(IntegrityIssue('stock', '${p.name}: stock ${p.stockQty} vs cost layers $layerQty'));
      for (final bucket in StockBucket.values) {
        final net = Qty.sum(moves.where((m0) => m0.productId == p.id && m0.bucket == bucket).map((m0) => m0.qty));
        if (net != p.bucket(bucket)) issues.add(IntegrityIssue('stock', '${p.name}: ${bucket.label} ${p.bucket(bucket)} vs movements $net'));
      }
      final held = Qty.sum(holdings.where((h) => h.productId == p.id).map((h) => h.qty));
      if (held != p.issuedQty) issues.add(IntegrityIssue('technician', '${p.name}: issued ${p.issuedQty} vs technician holdings $held'));
      final pending = Qty.sum(inspections.where((x) => x.productId == p.id && x.status == InspectionStatus.pending).map((x) => x.qty));
      if (pending != p.inspectionQty) issues.add(IntegrityIssue('inspection', '${p.name}: inspection ${p.inspectionQty} vs queue $pending'));
      final repairable = Qty.sum(inspections.where((x) => x.productId == p.id && x.status == InspectionStatus.repairable).map((x) => x.qty));
      if (repairable != p.repairableQty) issues.add(IntegrityIssue('inspection', '${p.name}: repairable ${p.repairableQty} vs queue $repairable'));

      // 3. Serial counts match stock for serial products.
      if (p.requiresSerial) {
        int count(SerialStatus st) => serials.where((r) => r.productId == p.id && r.status == st).length;
        if (count(SerialStatus.inStock) != p.stockQty.milli ~/ 1000) issues.add(IntegrityIssue('serial', '${p.name}: stock ${p.stockQty} vs in-stock serials ${count(SerialStatus.inStock)}'));
        if (count(SerialStatus.issuedToTechnician) != p.issuedQty.milli ~/ 1000) issues.add(IntegrityIssue('serial', '${p.name}: issued ${p.issuedQty} vs serials ${count(SerialStatus.issuedToTechnician)}'));
        if (count(SerialStatus.pendingInspection) != p.inspectionQty.milli ~/ 1000) issues.add(IntegrityIssue('serial', '${p.name}: inspection serial count mismatch'));
        if (count(SerialStatus.damaged) != p.damagedQty.milli ~/ 1000) issues.add(IntegrityIssue('serial', '${p.name}: damaged ${p.damagedQty} vs damaged serials ${count(SerialStatus.damaged)}'));
        if (count(SerialStatus.awaitingRepair) != p.repairableQty.milli ~/ 1000) issues.add(IntegrityIssue('serial', '${p.name}: repairable ${p.repairableQty} vs serials ${count(SerialStatus.awaitingRepair)}'));
      }
    }

    // 4. Serial index consistency.
    for (final r in serials) {
      final keys = (store.read(Boxes.serialIndex, r.serial)?['keys'] as List?) ?? const [];
      if (!keys.contains(r.key)) issues.add(IntegrityIssue('serial', 'Serial ${r.display} missing from index'));
    }

    // 4. Pending journal (should be empty when idle) is handled by HiveStore.
    return issues;
  }
}
