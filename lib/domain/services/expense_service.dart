import '../../core/errors.dart';
import '../../core/ids.dart';
import '../../core/money.dart';
import '../../data/store/data_store.dart';
import '../models/expense.dart';
import '../models/party.dart';
import '../models/user.dart';
import 'context.dart';

/// Shop expenses (rent, bills, salaries, transport, maintenance …).
class ExpenseService {
  final ServiceContext ctx;
  ExpenseService(this.ctx);

  /// Expenses in the period, newest first. Deleted ones only on request.
  List<Expense> list({DateTime? from, DateTime? to, String? category, bool includeDeleted = false, String query = ''}) {
    final q = query.trim().toLowerCase();
    return ctx.all(Boxes.expenses, Expense.fromJson).where((e) {
      if (e.deleted && !includeDeleted) return false;
      if (from != null && e.date.isBefore(from)) return false;
      if (to != null && e.date.isAfter(to)) return false;
      if (category != null && category.isNotEmpty && e.category != category) return false;
      if (q.isNotEmpty && !('${e.number} ${e.title} ${e.category} ${e.description}').toLowerCase().contains(q)) return false;
      return true;
    }).toList()
      ..sort((a, b) {
        final c = b.date.compareTo(a.date);
        return c != 0 ? c : b.number.compareTo(a.number);
      });
  }

  Expense? byId(String id) {
    final j = ctx.store.read(Boxes.expenses, id);
    return j == null ? null : Expense.fromJson(j);
  }

  /// Total per category for the period (deleted excluded), largest first.
  List<(String, Money)> byCategory({DateTime? from, DateTime? to}) {
    final m = <String, Money>{};
    for (final e in list(from: from, to: to)) {
      m[e.category] = (m[e.category] ?? const Money.zero()) + e.amount;
    }
    return m.entries.map((e) => (e.key, e.value)).toList()..sort((a, b) => b.$2.compareTo(a.$2));
  }

  Money total({DateTime? from, DateTime? to}) => Money.sum(list(from: from, to: to).map((e) => e.amount));

  /// Categories used so far plus the standard ones.
  List<String> categories() => {...expenseCategories, ...ctx.all(Boxes.expenses, Expense.fromJson).map((e) => e.category).where((c) => c.isNotEmpty)}.toList();

  void _validate(String category, String title, Money amount) {
    if (category.trim().isEmpty) throw const ValidationException('Choose or type an expense category.');
    if (title.trim().isEmpty) throw const ValidationException('Enter what the expense was for.');
    if (!amount.isPositive) throw const ValidationException('The amount must be more than zero.');
  }

  Future<Expense> create({
    required String category,
    required String title,
    required Money amount,
    required DateTime date,
    String description = '',
    PaymentMethod method = PaymentMethod.cash,
    String? receiptPath,
  }) async {
    ctx.require(Permission.manageExpenses);
    _validate(category, title, amount);
    final uow = ctx.uow();
    final now = ctx.now();
    final e = Expense(
      id: newId(),
      number: ctx.nextNumber(uow, 'expense', 'EXP', pad: 5),
      date: date,
      category: category.trim(),
      title: title.trim(),
      amount: amount,
      description: description.trim(),
      method: method,
      receiptPath: (receiptPath ?? '').isEmpty ? null : receiptPath,
      createdBy: ctx.userId,
      createdAt: now,
      updatedAt: now,
      history: [ExpenseChange(now, 'created', '${amount.format()} ${category.trim()}', ctx.userId)],
    );
    uow.put(Boxes.expenses, e.id, e.toJson());
    ctx.audit(uow, 'create', 'expense', e.id, '${e.number} ${e.category} ${amount.format()}');
    await uow.commit();
    return e;
  }

  Future<Expense> update(
    String id, {
    required String category,
    required String title,
    required Money amount,
    required DateTime date,
    String description = '',
    PaymentMethod method = PaymentMethod.cash,
    String? receiptPath,
  }) async {
    ctx.require(Permission.manageExpenses);
    _validate(category, title, amount);
    final old = byId(id);
    if (old == null) throw const NotFoundException('Expense not found.');
    if (old.deleted) throw const BusinessException('This expense was deleted. Restore it first.');
    final changes = <String>[
      if (old.amount != amount) 'amount ${old.amount.format()} → ${amount.format()}',
      if (old.category != category.trim()) 'category ${old.category} → ${category.trim()}',
      if (old.title != title.trim()) 'title changed',
      if (old.date != date) 'date changed',
      if (old.method != method) 'payment method ${old.method.label} → ${method.label}',
      if (old.description != description.trim()) 'description changed',
      if ((old.receiptPath ?? '') != (receiptPath ?? '')) 'receipt changed',
    ];
    if (changes.isEmpty) return old;
    final now = ctx.now();
    final e = old.copyWith(
      category: category.trim(),
      title: title.trim(),
      amount: amount,
      date: date,
      description: description.trim(),
      method: method,
      receiptPath: receiptPath,
      clearReceipt: (receiptPath ?? '').isEmpty,
      updatedAt: now,
      history: [...old.history, ExpenseChange(now, 'edited', changes.join('; '), ctx.userId)],
    );
    final uow = ctx.uow()..put(Boxes.expenses, id, e.toJson());
    ctx.audit(uow, 'update', 'expense', id, '${e.number}: ${changes.join('; ')}');
    await uow.commit();
    return e;
  }

  /// Marks the expense deleted (kept with its history; left out of reports).
  Future<void> delete(String id, {String reason = ''}) async {
    ctx.require(Permission.manageExpenses);
    final old = byId(id);
    if (old == null) throw const NotFoundException('Expense not found.');
    if (old.deleted) return;
    final now = ctx.now();
    final e = old.copyWith(deleted: true, updatedAt: now, history: [...old.history, ExpenseChange(now, 'deleted', reason.trim(), ctx.userId)]);
    final uow = ctx.uow()..put(Boxes.expenses, id, e.toJson());
    ctx.audit(uow, 'delete', 'expense', id, '${e.number} ${e.amount.format()} ${reason.trim()}');
    await uow.commit();
  }

  Future<void> restore(String id) async {
    ctx.require(Permission.manageExpenses);
    final old = byId(id);
    if (old == null || !old.deleted) return;
    final now = ctx.now();
    final e = old.copyWith(deleted: false, updatedAt: now, history: [...old.history, ExpenseChange(now, 'restored', '', ctx.userId)]);
    final uow = ctx.uow()..put(Boxes.expenses, id, e.toJson());
    ctx.audit(uow, 'restore', 'expense', id, e.number);
    await uow.commit();
  }
}
