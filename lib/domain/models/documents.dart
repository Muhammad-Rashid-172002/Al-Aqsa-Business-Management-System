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

class SaleItem {
  final String productId;
  final String name;
  final Qty qty;
  final Money unitPrice;
  final Money discount; // line discount amount
  final List<String> serials; // serial keys (or plain serials on drafts)
  final Money cogs; // cost of goods sold for this line (set on completion)
  final Qty returnedQty;
  final String? techUsageId; // when invoicing material a technician installed

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
  });

  Money get gross => unitPrice.timesQty(qty);
  Money get net => gross - discount;

  SaleItem copyWith({Qty? qty, Money? unitPrice, Money? discount, List<String>? serials, Money? cogs, Qty? returnedQty}) => SaleItem(
        productId: productId,
        name: name,
        qty: qty ?? this.qty,
        unitPrice: unitPrice ?? this.unitPrice,
        discount: discount ?? this.discount,
        serials: serials ?? this.serials,
        cogs: cogs ?? this.cogs,
        returnedQty: returnedQty ?? this.returnedQty,
        techUsageId: techUsageId,
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
  });

  Money get subtotal => Money.sum(items.map((e) => e.gross));
  Money get lineDiscounts => Money.sum(items.map((e) => e.discount));
  Money get total => Money.sum(items.map((e) => e.net)) - invoiceDiscount;
  Money get remaining => total - paidAtSale;
  Money get cogs => Money.sum(items.map((e) => e.cogs));
  Qty get totalQty => Qty.sum(items.map((e) => e.qty));

  /// Net revenue of one line after spreading the invoice-level discount
  /// proportionally across lines (used for refunds and product reports).
  Money lineRevenue(int index) {
    final linesNet = Money.sum(items.map((e) => e.net));
    final line = items[index].net;
    if (linesNet.isZero) return line;
    return line - invoiceDiscount.share(line.paisa, linesNet.paisa);
  }

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
