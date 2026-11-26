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
      if (it.kind == SaleLineKind.service) {
        // Labour belongs to the worker: it goes on a separate labour bill.
        throw ValidationException('"${it.name}" is labour / installation. It goes on a separate labour bill, not on the shop invoice.');
      }
      if (!it.isStock) {
        // Non-stock item: no product record, no stock movement.
        items.add(_checkCustomLine(it));
        continue;
      }
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

  // ── Billing presets (frequently used non-stock items and services) ──

  static const _presetKey = 'billing_presets';

  List<BillingPreset> presets() {
    final j = ctx.store.read(Boxes.settings, _presetKey);
    final list = mapList(j?['items']).map(BillingPreset.fromJson).where((p) => p.name.trim().isNotEmpty).toList();
    list.sort((a, b) => a.kind.index != b.kind.index ? a.kind.index.compareTo(b.kind.index) : a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  }

  /// Saves (or replaces, by kind and name) a preset.
  Future<void> savePreset(BillingPreset p) async {
    ctx.require(Permission.manageSales);
    if (p.kind == SaleLineKind.product) throw const ValidationException('Presets are for non-stock items and services.');
    if (p.name.trim().isEmpty) throw const ValidationException('Enter a description.');
    if (p.unitPrice.isNegative) throw const ValidationException('Price cannot be negative.');
    final clean = BillingPreset(kind: p.kind, name: p.name.trim(), unitPrice: p.unitPrice, unit: p.unit.trim());
    final rest = presets().where((x) => !(x.kind == clean.kind && x.name.toLowerCase() == clean.name.toLowerCase()));
    final uow = ctx.uow()..put(Boxes.settings, _presetKey, {'items': [...rest.map((e) => e.toJson()), clean.toJson()]});
    ctx.audit(uow, 'update', 'billing_preset', clean.name, '${clean.kind.label}: ${clean.unitPrice.format()}');
    await uow.commit();
  }

  Future<void> deletePreset(SaleLineKind kind, String name) async {
    ctx.require(Permission.manageSales);
    final rest = presets().where((x) => !(x.kind == kind && x.name.toLowerCase() == name.trim().toLowerCase()));
    final uow = ctx.uow()..put(Boxes.settings, _presetKey, {'items': rest.map((e) => e.toJson()).toList()});
    ctx.audit(uow, 'delete', 'billing_preset', name, kind.label);
    await uow.commit();
  }

  /// The customer's account balance right after a return was recorded
  /// (including its cash refund). Negative = credit held for the customer.
  /// Null for walk-in returns.
  Money? customerBalanceAfterReturn(ReturnDoc r) {
    if (r.partyId == null) return null;
    final entries = parties.entries(PartyKind.customer, r.partyId!);
    final refundIds = {
      for (final p in ctx.all(Boxes.payments, Payment.fromJson))
        if (p.refType == 'sales_return' && p.refId == r.id) p.id
    };
    var last = -1;
    for (var k = 0; k < entries.length; k++) {
      final e = entries[k];
      if ((e.refType == 'sales_return' && e.refId == r.id) || (e.refType == 'payment' && refundIds.contains(e.refId))) last = k;
    }
    if (last < 0) return null;
    return Money.sum(entries.take(last + 1).map((e) => e.balanceEffect));
  }

  SaleItem _checkCustomLine(SaleItem it) {
    if (it.name.trim().isEmpty) throw ValidationException('Enter a description for the ${it.kind.label.toLowerCase()}.');
    if (!it.qty.isPositive) throw ValidationException('Quantity of "${it.name}" must be more than zero.');
    if (it.techUsageId != null || it.serials.isNotEmpty) throw ValidationException('"${it.name}" cannot have serial numbers.');
    return SaleItem.custom(kind: it.kind, name: it.name.trim(), qty: it.qty, unitPrice: it.unitPrice, discount: it.discount, unit: it.unit.trim());
  }

  /// [paidAgainst] for every invoice at once (for lists).
  Map<String, Money> paidBySale() {
    final out = <String, Money>{};
    for (final p in ctx.all(Boxes.payments, Payment.fromJson)) {
      if (p.voided) continue;
      if (p.direction == PaymentDirection.received && p.refType == 'sale') out[p.refId] = (out[p.refId] ?? const Money.zero()) + p.amount;
      if (p.direction == PaymentDirection.paid && p.refType == 'sale_edit') out[p.refId] = (out[p.refId] ?? const Money.zero()) - p.amount;
    }
    return out;
  }

  /// Payments received against an invoice, less money paid back on it.
  Money paidAgainst(String saleId) {
    var paid = const Money.zero();
    for (final p in ctx.all(Boxes.payments, Payment.fromJson)) {
      if (p.voided || p.refId != saleId) continue;
      if (p.direction == PaymentDirection.received && p.refType == 'sale') paid += p.amount;
      if (p.direction == PaymentDirection.paid && p.refType == 'sale_edit') paid -= p.amount;
    }
    return paid;
  }

  /// Edits a completed invoice: products and quantities, prices, discounts,
  /// non-stock items and services, notes.
  ///
  /// The invoice keeps its number, date and every payment. Stock and serial
  /// numbers follow the change (removed units go back to stock at their own
  /// cost, added units are taken from stock). For a customer the change in
  /// total is posted as a separate ledger entry, so the balance is right and
  /// the original sale entry stays as it was. [receivedNow] records an extra
  /// payment against the invoice. A walk-in invoice must stay fully paid;
  /// if its total goes down the difference is paid back as a cash refund.
  /// Every edit is kept in the invoice's edit history.
  Future<Sale> editInvoice(
    String saleId, {
    required List<SaleItem> items,
    required Money invoiceDiscount,
    String? notes,
    required String reason,
    Money receivedNow = const Money.zero(),
    PaymentMethod method = PaymentMethod.cash,
  }) async {
    ctx.require(Permission.editInvoices);
    if (reason.trim().isEmpty) throw const ValidationException('Write why the invoice is being changed.');
    if (items.isEmpty) throw const ValidationException('An invoice needs at least one line.');
    if (invoiceDiscount.isNegative || receivedNow.isNegative) throw const ValidationException('Amounts cannot be negative.');
    final uow = ctx.uow();
    final j = uow.read(Boxes.sales, saleId);
    if (j == null) throw const NotFoundException('Invoice not found.');
    final sale = Sale.fromJson(j);
    if (sale.status != DocStatus.completed) throw const BusinessException('Only completed invoices can be edited.');
    if (sale.items.any((e) => e.returnedQty.isPositive)) {
      throw const BusinessException('This invoice has returns. Record further changes as a return instead of editing it.');
    }
    if (sale.items.any((e) => e.techUsageId != null) || items.any((e) => e.techUsageId != null)) {
      throw const BusinessException('This invoice bills material a technician installed and cannot be edited. Cancel it and bill again.');
    }
    for (final it in items) {
      if (it.unitPrice.isNegative || it.discount.isNegative) throw const ValidationException('Amounts cannot be negative.');
      if (it.net.isNegative) throw ValidationException('Discount on "${it.name}" is larger than the line amount.');
      if (it.isStock && !it.qty.isPositive) throw ValidationException('Quantity of "${it.name}" must be more than zero.');
    }
    // Labour lines from before labour bills existed may stay (or be removed);
    // new labour goes on a labour bill.
    if (items.where((e) => e.kind == SaleLineKind.service).length > sale.items.where((e) => e.kind == SaleLineKind.service).length) {
      throw const ValidationException('New labour / installation goes on a separate labour bill, not on the shop invoice.');
    }
    final draft = sale.copyWith(items: items, invoiceDiscount: invoiceDiscount);
    final newTotal = draft.total;
    if (newTotal.isNegative) throw const ValidationException('Discount is larger than the invoice amount.');
    final oldTotal = sale.total;
    final paid = paidAgainst(sale.id);
    Party? customer;
    if (sale.customerId != null) customer = parties.require(uow, PartyKind.customer, sale.customerId!);
    var refund = const Money.zero();
    if (customer == null) {
      final due = newTotal - paid;
      if (receivedNow > due && due.isPositive) throw ValidationException('Only ${due.format()} is due on this invoice.');
      if (due.isPositive && receivedNow < due) {
        throw ValidationException('A walk-in invoice must be fully paid: receive ${due.format()} now, or select a customer account first.');
      }
      if (due.isNegative) refund = -due;
    } else {
      final due = newTotal - paid;
      if (receivedNow.isPositive && receivedNow > due) {
        throw ValidationException(due.isPositive ? 'Only ${due.format()} is due on this invoice.' : 'Nothing is due on this invoice.');
      }
    }

    // ── Stock and serial numbers, product by product ──
    final seen = <String>{};
    final newItems = <SaleItem>[for (final it in items) it.isStock ? it : _checkCustomLine(it)];
    final pids = <String>{for (final it in sale.items) if (it.isStock) it.productId, for (final it in items) if (it.isStock) it.productId};
    for (final pid in pids) {
      final p = inv.product(uow, pid);
      final oldLines = sale.items.where((e) => e.isStock && e.productId == pid).toList();
      final newIdx = [for (var k = 0; k < newItems.length; k++) if (newItems[k].isStock && newItems[k].productId == pid) k];
      final oldQty = Qty.sum(oldLines.map((e) => e.qty));
      final oldCogs = Money.sum(oldLines.map((e) => e.cogs));
      Money cogsTotal;
      if (p.requiresSerial) {
        final oldKeys = [for (final l in oldLines) ...l.serials];
        final newKeysByLine = <int, List<String>>{};
        for (final k in newIdx) {
          final it = newItems[k];
          final keys = <String>[];
          if (it.serials.length != it.qty.wholeUnits || it.serials.isEmpty) {
            throw ValidationException('"${p.name}" needs one serial number per unit (${it.qty.format()}).');
          }
          for (final sr in it.serials) {
            final known = SerialRecord.isKey(sr) ? sr : serials.resolve(uow, sr, pid, preferStatus: {SerialStatus.inStock}).key;
            if (!seen.add(known)) throw DuplicateException('Serial "${SerialRecord.displayOf(known)}" is on the invoice twice.');
            keys.add(known);
          }
          newKeysByLine[k] = keys;
        }
        final newKeys = newKeysByLine.values.expand((e) => e).toSet();
        final removed = oldKeys.where((k) => !newKeys.contains(k)).toList();
        final added = newKeys.where((k) => !oldKeys.contains(k)).toList();
        if (removed.isNotEmpty) {
          final units = [for (final k in removed) serials.resolve(uow, k, pid)];
          final back = oldCogs.shareQty(Qty.units(removed.length), Qty.units(oldKeys.length));
          inv.stockInUnits(uow, productId: pid, units: units, fallbackTotal: back, type: 'saleEdit', refType: 'sale_edit', refId: sale.id, reason: '${sale.number}: $reason');
          for (final r in units) {
            serials.save(uow,
                r.transition(SerialStatus.inStock,
                    at: ctx.now(), note: 'Removed from ${sale.number} (invoice edited)', refType: 'sale_edit', refId: sale.id, userId: ctx.userId, clearCustomer: true, clearSale: true, clearWarranty: true));
          }
        }
        final keptCogs = oldKeys.isEmpty ? const Money.zero() : oldCogs.shareQty(Qty.units(oldKeys.length - removed.length), Qty.units(oldKeys.length));
        var addedCogs = const Money.zero();
        if (added.isNotEmpty) {
          final recs = serials.requireAll(uow, added, pid, {SerialStatus.inStock}, 'invoice edit');
          addedCogs = inv.stockOut(uow, productId: pid, qty: Qty.units(recs.length), type: 'saleEdit', refType: 'sale_edit', refId: sale.id, reason: sale.number, units: recs);
          for (final r in recs) {
            final wStart = p.warrantyMonths > 0 ? sale.date : null;
            serials.save(
                uow,
                r.transition(SerialStatus.sold,
                    at: ctx.now(),
                    note: 'Added to ${sale.number} (invoice edited)',
                    refType: 'sale',
                    refId: sale.id,
                    userId: ctx.userId,
                    customerId: customer?.id,
                    saleId: sale.id,
                    clearTechnician: true,
                    warrantyStart: wStart,
                    warrantyExpiry: wStart == null ? null : addMonths(wStart, p.warrantyMonths)));
          }
        }
        cogsTotal = keptCogs + addedCogs;
        for (final k in newIdx) {
          newItems[k] = newItems[k].copyWith(serials: newKeysByLine[k], qty: Qty.units(newKeysByLine[k]!.length));
        }
      } else {
        for (final k in newIdx) {
          inv.checkQty(p, newItems[k].qty);
          if (newItems[k].serials.isNotEmpty) newItems[k] = newItems[k].copyWith(serials: const []);
        }
        final newQty = Qty.sum(newIdx.map((k) => newItems[k].qty));
        if (newQty < oldQty) {
          final back = oldQty - newQty;
          final backCost = oldCogs.shareQty(back, oldQty);
          inv.stockIn(uow, productId: pid, qty: back, unitCost: backCost.perUnit(back), totalCost: backCost, type: 'saleEdit', refType: 'sale_edit', refId: sale.id, reason: '${sale.number}: $reason');
          cogsTotal = oldCogs - backCost;
        } else if (newQty > oldQty) {
          cogsTotal = oldCogs + inv.stockOut(uow, productId: pid, qty: newQty - oldQty, type: 'saleEdit', refType: 'sale_edit', refId: sale.id, reason: sale.number);
        } else {
          cogsTotal = oldCogs;
        }
      }
      // Spread the product's cost over its new lines by quantity.
      final totalQty = Qty.sum(newIdx.map((k) => newItems[k].qty));
      var left = cogsTotal;
      for (var n = 0; n < newIdx.length; n++) {
        final k = newIdx[n];
        final share = n == newIdx.length - 1 ? left : cogsTotal.shareQty(newItems[k].qty, totalQty);
        left -= share;
        newItems[k] = newItems[k].copyWith(cogs: share);
      }
    }

    final now = ctx.now();
    final updatedDraft = sale.copyWith(items: newItems, invoiceDiscount: invoiceDiscount, notes: notes ?? sale.notes);
    final edit = SaleEdit(
      id: newId(),
      at: now,
      userId: ctx.userId,
      reason: reason.trim(),
      beforeItems: sale.items,
      beforeDiscount: sale.invoiceDiscount,
      beforeNotes: sale.notes,
      beforeTotal: oldTotal,
      afterItems: newItems,
      afterDiscount: invoiceDiscount,
      afterNotes: updatedDraft.notes,
      afterTotal: updatedDraft.total,
    );
    final updated = updatedDraft.copyWith(edits: [...sale.edits, edit]);
    uow.put(Boxes.sales, sale.id, updated.toJson());
    final diff = updated.total - oldTotal;
    if (customer != null && !diff.isZero) {
      parties.post(uow,
          kind: PartyKind.customer,
          partyId: customer.id,
          type: LedgerType.adjustment,
          debit: diff.isPositive ? diff : const Money.zero(),
          credit: diff.isNegative ? -diff : const Money.zero(),
          refType: 'sale_edit',
          refId: sale.id,
          refNumber: sale.number,
          note: 'Invoice edited: ${oldTotal.format()} to ${updated.total.format()} - ${reason.trim()}',
          at: now);
    }
    if (receivedNow.isPositive) {
      parties.recordPayment(uow,
          kind: customer == null ? null : PartyKind.customer,
          partyId: customer?.id,
          amount: receivedNow,
          method: method,
          direction: PaymentDirection.received,
          refType: 'sale',
          refId: sale.id,
          refNumber: sale.number,
          note: 'Received when invoice was edited',
          at: now);
    }
    if (refund.isPositive) {
      parties.recordPayment(uow,
          kind: null,
          partyId: null,
          amount: refund,
          method: method,
          direction: PaymentDirection.paid,
          refType: 'sale_edit',
          refId: sale.id,
          refNumber: sale.number,
          note: 'Paid back after invoice edit (total ${oldTotal.format()} to ${updated.total.format()})',
          at: now);
    }
    ctx.audit(uow, 'edit', 'sale', sale.id, '${sale.number}: ${oldTotal.format()} -> ${updated.total.format()}. ${reason.trim()}');
    await uow.commit();
    return updated;
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
    Money? amount,
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
      if (!returnConditions.contains(l.condition)) throw ValidationException('Unknown return condition "${l.condition}".');
      final idx = items.indexWhere((e) => e.isStock && e.productId == l.productId && (e.qty - e.returnedQty).isPositive);
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
        case 'faulty':
          // Not sellable: kept apart in the inspection queue, marked Faulty.
          inspections.enqueue(uow, product: p, qty: l.qty, cost: cost, serialRecords: recs, sourceType: 'sales_return', sourceId: id, condition: 'Faulty', reason: '$number: $reason');
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
    // A different settlement amount (for example a deduction for a damaged
    // item) is spread over the returned lines; it can only be lower.
    if (amount != null) {
      final full = Money.sum(out.map((l) => l.amount));
      if (amount.isNegative || amount.isZero) throw const ValidationException('Enter the return amount.');
      if (amount > full) throw ValidationException('The return amount cannot be more than the price charged (${full.format()}).');
      if (amount != full) {
        var left = amount;
        for (var k = 0; k < out.length; k++) {
          final l = out[k];
          final share = k == out.length - 1 ? left : amount.share(l.amount.paisa, full.paisa);
          left -= share;
          out[k] = ReturnLine(productId: l.productId, name: l.name, qty: l.qty, serials: l.serials, amount: share, cost: l.cost, condition: l.condition);
        }
      }
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
