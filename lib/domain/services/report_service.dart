import '../../core/money.dart';
import '../../core/qty.dart';
import '../../data/store/data_store.dart';
import '../models/documents.dart';
import '../models/expense.dart';
import '../models/json_utils.dart';
import '../models/operations.dart';
import '../models/party.dart';
import '../models/product.dart';
import 'context.dart';
import 'inventory_engine.dart';
import 'party_service.dart';

class DateRange {
  final DateTime from;
  final DateTime to;
  const DateRange(this.from, this.to);

  static DateRange today(DateTime now) => DateRange(dayStart(now), dayEnd(now));
  static DateRange thisWeek(DateTime now) {
    final start = dayStart(now.subtract(Duration(days: now.weekday - 1)));
    return DateRange(start, dayEnd(now));
  }

  static DateRange thisMonth(DateTime now) => DateRange(DateTime(now.year, now.month), dayEnd(now));
  static DateRange lastMonth(DateTime now) => DateRange(DateTime(now.year, now.month - 1), dayEnd(DateTime(now.year, now.month, 0)));
  static DateRange thisYear(DateTime now) => DateRange(DateTime(now.year), dayEnd(now));

  bool contains(DateTime d) => !d.isBefore(from) && !d.isAfter(to);
}

/// Gross profit summary. Operating expenses (rent, salaries, electricity)
/// are not recorded in this system, so this is profit BEFORE expenses.
class ProfitSummary {
  final Money grossSales; // completed invoices, after discounts
  final Money salesReturns;
  final Money netSales;
  final Money cogs; // cost of goods sold (FIFO) minus cost of returned goods
  final Money grossProfit;
  final Money repairRevenue;
  final Money repairPartsCost;
  final int invoiceCount;
  const ProfitSummary({
    required this.grossSales,
    required this.salesReturns,
    required this.netSales,
    required this.cogs,
    required this.grossProfit,
    required this.repairRevenue,
    required this.repairPartsCost,
    required this.invoiceCount,
  });

  Money get grossProfitIncludingRepairs => grossProfit + repairRevenue - repairPartsCost;

  /// Gross margin in basis points (e.g. 2500 = 25%).
  int get marginBp => netSales.isZero ? 0 : (grossProfit.paisa * 10000 ~/ netSales.paisa);
}

/// Profit & loss for a period.
///
///   Gross sales (before discounts)
///   − sales discounts (line + invoice)
///   − sales returns
///   = net sales
///   − cost of goods sold (actual FIFO purchase cost of the units sold,
///     less the cost of units returned)
///   = GROSS PROFIT
///   + repair service profit (charges − parts cost)
///   − shop expenses
///   = NET OPERATING PROFIT
///
/// Cash received is shown separately: credit sales count as sales when
/// invoiced, but only payments actually received count as cash.
class FinancialSummary {
  final DateRange range;
  final int invoiceCount;
  final Money grossSales;
  final Money discounts;
  final Money salesReturns;
  final Money cogs;
  final Money repairCharges;
  final Money repairPartsCost;
  final Money expenses;
  final List<(String, Money)> expensesByCategory;
  final Money cashReceived; // from customers / walk-in, not void
  final Money refundsPaid; // cash refunds to customers
  final Money creditSales; // invoiced amount not paid at the time of sale
  final Money purchases;
  final Money customerOutstanding; // as of the end of the period
  const FinancialSummary({
    required this.range,
    required this.invoiceCount,
    required this.grossSales,
    required this.discounts,
    required this.salesReturns,
    required this.cogs,
    required this.repairCharges,
    required this.repairPartsCost,
    required this.expenses,
    required this.expensesByCategory,
    required this.cashReceived,
    required this.refundsPaid,
    required this.creditSales,
    required this.purchases,
    required this.customerOutstanding,
  });

  Money get netSales => grossSales - discounts - salesReturns;
  Money get grossProfit => netSales - cogs;
  Money get repairProfit => repairCharges - repairPartsCost;
  Money get netOperatingProfit => grossProfit + repairProfit - expenses;
  Money get netCashFromCustomers => cashReceived - refundsPaid;

  /// Gross margin in basis points of net sales.
  int get marginBp => netSales.isZero ? 0 : grossProfit.paisa * 10000 ~/ netSales.paisa;
}

class ProductSalesRow {
  final String productId;
  final String name;
  Qty qty = const Qty.zero();
  Money revenue = const Money.zero();
  Money cogs = const Money.zero();
  ProductSalesRow(this.productId, this.name);
  Money get profit => revenue - cogs;
}

class MonthPoint {
  final DateTime month;
  final Money sales;
  final Money purchases;
  final Money grossProfit;
  const MonthPoint(this.month, this.sales, this.purchases, this.grossProfit);
}

class StockRow {
  final Product product;
  final Money fifoValue;
  final Money sellingValue;
  const StockRow(this.product, this.fifoValue, this.sellingValue);
}

class ReportService {
  final ServiceContext ctx;
  final InventoryEngine inv;
  final PartyService parties;
  ReportService(this.ctx, this.inv, this.parties);

  Iterable<Sale> _sales(DateRange r) =>
      ctx.all(Boxes.sales, Sale.fromJson).where((x) => x.status == DocStatus.completed && r.contains(x.date));

  Iterable<ReturnDoc> _salesReturns(DateRange r) => ctx.all(Boxes.salesReturns, ReturnDoc.fromJson).where((x) => r.contains(x.date));

  Iterable<Purchase> purchases(DateRange r) =>
      ctx.all(Boxes.purchases, Purchase.fromJson).where((x) => x.status == DocStatus.completed && r.contains(x.date));

  ProfitSummary profit(DateRange r) {
    final sales = _sales(r).toList();
    final returns = _salesReturns(r).toList();
    final gross = Money.sum(sales.map((x) => x.total));
    final ret = Money.sum(returns.map((x) => x.total));
    final cogs = Money.sum(sales.map((x) => x.cogs)) - Money.sum(returns.map((x) => x.costTotal));
    final repairs = ctx.all(Boxes.repairs, RepairJob.fromJson)
        .where((j) => j.status == RepairStatus.delivered && j.deliveryDate != null && r.contains(j.deliveryDate!))
        .toList();
    final net = gross - ret;
    return ProfitSummary(
      grossSales: gross,
      salesReturns: ret,
      netSales: net,
      cogs: cogs,
      grossProfit: net - cogs,
      repairRevenue: Money.sum(repairs.map((j) => j.totalCharges)),
      repairPartsCost: Money.sum(repairs.map((j) => j.partsCost)),
      invoiceCount: sales.length,
    );
  }

  /// Full profit & loss for [r] (see [FinancialSummary]).
  FinancialSummary financials(DateRange r) {
    final sales = _sales(r).toList();
    final returns = _salesReturns(r).toList();
    final repairs = ctx.all(Boxes.repairs, RepairJob.fromJson)
        .where((j) => j.status == RepairStatus.delivered && j.deliveryDate != null && r.contains(j.deliveryDate!))
        .toList();
    final expenses = ctx.all(Boxes.expenses, Expense.fromJson).where((e) => !e.deleted && r.contains(e.date)).toList();
    final byCat = <String, Money>{};
    for (final e in expenses) {
      byCat[e.category] = (byCat[e.category] ?? const Money.zero()) + e.amount;
    }
    // A cancelled invoice's payment and its refund cancel out: both are left
    // out so cash received is not inflated by sales that never happened.
    final cancelled = {for (final s0 in ctx.all(Boxes.sales, Sale.fromJson)) if (s0.status == DocStatus.cancelled) s0.id};
    final pays = ctx.all(Boxes.payments, Payment.fromJson)
        .where((p) => !p.voided && r.contains(p.at) && p.partyKind != PartyKind.supplier && !cancelled.contains(p.refId));
    var received = const Money.zero();
    var refunds = const Money.zero();
    for (final p in pays) {
      if (p.direction == PaymentDirection.received) {
        received += p.amount;
      } else {
        refunds += p.amount;
      }
    }
    var outstanding = const Money.zero();
    for (final e in ctx.all(Boxes.ledger, LedgerEntry.fromJson)) {
      if (e.partyKind == PartyKind.customer && !e.at.isAfter(r.to)) outstanding += e.debit - e.credit;
    }
    return FinancialSummary(
      range: r,
      invoiceCount: sales.length,
      grossSales: Money.sum(sales.map((x) => x.subtotal)),
      discounts: Money.sum(sales.map((x) => x.lineDiscounts + x.invoiceDiscount)),
      salesReturns: Money.sum(returns.map((x) => x.total)),
      cogs: Money.sum(sales.map((x) => x.cogs)) - Money.sum(returns.map((x) => x.costTotal)),
      repairCharges: Money.sum(repairs.map((j) => j.totalCharges)),
      repairPartsCost: Money.sum(repairs.map((j) => j.partsCost)),
      expenses: Money.sum(expenses.map((e) => e.amount)),
      expensesByCategory: byCat.entries.map((e) => (e.key, e.value)).toList()..sort((a, b) => b.$2.compareTo(a.$2)),
      cashReceived: received,
      refundsPaid: refunds,
      creditSales: Money.sum(sales.map((x) => x.remaining.isNegative ? const Money.zero() : x.remaining)),
      purchases: purchaseTotal(r),
      customerOutstanding: outstanding,
    );
  }

  /// One [FinancialSummary] per calendar month of [year] (up to [upTo]).
  List<FinancialSummary> yearByMonth(int year, {DateTime? upTo}) {
    final last = upTo ?? ctx.now();
    return [
      for (var mo = 1; mo <= 12; mo++)
        if (DateTime(year, mo).isBefore(last) || (year == last.year && mo == last.month))
          financials(DateRange(DateTime(year, mo), dayEnd(DateTime(year, mo + 1, 0)))),
    ];
  }

  Money salesTotal(DateRange r) => Money.sum(_sales(r).map((x) => x.total)) - Money.sum(_salesReturns(r).map((x) => x.total));
  Money purchaseTotal(DateRange r) => Money.sum(purchases(r).map((x) => x.total));

  List<ProductSalesRow> productSales(DateRange r) {
    final rows = <String, ProductSalesRow>{};
    for (final sale in _sales(r)) {
      for (var k = 0; k < sale.items.length; k++) {
        final it = sale.items[k];
        final row = rows.putIfAbsent(it.productId, () => ProductSalesRow(it.productId, it.name));
        row.qty += it.qty;
        row.revenue += sale.lineRevenue(k);
        row.cogs += it.cogs;
      }
    }
    for (final ret in _salesReturns(r)) {
      for (final l in ret.lines) {
        final row = rows.putIfAbsent(l.productId, () => ProductSalesRow(l.productId, l.name));
        row.qty -= l.qty;
        row.revenue -= l.amount;
        row.cogs -= l.cost;
      }
    }
    return rows.values.toList()..sort((a, b) => b.revenue.compareTo(a.revenue));
  }

  Map<String, Money> customerSales(DateRange r) {
    final out = <String, Money>{};
    for (final sale in _sales(r)) {
      out[sale.customerName] = (out[sale.customerName] ?? const Money.zero()) + sale.total;
    }
    return out;
  }

  Map<String, Money> supplierPurchases(DateRange r) {
    final out = <String, Money>{};
    for (final p in purchases(r)) {
      final name = parties.byId(PartyKind.supplier, p.supplierId)?.name ?? 'Unknown';
      out[name] = (out[name] ?? const Money.zero()) + p.total;
    }
    return out;
  }

  /// Last [months] months including the current one, oldest first.
  List<MonthPoint> monthly(int months) {
    final now = ctx.now();
    final out = <MonthPoint>[];
    for (var k = months - 1; k >= 0; k--) {
      final start = DateTime(now.year, now.month - k);
      final end = dayEnd(DateTime(start.year, start.month + 1, 0));
      final r = DateRange(start, end);
      final pr = profit(r);
      out.add(MonthPoint(start, pr.netSales, purchaseTotal(r), pr.grossProfit));
    }
    return out;
  }

  List<StockRow> stock({bool lowOnly = false, bool outOnly = false}) {
    final layers = <String, Money>{};
    for (final l in ctx.all(Boxes.costLayers, CostLayer.fromJson)) {
      if (l.qtyRemaining.isPositive) layers[l.productId] = (layers[l.productId] ?? const Money.zero()) + l.unitCost.timesQty(l.qtyRemaining);
    }
    return ctx.all(Boxes.products, Product.fromJson)
        .where((p) => !p.archived)
        .where((p) => !lowOnly || p.isLowStock)
        .where((p) => !outOnly || p.isOutOfStock)
        .map((p) => StockRow(p, layers[p.id] ?? const Money.zero(), p.sellingPrice.timesQty(p.stockQty.isNegative ? const Qty.zero() : p.stockQty)))
        .toList()
      ..sort((a, b) => a.product.name.compareTo(b.product.name));
  }

  /// Stock value (FIFO cost) by category — comparable across units.
  Map<String, Money> stockValueByCategory() {
    final cats = {for (final c in ctx.all(Boxes.categories, ProductCategory.fromJson)) c.id: c.name};
    final prodCat = {for (final p in ctx.all(Boxes.products, Product.fromJson)) p.id: cats[p.categoryId] ?? 'Uncategorised'};
    final out = <String, Money>{};
    for (final l in ctx.all(Boxes.costLayers, CostLayer.fromJson)) {
      if (!l.qtyRemaining.isPositive) continue;
      final name = prodCat[l.productId] ?? 'Uncategorised';
      out[name] = (out[name] ?? const Money.zero()) + l.unitCost.timesQty(l.qtyRemaining);
    }
    return out;
  }

  // The movement log is not kept in the read cache (largest box, rarely read).
  List<StockMovement> movements(DateRange r, {String? productId}) => ctx.store
      .values(Boxes.stockMovements)
      .map(StockMovement.fromJson)
      .where((m0) => r.contains(m0.at) && (productId == null || m0.productId == productId))
      .toList()
    ..sort((a, b) => b.at.compareTo(a.at));
}
