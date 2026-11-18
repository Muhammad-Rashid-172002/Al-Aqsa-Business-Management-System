import '../../core/money.dart';
import 'json_utils.dart';

enum PartyKind { customer, supplier }

/// Customer or supplier profile. [balance] is a cache of the ledger total:
/// for customers it is the receivable (they owe us), for suppliers the
/// payable (we owe them). The ledger is always the source of truth.
class Party {
  final String id;
  final PartyKind kind;
  final String name;
  final String company;
  final String contactPerson;
  final String phone;
  final String address;
  final String email;
  final Money openingBalance;
  final Money balance;
  final String notes;
  final bool active;
  final DateTime createdAt;

  const Party({
    required this.id,
    required this.kind,
    required this.name,
    this.company = '',
    this.contactPerson = '',
    this.phone = '',
    this.address = '',
    this.email = '',
    this.openingBalance = const Money.zero(),
    this.balance = const Money.zero(),
    this.notes = '',
    this.active = true,
    required this.createdAt,
  });

  Party copyWith({
    String? name,
    String? company,
    String? contactPerson,
    String? phone,
    String? address,
    String? email,
    Money? balance,
    String? notes,
    bool? active,
  }) =>
      Party(
        id: id,
        kind: kind,
        name: name ?? this.name,
        company: company ?? this.company,
        contactPerson: contactPerson ?? this.contactPerson,
        phone: phone ?? this.phone,
        address: address ?? this.address,
        email: email ?? this.email,
        openingBalance: openingBalance,
        balance: balance ?? this.balance,
        notes: notes ?? this.notes,
        active: active ?? this.active,
        createdAt: createdAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'name': name,
        'company': company,
        'contactPerson': contactPerson,
        'phone': phone,
        'address': address,
        'email': email,
        'openingBalance': openingBalance.paisa,
        'balance': balance.paisa,
        'notes': notes,
        'active': active,
        'createdAt': createdAt.toIso8601String(),
      };

  factory Party.fromJson(Map<String, dynamic> j) => Party(
        id: s(j['id']),
        kind: enumByName(PartyKind.values, j['kind'], PartyKind.customer),
        name: s(j['name']),
        company: s(j['company']),
        contactPerson: s(j['contactPerson']),
        phone: s(j['phone']),
        address: s(j['address']),
        email: s(j['email']),
        openingBalance: m(j['openingBalance']),
        balance: m(j['balance']),
        notes: s(j['notes']),
        active: b(j['active'], true),
        createdAt: parseDate(j['createdAt']),
      );
}

enum LedgerType { opening, sale, payment, salesReturn, purchase, purchaseReturn, adjustment, reversal, repairCharge, refund }

/// Append-only ledger line. Amount sign convention per party:
///  customer: debit increases receivable, credit reduces it.
///  supplier: credit increases payable, debit reduces it.
class LedgerEntry {
  final String id;
  final PartyKind partyKind;
  final String partyId;
  final DateTime at;
  final LedgerType type;
  final Money debit;
  final Money credit;
  final String refType;
  final String refId;
  final String refNumber;
  final String note;
  final String userId;

  const LedgerEntry({
    required this.id,
    required this.partyKind,
    required this.partyId,
    required this.at,
    required this.type,
    this.debit = const Money.zero(),
    this.credit = const Money.zero(),
    this.refType = '',
    this.refId = '',
    this.refNumber = '',
    this.note = '',
    required this.userId,
  });

  /// Effect on the party balance (receivable for customers, payable for suppliers).
  Money get balanceEffect => partyKind == PartyKind.customer ? debit - credit : credit - debit;

  Map<String, dynamic> toJson() => {
        'id': id,
        'partyKind': partyKind.name,
        'partyId': partyId,
        'at': at.toIso8601String(),
        'type': type.name,
        'debit': debit.paisa,
        'credit': credit.paisa,
        'refType': refType,
        'refId': refId,
        'refNumber': refNumber,
        'note': note,
        'userId': userId,
      };

  factory LedgerEntry.fromJson(Map<String, dynamic> j) => LedgerEntry(
        id: s(j['id']),
        partyKind: enumByName(PartyKind.values, j['partyKind'], PartyKind.customer),
        partyId: s(j['partyId']),
        at: parseDate(j['at']),
        type: enumByName(LedgerType.values, j['type'], LedgerType.adjustment),
        debit: m(j['debit']),
        credit: m(j['credit']),
        refType: s(j['refType']),
        refId: s(j['refId']),
        refNumber: s(j['refNumber']),
        note: s(j['note']),
        userId: s(j['userId']),
      );
}

enum PaymentMethod { cash, bankTransfer, cheque, mobileWallet, other }

extension PaymentMethodLabel on PaymentMethod {
  String get label => switch (this) {
        PaymentMethod.cash => 'Cash',
        PaymentMethod.bankTransfer => 'Bank Transfer',
        PaymentMethod.cheque => 'Cheque',
        PaymentMethod.mobileWallet => 'JazzCash / Easypaisa',
        PaymentMethod.other => 'Other',
      };
}

enum PaymentDirection { received, paid }

class Payment {
  final String id;
  final String number;
  final PartyKind? partyKind; // null for walk-in cash sale
  final String? partyId;
  final DateTime at;
  final Money amount;
  final PaymentMethod method;
  final PaymentDirection direction;
  final String refType;
  final String refId;
  final String note;
  final String userId;
  final bool voided;
  final String voidReason;

  const Payment({
    required this.id,
    required this.number,
    this.partyKind,
    this.partyId,
    required this.at,
    required this.amount,
    required this.method,
    required this.direction,
    this.refType = '',
    this.refId = '',
    this.note = '',
    required this.userId,
    this.voided = false,
    this.voidReason = '',
  });

  Payment voidWith(String reason) => Payment(
        id: id,
        number: number,
        partyKind: partyKind,
        partyId: partyId,
        at: at,
        amount: amount,
        method: method,
        direction: direction,
        refType: refType,
        refId: refId,
        note: note,
        userId: userId,
        voided: true,
        voidReason: reason,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'number': number,
        'partyKind': partyKind?.name,
        'partyId': partyId,
        'at': at.toIso8601String(),
        'amount': amount.paisa,
        'method': method.name,
        'direction': direction.name,
        'refType': refType,
        'refId': refId,
        'note': note,
        'userId': userId,
        'voided': voided,
        'voidReason': voidReason,
      };

  factory Payment.fromJson(Map<String, dynamic> j) => Payment(
        id: s(j['id']),
        number: s(j['number']),
        partyKind: j['partyKind'] == null ? null : enumByName(PartyKind.values, j['partyKind'], PartyKind.customer),
        partyId: sn(j['partyId']),
        at: parseDate(j['at']),
        amount: m(j['amount']),
        method: enumByName(PaymentMethod.values, j['method'], PaymentMethod.cash),
        direction: enumByName(PaymentDirection.values, j['direction'], PaymentDirection.received),
        refType: s(j['refType']),
        refId: s(j['refId']),
        note: s(j['note']),
        userId: s(j['userId']),
        voided: b(j['voided']),
        voidReason: s(j['voidReason']),
      );
}
