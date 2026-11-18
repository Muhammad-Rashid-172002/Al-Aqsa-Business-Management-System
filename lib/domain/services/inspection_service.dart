import '../../core/errors.dart';
import '../../core/ids.dart';
import '../../core/money.dart';
import '../../core/qty.dart';
import '../../data/store/data_store.dart';
import '../models/product.dart';
import '../models/user.dart';
import 'context.dart';
import 'inventory_engine.dart';
import 'serial_service.dart';

/// Quality-control queue for returned goods in Used/Damaged/Faulty condition.
/// Nothing in this queue is sellable until the owner decides.
class InspectionService {
  final ServiceContext ctx;
  final InventoryEngine inv;
  final SerialService serials;
  InspectionService(this.ctx, this.inv, this.serials);

  List<InspectionItem> list({bool openOnly = true}) => ctx.all(Boxes.inspections, InspectionItem.fromJson)
      .where((x) => !openOnly || x.status != InspectionStatus.resolved)
      .toList()
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  /// Called inside another operation's unit of work: moves goods into the
  /// inspection bucket and creates the queue item.
  InspectionItem enqueue(
    UnitOfWork uow, {
    required Product product,
    required Qty qty,
    required Money cost,
    required List<SerialRecord> serialRecords,
    required String sourceType,
    required String sourceId,
    String? technicianId,
    required String condition,
    String reason = '',
  }) {
    final item = InspectionItem(
      id: newId(),
      productId: product.id,
      productName: product.name,
      qty: qty,
      cost: cost,
      serials: serialRecords.map((r) => r.key).toList(),
      sourceType: sourceType,
      sourceId: sourceId,
      technicianId: technicianId,
      reportedCondition: condition,
      reason: reason,
      createdAt: ctx.now(),
    );
    inv.changeBucket(uow, product.id, StockBucket.inspection, qty, 'toInspection', sourceType, sourceId, '$condition: $reason', cost);
    for (final r in serialRecords) {
      serials.save(
          uow,
          r.transition(SerialStatus.pendingInspection,
              at: ctx.now(), note: 'Returned ($condition) - awaiting inspection', refType: 'inspection', refId: item.id, userId: ctx.userId, clearTechnician: true, clearCustomer: true, clearSale: true, clearWarranty: true));
    }
    uow.put(Boxes.inspections, item.id, item.toJson());
    return item;
  }

  /// Owner decision. [qty] may be less than the item (split decision); for
  /// serial items pass the chosen [serialKeys] instead.
  Future<InspectionItem> decide(String itemId, InspectionDecision decision, {Qty? qty, List<String>? serialKeys, String note = ''}) async {
    ctx.require(Permission.approveInspection);
    final uow = ctx.uow();
    final j = uow.read(Boxes.inspections, itemId);
    if (j == null) throw const NotFoundException('Inspection item not found.');
    final item = InspectionItem.fromJson(j);
    if (item.status == InspectionStatus.resolved) throw const BusinessException('This item is already resolved.');
    if (item.status == InspectionStatus.repairable && decision == InspectionDecision.repairable) {
      throw const BusinessException('This item is already marked repairable.');
    }
    final p = inv.product(uow, item.productId);

    List<String> keys;
    Qty take;
    if (p.requiresSerial) {
      keys = serialKeys ?? item.serials;
      if (keys.isEmpty || !keys.every(item.serials.contains)) throw const ValidationException('Choose serial numbers from this item.');
      take = Qty.units(keys.length);
    } else {
      keys = const [];
      take = qty ?? item.qty;
      inv.checkQty(p, take);
    }
    if (take > item.qty) throw ValidationException('Only ${item.qty.format()} ${p.unit} in this item.');
    final cost = take == item.qty ? item.cost : item.cost.shareQty(take, item.qty);
    final from = item.currentBucket;
    final ref = item.id;

    inv.changeBucket(uow, p.id, from, -take, 'inspection_${decision.name}', 'inspection', ref, note, cost);
    final SerialStatus newStatus;
    switch (decision) {
      case InspectionDecision.sellable:
        inv.stockIn(uow, productId: p.id, qty: take, unitCost: cost.perUnit(take), totalCost: cost, type: 'inspectionApproved', refType: 'inspection', refId: ref, reason: note);
        newStatus = SerialStatus.inStock;
      case InspectionDecision.repairable:
        inv.changeBucket(uow, p.id, StockBucket.repairable, take, 'inspection_repairable', 'inspection', ref, note, cost);
        newStatus = SerialStatus.awaitingRepair;
      case InspectionDecision.damaged:
        inv.changeBucket(uow, p.id, StockBucket.damaged, take, 'inspection_damaged', 'inspection', ref, note, cost);
        newStatus = SerialStatus.damaged;
    }
    for (final k in keys) {
      final r = SerialRecord.fromJson(uow.read(Boxes.serials, k)!);
      serials.save(uow, r.transition(newStatus, at: ctx.now(), note: 'Inspection: ${decision.name}${note.isEmpty ? '' : ' - $note'}', refType: 'inspection', refId: ref, userId: ctx.userId));
    }

    final remainingQty = item.qty - take;
    final decided = item.copyWith(
      qty: take,
      cost: cost,
      serials: keys,
      status: decision == InspectionDecision.repairable ? InspectionStatus.repairable : InspectionStatus.resolved,
      decision: decision,
      decisionNote: note,
      resolvedAt: decision == InspectionDecision.repairable ? null : ctx.now(),
      resolvedBy: ctx.userId,
    );
    if (remainingQty.isPositive) {
      // Keep the undecided remainder as the original item; decided part gets a new id.
      final rest = item.copyWith(qty: remainingQty, cost: item.cost - cost, serials: item.serials.where((k) => !keys.contains(k)).toList());
      uow.put(Boxes.inspections, item.id, rest.toJson());
      final part = decided.copyWith(id: newId());
      uow.put(Boxes.inspections, part.id, part.toJson());
      ctx.audit(uow, 'inspection_${decision.name}', 'inspection', part.id, '${p.name} x${take.format()}');
      await uow.commit();
      return part;
    }
    uow.put(Boxes.inspections, item.id, decided.toJson());
    ctx.audit(uow, 'inspection_${decision.name}', 'inspection', item.id, '${p.name} x${take.format()}');
    await uow.commit();
    return decided;
  }
}
