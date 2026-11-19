import '../../core/errors.dart';
import '../../core/ids.dart';
import '../../core/money.dart';
import '../../core/qty.dart';
import '../../data/store/data_store.dart';
import '../models/documents.dart';
import '../models/json_utils.dart';
import '../models/operations.dart';
import '../models/party.dart';
import '../models/product.dart';
import '../models/user.dart';
import 'auth_service.dart';
import 'context.dart';
import 'inspection_service.dart';
import 'inventory_engine.dart';
import 'party_service.dart';
import 'purchase_service.dart' show ReturnLineInput;
import 'serial_service.dart';

class SalesService {
  final ServiceContext ctx;
  final InventoryEngine inv;
  final PartyService parties;
  final SerialService serials;
  final InspectionService inspections;
  SalesService(this.ctx, this.inv, this.parties, this.serials, this.inspections);

  List<Sale> list({DateTime? from, DateTime? to, String? customerId, DocStatus? status, String query = ''}) {
    final q = query.trim().toLowerCase();
    return ctx.all(Boxes.sales, Sale.fromJson).where((x) {
      if (status != null && x.status != status) return false;
      if (customerId != null && x.customerId != customerId) return false;
      if (from != null && x.date.isBefore(dayStart(from))) return false;
      if (to != null && x.date.isAfter(dayEnd(to))) return false;
      if (q.isNotEmpty && !x.number.toLowerCase().contains(q) && !x.customerName.toLowerCase().contains(q)) return false;
      return true;
    }).toList()
      ..sort((a, b) => b.date.compareTo(a.date));
  }

  Sale? byId(String id) {
    final j = ctx.store.read(Boxes.sales, id);
    return j == null ? null : Sale.fromJson(j);
  }

  /// Empty draft ready for the POS screen.
  Sale newDraft() => Sale(
        id: newId(),
        number: 'DRAFT',
        date: ctx.now(),
        items: const [],
        createdBy: ctx.userId,
        createdAt: ctx.now(),
        method: PaymentMethod.values.firstWhere((m0) => m0.name == ctx.settings.defaultPaymentMethod, orElse: () => PaymentMethod.cash),
      );

  /// Saves a draft (held bill). Drafts never affect stock or accounts.
  Future<Sale> saveDraft(Sale draft) async {
    ctx.require(Permission.manageSales);
    if (draft.status != DocStatus.draft) throw const BusinessException('Only drafts can be saved this way.');
    final existing = byId(draft.id);
    if (existing != null && existing.status != DocStatus.draft) throw const BusinessException('This invoice is already completed.');
    final w = ctx.uow()..put(Boxes.sales, draft.id, draft.toJson());
    await w.commit();
    return draft;
  }

  Future<void> deleteDraft(String id) async {
    ctx.require(Permission.manageSales);
    final d = byId(id);
    if (d == null) return;
    if (d.status != DocStatus.draft) throw const BusinessException('Completed invoices cannot be deleted. Cancel them instead.');
    final w = ctx.uow()..delete(Boxes.sales, id);
    await w.commit();
  }

  /// True when completing [draft] would need owner credit approval.
  bool needsCreditApproval(Sale draft) => draft.paidAtSale < draft.total && !ctx.can(Permission.approveCredit);

  /// Completes a sale atomically: invoice number, stock-out with FIFO COGS,
  /// serial status + warranty, customer ledger and payment.
  ///
  /// Credit (paid < total) needs a customer account and owner approval:
  /// either the logged-in user holds `approveCredit` or [creditApproval]
  /// was obtained from [AuthService.authorize].
  Future<Sale> complete(Sale draft, {bool allowNegativeStock = false, Authorization? creditApproval}) async {
    ctx.require(Permission.manageSales);
    if (allowNegativeStock) ctx.require(Permission.allowNegativeStock);
    if (draft.items.isEmpty) throw const ValidationException('Add at least one product.');
    final existing = byId(draft.id);
    if (existing != null && existing.status != DocStatus.draft) throw const BusinessException('This invoice is already completed.');
    if (draft.paidAtSale.isNegative || draft.invoiceDiscount.isNegative) throw const ValidationException('Amounts cannot be negative.');

    final uow = ctx.uow();
    Party? customer;
    if (draft.customerId != null) customer = parties.require(uow, PartyKind.customer, draft.customerId!);
    final total = draft.total;
    if (total.isNegative) throw const ValidationException('Discount is larger than the invoice amount.');
    if (draft.paidAtSale > total) throw const ValidationException('Paid amount is more than the invoice total.');
    String? approvedBy;
    if (draft.paidAtSale < total) {
      if (customer == null) {
        throw const ValidationException('Credit sale: select or create a customer account for the unpaid balance.');
      }
      if (ctx.can(Permission.approveCredit)) {
        approvedBy = ctx.userId;
      } else if (creditApproval != null && creditApproval.permission == Permission.approveCredit) {
        approvedBy = creditApproval.userId;
      } else {
        throw const PermissionException('Credit sale needs owner approval.');
      }
    }

    final number = ctx.nextNumber(uow, 'sale', ctx.settings.invoicePrefix);
    final id = draft.id;
    final policy = ctx.settings.warrantyStartPolicy;
    final seen = <String>{};
    final items = <SaleItem>[];
    for (final it in draft.items) {
      if (it.unitPrice.isNegative || it.discount.isNegative) throw const ValidationException('Amounts cannot be negative.');
      if (it.net.isNegative) throw ValidationException('Discount on "${it.name}" is larger than the line amount.');
      final p = inv.product(uow, it.productId);
      inv.checkQty(p, it.qty);
      var recs = <SerialRecord>[];
      Money cogs;
      DateTime warrantyFrom = draft.date;
      if (it.techUsageId != null) {
        // Material already installed by a technician: no shop stock movement.
        final uj = uow.read(Boxes.techTxns, it.techUsageId!);
        if (uj == null) throw const NotFoundException('Installation record not found.');
        final usage = TechTxn.fromJson(uj);
        if (usage.type != TechTxnType.installed || usage.productId != p.id) throw const ValidationException('Installation record does not match.');
        if (usage.invoicedSaleId != null) throw const BusinessException('This installation is already invoiced.');
        if (usage.qty != it.qty) throw ValidationException('Installed quantity is ${usage.qty.format()}; invoice must use the same quantity.');
        if (customer != null && usage.customerId != null && usage.customerId != customer.id) {
          throw const ValidationException('This installation belongs to a different customer.');
        }
        cogs = usage.cost;
        warrantyFrom = policy == WarrantyStartPolicy.installationDate ? usage.at : draft.date;
        if (p.requiresSerial) {
          final sers = it.serials.isEmpty ? usage.serials : serials.normalizeList(it.serials, expectedQty: it.qty.wholeUnits, productName: p.name);
          recs = serials.requireAll(uow, sers, p.id, {SerialStatus.installed}, 'invoicing');
          if (!recs.every((r) => usage.serials.contains(r.key))) throw const ValidationException('Serials must match the installation record.');
        }
        uow.put(Boxes.techTxns, usage.id, usage.markInvoiced(id, it.qty).toJson());
      } else {
        if (p.requiresSerial) {
          final sers = serials.normalizeList(it.serials, expectedQty: it.qty.wholeUnits, productName: p.name);
          recs = serials.requireAll(uow, sers, p.id, {SerialStatus.inStock}, 'sale');
        }
        cogs = inv.stockOut(uow, productId: p.id, qty: it.qty, type: 'sale', refType: 'sale', refId: id, reason: number, allowNegative: allowNegativeStock, units: recs);
      }
      for (final r in recs) {
        if (!seen.add(r.key)) throw DuplicateException('Serial "${r.display}" is on the invoice twice.');
        final wStart = p.warrantyMonths > 0 ? warrantyFrom : null;
        serials.save(
            uow,
            r.transition(SerialStatus.sold,
                at: ctx.now(),
                note: 'Sold on $number',
                refType: 'sale',
                refId: id,
                userId: ctx.userId,
                customerId: customer?.id,
                saleId: id,
                clearTechnician: true,
                warrantyStart: wStart,
                warrantyExpiry: wStart == null ? null : addMonths(wStart, p.warrantyMonths)));
      }
      items.add(it.copyWith(serials: recs.map((r) => r.key).toList(), cogs: cogs));
    }

    final sale = draft.copyWith(
      number: number,
      items: items,
      status: DocStatus.completed,
      customerName: customer?.name ?? 'Walk-in Customer',
      creditApprovedBy: approvedBy,
    );
    uow.put(Boxes.sales, id, sale.toJson());
    if (customer != null) {
      parties.post(uow, kind: PartyKind.customer, partyId: customer.id, type: LedgerType.sale, debit: total, refType: 'sale', refId: id, refNumber: number, at: sale.date);
    }
    if (sale.paidAtSale.isPositive) {
      parties.recordPayment(uow,
          kind: customer == null ? null : PartyKind.customer,
          partyId: customer?.id,
          amount: sale.paidAtSale,
          method: sale.method,
          direction: PaymentDirection.received,
          refType: 'sale',
          refId: id,
          refNumber: number,
          at: sale.date);
    }
    ctx.audit(uow, 'complete', 'sale', id, '$number ${total.format()}${approvedBy != null ? ' credit approved by $approvedBy' : ''}');
    await uow.commit();
    return sale;
  }

  /// Cancels a completed invoice. Stock, serials and accounts are reversed by
  /// new records; the invoice is kept with status "cancelled".
  Future<void> cancel(String saleId, String reason) async {
    ctx.require(Permission.cancelTransactions);
    if (reason.trim().isEmpty) throw const ValidationException('A reason is required.');
    final uow = ctx.uow();
    final j = uow.read(Boxes.sales, saleId);
    if (j == null) throw const NotFoundException('Invoice not found.');
    final sale = Sale.fromJson(j);
    if (sale.status != DocStatus.completed) throw const BusinessException('Only completed invoices can be cancelled.');
    if (sale.items.any((e) => e.returnedQty.isPositive)) throw const BusinessException('This invoice has returns and cannot be cancelled.');
    for (final it in sale.items) {
      if (it.techUsageId != null) {
        final usage = TechTxn.fromJson(uow.read(Boxes.techTxns, it.techUsageId!)!);
        uow.put(Boxes.techTxns, usage.id, usage.clearInvoice().toJson());
        for (final k in it.serials) {
          final r = serials.resolve(uow, k, it.productId);
          serials.save(uow,
              r.transition(SerialStatus.installed, at: ctx.now(), note: 'Invoice ${sale.number} cancelled', refType: 'sale_cancel', refId: sale.id, userId: ctx.userId, clearSale: true, clearWarranty: true));
        }
        continue;
      }
      if (it.serials.isNotEmpty) {
        inv.stockInUnits(uow,
            productId: it.productId, units: [for (final k in it.serials) serials.resolve(uow, k, it.productId)], fallbackTotal: it.cogs, type: 'saleCancel', refType: 'sale_cancel', refId: sale.id, reason: reason);
      } else {
        inv.stockIn(uow,
            productId: it.productId, qty: it.qty, unitCost: it.cogs.perUnit(it.qty), totalCost: it.cogs, type: 'saleCancel', refType: 'sale_cancel', refId: sale.id, reason: reason);
      }
      for (final k in it.serials) {
        final r = serials.resolve(uow, k, it.productId);
        serials.save(uow,
            r.transition(SerialStatus.inStock,
                at: ctx.now(), note: 'Invoice ${sale.number} cancelled', refType: 'sale_cancel', refId: sale.id, userId: ctx.userId, clearCustomer: true, clearSale: true, clearWarranty: true));
      }
    }
    if (sale.customerId != null) {
      parties.post(uow,
          kind: PartyKind.customer, partyId: sale.customerId!, type: LedgerType.reversal, credit: sale.total, refType: 'sale_cancel', refId: sale.id, refNumber: sale.number, note: 'Cancelled: $reason');
    }
    if (sale.paidAtSale.isPositive) {
      parties.recordPayment(uow,
          kind: sale.customerId == null ? null : PartyKind.customer,
          partyId: sale.customerId,
          amount: sale.paidAtSale,
          method: sale.method,
          direction: PaymentDirection.paid,
          refType: 'sale_cancel',
          refId: sale.id,
          refNumber: sale.number,
          note: 'Refund on cancellation');
    }
    uow.put(Boxes.sales, sale.id, sale.copyWith(status: DocStatus.cancelled, cancelReason: reason).toJson());
    ctx.audit(uow, 'cancel', 'sale', sale.id, reason);
    await uow.commit();
  }

  /// Customer return against an original invoice. Condition per line:
  /// resellable (back to stock), damaged, or inspect (owner QC queue).
  Future<ReturnDoc> createReturn({
    required String saleId,
    required List<ReturnLineInput> lines,
    required String reason,
    RefundMode refundMode = RefundMode.cash,
    PaymentMethod method = PaymentMethod.cash,
    DateTime? date,
  }) async {
    ctx.require(Permission.manageSales);
    if (lines.isEmpty) throw const ValidationException('Select at least one item to return.');
    if (reason.trim().isEmpty) throw const ValidationException('Please enter a return reason.');
    final uow = ctx.uow();
    final j = uow.read(Boxes.sales, saleId);
    if (j == null) throw const NotFoundException('Invoice not found.');
    var sale = Sale.fromJson(j);
    if (sale.status != DocStatus.completed) throw const BusinessException('Returns are only allowed on completed invoices.');
    if (sale.customerId == null && refundMode == RefundMode.accountCredit) {
      throw const ValidationException('Walk-in sales can only be refunded in cash.');
    }
    final id = newId();
    final number = ctx.nextNumber(uow, 'sales_return', 'SRT');
    final when = date ?? ctx.now();
    final items = [...sale.items];
    final out = <ReturnLine>[];
    for (final l in lines) {
      final idx = items.indexWhere((e) => e.productId == l.productId && (e.qty - e.returnedQty).isPositive);
      if (idx < 0) throw const ValidationException('Product is not on this invoice or already fully returned.');
      final it = items[idx];
      final eligible = it.qty - it.returnedQty;
      final p = inv.product(uow, it.productId);
      inv.checkQty(p, l.qty);
      if (l.qty > eligible) throw ValidationException('You can return at most ${eligible.format()} of "${it.name}".');
      var recs = <SerialRecord>[];
      if (p.requiresSerial) {
        final sers = serials.normalizeList(l.serials, expectedQty: l.qty.wholeUnits, productName: p.name);
        recs = serials.requireAll(uow, sers, p.id, {SerialStatus.sold}, 'return');
        for (final r in recs) {
          if (r.saleId != sale.id) throw ValidationException('Serial "${r.display}" was not sold on ${sale.number}.');
        }
      }
      // A serial unit's cost is its own batch cost; others share the line cost.
      final cost = InventoryEngine.unitsCost(recs) ?? it.cogs.shareQty(l.qty, it.qty);
      final refund = sale.lineRevenue(idx).shareQty(l.qty, it.qty);
      switch (l.condition) {
        case 'damaged':
          inv.changeBucket(uow, p.id, StockBucket.damaged, l.qty, 'salesReturn', 'sales_return', id, reason, cost);
          for (final r in recs) {
            serials.save(uow,
                r.transition(SerialStatus.damaged, at: when, note: 'Customer return $number (damaged)', refType: 'sales_return', refId: id, userId: ctx.userId, clearCustomer: true, clearSale: true, clearWarranty: true));
          }
        case 'inspect':
          inspections.enqueue(uow, product: p, qty: l.qty, cost: cost, serialRecords: recs, sourceType: 'sales_return', sourceId: id, condition: 'customer return', reason: reason);
        default:
          if (recs.isNotEmpty) {
            inv.stockInUnits(uow, productId: p.id, units: recs, fallbackTotal: cost, type: 'salesReturn', refType: 'sales_return', refId: id, reason: reason);
          } else {
            inv.stockIn(uow, productId: p.id, qty: l.qty, unitCost: cost.perUnit(l.qty), totalCost: cost, type: 'salesReturn', refType: 'sales_return', refId: id, reason: reason);
          }
          for (final r in recs) {
            serials.save(uow,
                r.transition(SerialStatus.inStock, at: when, note: 'Customer return $number', refType: 'sales_return', refId: id, userId: ctx.userId, clearCustomer: true, clearSale: true, clearWarranty: true));
          }
      }
      out.add(ReturnLine(productId: p.id, name: it.name, qty: l.qty, serials: recs.map((r) => r.key).toList(), amount: refund, cost: cost, condition: l.condition));
      items[idx] = it.copyWith(returnedQty: it.returnedQty + l.qty);
    }
    sale = sale.copyWith(items: items);
    final doc = ReturnDoc(
      id: id,
      number: number,
      originalId: sale.id,
      originalNumber: sale.number,
      partyId: sale.customerId,
      date: when,
      lines: out,
      refundMode: refundMode,
      method: method,
      reason: reason,
      userId: ctx.userId,
    );
    uow.put(Boxes.sales, sale.id, sale.toJson());
    uow.put(Boxes.salesReturns, id, doc.toJson());
    if (sale.customerId != null) {
      parties.post(uow,
          kind: PartyKind.customer, partyId: sale.customerId!, type: LedgerType.salesReturn, credit: doc.total, refType: 'sales_return', refId: id, refNumber: number, note: reason, at: when);
    }
    if (refundMode == RefundMode.cash && doc.total.isPositive) {
      parties.recordPayment(uow,
          kind: sale.customerId == null ? null : PartyKind.customer,
          partyId: sale.customerId,
          amount: doc.total,
          method: method,
          direction: PaymentDirection.paid,
          refType: 'sales_return',
          refId: id,
          refNumber: number,
          note: 'Refund',
          at: when);
    }
    ctx.audit(uow, 'create', 'sales_return', id, '$number ${doc.total.format()}');
    await uow.commit();
    return doc;
  }

  List<ReturnDoc> returns({DateTime? from, DateTime? to}) => ctx.all(Boxes.salesReturns, ReturnDoc.fromJson).where((r) {
        if (from != null && r.date.isBefore(dayStart(from))) return false;
        if (to != null && r.date.isAfter(dayEnd(to))) return false;
        return true;
      }).toList()
        ..sort((a, b) => b.date.compareTo(a.date));

  /// Sale line priced from the product's current price (for POS add).
  SaleItem lineFor(Product p, {Qty qty = const Qty.one(), List<String> serials = const [], bool wholesale = false}) => SaleItem(
      productId: p.id, name: p.name, qty: qty, unitPrice: wholesale && p.wholesalePrice != null ? p.wholesalePrice! : p.sellingPrice, serials: serials);
}
