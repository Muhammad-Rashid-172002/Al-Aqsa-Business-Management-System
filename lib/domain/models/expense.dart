import '../../core/money.dart';
import 'json_utils.dart';
import 'party.dart';

/// Standard shop expense categories (the owner can also type their own).
const expenseCategories = [
  'Shop rent',
  'Electricity bill',
  'Internet bill',
  'Staff salaries',
  'Transport',
  'Maintenance',
  'Other',
];

/// One change to an expense (kept with the expense).
class ExpenseChange {
  final DateTime at;
  final String action; // created | edited | deleted | restored
  final String summary;
  final String userId;
  const ExpenseChange(this.at, this.action, this.summary, this.userId);
  Map<String, dynamic> toJson() => {'at': at.toIso8601String(), 'action': action, 'summary': summary, 'userId': userId};
  factory ExpenseChange.fromJson(Map<String, dynamic> j) => ExpenseChange(parseDate(j['at']), s(j['action']), s(j['summary']), s(j['userId']));
}

/// A shop running cost (rent, electricity, salaries …). Deleting keeps the
/// record (marked deleted, with its history) so nothing silently disappears;
/// deleted expenses are left out of every report.
class Expense {
  final String id;
  final String number;
  final DateTime date;
  final String category;
  final String title;
  final Money amount;
  final String description;
  final PaymentMethod method;
  final String? receiptPath;
  final bool deleted;
  final String createdBy;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<ExpenseChange> history;

  const Expense({
    required this.id,
    required this.number,
    required this.date,
    required this.category,
    required this.title,
    required this.amount,
    this.description = '',
    this.method = PaymentMethod.cash,
    this.receiptPath,
    this.deleted = false,
    this.createdBy = '',
    required this.createdAt,
    required this.updatedAt,
    this.history = const [],
  });

  Expense copyWith({
    DateTime? date,
    String? category,
    String? title,
    Money? amount,
    String? description,
    PaymentMethod? method,
    String? receiptPath,
    bool clearReceipt = false,
    bool? deleted,
    DateTime? updatedAt,
    List<ExpenseChange>? history,
  }) =>
      Expense(
        id: id,
        number: number,
        date: date ?? this.date,
        category: category ?? this.category,
        title: title ?? this.title,
        amount: amount ?? this.amount,
        description: description ?? this.description,
        method: method ?? this.method,
        receiptPath: clearReceipt ? null : (receiptPath ?? this.receiptPath),
        deleted: deleted ?? this.deleted,
        createdBy: createdBy,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        history: history ?? this.history,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'number': number,
        'date': date.toIso8601String(),
        'category': category,
        'title': title,
        'amount': amount.toJson(),
        'description': description,
        'method': method.name,
        'receiptPath': receiptPath,
        'deleted': deleted,
        'createdBy': createdBy,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'history': history.map((e) => e.toJson()).toList(),
      };

  factory Expense.fromJson(Map<String, dynamic> j) => Expense(
        id: s(j['id']),
        number: s(j['number']),
        date: parseDate(j['date']),
        category: s(j['category']),
        title: s(j['title']),
        amount: m(j['amount']),
        description: s(j['description']),
        method: enumByName(PaymentMethod.values, j['method'], PaymentMethod.cash),
        receiptPath: sn(j['receiptPath']),
        deleted: b(j['deleted']),
        createdBy: s(j['createdBy']),
        createdAt: parseDate(j['createdAt']),
        updatedAt: parseDate(j['updatedAt']),
        history: mapList(j['history']).map(ExpenseChange.fromJson).toList(),
      );
}
