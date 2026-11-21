import '../../core/errors.dart';
import '../../core/ids.dart';
import '../../core/money.dart';
import '../../data/store/data_store.dart';
import '../models/json_utils.dart';
import '../models/party.dart';
import '../models/user.dart';
import 'context.dart';

class StatementLine {
  final LedgerEntry entry;
  final Money runningBalance;
  const StatementLine(this.entry, this.runningBalance);
}

class PartyStatement {
  final Party party;
  final Money openingBalance; // balance before the period
  final List<StatementLine> lines;
  final Money closingBalance;
  const PartyStatement(this.party, this.openingBalance, this.lines, this.closingBalance);
}

/// Customers, suppliers, the append-only ledger and payments.
class PartyService {
  final ServiceContext ctx;
  PartyService(this.ctx);

  String _box(PartyKind k) => k == PartyKind.customer ? Boxes.customers : Boxes.suppliers;
  Permission _perm(PartyKind k) => k == PartyKind.customer ? Permission.manageCustomers : Permission.manageSuppliers;

  List<Party> list(PartyKind kind, {String query = '', bool includeInactive = false}) {
    final q = query.trim().toLowerCase();
    return ctx.all(_box(kind), Party.fromJson).where((p) {
      if (!includeInactive && !p.active) return false;
      if (q.isEmpty) return true;
      return p.name.toLowerCase().contains(q) || p.phone.contains(q) || p.altPhone.contains(q) || p.company.toLowerCase().contains(q);
    }).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  Party? byId(PartyKind kind, String id) {
    final j = ctx.store.read(_box(kind), id);
    return j == null ? null : Party.fromJson(j);
  }

  Party require(UnitOfWork uow, PartyKind kind, String id) {
    final j = uow.read(_box(kind), id);
    if (j == null) throw NotFoundException('${kind == PartyKind.customer ? 'Customer' : 'Supplier'} not found.');
    return Party.fromJson(j);
  }

  Future<Party> create({
    required PartyKind kind,
    required String name,
    String company = '',
    String contactPerson = '',
    String phone = '',
    String altPhone = '',
    String address = '',
    String email = '',
    Money openingBalance = const Money.zero(),
    String notes = '',
  }) async {
    ctx.require(_perm(kind));
    final n = name.trim();
    if (n.isEmpty) throw const ValidationException('Name is required.');
    final ph = phone.trim();
    if (ph.isNotEmpty && list(kind, includeInactive: true).any((p) => p.phone == ph && p.name.toLowerCase() == n.toLowerCase())) {
      throw DuplicateException('"$n" with phone $ph already exists.');
    }
    final p = Party(
      id: newId(),
      kind: kind,
      name: n,
      company: company.trim(),
      contactPerson: contactPerson.trim(),
      phone: ph,
      altPhone: altPhone.trim(),
      address: address.trim(),
      email: email.trim(),
      openingBalance: openingBalance,
      notes: notes,
      createdAt: ctx.now(),
    );
    final uow = ctx.uow()..put(_box(kind), p.id, p.toJson());
    if (!openingBalance.isZero) {
      // Positive opening = they owe us (customer) / we owe them (supplier).
      final isCustomer = kind == PartyKind.customer;
      final pos = openingBalance.isPositive;
      post(uow,
          kind: kind,
          partyId: p.id,
          type: LedgerType.opening,
          debit: (isCustomer == pos) ? openingBalance.abs() : const Money.zero(),
          credit: (isCustomer == pos) ? const Money.zero() : openingBalance.abs(),
          note: 'Opening balance');
    }
    ctx.audit(uow, 'create', kind.name, p.id, n);
    await uow.commit();
    return byId(kind, p.id)!;
  }

  Future<Party> update(Party p) async {
    ctx.require(_perm(p.kind));
    if (p.name.trim().isEmpty) throw const ValidationException('Name is required.');
    final uow = ctx.uow();
    final current = require(uow, p.kind, p.id);
    // Balance and opening balance are ledger-controlled and cannot be edited here.
    final saved = current.copyWith(
        name: p.name.trim(),
        company: p.company,
        contactPerson: p.contactPerson,
        phone: p.phone,
        altPhone: p.altPhone.trim(),
        address: p.address,
        email: p.email,
        notes: p.notes,
        active: p.active);
    uow.put(_box(p.kind), p.id, saved.toJson());
    ctx.audit(uow, 'update', p.kind.name, p.id);
    await uow.commit();
    return saved;
  }

  /// True when the customer/supplier appears in any transaction, payment,
  /// ledger entry, quotation, repair, warranty claim or serial record.
  bool hasHistory(PartyKind kind, String id) {
    const keys = ['partyId', 'customerId', 'supplierId'];
    for (final box in const [Boxes.ledger, Boxes.payments, Boxes.sales, Boxes.purchases, Boxes.salesReturns, Boxes.purchaseReturns, Boxes.quotations, Boxes.repairs, Boxes.warrantyClaims, Boxes.serials, Boxes.techTxns]) {
      for (final j in ctx.store.values(box)) {
        for (final k in keys) {
          if (j[k] == id) return true;
        }
      }
    }
    return false;
  }

  /// Deletes a customer/supplier with no history and a zero balance;
  /// otherwise archives it (inactive: hidden from lists and pickers, while
  /// the ledger, invoices and reports keep it). Returns true when archived.
  Future<bool> deleteOrArchive(PartyKind kind, String id) async {
    ctx.require(_perm(kind));
    final uow = ctx.uow();
    final p = require(uow, kind, id);
    if (!p.balance.isZero || hasHistory(kind, id)) {
      uow.put(_box(kind), id, p.copyWith(active: false).toJson());
      ctx.audit(uow, 'archive', kind.name, id, p.name);
      await uow.commit();
      return true;
    }
    uow.delete(_box(kind), id);
    ctx.audit(uow, 'delete', kind.name, id, p.name);
    await uow.commit();
    return false;
  }

  /// Makes an archived customer/supplier active again.
  Future<void> restore(PartyKind kind, String id) async {
    ctx.require(_perm(kind));
    final uow = ctx.uow();
    final p = require(uow, kind, id);
    uow.put(_box(kind), id, p.copyWith(active: true).toJson());
    ctx.audit(uow, 'restore', kind.name, id, p.name);
    await uow.commit();
  }

  /// Appends a ledger entry and updates the cached party balance.
  LedgerEntry post(
    UnitOfWork uow, {
    required PartyKind kind,
    required String partyId,
    required LedgerType type,
    Money debit = const Money.zero(),
    Money credit = const Money.zero(),
    String refType = '',
    String refId = '',
    String refNumber = '',
    String note = '',
    DateTime? at,
  }) {
    if (debit.isNegative || credit.isNegative) throw ArgumentError('Ledger amounts must be positive');
    final e = LedgerEntry(
      id: newId(),
      partyKind: kind,
      partyId: partyId,
      at: at ?? ctx.now(),
      type: type,
      debit: debit,
      credit: credit,
      refType: refType,
      refId: refId,
      refNumber: refNumber,
      note: note,
      userId: ctx.userId,
    );
    uow.put(Boxes.ledger, e.id, e.toJson());
    final p = require(uow, kind, partyId);
    uow.put(_box(kind), partyId, p.copyWith(balance: p.balance + e.balanceEffect).toJson());
    return e;
  }

  /// Records a payment row (and the ledger entry if a party is involved).
  Payment recordPayment(
    UnitOfWork uow, {
    PartyKind? kind,
    String? partyId,
    required Money amount,
    required PaymentMethod method,
    required PaymentDirection direction,
    String refType = '',
    String refId = '',
    String refNumber = '',
    String note = '',
    DateTime? at,
  }) {
    if (!amount.isPositive) throw const ValidationException('Payment amount must be greater than zero.');
    final pay = Payment(
      id: newId(),
      number: ctx.nextNumber(uow, 'payment', direction == PaymentDirection.received ? 'RCV' : 'PAY'),
      partyKind: kind,
      partyId: partyId,
      at: at ?? ctx.now(),
      amount: amount,
      method: method,
      direction: direction,
      refType: refType,
      refId: refId,
      note: note,
      userId: ctx.userId,
    );
    uow.put(Boxes.payments, pay.id, pay.toJson());
    if (kind != null && partyId != null) {
      // Customer receipt: credit customer. Supplier payment: debit supplier.
      // Refunds go the other way.
      final isCustomer = kind == PartyKind.customer;
      final reducesBalance = (isCustomer && direction == PaymentDirection.received) || (!isCustomer && direction == PaymentDirection.paid);
      final type = reducesBalance ? LedgerType.payment : LedgerType.refund;
      final asDebit = isCustomer ? !reducesBalance : reducesBalance;
      post(uow,
          kind: kind,
          partyId: partyId,
          type: type,
          debit: asDebit ? amount : const Money.zero(),
          credit: asDebit ? const Money.zero() : amount,
          refType: 'payment',
          refId: pay.id,
          refNumber: refNumber.isEmpty ? pay.number : refNumber,
          note: note.isEmpty ? method.label : '${method.label} - $note',
          at: pay.at);
    }
    return pay;
  }

  /// Standalone payment: receive from customer or pay a supplier.
  Future<Payment> addPayment({
    required PartyKind kind,
    required String partyId,
    required Money amount,
    required PaymentMethod method,
    String note = '',
    String? againstDocId,
    String againstDocNumber = '',
    DateTime? at,
  }) async {
    ctx.require(Permission.manageLedgers);
    final uow = ctx.uow();
    require(uow, kind, partyId);
    final pay = recordPayment(uow,
        kind: kind,
        partyId: partyId,
        amount: amount,
        method: method,
        direction: kind == PartyKind.customer ? PaymentDirection.received : PaymentDirection.paid,
        refType: againstDocId == null ? 'account' : (kind == PartyKind.customer ? 'sale' : 'purchase'),
        refId: againstDocId ?? '',
        refNumber: againstDocNumber,
        note: note,
        at: at);
    ctx.audit(uow, 'payment', kind.name, partyId, '${pay.number} ${amount.format()}');
    await uow.commit();
    return pay;
  }

  /// Voids a payment by posting a reversing entry. The original row is kept.
  Future<void> voidPayment(String paymentId, String reason) async {
    ctx.require(Permission.cancelTransactions);
    if (reason.trim().isEmpty) throw const ValidationException('A reason is required.');
    final uow = ctx.uow();
    final j = uow.read(Boxes.payments, paymentId);
    if (j == null) throw const NotFoundException('Payment not found.');
    final pay = Payment.fromJson(j);
    if (pay.voided) throw const BusinessException('This payment is already voided.');
    uow.put(Boxes.payments, pay.id, pay.voidWith(reason).toJson());
    if (pay.partyKind != null && pay.partyId != null) {
      final original = uow.values(Boxes.ledger).map(LedgerEntry.fromJson).firstWhere((e) => e.refType == 'payment' && e.refId == pay.id);
      post(uow,
          kind: pay.partyKind!,
          partyId: pay.partyId!,
          type: LedgerType.reversal,
          debit: original.credit,
          credit: original.debit,
          refType: 'payment_void',
          refId: pay.id,
          refNumber: pay.number,
          note: 'Void: $reason');
    }
    ctx.audit(uow, 'void', 'payment', pay.id, reason);
    await uow.commit();
  }

  /// Manual debit/credit adjustment with a mandatory note.
  Future<void> adjust({required PartyKind kind, required String partyId, required Money amount, required bool increaseBalance, required String note}) async {
    ctx.require(Permission.manageLedgers);
    if (note.trim().isEmpty) throw const ValidationException('A note is required for adjustments.');
    if (!amount.isPositive) throw const ValidationException('Amount must be greater than zero.');
    final uow = ctx.uow();
    final isCustomer = kind == PartyKind.customer;
    final asDebit = isCustomer == increaseBalance;
    post(uow,
        kind: kind,
        partyId: partyId,
        type: LedgerType.adjustment,
        debit: asDebit ? amount : const Money.zero(),
        credit: asDebit ? const Money.zero() : amount,
        refType: 'adjustment',
        note: note);
    ctx.audit(uow, 'ledger_adjust', kind.name, partyId, '${increaseBalance ? '+' : '-'}${amount.format()} $note');
    await uow.commit();
  }

  /// Committed ledger entries grouped by party (cached until the ledger changes).
  Map<String, List<LedgerEntry>> _ledgerByParty() => ctx.derived('ledgerByParty', const [Boxes.ledger], () {
        final m = <String, List<LedgerEntry>>{};
        for (final e in ctx.all(Boxes.ledger, LedgerEntry.fromJson)) {
          (m['${e.partyKind.name}|${e.partyId}'] ??= []).add(e);
        }
        return m;
      });

  List<LedgerEntry> entries(PartyKind kind, String partyId) =>
      [...?_ledgerByParty()['${kind.name}|$partyId']]
        ..sort((a, b) {
          final c = a.at.compareTo(b.at);
          return c != 0 ? c : a.id.compareTo(b.id);
        });

  /// Balance computed from the ledger (source of truth).
  Money ledgerBalance(PartyKind kind, String partyId) => Money.sum(entries(kind, partyId).map((e) => e.balanceEffect));

  PartyStatement statement(PartyKind kind, String partyId, {DateTime? from, DateTime? to}) {
    final p = byId(kind, partyId);
    if (p == null) throw const NotFoundException('Account not found.');
    var opening = const Money.zero();
    final lines = <StatementLine>[];
    var running = const Money.zero();
    for (final e in entries(kind, partyId)) {
      if (from != null && e.at.isBefore(dayStart(from))) {
        opening += e.balanceEffect;
        running = opening;
        continue;
      }
      if (to != null && e.at.isAfter(dayEnd(to))) continue;
      running += e.balanceEffect;
      lines.add(StatementLine(e, running));
    }
    return PartyStatement(p, opening, lines, running);
  }

  /// Per customer / supplier: how much they paid (net of refunds and voided
  /// payments) and how much they were billed in total (balance + paid, i.e.
  /// invoices, opening balance and adjustments net of returns and
  /// cancellations). Read from the ledger; cached until it changes.
  Map<String, PartyTotals> accountTotals(PartyKind kind) => ctx.derived('accountTotals_${kind.name}', const [Boxes.ledger, Boxes.customers, Boxes.suppliers], () {
        final paid = <String, int>{};
        final last = <String, DateTime>{};
        for (final e in ctx.all(Boxes.ledger, LedgerEntry.fromJson)) {
          if (e.partyKind != kind) continue;
          final isPayment = e.type == LedgerType.payment || e.type == LedgerType.refund || e.refType == 'payment_void';
          if (!isPayment) continue;
          // Customers pay with a credit entry; suppliers are paid with a debit.
          final v = kind == PartyKind.customer ? e.credit.paisa - e.debit.paisa : e.debit.paisa - e.credit.paisa;
          paid[e.partyId] = (paid[e.partyId] ?? 0) + v;
          if (e.type == LedgerType.payment && (last[e.partyId] == null || e.at.isAfter(last[e.partyId]!))) last[e.partyId] = e.at;
        }
        return {
          for (final p in list(kind, includeInactive: true))
            p.id: PartyTotals(paid: Money(paid[p.id] ?? 0), billed: p.balance + Money(paid[p.id] ?? 0), lastPayment: last[p.id]),
        };
      });

  /// The customer for a bill typed at the POS: an existing one with the same
  /// mobile number (0300…, +92 300…, 92300… all match), otherwise a new
  /// customer saved with this name and number.
  /// The existing customer a name / mobile typed at the POS belongs to,
  /// or null when it is a new customer.
  ///
  /// * Mobile typed: the customer with that mobile (main or alternate
  ///   number). If none has it, a same-name customer who has no mobile
  ///   saved yet (the number is then added to them). A same-name
  ///   customer with a different mobile is a different person.
  /// * Only a name: the customer with that name (case and extra spaces
  ///   ignored). With several of that name, the one without a mobile,
  ///   otherwise the oldest.
  Party? matchCustomer({String name = '', String phone = ''}) {
    final n = nameKey(name);
    final key = phoneKey(phone);
    final all = list(PartyKind.customer)..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    bool hasPhone(Party p) => phoneKey(p.phone).isNotEmpty || phoneKey(p.altPhone).isNotEmpty;
    if (key.isNotEmpty) {
      for (final p in all) {
        if (phoneKey(p.phone) == key || phoneKey(p.altPhone) == key) return p;
      }
      if (n.isEmpty) return null;
      for (final p in all) {
        if (nameKey(p.name) == n && !hasPhone(p)) return p;
      }
      return null;
    }
    if (n.isEmpty) return null;
    final same = all.where((p) => nameKey(p.name) == n).toList();
    if (same.isEmpty) return null;
    for (final p in same) {
      if (!hasPhone(p)) return p;
    }
    return same.first;
  }

  Future<Party> findOrCreateCustomer({String name = '', String phone = ''}) async {
    final n = name.trim();
    final ph = phone.trim();
    if (n.isEmpty && ph.isEmpty) throw const ValidationException('Enter the customer\'s name or mobile number.');
    final found = matchCustomer(name: n, phone: ph);
    if (found != null) {
      final key = phoneKey(ph);
      if (key.isNotEmpty && phoneKey(found.phone).isEmpty && phoneKey(found.altPhone).isEmpty) {
        return update(found.copyWith(phone: ph));
      }
      return found;
    }
    return create(kind: PartyKind.customer, name: n.isEmpty ? 'Customer $ph' : n, phone: ph);
  }

  /// A name in one comparable form: lower case, single spaces.
  static String nameKey(String name) => name.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  /// Digits of a phone number in one comparable form (Pakistani numbers
  /// as 03XXXXXXXXX). Empty when there are too few digits to compare.
  static String phoneKey(String phone) {
    var d = phone.replaceAll(RegExp(r'\D'), '');
    if (d.startsWith('0092')) d = d.substring(2);
    if (d.startsWith('92') && d.length == 12) d = '0${d.substring(2)}';
    if (d.length == 10 && d.startsWith('3')) d = '0$d';
    return d.length >= 7 ? d : '';
  }

  Money totalReceivables() => Money.sum(list(PartyKind.customer, includeInactive: true).map((p) => p.balance).where((b) => b.isPositive));
  Money totalPayables() => Money.sum(list(PartyKind.supplier, includeInactive: true).map((p) => p.balance).where((b) => b.isPositive));

  List<Payment> payments({DateTime? from, DateTime? to, PartyKind? kind, String? partyId}) =>
      ctx.all(Boxes.payments, Payment.fromJson).where((p) {
        if (from != null && p.at.isBefore(dayStart(from))) return false;
        if (to != null && p.at.isAfter(dayEnd(to))) return false;
        if (kind != null && p.partyKind != kind) return false;
        if (partyId != null && p.partyId != partyId) return false;
        return true;
      }).toList()
        ..sort((a, b) => b.at.compareTo(a.at));
}

class PartyTotals {
  final Money paid; // received from a customer / paid to a supplier
  final Money billed; // balance + paid
  final DateTime? lastPayment;
  const PartyTotals({required this.paid, required this.billed, this.lastPayment});
}
