import '../../core/errors.dart';
import '../../core/ids.dart';
import '../../core/money.dart';
import '../../data/store/data_store.dart';
import '../models/documents.dart';
import '../models/json_utils.dart';
import '../models/labour.dart';
import '../models/party.dart';
import '../models/user.dart';
import 'context.dart';

/// Totals of labour bills in a period (the workers' money, not the shop's).
class LabourSummary {
  final int bills;
  final Money billed;
  final Money collected;
  final Money due;
  final Money paidToWorkers;
  const LabourSummary(this.bills, this.billed, this.collected, this.due, this.paidToWorkers);
  Money get heldForWorkers => collected - paidToWorkers;
}

/// Labour / installation bills (karegar's charges). Kept completely apart
/// from shop sales: no shop invoice line, no customer ledger entry, no
/// payment record, not in shop sales, cash or profit.
class LabourService {
  final ServiceContext ctx;
  LabourService(this.ctx);

  List<LabourBill> list({DateTime? from, DateTime? to, String? customerId, String query = '', bool includeCancelled = true}) {
    final q = query.trim().toLowerCase();
    return ctx.all(Boxes.labourBills, LabourBill.fromJson).where((b) {
      if (!includeCancelled && b.cancelled) return false;
      if (from != null && b.date.isBefore(dayStart(from))) return false;
      if (to != null && b.date.isAfter(dayEnd(to))) return false;
      if (customerId != null && b.customerId != customerId) return false;
      if (q.isNotEmpty &&
          !'${b.number} ${b.customerName} ${b.customerPhone} ${b.workerName} ${b.saleNumber} ${b.lines.map((l) => l.description).join(' ')}'
              .toLowerCase()
              .contains(q)) {
        return false;
      }
      return true;
    }).toList()
      ..sort((a, b) {
        final c = b.date.compareTo(a.date);
        return c != 0 ? c : b.number.compareTo(a.number);
      });
  }

  LabourBill? byId(String id) {
    final j = ctx.store.read(Boxes.labourBills, id);
    return j == null ? null : LabourBill.fromJson(j);
  }

  List<LabourBill> forSale(String saleId) => list().where((b) => b.saleId == saleId).toList();

  LabourSummary summary({DateTime? from, DateTime? to}) {
    final bills = list(from: from, to: to, includeCancelled: false);
    return LabourSummary(
      bills.length,
      Money.sum(bills.map((b) => b.total)),
      Money.sum(bills.map((b) => b.collected)),
      Money.sum(bills.map((b) => b.due)),
      Money.sum(bills.map((b) => b.paidToWorker)),
    );
  }

  /// Per worker: billed, collected, paid to the worker (non-cancelled bills).
  List<(String, Money, Money, Money)> byWorker({DateTime? from, DateTime? to}) {
    final m = <String, List<Money>>{};
    for (final b in list(from: from, to: to, includeCancelled: false)) {
      final k = b.workerName.trim().isEmpty ? 'Not set' : b.workerName.trim();
      final g = m.putIfAbsent(k, () => [const Money.zero(), const Money.zero(), const Money.zero()]);
      g[0] += b.total;
      g[1] += b.collected;
      g[2] += b.paidToWorker;
    }
    return [for (final e in m.entries) (e.key, e.value[0], e.value[1], e.value[2])]..sort((a, b) => b.$2.compareTo(a.$2));
  }

  Future<LabourBill> create({
    required List<LabourLine> lines,
    String? customerId,
    String customerName = '',
    String customerPhone = '',
    String workerName = '',
    String? technicianId,
    String? saleId,
    String saleNumber = '',
    Money discount = const Money.zero(),
    Money receivedNow = const Money.zero(),
    PaymentMethod method = PaymentMethod.cash,
    String notes = '',
    DateTime? date,
  }) async {
    ctx.require(Permission.manageSales);
    final clean = [
      for (final l in lines)
        LabourLine(description: l.description.trim(), qty: l.qty, rate: l.rate, unit: l.unit.trim()),
    ];
    if (clean.isEmpty) throw const ValidationException('Add at least one labour / installation line.');
    for (final l in clean) {
      if (l.description.isEmpty) throw const ValidationException('Enter what the labour is for.');
      if (!l.qty.isPositive) throw ValidationException('Quantity of "${l.description}" must be more than zero.');
      if (l.rate.isNegative) throw const ValidationException('Rate cannot be negative.');
    }
    if (discount.isNegative || receivedNow.isNegative) throw const ValidationException('Amounts cannot be negative.');
    final subtotal = Money.sum(clean.map((l) => l.amount));
    if (discount > subtotal) throw const ValidationException('Discount is larger than the labour amount.');
    final total = subtotal - discount;
    if (receivedNow > total) throw ValidationException('Only ${total.format()} is billed for labour.');
    var name = customerName.trim();
    var phone = customerPhone.trim();
    if (customerId != null) {
      final j = ctx.store.read(Boxes.customers, customerId);
      if (j == null) throw const NotFoundException('Customer not found.');
      final p = Party.fromJson(j);
      if (name.isEmpty) name = p.name;
      if (phone.isEmpty) phone = p.phone;
    }
    if (name.isEmpty) name = 'Walk-in Customer';
    final uow = ctx.uow();
    final now = ctx.now();
    final b = LabourBill(
      id: newId(),
      number: ctx.nextNumber(uow, 'labour', 'LB'),
      date: date ?? now,
      customerId: customerId,
      customerName: name,
      customerPhone: phone,
      workerName: workerName.trim(),
      technicianId: technicianId,
      saleId: saleId,
      saleNumber: saleNumber,
      lines: clean,
      discount: discount,
      collections: [if (receivedNow.isPositive) LabourMoney(at: now, amount: receivedNow, method: method, note: 'Received with the bill', userId: ctx.userId)],
      notes: notes.trim(),
      createdBy: ctx.userId,
      createdAt: now,
    );
    uow.put(Boxes.labourBills, b.id, b.toJson());
    ctx.audit(uow, 'create', 'labour_bill', b.id, '${b.number} ${b.total.format()} ${b.customerName}${b.workerName.isEmpty ? '' : ' / ${b.workerName}'}');
    await uow.commit();
    return b;
  }

  /// Labour bill from the service / labour lines of a POS bill.
  Future<LabourBill> fromSaleLines(List<SaleItem> lines, {String? customerId, String customerName = '', String customerPhone = '', String? saleId, String saleNumber = '', String workerName = '', Money receivedNow = const Money.zero(), PaymentMethod method = PaymentMethod.cash}) {
    final out = <LabourLine>[];
    var disc = const Money.zero();
    for (final it in lines) {
      out.add(LabourLine(description: it.name, qty: it.qty, rate: it.unitPrice, unit: it.unit));
      disc += it.discount;
    }
    return create(lines: out, discount: disc, customerId: customerId, customerName: customerName, customerPhone: customerPhone, saleId: saleId, saleNumber: saleNumber, workerName: workerName, receivedNow: receivedNow, method: method);
  }

  Future<LabourBill> _change(String id, LabourBill Function(LabourBill) f, String action, String detail) async {
    final uow = ctx.uow();
    final j = uow.read(Boxes.labourBills, id);
    if (j == null) throw const NotFoundException('Labour bill not found.');
    final b = LabourBill.fromJson(j);
    if (b.cancelled) throw const BusinessException('This labour bill is cancelled.');
    final nb = f(b);
    uow.put(Boxes.labourBills, id, nb.toJson());
    ctx.audit(uow, action, 'labour_bill', id, '${b.number}: $detail');
    await uow.commit();
    return nb;
  }

  /// Money received from the customer for the labour.
  Future<LabourBill> collect(String id, Money amount, {PaymentMethod method = PaymentMethod.cash, String note = ''}) async {
    ctx.require(Permission.manageSales);
    if (!amount.isPositive) throw const ValidationException('Enter the amount received.');
    final b = byId(id);
    if (b == null) throw const NotFoundException('Labour bill not found.');
    if (amount > b.due) throw ValidationException(b.due.isPositive ? 'Only ${b.due.format()} is due on this labour bill.' : 'Nothing is due on this labour bill.');
    return _change(id, (x) => x.copyWith(collections: [...x.collections, LabourMoney(at: ctx.now(), amount: amount, method: method, note: note.trim(), userId: ctx.userId)]),
        'collect', 'received ${amount.format()}');
  }

  /// Money handed to the worker (karegar).
  Future<LabourBill> payWorker(String id, Money amount, {PaymentMethod method = PaymentMethod.cash, String note = ''}) async {
    ctx.require(Permission.manageSales);
    if (!amount.isPositive) throw const ValidationException('Enter the amount paid to the worker.');
    final b = byId(id);
    if (b == null) throw const NotFoundException('Labour bill not found.');
    final open = b.total - b.paidToWorker;
    if (amount > open) throw ValidationException('Only ${open.format()} is left to pay to the worker on this bill.');
    return _change(id, (x) => x.copyWith(workerPayments: [...x.workerPayments, LabourMoney(at: ctx.now(), amount: amount, method: method, note: note.trim(), userId: ctx.userId)]),
        'pay_worker', 'paid ${amount.format()} to ${b.workerName.isEmpty ? 'worker' : b.workerName}');
  }

  Future<LabourBill> setWorker(String id, String workerName) async {
    ctx.require(Permission.manageSales);
    return _change(id, (x) => x.copyWith(workerName: workerName.trim()), 'update', 'worker ${workerName.trim()}');
  }

  /// Cancels a labour bill (kept, marked cancelled, with the reason).
  Future<LabourBill> cancel(String id, String reason) async {
    ctx.require(Permission.cancelTransactions);
    if (reason.trim().isEmpty) throw const ValidationException('Write why the labour bill is cancelled.');
    return _change(id, (x) => x.copyWith(cancelled: true, cancelReason: reason.trim()), 'cancel', reason.trim());
  }
}
