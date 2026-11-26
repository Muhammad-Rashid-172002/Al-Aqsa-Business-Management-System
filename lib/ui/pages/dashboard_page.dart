import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../domain/models/documents.dart';
import '../../domain/models/operations.dart';
import '../../domain/models/party.dart';
import '../../domain/models/user.dart';
import '../../domain/services/report_service.dart';
import '../../domain/services/backup_service.dart' show appDisplayName;
import '../providers.dart';
import '../splash/splash_screen.dart' show AppLogoFull;
import '../theme.dart';
import '../widgets/charts.dart';
import '../widgets/common.dart';

enum RangePreset { today, week, month, lastMonth, custom }

final dashboardRangeProvider = StateProvider<(RangePreset, DateRange?)>((ref) => (RangePreset.month, null));

class DashboardPage extends ConsumerWidget {
  const DashboardPage({super.key});

  DateRange _range(RangePreset p, DateRange? custom, DateTime now) => switch (p) {
        RangePreset.today => DateRange.today(now),
        RangePreset.week => DateRange.thisWeek(now),
        RangePreset.month => DateRange.thisMonth(now),
        RangePreset.lastMonth => DateRange.lastMonth(now),
        RangePreset.custom => custom ?? DateRange.thisMonth(now),
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AppTheme.of(context);
    final app = ref.watch(liveServicesProvider);
    final user = ref.watch(currentUserProvider)!;
    final (preset, custom) = ref.watch(dashboardRangeProvider);
    final now = app.ctx.now();
    final range = _range(preset, custom, now);
    final fin = user.can(Permission.viewFinancials);

    final profit = app.reports.profit(range);
    final todaySales = app.reports.salesTotal(DateRange.today(now));
    final monthSales = app.reports.salesTotal(DateRange.thisMonth(now));
    final purchases = app.reports.purchaseTotal(range);
    final stock = app.reports.stock();
    final valuation = app.inventory.stockValuation();
    final low = stock.where((r) => r.product.isLowStock).length;
    final out = stock.where((r) => r.product.isOutOfStock).length;
    final totalQty = stock.fold(0.0, (a, r) => a + (r.product.stockQty.isPositive ? r.product.stockQty.asDouble : 0));
    final months = app.reports.monthly(6);
    final top = app.reports.productSales(range).take(6).toList();
    final byCat = app.reports.stockValueByCategory();
    final recentSales = app.sales.list(status: DocStatus.completed).take(6).toList();
    final recentPurchases = app.purchases.list(includeCancelled: false).take(6).toList();
    final holdings = app.technicians.holdings();
    final pendingRepairs = app.repairs.list(openOnly: true);
    final openClaims = app.warranty.claims().where((x) => x.status == ClaimStatus.open || x.status == ClaimStatus.sentForRepair).length;
    final df = DateFormat('d MMM');

    String short(double paisa) {
      final r = paisa / 100;
      if (r >= 10000000) return '${(r / 10000000).toStringAsFixed(1)}Cr';
      if (r >= 100000) return '${(r / 100000).toStringAsFixed(1)}L';
      if (r >= 1000) return '${(r / 1000).toStringAsFixed(0)}K';
      return r.toStringAsFixed(0);
    }

    Widget grid(List<Widget> children, {double minWidth = 250}) => ResponsiveGrid(minItemWidth: minWidth, children: children);

    Widget section(String title, Widget child, {double height = 300, Widget? trailing}) => AppCard(
          child: SizedBox(
            height: height,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: c.text))),
                if (trailing != null) trailing,
              ]),
              const SizedBox(height: 14),
              Expanded(child: child),
            ]),
          ),
        );

    Widget activity(String title, List<(String, String, String)> rows, String emptyText) => section(
          title,
          rows.isEmpty
              ? Center(child: Text(emptyText, style: TextStyle(color: c.textMuted)))
              : ListView.separated(
                  itemCount: rows.length,
                  separatorBuilder: (_, __) => Divider(color: c.border, height: 1),
                  itemBuilder: (_, k) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    child: Row(children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(rows[k].$1, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: c.text, fontWeight: FontWeight.w600, fontSize: 13)),
                          Text(rows[k].$2, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: c.textMuted, fontSize: 12)),
                        ]),
                      ),
                      const SizedBox(width: 10),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 160),
                        child: Text(rows[k].$3, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.right, style: TextStyle(color: c.text, fontWeight: FontWeight.w600, fontSize: 13)),
                      ),
                    ]),
                  ),
                ),
          height: 290,
        );

    return SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Row(children: [
              const AppLogoFull(height: 64),
              const SizedBox(width: 14),
              Expanded(
                child: Text(appDisplayName, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppTheme.of(context).text)),
              ),
            ]),
          ),
          PageHeader(
            title: 'Dashboard',
            subtitle: 'Live figures from your records • ${DateFormat('d MMM yyyy').format(range.from)} – ${DateFormat('d MMM yyyy').format(range.to)}',
            actions: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SegmentedButton<RangePreset>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: RangePreset.today, label: Text('Today')),
                  ButtonSegment(value: RangePreset.week, label: Text('This Week')),
                  ButtonSegment(value: RangePreset.month, label: Text('This Month')),
                  ButtonSegment(value: RangePreset.lastMonth, label: Text('Last Month')),
                  ButtonSegment(value: RangePreset.custom, label: Text('Custom')),
                ],
                selected: {preset},
                onSelectionChanged: (s) async {
                  final p = s.first;
                  if (p == RangePreset.custom) {
                    final picked = await showDateRangePicker(context: context, firstDate: DateTime(2020), lastDate: DateTime(now.year + 1));
                    if (picked == null) return;
                    ref.read(dashboardRangeProvider.notifier).state = (p, DateRange(picked.start, DateTime(picked.end.year, picked.end.month, picked.end.day, 23, 59, 59)));
                  } else {
                    ref.read(dashboardRangeProvider.notifier).state = (p, null);
                  }
                },
                ),
              ),
            ],
          ),
          if (fin) ...[
            grid([
              StatCard(label: "Today's Sales", icon: Icons.today_rounded, value: AnimatedMoney(todaySales)),
              StatCard(label: 'Monthly Sales', icon: Icons.calendar_month_rounded, value: AnimatedMoney(monthSales)),
              StatCard(label: 'Purchases (period)', icon: Icons.local_shipping_outlined, value: AnimatedMoney(purchases), tone: c.warning),
              StatCard(
                label: 'Gross Profit (period)',
                icon: Icons.trending_up_rounded,
                value: AnimatedMoney(profit.grossProfit),
                caption: 'Stock products only, before expenses • margin ${(profit.marginBp / 100).toStringAsFixed(1)}%',
                tone: profit.grossProfit.isNegative ? c.danger : c.accent,
              ),
              StatCard(label: 'Customer Receivables', icon: Icons.call_received_rounded, value: AnimatedMoney(app.parties.totalReceivables())),
              StatCard(label: 'Supplier Payables', icon: Icons.call_made_rounded, value: AnimatedMoney(app.parties.totalPayables()), tone: c.danger),
            ]),
            const SizedBox(height: 16),
          ],
          grid([
            StatCard(label: 'Total Products', icon: Icons.inventory_2_outlined, value: AnimatedCount(stock.length)),
            StatCard(label: 'Total Stock Quantity', icon: Icons.stacked_bar_chart_rounded, value: AnimatedCount(totalQty.round()), caption: 'All units incl. metres'),
            StatCard(
                label: 'Low Stock',
                icon: Icons.warning_amber_rounded,
                value: AnimatedCount(low),
                tone: c.warning,
                onTap: () => ref.read(navProvider.notifier).state = NavItem.inventory),
            StatCard(
                label: 'Out of Stock',
                icon: Icons.remove_shopping_cart_outlined,
                value: AnimatedCount(out),
                tone: c.danger,
                onTap: () => ref.read(navProvider.notifier).state = NavItem.inventory),
            if (fin) StatCard(label: 'Inventory Value (FIFO cost)', icon: Icons.account_balance_outlined, value: AnimatedMoney(valuation)),
          ], minWidth: 220),
          const SizedBox(height: 16),
          if (fin)
            LayoutBuilder(builder: (_, cons) {
              final wide = cons.maxWidth > 1100;
              final chart = section(
                'Sales vs Purchases • last 6 months',
                GroupedBarChart(
                  labels: [for (final m0 in months) DateFormat('MMM').format(m0.month)],
                  bars: [
                    BarSeries('Net Sales', c.accent, [for (final m0 in months) m0.sales.paisa.toDouble()]),
                    BarSeries('Purchases', c.warning.withValues(alpha: 0.85), [for (final m0 in months) m0.purchases.paisa.toDouble()]),
                  ],
                  line: BarSeries('Gross Profit', const Color(0xFF6FB8FF), [for (final m0 in months) m0.grossProfit.paisa.toDouble()]),
                  format: short,
                ),
                height: 330,
              );
              final topCard = section(
                'Top Selling Products',
                top.isEmpty
                    ? Center(child: Text('No sales in this period', style: TextStyle(color: c.textMuted)))
                    : SingleChildScrollView(
                        child: RankBars(color: c.accent, rows: [for (final r in top) (r.name, r.revenue.paisa.toDouble(), '${r.qty.format()} sold • ${r.revenue.format(showDecimals: false)}')]),
                      ),
                height: 330,
              );
              return wide
                  ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(flex: 3, child: chart), const SizedBox(width: 16), Expanded(flex: 2, child: topCard)])
                  : Column(children: [chart, const SizedBox(height: 16), topCard]);
            }),
          const SizedBox(height: 16),
          grid([
            section(
              'Stock Value by Category',
              byCat.isEmpty
                  ? Center(child: Text('No products yet', style: TextStyle(color: c.textMuted)))
                  : DonutChart(
                      data: byCat.map((k, v) => MapEntry(k, v.paisa / 100)),
                      centerLabel: 'Rs value',
                      palette: [c.accent, const Color(0xFF6FB8FF), c.warning, const Color(0xFFB28DFF), const Color(0xFFFF8A80), c.primary],
                    ),
              height: 240,
            ),
            activity(
              'Pending Technician Stock',
              [
                for (final h in holdings.take(8))
                  (
                    app.technicians.technicians(includeInactive: true).firstWhere((e) => e.id == h.technicianId).name,
                    app.catalog.byId(h.productId)?.name ?? '',
                    h.qty.format(),
                  )
              ],
              'No material is out with technicians',
            ),
            activity(
              'Pending Work',
              [
                for (final r in pendingRepairs.take(6)) (r.number, '${r.customerName} • ${r.productName}', r.status.label),
                if (openClaims > 0) ('Warranty', '$openClaims open warranty claim(s)', ''),
              ],
              'No pending repairs or warranty claims',
            ),
          ], minWidth: 380),
          const SizedBox(height: 16),
          if (fin)
            grid([
              activity('Recent Sales', [for (final s0 in recentSales) (s0.number, '${s0.customerName} • ${df.format(s0.date)}', s0.total.format(showDecimals: false))],
                  'No sales yet'),
              activity(
                  'Recent Purchases',
                  [
                    for (final p in recentPurchases)
                      (p.number, '${app.parties.byId(PartyKind.supplier, p.supplierId)?.name ?? ''} • ${df.format(p.date)}', p.total.format(showDecimals: false))
                  ],
                  'No purchases yet'),
              activity(
                  'Recent Payments',
                  [
                    for (final p in app.parties.payments().take(6))
                      (p.number, '${p.method.label}${p.voided ? ' • VOID' : ''} • ${df.format(p.at)}', '${p.direction.name == 'received' ? '+' : '−'}${p.amount.format(showDecimals: false)}')
                  ],
                  'No payments yet'),
              activity(
                  'Recent Returns',
                  [
                    for (final r in [...app.sales.returns(), ...app.purchases.returns()]..sort((a, b) => b.date.compareTo(a.date)))
                      (r.number, '${r.originalNumber} • ${df.format(r.date)}', r.total.format(showDecimals: false))
                  ].take(6).toList(),
                  'No returns yet'),
            ], minWidth: 380),
          const SizedBox(height: 8),
          if (fin)
            Text('Gross profit = stock product sales after discounts − their actual purchase cost (FIFO), before shop expenses. Non-stock items (screws, clips) and labour are not shop profit; sales exclude labour.',
                style: TextStyle(color: c.textMuted, fontSize: 11.5)),
        ],
      ),
    );
  }
}
