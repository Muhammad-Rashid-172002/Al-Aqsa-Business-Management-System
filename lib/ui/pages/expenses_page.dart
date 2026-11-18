import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../domain/models/expense.dart';
import '../../domain/models/party.dart';
import '../../domain/services/report_service.dart';
import '../../domain/services/report_tables.dart';
import '../../export/tabular.dart';
import '../print_actions.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/file_browser.dart';
import '../widgets/forms.dart';
import 'backup_page.dart' show openFolder;

/// Shop expenses: add, view, edit, delete (kept with history), filter,
/// export and print.
class ExpensesPage extends ConsumerStatefulWidget {
  const ExpensesPage({super.key});
  @override
  ConsumerState<ExpensesPage> createState() => _ExpensesPageState();
}

class _ExpensesPageState extends ConsumerState<ExpensesPage> {
  DateTime _from = DateTime(DateTime.now().year, DateTime.now().month);
  DateTime _to = DateTime.now();
  String? _category;
  String _q = '';
  bool _showDeleted = false;

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    final app = ref.watch(liveServicesProvider);
    final to = DateTime(_to.year, _to.month, _to.day, 23, 59, 59);
    final list = app.expenses.list(from: _from, to: to, category: _category, includeDeleted: _showDeleted, query: _q);
    final live = list.where((e) => !e.deleted).toList();
    final total = Money.sum(live.map((e) => e.amount));
    final byCat = app.expenses.byCategory(from: _from, to: to);
    final range = DateRange(_from, to);
    List<ExportTable> tables() {
      final sheets = ReportBuilder(app).workbook(ReportKind.expenses, range, ReportFilter(txnType: _category));
      // Exactly the rows on screen (search applied).
      final ids = {for (final e in live) e.number};
      return [ExportTable(sheets[0].title, sheets[0].headers, sheets[0].rows.where((r) => ids.contains(r[0])).toList(), footer: [
        ['Total (${live.length})', null, null, null, null, null, total.paisa / 100, null]
      ], info: sheets[0].info), sheets[1]];
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PageHeader(title: 'Expenses', breadcrumbs: const ['Expenses'], actions: [
          ExportMenu(tables: tables, name: 'Expenses ${dateFmt.format(_from).replaceAll('/', '-')}', settings: () => app.ctx.settings, landscape: true),
          FilledButton.icon(key: const ValueKey('add-expense'), onPressed: () => showExpenseDialog(context, ref), icon: const Icon(Icons.add), label: const Text('Add Expense')),
        ]),
        DateRangeBar(from: _from, to: _to, onChanged: (a, b) => setState(() {
              _from = a;
              _to = b;
            })),
        const SizedBox(height: 12),
        ResponsiveGrid(minItemWidth: 220, children: [
          StatCard(label: 'Total expenses (period)', icon: Icons.payments_outlined, value: AnimatedMoney(total), tone: c.danger, caption: '${live.length} entr${live.length == 1 ? 'y' : 'ies'}'),
          for (final (cat, amt) in byCat.take(3)) StatCard(label: cat, icon: Icons.category_outlined, value: AnimatedMoney(amt)),
        ]),
        const SizedBox(height: 12),
        Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SizedBox(
            width: 260,
            child: TextField(
              decoration: const InputDecoration(labelText: 'Search expenses', prefixIcon: Icon(Icons.search), isDense: true),
              onChanged: (v) => setState(() => _q = v),
            ),
          ),
          SizedBox(
            width: 220,
            child: AppDropdown<String?>(
              key: const ValueKey('expense-category-filter'),
              value: _category,
              decoration: const InputDecoration(labelText: 'Category', isDense: true),
              items: [
                const DropdownMenuItem(value: null, child: Text('All categories')),
                for (final cat in app.expenses.categories()) DropdownMenuItem(value: cat, child: Text(cat)),
              ],
              onChanged: (v) => setState(() => _category = v),
            ),
          ),
          FilterChip(label: const Text('Show deleted'), selected: _showDeleted, onSelected: (v) => setState(() => _showDeleted = v)),
        ]),
        const SizedBox(height: 12),
        AppCard(
          padding: EdgeInsets.zero,
          child: AppTable<Expense>(
            rows: list,
            pageSize: 50,
            onRowTap: (e) => _view(context, e),
            empty: const EmptyState(icon: Icons.receipt_long_outlined, title: 'No expenses in this period', message: 'Add rent, bills, salaries and other running costs to see the net operating profit.'),
            columns: [
              AppColumn('No', flex: 1, minWidth: 90, (e) => Text(e.number, style: TextStyle(decoration: e.deleted ? TextDecoration.lineThrough : null))),
              AppColumn('Date', flex: 1, minWidth: 96, (e) => Text(dateFmt.format(e.date))),
              AppColumn('Category', flex: 2, minWidth: 130, (e) => Text(e.category)),
              AppColumn('Title', flex: 3, minWidth: 160, (e) => Text(e.title, overflow: TextOverflow.ellipsis)),
              AppColumn('Method', flex: 1, minWidth: 90, (e) => Text(e.method.label)),
              AppColumn('Receipt', flex: 1, minWidth: 70, (e) => (e.receiptPath ?? '').isEmpty ? const Text('—') : Icon(Icons.attach_file, size: 16, color: c.accent)),
              AppColumn('Amount', numeric: true, flex: 2, minWidth: 110, (e) => Text(e.deleted ? 'DELETED' : e.amount.format(), style: TextStyle(fontWeight: FontWeight.w700, color: e.deleted ? c.textMuted : null))),
            ],
          ),
        ),
      ]),
    );
  }

  Future<void> _view(BuildContext context, Expense e) async {
    final app = ref.read(servicesProvider);
    final c = AppTheme.of(context);
    await showDialog<void>(
      context: context,
      builder: (ctx) => FormDialog(
        title: '${e.number} • ${e.category}',
        width: 560,
        body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          InfoRow('Title', e.title),
          InfoRow('Amount', e.amount.format()),
          InfoRow('Date', dateFmt.format(e.date)),
          InfoRow('Payment method', e.method.label),
          if (e.description.isNotEmpty) InfoRow('Description', e.description),
          InfoRow('Receipt', (e.receiptPath ?? '').isEmpty ? 'None' : e.receiptPath!),
          if (e.deleted) InfoRow('Status', 'DELETED — not counted in reports', color: c.danger),
          const SizedBox(height: 10),
          Text('History', style: TextStyle(fontWeight: FontWeight.w700, color: c.text)),
          for (final h in e.history) Text('${dateTimeFmt.format(h.at)} • ${h.action}${h.summary.isEmpty ? '' : ' • ${h.summary}'}', style: TextStyle(color: c.textMuted, fontSize: 12)),
        ]),
        actions: [
          if ((e.receiptPath ?? '').isNotEmpty && File(e.receiptPath!).existsSync())
            TextButton.icon(onPressed: () => openFolder(File(e.receiptPath!).parent.path), icon: const Icon(Icons.folder_open, size: 18), label: const Text('Show receipt')),
          if (e.deleted)
            TextButton(onPressed: () async {
              Navigator.pop(ctx);
              await runAction(context, () => app.expenses.restore(e.id), success: 'Expense restored');
            }, child: const Text('Restore'))
          else ...[
            TextButton(
              onPressed: () async {
                final reason = TextEditingController();
                final ok = await showDialog<bool>(
                  context: ctx,
                  builder: (d) => AlertDialog(
                    title: Text('Delete ${e.number}?'),
                    content: SizedBox(
                      width: 380,
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Text('${e.title} • ${e.amount.format()}\nIt will no longer count in reports. It stays in the history and can be restored.'),
                        const SizedBox(height: 10),
                        TextField(controller: reason, decoration: const InputDecoration(labelText: 'Reason (optional)')),
                      ]),
                    ),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
                      FilledButton(style: FilledButton.styleFrom(backgroundColor: AppTheme.of(d).danger), onPressed: () => Navigator.pop(d, true), child: const Text('Delete')),
                    ],
                  ),
                );
                if (ok == true && ctx.mounted) {
                  Navigator.pop(ctx);
                  if (context.mounted) await runAction(context, () => app.expenses.delete(e.id, reason: reason.text), success: 'Expense deleted');
                }
                reason.dispose();
              },
              child: Text('Delete', style: TextStyle(color: c.danger)),
            ),
            OutlinedButton(onPressed: () {
              Navigator.pop(ctx);
              showExpenseDialog(context, ref, existing: e);
            }, child: const Text('Edit')),
          ],
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }
}

Future<void> showExpenseDialog(BuildContext context, WidgetRef ref, {Expense? existing}) =>
    showDialog<void>(context: context, builder: (_) => _ExpenseDialog(existing: existing));

class _ExpenseDialog extends ConsumerStatefulWidget {
  final Expense? existing;
  const _ExpenseDialog({this.existing});
  @override
  ConsumerState<_ExpenseDialog> createState() => _ExpenseDialogState();
}

class _ExpenseDialogState extends ConsumerState<_ExpenseDialog> {
  late final _title = TextEditingController(text: widget.existing?.title ?? '');
  late final _amount = TextEditingController(text: widget.existing == null ? '' : (widget.existing!.amount.paisa / 100).toStringAsFixed(2));
  late final _desc = TextEditingController(text: widget.existing?.description ?? '');
  late final _custom = TextEditingController();
  late String _category = widget.existing?.category ?? expenseCategories.first;
  late DateTime _date = widget.existing?.date ?? DateTime.now();
  late PaymentMethod _method = widget.existing?.method ?? PaymentMethod.cash;
  late String? _receipt = widget.existing?.receiptPath;
  bool _saving = false;

  @override
  void dispose() {
    _title.dispose();
    _amount.dispose();
    _desc.dispose();
    _custom.dispose();
    super.dispose();
  }

  Future<void> _pickReceipt() async {
    final path = await browseFiles(context, mode: BrowseMode.openFile, title: 'Receipt (PDF or image)', extensions: const ['.pdf', '.png', '.jpg', '.jpeg', '.webp', '.bmp']);
    if (path == null || !mounted) return;
    await runAction(context, () async {
      final saved = await ref.read(servicesProvider).importMedia(path, folder: 'receipts', allowPdf: true);
      setState(() => _receipt = saved);
    });
  }

  Future<void> _save() async {
    final app = ref.read(servicesProvider);
    final cat = _category == '__custom' ? _custom.text.trim() : _category;
    final amount = Money.tryParse(_amount.text) ?? const Money.zero();
    setState(() => _saving = true);
    final ok = await runAction(context, () async {
      if (widget.existing == null) {
        await app.expenses.create(category: cat, title: _title.text, amount: amount, date: _date, description: _desc.text, method: _method, receiptPath: _receipt);
      } else {
        await app.expenses.update(widget.existing!.id, category: cat, title: _title.text, amount: amount, date: _date, description: _desc.text, method: _method, receiptPath: _receipt);
      }
    }, success: widget.existing == null ? 'Expense added' : 'Expense updated');
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(liveServicesProvider);
    final cats = app.expenses.categories();
    if (!cats.contains(_category) && _category != '__custom') cats.add(_category);
    return FormDialog(
      title: widget.existing == null ? 'Add expense' : 'Edit ${widget.existing!.number}',
      width: 560,
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AppDropdown<String>(
          key: const ValueKey('expense-category'),
          value: _category,
          decoration: const InputDecoration(labelText: 'Category *'),
          items: [
            for (final cat in cats) DropdownMenuItem(value: cat, child: Text(cat)),
            const DropdownMenuItem(value: '__custom', child: Text('Other category…')),
          ],
          onChanged: (v) => setState(() => _category = v ?? _category),
        ),
        if (_category == '__custom') ...[
          const SizedBox(height: 12),
          TextField(key: const ValueKey('expense-custom-category'), controller: _custom, decoration: const InputDecoration(labelText: 'New category name *')),
        ],
        const SizedBox(height: 12),
        TextField(key: const ValueKey('expense-title'), controller: _title, decoration: const InputDecoration(labelText: 'Title * (e.g. "November rent")')),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: TextField(
              key: const ValueKey('expense-amount'),
              controller: _amount,
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
              decoration: const InputDecoration(labelText: 'Amount (Rs) *'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () async {
                final d = await showDatePicker(context: context, firstDate: DateTime(2020), lastDate: DateTime.now().add(const Duration(days: 366)), initialDate: _date);
                if (d != null) setState(() => _date = DateTime(d.year, d.month, d.day, 12));
              },
              icon: const Icon(Icons.event, size: 18),
              label: Text('Date: ${dateFmt.format(_date)}'),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        AppDropdown<PaymentMethod>(
          value: _method,
          decoration: const InputDecoration(labelText: 'Payment method'),
          items: [for (final m in PaymentMethod.values) DropdownMenuItem(value: m, child: Text(m.label))],
          onChanged: (v) => setState(() => _method = v ?? _method),
        ),
        const SizedBox(height: 12),
        TextField(controller: _desc, maxLines: 3, decoration: const InputDecoration(labelText: 'Description')),
        const SizedBox(height: 12),
        Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          OutlinedButton.icon(onPressed: _pickReceipt, icon: const Icon(Icons.attach_file, size: 18), label: Text((_receipt ?? '').isEmpty ? 'Attach receipt (optional)' : 'Change receipt')),
          if ((_receipt ?? '').isNotEmpty) ...[
            Text(_receipt!.split(RegExp(r'[\\/]')).last, style: TextStyle(color: AppTheme.of(context).textMuted, fontSize: 12)),
            TextButton(onPressed: () => setState(() => _receipt = null), child: const Text('Remove')),
          ],
        ]),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('expense-save'), onPressed: _saving ? null : _save, child: const Text('Save')),
      ],
    );
  }
}
