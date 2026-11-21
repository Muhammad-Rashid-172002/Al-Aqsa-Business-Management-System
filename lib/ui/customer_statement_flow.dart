import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/money.dart';
import '../domain/models/operations.dart';
import '../domain/models/party.dart';
import '../domain/services/app_services.dart';
import '../domain/services/customer_statement.dart';
import '../printing/pdf_docs.dart';
import 'print_actions.dart';
import 'providers.dart';
import 'theme.dart';
import 'widgets/common.dart';
import 'widgets/forms.dart';

/// "Print Customer Statement": asks for the customer when [customer] is
/// null, then shows the period choice with Print Preview, Print and
/// Export PDF. [from] / [to] preselect a custom range.
Future<void> showCustomerStatement(BuildContext context, WidgetRef ref, {Party? customer, DateTime? from, DateTime? to}) async {
  var c = customer;
  if (c == null) {
    final app = ref.read(servicesProvider);
    c = await pickFromList<Party>(
      context,
      title: 'Customer statement - choose customer',
      items: app.parties.list(PartyKind.customer, includeInactive: true),
      label: (x) => x.name,
      subtitle: (x) => [if (x.phone.isNotEmpty) x.phone, 'Balance ${x.balance.format()}'].join('  •  '),
    );
    if (c == null || !context.mounted) return;
  }
  await showDialog<void>(context: context, builder: (_) => CustomerStatementDialog(customerId: c!.id, from: from, to: to));
}

class CustomerStatementDialog extends ConsumerStatefulWidget {
  final String customerId;
  final DateTime? from;
  final DateTime? to;
  const CustomerStatementDialog({super.key, required this.customerId, this.from, this.to});
  @override
  ConsumerState<CustomerStatementDialog> createState() => _CustomerStatementDialogState();
}

class _CustomerStatementDialogState extends ConsumerState<CustomerStatementDialog> {
  late StatementPeriod _period;
  DateTime? _from;
  DateTime? _to;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _from = widget.from;
    _to = widget.to;
    _period = (_from != null || _to != null) ? StatementPeriod.custom : StatementPeriod.complete;
  }

  CustomerStatement? _build(AppServices app) {
    try {
      return app.customerStatements.build(widget.customerId, period: _period, from: _from, to: _to);
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List> _pdf(AppSettings st, CustomerStatement s) async {
    try {
      return await customerStatementPdfInBackground(st, s);
    } catch (_) {
      // Some platforms cannot start an isolate; build on this one instead.
      return customerStatementPdf(st, s);
    }
  }

  Future<void> _run(Future<void> Function(Uint8List bytes, String name) action) async {
    final app = ref.read(servicesProvider);
    final s = _build(app);
    if (s == null) {
      showToast(context, 'Check the dates: the end date must not be before the start date.', error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      final bytes = await _pdf(app.ctx.settings, s);
      if (!mounted) return;
      await action(bytes, _fileName(s));
    } catch (e) {
      if (mounted) showToast(context, 'Could not create the statement: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _fileName(CustomerStatement s) {
    final range = s.from == null && s.to == null ? 'complete' : '${dateFmt.format(s.from ?? s.generatedAt)} to ${dateFmt.format(s.to ?? s.generatedAt)}'.replaceAll('/', '-');
    return 'Customer Statement ${s.customer.name} $range';
  }

  Future<void> _pickDate(bool start) async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year + 1, 12, 31),
      initialDate: (start ? _from : _to) ?? now,
    );
    if (d == null || !mounted) return;
    setState(() {
      _period = StatementPeriod.custom;
      if (start) {
        _from = d;
      } else {
        _to = d;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    final app = ref.watch(liveServicesProvider);
    final party = app.parties.byId(PartyKind.customer, widget.customerId);
    if (party == null) return const RecordGone('customer');
    final s = _build(app);
    Widget line(String label, Money v, {bool strong = false, Color? color}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            Expanded(child: Text(label, style: TextStyle(color: strong ? c.text : c.textMuted, fontWeight: strong ? FontWeight.w700 : FontWeight.w400))),
            Text(v.isNegative ? '${v.abs().format()} adv.' : v.format(),
                style: TextStyle(color: color ?? c.text, fontWeight: strong ? FontWeight.w800 : FontWeight.w600, fontSize: strong ? 16 : 14)),
          ]),
        );
    int count(InvoiceState st) => s?.invoices.where((i) => i.state == st).length ?? 0;

    return FormDialog(
      title: 'Print Customer Statement',
      width: 620,
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(party.name, key: const ValueKey('cs-customer'), style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: c.text)),
        if (party.phone.isNotEmpty || party.address.isNotEmpty)
          Text([party.phone, party.address].where((e) => e.isNotEmpty).join('  •  '), style: TextStyle(color: c.textMuted)),
        const SizedBox(height: 16),
        Text('Period', style: TextStyle(color: c.textMuted, fontSize: 12)),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final p in StatementPeriod.values)
            ChoiceChip(
              key: ValueKey('cs-period-${p.name}'),
              label: Text(p.label),
              selected: _period == p,
              onSelected: (_) => setState(() {
                _period = p;
                if (p == StatementPeriod.custom) {
                  final now = DateTime.now();
                  _from ??= DateTime(now.year, now.month, 1);
                  _to ??= now;
                }
              }),
            ),
        ]),
        if (_period == StatementPeriod.custom) ...[
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                key: const ValueKey('cs-from'),
                onPressed: () => _pickDate(true),
                icon: const Icon(Icons.event, size: 18),
                label: Text('From: ${_from == null ? 'start' : dateFmt.format(_from!)}'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                key: const ValueKey('cs-to'),
                onPressed: () => _pickDate(false),
                icon: const Icon(Icons.event, size: 18),
                label: Text('To: ${_to == null ? 'today' : dateFmt.format(_to!)}'),
              ),
            ),
          ]),
        ],
        const SizedBox(height: 16),
        Container(
          key: const ValueKey('cs-summary'),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: c.surfaceHigh, borderRadius: BorderRadius.circular(10), border: Border.all(color: c.border)),
          child: s == null
              ? Text('The end date is before the start date.', style: TextStyle(color: c.danger))
              : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text(
                    s.from == null && s.to == null
                        ? 'Complete history, to ${dateFmt.format(s.generatedAt)}'
                        : '${s.from == null ? 'Start' : dateFmt.format(s.from!)} to ${dateFmt.format(s.to ?? s.generatedAt)}',
                    style: TextStyle(color: c.textMuted, fontSize: 12),
                  ),
                  const SizedBox(height: 6),
                  line('Opening balance', s.openingBalance),
                  line('Total purchases / debit', s.totalDebit),
                  line('Payments received', s.totalPayments, color: c.accent),
                  line('Returns (${s.returns.length} item${s.returns.length == 1 ? '' : 's'})', s.totalReturns),
                  if (!s.totalOtherCredits.isZero) line('Adjustments / cancellations', s.totalOtherCredits),
                  const Divider(height: 14),
                  line(s.closingBalance.isNegative ? 'Advance with us' : 'Closing outstanding balance', s.closingBalance,
                      strong: true, color: s.closingBalance.isPositive ? c.warning : c.accent),
                  const SizedBox(height: 6),
                  Text(
                    '${s.invoices.length} invoice${s.invoices.length == 1 ? '' : 's'}: ${count(InvoiceState.paid)} paid, '
                    '${count(InvoiceState.partlyPaid)} partly paid, ${count(InvoiceState.unpaid)} unpaid'
                    '${count(InvoiceState.cancelled) > 0 ? ', ${count(InvoiceState.cancelled)} cancelled' : ''}  •  '
                    '${s.rows.length - 1} statement lines',
                    style: TextStyle(color: c.textMuted, fontSize: 12),
                  ),
                ]),
        ),
        const SizedBox(height: 8),
        Text('A4 statement with every invoice line, payment, return and adjustment and the running balance.', style: TextStyle(color: c.textMuted, fontSize: 12)),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        OutlinedButton.icon(
          key: const ValueKey('cs-pdf'),
          onPressed: _busy || s == null ? null : () => _run((b, n) => savePdf(context, b, name: n)),
          icon: const Icon(Icons.save_alt, size: 18),
          label: const Text('Export PDF'),
        ),
        OutlinedButton.icon(
          key: const ValueKey('cs-print'),
          onPressed: _busy || s == null ? null : () => _run((b, n) => printWithDialog(context, b, name: n)),
          icon: const Icon(Icons.print_outlined, size: 18),
          label: const Text('Print'),
        ),
        FilledButton.icon(
          key: const ValueKey('cs-preview'),
          onPressed: _busy || s == null
              ? null
              : () => _run((b, n) => showPdf(context, app.ctx.settings, () async => b, name: n)),
          icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.preview_outlined, size: 18),
          label: const Text('Print Preview'),
        ),
      ],
    );
  }
}
