import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors.dart';
import '../../core/money.dart';
import '../../domain/models/documents.dart';
import '../../domain/models/labour.dart';
import '../../domain/models/party.dart';
import '../../domain/models/user.dart';
import '../../export/tabular.dart';
import '../../printing/pdf_docs.dart';
import '../bill_lines.dart';
import '../print_actions.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/forms.dart';

/// Labour / installation bills: the workers' (karegar's) charges, kept
/// apart from shop invoices, the customer ledger and shop profit.
class LabourBillsPage extends ConsumerStatefulWidget {
  const LabourBillsPage({super.key});
  @override
  ConsumerState<LabourBillsPage> createState() => _LabourBillsPageState();
}

class _LabourBillsPageState extends ConsumerState<LabourBillsPage> {
  DateTime _from = DateTime(DateTime.now().year, DateTime.now().month);
  DateTime _to = DateTime.now();
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    final app = ref.watch(liveServicesProvider);
    final list = app.labour.list(from: _from, to: _to, query: _q);
    final s = app.labour.summary(from: _from, to: _to);
    List<ExportTable> tables() => [
          ExportTable('Labour Bills', ['Bill', 'Date', 'Customer', 'Worker', 'Invoice', 'Total', 'Received', 'Due', 'Paid to worker', 'Status'], [
            for (final b in list)
              [
                b.number,
                b.date,
                b.customerName,
                b.workerName,
                b.saleNumber,
                b.total.paisa / 100,
                b.collected.paisa / 100,
                b.due.paisa / 100,
                b.paidToWorker.paisa / 100,
                b.cancelled ? 'Cancelled' : (b.due.isPositive ? 'Due' : 'Paid'),
              ]
          ], footer: [
            ['Total (${s.bills})', null, null, null, null, s.billed.paisa / 100, s.collected.paisa / 100, s.due.paisa / 100, s.paidToWorkers.paisa / 100, null]
          ]),
          ExportTable('Labour by worker', ['Worker', 'Billed', 'Collected', 'Paid to worker'], [
            for (final (w, billed, coll, paid) in app.labour.byWorker(from: _from, to: _to)) [w, billed.paisa / 100, coll.paisa / 100, paid.paisa / 100]
          ]),
        ];
    return SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PageHeader(title: 'Labour Bills', breadcrumbs: const ['Sales', 'Labour Bills'], actions: [
          ExportMenu(tables: tables, name: 'Labour Bills ${dateFmt.format(_from).replaceAll('/', '-')}', settings: () => app.ctx.settings, landscape: true),
          FilledButton.icon(key: const ValueKey('add-labour'), onPressed: () => showLabourBillDialog(context, ref), icon: const Icon(Icons.add), label: const Text('New Labour Bill')),
        ]),
        Text("Installation and labour charges are the worker's (karegar's) money. They are billed here, separately from the shop invoice, and are not in shop sales, the customer ledger or shop profit.",
            style: TextStyle(color: c.textMuted)),
        const SizedBox(height: 10),
        DateRangeBar(from: _from, to: _to, onChanged: (a, b) => setState(() {
              _from = a;
              _to = b;
            })),
        const SizedBox(height: 12),
        ResponsiveGrid(minItemWidth: 200, children: [
          StatCard(label: 'Labour billed', icon: Icons.handyman_outlined, value: AnimatedMoney(s.billed), caption: '${s.bills} bill${s.bills == 1 ? '' : 's'}'),
          StatCard(label: 'Collected from customers', icon: Icons.call_received_rounded, value: AnimatedMoney(s.collected)),
          StatCard(label: 'Due from customers', icon: Icons.schedule, value: AnimatedMoney(s.due), tone: c.warning),
          StatCard(label: 'Held for workers', icon: Icons.account_balance_wallet_outlined, value: AnimatedMoney(s.heldForWorkers), caption: 'Collected, not yet paid to workers'),
        ]),
        const SizedBox(height: 12),
        SizedBox(
          width: 300,
          child: TextField(
            decoration: const InputDecoration(labelText: 'Search bill, customer, worker, invoice', prefixIcon: Icon(Icons.search), isDense: true),
            onChanged: (v) => setState(() => _q = v),
          ),
        ),
        const SizedBox(height: 12),
        AppCard(
          padding: EdgeInsets.zero,
          child: AppTable<LabourBill>(
            rows: list,
            pageSize: 50,
            onRowTap: (b) => showLabourBillDetail(context, ref, b.id),
            empty: const EmptyState(icon: Icons.handyman_outlined, title: 'No labour bills in this period', message: 'Add installation or labour in the POS (Add Item > Labour / installation) or press New Labour Bill.'),
            columns: [
              AppColumn('Bill', flex: 1, minWidth: 100, (b) => Text(b.number, style: TextStyle(fontWeight: FontWeight.w600, decoration: b.cancelled ? TextDecoration.lineThrough : null))),
              AppColumn('Date', flex: 1, minWidth: 96, (b) => Text(dateFmt.format(b.date))),
              AppColumn('Customer', flex: 2, minWidth: 140, (b) => Text(b.customerName, overflow: TextOverflow.ellipsis)),
              AppColumn('Worker', flex: 2, minWidth: 120, (b) => Text(b.workerName.isEmpty ? '—' : b.workerName, overflow: TextOverflow.ellipsis)),
              AppColumn('Invoice', flex: 1, minWidth: 100, (b) => Text(b.saleNumber.isEmpty ? '—' : b.saleNumber)),
              AppColumn('Total', numeric: true, flex: 1, minWidth: 100, (b) => Text(b.total.format(), style: const TextStyle(fontWeight: FontWeight.w700))),
              AppColumn('Due', numeric: true, flex: 1, minWidth: 90, (b) => Text(b.cancelled ? 'Cancelled' : (b.due.isPositive ? b.due.format() : '—'), style: TextStyle(color: b.due.isPositive ? c.warning : c.textMuted))),
              AppColumn('To worker', numeric: true, flex: 1, minWidth: 100, (b) => Text(b.paidToWorker.isZero ? '—' : b.paidToWorker.format())),
            ],
          ),
        ),
      ]),
    );
  }
}

/// New labour bill: customer, worker, labour lines, discount, received now.
Future<void> showLabourBillDialog(BuildContext context, WidgetRef ref, {Party? customer}) =>
    showDialog<void>(context: context, barrierDismissible: false, builder: (_) => _LabourBillDialog(customer: customer));

class _LabourBillDialog extends ConsumerStatefulWidget {
  final Party? customer;
  const _LabourBillDialog({this.customer});
  @override
  ConsumerState<_LabourBillDialog> createState() => _LabourBillDialogState();
}

class _LabourBillDialogState extends ConsumerState<_LabourBillDialog> {
  Party? _customer;
  final _name = TextEditingController();
  final _phone = TextEditingController();
  TextEditingController? _workerField; // owned by the Autocomplete
  final _disc = TextEditingController();
  final _received = TextEditingController();
  final _notes = TextEditingController();
  PaymentMethod _method = PaymentMethod.cash;
  List<SaleItem> _lines = [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _customer = widget.customer;
  }

  @override
  void dispose() {
    for (final t in [_name, _phone, _disc, _received, _notes]) {
      t.dispose();
    }
    super.dispose();
  }

  Money get _total => Money.sum(_lines.map((l) => l.net)) - (Money.tryParse(_disc.text) ?? const Money.zero());

  Future<void> _addLine([int? i]) async {
    final line = await showCustomLineDialog(context, ref, kind: SaleLineKind.service, existing: i == null ? null : _lines[i]);
    if (line == null || !mounted) return;
    setState(() => i == null ? _lines = [..._lines, line] : _lines = ([..._lines]..[i] = line));
  }

  Future<void> _pickCustomer() async {
    final app = ref.read(servicesProvider);
    final p = await pickFromList<Party>(
      context,
      title: 'Customer for the labour bill',
      items: app.parties.list(PartyKind.customer),
      label: (x) => x.name,
      subtitle: (x) => x.phone,
    );
    if (p != null && mounted) setState(() => _customer = p);
  }

  Future<void> _save() async {
    final app = ref.read(servicesProvider);
    if (_lines.isEmpty) return showToast(context, 'Add at least one labour / installation line.', error: true);
    setState(() => _busy = true);
    try {
      var customerId = _customer?.id;
      if (customerId == null && (_name.text.trim().isNotEmpty || _phone.text.trim().isNotEmpty)) {
        customerId = (await app.parties.findOrCreateCustomer(name: _name.text, phone: _phone.text)).id;
      }
      final b = await app.labour.create(
        lines: [for (final l in _lines) LabourLine(description: l.name, qty: l.qty, rate: l.unitPrice, unit: l.unit)],
        discount: (Money.tryParse(_disc.text) ?? const Money.zero()) + Money.sum(_lines.map((l) => l.discount)),
        customerId: customerId,
        workerName: _workerField?.text ?? '',
        receivedNow: Money.tryParse(_received.text) ?? const Money.zero(),
        method: _method,
        notes: _notes.text,
      );
      if (!mounted) return;
      Navigator.pop(context);
      showToast(context, 'Labour bill ${b.number} saved: ${b.total.format()}');
      final st = app.ctx.settings;
      await showPdf(context, st, () => labourBillPdf(st, b), name: b.number);
    } catch (e) {
      if (mounted) showToast(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    final workers = ref.watch(liveServicesProvider).technicians.technicians().map((t) => t.name).toList();
    return FormDialog(
      title: 'New Labour Bill',
      width: 720,
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: _customer != null
                ? Text('Customer: ${_customer!.name}${_customer!.phone.isEmpty ? '' : '  •  ${_customer!.phone}'}', style: TextStyle(fontWeight: FontWeight.w600, color: c.text))
                : FieldRow([
                    LabeledField('Customer name', _name, key: const ValueKey('lb-name')),
                    LabeledField('Mobile', _phone, key: const ValueKey('lb-phone')),
                  ]),
          ),
          const SizedBox(width: 8),
          TextButton(onPressed: _pickCustomer, child: Text(_customer == null ? 'Choose saved customer' : 'Change')),
        ]),
        Autocomplete<String>(
          optionsBuilder: (v) => workers.where((w) => w.toLowerCase().contains(v.text.toLowerCase())),
          fieldViewBuilder: (ctx, ctl, focus, submit) {
            _workerField = ctl;
            return TextField(
              key: const ValueKey('lb-worker'),
              controller: ctl,
              focusNode: focus,
              decoration: const InputDecoration(labelText: 'Karegar / worker name', isDense: true),
            );
          },
        ),
        const SizedBox(height: 10),
        for (var i = 0; i < _lines.length; i++)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(_lines[i].name),
            subtitle: Text('${_lines[i].unitPrice.format()} × ${_lines[i].qty.format()} ${_lines[i].unit}'),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(_lines[i].net.format(), style: const TextStyle(fontWeight: FontWeight.w700)),
              IconButton(onPressed: () => _addLine(i), icon: const Icon(Icons.edit_outlined, size: 18)),
              IconButton(onPressed: () => setState(() => _lines = [..._lines]..removeAt(i)), icon: Icon(Icons.close, size: 18, color: c.danger)),
            ]),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(key: const ValueKey('lb-add-line'), onPressed: _addLine, icon: const Icon(Icons.add, size: 18), label: const Text('Add labour / installation')),
        ),
        FieldRow([
          LabeledField('Discount (Rs)', _disc, formatters: moneyInput, onChanged: (_) => setState(() {})),
          LabeledField('Received now (Rs)', _received, key: const ValueKey('lb-received'), formatters: moneyInput),
          LabeledField('Notes', _notes),
        ]),
        SizedBox(
          width: 240,
          child: AppDropdown<PaymentMethod>(
            value: _method,
            decoration: const InputDecoration(labelText: 'Received by'),
            items: [for (final m0 in PaymentMethod.values) DropdownMenuItem(value: m0, child: Text(m0.label))],
            onChanged: (v) => setState(() => _method = v ?? _method),
          ),
        ),
        const SizedBox(height: 10),
        InfoRow('Labour total', _total.format(), strong: true),
      ]),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('lb-save'), onPressed: _busy ? null : _save, child: const Text('Save labour bill')),
      ],
    );
  }
}

/// Labour bill: lines, money received and paid to the worker, actions.
Future<void> showLabourBillDetail(BuildContext context, WidgetRef ref, String id) =>
    showDialog<void>(context: context, builder: (_) => _LabourBillDetail(id: id));

class _LabourBillDetail extends ConsumerWidget {
  final String id;
  const _LabourBillDetail({required this.id});

  Future<Money?> _amount(BuildContext context, String title, Money max) async {
    final v = await promptText(context, title: title, label: 'Amount (Rs), up to ${max.format()}', initial: max.toDecimalString());
    return v == null ? null : Money.tryParse(v);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AppTheme.of(context);
    final app = ref.watch(liveServicesProvider);
    final b = app.labour.byId(id);
    if (b == null) return const RecordGone('labour bill');
    final st = app.ctx.settings;
    String when(LabourMoney x) => '${dateTimeFmt.format(x.at)}  •  ${x.method.label}${x.note.isEmpty ? '' : '  •  ${x.note}'}';
    return FormDialog(
      title: 'Labour bill ${b.number}${b.cancelled ? ' (cancelled)' : ''}',
      width: 640,
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InfoRow('Date', dateTimeFmt.format(b.date)),
        InfoRow('Customer', '${b.customerName}${b.customerPhone.isEmpty ? '' : '  •  ${b.customerPhone}'}'),
        InfoRow('Worker (karegar)', b.workerName.isEmpty ? '—' : b.workerName),
        if (b.saleNumber.isNotEmpty) InfoRow('With shop invoice', b.saleNumber),
        const Divider(),
        for (final l in b.lines) InfoRow('${l.description}  ×${l.qty.format()} ${l.unit}', l.amount.format()),
        if (b.discount.isPositive) InfoRow('Discount', '− ${b.discount.format()}'),
        InfoRow('Labour total', b.total.format(), strong: true),
        InfoRow('Received from customer', b.collected.format()),
        InfoRow('Due', b.due.format(), color: b.due.isPositive ? c.warning : null),
        InfoRow('Paid to worker', b.paidToWorker.format()),
        if (b.heldForWorker.isPositive) InfoRow('Held for the worker', b.heldForWorker.format(), color: c.accent),
        if (b.collections.isNotEmpty) ...[
          const Divider(),
          Text('Received', style: TextStyle(fontWeight: FontWeight.w700, color: c.text)),
          for (final x in b.collections) InfoRow(when(x), x.amount.format()),
        ],
        if (b.workerPayments.isNotEmpty) ...[
          const Divider(),
          Text('Paid to worker', style: TextStyle(fontWeight: FontWeight.w700, color: c.text)),
          for (final x in b.workerPayments) InfoRow(when(x), x.amount.format()),
        ],
        if (b.cancelled) Text('Cancelled: ${b.cancelReason}', style: TextStyle(color: c.danger)),
        if (b.notes.isNotEmpty) Text('Notes: ${b.notes}', style: TextStyle(color: c.textMuted)),
        const SizedBox(height: 6),
        Text("Not part of shop sales, the customer's shop ledger or profit.", style: TextStyle(color: c.textMuted, fontSize: 12)),
      ]),
      actions: [
        if (!b.cancelled && app.ctx.can(Permission.cancelTransactions))
          TextButton(
            onPressed: () async {
              final r = await promptText(context, title: 'Cancel labour bill ${b.number}', label: 'Reason');
              if (r != null && context.mounted) await runAction(context, () => app.labour.cancel(b.id, r), success: 'Labour bill cancelled');
            },
            child: Text('Cancel bill', style: TextStyle(color: c.danger)),
          ),
        OutlinedButton.icon(onPressed: () => showPdf(context, st, () => labourBillPdf(st, b), name: b.number), icon: const Icon(Icons.print_outlined, size: 18), label: const Text('Print')),
        if (!b.cancelled && (b.total - b.paidToWorker).isPositive)
          OutlinedButton(
            key: const ValueKey('lb-pay-worker'),
            onPressed: () async {
              final a = await _amount(context, 'Pay the worker', b.total - b.paidToWorker);
              if (a != null && context.mounted) await runAction(context, () => app.labour.payWorker(b.id, a), success: 'Paid ${a.format()} to the worker');
            },
            child: const Text('Pay worker'),
          ),
        if (!b.cancelled && b.due.isPositive)
          FilledButton(
            key: const ValueKey('lb-collect'),
            onPressed: () async {
              final a = await _amount(context, 'Receive labour payment', b.due);
              if (a != null && context.mounted) await runAction(context, () => app.labour.collect(b.id, a), success: 'Received ${a.format()}');
            },
            child: const Text('Receive'),
          ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
      ],
    );
  }
}
