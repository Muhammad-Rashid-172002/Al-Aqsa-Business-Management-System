import '../../core/errors.dart';
import '../../core/ids.dart';
import '../../core/money.dart';
import '../../core/qty.dart';
import '../../data/store/data_store.dart';
import '../models/documents.dart';
import '../models/json_utils.dart';
import '../models/party.dart';
import '../models/product.dart';
import '../models/user.dart';
import 'context.dart';
import 'inventory_engine.dart';
import 'party_service.dart';
import 'serial_service.dart';

class PurchaseLineInput {
  final String productId;
  final Qty qty;
  final Money unitCost;
  final Money discount;
  final Money tax;
  final List<String> serials;
  const PurchaseLineInput({
    required this.productId,
    required this.qty,
    required this.unitCost,
    this.discount = const Money.zero(),
    this.tax = const Money.zero(),
    this.serials = const [],
  });
}

class ReturnLineInput {
  final String productId;
  final Qty qty;
  final List<String> serials;
  final String condition; // sales returns: resellable | damaged | inspect
  const ReturnLineInput({required this.productId, required this.qty, this.serials = const [], this.condition = 'resellable'});
}

class PurchaseService {
  final ServiceContext ctx;
  final InventoryEngine inv;
  final PartyService parties;
  final SerialService serials;
  PurchaseService(this.ctx, this.inv, this.parties, this.serials);

  List<Purchase> list({DateTime? from, DateTime? to, String? supplierId, bool includeCancelled = true, String query = ''}) {
    final q = query.trim().toLowerCase();
    return ctx.all(Boxes.purchases, Purchase.fromJson).where((p) {
      if (!includeCancelled && p.status == DocStatus.cancelled) return false;
      if (supplierId != null && p.supplierId != supplierId) return false;
      if (from != null && p.date.isBefore(dayStart(from))) return false;
      if (to != null && p.date.isAfter(dayEnd(to))) return false;
      if (q.isNotEmpty && !p.number.toLowerCase().contains(q) && !p.supplierInvoiceNo.toLowerCase().contains(q)) return false;
      return true;
    }).toList()
      ..sort((a, b) => b.date.compareTo(a.date));
  }

  Purchase? byId(String id) {
    final j = ctx.store.read(Boxes.purchases, id);
    return j == null ? null : Purchase.fromJson(j);
  }

  /// Serial conflicts for a planned purchase (for the UI to show before saving).
  List<SerialConflict> previewConflicts(List<PurchaseLineInput> lines) {
    final out = <SerialConflict>[];
    for (final l in lines) {
      final p = ctx.store.read(Boxes.products, l.productId);
      if (p == null) continue;
      out.addAll(serials.conflicts(null, Product.fromJson(p), l.serials));
    }
    return out;
  }

  /// Confirms a purchase in one unit of work: purchase document, stock-in
  /// with FIFO layers, serial registration, supplier ledger and payment.
  /// Adds new serial-numbered units to an EXISTING product when they did
  /// not come from a supplier purchase (opening stock, stock found in a
  /// count, a gift). Same rules as a purchase: one new cost batch at
  /// [unitCost] dated [date], each serial unique (earlier purchases
  /// included; only the owner may approve a genuine duplicate), stock rises
  /// by the number of serials. Old serials are untouched. Returns the
  /// stock-in number (SIN-…).
  Future<String> addSerialStock({
    required String productId,
    required List<String> serials,
    required Money unitCost,
    required DateTime date,
    required String reason,
    Set<String> approvedSerialConflicts = const {},
  }) async {
    ctx.require(Permission.adjustStock);
    if (reason.trim().isEmpty) throw const ValidationException('Please give a reason (e.g. opening stock).');
    if (unitCost.isNegative) throw const ValidationException('Cost cannot be negative.');
    final uow = ctx.uow();
    final p = inv.product(uow, productId);
    if (!p.requiresSerial) throw const BusinessException('This product does not track serial numbers.');
    if (serials.isEmpty) throw const ValidationException('Enter at least one serial number.');
    final list = this.serials.normalizeList(serials, expectedQty: serials.length, productName: p.name);
    if (list.toSet().length != list.length) throw const DuplicateException('A serial number is entered twice.');
    final ref = newId();
    final number = ctx.nextNumber(uow, 'stock_in', 'SIN', pad: 5);
    final qty = Qty.units(list.length);
    inv.stockIn(uow, productId: p.id, qty: qty, unitCost: unitCost, type: 'serialStockIn', refType: 'stock_in', refId: ref, reason: '$number: $reason', date: date);
    this.serials.registerPurchased(uow,
        serials: list,
        product: p,
        supplierId: null,
        purchaseId: ref,
        purchaseNumber: number,
        date: date,
        unitCost: unitCost,
        approved: approvedSerialConflicts.map(normalizeCode).toSet(),
        outKeys: <String>[],
        verb: 'Added to stock',
        refType: 'stock_in');
    ctx.audit(uow, 'serial_stock_in', 'product', p.id, '$number: +${list.length} ${p.unit} @ ${unitCost.format()} – $reason');
    await uow.commit();
    return number;
  }

  Future<Purchase> create({
    required String supplierId,
    String supplierInvoiceNo = '',
    required DateTime date,
    required List<PurchaseLineInput> lines,
    Money paid = const Money.zero(),
    PaymentMethod method = PaymentMethod.cash,
    String notes = '',
    Set<String> approvedSerialConflicts = const {},
  }) async {
    final uow = ctx.uow();
    final purchase = stage(uow,
        supplierId: supplierId,
        supplierInvoiceNo: supplierInvoiceNo,
        date: date,
        lines: lines,
        paid: paid,
        method: method,
        notes: notes,
        approvedSerialConflicts: approvedSerialConflicts);
    await uow.commit();
    return purchase;
  }

  /// Adds a purchase to [uow] without committing (see [create]).
  Purchase stage(
    UnitOfWork uow, {
    required String supplierId,
    String supplierInvoiceNo = '',
    required DateTime date,
    required List<PurchaseLineInput> lines,
    Money paid = const Money.zero(),
    PaymentMethod method = PaymentMethod.cash,
    String notes = '',
    Set<String> approvedSerialConflicts = const {},
  }) {
    ctx.require(Permission.managePurchases);
    if (lines.isEmpty) throw const ValidationException('Add at least one product.');
    if (paid.isNegative) throw const ValidationException('Paid amount cannot be negative.');
    final supplier = parties.require(uow, PartyKind.supplier, supplierId);
    final invNo = supplierInvoiceNo.trim();
    if (invNo.isNotEmpty &&
        list(supplierId: supplierId).any((p) => p.status != DocStatus.cancelled && p.supplierInvoiceNo.toLowerCase() == invNo.toLowerCase())) {
      throw DuplicateException('Supplier invoice "$invNo" is already entered for ${supplier.name}.');
    }

    final id = newId();
    final number = ctx.nextNumber(uow, 'purchase', ctx.settings.purchasePrefix);
    final seenSerials = <String>{};
    final drafts = <(PurchaseItem, Product)>[];
    for (final l in lines) {
      final p = inv.product(uow, l.productId);
      inv.checkQty(p, l.qty);
      if (l.unitCost.isNegative || l.discount.isNegative || l.tax.isNegative) throw const ValidationException('Amounts cannot be negative.');
      if (p.archived) throw BusinessException('"${p.name}" is archived.');
      var sers = <String>[];
      if (p.requiresSerial) {
        sers = serials.normalizeList(l.serials, expectedQty: l.qty.wholeUnits, productName: p.name);
        for (final sn in sers) {
          if (!seenSerials.add('${p.brandKey}|$sn')) throw DuplicateException('Serial "$sn" appears on two lines.');
        }
      }
      final item = PurchaseItem(productId: p.id, name: p.name, qty: l.qty, unitCost: l.unitCost, discount: l.discount, tax: l.tax, serials: sers);
      if (item.net.isNegative) throw ValidationException('Discount on "${p.name}" is larger than the line amount.');
      drafts.add((item, p));
    }
    final total = Money.sum(drafts.map((d) => d.$1.net));
    if (paid > total) throw const ValidationException('Paid amount is more than the purchase total.');

    final items = <PurchaseItem>[];
    for (final (it, p) in drafts) {
      final unit = it.landedUnitCost;
      inv.stockIn(uow,
          productId: it.productId, qty: it.qty, unitCost: unit, totalCost: it.net, type: 'purchase', refType: 'purchase', refId: id, reason: number, date: date);
      inv.saveProduct(uow, inv.product(uow, it.productId).copyWith(purchasePrice: it.unitCost));
      var keys = <String>[];
      if (it.serials.isNotEmpty) {
        serials.registerPurchased(uow,
            serials: it.serials,
            product: p,
            supplierId: supplierId,
            purchaseId: id,
            purchaseNumber: number,
            date: date,
            unitCost: unit,
            approved: approvedSerialConflicts.map(normalizeCode).toSet(),
            outKeys: keys);
      }
      items.add(PurchaseItem(productId: it.productId, name: it.name, qty: it.qty, unitCost: it.unitCost, discount: it.discount, tax: it.tax, serials: keys));
    }
    final purchase = Purchase(
      id: id,
      number: number,
      supplierId: supplierId,
      supplierInvoiceNo: invNo,
      date: date,
      items: items,
      paidAtPurchase: paid,
      method: method,
      notes: notes,
      status: DocStatus.completed,
      createdBy: ctx.userId,
      createdAt: ctx.now(),
    );
    uow.put(Boxes.purchases, id, purchase.toJson());
    parties.post(uow,
        kind: PartyKind.supplier,
        partyId: supplierId,
        type: LedgerType.purchase,
        credit: purchase.total,
        refType: 'purchase',
        refId: id,
        refNumber: number,
        note: invNo.isEmpty ? 'Purchase' : 'Supplier inv $invNo',
        at: date);
    if (paid.isPositive) {
      parties.recordPayment(uow,
          kind: PartyKind.supplier,
          partyId: supplierId,
          amount: paid,
          method: method,
          direction: PaymentDirection.paid,
          refType: 'purchase',
          refId: id,
          refNumber: number,
          at: date);
    }
    ctx.audit(uow, 'create', 'purchase', id, '$number ${purchase.total.format()}');
    return purchase;
  }

  /// Cancels a purchase only if none of its stock has been used yet.
  Future<void> cancel(String purchaseId, String reason) async {
    ctx.require(Permission.cancelTransactions);
    if (reason.trim().isEmpty) throw const ValidationException('A reason is required.');
    final uow = ctx.uow();
    final j = uow.read(Boxes.purchases, purchaseId);
    if (j == null) throw const NotFoundException('Purchase not found.');
    final pur = Purchase.fromJson(j);
    if (pur.status == DocStatus.cancelled) throw const BusinessException('Already cancelled.');
    if (pur.items.any((e) => e.returnedQty.isPositive)) throw const BusinessException('This purchase has returns. Cancel is not allowed.');
    final layers = uow.values(Boxes.costLayers).map(CostLayer.fromJson).where((l) => l.sourceType == 'purchase' && l.sourceId == pur.id).toList();
    for (final l in layers) {
      if (l.qtyRemaining != l.qtyIn) {
        throw const BusinessException('Some items from this purchase were already sold or issued. Use a purchase return instead.');
      }
    }
    for (final it in pur.items) {
      final rec = serials.requireAll(uow, it.serials, it.productId, {SerialStatus.inStock}, 'cancellation');
      for (final r in rec) {
        if (r.history.length > 1) throw BusinessException('Serial ${r.display} has later history. Use a purchase return instead.');
        serials.remove(uow, r);
      }
      inv.stockOut(uow, productId: it.productId, qty: it.qty, type: 'purchaseCancel', refType: 'purchase', refId: pur.id, reason: reason, preferSourceId: pur.id);
    }
    uow.put(Boxes.purchases, pur.id, pur.copyWith(status: DocStatus.cancelled, cancelReason: reason).toJson());
    parties.post(uow,
        kind: PartyKind.supplier,
        partyId: pur.supplierId,
        type: LedgerType.reversal,
        debit: pur.total,
        refType: 'purchase_cancel',
        refId: pur.id,
        refNumber: pur.number,
        note: 'Cancelled: $reason');
    if (pur.paidAtPurchase.isPositive) {
      parties.recordPayment(uow,
          kind: PartyKind.supplier,
          partyId: pur.supplierId,
          amount: pur.paidAtPurchase,
          method: pur.method,
          direction: PaymentDirection.received,
          refType: 'purchase_cancel',
          refId: pur.id,
          refNumber: pur.number,
          note: 'Refund on cancellation');
    }
    ctx.audit(uow, 'cancel', 'purchase', pur.id, reason);
    await uow.commit();
  }

  /// Returns goods to the supplier. Credit reduces the payable; optionally
  /// the supplier refunds cash.
  Future<ReturnDoc> createReturn({
    required String purchaseId,
    required List<ReturnLineInput> lines,
    required String reason,
    RefundMode refundMode = RefundMode.accountCredit,
    PaymentMethod method = PaymentMethod.cash,
    DateTime? date,
  }) async {
    ctx.require(Permission.managePurchases);
    if (lines.isEmpty) throw const ValidationException('Select at least one item to return.');
    if (reason.trim().isEmpty) throw const ValidationException('Please enter a return reason.');
    final uow = ctx.uow();
    final j = uow.read(Boxes.purchases, purchaseId);
    if (j == null) throw const NotFoundException('Purchase not found.');
    var pur = Purchase.fromJson(j);
    if (pur.status == DocStatus.cancelled) throw const BusinessException('This purchase is cancelled.');
    final id = newId();
    final number = ctx.nextNumber(uow, 'purchase_return', 'PRT');
    final when = date ?? ctx.now();
    final items = [...pur.items];
    final out = <ReturnLine>[];
    for (final l in lines) {
      final idx = items.indexWhere((e) => e.productId == l.productId);
      if (idx < 0) throw const ValidationException('Product is not on this purchase.');
      final it = items[idx];
      final eligible = it.qty - it.returnedQty;
      final p = inv.product(uow, it.productId);
      inv.checkQty(p, l.qty);
      if (l.qty > eligible) throw ValidationException('You can return at most ${eligible.format()} of "${it.name}".');
      var keys = <String>[];
      if (p.requiresSerial) {
        final sers = serials.normalizeList(l.serials, expectedQty: l.qty.wholeUnits, productName: p.name);
        final recs = serials.requireAll(uow, sers, p.id, {SerialStatus.inStock, SerialStatus.damaged, SerialStatus.awaitingRepair}, 'supplier return');
        for (final r in recs) {
          if (r.purchaseId != pur.id) throw ValidationException('Serial "${r.display}" was not bought on ${pur.number}.');
          if (r.status == SerialStatus.damaged) {
            inv.changeBucket(uow, p.id, StockBucket.damaged, -const Qty.one(), 'purchaseReturn', 'purchase_return', id, reason);
          } else if (r.status == SerialStatus.awaitingRepair) {
            inv.changeBucket(uow, p.id, StockBucket.repairable, -const Qty.one(), 'purchaseReturn', 'purchase_return', id, reason);
          } else {
            inv.stockOut(uow, productId: p.id, qty: const Qty.one(), type: 'purchaseReturn', refType: 'purchase_return', refId: id, reason: reason, preferSourceId: pur.id);
          }
          serials.save(uow, r.transition(SerialStatus.returnedToSupplier, at: when, note: 'Returned to supplier $number', refType: 'purchase_return', refId: id, userId: ctx.userId));
          keys.add(r.key);
        }
      } else {
        inv.stockOut(uow, productId: p.id, qty: l.qty, type: 'purchaseReturn', refType: 'purchase_return', refId: id, reason: reason, preferSourceId: pur.id);
      }
      final value = it.net.shareQty(l.qty, it.qty);
      out.add(ReturnLine(productId: p.id, name: it.name, qty: l.qty, serials: keys, amount: value, cost: it.landedUnitCost.timesQty(l.qty)));
      items[idx] = it.withReturned(it.returnedQty + l.qty);
    }
    pur = pur.copyWith(items: items);
    final doc = ReturnDoc(
      id: id,
      number: number,
      originalId: pur.id,
      originalNumber: pur.number,
      partyId: pur.supplierId,
      date: when,
      lines: out,
      refundMode: refundMode,
      method: method,
      reason: reason,
      userId: ctx.userId,
    );
    uow.put(Boxes.purchases, pur.id, pur.toJson());
    uow.put(Boxes.purchaseReturns, id, doc.toJson());
    parties.post(uow,
        kind: PartyKind.supplier, partyId: pur.supplierId, type: LedgerType.purchaseReturn, debit: doc.total, refType: 'purchase_return', refId: id, refNumber: number, note: reason, at: when);
    if (refundMode == RefundMode.cash) {
      parties.recordPayment(uow,
          kind: PartyKind.supplier,
          partyId: pur.supplierId,
          amount: doc.total,
          method: method,
          direction: PaymentDirection.received,
          refType: 'purchase_return',
          refId: id,
          refNumber: number,
          at: when);
    }
    ctx.audit(uow, 'create', 'purchase_return', id, '$number ${doc.total.format()}');
    await uow.commit();
    return doc;
  }

  List<ReturnDoc> returns({DateTime? from, DateTime? to}) => ctx.all(Boxes.purchaseReturns, ReturnDoc.fromJson).where((r) {
        if (from != null && r.date.isBefore(dayStart(from))) return false;
        if (to != null && r.date.isAfter(dayEnd(to))) return false;
        return true;
      }).toList()
        ..sort((a, b) => b.date.compareTo(a.date));
}
