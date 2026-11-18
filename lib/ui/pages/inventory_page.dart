import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../core/qty.dart';
import '../../domain/models/product.dart';
import '../../domain/models/user.dart';
import '../../domain/services/report_service.dart';
import '../../export/tabular.dart';
import '../print_actions.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/forms.dart';
import 'products_page.dart' show showProductDetails;

class InventoryPage extends ConsumerStatefulWidget {
  const InventoryPage({super.key});
  @override
  ConsumerState<InventoryPage> createState() => _InventoryPageState();
}

enum _StockFilter { all, low, out, issued, damaged }

class _InventoryPageState extends ConsumerState<InventoryPage> {
  String _q = '';
  _StockFilter _f = _StockFilter.all;
  DateTime _from = DateTime.now().subtract(const Duration(days: 30));
  DateTime _to = DateTime.now();
  String? _moveProduct;

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    final app = ref.watch(liveServicesProvider);
    final user = ref.watch(currentUserProvider)!;
    final pendingInspection = app.inspections.list().length;
    return DefaultTabController(
      length: 3,
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          PageHeader(
            title: 'Inventory',
            breadcrumbs: const ['Inventory'],
            subtitle: user.can(Permission.viewFinancials) ? 'Stock value (FIFO cost): ${app.inventory.stockValuation().format()}' : null,
          ),
          TabBar(isScrollable: true, labelColor: c.accent, tabs: [
            const Tab(text: 'Stock'),
            Tab(child: Badge(isLabelVisible: pendingInspection > 0, label: Text('$pendingInspection'), child: const Padding(padding: EdgeInsets.only(right: 10), child: Text('Inspection queue')))),
            const Tab(text: 'Stock movements'),
          ]),
          const SizedBox(height: 14),
          Expanded(
            child: TabBarView(children: [
              _stockTab(context, c, user),
              const _InspectionTab(),
              _movementsTab(context, c),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _stockTab(BuildContext context, AppColors c, AppUser user) {
    final app = ref.watch(liveServicesProvider);
    final fin = user.can(Permission.viewPurchasePrice);
    var rows = app.reports.stock();
    final units = app.serials.statusCountsByProduct();
    final ql = _q.toLowerCase();
    rows = rows.where((r) {
      final p = r.product;
      if (ql.isNotEmpty && !p.name.toLowerCase().contains(ql) && !p.sku.toLowerCase().contains(ql) && !p.brand.toLowerCase().contains(ql)) return false;
      return switch (_f) {
        _StockFilter.all => true,
        _StockFilter.low => p.isLowStock,
        _StockFilter.out => p.isOutOfStock,
        _StockFilter.issued => p.issuedQty.isPositive,
        _StockFilter.damaged => p.damagedQty.isPositive || p.repairableQty.isPositive,
      };
    }).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
        SearchBox(hint: 'Search product…', width: 260, onChanged: (v) => setState(() => _q = v)),
        for (final f in _StockFilter.values)
          ChoiceChip(
            label: Text(switch (f) {
              _StockFilter.all => 'All',
              _StockFilter.low => 'Low stock',
              _StockFilter.out => 'Out of stock',
              _StockFilter.issued => 'With technicians',
              _StockFilter.damaged => 'Damaged / repairable',
            }),
            selected: _f == f,
            onSelected: (_) => setState(() => _f = f),
          ),
        ExportMenu(tables: () => [_table(rows, fin)]),
      ]),
      const SizedBox(height: 12),
      Expanded(
        child: SingleChildScrollView(
          child: AppTable<StockRow>(
            rows: rows,
            pageSize: 30,
            onRowTap: (r) => _productActions(context, r.product),
            empty: const EmptyState(icon: Icons.warehouse_outlined, title: 'Nothing here', message: 'No products match this filter.'),
            columns: [
              AppColumn('Product', flex: 4, minWidth: 170, (r) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(r.product.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                    Text('${r.product.sku} • min ${r.product.minStock.format()}', style: TextStyle(color: c.textMuted, fontSize: 12)),
                  ])),
              AppColumn('Available', numeric: true, minWidth: 100, (r) {
                final p = r.product;
                return StatusPill('${p.stockQty.format()} ${p.unit}', p.isOutOfStock ? c.danger : (p.stockQty <= p.minStock ? c.warning : c.accent));
              }),
              AppColumn('Sold (units)', numeric: true, flex: 1, (r) => Text(_n(units[r.product.id]?[SerialStatus.sold], r.product))),
              AppColumn('Installed', numeric: true, flex: 1, (r) => Text(_n(units[r.product.id]?[SerialStatus.installed], r.product))),
              AppColumn('Issued', numeric: true, flex: 1, (r) => Text(_z(r.product.issuedQty))),
              AppColumn('Inspection', numeric: true, flex: 1, (r) => Text(_z(r.product.inspectionQty))),
              AppColumn('Repairable', numeric: true, flex: 1, (r) => Text(_z(r.product.repairableQty))),
              AppColumn('Damaged', numeric: true, flex: 1, (r) => Text(_z(r.product.damagedQty))),
              if (fin) AppColumn('Cost value', numeric: true, (r) => Text(r.fifoValue.format(showDecimals: false))),
              AppColumn('Sale value', numeric: true, (r) => Text(r.sellingValue.format(showDecimals: false))),
            ],
          ),
        ),
      ),
    ]);
  }

  String _z(Qty q) => q.isZero ? '—' : q.format();

  /// Unit counts exist only for serial-tracked products.
  String _n(int? v, Product p) => !p.requiresSerial ? '—' : '${v ?? 0}';

  ExportTable _table(List<StockRow> rows, bool fin) => ExportTable('Stock', [
        'Product', 'SKU', 'Unit', 'Available', 'Issued', 'Inspection', 'Repairable', 'Damaged', 'Min', if (fin) 'Cost value', 'Sale value'
      ], [
        for (final r in rows)
          [
            r.product.name,
            r.product.sku,
            r.product.unit,
            r.product.stockQty.asDouble,
            r.product.issuedQty.asDouble,
            r.product.inspectionQty.asDouble,
            r.product.repairableQty.asDouble,
            r.product.damagedQty.asDouble,
            r.product.minStock.asDouble,
            if (fin) r.fifoValue.paisa / 100,
            r.sellingValue.paisa / 100,
          ]
      ], footer: [
        ['Total', '', '', '', '', '', '', '', '', if (fin) Money.sum(rows.map((r) => r.fifoValue)).paisa / 100, Money.sum(rows.map((r) => r.sellingValue)).paisa / 100]
      ]);

  Future<void> _productActions(BuildContext context, Product p) async {
    final app = ref.read(servicesProvider);
    final canAdjust = app.ctx.can(Permission.adjustStock);
    await showDialog<void>(
      context: context,
      builder: (ctx) => Consumer(builder: (ctx, ref, _) {
        final c = AppTheme.of(ctx);
        final a = ref.watch(liveServicesProvider);
        final prod = a.catalog.byId(p.id)!;
        final moves = a.inventory.history(p.id).take(40).toList();
        return FormDialog(
          title: prod.name,
          width: 760,
          body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Wrap(spacing: 10, runSpacing: 10, children: [
              for (final b in StockBucket.values) StatusPill('${b.label}: ${prod.bucket(b).format()} ${prod.unit}', b == StockBucket.available ? c.accent : c.textMuted),
            ]),
            const SizedBox(height: 14),
            Text('Recent movements', style: TextStyle(fontWeight: FontWeight.w700, color: c.text)),
            const SizedBox(height: 6),
            for (final m0 in moves)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text('${m0.type} • ${m0.bucket.label}'),
                subtitle: Text('${dateTimeFmt.format(m0.at)} • ${m0.reason}'),
                trailing: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 200),
                  child: Text('${m0.qty.isNegative ? '' : '+'}${m0.qty.format()}  (${m0.before.format()} → ${m0.after.format()})',
                      textAlign: TextAlign.right, style: TextStyle(color: m0.qty.isNegative ? c.danger : c.accent, fontWeight: FontWeight.w600)),
                ),
              ),
            if (moves.isEmpty) Text('No movements yet', style: TextStyle(color: c.textMuted)),
          ]),
          actions: [
            if (prod.requiresSerial)
              OutlinedButton.icon(
                onPressed: () => showProductDetails(ctx, prod.id, initialTab: 1),
                icon: const Icon(Icons.qr_code_2, size: 18),
                label: const Text('Serial numbers'),
              ),
            if (canAdjust && !prod.requiresSerial) OutlinedButton(onPressed: () => _adjust(ctx, prod), child: const Text('Adjust stock')),
            if (canAdjust) OutlinedButton(onPressed: () => _markDamaged(ctx, prod), child: const Text('Mark damaged')),
            if (canAdjust && !prod.requiresSerial && prod.damagedQty.isPositive) OutlinedButton(onPressed: () => _writeOff(ctx, prod), child: const Text('Write off damaged')),
            FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
          ],
        );
      }),
    );
  }

  Future<void> _adjust(BuildContext context, Product p) async {
    final qty = TextEditingController(text: p.stockQty.format());
    final reason = TextEditingController();
    final key = GlobalKey<FormState>();
    await showDialog<void>(
      context: context,
      builder: (ctx) => FormDialog(
        title: 'Stock count • ${p.name}',
        width: 460,
        body: Form(
          key: key,
          child: Column(children: [
            InfoRow('System quantity', '${p.stockQty.format()} ${p.unit}'),
            const SizedBox(height: 10),
            FieldRow([LabeledField('Counted quantity', qty, formatters: qtyInput, autofocus: true, validator: (v) => Qty.tryParse(v ?? '') == null ? 'Enter a number' : null)]),
            FieldRow([LabeledField('Reason (required)', reason, validator: (v) => (v ?? '').trim().isEmpty ? 'Required' : null)]),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              if (!key.currentState!.validate()) return;
              final ok = await runAction(ctx, () => ref.read(servicesProvider).inventory.adjustTo(p.id, Qty.parse(qty.text), reason.text), success: 'Stock adjusted');
              if (ok && ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Save count'),
          ),
        ],
      ),
    );
  }

  Future<void> _markDamaged(BuildContext context, Product p) async {
    final app = ref.read(servicesProvider);
    final qty = TextEditingController(text: '1');
    final reason = TextEditingController();
    final chosen = <String>{};
    final serials = p.requiresSerial ? app.serials.inStockFor(p.id) : const <SerialRecord>[];
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => FormDialog(
          title: 'Mark damaged • ${p.name}',
          width: 520,
          body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (p.requiresSerial)
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final r in serials) FilterChip(label: Text(r.display), selected: chosen.contains(r.key), onSelected: (v) => setS(() => v ? chosen.add(r.key) : chosen.remove(r.key))),
              ])
            else
              TextField(controller: qty, inputFormatters: qtyInput, decoration: InputDecoration(labelText: 'Quantity (${p.unit})')),
            const SizedBox(height: 12),
            TextField(controller: reason, decoration: const InputDecoration(labelText: 'Reason (required)')),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                final q = p.requiresSerial ? Qty.units(chosen.length) : (Qty.tryParse(qty.text) ?? const Qty.zero());
                final ok = await runAction(ctx, () => app.inventory.markDamaged(p.id, q, reason.text, serialKeys: chosen.toList()), success: 'Moved to damaged stock');
                if (ok && ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Mark damaged'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _writeOff(BuildContext context, Product p) async {
    final qty = TextEditingController(text: p.damagedQty.format());
    final reason = await promptText(context, title: 'Write off damaged stock', label: 'Reason (e.g. scrapped)');
    if (reason == null || !context.mounted) return;
    await runAction(context, () => ref.read(servicesProvider).inventory.writeOffDamaged(p.id, Qty.parse(qty.text), reason), success: 'Damaged stock written off');
  }

  Widget _movementsTab(BuildContext context, AppColors c) {
    final app = ref.watch(liveServicesProvider);
    final moves = app.reports.movements(DateRange(_from, _to), productId: _moveProduct);
    final names = {for (final p in app.catalog.products(includeArchived: true)) p.id: p.name};
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
        SizedBox(
          width: 260,
          child: AppDropdown<String?>(
            value: _moveProduct,
            isDense: true,
            decoration: const InputDecoration(labelText: 'Product'),
            items: [const DropdownMenuItem(value: null, child: Text('All products')), for (final e in names.entries) DropdownMenuItem(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis))],
            onChanged: (v) => setState(() => _moveProduct = v),
          ),
        ),
        DateRangeBar(from: _from, to: _to, onChanged: (a, b) => setState(() {
              _from = a;
              _to = b;
            })),
        ExportMenu(tables: () => [ExportTable('Stock Movements', ['Date', 'Product', 'Type', 'Bucket', 'Qty', 'Before', 'After', 'Reason'], [
            for (final m0 in moves) [dateTimeFmt.format(m0.at), names[m0.productId] ?? '', m0.type, m0.bucket.label, m0.qty.asDouble, m0.before.asDouble, m0.after.asDouble, m0.reason]
          ])]),
      ]),
      const SizedBox(height: 12),
      Expanded(
        child: SingleChildScrollView(
          child: AppTable<StockMovement>(
            rows: moves,
            pageSize: 40,
            empty: const EmptyState(icon: Icons.swap_vert, title: 'No movements', message: 'Stock changes in this period appear here.'),
            columns: [
              AppColumn('Date', (m0) => Text(dateTimeFmt.format(m0.at))),
              AppColumn('Product', flex: 3, (m0) => Text(names[m0.productId] ?? '')),
              AppColumn('Type', (m0) => Text(m0.type)),
              AppColumn('Bucket', (m0) => Text(m0.bucket.label)),
              AppColumn('Change', numeric: true, (m0) => Text('${m0.qty.isNegative ? '' : '+'}${m0.qty.format()}', style: TextStyle(color: m0.qty.isNegative ? c.danger : c.accent, fontWeight: FontWeight.w600))),
              AppColumn('Before → After', numeric: true, (m0) => Text('${m0.before.format()} → ${m0.after.format()}')),
              AppColumn('Reason', flex: 3, (m0) => Text(m0.reason, overflow: TextOverflow.ellipsis)),
            ],
          ),
        ),
      ),
    ]);
  }
}

class _InspectionTab extends ConsumerWidget {
  const _InspectionTab();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AppTheme.of(context);
    final app = ref.watch(liveServicesProvider);
    final canDecide = app.ctx.can(Permission.approveInspection);
    final items = app.inspections.list();
    final techs = {for (final t in app.technicians.technicians(includeInactive: true)) t.id: t.name};
    if (items.isEmpty) {
      return const EmptyState(icon: Icons.fact_check_outlined, title: 'Nothing to inspect', message: 'Used, damaged or faulty returns wait here until the owner decides.');
    }
    return ListView(children: [
      if (!canDecide)
        Padding(padding: const EdgeInsets.only(bottom: 12), child: Text('Only the owner can approve inspected items.', style: TextStyle(color: c.warning))),
      for (final it in items)
        AppCard(
          padding: const EdgeInsets.all(16),
          child: LayoutBuilder(builder: (context, cons) {
          final info = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Wrap(spacing: 10, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Text('${it.productName}  ×  ${it.qty.format()}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                  StatusPill(it.status == InspectionStatus.repairable ? 'Repairable' : 'Awaiting inspection', it.status == InspectionStatus.repairable ? c.warning : const Color(0xFF6FB8FF)),
                ]),
                const SizedBox(height: 4),
                Text(
                    [
                      'Reported: ${it.reportedCondition}',
                      if (it.reason.isNotEmpty) it.reason,
                      it.sourceType == 'tech_return' ? 'from technician ${techs[it.technicianId] ?? ''}' : 'customer return',
                      dateTimeFmt.format(it.createdAt),
                      if (it.serials.isNotEmpty) 'S/N ${it.serials.map(SerialRecord.displayOf).join(', ')}',
                    ].join(' • '),
                    style: TextStyle(color: c.textMuted, fontSize: 12.5)),
              ]);
          final buttons = Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton(onPressed: () => _decide(context, ref, it, InspectionDecision.sellable), child: const Text('Sellable')),
              if (it.status == InspectionStatus.pending)
                OutlinedButton(onPressed: () => _decide(context, ref, it, InspectionDecision.repairable), child: const Text('Repairable')),
              OutlinedButton(
                style: OutlinedButton.styleFrom(foregroundColor: c.danger),
                onPressed: () => _decide(context, ref, it, InspectionDecision.damaged),
                child: const Text('Damaged'),
              ),
          ]);
          if (!canDecide) return info;
          if (cons.maxWidth < 760) return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [info, const SizedBox(height: 12), buttons]);
          return Row(children: [Expanded(child: info), const SizedBox(width: 12), buttons]);
          }),
        ),
    ].expand((w) => [w, const SizedBox(height: 10)]).toList());
  }

  Future<void> _decide(BuildContext context, WidgetRef ref, InspectionItem it, InspectionDecision d) async {
    final app = ref.read(servicesProvider);
    final p = app.catalog.byId(it.productId);
    final qty = TextEditingController(text: it.qty.format());
    final note = TextEditingController();
    final chosen = {...it.serials};
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => FormDialog(
          title: 'Mark as ${d.name} • ${it.productName}',
          width: 480,
          body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (it.serials.isNotEmpty)
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final k in it.serials) FilterChip(label: Text(SerialRecord.displayOf(k)), selected: chosen.contains(k), onSelected: (v) => setS(() => v ? chosen.add(k) : chosen.remove(k))),
              ])
            else
              TextField(controller: qty, inputFormatters: qtyInput, decoration: InputDecoration(labelText: 'Quantity (${p?.unit ?? ''}) - part of the item is OK')),
            const SizedBox(height: 12),
            TextField(controller: note, decoration: const InputDecoration(labelText: 'Inspection note')),
            const SizedBox(height: 10),
            Text(switch (d) {
              InspectionDecision.sellable => 'Goes back to sellable stock at its original cost.',
              InspectionDecision.repairable => 'Kept as repairable (not sellable). Decide again after repair.',
              InspectionDecision.damaged => 'Moves to damaged stock (can be returned to supplier or written off).',
            }),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                final ok = await runAction(
                    ctx,
                    () => app.inspections.decide(it.id, d,
                        qty: it.serials.isEmpty ? Qty.tryParse(qty.text) : null, serialKeys: it.serials.isEmpty ? null : chosen.toList(), note: note.text),
                    success: 'Inspection decision saved');
                if (ok && ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Confirm'),
            ),
          ],
        ),
      ),
    );
  }
}
