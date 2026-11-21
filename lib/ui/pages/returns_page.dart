import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors.dart';
import '../../core/qty.dart';
import '../../domain/models/documents.dart';
import '../../domain/models/party.dart';
import '../../domain/models/product.dart';
import '../../domain/models/user.dart';
import '../../domain/services/purchase_service.dart';
import '../print_actions.dart';
import '../../export/tabular.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/forms.dart';

/// Lists customer and supplier returns; new returns start from an invoice
/// or purchase picked here.
class ReturnsPage extends ConsumerWidget {
  const ReturnsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(liveServicesProvider);
    final user = ref.watch(currentUserProvider)!;
    final c = AppTheme.of(context);
    Widget list(List<ReturnDoc> rows, bool sales) => SingleChildScrollView(
          padding: const EdgeInsets.only(top: 16),
          child: AppTable<ReturnDoc>(
            rows: rows,
            onRowTap: (r) => _showReturn(context, r, sales),
            empty: EmptyState(icon: Icons.assignment_return_outlined, title: 'No returns yet', message: sales ? 'Customer returns appear here.' : 'Returns to suppliers appear here.'),
            columns: [
              AppColumn('Return No', (r) => Text(r.number, style: const TextStyle(fontWeight: FontWeight.w600))),
              AppColumn('Date', (r) => Text(dateFmt.format(r.date))),
              AppColumn(sales ? 'Invoice' : 'Purchase', (r) => Text(r.originalNumber)),
              AppColumn(sales ? 'Customer' : 'Supplier', flex: 3, (r) {
                final p = r.partyId == null ? null : app.parties.byId(sales ? PartyKind.customer : PartyKind.supplier, r.partyId!);
                return Text(p?.name ?? 'Walk-in');
              }),
              AppColumn('Items', flex: 1, (r) => Text('${r.lines.length}')),
              AppColumn('Settlement', (r) => Text(r.refundMode == RefundMode.cash ? 'Cash ${r.method.label}' : 'Account credit')),
              AppColumn('Amount', numeric: true, (r) => Text(r.total.format(), style: const TextStyle(fontWeight: FontWeight.w600))),
            ],
          ),
        );

    return DefaultTabController(
      length: 2,
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          PageHeader(title: 'Returns', breadcrumbs: const ['Returns'], subtitle: 'Technician returns are handled under Technicians.', actions: [
            ExportMenu(tables: () {
              ExportTable sheet(String title, List<ReturnDoc> rows, PartyKind kind) => ExportTable(title, ['Return', 'Date', 'Original', kind == PartyKind.customer ? 'Customer' : 'Supplier', 'Items', 'Settlement', 'Reason', 'Amount'], [
                    for (final r in rows)
                      [
                        r.number,
                        r.date,
                        r.originalNumber,
                        r.partyId == null ? 'Walk-in' : (app.parties.byId(kind, r.partyId!)?.name ?? ''),
                        r.lines.map((l) => '${l.name} x${l.qty.format()}${l.serials.isEmpty ? '' : ' (${l.serials.map(SerialRecord.displayOf).join(', ')})'}').join('; '),
                        r.refundMode == RefundMode.cash ? 'Cash ${r.method.label}' : 'Account credit',
                        r.reason,
                        r.total.paisa / 100,
                      ]
                  ], footer: [
                    ['Total (${rows.length})', null, null, null, null, null, null, rows.fold<double>(0, (a, r) => a + r.total.paisa / 100)]
                  ]);
              return [sheet('Customer Returns', app.sales.returns(), PartyKind.customer), sheet('Returns to Suppliers', app.purchases.returns(), PartyKind.supplier)];
            }),
            if (user.can(Permission.manageSales))
              FilledButton.icon(
                icon: const Icon(Icons.undo, size: 18),
                label: const Text('Customer Return'),
                onPressed: () async {
                  final sale = await pickFromList<Sale>(context,
                      title: 'Pick the original invoice',
                      items: app.sales.list(status: DocStatus.completed),
                      label: (s0) => '${s0.number} • ${s0.customerName}',
                      subtitle: (s0) => '${dateFmt.format(s0.date)} • ${s0.total.format()}');
                  if (sale != null && context.mounted) await showSalesReturnDialog(context, ref, sale);
                },
              ),
            if (user.can(Permission.managePurchases))
              OutlinedButton.icon(
                icon: const Icon(Icons.local_shipping_outlined, size: 18),
                label: const Text('Return to Supplier'),
                onPressed: () async {
                  final pur = await pickFromList<Purchase>(context,
                      title: 'Pick the original purchase',
                      items: app.purchases.list(includeCancelled: false),
                      label: (p) => '${p.number} • ${app.parties.byId(PartyKind.supplier, p.supplierId)?.name ?? ''}',
                      subtitle: (p) => '${dateFmt.format(p.date)} • ${p.supplierInvoiceNo} • ${p.total.format()}');
                  if (pur != null && context.mounted) await showPurchaseReturnDialog(context, ref, pur);
                },
              ),
          ]),
          TabBar(isScrollable: true, labelColor: c.accent, tabs: const [Tab(text: 'Customer returns'), Tab(text: 'Supplier returns')]),
          Expanded(child: TabBarView(children: [list(app.sales.returns(), true), list(app.purchases.returns(), false)])),
        ]),
      ),
    );
  }

  void _showReturn(BuildContext context, ReturnDoc r, bool sales) {
    showDialog<void>(
      context: context,
      builder: (ctx) => FormDialog(
        title: 'Return ${r.number}',
        body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          InfoRow('Date', dateTimeFmt.format(r.date)),
          InfoRow(sales ? 'Invoice' : 'Purchase', r.originalNumber),
          InfoRow('Reason', r.reason),
          InfoRow('Settlement', r.refundMode == RefundMode.cash ? 'Cash refund (${r.method.label})' : 'Credited to account'),
          const Divider(),
          for (final l in r.lines)
            ListTile(
              dense: true,
              title: Text('${l.name} × ${l.qty.format()}'),
              subtitle: Text([if (l.serials.isNotEmpty) 'S/N ${l.serials.map(SerialRecord.displayOf).join(', ')}', if (sales) 'Condition: ${returnConditionLabel(l.condition)} (${returnConditionStock(l.condition)})'].join(' • ')),
              trailing: Text(l.amount.format()),
            ),
          const Divider(),
          InfoRow('Total', r.total.format(), strong: true),
        ]),
        actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      ),
    );
  }
}

class _RetLine {
  final String productId;
  final String name;
  final Qty eligible;
  final bool serial;
  final bool decimal;
  final List<String> serialChoices;
  final TextEditingController qty = TextEditingController();
  final Set<String> chosen = {};
  String condition = 'resellable';
  _RetLine(this.productId, this.name, this.eligible, this.serial, this.decimal, this.serialChoices);
}

Future<void> showSalesReturnDialog(BuildContext context, WidgetRef ref, Sale sale) async {
  final app = ref.read(servicesProvider);
  final lines = <_RetLine>[];
  for (final it in sale.items) {
    final el = it.qty - it.returnedQty;
    if (!el.isPositive) continue;
    final p = app.catalog.byId(it.productId);
    final soldKeys = it.serials.where((k) => app.serials.byKey(k)?.status == SerialStatus.sold && app.serials.byKey(k)?.saleId == sale.id).toList();
    lines.add(_RetLine(it.productId, it.name, el, p?.requiresSerial ?? false, p?.allowDecimal ?? false, soldKeys));
  }
  if (lines.isEmpty) {
    showToast(context, 'Everything on ${sale.number} has already been returned.', error: true);
    return;
  }
  await _returnDialog(context,
      title: 'Customer return • ${sale.number}',
      lines: lines,
      conditions: const {
        'resellable': 'Saleable - back to stock',
        'faulty': 'Faulty - kept aside',
        'damaged': 'Damaged',
        'inspect': 'Needs inspection',
      },
      allowCredit: sale.customerId != null,
      submit: (inputs, reason, mode, method) => app.sales.createReturn(saleId: sale.id, lines: inputs, reason: reason, refundMode: mode, method: method));
}

Future<void> showPurchaseReturnDialog(BuildContext context, WidgetRef ref, Purchase pur) async {
  final app = ref.read(servicesProvider);
  final lines = <_RetLine>[];
  for (final it in pur.items) {
    final el = it.qty - it.returnedQty;
    if (!el.isPositive) continue;
    final p = app.catalog.byId(it.productId);
    final keys = it.serials
        .where((k) => {SerialStatus.inStock, SerialStatus.damaged, SerialStatus.awaitingRepair}.contains(app.serials.byKey(k)?.status) && app.serials.byKey(k)?.purchaseId == pur.id)
        .toList();
    lines.add(_RetLine(it.productId, it.name, el, p?.requiresSerial ?? false, p?.allowDecimal ?? false, keys));
  }
  if (lines.isEmpty) {
    showToast(context, 'Nothing left to return on ${pur.number}.', error: true);
    return;
  }
  await _returnDialog(context,
      title: 'Return to supplier • ${pur.number}',
      lines: lines,
      conditions: const {},
      allowCredit: true,
      defaultCredit: true,
      submit: (inputs, reason, mode, method) => app.purchases.createReturn(purchaseId: pur.id, lines: inputs, reason: reason, refundMode: mode, method: method));
}

Future<void> _returnDialog(
  BuildContext context, {
  required String title,
  required List<_RetLine> lines,
  required Map<String, String> conditions,
  required bool allowCredit,
  bool defaultCredit = false,
  required Future<ReturnDoc> Function(List<ReturnLineInput>, String, RefundMode, PaymentMethod) submit,
}) async {
  final reason = TextEditingController();
  var mode = defaultCredit && allowCredit ? RefundMode.accountCredit : RefundMode.cash;
  var method = PaymentMethod.cash;
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
      final c = AppTheme.of(ctx);
      return FormDialog(
        title: title,
        width: 760,
        body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final l in lines)
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(border: Border.all(color: c.border), borderRadius: BorderRadius.circular(12)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${l.name}  •  returnable: ${l.eligible.format()}', style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                if (l.serial)
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    for (final k in l.serialChoices)
                      FilterChip(
                        label: Text(SerialRecord.displayOf(k)),
                        selected: l.chosen.contains(k),
                        onSelected: (v) => setS(() => v ? l.chosen.add(k) : l.chosen.remove(k)),
                      ),
                    if (l.serialChoices.isEmpty) Text('No returnable units', style: TextStyle(color: c.textMuted)),
                  ])
                else
                  SizedBox(
                    width: 200,
                    child: TextField(controller: l.qty, inputFormatters: qtyInput, decoration: const InputDecoration(labelText: 'Return quantity'), onChanged: (_) => setS(() {})),
                  ),
                if (conditions.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(spacing: 6, children: [
                    for (final e in conditions.entries) ChoiceChip(label: Text(e.value), selected: l.condition == e.key, onSelected: (_) => setS(() => l.condition = e.key)),
                  ]),
                ],
              ]),
            ),
          FieldRow([LabeledField('Reason for return *', reason)]),
          Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 260),
              child: SegmentedButton<RefundMode>(
                segments: [
                  const ButtonSegment(value: RefundMode.cash, label: Text('Cash refund')),
                  if (allowCredit) const ButtonSegment(value: RefundMode.accountCredit, label: Text('Adjust account')),
                ],
                selected: {mode},
                onSelectionChanged: (s) => setS(() => mode = s.first),
              ),
            ),
            if (mode == RefundMode.cash)
              SizedBox(
                width: 220,
                child: AppDropdown<PaymentMethod>(
                  value: method,
                  decoration: const InputDecoration(labelText: 'Refund method'),
                  items: [for (final m0 in PaymentMethod.values) DropdownMenuItem(value: m0, child: Text(m0.label))],
                  onChanged: (v) => setS(() => method = v ?? method),
                ),
              ),
          ]),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final inputs = <ReturnLineInput>[];
              for (final l in lines) {
                if (l.serial) {
                  if (l.chosen.isNotEmpty) inputs.add(ReturnLineInput(productId: l.productId, qty: Qty.units(l.chosen.length), serials: l.chosen.toList(), condition: l.condition));
                } else {
                  final q = Qty.tryParse(l.qty.text);
                  if (q != null && q.isPositive) inputs.add(ReturnLineInput(productId: l.productId, qty: q, condition: l.condition));
                }
              }
              if (inputs.isEmpty) return showToast(ctx, 'Enter what is being returned.', error: true);
              try {
                final doc = await submit(inputs, reason.text, mode, method);
                if (ctx.mounted) {
                  Navigator.pop(ctx);
                  showToast(context, 'Return ${doc.number} saved: ${doc.total.format()}');
                }
              } catch (e) {
                if (ctx.mounted) showToast(ctx, friendlyError(e), error: true);
              }
            },
            child: const Text('Save Return'),
          ),
        ],
      );
    }),
  );
}
