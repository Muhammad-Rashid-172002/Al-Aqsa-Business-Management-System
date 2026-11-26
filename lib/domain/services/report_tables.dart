import 'package:intl/intl.dart';

import '../../core/ids.dart';
import '../../core/money.dart';
import '../../core/qty.dart';
import '../../data/store/data_store.dart';
import '../../export/tabular.dart';
import '../models/documents.dart';
import '../models/json_utils.dart';
import '../models/operations.dart';
import '../models/party.dart';
import '../models/product.dart';
import '../models/user.dart';
import 'app_services.dart';
import 'report_service.dart';
import 'warranty_repair_service.dart';

/// Filters a report can offer (besides the date range).
enum ReportFilterField { product, category, supplier, customer, paymentStatus, serial, technician, txnType }

/// Invoice payment status: from payments recorded against the invoice (at
/// the sale or later against that invoice). Payments made to the customer's
/// account in general reduce the balance but belong to no single invoice.
enum PayStatus {
  paid('Paid'),
  partial('Partly paid'),
  unpaid('Unpaid');

  final String label;
  const PayStatus(this.label);
}

class ReportFilter {
  final String? productId;
  final String? categoryId;
  final String? supplierId;
  final String? customerId;
  final PayStatus? payment;
  final String? serial;
  final String? technicianId;
  final String? txnType;
  const ReportFilter({this.productId, this.categoryId, this.supplierId, this.customerId, this.payment, this.serial, this.technicianId, this.txnType});

  static const none = ReportFilter();

  bool get isEmpty =>
      productId == null && categoryId == null && supplierId == null && customerId == null && payment == null && (serial ?? '').isEmpty && technicianId == null && txnType == null;

  /// Only the filters [fields] supports (others are ignored, never applied).
  ReportFilter only(Set<ReportFilterField> fields) => ReportFilter(
        productId: fields.contains(ReportFilterField.product) ? productId : null,
        categoryId: fields.contains(ReportFilterField.category) ? categoryId : null,
        supplierId: fields.contains(ReportFilterField.supplier) ? supplierId : null,
        customerId: fields.contains(ReportFilterField.customer) ? customerId : null,
        payment: fields.contains(ReportFilterField.paymentStatus) ? payment : null,
        serial: fields.contains(ReportFilterField.serial) && (serial ?? '').trim().isNotEmpty ? normalizeCode(serial!) : null,
        technicianId: fields.contains(ReportFilterField.technician) ? technicianId : null,
        txnType: fields.contains(ReportFilterField.txnType) ? txnType : null,
      );
}

const _sales = {ReportFilterField.customer, ReportFilterField.product, ReportFilterField.category};
const _stock = {ReportFilterField.product, ReportFilterField.category};

/// Every report the owner can open, export to Excel/CSV, print or save as PDF.
enum ReportKind {
  // Business overview
  businessDaily('Business', 'Daily Business Report'),
  businessWeekly('Business', 'Weekly Business Report'),
  businessMonthly('Business', 'Monthly Business Report'),
  // Profit & expenses
  profitLoss('Profit & Expenses', 'Profit & Loss'),
  profit('Profit & Expenses', 'Gross Profit (before expenses)'),
  yearlySummary('Profit & Expenses', 'Yearly Financial Summary'),
  expenses('Profit & Expenses', 'Expense Report'),
  expensesByCategory('Profit & Expenses', 'Category-wise Expenses'),
  // Sales
  salesDaily('Sales', 'Daily Sales'),
  salesMonthly('Sales', 'Monthly Sales'),
  salesYearly('Sales', 'Yearly Sales'),
  salesByProduct('Sales', 'Product-wise Sales'),
  salesByCustomer('Sales', 'Customer-wise Sales'),
  salesInvoices('Sales', 'Sales Register (Invoices)'),
  discounts('Sales', 'Discounts Report'),
  salesReturns('Sales', 'Sales Returns'),
  // Purchases
  purchaseRegister('Purchases', 'Purchase Register'),
  bulkPurchases('Purchases', 'Purchase Details & Serial Numbers'),
  purchasesBySupplier('Purchases', 'Supplier-wise Purchases'),
  purchasesMonthly('Purchases', 'Monthly Purchases'),
  purchaseReturns('Purchases', 'Purchase Returns'),
  // Products & inventory
  productList('Products & Stock', 'Product List'),
  stockCurrent('Products & Stock', 'Product Stock'),
  stockLow('Products & Stock', 'Low Stock'),
  stockOut('Products & Stock', 'Out of Stock'),
  stockValuation('Products & Stock', 'Stock Valuation'),
  stockMovement('Products & Stock', 'Stock Movement'),
  serials('Products & Stock', 'Serial Number List'),
  // Accounts
  customerLedger('Accounts', 'Customer Ledger'),
  supplierLedger('Accounts', 'Supplier Ledger'),
  receivables('Accounts', 'Customer Outstanding Balances'),
  payables('Accounts', 'Supplier Outstanding Balances'),
  payments('Accounts', 'Payment History'),
  // Technicians
  techIssued('Technicians', 'Issued Material'),
  techReturned('Technicians', 'Returned Material'),
  techUsed('Technicians', 'Used / Installed Material'),
  techPending('Technicians', 'Pending Material (held)'),
  // Warranty
  warrantyActive('Warranty', 'Active Warranty'),
  warrantyExpired('Warranty', 'Expired Warranty'),
  warrantyClaims('Warranty', 'Warranty Claims'),
  // Repairs & faulty
  repairsPending('Repairs & Faulty', 'Pending Repairs'),
  repairsCompleted('Repairs & Faulty', 'Completed Repairs'),
  faultyStock('Repairs & Faulty', 'Faulty & Damaged Products');

  final String group;
  final String title;
  const ReportKind(this.group, this.title);

  /// Reports that ignore the date range (snapshots of "now").
  bool get isSnapshot => const {
        ReportKind.productList,
        ReportKind.stockCurrent,
        ReportKind.stockLow,
        ReportKind.stockOut,
        ReportKind.stockValuation,
        ReportKind.serials,
        ReportKind.techPending,
        ReportKind.receivables,
        ReportKind.payables,
        ReportKind.warrantyActive,
        ReportKind.warrantyExpired,
        ReportKind.repairsPending,
        ReportKind.faultyStock,
      }.contains(this);

  /// Shown only to users who may see profits, costs and expenses.
  bool get isFinancial => group == 'Profit & Expenses' || group == 'Business' || this == ReportKind.stockValuation;

  bool get landscape => const {
        ReportKind.businessDaily,
        ReportKind.businessWeekly,
        ReportKind.businessMonthly,
        ReportKind.yearlySummary,
        ReportKind.salesInvoices,
        ReportKind.discounts,
        ReportKind.purchaseRegister,
        ReportKind.bulkPurchases,
        ReportKind.productList,
        ReportKind.stockCurrent,
        ReportKind.stockLow,
        ReportKind.stockOut,
        ReportKind.stockValuation,
        ReportKind.stockMovement,
        ReportKind.serials,
        ReportKind.customerLedger,
        ReportKind.supplierLedger,
        ReportKind.payments,
        ReportKind.techIssued,
        ReportKind.techReturned,
        ReportKind.techUsed,
        ReportKind.warrantyClaims,
        ReportKind.repairsPending,
        ReportKind.repairsCompleted,
        ReportKind.salesReturns,
        ReportKind.purchaseReturns,
        ReportKind.expenses,
      }.contains(this);

  /// Filters this report supports.
  Set<ReportFilterField> get filters => switch (this) {
        ReportKind.salesDaily || ReportKind.salesMonthly || ReportKind.salesYearly || ReportKind.salesByProduct || ReportKind.salesByCustomer || ReportKind.discounts => _sales,
        ReportKind.salesInvoices => {..._sales, ReportFilterField.paymentStatus, ReportFilterField.serial},
        ReportKind.salesReturns => _sales,
        ReportKind.purchaseRegister => {ReportFilterField.supplier, ..._stock, ReportFilterField.paymentStatus},
        ReportKind.bulkPurchases => {ReportFilterField.supplier, ..._stock, ReportFilterField.serial},
        ReportKind.purchasesBySupplier || ReportKind.purchasesMonthly || ReportKind.purchaseReturns => {ReportFilterField.supplier, ..._stock},
        ReportKind.productList || ReportKind.stockCurrent || ReportKind.stockLow || ReportKind.stockOut || ReportKind.stockValuation => _stock,
        ReportKind.stockMovement => {..._stock, ReportFilterField.txnType},
        ReportKind.serials => {..._stock, ReportFilterField.supplier, ReportFilterField.customer, ReportFilterField.serial, ReportFilterField.txnType},
        ReportKind.customerLedger => {ReportFilterField.customer, ReportFilterField.txnType},
        ReportKind.supplierLedger => {ReportFilterField.supplier, ReportFilterField.txnType},
        ReportKind.receivables => {ReportFilterField.customer},
        ReportKind.payables => {ReportFilterField.supplier},
        ReportKind.payments => {ReportFilterField.customer, ReportFilterField.supplier, ReportFilterField.txnType},
        ReportKind.techIssued || ReportKind.techReturned || ReportKind.techUsed => {ReportFilterField.technician, ..._stock, ReportFilterField.customer, ReportFilterField.serial},
        ReportKind.techPending => {ReportFilterField.technician, ..._stock},
        ReportKind.warrantyActive || ReportKind.warrantyExpired => {..._stock, ReportFilterField.customer, ReportFilterField.serial},
        ReportKind.warrantyClaims => {..._stock, ReportFilterField.customer, ReportFilterField.serial, ReportFilterField.txnType},
        ReportKind.repairsPending || ReportKind.repairsCompleted => {ReportFilterField.technician, ReportFilterField.customer, ReportFilterField.serial, ReportFilterField.txnType},
        ReportKind.faultyStock => {..._stock, ReportFilterField.serial, ReportFilterField.txnType},
        ReportKind.expenses || ReportKind.expensesByCategory => {ReportFilterField.txnType},
        _ => const <ReportFilterField>{},
      };

  /// What the "Type" filter means for this report.
  String get txnTypeLabel => switch (this) {
        ReportKind.stockMovement => 'Movement type',
        ReportKind.serials || ReportKind.faultyStock => 'Unit status',
        ReportKind.customerLedger || ReportKind.supplierLedger => 'Transaction type',
        ReportKind.payments => 'Direction',
        ReportKind.warrantyClaims => 'Claim status',
        ReportKind.repairsPending || ReportKind.repairsCompleted => 'Repair status',
        ReportKind.expenses || ReportKind.expensesByCategory => 'Expense category',
        _ => 'Type',
      };
}

double _m(Money v) => v.paisa / 100;
double _q(Qty v) => v.asDouble;
String _two(int v) => v.toString().padLeft(2, '0');

const _faulty = {
  SerialStatus.damaged,
  SerialStatus.underRepair,
  SerialStatus.awaitingRepair,
  SerialStatus.pendingInspection,
  SerialStatus.returned,
};

class ReportBuilder {
  final AppServices app;
  ReportBuilder(this.app);

  /// Options for the "Type" filter of [k] (value, label).
  List<(String, String)> txnTypeOptions(ReportKind k) => switch (k) {
        ReportKind.stockMovement => [
            for (final t in {for (final m0 in app.ctx.store.values(Boxes.stockMovements)) m0['type'] as String? ?? ''}.where((x) => x.isNotEmpty).toList()..sort()) (t, t),
          ],
        ReportKind.serials => [for (final s0 in SerialStatus.values) (s0.name, s0.label)],
        ReportKind.faultyStock => [for (final s0 in _faulty) (s0.name, s0.label)],
        ReportKind.customerLedger || ReportKind.supplierLedger => [for (final t in LedgerType.values) (t.name, _ledgerLabel(t))],
        ReportKind.payments => [('received', 'Received'), ('paid', 'Paid out')],
        ReportKind.warrantyClaims => [for (final s0 in ClaimStatus.values) (s0.name, s0.name)],
        ReportKind.repairsPending || ReportKind.repairsCompleted => [for (final s0 in RepairStatus.values) (s0.name, s0.label)],
        ReportKind.expenses || ReportKind.expensesByCategory => [for (final c0 in app.expenses.categories()) (c0, c0)],
        _ => const [],
      };

  static String _ledgerLabel(LedgerType t) => switch (t) {
        LedgerType.opening => 'Opening balance',
        LedgerType.sale => 'Sale',
        LedgerType.payment => 'Payment',
        LedgerType.salesReturn => 'Sales return',
        LedgerType.purchase => 'Purchase',
        LedgerType.purchaseReturn => 'Purchase return',
        LedgerType.adjustment => 'Adjustment',
        LedgerType.reversal => 'Reversal',
        LedgerType.repairCharge => 'Repair charge',
        LedgerType.refund => 'Refund',
      };

  /// Lines for report headings: period and the filters applied.
  List<String> describe(ReportKind k, DateRange r, ReportFilter f0) {
    final f = f0.only(k.filters);
    final d = DateFormat('dd/MM/yyyy');
    final out = <String>[k.isSnapshot ? 'As of ${DateFormat('dd/MM/yyyy HH:mm').format(app.ctx.now())}' : 'Period: ${d.format(r.from)} – ${d.format(r.to)}'];
    final parts = <String>[
      if (f.productId != null) 'Product: ${app.catalog.byId(f.productId!)?.name ?? '?'}',
      if (f.categoryId != null) 'Category: ${app.catalog.categories().where((c0) => c0.id == f.categoryId).map((c0) => c0.name).firstOrNull ?? '?'}',
      if (f.supplierId != null) 'Supplier: ${app.parties.byId(PartyKind.supplier, f.supplierId!)?.name ?? '?'}',
      if (f.customerId != null) 'Customer: ${app.parties.byId(PartyKind.customer, f.customerId!)?.name ?? '?'}',
      if (f.payment != null) 'Payment status: ${f.payment!.label}',
      if (f.serial != null) 'Serial: ${f.serial}',
      if (f.technicianId != null) 'Technician: ${app.technicians.technicians(includeInactive: true).where((t) => t.id == f.technicianId).map((t) => t.name).firstOrNull ?? '?'}',
      if (f.txnType != null) '${k.txnTypeLabel}: ${txnTypeOptions(k).where((o) => o.$1 == f.txnType).map((o) => o.$2).firstOrNull ?? f.txnType}',
    ];
    if (parts.isNotEmpty) out.add('Filters: ${parts.join(' • ')}');
    return out;
  }

  /// The report as one table (the first sheet of [workbook]).
  ExportTable build(ReportKind k, DateRange r, [ReportFilter filter = ReportFilter.none]) => workbook(k, r, filter).first;

  /// The report as one or more sheets, each with the period / filter lines.
  List<ExportTable> workbook(ReportKind k, DateRange r, [ReportFilter filter = ReportFilter.none]) {
    final info = describe(k, r, filter);
    return [for (final t in _build(k, r, filter.only(k.filters))) t.withInfo(info)];
  }

  List<ExportTable> _build(ReportKind k, DateRange r, ReportFilter f) {
    final ctx = app.ctx;
    final fin = ctx.can(Permission.viewFinancials);
    final showCost = ctx.can(Permission.viewPurchasePrice);
    // Lookups built only by the reports that use them (`late`).
    late final products = {for (final p in app.catalog.products(includeArchived: true)) p.id: p};
    late final catNames = {for (final c0 in app.catalog.categories()) c0.id: c0.name};
    late final cust = {for (final p in app.parties.list(PartyKind.customer, includeInactive: true)) p.id: p.name};
    late final sup = {for (final p in app.parties.list(PartyKind.supplier, includeInactive: true)) p.id: p.name};
    late final techs = {for (final t in app.technicians.technicians(includeInactive: true)) t.id: t.name};
    late final payIn = _paymentsByRef(PaymentDirection.received);
    late final payOut = _paymentsByRef(PaymentDirection.paid);

    bool prodOk(String? id) {
      if (f.productId != null && id != f.productId) return false;
      if (f.categoryId != null && (id == null || products[id]?.categoryId != f.categoryId)) return false;
      return true;
    }

    bool serialOk(Iterable<String> keysOrSerials) => f.serial == null || keysOrSerials.any((k0) => _plain(k0) == f.serial);
    final lineFilter = f.productId != null || f.categoryId != null;

    PayStatus status(Money total, Money paid) => paid >= total ? PayStatus.paid : (paid.isPositive ? PayStatus.partial : PayStatus.unpaid);
    Money salePaid(Sale s0) => payIn[s0.id] ?? const Money.zero();
    Money purchasePaid(Purchase p) => payOut[p.id] ?? const Money.zero();

    late final sales = app.sales
        .list(from: r.from, to: r.to, status: DocStatus.completed)
        .where((s0) =>
            (f.customerId == null || s0.customerId == f.customerId) &&
            (!lineFilter || s0.items.any((it) => prodOk(it.productId))) &&
            serialOk(s0.items.expand((it) => it.serials)) &&
            (f.payment == null || status(s0.total, salePaid(s0)) == f.payment))
        .toList()
      ..sort((a, b) => a.date.compareTo(b.date));
    late final saleReturns = app.sales.returns(from: r.from, to: r.to).where((x) => f.customerId == null || x.partyId == f.customerId).toList();
    late final purchases = app.reports
        .purchases(r)
        .where((p) =>
            (f.supplierId == null || p.supplierId == f.supplierId) &&
            (!lineFilter || p.items.any((it) => prodOk(it.productId))) &&
            serialOk(p.items.expand((it) => it.serials)) &&
            (f.payment == null || status(p.total, purchasePaid(p)) == f.payment))
        .toList()
      ..sort((a, b) => a.date.compareTo(b.date));

    /// Line-level sales (respecting product/category filters): revenue after
    /// discounts (invoice discount shared over the lines) and FIFO cost.
    /// Shop STOCK product lines only: the base of shop sales profit.
    Iterable<(Sale, Money, Money, Qty, String)> saleLines() sync* {
      for (final s0 in sales) {
        final rev = s0.lineRevenues();
        for (var i = 0; i < s0.items.length; i++) {
          final it = s0.items[i];
          if (!it.isStock || !prodOk(it.productId)) continue;
          yield (s0, rev[i], it.cogs, it.qty, it.lineKey);
        }
      }
    }

    /// Non-stock items and labour / installation lines: billed amounts
    /// after discounts, kept out of profit. Only when no product / category
    /// filter is set.
    Iterable<(Sale, Money, Qty, String, SaleLineKind)> otherLines() sync* {
      if (lineFilter) return;
      for (final s0 in sales) {
        final rev = s0.lineRevenues();
        for (var i = 0; i < s0.items.length; i++) {
          final it = s0.items[i];
          if (it.isStock) continue;
          yield (s0, rev[i], it.qty, it.lineKey, it.kind);
        }
      }
    }

    Iterable<(ReturnDoc, Money, Money)> returnLines() sync* {
      for (final rt in saleReturns) {
        for (final l in rt.lines) {
          if (!prodOk(l.productId)) continue;
          yield (rt, l.amount, l.cost);
        }
      }
    }

    ExportTable grouped(String title, String keyLabel, String Function(DateTime) key) {
      // [product revenue, cost, non-stock, labour]
      final rows = <String, List<Money>>{};
      final invoices = <String, Set<String>>{};
      List<Money> g0(String kk) => rows.putIfAbsent(kk, () => List.filled(4, const Money.zero()));
      for (final (s0, rev, cogs, _, _) in saleLines()) {
        final kk = key(s0.date);
        final g = g0(kk);
        g[0] = g[0] + rev;
        g[1] = g[1] + cogs;
        (invoices[kk] ??= {}).add(s0.id);
      }
      for (final (s0, rev, _, _, kind) in otherLines()) {
        final kk = key(s0.date);
        final g = g0(kk);
        if (kind == SaleLineKind.service) {
          g[3] = g[3] + rev;
        } else {
          g[2] = g[2] + rev;
        }
        (invoices[kk] ??= {}).add(s0.id);
      }
      for (final (rt, amount, cost) in returnLines()) {
        final g = g0(key(rt.date));
        g[0] = g[0] - amount;
        g[1] = g[1] - cost;
      }
      final keys = rows.keys.toList()..sort();
      final labour = rows.values.any((g) => !g[3].isZero);
      Money tot(int i) => Money.sum(rows.values.map((g) => g[i]));
      return ExportTable(title, [
        keyLabel,
        'Invoices',
        'Net Product Sales',
        'Non-stock Items (not in profit)',
        if (labour) "Labour / Installation (worker's money)",
        if (fin) 'Cost of Goods',
        if (fin) 'Gross Profit (products)',
      ], [
        for (final kk in keys)
          [
            kk,
            invoices[kk]?.length ?? 0,
            _m(rows[kk]![0]),
            _m(rows[kk]![2]),
            if (labour) _m(rows[kk]![3]),
            if (fin) _m(rows[kk]![1]),
            if (fin) _m(rows[kk]![0] - rows[kk]![1]),
          ]
      ], footer: [
        [
          'Total',
          {for (final s in invoices.values) ...s}.length,
          _m(tot(0)),
          _m(tot(2)),
          if (labour) _m(tot(3)),
          if (fin) _m(tot(1)),
          if (fin) _m(tot(0) - tot(1)),
        ]
      ]);
    }

    ExportTable business(String title, String keyLabel, List<(String, DateRange)> periods) {
      final rows = <List<Object?>>[];
      final tot = List<Money>.filled(12, const Money.zero());
      var invoices = 0;
      for (final (label, pr) in periods) {
        final s0 = app.reports.financials(pr);
        final vals = [s0.grossSales, s0.discounts, s0.salesReturns, s0.netSales, s0.cogs, s0.grossProfit, s0.repairProfit, s0.expenses, s0.netOperatingProfit, s0.netCashFromCustomers, s0.nonStockSales, s0.labourOnInvoices];
        for (var i = 0; i < vals.length; i++) {
          tot[i] = tot[i] + vals[i];
        }
        invoices += s0.invoiceCount;
        rows.add([label, s0.invoiceCount, for (final v in vals) _m(v), _m(s0.purchases)]);
      }
      return ExportTable(
        title,
        [keyLabel, 'Invoices', 'Product Sales (gross)', 'Product Discounts', 'Returns', 'Net Product Sales', 'Cost of Goods', 'Gross Profit', 'Repair Profit', 'Expenses', 'Net Operating Profit', 'Cash Received (net)', 'Non-stock Items (not in profit)', "Labour / Installation (worker's money)", 'Purchases'],
        rows,
        footer: [
          ['Total', invoices, for (final v in tot) _m(v), _m(app.reports.purchaseTotal(r))]
        ],
      );
    }

    switch (k) {
      // ── Business overview ────────────────────────────────────────────
      case ReportKind.businessDaily:
        final days = <(String, DateRange)>[];
        for (var d = dayStart(r.from); !d.isAfter(r.to) && days.length < 400; d = DateTime(d.year, d.month, d.day + 1)) {
          days.add(('${d.year}-${_two(d.month)}-${_two(d.day)}', DateRange(d, dayEnd(d))));
        }
        return [business(k.title, 'Date', days)];
      case ReportKind.businessWeekly:
        final weeks = <(String, DateRange)>[];
        var w = dayStart(r.from.subtract(Duration(days: r.from.weekday - 1)));
        while (!w.isAfter(r.to) && weeks.length < 160) {
          final from = w.isBefore(r.from) ? r.from : w;
          final end = dayEnd(w.add(const Duration(days: 6)));
          final to = end.isAfter(r.to) ? r.to : end;
          weeks.add(('Week of ${w.year}-${_two(w.month)}-${_two(w.day)}', DateRange(from, to)));
          w = DateTime(w.year, w.month, w.day + 7);
        }
        return [business(k.title, 'Week (Mon–Sun)', weeks)];
      case ReportKind.businessMonthly:
        final months = <(String, DateRange)>[];
        for (var m0 = DateTime(r.from.year, r.from.month); !m0.isAfter(r.to) && months.length < 120; m0 = DateTime(m0.year, m0.month + 1)) {
          final from = m0.isBefore(r.from) ? r.from : m0;
          final end = dayEnd(DateTime(m0.year, m0.month + 1, 0));
          months.add(('${m0.year}-${_two(m0.month)}', DateRange(from, end.isAfter(r.to) ? r.to : end)));
        }
        return [business(k.title, 'Month', months)];

      // ── Profit & expenses ────────────────────────────────────────────
      case ReportKind.profitLoss:
        final s0 = app.reports.financials(r);
        final summary = ExportTable(k.title, ['Item', 'Amount (PKR)'], [
          ['Shop stock product sales (before discounts)', _m(s0.grossSales)],
          ['Less: Discounts on products (incl. bill discounts)', -_m(s0.discounts)],
          ['Less: Sales Returns', -_m(s0.salesReturns)],
          ['Net Product Sales', _m(s0.netSales)],
          ['Less: Cost of Goods Sold (actual FIFO purchase cost)', -_m(s0.cogs)],
          ['GROSS PROFIT', _m(s0.grossProfit)],
          ['Add: Repair Service Profit (charges − parts cost)', _m(s0.repairProfit)],
          for (final (cat, amt) in s0.expensesByCategory) ['Less: $cat', -_m(amt)],
          ['Total Shop Expenses', -_m(s0.expenses)],
          ['NET OPERATING PROFIT', _m(s0.netOperatingProfit)],
          ['', null],
          ['BILLED BUT NOT SHOP PROFIT — for information', null],
          ['Non-stock items billed (screws, clips, accessories; no recorded cost)', _m(s0.nonStockSales)],
          ['Labour / installation on invoices (worker\'s money, payable by customers)', _m(s0.labourOnInvoices)],
          if (s0.labourBills.count > 0) ['Separate labour bills (worker\'s money): ${s0.labourBills.count}', _m(s0.labourBills.billed)],
          ['Total billed on shop invoices', _m(s0.invoicedTotal)],
          ['', null],
          ['CASH (not profit) — for information', null],
          ['Cash received from customers', _m(s0.cashReceived)],
          ['Less: Refunds paid to customers', -_m(s0.refundsPaid)],
          ['Net cash from customers', _m(s0.netCashFromCustomers)],
          ['Sold on credit in this period (not yet received at the sale)', _m(s0.creditSales)],
          ['Customer balances outstanding at period end', _m(s0.customerOutstanding)],
          ['Purchases in this period (stock bought, not an expense)', _m(s0.purchases)],
          ['Invoices', s0.invoiceCount],
          ['Gross margin on net sales %', s0.marginBp / 100],
        ], footer: [
          ['Unsold stock is not counted as sales; purchases become cost only when the goods are sold.', null],
        ]);
        return [summary, ..._expenseSheets(r, null)];
      case ReportKind.profit:
        final p = app.reports.profit(r);
        return [
          ExportTable(k.title, ['Item', 'Amount'], [
            ['Shop Product Sales (after discounts)', _m(p.grossSales)],
            ['Less: Sales Returns', -_m(p.salesReturns)],
            ['Net Product Sales', _m(p.netSales)],
            ['Less: Cost of Goods Sold (FIFO)', -_m(p.cogs)],
            ['Gross Profit from Sales', _m(p.grossProfit)],
            ['Repair Revenue', _m(p.repairRevenue)],
            ['Less: Repair Parts Cost', -_m(p.repairPartsCost)],
            ['Gross Profit incl. Repairs', _m(p.grossProfitIncludingRepairs)],
            ['Gross Margin on Sales %', p.marginBp / 100],
            ['Invoices', p.invoiceCount],
            ['Non-stock items billed (not in profit)', _m(p.nonStockSales)],
            ['Labour / installation (worker\'s, not in profit)', _m(p.labourOnInvoices)],
          ], footer: [
            ['NOTE: This is GROSS profit — shop expenses are not subtracted. See "Profit & Loss" for net operating profit.', ''],
          ]),
        ];
      case ReportKind.yearlySummary:
        final months = <(String, DateRange)>[];
        for (var m0 = DateTime(r.from.year, r.from.month); !m0.isAfter(r.to) && months.length < 120; m0 = DateTime(m0.year, m0.month + 1)) {
          final from = m0.isBefore(r.from) ? r.from : m0;
          final end = dayEnd(DateTime(m0.year, m0.month + 1, 0));
          months.add((DateFormat('MMM yyyy').format(m0), DateRange(from, end.isAfter(r.to) ? r.to : end)));
        }
        return [business(k.title, 'Month', months), ..._expenseSheets(r, null).skip(1)];
      case ReportKind.expenses:
        return _expenseSheets(r, f.txnType);
      case ReportKind.expensesByCategory:
        return [_expenseSheets(r, f.txnType)[1]];

      // ── Sales ────────────────────────────────────────────────────────
      case ReportKind.salesDaily:
        final fm = DateFormat('yyyy-MM-dd');
        return [grouped(k.title, 'Date', fm.format)];
      case ReportKind.salesMonthly:
        final fm = DateFormat('yyyy-MM');
        return [grouped(k.title, 'Month', fm.format)];
      case ReportKind.salesYearly:
        return [grouped(k.title, 'Year', (d) => '${d.year}')];
      case ReportKind.salesByProduct:
        final rows = <String, ProductSalesRow>{};
        for (final (s0, rev, cogs, qty, pid) in saleLines()) {
          final row = rows.putIfAbsent(pid, () => ProductSalesRow(pid, s0.items.firstWhere((it) => it.lineKey == pid).name));
          row.qty += qty;
          row.revenue += rev;
          row.cogs += cogs;
        }
        for (final rt in saleReturns) {
          for (final l in rt.lines.where((l) => prodOk(l.productId))) {
            final row = rows.putIfAbsent(l.productId, () => ProductSalesRow(l.productId, l.name));
            row.qty -= l.qty;
            row.revenue -= l.amount;
            row.cogs -= l.cost;
          }
        }
        final list = rows.values.toList()..sort((a, b) => b.revenue.compareTo(a.revenue));
        final others = <String, ProductSalesRow>{};
        for (final (s0, rev, qty, key, kind) in otherLines()) {
          final row = others.putIfAbsent(key, () => ProductSalesRow(key, s0.items.firstWhere((it) => it.lineKey == key).name, kind: kind));
          row.qty += qty;
          row.revenue += rev;
        }
        final olist = others.values.toList()..sort((a, b) => b.revenue.compareTo(a.revenue));
        return [
          ExportTable(k.title, ['Product', 'Qty', 'Revenue', if (fin) 'Cost', if (fin) 'Gross Profit'], [
            for (final x in list) [x.name, _q(x.qty), _m(x.revenue), if (fin) _m(x.cogs), if (fin) _m(x.profit)]
          ], footer: [
            ['Total', '', _m(Money.sum(list.map((x) => x.revenue))), if (fin) _m(Money.sum(list.map((x) => x.cogs))), if (fin) _m(Money.sum(list.map((x) => x.profit)))]
          ]),
          if (olist.isNotEmpty)
            ExportTable('Non-stock items & labour (billed, not shop profit)', ['Item', 'Type', 'Qty', 'Billed'], [
              for (final x in olist) [x.name, x.kind == SaleLineKind.service ? 'Labour (worker)' : 'Non-stock item', _q(x.qty), _m(x.revenue)]
            ], footer: [
              ['Total', '', '', _m(Money.sum(olist.map((x) => x.revenue)))]
            ]),
        ];
      case ReportKind.salesByCustomer:
        final m0 = <String, Money>{};
        for (final (s0, rev, _, _, _) in saleLines()) {
          m0[s0.customerName] = (m0[s0.customerName] ?? const Money.zero()) + rev;
        }
        for (final (s0, rev, _, _, kind) in otherLines()) {
          if (kind == SaleLineKind.service) continue; // labour is the worker's
          m0[s0.customerName] = (m0[s0.customerName] ?? const Money.zero()) + rev;
        }
        final list = m0.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
        return [
          ExportTable(k.title, ['Customer', 'Sales'], [for (final e in list) [e.key, _m(e.value)]], footer: [
            ['Total', _m(Money.sum(list.map((e) => e.value)))]
          ]),
        ];
      case ReportKind.salesInvoices:
        return [
          ExportTable(k.title, [
            'Invoice', 'Date', 'Customer', 'Gross Amount', 'Discount', 'Net Total', 'Received', 'Balance', 'Payment Status', 'Non-stock Items', 'Labour (worker)', if (fin) 'Product Cost', if (fin) 'Product Gross Profit',
          ], [
            for (final s0 in sales)
              [
                s0.number,
                s0.date,
                s0.customerName,
                _m(s0.subtotal),
                _m(s0.lineDiscounts + s0.invoiceDiscount),
                _m(s0.total),
                _m(salePaid(s0)),
                _m(s0.total - salePaid(s0)),
                status(s0.total, salePaid(s0)).label,
                _m(s0.nonStockRevenue),
                _m(s0.labourRevenue),
                if (fin) _m(s0.cogs),
                if (fin) _m(s0.productRevenue - s0.cogs),
              ]
          ], footer: [
            [
              'Total (${sales.length})',
              null,
              null,
              _m(Money.sum(sales.map((s0) => s0.subtotal))),
              _m(Money.sum(sales.map((s0) => s0.lineDiscounts + s0.invoiceDiscount))),
              _m(Money.sum(sales.map((s0) => s0.total))),
              _m(Money.sum(sales.map(salePaid))),
              _m(Money.sum(sales.map((s0) => s0.total - salePaid(s0)))),
              null,
              _m(Money.sum(sales.map((s0) => s0.nonStockRevenue))),
              _m(Money.sum(sales.map((s0) => s0.labourRevenue))),
              if (fin) _m(Money.sum(sales.map((s0) => s0.cogs))),
              if (fin) _m(Money.sum(sales.map((s0) => s0.productRevenue - s0.cogs))),
            ]
          ]),
        ];
      case ReportKind.discounts:
        final list = sales.where((s0) => (s0.lineDiscounts + s0.invoiceDiscount).isPositive).toList();
        return [
          ExportTable(k.title, ['Invoice', 'Date', 'Customer', 'Gross Amount', 'Line Discounts', 'Invoice Discount', 'Total Discount', 'Net Total', 'Payment Received'], [
            for (final s0 in list)
              [s0.number, s0.date, s0.customerName, _m(s0.subtotal), _m(s0.lineDiscounts), _m(s0.invoiceDiscount), _m(s0.lineDiscounts + s0.invoiceDiscount), _m(s0.total), _m(salePaid(s0))]
          ], footer: [
            [
              'Total (${list.length})',
              null,
              null,
              _m(Money.sum(list.map((s0) => s0.subtotal))),
              _m(Money.sum(list.map((s0) => s0.lineDiscounts))),
              _m(Money.sum(list.map((s0) => s0.invoiceDiscount))),
              _m(Money.sum(list.map((s0) => s0.lineDiscounts + s0.invoiceDiscount))),
              _m(Money.sum(list.map((s0) => s0.total))),
              _m(Money.sum(list.map(salePaid))),
            ],
            ['A discount reduces the sale price; it is not a payment. "Payment Received" is money actually received against the invoice.', null, null, null, null, null, null, null, null],
          ]),
        ];
      case ReportKind.salesReturns:
      case ReportKind.purchaseReturns:
        final isP = k == ReportKind.purchaseReturns;
        final list = (isP ? app.purchases.returns(from: r.from, to: r.to) : app.sales.returns(from: r.from, to: r.to))
            .where((x) => isP ? (f.supplierId == null || x.partyId == f.supplierId) : (f.customerId == null || x.partyId == f.customerId))
            .where((x) => !lineFilter || x.lines.any((l) => prodOk(l.productId)))
            .toList();
        final pn = isP ? sup : cust;
        return [
          ExportTable(k.title, ['Return', 'Date', 'Original', isP ? 'Supplier' : 'Customer', 'Items', 'Reason', 'Amount'], [
            for (final x in list)
              [x.number, x.date, x.originalNumber, pn[x.partyId] ?? 'Walk-in', x.lines.map((l) => '${l.name} x${l.qty.format()}${l.serials.isEmpty ? '' : ' (${l.serials.map(SerialRecord.displayOf).join(', ')})'}').join('; '), x.reason, _m(x.total)]
          ], footer: [
            ['Total', null, null, null, null, null, _m(Money.sum(list.map((x) => x.total)))]
          ]),
        ];

      // ── Purchases ────────────────────────────────────────────────────
      case ReportKind.purchaseRegister:
        return [
          ExportTable(k.title, ['Purchase', 'Date', 'Supplier', 'Supplier Invoice', 'Items', 'Total', 'Paid', 'Balance', 'Payment Status'], [
            for (final p in purchases)
              [
                p.number,
                p.date,
                sup[p.supplierId] ?? '',
                p.supplierInvoiceNo,
                p.items.length,
                _m(p.total),
                _m(purchasePaid(p)),
                _m(p.total - purchasePaid(p)),
                status(p.total, purchasePaid(p)).label,
              ]
          ], footer: [
            ['Total (${purchases.length})', null, null, null, null, _m(Money.sum(purchases.map((p) => p.total))), _m(Money.sum(purchases.map(purchasePaid))), _m(Money.sum(purchases.map((p) => p.total - purchasePaid(p)))), null]
          ]),
        ];
      case ReportKind.bulkPurchases:
        final lines = <List<Object?>>[];
        final serialRows = <List<Object?>>[];
        var qty = const Qty.zero();
        var net = const Money.zero();
        for (final p in purchases) {
          for (final it in p.items) {
            if (!prodOk(it.productId)) continue;
            if (f.serial != null && !it.serials.any((s0) => _plain(s0) == f.serial)) continue;
            qty += it.qty;
            net += it.net;
            lines.add([p.number, p.date, sup[p.supplierId] ?? '', p.supplierInvoiceNo, it.name, _q(it.qty), if (showCost) _m(it.unitCost), if (showCost) _m(it.discount), if (showCost) _m(it.net), it.serials.length]);
            for (final key in it.serials) {
              if (f.serial != null && _plain(key) != f.serial) continue;
              final rec = app.serials.byKey(key);
              serialRows.add([p.number, p.date, it.name, SerialRecord.displayOf(key), rec?.status.label ?? 'Not found', rec?.customerId == null ? '' : (cust[rec!.customerId] ?? ''), rec?.warrantyExpiry]);
            }
          }
        }
        return [
          ExportTable(k.title, ['Purchase', 'Date', 'Supplier', 'Supplier Invoice', 'Product', 'Qty', if (showCost) 'Unit Cost', if (showCost) 'Discount', if (showCost) 'Line Total', 'Serial Numbers'], lines, footer: [
            ['Total', null, null, null, null, _q(qty), if (showCost) null, if (showCost) null, if (showCost) _m(net), serialRows.length]
          ]),
          ExportTable('Serial Numbers', ['Purchase', 'Date', 'Product', 'Serial', 'Current Status', 'Customer', 'Warranty Until'], serialRows, footer: [
            ['Units: ${serialRows.length}', null, null, null, null, null, null]
          ]),
        ];
      case ReportKind.purchasesBySupplier:
        final m0 = <String, Money>{};
        for (final p in purchases) {
          final v = Money.sum(p.items.where((it) => prodOk(it.productId)).map((it) => it.net));
          final name = sup[p.supplierId] ?? 'Unknown';
          m0[name] = (m0[name] ?? const Money.zero()) + v;
        }
        final list = m0.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
        return [
          ExportTable(k.title, ['Supplier', 'Purchases'], [for (final e in list) [e.key, _m(e.value)]], footer: [
            ['Total', _m(Money.sum(list.map((e) => e.value)))]
          ]),
        ];
      case ReportKind.purchasesMonthly:
        final g = <String, Money>{};
        for (final p in purchases) {
          final kk = '${p.date.year}-${_two(p.date.month)}';
          g[kk] = (g[kk] ?? const Money.zero()) + Money.sum(p.items.where((it) => prodOk(it.productId)).map((it) => it.net));
        }
        final keys = g.keys.toList()..sort();
        return [
          ExportTable(k.title, ['Month', 'Purchases'], [for (final kk in keys) [kk, _m(g[kk]!)]], footer: [
            ['Total', _m(Money.sum(g.values))]
          ]),
        ];

      // ── Products & stock ─────────────────────────────────────────────
      case ReportKind.productList:
        final list = app.catalog.products().where((p) => prodOk(p.id)).toList();
        return [
          ExportTable(k.title, [
            'Product', 'SKU', 'Category', 'Brand', 'Model', 'Unit', if (showCost) 'Purchase Price', 'Selling Price', 'Wholesale Price', 'Stock', 'Minimum', 'Serial Tracked', 'Warranty (months)', 'Barcodes',
          ], [
            for (final p in list)
              [
                p.name,
                p.sku,
                catNames[p.categoryId] ?? '',
                p.brand,
                p.model,
                p.unit,
                if (showCost) _m(p.purchasePrice),
                _m(p.sellingPrice),
                p.wholesalePrice == null ? null : _m(p.wholesalePrice!),
                _q(p.stockQty),
                _q(p.minStock),
                p.requiresSerial ? 'Yes' : 'No',
                p.warrantyMonths,
                p.barcodes.where((b0) => b0 != p.internalCode).join(' '),
              ]
          ], footer: [
            ['Products: ${list.length}', null, null, null, null, null, if (showCost) null, null, null, null, null, null, null, null]
          ]),
        ];
      case ReportKind.stockCurrent:
      case ReportKind.stockLow:
      case ReportKind.stockOut:
      case ReportKind.stockValuation:
        final rows = app.reports.stock(lowOnly: k == ReportKind.stockLow, outOnly: k == ReportKind.stockOut).where((x) => prodOk(x.product.id)).toList();
        final units = app.serials.statusCountsByProduct();
        String u(Product p, SerialStatus s0) => p.requiresSerial ? '${units[p.id]?[s0] ?? 0}' : '';
        return [
          ExportTable(k.title, [
            'Product', 'SKU', 'Unit', 'Available', 'Issued', 'Inspection', 'Damaged', 'Minimum', if (showCost) 'Cost Value (FIFO)', 'Sale Value', 'Sold (units)', 'Installed (units)',
          ], [
            for (final x in rows)
              [
                x.product.name,
                x.product.sku,
                x.product.unit,
                _q(x.product.stockQty),
                _q(x.product.issuedQty),
                _q(x.product.inspectionQty),
                _q(x.product.damagedQty),
                _q(x.product.minStock),
                if (showCost) _m(x.fifoValue),
                _m(x.sellingValue),
                u(x.product, SerialStatus.sold),
                u(x.product, SerialStatus.installed),
              ]
          ], footer: [
            ['Total', null, null, null, null, null, null, null, if (showCost) _m(Money.sum(rows.map((x) => x.fifoValue))), _m(Money.sum(rows.map((x) => x.sellingValue))), null, null]
          ]),
        ];
      case ReportKind.stockMovement:
        final mv = app.reports.movements(r).where((x) => prodOk(x.productId) && (f.txnType == null || x.type == f.txnType)).toList();
        return [
          ExportTable(k.title, ['Date', 'Product', 'Type', 'Bucket', 'Change', 'Before', 'After', 'Reason'], [
            for (final x in mv) [x.at, products[x.productId]?.name ?? '', x.type, x.bucket.label, _q(x.qty), _q(x.before), _q(x.after), x.reason]
          ]),
        ];
      case ReportKind.serials:
        final list = app.serials.search().where((x) {
          if (!prodOk(x.productId)) return false;
          if (f.supplierId != null && x.supplierId != f.supplierId) return false;
          if (f.customerId != null && x.customerId != f.customerId) return false;
          if (f.serial != null && x.serial != f.serial) return false;
          if (f.txnType != null && x.status.name != f.txnType) return false;
          return true;
        }).toList();
        return [
          ExportTable(k.title, ['Serial', 'Brand', 'Product', 'Status', 'Supplier', 'Customer', 'Purchased', 'Warranty Until', 'Purchase', 'Sale', 'Technician'], [
            for (final x in list)
              [
                x.display,
                x.brandKey,
                products[x.productId]?.name ?? '',
                x.status.label,
                sup[x.supplierId] ?? '',
                cust[x.customerId] ?? '',
                x.purchaseDate,
                x.warrantyExpiry,
                x.purchaseId == null ? '' : (app.purchases.byId(x.purchaseId!)?.number ?? ''),
                x.saleId == null ? '' : (app.sales.byId(x.saleId!)?.number ?? ''),
                techs[x.technicianId] ?? '',
              ]
          ], footer: [
            ['Units: ${list.length}', null, null, null, null, null, null, null, null, null, null]
          ]),
        ];

      // ── Accounts ─────────────────────────────────────────────────────
      case ReportKind.customerLedger:
      case ReportKind.supplierLedger:
        final kind = k == ReportKind.customerLedger ? PartyKind.customer : PartyKind.supplier;
        final partyId = kind == PartyKind.customer ? f.customerId : f.supplierId;
        final parties = partyId != null ? [app.parties.byId(kind, partyId)].whereType<Party>().toList() : app.parties.list(kind, includeInactive: true);
        final rows = <List<Object?>>[];
        var debit = const Money.zero();
        var credit = const Money.zero();
        var closing = const Money.zero();
        for (final p in parties) {
          final st = app.parties.statement(kind, p.id, from: r.from, to: r.to);
          final lines = st.lines.where((l) => f.txnType == null || l.entry.type.name == f.txnType).toList();
          if (lines.isEmpty && st.openingBalance.isZero && partyId == null) continue;
          rows.add([r.from, p.name, 'Opening balance', '', '', null, null, _m(st.openingBalance)]);
          for (final l in lines) {
            final e = l.entry;
            debit += e.debit;
            credit += e.credit;
            rows.add([e.at, p.name, _ledgerLabel(e.type), e.refNumber, e.note, _m(e.debit), _m(e.credit), _m(l.runningBalance)]);
          }
          closing += st.closingBalance;
        }
        return [
          ExportTable(k.title, ['Date', kind == PartyKind.customer ? 'Customer' : 'Supplier', 'Type', 'Reference', 'Note', 'Debit', 'Credit', 'Balance'], rows, footer: [
            ['Total', null, null, null, null, _m(debit), _m(credit), _m(closing)],
            [
              kind == PartyKind.customer
                  ? 'Customer: debit = invoiced to the customer, credit = payments, returns, discounts allowed after sale. Balance = amount the customer owes.'
                  : 'Supplier: credit = purchases, debit = payments and returns. Balance = amount the shop owes.',
              null, null, null, null, null, null, null,
            ],
          ]),
        ];
      case ReportKind.receivables:
      case ReportKind.payables:
        final kind = k == ReportKind.receivables ? PartyKind.customer : PartyKind.supplier;
        final id = kind == PartyKind.customer ? f.customerId : f.supplierId;
        final list = app.parties.list(kind, includeInactive: true).where((p) => !p.balance.isZero && (id == null || p.id == id)).toList()
          ..sort((a, b) => b.balance.compareTo(a.balance));
        return [
          ExportTable(k.title, [kind == PartyKind.customer ? 'Customer' : 'Supplier', 'Phone', 'Balance'], [
            for (final p in list) [p.name, p.phone, _m(p.balance)]
          ], footer: [
            ['Total', '', _m(Money.sum(list.map((p) => p.balance)))]
          ]),
        ];
      case ReportKind.payments:
        final list = app.parties.payments(from: r.from, to: r.to).where((p) {
          if (f.customerId != null || f.supplierId != null) {
            final ok = (f.customerId != null && p.partyKind == PartyKind.customer && p.partyId == f.customerId) ||
                (f.supplierId != null && p.partyKind == PartyKind.supplier && p.partyId == f.supplierId);
            if (!ok) return false;
          }
          if (f.txnType != null && p.direction.name != f.txnType) return false;
          return true;
        }).toList();
        String who(Payment p) => p.partyId == null ? 'Walk-in' : (p.partyKind == PartyKind.customer ? cust[p.partyId] : sup[p.partyId]) ?? '';
        final live = list.where((p) => !p.voided);
        return [
          ExportTable(k.title, ['No', 'Date', 'Account', 'Direction', 'Method', 'Reference', 'Amount', 'Status', 'Account Type'], [
            for (final p in list)
              [p.number, p.at, who(p), p.direction == PaymentDirection.received ? 'Received' : 'Paid out', p.method.label, p.refType, _m(p.amount), p.voided ? 'VOID' : '', p.partyKind?.name ?? 'walk-in']
          ], footer: [
            ['Received', null, null, null, null, null, _m(Money.sum(live.where((p) => p.direction == PaymentDirection.received).map((p) => p.amount))), null, null],
            ['Paid', null, null, null, null, null, _m(Money.sum(live.where((p) => p.direction == PaymentDirection.paid).map((p) => p.amount))), null, null],
          ]),
        ];

      // ── Technicians ──────────────────────────────────────────────────
      case ReportKind.techIssued:
      case ReportKind.techReturned:
      case ReportKind.techUsed:
        final types = switch (k) {
          ReportKind.techIssued => {TechTxnType.issue},
          ReportKind.techUsed => {TechTxnType.installed},
          _ => {TechTxnType.returnUnused, TechTxnType.returnUsed, TechTxnType.returnDamaged, TechTxnType.returnFaulty},
        };
        final list = app.technicians
            .history(technicianId: f.technicianId)
            .where((t) => types.contains(t.type) && r.contains(t.at) && prodOk(t.productId) && (f.customerId == null || t.customerId == f.customerId) && serialOk(t.serials))
            .toList();
        return [
          ExportTable(k.title, ['Date', 'Technician', 'Type', 'Product', 'Qty', 'Job', 'Customer', 'Cost Value', 'Serials'], [
            for (final t in list) [t.at, techs[t.technicianId] ?? '', t.type.label, t.productName, _q(t.qty), t.jobRef, cust[t.customerId] ?? '', _m(t.cost), t.serials.map(SerialRecord.displayOf).join(', ')]
          ], footer: [
            ['Total', null, null, null, _q(Qty.sum(list.map((t) => t.qty))), null, null, _m(Money.sum(list.map((t) => t.cost))), null]
          ]),
        ];
      case ReportKind.techPending:
        final hs = app.technicians.holdings().where((h) => (f.technicianId == null || h.technicianId == f.technicianId) && prodOk(h.productId)).toList();
        return [
          ExportTable(k.title, ['Technician', 'Product', 'Qty Held', 'Cost Value'], [
            for (final h in hs) [techs[h.technicianId] ?? '', products[h.productId]?.name ?? '', _q(h.qty), _m(h.cost)]
          ], footer: [
            ['Total', '', '', _m(Money.sum(hs.map((h) => h.cost)))]
          ]),
        ];

      // ── Warranty ─────────────────────────────────────────────────────
      case ReportKind.warrantyActive:
      case ReportKind.warrantyExpired:
        final list = app.warranty
            .all(state: k == ReportKind.warrantyActive ? WarrantyState.active : WarrantyState.expired)
            .where((w) => prodOk(w.serial.productId) && (f.customerId == null || w.serial.customerId == f.customerId) && (f.serial == null || w.serial.serial == f.serial))
            .toList();
        return [
          ExportTable(k.title, ['Serial', 'Product', 'Customer', 'Start', 'Expiry', 'Days Left'], [
            for (final w in list) [w.serial.display, w.product?.name ?? '', cust[w.serial.customerId] ?? '', w.serial.warrantyStart, w.serial.warrantyExpiry, w.daysLeft]
          ]),
        ];
      case ReportKind.warrantyClaims:
        final list = app.warranty
            .claims()
            .where((x) => r.contains(x.date) && prodOk(x.productId) && (f.customerId == null || x.customerId == f.customerId) && serialOk([x.serial]) && (f.txnType == null || x.status.name == f.txnType))
            .toList();
        return [
          ExportTable(k.title, ['Claim', 'Date', 'Serial', 'Product', 'Customer', 'Issue', 'Status', 'Resolution'], [
            for (final x in list) [x.number, x.date, SerialRecord.displayOf(x.serial), products[x.productId]?.name ?? '', cust[x.customerId] ?? '', x.issue, x.status.name, x.resolution]
          ]),
        ];

      // ── Repairs & faulty ─────────────────────────────────────────────
      case ReportKind.repairsPending:
      case ReportKind.repairsCompleted:
        final list = app.repairs
            .list()
            .where((j) => k == ReportKind.repairsPending ? j.status.isOpen : (!j.status.isOpen && j.deliveryDate != null && r.contains(j.deliveryDate!)))
            .where((j) =>
                (f.technicianId == null || j.technicianId == f.technicianId) &&
                (f.customerId == null || j.customerId == f.customerId) &&
                (f.serial == null || normalizeCode(j.serial) == f.serial) &&
                (f.txnType == null || j.status.name == f.txnType))
            .toList();
        return [
          ExportTable(k.title, ['Job', 'Received', 'Customer', 'Device', 'Technician', 'Status', 'Charges', 'Delivered', 'Serial', 'Under Warranty'], [
            for (final j in list) [j.number, j.receivedDate, j.customerName, j.productName, techs[j.technicianId] ?? '', j.status.label, _m(j.totalCharges), j.deliveryDate, j.serial, j.underWarranty ? 'Yes' : 'No']
          ], footer: [
            ['Total', null, null, null, null, null, _m(Money.sum(list.map((j) => j.totalCharges))), null, null, null]
          ]),
        ];
      case ReportKind.faultyStock:
        final rows = <List<Object?>>[];
        for (final x in app.serials.search()) {
          if (!_faulty.contains(x.status) || !prodOk(x.productId)) continue;
          if (f.serial != null && x.serial != f.serial) continue;
          if (f.txnType != null && x.status.name != f.txnType) continue;
          final last = x.history.isEmpty ? null : x.history.last;
          rows.add([products[x.productId]?.name ?? '', x.display, x.status.label, 1.0, last?.at, last?.note ?? '', cust[x.customerId] ?? '']);
        }
        if (f.serial == null && f.txnType == null) {
          for (final p in products.values.where((p) => !p.requiresSerial && !p.archived && prodOk(p.id))) {
            if (p.damagedQty.isPositive) rows.add([p.name, '', 'Damaged', _q(p.damagedQty), null, '', '']);
            if (p.inspectionQty.isPositive) rows.add([p.name, '', 'Awaiting Inspection', _q(p.inspectionQty), null, '', '']);
            if (p.repairableQty.isPositive) rows.add([p.name, '', 'Repairable (Not Sellable)', _q(p.repairableQty), null, '', '']);
          }
        }
        return [
          ExportTable(k.title, ['Product', 'Serial', 'Condition', 'Qty', 'Since', 'Note', 'Customer'], rows, footer: [
            ['Not sellable — not counted in available stock.', null, null, rows.fold<double>(0, (a, x) => a + (x[3] as double)), null, null, null]
          ]),
        ];
    }
  }

  /// Expense list + category summary (+ monthly totals) for [r].
  List<ExportTable> _expenseSheets(DateRange r, String? category) {
    final list = app.expenses.list(from: r.from, to: r.to, category: category).reversed.toList();
    final total = Money.sum(list.map((e) => e.amount));
    final cats = <String, (Money, int)>{};
    for (final e in list) {
      final c0 = cats[e.category] ?? (const Money.zero(), 0);
      cats[e.category] = (c0.$1 + e.amount, c0.$2 + 1);
    }
    final catRows = cats.entries.toList()..sort((a, b) => b.value.$1.compareTo(a.value.$1));
    return [
      ExportTable('Expenses', ['No', 'Date', 'Category', 'Title', 'Description', 'Payment Method', 'Amount', 'Receipt'], [
        for (final e in list) [e.number, e.date, e.category, e.title, e.description, e.method.label, _m(e.amount), (e.receiptPath ?? '').isEmpty ? '' : 'Yes']
      ], footer: [
        ['Total (${list.length})', null, null, null, null, null, _m(total), null]
      ]),
      ExportTable('Expenses by Category', ['Category', 'Entries', 'Amount', 'Share %'], [
        for (final e in catRows) [e.key, e.value.$2, _m(e.value.$1), total.isZero ? 0.0 : (e.value.$1.paisa * 10000 ~/ total.paisa) / 100]
      ], footer: [
        ['Total', list.length, _m(total), total.isZero ? 0.0 : 100.0]
      ]),
    ];
  }

  /// Received (or paid) payments per document id (not void).
  Map<String, Money> _paymentsByRef(PaymentDirection dir) {
    final m0 = <String, Money>{};
    for (final p in app.ctx.all(Boxes.payments, Payment.fromJson)) {
      if (p.voided || p.direction != dir || p.refId.isEmpty) continue;
      if (dir == PaymentDirection.received && p.refType != 'sale') continue;
      if (dir == PaymentDirection.paid && p.refType != 'purchase') continue;
      m0[p.refId] = (m0[p.refId] ?? const Money.zero()) + p.amount;
    }
    return m0;
  }

  static String _plain(String keyOrSerial) {
    if (!SerialRecord.isKey(keyOrSerial)) return normalizeCode(keyOrSerial);
    return keyOrSerial.split('|')[1];
  }
}

/// Count of rows in a box (used by Settings > Data overview).
int boxCount(AppServices app, String box) => app.ctx.store.count(box);
const dataBoxesForOverview = [Boxes.products, Boxes.serials, Boxes.sales, Boxes.purchases, Boxes.customers, Boxes.suppliers, Boxes.payments, Boxes.ledger, Boxes.expenses, Boxes.stockMovements, Boxes.auditLogs];

/// Report with no data is still a valid (empty) table: used by tests.
bool isEmptyReport(ExportTable t) => t.rows.isEmpty;
