import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/errors.dart';
import '../core/money.dart';
import '../core/qty.dart';
import '../domain/models/documents.dart';
import 'providers.dart';
import 'theme.dart';
import 'widgets/common.dart';
import 'widgets/forms.dart';

/// "+ Add Item": stock product, non-stock item or service / labour.
/// [allowService] false hides labour (e.g. when editing a shop invoice).
Future<SaleLineKind?> chooseLineKind(BuildContext context, {bool allowService = true}) => showDialog<SaleLineKind>(
      context: context,
      builder: (ctx) {
        final c = AppTheme.of(ctx);
        Widget option(SaleLineKind k, IconData icon, String help) => Card(
              margin: const EdgeInsets.only(bottom: 10),
              child: ListTile(
                key: ValueKey('add-kind-${k.name}'),
                leading: Icon(icon, color: c.accent),
                title: Text(k.label, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(help),
                onTap: () => Navigator.pop(ctx, k),
              ),
            );
        return FormDialog(
          title: 'Add Item',
          width: 480,
          body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            option(SaleLineKind.product, Icons.inventory_2_outlined, 'A product from stock (stock is reduced)'),
            option(SaleLineKind.nonStock, Icons.category_outlined, 'Clips, screws, small accessories - no stock, no product record'),
            if (allowService)
              option(SaleLineKind.service, Icons.handyman_outlined, "Installation / labour (karegar's charges): on the customer's bill and payable, but the worker's money - not shop sales or profit"),
          ]),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel'))],
        );
      },
    );

/// Small label shown next to non-stock and service lines.
class LineKindPill extends StatelessWidget {
  final SaleItem item;
  const LineKindPill(this.item, {super.key});
  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    return switch (item.kind) {
      SaleLineKind.product => const SizedBox.shrink(),
      SaleLineKind.nonStock => StatusPill('Non-stock', c.textMuted),
      SaleLineKind.service => StatusPill(item.worker.isEmpty ? 'Labour' : 'Labour: ${item.worker}', c.warning),
    };
  }
}

/// Adds or edits a non-stock item or a service line: description,
/// quantity, unit, rate, discount; the total is worked out as you type.
/// Saved presets of the same kind can be picked, and the line can be saved
/// as a new preset.
Future<SaleItem?> showCustomLineDialog(BuildContext context, WidgetRef ref, {required SaleLineKind kind, SaleItem? existing}) async {
  return showDialog<SaleItem>(context: context, builder: (_) => _CustomLineDialog(kind: existing?.kind ?? kind, existing: existing));
}

class _CustomLineDialog extends ConsumerStatefulWidget {
  final SaleLineKind kind;
  final SaleItem? existing;
  const _CustomLineDialog({required this.kind, this.existing});
  @override
  ConsumerState<_CustomLineDialog> createState() => _CustomLineDialogState();
}

class _CustomLineDialogState extends ConsumerState<_CustomLineDialog> {
  final _form = GlobalKey<FormState>();
  late final _desc = TextEditingController(text: widget.existing?.name ?? '');
  late final _qty = TextEditingController(text: widget.existing?.qty.format() ?? '1');
  late final _unit = TextEditingController(text: widget.existing?.unit ?? (widget.kind == SaleLineKind.service ? 'job' : 'pcs'));
  late final _rate = TextEditingController(text: widget.existing?.unitPrice.toDecimalString() ?? '');
  late final _worker = TextEditingController(text: widget.existing?.worker ?? '');
  late final _disc = TextEditingController(text: widget.existing == null || widget.existing!.discount.isZero ? '' : widget.existing!.discount.toDecimalString());
  bool _savePreset = false;

  @override
  void dispose() {
    for (final t in [_desc, _qty, _unit, _rate, _disc, _worker]) {
      t.dispose();
    }
    super.dispose();
  }

  Money get _total {
    final q = Qty.tryParse(_qty.text) ?? const Qty.zero();
    final r = Money.tryParse(_rate.text) ?? const Money.zero();
    final d = Money.tryParse(_disc.text) ?? const Money.zero();
    return r.timesQty(q) - d;
  }

  Future<void> _ok() async {
    if (!_form.currentState!.validate()) return;
    final item = SaleItem.custom(
      kind: widget.kind,
      name: _desc.text.trim(),
      qty: Qty.parse(_qty.text),
      unitPrice: Money.parse(_rate.text),
      discount: Money.tryParse(_disc.text) ?? const Money.zero(),
      unit: _unit.text.trim(),
      worker: widget.kind == SaleLineKind.service ? _worker.text.trim() : '',
    );
    if (item.net.isNegative) return showToast(context, 'The discount is larger than the line amount.', error: true);
    if (_savePreset) {
      try {
        await ref.read(servicesProvider).sales.savePreset(BillingPreset(kind: item.kind, name: item.name, unitPrice: item.unitPrice, unit: item.unit));
      } catch (e) {
        if (mounted) showToast(context, friendlyError(e), error: true);
        return;
      }
    }
    if (mounted) Navigator.pop(context, item);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    final app = ref.watch(liveServicesProvider);
    final presets = app.sales.presets().where((p) => p.kind == widget.kind).toList();
    final service = widget.kind == SaleLineKind.service;
    return FormDialog(
      title: '${widget.existing == null ? 'Add' : 'Edit'} ${widget.kind.label.toLowerCase()}',
      width: 560,
      body: Form(
        key: _form,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (presets.isNotEmpty) ...[
            Text('Saved items', style: TextStyle(color: c.textMuted, fontSize: 12)),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final p in presets)
                InputChip(
                  key: ValueKey('cl-preset-${p.name}'),
                  label: Text('${p.name}  •  ${p.unitPrice.format()}${p.unit.isEmpty ? '' : '/${p.unit}'}'),
                  onPressed: () => setState(() {
                    _desc.text = p.name;
                    _rate.text = p.unitPrice.toDecimalString();
                    if (p.unit.isNotEmpty) _unit.text = p.unit;
                  }),
                  onDeleted: () async {
                    await app.sales.deletePreset(p.kind, p.name);
                    if (mounted) setState(() {});
                  },
                  deleteButtonTooltipMessage: 'Remove saved item',
                ),
            ]),
            const SizedBox(height: 12),
          ],
          LabeledField(service ? 'Service description *' : 'Item description *', _desc,
              key: const ValueKey('cl-desc'),
              autofocus: widget.existing == null,
              hint: service ? 'e.g. CCTV Installation, Labour charges' : 'e.g. Cable clips, Screws',
              validator: (v) => (v ?? '').trim().isEmpty ? 'Required' : null),
          FieldRow([
            LabeledField('Quantity *', _qty,
                key: const ValueKey('cl-qty'), formatters: qtyInput, validator: (v) => qtyValidator(v), onChanged: (_) => setState(() {})),
            LabeledField('Unit', _unit, key: const ValueKey('cl-unit'), hint: service ? 'job, day, hour' : 'pcs, box'),
            LabeledField(service ? 'Rate *' : 'Unit price *', _rate,
                key: const ValueKey('cl-rate'), formatters: moneyInput, validator: moneyValidator, onChanged: (_) => setState(() {})),
          ]),
          FieldRow([
            if (service) LabeledField('Karegar / worker', _worker, key: const ValueKey('cl-worker')),
            LabeledField('Discount (Rs)', _disc,
                key: const ValueKey('cl-disc'), formatters: moneyInput, validator: (v) => moneyValidator(v, required: false), onChanged: (_) => setState(() {})),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: CheckboxListTile(
                key: const ValueKey('cl-save-preset'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _savePreset,
                onChanged: (v) => setState(() => _savePreset = v ?? false),
                title: const Text('Save for quick billing next time'),
              ),
            ),
            Text('Total  ', style: TextStyle(color: c.textMuted)),
            Text(_total.format(), key: const ValueKey('cl-total'), style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: c.text)),
          ]),
          Text(
              service
                  ? "Labour is shown on the customer's invoice and is part of what they pay, but it is the worker's (karegar's) money: not shop sales, income or profit."
                  : 'Non-stock items are billed on the invoice without a product record, do not reduce stock and are not counted in shop profit.',
              style: TextStyle(color: c.textMuted, fontSize: 12)),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('cl-ok'), onPressed: _ok, child: Text(widget.existing == null ? 'Add to bill' : 'Update')),
      ],
    );
  }
}
