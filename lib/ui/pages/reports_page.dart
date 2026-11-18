import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/party.dart';
import '../../domain/models/user.dart';
import '../../domain/services/report_service.dart';
import '../../domain/services/report_tables.dart';
import '../../export/tabular.dart';
import '../print_actions.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/forms.dart';

class ReportsPage extends ConsumerStatefulWidget {
  const ReportsPage({super.key});
  @override
  ConsumerState<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends ConsumerState<ReportsPage> {
  ReportKind _kind = ReportKind.profitLoss;
  DateTime _from = DateTime(DateTime.now().year, DateTime.now().month);
  DateTime _to = DateTime.now();
  ReportFilter _f = ReportFilter.none;
  final _serial = TextEditingController();
  int _sheet = 0;

  @override
  void dispose() {
    _serial.dispose();
    super.dispose();
  }

  ReportFilter _with({
    Object? productId = _keep,
    Object? categoryId = _keep,
    Object? supplierId = _keep,
    Object? customerId = _keep,
    Object? payment = _keep,
    Object? serial = _keep,
    Object? technicianId = _keep,
    Object? txnType = _keep,
  }) =>
      ReportFilter(
        productId: productId == _keep ? _f.productId : productId as String?,
        categoryId: categoryId == _keep ? _f.categoryId : categoryId as String?,
        supplierId: supplierId == _keep ? _f.supplierId : supplierId as String?,
        customerId: customerId == _keep ? _f.customerId : customerId as String?,
        payment: payment == _keep ? _f.payment : payment as PayStatus?,
        serial: serial == _keep ? _f.serial : serial as String?,
        technicianId: technicianId == _keep ? _f.technicianId : technicianId as String?,
        txnType: txnType == _keep ? _f.txnType : txnType as String?,
      );

  Widget _filters(BuildContext context, ReportBuilder b) {
    final app = b.app;
    final fs = _kind.filters;
    if (fs.isEmpty) return const SizedBox.shrink();
    Widget dd<T>(String key, String label, T? value, List<(T, String)> items, void Function(T?) on, {double width = 210}) => SizedBox(
          width: width,
          child: AppDropdown<T?>(
            key: ValueKey('rf-$key'),
            value: items.any((i) => i.$1 == value) ? value : null,
            decoration: InputDecoration(labelText: label, isDense: true),
            items: [
              DropdownMenuItem<T?>(value: null, child: Text('All', style: TextStyle(color: AppTheme.of(context).textMuted))),
              for (final i in items) DropdownMenuItem<T?>(value: i.$1, child: Text(i.$2, maxLines: 1, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) => setState(() {
              on(v);
              _sheet = 0;
            }),
          ),
        );
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
        if (fs.contains(ReportFilterField.product))
          dd<String>('product', 'Product', _f.productId, [for (final p in app.catalog.products(includeArchived: true)) (p.id, p.name)], (v) => _f = _with(productId: v), width: 240),
        if (fs.contains(ReportFilterField.category))
          dd<String>('category', 'Category', _f.categoryId, [for (final c0 in app.catalog.categories()) (c0.id, c0.name)], (v) => _f = _with(categoryId: v)),
        if (fs.contains(ReportFilterField.supplier))
          dd<String>('supplier', 'Supplier', _f.supplierId, [for (final p in app.parties.list(PartyKind.supplier, includeInactive: true)) (p.id, p.name)], (v) => _f = _with(supplierId: v)),
        if (fs.contains(ReportFilterField.customer))
          dd<String>('customer', 'Customer', _f.customerId, [for (final p in app.parties.list(PartyKind.customer, includeInactive: true)) (p.id, p.name)], (v) => _f = _with(customerId: v)),
        if (fs.contains(ReportFilterField.paymentStatus))
          dd<PayStatus>('payment', 'Payment status', _f.payment, [for (final s0 in PayStatus.values) (s0, s0.label)], (v) => _f = _with(payment: v), width: 170),
        if (fs.contains(ReportFilterField.technician))
          dd<String>('technician', 'Technician', _f.technicianId, [for (final t0 in app.technicians.technicians(includeInactive: true)) (t0.id, t0.name)], (v) => _f = _with(technicianId: v)),
        if (fs.contains(ReportFilterField.txnType))
          dd<String>('type', _kind.txnTypeLabel, _f.txnType, b.txnTypeOptions(_kind), (v) => _f = _with(txnType: v)),
        if (fs.contains(ReportFilterField.serial))
          SizedBox(
            width: 190,
            child: TextField(
              key: const ValueKey('rf-serial'),
              controller: _serial,
              decoration: InputDecoration(
                labelText: 'Serial number',
                isDense: true,
                suffixIcon: _serial.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 16),
                        onPressed: () => setState(() {
                          _serial.clear();
                          _f = _with(serial: null);
                        })),
              ),
              onSubmitted: (v) => setState(() => _f = _with(serial: v.trim().isEmpty ? null : v.trim())),
              onChanged: (v) => setState(() => _f = _with(serial: v.trim().isEmpty ? null : v.trim())),
            ),
          ),
        if (!_f.only(fs).isEmpty)
          TextButton.icon(
            onPressed: () => setState(() {
              _f = ReportFilter.none;
              _serial.clear();
            }),
            icon: const Icon(Icons.filter_alt_off_outlined, size: 18),
            label: const Text('Clear filters'),
          ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    final app = ref.watch(liveServicesProvider);
    final fin = app.ctx.can(Permission.viewFinancials);
    final kinds = ReportKind.values.where((k) => fin || !k.isFinancial).toList();
    if (!kinds.contains(_kind)) _kind = kinds.first;
    final groups = <String, List<ReportKind>>{};
    for (final k in kinds) {
      groups.putIfAbsent(k.group, () => []).add(k);
    }
    final range = DateRange(DateTime(_from.year, _from.month, _from.day), DateTime(_to.year, _to.month, _to.day, 23, 59, 59));
    final b = ReportBuilder(app);
    final List<ExportTable> sheets;
    try {
      sheets = b.workbook(_kind, range, _f);
    } catch (e) {
      return Center(child: Text('Could not build report: $e'));
    }
    final sheet = _sheet < sheets.length ? _sheet : 0;
    final table = sheets[sheet];
    final period = table.info.join('   •   ');
    final name = '${_kind.title} ${dateFmt.format(_from).replaceAll('/', '-')}';
    void act(ExportAction a) => runExport(context, app.ctx.settings, sheets, a, name: name, landscape: _kind.landscape);
    return LayoutBuilder(builder: (context, outer) {
      // Report list: 260 px on wide windows, down to 200 px on small ones.
      final listWidth = (outer.maxWidth * 0.24).clamp(200.0, 260.0);
      return Padding(
        padding: EdgeInsets.all(outer.maxWidth < 1000 ? 18 : 28),
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(
            width: listWidth,
            child: AppCard(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: ListView(children: [
                for (final g in groups.entries) ...[
                  Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 4), child: Text(g.key.toUpperCase(), style: TextStyle(color: c.textMuted, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.8))),
                  for (final k in g.value)
                    ListTile(
                      dense: true,
                      selected: k == _kind,
                      selectedTileColor: c.primary.withValues(alpha: 0.18),
                      title: Text(k.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                      onTap: () => setState(() {
                        _kind = k;
                        _sheet = 0;
                      }),
                    ),
                ],
              ]),
            ),
          ),
          SizedBox(width: outer.maxWidth < 1000 ? 14 : 20),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              PageHeader(title: _kind.title, subtitle: period, breadcrumbs: ['Reports', _kind.group], actions: [
                FilledButton.icon(key: const ValueKey('report-excel'), onPressed: () => act(ExportAction.excel), icon: const Icon(Icons.table_view_outlined, size: 18), label: const Text('Excel')),
                OutlinedButton.icon(key: const ValueKey('report-pdf'), onPressed: () => act(ExportAction.pdf), icon: const Icon(Icons.picture_as_pdf_outlined, size: 18), label: const Text('PDF')),
                OutlinedButton.icon(key: const ValueKey('report-print'), onPressed: () => act(ExportAction.print), icon: const Icon(Icons.print_outlined, size: 18), label: const Text('Print')),
                OutlinedButton.icon(key: const ValueKey('report-preview'), onPressed: () => act(ExportAction.preview), icon: const Icon(Icons.preview_outlined, size: 18), label: const Text('Preview')),
                IconButton(tooltip: 'Export CSV', onPressed: () => act(ExportAction.csv), icon: const Icon(Icons.text_snippet_outlined)),
              ]),
              if (!_kind.isSnapshot)
                DateRangeBar(from: _from, to: _to, onChanged: (a, b0) => setState(() {
                      _from = a;
                      _to = b0;
                    })),
              _filters(context, b),
              const SizedBox(height: 14),
              if (_kind == ReportKind.profit) _ProfitCards(range: range),
              if (sheets.length > 1)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Wrap(spacing: 8, children: [
                    for (var i = 0; i < sheets.length; i++)
                      ChoiceChip(label: Text(i == 0 ? _kind.title : sheets[i].title), selected: i == sheet, onSelected: (_) => setState(() => _sheet = i)),
                  ]),
                ),
              Expanded(
                child: SingleChildScrollView(
                  child: AppTable<List<Object?>>(
                    rows: [...table.rows, ...table.footer],
                    pageSize: 50,
                    empty: const EmptyState(icon: Icons.insights_outlined, title: 'No records for this report', message: 'Try another date range or clear the filters.'),
                    columns: [
                      for (var i = 0; i < table.headers.length; i++)
                        AppColumn(
                          table.headers[i],
                          flex: i == 0 ? 3 : 2,
                          minWidth: i == 0 ? 150 : 96,
                          numeric: table.rows.isNotEmpty && table.rows.first.length > i && table.rows.first[i] is num,
                          (r) {
                            final v = i < r.length ? r[i] : null;
                            final isFooter = identical(r, table.footer.firstOrNull) || table.footer.any((f0) => identical(f0, r));
                            return Text(v is double ? _fmt(v) : exportCellText(v),
                                style: TextStyle(fontWeight: isFooter ? FontWeight.w800 : FontWeight.w400, color: v is num && v < 0 ? c.danger : null), overflow: TextOverflow.ellipsis);
                          },
                        ),
                    ],
                  ),
                ),
              ),
            ]),
          ),
        ]),
      );
    });
  }

  String _fmt(double v) {
    final s = v.toStringAsFixed(2);
    final parts = s.split('.');
    final neg = parts[0].startsWith('-');
    final w = neg ? parts[0].substring(1) : parts[0];
    final b = StringBuffer();
    for (var i = 0; i < w.length; i++) {
      if (i > 0 && (w.length - i) % 3 == 0) b.write(',');
      b.write(w[i]);
    }
    return '${neg ? '-' : ''}$b.${parts[1]}';
  }
}

const _keep = Object();

class _ProfitCards extends ConsumerWidget {
  final DateRange range;
  const _ProfitCards({required this.range});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AppTheme.of(context);
    final p = ref.watch(liveServicesProvider).reports.profit(range);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: ResponsiveGrid(minItemWidth: 200, spacing: 12, children: [
        for (final e in [
          ('Net Sales', AnimatedMoney(p.netSales), c.accent),
          ('Cost of Goods Sold', AnimatedMoney(p.cogs), c.warning),
          ('Gross Profit (before expenses)', AnimatedMoney(p.grossProfit), p.grossProfit.isNegative ? c.danger : c.accent),
        ])
          StatCard(label: e.$1, icon: Icons.insights, value: e.$2, tone: e.$3),
      ]),
    );
  }
}
