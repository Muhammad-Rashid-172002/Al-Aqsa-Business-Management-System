import '../../core/money.dart';
import '../../core/qty.dart';
import 'json_utils.dart';
import 'party.dart';

/// Labour / installation for a customer: the worker's (karegar's) money, kept
/// apart from shop sales. It is not on the shop invoice, not in the customer's
/// shop ledger, and not in shop sales or profit.
class LabourLine {
  final String description; // CCTV installation, wiring, labour...
  final Qty qty;
  final Money rate;
  final String unit; // job, day, hour, point
  const LabourLine({required this.description, required this.qty, required this.rate, this.unit = ''});

  Money get amount => rate.timesQty(qty);

  Map<String, dynamic> toJson() => {'description': description, 'qty': qty.milli, 'rate': rate.paisa, 'unit': unit};
  factory LabourLine.fromJson(Map<String, dynamic> j) =>
      LabourLine(description: s(j['description']), qty: qy(j['qty']), rate: m(j['rate']), unit: s(j['unit']));
}

/// Money moving on a labour bill: collected from the customer, or paid to
/// the worker.
class LabourMoney {
  final DateTime at;
  final Money amount;
  final PaymentMethod method;
  final String note;
  final String userId;
  const LabourMoney({required this.at, required this.amount, this.method = PaymentMethod.cash, this.note = '', this.userId = ''});

  Map<String, dynamic> toJson() => {'at': at.toIso8601String(), 'amount': amount.paisa, 'method': method.name, 'note': note, 'userId': userId};
  factory LabourMoney.fromJson(Map<String, dynamic> j) => LabourMoney(
        at: parseDate(j['at']),
        amount: m(j['amount']),
        method: PaymentMethod.values.firstWhere((x) => x.name == j['method'], orElse: () => PaymentMethod.cash),
        note: s(j['note']),
        userId: s(j['userId']),
      );
}

class LabourBill {
  final String id;
  final String number; // LB-000001
  final DateTime date;
  final String? customerId;
  final String customerName;
  final String customerPhone;
  final String workerName; // karegar
  final String? technicianId; // when the worker is a saved technician
  final String? saleId; // shop invoice the work went with, if any
  final String saleNumber;
  final List<LabourLine> lines;
  final Money discount;
  final List<LabourMoney> collections; // received from the customer
  final List<LabourMoney> workerPayments; // handed to the worker
  final String notes;
  final bool cancelled;
  final String cancelReason;
  final String createdBy;
  final DateTime createdAt;

  const LabourBill({
    required this.id,
    required this.number,
    required this.date,
    this.customerId,
    required this.customerName,
    this.customerPhone = '',
    this.workerName = '',
    this.technicianId,
    this.saleId,
    this.saleNumber = '',
    required this.lines,
    this.discount = const Money.zero(),
    this.collections = const [],
    this.workerPayments = const [],
    this.notes = '',
    this.cancelled = false,
    this.cancelReason = '',
    this.createdBy = '',
    required this.createdAt,
  });

  Money get subtotal => Money.sum(lines.map((l) => l.amount));
  Money get total => subtotal - discount;
  Money get collected => Money.sum(collections.map((c) => c.amount));
  Money get due => cancelled ? const Money.zero() : total - collected;
  Money get paidToWorker => Money.sum(workerPayments.map((c) => c.amount));

  /// Collected from the customer but not yet handed to the worker.
  Money get heldForWorker => collected - paidToWorker;

  LabourBill copyWith({
    List<LabourMoney>? collections,
    List<LabourMoney>? workerPayments,
    bool? cancelled,
    String? cancelReason,
    String? workerName,
    String? notes,
  }) =>
      LabourBill(
        id: id,
        number: number,
        date: date,
        customerId: customerId,
        customerName: customerName,
        customerPhone: customerPhone,
        workerName: workerName ?? this.workerName,
        technicianId: technicianId,
        saleId: saleId,
        saleNumber: saleNumber,
        lines: lines,
        discount: discount,
        collections: collections ?? this.collections,
        workerPayments: workerPayments ?? this.workerPayments,
        notes: notes ?? this.notes,
        cancelled: cancelled ?? this.cancelled,
        cancelReason: cancelReason ?? this.cancelReason,
        createdBy: createdBy,
        createdAt: createdAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'number': number,
        'date': date.toIso8601String(),
        'customerId': customerId,
        'customerName': customerName,
        'customerPhone': customerPhone,
        'workerName': workerName,
        'technicianId': technicianId,
        'saleId': saleId,
        'saleNumber': saleNumber,
        'lines': lines.map((l) => l.toJson()).toList(),
        'discount': discount.paisa,
        'collections': collections.map((c) => c.toJson()).toList(),
        'workerPayments': workerPayments.map((c) => c.toJson()).toList(),
        'notes': notes,
        'cancelled': cancelled,
        'cancelReason': cancelReason,
        'createdBy': createdBy,
        'createdAt': createdAt.toIso8601String(),
        'total': total.paisa,
      };

  factory LabourBill.fromJson(Map<String, dynamic> j) => LabourBill(
        id: s(j['id']),
        number: s(j['number']),
        date: parseDate(j['date']),
        customerId: sn(j['customerId']),
        customerName: s(j['customerName']),
        customerPhone: s(j['customerPhone']),
        workerName: s(j['workerName']),
        technicianId: sn(j['technicianId']),
        saleId: sn(j['saleId']),
        saleNumber: s(j['saleNumber']),
        lines: mapList(j['lines']).map(LabourLine.fromJson).toList(),
        discount: m(j['discount']),
        collections: mapList(j['collections']).map(LabourMoney.fromJson).toList(),
        workerPayments: mapList(j['workerPayments']).map(LabourMoney.fromJson).toList(),
        notes: s(j['notes']),
        cancelled: j['cancelled'] == true,
        cancelReason: s(j['cancelReason']),
        createdBy: s(j['createdBy']),
        createdAt: parseDate(j['createdAt']),
      );
}
