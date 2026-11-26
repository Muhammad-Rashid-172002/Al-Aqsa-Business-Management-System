import '../../core/money.dart';
import '../../core/qty.dart';
import 'json_utils.dart';
import 'party.dart';

enum DocStatus { draft, completed, cancelled }

// ───────────────────────── Purchases ─────────────────────────

class PurchaseItem {
  final String productId;
  final String name; // snapshot
  final Qty qty;
  final Money unitCost;
  final Money discount; // line discount amount
  final Money tax; // line tax amount
  final List<String> serials; // serial keys
  final Qty returnedQty;

  const PurchaseItem({
    required this.productId,
    required this.name,
    required this.qty,
    required this.unitCost,
    this.discount = const Money.zero(),
    this.tax = const Money.zero(),
    this.serials = const [],
    this.returnedQty = const Qty.zero(),
  });

  Money get gross => unitCost.timesQty(qty);
  Money get net => gross - discount + tax;

  /// Landed cost per unit used for FIFO valuation.
  Money get landedUnitCost => net.perUnit(qty);

  PurchaseItem withReturned(Qty r) => PurchaseItem(
      productId: productId, name: name, qty: qty, unitCost: unitCost, discount: discount, tax: tax, serials: serials, returnedQty: r);

  Map<String, dynamic> toJson() => {
        'productId': productId,
        'name': name,
        'qty': qty.milli,
        'unitCost': unitCost.paisa,
        'discount': discount.paisa,
        'tax': tax.paisa,
        'serials': serials,
        'returnedQty': returnedQty.milli,
      };
  factory PurchaseItem.fromJson(Map<String, dynamic> j) => PurchaseItem(
        productId: s(j['productId']),
        name: s(j['name']),
        qty: qy(j['qty']),
        unitCost: m(j['unitCost']),
        discount: m(j['discount']),
        tax: m(j['tax']),
        serials: strList(j['serials']),
        returnedQty: qy(j['returnedQty']),
      );
}

class Purchase {
  final String id;
  final String number;
  final String supplierId;
  final String supplierInvoiceNo;
  final DateTime date;
  final List<PurchaseItem> items;
  final Money paidAtPurchase;
  final PaymentMethod method;
  final String notes;
  final DocStatus status;
  final String createdBy;
  final DateTime createdAt;
  final String cancelReason;

  const Purchase({
    required this.id,
    required this.number,
    required this.supplierId,
    this.supplierInvoiceNo = '',
    required this.date,
    required this.items,
    this.paidAtPurchase = const Money.zero(),
    this.method = PaymentMethod.cash,
    this.notes = '',
    this.status = DocStatus.completed,
    required this.createdBy,
    required this.createdAt,
    this.cancelReason = '',
  });

  Money get subtotal => Money.sum(items.map((e) => e.gross));
  Money get discountTotal => Money.sum(items.map((e) => e.discount));
  Money get taxTotal => Money.sum(items.map((e) => e.tax));
  Money get total => Money.sum(items.map((e) => e.net));
  Money get remaining => total - paidAtPurchase;
  Qty get totalQty => Qty.sum(items.map((e) => e.qty));

  Purchase copyWith({List<PurchaseItem>? items, DocStatus? status, String? cancelReason}) => Purchase(
        id: id,
        number: number,
        supplierId: supplierId,
        supplierInvoiceNo: supplierInvoiceNo,
        date: date,
        items: items ?? this.items,
        paidAtPurchase: paidAtPurchase,
        method: method,
        notes: notes,
        status: status ?? this.status,
        createdBy: createdBy,
        createdAt: createdAt,
        cancelReason: cancelReason ?? this.cancelReason,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'number': number,
        'supplierId': supplierId,
        'supplierInvoiceNo': supplierInvoiceNo,
        'date': date.toIso8601String(),
        'items': items.map((e) => e.toJson()).toList(),
        'paidAtPurchase': paidAtPurchase.paisa,
        'method': method.name,
        'notes': notes,
        'status': status.name,
        'createdBy': createdBy,
        'createdAt': createdAt.toIso8601String(),
        'cancelReason': cancelReason,
        'total': total.paisa, // denormalized for quick listing
      };

  factory Purchase.fromJson(Map<String, dynamic> j) => Purchase(
        id: s(j['id']),
        number: s(j['number']),
        supplierId: s(j['supplierId']),
        supplierInvoiceNo: s(j['supplierInvoiceNo']),
        date: parseDate(j['date']),
        items: mapList(j['items']).map(PurchaseItem.fromJson).toList(),
        paidAtPurchase: m(j['paidAtPurchase']),
        method: enumByName(PaymentMethod.values, j['method'], PaymentMethod.cash),
        notes: s(j['notes']),
        status: enumByName(DocStatus.values, j['status'], DocStatus.completed),
        createdBy: s(j['createdBy']),
        createdAt: parseDate(j['createdAt']),
        cancelReason: s(j['cancelReason']),
      );
}

class ReturnLine {
  final String productId;
  final String name;
  final Qty qty;
  final List<String> serials;
  final Money amount; // refund / credit value
  final Money cost; // cost value of returned units
  final String condition; // resellable | damaged | inspect (sales return)

  const ReturnLine({
    required this.productId,
    required this.name,
    required this.qty,
    this.serials = const [],
    required this.amount,
    this.cost = const Money.zero(),
    this.condition = 'resellable',
  });

  Map<String, dynamic> toJson() => {
        'productId': productId,
        'name': name,
        'qty': qty.milli,
        'serials': serials,
        'amount': amount.paisa,
        'cost': cost.paisa,
        'condition': condition,
      };
  factory ReturnLine.fromJson(Map<String, dynamic> j) => ReturnLine(
        productId: s(j['productId']),
        name: s(j['name']),
        qty: qy(j['qty']),
        serials: strList(j['serials']),
        amount: m(j['amount']),
        cost: m(j['cost']),
        condition: s(j['condition']),
      );
}

enum RefundMode { cash, accountCredit }

/// Condition of a customer-returned item and where its stock goes.
///  resellable: Saleable, back to available stock.
///  faulty: kept aside in the inspection queue (not sellable) for the owner
///    to decide: repair, sell or write off.
///  damaged: damaged stock (not sellable).
///  inspect: not checked yet, inspection queue.
const returnConditions = ['resellable', 'faulty', 'damaged', 'inspect'];

String returnConditionLabel(String condition) => switch (condition) {
      'faulty' => 'Faulty',
      'damaged' => 'Damaged',
      'inspect' => 'Needs inspection',
      _ => 'Saleable',
    };

/// Where the returned stock went, for statements and return details.
String returnConditionStock(String condition) => switch (condition) {
      'faulty' => 'kept aside as faulty, awaiting inspection',
      'damaged' => 'moved to damaged stock',
      'inspect' => 'awaiting inspection',
      _ => 'back to available stock',
    };

class ReturnDoc {
  final String id;
  final String number;
  final String originalId; // sale or purchase id
  final String originalNumber;
  final String? partyId;
  final DateTime date;
  final List<ReturnLine> lines;
  final RefundMode refundMode;
  final PaymentMethod method;
  final String reason;
  final String userId;

  const ReturnDoc({
    required this.id,
    required this.number,
    required this.originalId,
    required this.originalNumber,
    this.partyId,
    required this.date,
    required this.lines,
    required this.refundMode,
    this.method = PaymentMethod.cash,
    this.reason = '',
    required this.userId,
  });

  Money get total => Money.sum(lines.map((e) => e.amount));
  Money get costTotal => Money.sum(lines.map((e) => e.cost));

  Map<String, dynamic> toJson() => {
        'id': id,
        'number': number,
        'originalId': originalId,
        'originalNumber': originalNumber,
        'partyId': partyId,
        'date': date.toIso8601String(),
        'lines': lines.map((e) => e.toJson()).toList(),
        'refundMode': refundMode.name,
        'method': method.name,
        'reason': reason,
        'userId': userId,
        'total': total.paisa,
      };
  factory ReturnDoc.fromJson(Map<String, dynamic> j) => ReturnDoc(
        id: s(j['id']),
        number: s(j['number']),
        originalId: s(j['originalId']),
        originalNumber: s(j['originalNumber']),
        partyId: sn(j['partyId']),
        date: parseDate(j['date']),
        lines: mapList(j['lines']).map(ReturnLine.fromJson).toList(),
        refundMode: enumByName(RefundMode.values, j['refundMode'], RefundMode.cash),
        method: enumByName(PaymentMethod.values, j['method'], PaymentMethod.cash),
        reason: s(j['reason']),
        userId: s(j['userId']),
      );
}

// ───────────────────────── Sales ─────────────────────────

/// What a bill line is. Product lines move stock; non-stock items (clips,
/// screws, small accessories) and services (installation, labour) do not
/// need a product record and never touch stock.
enum SaleLineKind { product, nonStock, service }

extension SaleLineKindLabel on SaleLineKind {
  String get label => switch (this) {
        SaleLineKind.product => 'Stock product',
        SaleLineKind.nonStock => 'Non-stock item',
        SaleLineKind.service => 'Labour / installation',
      };
}

class SaleItem {
  final String productId; // '' for non-stock items and services
  final String name;
  final Qty qty;
  final Money unitPrice;
  final Money discount; // line discount amount
  final List<String> serials; // serial keys (or plain serials on drafts)
  final Money cogs; // cost of goods sold for this line (set on completion)
  final Qty returnedQty;
  final String? techUsageId; // when invoicing material a technician installed
  final SaleLineKind kind;
  final String unit; // for non-stock / service lines (pcs, job, hour...)
  final String worker; // labour lines: the karegar who did the work

  const SaleItem({
    required this.productId,
    required this.name,
    required this.qty,
    required this.unitPrice,
    this.discount = const Money.zero(),
    this.serials = const [],
    this.cogs = const Money.zero(),
    this.returnedQty = const Qty.zero(),
    this.techUsageId,
    this.kind = SaleLineKind.product,
    this.unit = '',
    this.worker = '',
  });

  /// A non-stock item or service line typed at the bill.
  const SaleItem.custom({
    required this.kind,
    required this.name,
    required this.qty,
    required this.unitPrice,
    this.discount = const Money.zero(),
    this.unit = '',
    this.worker = '',
  })  : productId = '',
        serials = const [],
        cogs = const Money.zero(),
        returnedQty = const Qty.zero(),
        techUsageId = null;

  bool get isStock => kind == SaleLineKind.product;

  /// Groups lines in reports: the product, or the typed name for
  /// non-stock items and services.
  String get lineKey => isStock ? productId : '${kind.name}:${name.trim().toLowerCase()}';

  Money get gross => unitPrice.timesQty(qty);
  Money get net => gross - discount;

  SaleItem copyWith({String? name, Qty? qty, Money? unitPrice, Money? discount, List<String>? serials, Money? cogs, Qty? returnedQty, String? unit, String? worker}) => SaleItem(
        productId: productId,
        name: name ?? this.name,
        qty: qty ?? this.qty,
        unitPrice: unitPrice ?? this.unitPrice,
        discount: discount ?? this.discount,
        serials: serials ?? this.serials,
        cogs: cogs ?? this.cogs,
        returnedQty: returnedQty ?? this.returnedQty,
        techUsageId: techUsageId,
        kind: kind,
        unit: unit ?? this.unit,
        worker: worker ?? this.worker,
      );

  Map<String, dynamic> toJson() => {
        'productId': productId,
        'name': name,
        'qty': qty.milli,
        'unitPrice': unitPrice.paisa,
        'discount': discount.paisa,
        'serials': serials,
        'cogs': cogs.paisa,
        'returnedQty': returnedQty.milli,
        'techUsageId': techUsageId,
        if (kind != SaleLineKind.product) 'kind': kind.name,
        if (unit.isNotEmpty) 'unit': unit,
        if (worker.isNotEmpty) 'worker': worker,
      };
  factory SaleItem.fromJson(Map<String, dynamic> j) => SaleItem(
        productId: s(j['productId']),
        name: s(j['name']),
        qty: qy(j['qty']),
        unitPrice: m(j['unitPrice']),
        discount: m(j['discount']),
        serials: strList(j['serials']),
        cogs: m(j['cogs']),
        returnedQty: qy(j['returnedQty']),
        techUsageId: sn(j['techUsageId']),
        kind: SaleLineKind.values.firstWhere((k) => k.name == j['kind'], orElse: () => SaleLineKind.product),
        unit: s(j['unit']),
        worker: s(j['worker']),
      );
}

/// A saved non-stock item or service for quick billing (e.g. "Clips",
/// "CCTV Installation").
class BillingPreset {
  final SaleLineKind kind;
  final String name;
  final Money unitPrice;
  final String unit;
  const BillingPreset({required this.kind, required this.name, required this.unitPrice, this.unit = ''});

  Map<String, dynamic> toJson() => {'kind': kind.name, 'name': name, 'unitPrice': unitPrice.paisa, 'unit': unit};
  factory BillingPreset.fromJson(Map<String, dynamic> j) => BillingPreset(
        kind: SaleLineKind.values.firstWhere((k) => k.name == j['kind'], orElse: () => SaleLineKind.nonStock),
        name: s(j['name']),
        unitPrice: m(j['unitPrice']),
        unit: s(j['unit']),
      );

  SaleItem toLine({Qty qty = const Qty.one()}) => SaleItem.custom(kind: kind, name: name, qty: qty, unitPrice: unitPrice, unit: unit);
}

/// One edit of a completed invoice: what it was and what it became.
class SaleEdit {
  final String id;
  final DateTime at;
  final String userId;
  final String reason;
  final List<SaleItem> beforeItems;
  final Money beforeDiscount;
  final String beforeNotes;
  final Money beforeTotal;
  final List<SaleItem> afterItems;
  final Money afterDiscount;
  final String afterNotes;
  final Money afterTotal;
  const SaleEdit({
    required this.id,
    required this.at,
    required this.userId,
    required this.reason,
    required this.beforeItems,
    required this.beforeDiscount,
    required this.beforeNotes,
    required this.beforeTotal,
    required this.afterItems,
    required this.afterDiscount,
    required this.afterNotes,
    required this.afterTotal,
  });

  Money get difference => afterTotal - beforeTotal;

  Map<String, dynamic> toJson() => {
        'id': id,
        'at': at.toIso8601String(),
        'userId': userId,
        'reason': reason,
        'beforeItems': beforeItems.map((e) => e.toJson()).toList(),
        'beforeDiscount': beforeDiscount.paisa,
        'beforeNotes': beforeNotes,
        'beforeTotal': beforeTotal.paisa,
        'afterItems': afterItems.map((e) => e.toJson()).toList(),
        'afterDiscount': afterDiscount.paisa,
        'afterNotes': afterNotes,
        'afterTotal': afterTotal.paisa,
      };
  factory SaleEdit.fromJson(Map<String, dynamic> j) => SaleEdit(
        id: s(j['id']),
        at: parseDate(j['at']),
        userId: s(j['userId']),
        reason: s(j['reason']),
        beforeItems: mapList(j['beforeItems']).map(SaleItem.fromJson).toList(),
        beforeDiscount: m(j['beforeDiscount']),
        beforeNotes: s(j['beforeNotes']),
        beforeTotal: m(j['beforeTotal']),
        afterItems: mapList(j['afterItems']).map(SaleItem.fromJson).toList(),
        afterDiscount: m(j['afterDiscount']),
        afterNotes: s(j['afterNotes']),
        afterTotal: m(j['afterTotal']),
      );
}

class Sale {
  final String id;
  final String number;
  final String? customerId; // null = walk-in
  final String customerName;
  final DateTime date;
  final List<SaleItem> items;
  final Money invoiceDiscount;
  final Money paidAtSale;
  final PaymentMethod method;
  final String notes;
  final DocStatus status;
  final String createdBy;
  final DateTime createdAt;
  final String cancelReason;
  final String? quotationId;
  final String? creditApprovedBy;
  final List<SaleEdit> edits; // edit history, oldest first

  const Sale({
    required this.id,
    required this.number,
    this.customerId,
    this.customerName = 'Walk-in Customer',
    required this.date,
    required this.items,
    this.invoiceDiscount = const Money.zero(),
    this.paidAtSale = const Money.zero(),
    this.method = PaymentMethod.cash,
    this.notes = '',
    this.status = DocStatus.draft,
    required this.createdBy,
    required this.createdAt,
    this.cancelReason = '',
    this.quotationId,
    this.creditApprovedBy,
    this.edits = const [],
  });

  bool get edited => edits.isNotEmpty;

  Money get subtotal => Money.sum(items.map((e) => e.gross));
  Money get lineDiscounts => Money.sum(items.map((e) => e.discount));
  Money get total => Money.sum(items.map((e) => e.net)) - invoiceDiscount;
  Money get remaining => total - paidAtSale;
  Money get cogs => Money.sum(items.map((e) => e.cogs));
  Qty get totalQty => Qty.sum(items.map((e) => e.qty));

  /// Net revenue of one line after spreading the invoice-level discount
  /// proportionally across lines (used for refunds and product reports).
  /// Each line's revenue after the invoice discount.
  ///
  /// The invoice discount is taken from the shop's stock products first
  /// (spread over them by amount), then from non-stock items, then from
  /// service lines on older invoices. So the product profit is never
  /// overstated by pushing the discount onto items that carry no profit.
  List<Money> lineRevenues() {
    final out = [for (final it in items) it.net];
    var left = invoiceDiscount;
    for (final tier in SaleLineKind.values) {
      if (!left.isPositive) break;
      final idx = [for (var k = 0; k < items.length; k++) if (items[k].kind == tier && items[k].net.isPositive) k];
      final tierNet = Money.sum(idx.map((k) => items[k].net));
      if (!tierNet.isPositive) continue;
      final d = left > tierNet ? tierNet : left;
      left -= d;
      var rest = d;
      for (var n = 0; n < idx.length; n++) {
        final k = idx[n];
        final share = n == idx.length - 1 ? rest : d.share(items[k].net.paisa, tierNet.paisa);
        rest -= share;
        out[k] = out[k] - share;
      }
    }
    return out;
  }

  Money lineRevenue(int index) => lineRevenues()[index];

  Money _revenueOf(SaleLineKind kind) {
    final rev = lineRevenues();
    var t = const Money.zero();
    for (var k = 0; k < items.length; k++) {
      if (items[k].kind == kind) t += rev[k];
    }
    return t;
  }

  /// Shop stock products, after discounts: the only revenue with a cost, so
  /// the only revenue in shop profit.
  Money get productRevenue => _revenueOf(SaleLineKind.product);

  /// Non-stock items (screws, clips...): billed to the customer, no stock,
  /// no recorded cost, so not counted in shop profit.
  Money get nonStockRevenue => _revenueOf(SaleLineKind.nonStock);

  /// Labour / installation on the invoice: part of what the customer pays,
  /// but the worker's (karegar's) money, not shop income or profit.
  Money get labourRevenue => _revenueOf(SaleLineKind.service);

  /// What the shop sold (products and non-stock items), without labour.
  Money get shopSales => total - labourRevenue;

  /// Stock products before discounts / their line and invoice discounts.
  Money get productGross => Money.sum(items.where((e) => e.isStock).map((e) => e.gross));
  Money get productDiscounts => productGross - productRevenue;

  Sale copyWith({
    String? customerId,
    String? customerName,
    DateTime? date,
    List<SaleItem>? items,
    Money? invoiceDiscount,
    Money? paidAtSale,
    PaymentMethod? method,
    String? notes,
    DocStatus? status,
    String? cancelReason,
    String? number,
    String? creditApprovedBy,
    List<SaleEdit>? edits,
    bool clearCustomer = false,
  }) =>
      Sale(
        id: id,
        number: number ?? this.number,
        customerId: clearCustomer ? null : (customerId ?? this.customerId),
        customerName: customerName ?? this.customerName,
        date: date ?? this.date,
        items: items ?? this.items,
        invoiceDiscount: invoiceDiscount ?? this.invoiceDiscount,
        paidAtSale: paidAtSale ?? this.paidAtSale,
        method: method ?? this.method,
        notes: notes ?? this.notes,
        status: status ?? this.status,
        createdBy: createdBy,
        createdAt: createdAt,
        cancelReason: cancelReason ?? this.cancelReason,
        quotationId: quotationId,
        creditApprovedBy: creditApprovedBy ?? this.creditApprovedBy,
        edits: edits ?? this.edits,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'number': number,
        'customerId': customerId,
        'customerName': customerName,
        'date': date.toIso8601String(),
        'items': items.map((e) => e.toJson()).toList(),
        'invoiceDiscount': invoiceDiscount.paisa,
        'paidAtSale': paidAtSale.paisa,
        'method': method.name,
        'notes': notes,
        'status': status.name,
        'createdBy': createdBy,
        'createdAt': createdAt.toIso8601String(),
        'cancelReason': cancelReason,
        'quotationId': quotationId,
        'creditApprovedBy': creditApprovedBy,
        if (edits.isNotEmpty) 'edits': edits.map((e) => e.toJson()).toList(),
        'total': total.paisa,
      };

  factory Sale.fromJson(Map<String, dynamic> j) => Sale(
        id: s(j['id']),
        number: s(j['number']),
        customerId: sn(j['customerId']),
        customerName: s(j['customerName']),
        date: parseDate(j['date']),
        items: mapList(j['items']).map(SaleItem.fromJson).toList(),
        invoiceDiscount: m(j['invoiceDiscount']),
        paidAtSale: m(j['paidAtSale']),
        method: enumByName(PaymentMethod.values, j['method'], PaymentMethod.cash),
        notes: s(j['notes']),
        status: enumByName(DocStatus.values, j['status'], DocStatus.draft),
        createdBy: s(j['createdBy']),
        createdAt: parseDate(j['createdAt']),
        cancelReason: s(j['cancelReason']),
        quotationId: sn(j['quotationId']),
        creditApprovedBy: sn(j['creditApprovedBy']),
        edits: mapList(j['edits']).map(SaleEdit.fromJson).toList(),
      );
}

// ───────────────────────── Quotations ─────────────────────────

enum QuotationStatus { draft, sent, approved, rejected, expired, converted }

class QuotationItem {
  final String productId;
  final String name;
  final Qty qty;
  final Money unitPrice;
  final Money discount;
  const QuotationItem({required this.productId, required this.name, required this.qty, required this.unitPrice, this.discount = const Money.zero()});
  Money get net => unitPrice.timesQty(qty) - discount;
  Map<String, dynamic> toJson() =>
      {'productId': productId, 'name': name, 'qty': qty.milli, 'unitPrice': unitPrice.paisa, 'discount': discount.paisa};
  factory QuotationItem.fromJson(Map<String, dynamic> j) => QuotationItem(
      productId: s(j['productId']), name: s(j['name']), qty: qy(j['qty']), unitPrice: m(j['unitPrice']), discount: m(j['discount']));
}

class Quotation {
  final String id;
  final String number;
  final String? customerId;
  final String customerName;
  final DateTime date;
  final DateTime expiryDate;
  final List<QuotationItem> items;
  final Money invoiceDiscount;
  final String terms;
  final String notes;
  final QuotationStatus status;
  final String? convertedSaleId;
  final String createdBy;

  const Quotation({
    required this.id,
    required this.number,
    this.customerId,
    required this.customerName,
    required this.date,
    required this.expiryDate,
    required this.items,
    this.invoiceDiscount = const Money.zero(),
    this.terms = '',
    this.notes = '',
    this.status = QuotationStatus.draft,
    this.convertedSaleId,
    required this.createdBy,
  });

  Money get total => Money.sum(items.map((e) => e.net)) - invoiceDiscount;

  /// Effective status: an un-converted quotation past its expiry is expired.
  QuotationStatus statusOn(DateTime now) {
    if ((status == QuotationStatus.draft || status == QuotationStatus.sent || status == QuotationStatus.approved) &&
        now.isAfter(dayEnd(expiryDate))) {
      return QuotationStatus.expired;
    }
    return status;
  }

  Quotation copyWith({
    String? customerId,
    String? customerName,
    DateTime? expiryDate,
    List<QuotationItem>? items,
    Money? invoiceDiscount,
    String? terms,
    String? notes,
    QuotationStatus? status,
    String? convertedSaleId,
  }) =>
      Quotation(
        id: id,
        number: number,
        customerId: customerId ?? this.customerId,
        customerName: customerName ?? this.customerName,
        date: date,
        expiryDate: expiryDate ?? this.expiryDate,
        items: items ?? this.items,
        invoiceDiscount: invoiceDiscount ?? this.invoiceDiscount,
        terms: terms ?? this.terms,
        notes: notes ?? this.notes,
        status: status ?? this.status,
        convertedSaleId: convertedSaleId ?? this.convertedSaleId,
        createdBy: createdBy,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'number': number,
        'customerId': customerId,
        'customerName': customerName,
        'date': date.toIso8601String(),
        'expiryDate': expiryDate.toIso8601String(),
        'items': items.map((e) => e.toJson()).toList(),
        'invoiceDiscount': invoiceDiscount.paisa,
        'terms': terms,
        'notes': notes,
        'status': status.name,
        'convertedSaleId': convertedSaleId,
        'createdBy': createdBy,
        'total': total.paisa,
      };

  factory Quotation.fromJson(Map<String, dynamic> j) => Quotation(
        id: s(j['id']),
        number: s(j['number']),
        customerId: sn(j['customerId']),
        customerName: s(j['customerName']),
        date: parseDate(j['date']),
        expiryDate: parseDate(j['expiryDate']),
        items: mapList(j['items']).map(QuotationItem.fromJson).toList(),
        invoiceDiscount: m(j['invoiceDiscount']),
        terms: s(j['terms']),
        notes: s(j['notes']),
        status: enumByName(QuotationStatus.values, j['status'], QuotationStatus.draft),
        convertedSaleId: sn(j['convertedSaleId']),
        createdBy: s(j['createdBy']),
      );
}
