import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/money.dart';
import '../../domain/models/json_utils.dart';
import '../../domain/services/report_service.dart';
import '../../domain/services/report_tables.dart';
import '../print_actions.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/charts.dart';
import '../widgets/common.dart';
import '../widgets/forms.dart';

/// Monthly profit & loss: sales, gross profit, expenses, net operating
/// profit and cash received, by month / year / custom range.
class FinancePage extends ConsumerStatefulWidget {
  const FinancePage({super.key});
  @override
  ConsumerState<FinancePage> createState() => _FinancePageState();
}

enum _Mode { month, year, custom }

class _FinancePageState extends ConsumerState<FinancePage> {
  _Mode _mode = _Mode.month;
  int _year = DateTime.now().year;
  int _month = DateTime.now().month;
  DateTime _from = DateTime(DateTime.now().year, DateTime.now().month);
  DateTime _to = DateTime.now();

  DateRange get _range => switch (_mode) {
        _Mode.month => DateRange(DateTime(_year, _month), dayEnd(DateTime(_year, _month + 1, 0))),
        _Mode.year => DateRange(DateTime(_year), dayEnd(DateTime(_year, 12, 31))),
        _Mode.custom => DateRange(dayStart(_from), dayEnd(_to)),
      };

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    final app = ref.watch(liveServicesProvider);
    final r = _range;
    final f = app.reports.financials(r);
    final label = switch (_mode) {
      _Mode.month => DateFormat('MMMM yyyy').format(DateTime(_year, _month)),
      _Mode.year => '$_year',
      _Mode.custom => '${dateFmt.format(_from)} – ${dateFmt.format(_to)}',
    };
    // Months shown in the chart: the 12 months up to the selected period.
    final chartEnd = DateTime(r.to.year, r.to.month);
    final months = [for (var k = 11; k >= 0; k--) DateTime(chartEnd.year, chartEnd.month - k)];
    final monthly = [for (final m in months) app.reports.financials(DateRange(m, dayEnd(DateTime(m.year, m.month + 1, 0))))];
    String short(double paisa) {
      final v = paisa / 100;
      final a = v.abs();
      final s = a >= 10000000 ? '${(a / 10000000).toStringAsFixed(1)}Cr' : a >= 100000 ? '${(a / 100000).toStringAsFixed(1)}L' : a >= 1000 ? '${(a / 1000).toStringAsFixed(0)}K' : a.toStringAsFixed(0);
      return v < 0 ? '-$s' : s;
    }

    final b = ReportBuilder(app);
    void export(ReportKind k, ExportAction a) =>
        runExport(context, app.ctx.settings, b.workbook(k, k == ReportKind.yearlySummary ? DateRange(DateTime(r.to.year), dayEnd(DateTime(r.to.year, 12, 31))) : r), a, name: '${k.title} $label', landscape: k.landscape);

    Widget line(String text, Money v, {bool bold = false, bool minus = false, Color? color, String? note}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(text, style: TextStyle(fontWeight: bold ? FontWeight.w800 : FontWeight.w500, color: c.text)),
                if (note != null) Text(note, style: TextStyle(color: c.textMuted, fontSize: 11)),
              ]),
            ),
            Text('${minus && !v.isZero ? '− ' : ''}${v.format()}', style: TextStyle(fontWeight: bold ? FontWeight.w800 : FontWeight.w600, color: color ?? (v.isNegative ? c.danger : c.text))),
          ]),
        );

    final pl = AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Profit & Loss • $label', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: c.text)),
        const SizedBox(height: 10),
        line('Total sales (before discounts)', f.grossSales),
        line('Sales discounts', f.discounts, minus: true),
        line('Sales returns', f.salesReturns, minus: true),
        Divider(color: c.border),
        line('Net sales', f.netSales, bold: true),
        line('Cost of goods sold', f.cogs, minus: true, note: 'Actual purchase cost (FIFO) of the units sold'),
        Divider(color: c.border),
        line('GROSS PROFIT', f.grossProfit, bold: true, color: f.grossProfit.isNegative ? c.danger : c.accent),
        if (!f.repairProfit.isZero) line('Repair service profit', f.repairProfit, note: 'Repair charges − parts cost'),
        line('Total shop expenses', f.expenses, minus: true),
        Divider(color: c.border),
        line('NET OPERATING PROFIT', f.netOperatingProfit, bold: true, color: f.netOperatingProfit.isNegative ? c.danger : c.accent, note: 'Gross profit + repair profit − expenses'),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: c.primary.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(10)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Cash (not profit)', style: TextStyle(fontWeight: FontWeight.w700, color: c.text)),
            line('Cash received from customers', f.cashReceived),
            line('Refunds paid to customers', f.refundsPaid, minus: true),
            line('Sold on credit (not received at the sale)', f.creditSales, note: 'Counted in sales, not in cash'),
            line('Customer balances outstanding at period end', f.customerOutstanding),
          ]),
        ),
      ]),
    );

    final cats = f.expensesByCategory;
    final palette = [c.danger, c.warning, const Color(0xFF6FB8FF), const Color(0xFFB28DFF), c.accent, c.primary, const Color(0xFFFF8A80)];
    return SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PageHeader(title: 'Profit & Loss', subtitle: label, breadcrumbs: const ['Profit & Loss'], actions: [
          PopupMenuButton<(ReportKind, ExportAction)>(
            key: const ValueKey('finance-export'),
            tooltip: 'Export to Excel / PDF, print',
            onSelected: (v) => export(v.$1, v.$2),
            itemBuilder: (_) => [
              for (final k in const [ReportKind.profitLoss, ReportKind.profit, ReportKind.expenses, ReportKind.expensesByCategory, ReportKind.yearlySummary]) ...[
                PopupMenuItem(enabled: false, height: 30, child: Text(k == ReportKind.yearlySummary ? '${k.title} ${r.to.year}' : k.title, style: TextStyle(fontWeight: FontWeight.w700, color: c.text))),
                for (final a in const [ExportAction.excel, ExportAction.pdf, ExportAction.print, ExportAction.preview])
                  PopupMenuItem(value: (k, a), height: 36, child: Padding(padding: const EdgeInsets.only(left: 12), child: Row(children: [Icon(a.icon, size: 17), const SizedBox(width: 10), Text(a.label)]))),
              ],
            ],
            child: IgnorePointer(child: OutlinedButton.icon(onPressed: () {}, icon: const Icon(Icons.ios_share, size: 18), label: const Text('Export / Print'))),
          ),
          FilledButton.icon(onPressed: () => ref.read(navProvider.notifier).state = NavItem.expenses, icon: const Icon(Icons.receipt_long_outlined, size: 18), label: const Text('Expenses')),
        ]),
        Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SegmentedButton<_Mode>(
            segments: const [
              ButtonSegment(value: _Mode.month, label: Text('Month')),
              ButtonSegment(value: _Mode.year, label: Text('Year')),
              ButtonSegment(value: _Mode.custom, label: Text('Custom')),
            ],
            selected: {_mode},
            onSelectionChanged: (s) => setState(() => _mode = s.first),
          ),
          if (_mode == _Mode.month)
            SizedBox(
              width: 150,
              child: AppDropdown<int>(
                key: const ValueKey('finance-month'),
                value: _month,
                decoration: const InputDecoration(labelText: 'Month', isDense: true),
                items: [for (var m = 1; m <= 12; m++) DropdownMenuItem(value: m, child: Text(DateFormat('MMMM').format(DateTime(2026, m))))],
                onChanged: (v) => setState(() => _month = v ?? _month),
              ),
            ),
          if (_mode != _Mode.custom)
            SizedBox(
              width: 120,
              child: AppDropdown<int>(
                key: const ValueKey('finance-year'),
                value: _year,
                decoration: const InputDecoration(labelText: 'Year', isDense: true),
                items: [for (var y = DateTime.now().year; y >= 2020; y--) DropdownMenuItem(value: y, child: Text('$y'))],
                onChanged: (v) => setState(() => _year = v ?? _year),
              ),
            ),
          if (_mode == _Mode.custom)
            DateRangeBar(from: _from, to: _to, onChanged: (a, b0) => setState(() {
                  _from = a;
                  _to = b0;
                })),
        ]),
        const SizedBox(height: 14),
        ResponsiveGrid(minItemWidth: 210, children: [
          StatCard(label: 'Net sales', icon: Icons.point_of_sale, value: AnimatedMoney(f.netSales), caption: '${f.invoiceCount} invoices • after discounts & returns'),
          StatCard(label: 'Gross profit', icon: Icons.trending_up, value: AnimatedMoney(f.grossProfit), tone: f.grossProfit.isNegative ? c.danger : c.accent, caption: 'Before expenses • margin ${(f.marginBp / 100).toStringAsFixed(1)}%'),
          StatCard(label: 'Total expenses', icon: Icons.receipt_long_outlined, value: AnimatedMoney(f.expenses), tone: c.danger),
          StatCard(label: 'Net operating profit', icon: Icons.account_balance, value: AnimatedMoney(f.netOperatingProfit), tone: f.netOperatingProfit.isNegative ? c.danger : c.accent),
          StatCard(label: 'Cash received (net)', icon: Icons.payments_outlined, value: AnimatedMoney(f.netCashFromCustomers), caption: 'Money actually received'),
          StatCard(label: 'Customers owe (end of period)', icon: Icons.call_received, value: AnimatedMoney(f.customerOutstanding), tone: c.warning),
        ]),
        const SizedBox(height: 16),
        LayoutBuilder(builder: (_, cons) {
          final wide = cons.maxWidth > 1000;
          final breakdown = AppCard(
            child: SizedBox(
              height: 320,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Expense breakdown', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: c.text)),
                const SizedBox(height: 12),
                Expanded(
                  child: cats.isEmpty
                      ? Center(child: Text('No expenses recorded for $label', style: TextStyle(color: c.textMuted)))
                      : DonutChart(data: {for (final (k, v) in cats) k: v.paisa / 100}, palette: palette, centerLabel: 'Rs expenses'),
                ),
              ]),
            ),
          );
          return wide
              ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(flex: 3, child: pl), const SizedBox(width: 16), Expanded(flex: 2, child: breakdown)])
              : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [pl, const SizedBox(height: 16), breakdown]);
        }),
        const SizedBox(height: 16),
        AppCard(
          child: SizedBox(
            height: 320,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Last 12 months: net sales, expenses and net operating profit', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: c.text)),
              const SizedBox(height: 12),
              Expanded(
                child: GroupedBarChart(
                  labels: [for (final m in months) DateFormat('MMM yy').format(m)],
                  bars: [
                    BarSeries('Net sales', c.accent, [for (final x in monthly) x.netSales.paisa.toDouble()]),
                    BarSeries('Gross profit', const Color(0xFF6FB8FF), [for (final x in monthly) x.grossProfit.paisa.toDouble()]),
                    BarSeries('Expenses', c.danger.withValues(alpha: 0.85), [for (final x in monthly) x.expenses.paisa.toDouble()]),
                  ],
                  line: BarSeries('Net operating profit', c.warning, [for (final x in monthly) x.netOperatingProfit.paisa.toDouble()]),
                  format: short,
                ),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}
