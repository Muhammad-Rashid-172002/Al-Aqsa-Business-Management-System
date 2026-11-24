import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/errors.dart';
import '../core/money.dart';
import '../core/qty.dart';
import '../domain/models/documents.dart';
import '../domain/models/party.dart';
import '../domain/models/product.dart';
import '../domain/models/user.dart';
import 'bill_lines.dart';
import 'providers.dart';
import 'theme.dart';
import 'widgets/common.dart';
import 'widgets/forms.dart';

/// Whether the signed-in user may edit [s] (and why not).
String? whyCannotEdit(WidgetRef ref, Sale s) {
  final app = ref.read(servicesProvider);
  if (!app.ctx.can(Permission.editInvoices)) return 'Only the owner can edit completed invoices.';
  if (s.status != DocStatus.completed) return 'Only completed invoices can be edited.';
  if (s.items.any((e) => e.returnedQty.isPositive)) return 'This invoice has returns: record changes as a return.';
  if (s.items.any((e) => e.techUsageId != null)) return 'This invoice bills technician-installed material: cancel it and bill again.';
  return null;
}

/// Opens the editor for a completed invoice, or explains why it cannot be
/// edited.
Future<void> showEditInvoice(BuildContext context, WidgetRef ref, Sale sale) async {
  final why = whyCannotEdit(ref, sale);
  if (why != null) return showToast(context, why, error: true);
  await showDialog<void>(context: context, barrierDismissible: false, builder: (_) => EditInvoiceDialog(sale: sale));
}

class EditInvoiceDialog extends ConsumerStatefulWidget {
  final Sale sale;
  const EditInvoiceDialog({super.key, required this.sale});
  @override
  ConsumerState<EditInvoiceDialog> createState() => _EditInvoiceDialogState();
}

class _EditInvoiceDialogState extends ConsumerState<EditInvoiceDialog> {
  late List<SaleItem> _items = [...widget.sale.items];
  late final _disc = TextEditingController(text: widget.sale.invoiceDiscount.isZero ? '' : widget.sale.invoiceDiscount.toDecimalString());
  late final _notes = TextEditingController(text: widget.sale.notes);
  final _reason = TextEditingController();
  final _received = TextEditingController();
  PaymentMethod _method = PaymentMethod.cash;
  bool _busy = false;

  @override
  void dispose() {
    for (final t in [_disc, _notes, _reason, _received]) {
      t.dispose();
    }
    super.dispose();
  }

  Money get _discount => Money.tryParse(_disc.text) ?? const Money.zero();
  Money get _newTotal => Money.sum(_items.map((e) => e.net)) - _discount;

  Future<void> _addItem() async {
    final app = ref.read(servicesProvider);
    final kind = await chooseLineKind(context);
    if (kind == null || !mounted) return;
    if (kind != SaleLineKind.product) {
      final line = await showCustomLineDialog(context, ref, kind: kind);
      if (line != null && mounted) setState(() => _items = [..._items, line]);
      return;
    }
    final p = await pickFromList<Product>(
      context,
      title: 'Add stock product',
      items: app.catalog.products(),
      label: (x) => x.name,
      subtitle: (x) => '${x.sellingPrice.format()}  •  in stock ${x.stockQty.format()} ${x.unit}',
    );
    if (p == null || !mounted) return;
    if (p.requiresSerial) {
      final keys = await _pickSerials(p, const []);
      if (keys == null || keys.isEmpty || !mounted) return;
      setState(() => _items = [..._items, app.sales.lineFor(p, qty: Qty.units(keys.length), serials: keys)]);
    } else {
      setState(() => _items = [..._items, app.sales.lineFor(p)]);
      await _editLine(_items.length - 1);
    }
  }

  /// Serial numbers for a line: the ones already on it plus units in stock.
  Future<List<String>?> _pickSerials(Product p, List<String> current) async {
    final app = ref.read(servicesProvider);
    final onBill = _items.expand((e) => e.serials).toSet()..removeAll(current);
    final choices = [...current, ...app.serials.inStockFor(p.id).map((r) => r.key).where((k) => !onBill.contains(k) && !current.contains(k))];
    final chosen = {...current};
    return showDialog<List<String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => FormDialog(
          title: '${p.name} - serial numbers',
          width: 560,
          body: choices.isEmpty
              ? const Text('No serial numbers of this product are in stock.')
              : Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final k in choices)
                    FilterChip(
                      key: ValueKey('ei-serial-${SerialRecord.displayOf(k)}'),
                      label: Text(SerialRecord.displayOf(k)),
                      selected: chosen.contains(k),
                      onSelected: (v) => setS(() => v ? chosen.add(k) : chosen.remove(k)),
                    ),
                ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(key: const ValueKey('ei-serial-ok'), onPressed: () => Navigator.pop(ctx, [for (final k in choices) if (chosen.contains(k)) k]), child: Text('Use ${chosen.length}')),
          ],
        ),
      ),
    );
  }

  Future<void> _editLine(int i) async {
    final app = ref.read(servicesProvider);
    final it = _items[i];
    if (!it.isStock) {
      final line = await showCustomLineDialog(context, ref, kind: it.kind, existing: it);
      if (line != null && mounted) setState(() => _items = [..._items]..[i] = line);
      return;
    }
    final p = app.catalog.byId(it.productId);
    if (p != null && p.requiresSerial) {
      final keys = await _pickSerials(p, it.serials);
      if (keys == null || !mounted) return;
      if (keys.isEmpty) {
        setState(() => _items = [..._items]..removeAt(i));
      } else {
        setState(() => _items = [..._items]..[i] = it.copyWith(serials: keys, qty: Qty.units(keys.length)));
      }
    }
    if (!mounted) return;
    final cur = _items.length > i ? _items[i] : null;
    if (cur == null || cur.productId != it.productId) return;
    final qty = TextEditingController(text: cur.qty.format());
    final price = TextEditingController(text: cur.unitPrice.toDecimalString());
    final disc = TextEditingController(text: cur.discount.isZero ? '' : cur.discount.toDecimalString());
    final key = GlobalKey<FormState>();
    final serial = p?.requiresSerial ?? false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => FormDialog(
        title: cur.name,
        width: 460,
        body: Form(
          key: key,
          child: Column(children: [
            FieldRow([
              LabeledField('Quantity${p == null ? '' : ' (${p.unit})'}', qty,
                  key: const ValueKey('ei-qty'), formatters: qtyInput, enabled: !serial, validator: (v) => qtyValidator(v, allowDecimal: p?.allowDecimal ?? false)),
              LabeledField('Unit price', price, key: const ValueKey('ei-price'), formatters: moneyInput, validator: moneyValidator),
            ]),
            FieldRow([LabeledField('Line discount (Rs)', disc, formatters: moneyInput, validator: (v) => moneyValidator(v, required: false))]),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(key: const ValueKey('ei-line-ok'), onPressed: () => key.currentState!.validate() ? Navigator.pop(ctx, true) : null, child: const Text('Update')),
        ],
      ),
    );
    if (ok == true && mounted) {
      setState(() => _items = [..._items]
        ..[i] = cur.copyWith(
          qty: serial ? cur.qty : Qty.parse(qty.text),
          unitPrice: Money.parse(price.text),
          discount: Money.tryParse(disc.text) ?? const Money.zero(),
        ));
    }
    qty.dispose();
    price.dispose();
    disc.dispose();
  }

  Future<void> _save() async {
    final app = ref.read(servicesProvider);
    if (_reason.text.trim().isEmpty) return showToast(context, 'Write why the invoice is being changed.', error: true);
    setState(() => _busy = true);
    try {
      await app.sales.editInvoice(
        widget.sale.id,
        items: _items,
        invoiceDiscount: _discount,
        notes: _notes.text,
        reason: _reason.text,
        receivedNow: Money.tryParse(_received.text) ?? const Money.zero(),
        method: _method,
      );
      if (!mounted) return;
      Navigator.pop(context);
      showToast(context, 'Invoice ${widget.sale.number} updated. Stock, payments and the customer account are adjusted.');
    } catch (e) {
      if (mounted) showToast(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    final app = ref.watch(liveServicesProvider);
    final s = widget.sale;
    final paid = app.sales.paidAgainst(s.id);
    final newTotal = _newTotal;
    final due = newTotal - paid - (Money.tryParse(_received.text) ?? const Money.zero());
    final walkIn = s.customerId == null;
    return FormDialog(
      title: 'Edit invoice ${s.number}',
      width: 860,
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('${s.customerName}  •  ${dateTimeFmt.format(s.date)}  •  invoice number and date stay the same', style: TextStyle(color: c.textMuted)),
        const SizedBox(height: 10),
        for (var i = 0; i < _items.length; i++)
          Container(
            key: ValueKey('ei-line-$i'),
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.border))),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Flexible(child: Text(_items[i].name, style: TextStyle(fontWeight: FontWeight.w600, color: c.text))),
                    const SizedBox(width: 6),
                    LineKindPill(_items[i]),
                  ]),
                  Text(
                    '${_items[i].unitPrice.format()} × ${_items[i].qty.format()} ${_items[i].unit}'
                    '${_items[i].discount.isZero ? '' : '  − ${_items[i].discount.format()}'}'
                    '${_items[i].serials.isEmpty ? '' : '   S/N ${_items[i].serials.map(SerialRecord.displayOf).join(', ')}'}',
                    style: TextStyle(fontSize: 12, color: c.textMuted),
                  ),
                ]),
              ),
              Text(_items[i].net.format(), style: TextStyle(fontWeight: FontWeight.w700, color: c.text)),
              IconButton(key: ValueKey('ei-edit-$i'), tooltip: 'Change', onPressed: () => _editLine(i), icon: const Icon(Icons.edit_outlined, size: 18)),
              IconButton(
                key: ValueKey('ei-remove-$i'),
                tooltip: 'Remove',
                onPressed: () => setState(() => _items = [..._items]..removeAt(i)),
                icon: Icon(Icons.close, size: 18, color: c.danger),
              ),
            ]),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(key: const ValueKey('ei-add-item'), onPressed: _addItem, icon: const Icon(Icons.add, size: 18), label: const Text('Add Item (product, non-stock, service)')),
        ),
        const SizedBox(height: 8),
        FieldRow([
          LabeledField('Invoice discount (Rs)', _disc, key: const ValueKey('ei-discount'), formatters: moneyInput, onChanged: (_) => setState(() {})),
          LabeledField('Notes on invoice', _notes),
        ]),
        FieldRow([
          LabeledField('Reason for the change *', _reason, key: const ValueKey('ei-reason'), hint: 'kept in the edit history'),
          LabeledField('Received now (optional)', _received, key: const ValueKey('ei-received'), formatters: moneyInput, onChanged: (_) => setState(() {})),
        ]),
        if ((Money.tryParse(_received.text) ?? const Money.zero()).isPositive || walkIn)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: SizedBox(
              width: 240,
              child: AppDropdown<PaymentMethod>(
                value: _method,
                decoration: const InputDecoration(labelText: 'Payment / refund method'),
                items: [for (final m0 in PaymentMethod.values) DropdownMenuItem(value: m0, child: Text(m0.label))],
                onChanged: (v) => setState(() => _method = v ?? _method),
              ),
            ),
          ),
        const SizedBox(height: 12),
        Container(
          key: const ValueKey('ei-summary'),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: c.surfaceHigh, borderRadius: BorderRadius.circular(10), border: Border.all(color: c.border)),
          child: Column(children: [
            InfoRow('Old total', s.total.format()),
            InfoRow('New total', newTotal.format(), strong: true),
            InfoRow('Paid against this invoice (kept)', paid.format()),
            if (due.isPositive)
              InfoRow(walkIn ? 'Must be received now (walk-in)' : 'Balance due on invoice', due.format(), color: c.warning)
            else if (due.isNegative)
              InfoRow(walkIn ? 'Paid back to customer (refund)' : 'Paid in excess: kept as customer credit', (-due).format(), color: c.accent)
            else
              InfoRow('Balance due on invoice', 'Nil'),
          ]),
        ),
        const SizedBox(height: 6),
        Text('Payments are never deleted. Stock and serial numbers are adjusted; every change is saved in the invoice edit history.',
            style: TextStyle(color: c.textMuted, fontSize: 12)),
      ]),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton.icon(
          key: const ValueKey('ei-save'),
          onPressed: _busy || _items.isEmpty ? null : _save,
          icon: const Icon(Icons.save_outlined, size: 18),
          label: const Text('Save changes'),
        ),
      ],
    );
  }
}

/// The edit history of an invoice: when, who, why, old and new totals.
class InvoiceEditHistory extends ConsumerWidget {
  final Sale sale;
  const InvoiceEditHistory(this.sale, {super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AppTheme.of(context);
    final app = ref.watch(liveServicesProvider);
    String who(String id) => app.auth.users().where((u) => u.id == id).map((u) => u.displayName).firstOrNull ?? '-';
    String lines(List<SaleItem> items) => items.map((e) => '${e.name} ×${e.qty.format()} @ ${e.unitPrice.format()}').join(', ');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Edit history', style: TextStyle(fontWeight: FontWeight.w700, color: c.text)),
      for (final e in sale.edits.reversed)
        Container(
          margin: const EdgeInsets.only(top: 6),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(border: Border.all(color: c.border), borderRadius: BorderRadius.circular(8)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${dateTimeFmt.format(e.at)}  •  ${who(e.userId)}  •  ${e.beforeTotal.format()} → ${e.afterTotal.format()}',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            if (e.reason.isNotEmpty) Text('Reason: ${e.reason}', style: TextStyle(color: c.textMuted)),
            Text('Before: ${lines(e.beforeItems)}${e.beforeDiscount.isZero ? '' : ' • discount ${e.beforeDiscount.format()}'}', style: TextStyle(fontSize: 12, color: c.textMuted)),
            Text('After: ${lines(e.afterItems)}${e.afterDiscount.isZero ? '' : ' • discount ${e.afterDiscount.format()}'}', style: TextStyle(fontSize: 12, color: c.textMuted)),
          ]),
        ),
    ]);
  }
}
