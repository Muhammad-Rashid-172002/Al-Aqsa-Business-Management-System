// "Add More Serial Numbers": restock an EXISTING serial-tracked product with
// new units (e.g. after it sold out) without creating the product again.
//
// Product name, company and model are shown read-only. The user enters the
// quantity and scans, types or pastes only the new serials. As a purchase,
// it records supplier, invoice, date and cost as its own batch; otherwise
// (opening / found stock) it records a stock-in batch at the given cost.
// Old serials keep their statuses; stock rises by the serials added.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors.dart';
import '../../core/money.dart';
import '../../core/qty.dart';
import '../../domain/models/party.dart';
import '../../domain/models/product.dart';
import '../../domain/models/user.dart';
import '../../domain/services/purchase_service.dart';
import '../../domain/services/serial_service.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/forms.dart';
import '../widgets/serial_entry.dart';
import 'parties_page.dart' show showPartyForm;

Future<void> showAddSerials(BuildContext context, Product product) => showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _AddSerials(productId: product.id),
    );

enum _Source { purchase, other }

class _AddSerials extends ConsumerStatefulWidget {
  final String productId;
  const _AddSerials({required this.productId});
  @override
  ConsumerState<_AddSerials> createState() => _AddSerialsState();
}

class _AddSerialsState extends ConsumerState<_AddSerials> {
  final _qty = TextEditingController();
  final _cost = TextEditingController();
  final _invoice = TextEditingController();
  final _paid = TextEditingController();
  final _reason = TextEditingController(text: 'Opening stock');
  _Source _source = _Source.purchase;
  String? _supplierId;
  DateTime _date = DateTime.now();
  List<String> _serials = const [];
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final p = ref.read(servicesProvider).catalog.byId(widget.productId);
    if (p != null && p.purchasePrice.isPositive) _cost.text = (p.purchasePrice.paisa / 100).toStringAsFixed(p.purchasePrice.paisa % 100 == 0 ? 0 : 2);
    final app = ref.read(servicesProvider);
    if (!app.ctx.can(Permission.managePurchases)) _source = _Source.other;
    _cost.addListener(_costChanged); // keeps the "Batch value" line current
  }

  void _costChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _cost.removeListener(_costChanged);
    for (final c in [_qty, _cost, _invoice, _paid, _reason]) {
      c.dispose();
    }
    super.dispose();
  }

  int get _units => int.tryParse(_qty.text.trim()) ?? 0;

  Future<void> _enterSerials(Product p) async {
    final r = await showSerialEntry(context, app: ref.read(servicesProvider), productName: p.name, brandKey: p.brandKey, productId: p.id, quantity: _units, initial: _serials);
    if (r == null || !mounted) return;
    setState(() {
      _serials = r.serials;
      _qty.text = '${r.quantity}';
    });
  }

  Future<bool> _approve(SerialConflictException e) async {
    final app = ref.read(servicesProvider);
    if (!app.ctx.can(Permission.resolveSerialConflicts)) {
      showToast(context, '${e.message} Only the owner can approve a genuine duplicate.', error: true);
      return false;
    }
    return confirmDialog(
      context,
      title: 'Serial numbers already exist',
      message: '${e.conflicts.map((c0) => '${c0.serial}: ${c0.kind == SerialConflictKind.sameBrand ? 'already registered for this brand (${c0.existing.status.label})' : 'exists under brand ${c0.existing.brandKey}'}').join('\n')}\n\n'
          'Approve only if these are genuinely different physical units.',
      confirm: 'Approve and save',
      danger: true,
    );
  }

  Future<void> _save(Product p) async {
    final app = ref.read(servicesProvider);
    final cost = Money.tryParse(_cost.text);
    String? problem;
    if (_units <= 0) {
      problem = 'Enter the quantity of new units.';
    } else if (_serials.length != _units) {
      problem = 'Enter one serial number per unit: ${_serials.length} of $_units entered.';
    } else if (cost == null || cost.isNegative) {
      problem = 'Enter the cost per unit.';
    } else if (_source == _Source.purchase && _supplierId == null) {
      problem = 'Select the supplier.';
    } else if (_source == _Source.other && _reason.text.trim().isEmpty) {
      problem = 'Give a reason (e.g. opening stock).';
    }
    if (problem != null) return showToast(context, problem, error: true);
    setState(() => _saving = true);
    final before = p.stockQty;
    var approved = <String>{};
    try {
      while (true) {
        try {
          if (_source == _Source.purchase) {
            await app.purchases.create(
              supplierId: _supplierId!,
              supplierInvoiceNo: _invoice.text.trim(),
              date: _date,
              paid: Money.tryParse(_paid.text) ?? const Money.zero(),
              lines: [PurchaseLineInput(productId: p.id, qty: Qty.units(_serials.length), unitCost: cost!, serials: _serials)],
              approvedSerialConflicts: approved,
            );
          } else {
            await app.purchases.addSerialStock(productId: p.id, serials: _serials, unitCost: cost!, date: _date, reason: _reason.text.trim(), approvedSerialConflicts: approved);
          }
          break;
        } on SerialConflictException catch (e) {
          if (!mounted || !await _approve(e)) return;
          approved = {...approved, ...e.conflicts.map((c0) => c0.serial)};
        }
      }
      if (!mounted) return;
      final after = app.catalog.byId(p.id)?.stockQty ?? before;
      showToast(context, 'Added ${_serials.length} serial number(s) to "${p.name}". Stock: ${before.format()} → ${after.format()} ${p.unit}');
      Navigator.pop(context);
    } catch (e) {
      if (mounted) showToast(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Read-only field: existing product details are shown, never re-entered.
  Widget _ro(String label, String value, {Key? key}) => InputDecorator(
        key: key,
        decoration: InputDecoration(labelText: label, enabled: false, suffixIcon: const Icon(Icons.lock_outline, size: 16)),
        child: Text(value.isEmpty ? '—' : value),
      );

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    final app = ref.watch(liveServicesProvider);
    final p = app.catalog.byId(widget.productId);
    if (p == null) return const RecordGone('product');
    final counts = app.serials.statusCounts(p.id);
    final suppliers = app.parties.list(PartyKind.supplier);
    final units = _units;
    final entered = _serials.length;
    final remaining = (units - entered).clamp(0, 1 << 30);
    final done = units > 0 && entered == units;
    final canPurchase = app.ctx.can(Permission.managePurchases);
    final canOther = app.ctx.can(Permission.adjustStock);

    return FormDialog(
      title: 'Add More Serial Numbers',
      width: 640,
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('New units are added to this existing product. Its details and all earlier serial numbers stay as they are.', style: TextStyle(color: c.textMuted, fontSize: 12)),
        const SizedBox(height: 12),
        FieldRow([_ro('Product', p.name, key: const ValueKey('as-name')), _ro('Company / brand', p.brand, key: const ValueKey('as-brand'))]),
        FieldRow([_ro('Model', p.model, key: const ValueKey('as-model')), _ro('Product code', p.internalCode)]),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 6, children: [
          StatusPill('In stock now: ${p.stockQty.format()} ${p.unit}', p.stockQty.isPositive ? c.accent : c.danger),
          for (final e in counts.entries) StatusPill('${e.key.label}: ${e.value}', c.textMuted),
        ]),
        const SizedBox(height: 16),
        if (canPurchase && canOther)
          SegmentedButton<_Source>(
            key: const ValueKey('as-source'),
            segments: const [
              ButtonSegment(value: _Source.purchase, icon: Icon(Icons.local_shipping_outlined, size: 18), label: Text('Purchase from supplier')),
              ButtonSegment(value: _Source.other, icon: Icon(Icons.inventory_2_outlined, size: 18), label: Text('Opening / other stock')),
            ],
            selected: {_source},
            onSelectionChanged: (s) => setState(() => _source = s.first),
          ),
        const SizedBox(height: 14),
        Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SizedBox(
            width: 170,
            child: TextField(
              key: const ValueKey('as-qty'),
              controller: _qty,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: 'New quantity (units)'),
              onChanged: (_) => setState(() {}),
            ),
          ),
          FilledButton.icon(
            key: const ValueKey('as-serials'),
            onPressed: units <= 0 ? null : () => _enterSerials(p),
            icon: Icon(done ? Icons.check_circle : Icons.qr_code_scanner, size: 18),
            label: Text(entered == 0 ? 'Scan / enter $units serial number${units == 1 ? '' : 's'}' : 'Edit serial numbers'),
          ),
          Text('Required $units • Entered $entered • Remaining $remaining',
              key: const ValueKey('as-progress'), style: TextStyle(color: done ? c.accent : c.warning, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 14),
        if (_source == _Source.purchase) ...[
          Row(children: [
            Expanded(
              child: AppDropdown<String?>(
                key: const ValueKey('as-supplier'),
                value: _supplierId,
                decoration: const InputDecoration(labelText: 'Supplier *'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('Select supplier')),
                  for (final s0 in suppliers) DropdownMenuItem(value: s0.id, child: Text(s0.name)),
                ],
                onChanged: (v) => setState(() => _supplierId = v),
              ),
            ),
            IconButton(
              tooltip: 'New supplier',
              icon: const Icon(Icons.person_add_alt),
              onPressed: () async {
                final s0 = await showPartyForm(context, ref, PartyKind.supplier);
                if (s0 != null && mounted) setState(() => _supplierId = s0.id);
              },
            ),
          ]),
          const SizedBox(height: 12),
          FieldRow([
            LabeledField('Supplier invoice no.', _invoice),
            LabeledField('Cost per unit (Rs) *', _cost, formatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))]),
          ]),
          FieldRow([LabeledField('Paid now (Rs)', _paid, formatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))]), _dateField()]),
        ] else ...[
          FieldRow([LabeledField('Cost per unit (Rs) *', _cost, formatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))]), _dateField()]),
          FieldRow([LabeledField('Reason *', _reason)]),
        ],
        if (units > 0 && (Money.tryParse(_cost.text) ?? const Money.zero()).isPositive)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('Batch value: ${(Money.tryParse(_cost.text)!).timesQty(Qty.units(units)).format()} • kept as its own cost batch for profit',
                style: TextStyle(color: c.textMuted, fontSize: 12)),
          ),
      ]),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton.icon(
          key: const ValueKey('as-save'),
          onPressed: _saving || !done ? null : () => _save(p),
          icon: _saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save_outlined, size: 18),
          label: Text('Add $entered serial number${entered == 1 ? '' : 's'}'),
        ),
      ],
    );
  }

  Widget _dateField() => InkWell(
        key: const ValueKey('as-date'),
        onTap: () async {
          final d = await showDatePicker(context: context, firstDate: DateTime(2020), lastDate: DateTime.now().add(const Duration(days: 1)), initialDate: _date);
          if (d != null && mounted) setState(() => _date = d);
        },
        child: InputDecorator(
          decoration: const InputDecoration(labelText: 'Date', suffixIcon: Icon(Icons.calendar_today, size: 18)),
          child: Text(dateFmt.format(_date)),
        ),
      );
}
