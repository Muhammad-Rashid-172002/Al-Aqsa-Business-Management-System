import '../../core/errors.dart';
import '../../core/ids.dart';
import '../../core/money.dart';
import '../../core/qty.dart';
import '../../data/store/data_store.dart';
import '../models/product.dart';
import '../models/user.dart';
import 'context.dart';

/// Low-level stock operations used inside a [UnitOfWork].
///
/// Costing method: FIFO. Every stock-in creates a [CostLayer]; every
/// stock-out consumes the oldest layers first and returns their exact cost,
/// which becomes the cost of goods sold. Every change writes a
/// [StockMovement] with before/after quantities.
class InventoryEngine {
  final ServiceContext ctx;
  InventoryEngine(this.ctx);

  Product product(UnitOfWork uow, String id) {
    final j = uow.read(Boxes.products, id);
    if (j == null) throw NotFoundException('Product not found ($id).');
    return Product.fromJson(j);
  }

  void saveProduct(UnitOfWork uow, Product p) => uow.put(Boxes.products, p.id, p.toJson());

  /// Validates a quantity for a product (positive; whole unless decimals allowed).
  void checkQty(Product p, Qty q) {
    if (!q.isPositive) throw ValidationException('Quantity for "${p.name}" must be greater than zero.');
    if ((p.requiresSerial || !p.allowDecimal) && !q.isWhole) {
      throw ValidationException('"${p.name}" is sold in whole ${p.unit}. Decimal quantity ${q.format()} is not allowed.');
    }
  }

  /// Committed cost layers grouped by product (cached until layers change).
  Map<String, List<CostLayer>> _layersByProduct() => ctx.derived('layersByProduct', const [Boxes.costLayers], () {
        final m = <String, List<CostLayer>>{};
        for (final l in ctx.all(Boxes.costLayers, CostLayer.fromJson)) {
          (m[l.productId] ??= []).add(l);
        }
        return m;
      });

  List<CostLayer> openLayers(UnitOfWork uow, String productId) {
    // Same result as filtering every layer of the unit of work (committed
    // layers overlaid with its pending writes), but only this product's
    // layers are looked at.
    final pending = uow.pendingOf(Boxes.costLayers);
    final layers = <CostLayer>[
      for (final l in _layersByProduct()[productId] ?? const <CostLayer>[])
        if (!pending.containsKey(l.id) && l.qtyRemaining.isPositive) l,
    ];
    pending.forEach((key, j) {
      if (j != null && j['productId'] == productId && ((j['qtyRemaining'] as num?) ?? 0) > 0) layers.add(CostLayer.fromJson(j));
    });
    layers.sort((a, b) {
      final c = a.date.compareTo(b.date);
      return c != 0 ? c : a.id.compareTo(b.id);
    });
    return layers;
  }

  void _movement(UnitOfWork uow, Product p, StockBucket bucket, Qty delta, Qty before, String type, String refType, String refId, String reason,
      [Money value = const Money.zero()]) {
    final mv = StockMovement(
      id: newId(),
      productId: p.id,
      at: ctx.now(),
      type: type,
      bucket: bucket,
      qty: delta,
      before: before,
      after: before + delta,
      value: value.abs(),
      refType: refType,
      refId: refId,
      reason: reason,
      userId: ctx.userId,
    );
    uow.put(Boxes.stockMovements, mv.id, mv.toJson());
  }

  /// Adds [qty] units to available stock at [unitCost].
  void stockIn(
    UnitOfWork uow, {
    required String productId,
    required Qty qty,
    required Money unitCost,
    required String type,
    required String refType,
    required String refId,
    String reason = '',
    DateTime? date,
    Money? totalCost,
  }) {
    final p = product(uow, productId);
    checkQty(p, qty);
    final layer = CostLayer(
      id: newId(),
      productId: productId,
      sourceType: refType,
      sourceId: refId,
      date: date ?? ctx.now(),
      qtyIn: qty,
      qtyRemaining: qty,
      unitCost: unitCost,
    );
    uow.put(Boxes.costLayers, layer.id, layer.toJson());
    saveProduct(uow, p.copyWith(stockQty: p.stockQty + qty));
    _movement(uow, p, StockBucket.available, qty, p.stockQty, type, refType, refId, reason, totalCost ?? unitCost.timesQty(qty));
  }

  /// Puts serial-tracked units back into available stock at each unit's own
  /// batch cost (one cost layer per distinct cost), so a unit from a cheaper
  /// or dearer batch keeps its cost when it is sold again. Units without a
  /// recorded cost fall back to [fallbackTotal] spread evenly.
  void stockInUnits(
    UnitOfWork uow, {
    required String productId,
    required List<SerialRecord> units,
    required Money fallbackTotal,
    required String type,
    required String refType,
    required String refId,
    String reason = '',
  }) {
    final qty = Qty.units(units.length);
    if (units.isEmpty) return;
    if (unitsCost(units) == null) {
      stockIn(uow, productId: productId, qty: qty, unitCost: fallbackTotal.perUnit(qty), totalCost: fallbackTotal, type: type, refType: refType, refId: refId, reason: reason);
      return;
    }
    final byCost = <int, int>{};
    for (final u in units) {
      byCost[u.cost.paisa] = (byCost[u.cost.paisa] ?? 0) + 1;
    }
    for (final e in byCost.entries) {
      final q = Qty.units(e.value);
      stockIn(uow, productId: productId, qty: q, unitCost: Money(e.key), totalCost: Money(e.key).timesQty(q), type: type, refType: refType, refId: refId, reason: reason);
    }
  }

  /// Sum of the units' recorded batch costs, or null if any unit has none.
  static Money? unitsCost(List<SerialRecord> units) {
    if (units.isEmpty || units.any((u) => u.cost.isZero)) return null;
    return Money.sum(units.map((u) => u.cost));
  }

  /// Consumes FIFO layers and returns the total cost. When layers run short
  /// (only possible with owner-authorised negative stock) the shortfall is
  /// valued at the product's last purchase price.
  Money consumeFifo(UnitOfWork uow, String productId, Qty qty, {String? preferSourceId, List<SerialRecord>? units}) {
    if (units != null && units.isNotEmpty) return _consumeUnits(uow, productId, qty, units);
    var need = qty;
    var cost = const Money.zero();
    final layers = openLayers(uow, productId);
    if (preferSourceId != null) {
      layers.sort((a, b) => (a.sourceId == preferSourceId ? 0 : 1).compareTo(b.sourceId == preferSourceId ? 0 : 1));
    }
    for (final l in layers) {
      if (need.isZero) break;
      final take = Qty.min(need, l.qtyRemaining);
      cost += l.unitCost.timesQty(take);
      uow.put(Boxes.costLayers, l.id, l.withRemaining(l.qtyRemaining - take).toJson());
      need -= take;
    }
    if (need.isPositive) cost += product(uow, productId).purchasePrice.timesQty(need);
    return cost;
  }

  /// Serial-tracked units leave stock at the cost of the batch each unit
  /// actually came from (specific identification), not the oldest batch:
  /// the layer of the unit's own purchase; failing that (e.g. a unit that
  /// came back on a customer return) an open layer with the unit's recorded
  /// cost; failing that, FIFO. Keeps every batch's remaining quantity equal
  /// to its unsold serials, so profit and stock value stay per-batch exact.
  Money _consumeUnits(UnitOfWork uow, String productId, Qty qty, List<SerialRecord> units) {
    var cost = const Money.zero();
    for (final u in units) {
      final layers = openLayers(uow, productId);
      if (layers.isEmpty) {
        cost += (u.cost.isZero ? product(uow, productId).purchasePrice : u.cost);
        continue;
      }
      final l = layers.where((l) => u.purchaseId != null && l.sourceId == u.purchaseId).firstOrNull ??
          layers.where((l) => l.unitCost == u.cost).firstOrNull ??
          layers.first;
      cost += l.unitCost;
      uow.put(Boxes.costLayers, l.id, l.withRemaining(l.qtyRemaining - const Qty.one()).toJson());
    }
    final rest = qty - Qty.units(units.length);
    if (rest.isPositive) cost += consumeFifo(uow, productId, rest);
    return cost;
  }

  /// Removes [qty] from available stock. Returns FIFO cost of removed units
  /// (for serial-tracked items pass [units]: each unit's own batch cost).
  Money stockOut(
    UnitOfWork uow, {
    required String productId,
    required Qty qty,
    required String type,
    required String refType,
    required String refId,
    String reason = '',
    bool allowNegative = false,
    String? preferSourceId,
    List<SerialRecord>? units,
  }) {
    final p = product(uow, productId);
    checkQty(p, qty);
    if (p.stockQty < qty && !allowNegative) {
      throw StockException('Not enough stock for "${p.name}". Available: ${p.stockQty.format()} ${p.unit}, required: ${qty.format()}.');
    }
    final cost = consumeFifo(uow, productId, qty, preferSourceId: preferSourceId, units: units);
    saveProduct(uow, p.copyWith(stockQty: p.stockQty - qty));
    _movement(uow, p, StockBucket.available, -qty, p.stockQty, type, refType, refId, reason, cost);
    return cost;
  }

  /// Changes a non-sellable bucket (issued, damaged, inspection, repairable).
  void changeBucket(UnitOfWork uow, String productId, StockBucket bucket, Qty delta, String type, String refType, String refId,
      [String reason = '', Money value = const Money.zero()]) {
    if (bucket == StockBucket.available) throw ArgumentError('Use stockIn/stockOut for available stock');
    final p = product(uow, productId);
    final before = p.bucket(bucket);
    if ((before + delta).isNegative) throw StockException('Not enough ${bucket.label.toLowerCase()} quantity for "${p.name}".');
    saveProduct(uow, p.withBucket(bucket, before + delta));
    _movement(uow, p, bucket, delta, before, type, refType, refId, reason, value);
  }

  /// Owner stock adjustment to an exact counted quantity.
  Future<void> adjustTo(String productId, Qty countedQty, String reason, {Money? unitCostForIncrease}) async {
    ctx.require(Permission.adjustStock);
    if (reason.trim().isEmpty) throw const ValidationException('A reason is required for stock adjustments.');
    if (countedQty.isNegative) throw const ValidationException('Counted quantity cannot be negative.');
    final uow = ctx.uow();
    final p = product(uow, productId);
    if (p.requiresSerial) {
      throw const BusinessException('Serial-tracked stock is adjusted per unit: use "Mark damaged" or register missing serials through a purchase.');
    }
    final diff = countedQty - p.stockQty;
    if (diff.isZero) return;
    final refId = newId();
    if (diff.isPositive) {
      stockIn(uow,
          productId: productId, qty: diff, unitCost: unitCostForIncrease ?? p.purchasePrice, type: 'adjustment', refType: 'adjustment', refId: refId, reason: reason);
    } else {
      stockOut(uow, productId: productId, qty: -diff, type: 'adjustment', refType: 'adjustment', refId: refId, reason: reason, allowNegative: true);
    }
    ctx.audit(uow, 'stock_adjust', 'product', productId, '${p.stockQty.format()} -> ${countedQty.format()}: $reason');
    await uow.commit();
  }

  /// Moves units from available stock to damaged (e.g. broken in shop).
  Future<void> markDamaged(String productId, Qty qty, String reason, {List<String> serialKeys = const []}) async {
    ctx.require(Permission.adjustStock);
    if (reason.trim().isEmpty) throw const ValidationException('Please give a reason.');
    final uow = ctx.uow();
    final p = product(uow, productId);
    if (p.requiresSerial && serialKeys.length != (qty.isWhole ? qty.wholeUnits : -1)) {
      throw ValidationException('Select ${qty.format()} serial number(s) to mark damaged.');
    }
    final ref = newId();
    final units = [
      for (final k in serialKeys)
        if (uow.read(Boxes.serials, k) case final j?) SerialRecord.fromJson(j)
    ];
    final cost = stockOut(uow, productId: productId, qty: qty, type: 'damage', refType: 'damage', refId: ref, reason: reason, units: units);
    changeBucket(uow, productId, StockBucket.damaged, qty, 'damage', 'damage', ref, reason, cost);
    for (final k in serialKeys) {
      final j = uow.read(Boxes.serials, k);
      if (j == null) throw NotFoundException('Serial $k not found.');
      final r = SerialRecord.fromJson(j);
      if (r.productId != productId || r.status != SerialStatus.inStock) throw BusinessException('Serial ${r.display} is not in stock.');
      uow.put(Boxes.serials, k, r.transition(SerialStatus.damaged, at: ctx.now(), note: 'Marked damaged: $reason', refType: 'damage', refId: ref, userId: ctx.userId).toJson());
    }
    ctx.audit(uow, 'mark_damaged', 'product', productId, '${qty.format()}: $reason');
    await uow.commit();
  }

  /// Writes damaged stock off (e.g. scrapped). Keeps a movement record.
  Future<void> writeOffDamaged(String productId, Qty qty, String reason) async {
    ctx.require(Permission.adjustStock);
    if (reason.trim().isEmpty) throw const ValidationException('Please give a reason.');
    final uow = ctx.uow();
    if (product(uow, productId).requiresSerial) {
      throw const BusinessException('Damaged serial-tracked units should be returned to the supplier (Purchase Return).');
    }
    changeBucket(uow, productId, StockBucket.damaged, -qty, 'writeOff', 'write_off', newId(), reason);
    ctx.audit(uow, 'write_off', 'product', productId, '${qty.format()}: $reason');
    await uow.commit();
  }

  List<StockMovement> history(String productId) =>
      // Not cached: the movement log is the largest box and is only read here,
      // in the movement report and before deleting a product; filtering the
      // raw records first keeps this fast without holding them in memory.
      ctx.store.values(Boxes.stockMovements).where((j) => j['productId'] == productId).map(StockMovement.fromJson).toList()
        ..sort((a, b) => b.at.compareTo(a.at));

  /// FIFO valuation of all available stock.
  Money stockValuation({String? productId}) {
    var total = const Money.zero();
    for (final l in ctx.all(Boxes.costLayers, CostLayer.fromJson)) {
      if (productId != null && l.productId != productId) continue;
      if (l.qtyRemaining.isPositive) total += l.unitCost.timesQty(l.qtyRemaining);
    }
    return total;
  }
}
