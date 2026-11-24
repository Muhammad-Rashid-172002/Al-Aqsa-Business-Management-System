import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../domain/models/documents.dart';
import '../../domain/models/party.dart';
import '../../domain/models/product.dart';
import '../../domain/models/user.dart';
import '../../export/tabular.dart';
import '../../printing/pdf_docs.dart';
import '../bill_lines.dart';
import '../edit_invoice_dialog.dart';
import '../print_actions.dart';
import '../record_actions.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/forms.dart';
import 'parties_page.dart';
import 'pos_page.dart';
import 'returns_page.dart';

/// "Sales / POS": the POS screen plus the invoice register.
class SalesPage extends StatelessWidget {
  const SalesPage({super.key});
  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    return DefaultTabController(
      length: 2,
      child: Column(children: [
        Container(
          color: c.surface,
          child: TabBar(labelColor: c.accent, tabs: const [Tab(icon: Icon(Icons.point_of_sale), text: 'New Sale'), Tab(icon: Icon(Icons.receipt_long), text: 'Invoices')]),
        ),
        const Expanded(child: TabBarView(physics: NeverScrollableScrollPhysics(), children: [PosPage(), InvoicesList()])),
      ]),
    );
  }
}

class InvoicesList extends ConsumerStatefulWidget {
  const InvoicesList({super.key});
  @override
  ConsumerState<InvoicesList> createState() => _InvoicesListState();
}

class _InvoicesListState extends ConsumerState<InvoicesList> {
  DateTime _from = DateTime(DateTime.now().year, DateTime.now().month);
  DateTime _to = DateTime.now();
  String _q = '';
  DocStatus? _status = DocStatus.completed;
  bool _unpaid = false;

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    final app = ref.watch(liveServicesProvider);
    final paidBy = app.sales.paidBySale();
    Money due(Sale s0) => s0.status == DocStatus.completed ? s0.total - (paidBy[s0.id] ?? const Money.zero()) : s0.remaining;
    final rows = app.sales.list(from: _from, to: _to, status: _status, query: _q).where((s0) => !_unpaid || due(s0).isPositive).toList();
    final total = Money.sum(rows.where((s0) => s0.status == DocStatus.completed).map((s0) => s0.total));
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SearchBox(hint: 'Invoice no or customer…', width: 260, onChanged: (v) => setState(() => _q = v)),
          AppDropdownButton<DocStatus?>(
            value: _status,
            items: const [
              DropdownMenuItem(value: DocStatus.completed, child: Text('Completed')),
              DropdownMenuItem(value: DocStatus.cancelled, child: Text('Cancelled')),
              DropdownMenuItem(value: DocStatus.draft, child: Text('Held / draft')),
              DropdownMenuItem(value: null, child: Text('All')),
            ],
            onChanged: (v) => setState(() => _status = v),
          ),
          FilterChip(label: const Text('With balance due'), selected: _unpaid, onSelected: (v) => setState(() => _unpaid = v)),
          DateRangeBar(from: _from, to: _to, onChanged: (a, b) => setState(() {
                _from = a;
                _to = b;
              })),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: Text('${rows.length} invoice(s) • ${total.format()}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: c.textMuted))),
          const SizedBox(width: 12),
          ExportMenu(tables: () => [ExportTable('Invoices', ['Invoice', 'Date', 'Customer', 'Total', 'Paid', 'Balance', 'Status'], [
              for (final s0 in rows) [s0.number, dateFmt.format(s0.date), s0.customerName, s0.total.paisa / 100, (s0.total - due(s0)).paisa / 100, due(s0).paisa / 100, s0.status.name]
            ])]),
        ]),
        const SizedBox(height: 12),
        Expanded(
          child: SingleChildScrollView(
            child: AppTable<Sale>(
              rows: rows,
              onRowTap: (s0) => s0.status == DocStatus.draft ? _openDraft(s0) : showInvoiceDetail(context, ref, s0.id),
              empty: const EmptyState(icon: Icons.receipt_long, title: 'No invoices', message: 'Completed sales in this period appear here.'),
              columns: [
                AppColumn('Invoice', (s0) => Text('${s0.number}${s0.edited ? ' (edited)' : ''}', style: const TextStyle(fontWeight: FontWeight.w600))),
                AppColumn('Date', (s0) => Text(dateTimeFmt.format(s0.date))),
                AppColumn('Customer', flex: 3, (s0) => Text(s0.customerName)),
                AppColumn('Total', numeric: true, (s0) => Text(s0.total.format())),
                AppColumn('Balance', numeric: true, (s0) => Text(due(s0).isPositive ? due(s0).format() : '—', style: TextStyle(color: due(s0).isPositive ? c.warning : c.textMuted))),
                AppColumn('Status', (s0) => StatusPill(s0.status == DocStatus.draft ? 'held' : s0.status.name, s0.status == DocStatus.cancelled ? c.danger : (s0.status == DocStatus.draft ? c.warning : c.accent))),
actionsColumn<Sale>((s0) => RowActionsMenu(
                    onView: s0.status == DocStatus.draft ? null : () => showInvoiceDetail(context, ref, s0.id),
                    onEdit: s0.status == DocStatus.draft
                        ? () => _openDraft(s0)
                        : (s0.status == DocStatus.completed && app.ctx.can(Permission.editInvoices) ? () => showEditInvoice(context, ref, s0) : null),
                    onDelete: s0.status == DocStatus.draft || (s0.status == DocStatus.completed && app.ctx.can(Permission.cancelTransactions)) ? () => deleteSaleRecord(context, ref, s0) : null,
                  )),
],
            ),
          ),
        ),
      ]),
    );
  }

  void _openDraft(Sale s0) {
    ref.read(posDraftProvider.notifier).state = s0;
    DefaultTabController.of(context).animateTo(0);
  }
}

Future<void> showInvoiceDetail(BuildContext context, WidgetRef ref, String saleId) => showDialog<void>(context: context, builder: (_) => _InvoiceDetail(saleId));

class _InvoiceDetail extends ConsumerWidget {
  final String saleId;
  const _InvoiceDetail(this.saleId);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AppTheme.of(context);
    final app = ref.watch(liveServicesProvider);
    final user = ref.watch(currentUserProvider)!;
    final found = app.sales.byId(saleId);
    if (found == null) return const RecordGone('invoice');
    final s0 = found;
    final customer = s0.customerId == null ? null : app.parties.byId(PartyKind.customer, s0.customerId!);
    final st = app.ctx.settings;
    final returns = app.sales.returns().where((r) => r.originalId == s0.id).toList();
    final payments = app.parties.payments().where((p) => p.refId == s0.id).toList();
    final canReturn = s0.status == DocStatus.completed && s0.items.any((e) => e.isStock && (e.qty - e.returnedQty).isPositive);
    final paidSoFar = app.sales.paidAgainst(s0.id);
    final dueNow = s0.total - paidSoFar;
    final canEdit = s0.status == DocStatus.completed && user.can(Permission.editInvoices);
    return FormDialog(
      title: 'Invoice ${s0.number}',
      width: 820,
      headerTrailing: StatusPill(s0.status.name.toUpperCase(), s0.status == DocStatus.cancelled ? c.danger : c.accent),
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AdaptiveSplit(breakpoint: 560, spacing: 0, children: [
          Padding(padding: const EdgeInsetsDirectional.only(end: 15), child: InfoRow('Customer', s0.customerName)),
          Padding(padding: const EdgeInsetsDirectional.only(start: 15), child: InfoRow('Date', dateTimeFmt.format(s0.date))),
        ]),
        if (s0.creditApprovedBy != null) InfoRow('Credit approved by', app.auth.users().where((u) => u.id == s0.creditApprovedBy).map((u) => u.displayName).firstOrNull ?? '-'),
        if (s0.status == DocStatus.cancelled) InfoRow('Cancel reason', s0.cancelReason, color: c.danger),
        const Divider(),
        for (final it in s0.items)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Row(children: [
              Flexible(child: Text('${it.name}  ×  ${it.qty.format()}${it.unit.isEmpty ? '' : ' ${it.unit}'}')),
              const SizedBox(width: 6),
              LineKindPill(it),
            ]),
            subtitle: Text([
              '${it.unitPrice.format()} each',
              if (!it.discount.isZero) 'discount ${it.discount.format()}',
              if (it.serials.isNotEmpty) 'S/N ${it.serials.map(SerialRecord.displayOf).join(', ')}',
              if (it.returnedQty.isPositive) 'returned ${it.returnedQty.format()}',
              if (user.can(Permission.viewFinancials)) 'cost ${it.cogs.format()}',
            ].join(' • ')),
            trailing: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 150), child: Text(it.net.format(), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w600))),
          ),
        const Divider(),
        InfoRow('Subtotal', s0.subtotal.format()),
        if (!s0.lineDiscounts.isZero) InfoRow('Line discounts', '− ${s0.lineDiscounts.format()}'),
        if (!s0.invoiceDiscount.isZero) InfoRow('Bill discount', '− ${s0.invoiceDiscount.format()}'),
        InfoRow('Total', s0.total.format(), strong: true),
        InfoRow('Paid at sale (${s0.method.label})', s0.paidAtSale.format()),
        if (s0.status == DocStatus.completed) ...[
          InfoRow('Paid against invoice (all payments)', paidSoFar.format()),
          InfoRow(dueNow.isNegative ? 'Paid in excess (customer credit)' : 'Balance due now', (dueNow.isNegative ? -dueNow : dueNow).format(),
              color: dueNow.isPositive ? c.warning : null),
        ] else if (s0.remaining.isPositive)
          InfoRow('Balance at sale', s0.remaining.format(), color: c.warning),
        if (user.can(Permission.viewFinancials) && s0.status == DocStatus.completed) InfoRow('Gross profit on invoice', (s0.total - s0.cogs).format(), color: c.accent),
        if (payments.isNotEmpty) ...[
          const Divider(),
          Text('Payments', style: TextStyle(fontWeight: FontWeight.w700, color: c.text)),
          for (final p in payments)
            InfoRow('${p.number} • ${dateFmt.format(p.at)}${p.voided ? ' (void)' : ''}', '${p.direction == PaymentDirection.received ? '+' : '−'}${p.amount.format()}'),
        ],
        if (returns.isNotEmpty) ...[
          const Divider(),
          Text('Returns', style: TextStyle(fontWeight: FontWeight.w700, color: c.text)),
          for (final r in returns) InfoRow('${r.number} • ${dateFmt.format(r.date)}', r.total.format()),
        ],
        if (s0.edited) ...[
          const Divider(),
          InvoiceEditHistory(s0),
        ],
      ]),
      actions: [
        if (s0.status == DocStatus.completed && user.can(Permission.cancelTransactions))
          TextButton(
            onPressed: () async {
              final reason = await promptText(context, title: 'Cancel invoice ${s0.number}?', label: 'Reason (kept in audit log)', confirm: 'Cancel invoice');
              if (reason == null || !context.mounted) return;
              await runAction(context, () => app.sales.cancel(s0.id, reason), success: 'Invoice cancelled. Stock and account reversed.');
            },
            child: Text('Cancel invoice', style: TextStyle(color: c.danger)),
          ),
        if (canEdit)
          OutlinedButton.icon(
            key: const ValueKey('inv-edit'),
            onPressed: () => showEditInvoice(context, ref, s0),
            icon: const Icon(Icons.edit_outlined, size: 18),
            label: const Text('Edit invoice'),
          ),
        if (canReturn) OutlinedButton.icon(onPressed: () => showSalesReturnDialog(context, ref, s0), icon: const Icon(Icons.undo, size: 18), label: const Text('Return items')),
        if (customer != null && customer.balance.isPositive && user.can(Permission.manageLedgers))
          OutlinedButton.icon(onPressed: () => showPaymentDialog(context, ref, customer), icon: const Icon(Icons.payments_outlined, size: 18), label: const Text('Receive payment')),
        OutlinedButton.icon(
          onPressed: () => showPdf(context, st, () => invoicePdf(st, s0, customer: customer, paper: paperFromSetting(st.receiptFormat), paid: paidSoFar), name: s0.number),
          icon: const Icon(Icons.receipt, size: 18),
          label: const Text('Receipt'),
        ),
        FilledButton.icon(
          onPressed: () => showPdf(context, st, () => invoicePdf(st, s0, customer: customer, paid: paidSoFar), name: s0.number),
          icon: const Icon(Icons.print, size: 18),
          label: const Text('A4 Invoice'),
        ),
      ],
    );
  }
}
