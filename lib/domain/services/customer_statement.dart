import '../../core/errors.dart';
import '../../core/money.dart';
import '../../core/qty.dart';
import '../../data/store/data_store.dart';
import '../models/documents.dart';
import '../models/json_utils.dart';
import '../models/operations.dart';
import '../models/party.dart';
import '../models/product.dart';
import 'context.dart';
import 'party_service.dart';

/// Period choices on the customer statement screen.
enum StatementPeriod { complete, thisMonth, previousMonth, custom }

extension StatementPeriodLabel on StatementPeriod {
  String get label => switch (this) {
        StatementPeriod.complete => 'Complete history',
        StatementPeriod.thisMonth => 'This month',
        StatementPeriod.previousMonth => 'Previous month',
        StatementPeriod.custom => 'Custom date range',
      };
}

/// What a statement row is. Only "posting" rows (one per ledger entry)
/// carry debit / credit / running balance; item rows show the detail.
enum StmtRowKind {
  opening,
  saleItem,
  invoiceDiscount,
  invoiceTotal,
  payment,
  refund,
  paymentVoid,
  invoiceCancel,
  invoiceEdit,
  editItem,
  returnItem,
  returnTotal,
  repairItem,
  repairTotal,
  adjustment,
  other,
}

class StmtRow {
  final StmtRowKind kind;
  final DateTime? date;
  final String voucher;
  final String description;
  final Qty? qty;
  final Money? unitPrice;
  final Money? totalPrice;
  final Money debit;
  final Money credit;

  /// Running balance after this row; set on posting rows only.
  final Money? balance;

  const StmtRow({
    required this.kind,
    this.date,
    this.voucher = '',
    required this.description,
    this.qty,
    this.unitPrice,
    this.totalPrice,
    this.debit = const Money.zero(),
    this.credit = const Money.zero(),
    this.balance,
  });

  bool get isPosting => balance != null;
}

enum InvoiceState { paid, partlyPaid, unpaid, cancelled }

extension InvoiceStateLabel on InvoiceState {
  String get label => switch (this) {
        InvoiceState.paid => 'Paid',
        InvoiceState.partlyPaid => 'Partly paid',
        InvoiceState.unpaid => 'Unpaid',
        InvoiceState.cancelled => 'Cancelled',
      };
}

/// One invoice in the statement with what was paid against it.
class InvoiceStatus {
  final String saleId;
  final String number;
  final DateTime date;
  final Money total;
  final Money returns; // value of goods returned against it
  final Money paid; // payments against this invoice, less refunds
  final Money due; // total - returns - paid (negative = paid in excess)
  final InvoiceState state;
  const InvoiceStatus(this.saleId, this.number, this.date, this.total, this.returns, this.paid, this.due, this.state);
}

/// One returned product line, for the statement's returns register.
class StatementReturn {
  final String returnId;
  final DateTime date;
  final String number; // return voucher
  final String invoiceNumber; // original invoice
  final String productName;
  final List<String> serials;
  final Qty qty;
  final Money amount;
  final String reason;
  final String condition; // resellable | faulty | damaged | inspect
  final RefundMode refundMode;
  const StatementReturn({
    required this.returnId,
    required this.date,
    required this.number,
    required this.invoiceNumber,
    required this.productName,
    required this.serials,
    required this.qty,
    required this.amount,
    required this.reason,
    required this.condition,
    required this.refundMode,
  });
}

class CustomerStatement {
  final Party customer;
  final DateTime? from;
  final DateTime? to;
  final DateTime generatedAt;
  final StatementPeriod period;
  final Money openingBalance;
  final List<StmtRow> rows; // the opening row first
  final Money totalDebit; // goods sold, repair charges, refunds, voided payments, debit adjustments
  final Money totalPayments; // payments received (credit)
  final Money totalReturnsAdjustments; // returns, cancelled invoices, credit adjustments (credit)
  final Money totalReturns; // part of [totalReturnsAdjustments]: customer returns only
  final List<StatementReturn> returns; // every returned line in the period
  final Money closingBalance;
  final Money onAccountPayments; // received, not against a specific invoice
  final List<InvoiceStatus> invoices;

  /// The customer's balance in the ledger (all entries, no period).
  final Money accountBalance;

  const CustomerStatement({
    required this.customer,
    required this.from,
    required this.to,
    required this.generatedAt,
    required this.period,
    required this.openingBalance,
    required this.rows,
    required this.totalDebit,
    required this.totalPayments,
    required this.totalReturnsAdjustments,
    required this.totalReturns,
    required this.returns,
    required this.closingBalance,
    required this.onAccountPayments,
    required this.invoices,
    required this.accountBalance,
  });

  Money get totalCredit => totalPayments + totalReturnsAdjustments;

  /// Cancelled invoices and credit adjustments (credit), without returns.
  Money get totalOtherCredits => totalReturnsAdjustments - totalReturns;

  /// True when the statement runs to today, so its closing balance must
  /// equal the customer's balance in the software.
  bool get coversToday => to == null || !to!.isBefore(dayStart(generatedAt));
}

/// Builds a detailed customer statement from the saved ledger: every
/// invoice with its product lines, every payment, return, refund,
/// cancellation, repair charge and adjustment, with a running balance.
///
/// The ledger is the only source of the amounts, so the closing balance is
/// the customer's real balance; documents only add the detail lines.
class CustomerStatementService {
  final ServiceContext ctx;
  final PartyService parties;
  CustomerStatementService(this.ctx, this.parties);

  /// The date range for a period choice. Custom uses [from] / [to].
  static (DateTime?, DateTime?) rangeFor(StatementPeriod p, DateTime now, {DateTime? from, DateTime? to}) => switch (p) {
        StatementPeriod.complete => (null, null),
        StatementPeriod.thisMonth => (DateTime(now.year, now.month, 1), dayStart(now)),
        StatementPeriod.previousMonth => (DateTime(now.year, now.month - 1, 1), DateTime(now.year, now.month, 0)),
        StatementPeriod.custom => (from == null ? null : dayStart(from), to == null ? null : dayStart(to)),
      };

  CustomerStatement build(String customerId, {StatementPeriod period = StatementPeriod.complete, DateTime? from, DateTime? to}) {
    final customer = parties.byId(PartyKind.customer, customerId);
    if (customer == null) throw const NotFoundException('Customer not found.');
    final now = ctx.now();
    final (f, t) = rangeFor(period, now, from: from, to: to);
    if (f != null && t != null && t.isBefore(f)) throw const ValidationException('The end date is before the start date.');

    final sales = {for (final s in ctx.all(Boxes.sales, Sale.fromJson)) s.id: s};
    final payments = {for (final p in ctx.all(Boxes.payments, Payment.fromJson)) p.id: p};
    final returns = {for (final r in ctx.all(Boxes.salesReturns, ReturnDoc.fromJson)) r.id: r};
    final repairs = {for (final r in ctx.all(Boxes.repairs, RepairJob.fromJson)) r.id: r};
    final products = {for (final p in ctx.all(Boxes.products, Product.fromJson)) p.id: p};

    final entries = parties.entries(PartyKind.customer, customerId);
    final accountBalance = Money.sum(entries.map((e) => e.balanceEffect));

    bool after(DateTime at) => t != null && at.isAfter(dayEnd(t));
    bool before(DateTime at) => f != null && at.isBefore(dayStart(f));

    // Opening: everything before the period, plus the account's own
    // opening-balance entry.
    var opening = const Money.zero();
    var hadOpeningEntry = false;
    for (final e in entries) {
      if (after(e.at)) continue;
      if (before(e.at) || e.type == LedgerType.opening) {
        opening += e.balanceEffect;
        if (e.type == LedgerType.opening) hadOpeningEntry = true;
      }
    }

    final rows = <StmtRow>[
      StmtRow(
        kind: StmtRowKind.opening,
        date: f,
        description: f == null
            ? (hadOpeningEntry ? 'Opening balance' : 'Opening balance (none)')
            : 'Balance brought forward on ${_dmy(f)}${hadOpeningEntry ? ' (includes opening balance)' : ''}',
        debit: opening.isPositive ? opening : const Money.zero(),
        credit: opening.isNegative ? -opening : const Money.zero(),
        balance: opening,
      ),
    ];

    var running = opening;
    var debit = const Money.zero();
    var paymentsIn = const Money.zero();
    var otherCredit = const Money.zero();
    var onAccount = const Money.zero();
    var returnCredit = const Money.zero();
    final returnLines = <StatementReturn>[];
    final invoiceIds = <String>[];

    String productDetail(String productId, String name) {
      final p = products[productId];
      if (p == null) return name;
      final extra = <String>[];
      final lower = name.toLowerCase();
      if (p.brand.trim().isNotEmpty && !lower.contains(p.brand.trim().toLowerCase())) extra.add(p.brand.trim());
      if (p.model.trim().isNotEmpty && !lower.contains(p.model.trim().toLowerCase())) extra.add('Model ${p.model.trim()}');
      final d = p.description.trim().replaceAll(RegExp(r'\s+'), ' ');
      if (d.isNotEmpty) extra.add(d.length > 90 ? '${d.substring(0, 87)}...' : d);
      return extra.isEmpty ? name : '$name\n${extra.join(' - ')}';
    }

    String serialText(List<String> keys) => keys.isEmpty ? '' : '\nS/N: ${keys.map(SerialRecord.displayOf).join(', ')}';

    String lineText(SaleItem it) {
      final disc = it.discount.isPositive ? '\nLess item discount ${_amt(it.discount)}' : '';
      final tag = switch (it.kind) {
        SaleLineKind.product => '',
        SaleLineKind.nonStock => ' (non-stock item${it.unit.isEmpty ? '' : ', ${it.unit}'})',
        SaleLineKind.service => ' (labour / installation${it.unit.isEmpty ? '' : ', ${it.unit}'}${it.worker.isEmpty ? '' : ', ${it.worker}'})',
      };
      final name = it.isStock ? productDetail(it.productId, it.name) : it.name;
      return '$name$tag${serialText(it.serials)}$disc';
    }

    /// What one edit changed, line by line; the totals add up to the change
    /// in the invoice total.
    List<StmtRow> editRows(Sale s, SaleEdit ed, DateTime at) {
      final out = <StmtRow>[];
      final before = <String, List<SaleItem>>{};
      final after = <String, List<SaleItem>>{};
      for (final it in ed.beforeItems) {
        (before[it.lineKey] ??= []).add(it);
      }
      for (final it in ed.afterItems) {
        (after[it.lineKey] ??= []).add(it);
      }
      for (final key in {...before.keys, ...after.keys}) {
        final b = before[key] ?? const <SaleItem>[];
        final a = after[key] ?? const <SaleItem>[];
        final bQty = Qty.sum(b.map((e) => e.qty));
        final aQty = Qty.sum(a.map((e) => e.qty));
        final bNet = Money.sum(b.map((e) => e.net));
        final aNet = Money.sum(a.map((e) => e.net));
        final bSer = b.expand((e) => e.serials).toList();
        final aSer = a.expand((e) => e.serials).toList();
        if (bQty == aQty && bNet == aNet && bSer.toSet().containsAll(aSer) && aSer.toSet().containsAll(bSer)) continue;
        final ref = (a.isNotEmpty ? a : b).first;
        String label;
        if (b.isEmpty) {
          label = 'Added: ${lineText(ref)}';
        } else if (a.isEmpty) {
          label = 'Removed: ${lineText(ref)}';
        } else {
          final parts = <String>[
            if (bQty != aQty) 'qty ${bQty.format()} to ${aQty.format()}',
            if (b.first.unitPrice != a.first.unitPrice) 'rate ${_amt(b.first.unitPrice)} to ${_amt(a.first.unitPrice)}',
            if (Money.sum(b.map((e) => e.discount)) != Money.sum(a.map((e) => e.discount)))
              'discount ${_amt(Money.sum(b.map((e) => e.discount)))} to ${_amt(Money.sum(a.map((e) => e.discount)))}',
          ];
          final removed = bSer.where((k) => !aSer.contains(k)).toList();
          final added = aSer.where((k) => !bSer.contains(k)).toList();
          label = 'Changed: ${a.first.isStock ? productDetail(a.first.productId, a.first.name) : a.first.name}'
              '${parts.isEmpty ? '' : ' (${parts.join(', ')})'}'
              '${removed.isEmpty ? '' : '\nS/N removed: ${removed.map(SerialRecord.displayOf).join(', ')}'}'
              '${added.isEmpty ? '' : '\nS/N added: ${added.map(SerialRecord.displayOf).join(', ')}'}';
        }
        out.add(StmtRow(
          kind: StmtRowKind.editItem,
          date: at,
          voucher: s.number,
          description: label,
          qty: a.isEmpty ? bQty : aQty,
          unitPrice: (a.isEmpty ? b : a).first.unitPrice,
          totalPrice: aNet - bNet,
        ));
      }
      if (ed.beforeDiscount != ed.afterDiscount) {
        out.add(StmtRow(
          kind: StmtRowKind.editItem,
          date: at,
          voucher: s.number,
          description: 'Invoice discount ${_amt(ed.beforeDiscount)} to ${_amt(ed.afterDiscount)}',
          totalPrice: ed.beforeDiscount - ed.afterDiscount,
        ));
      }
      return out;
    }

    for (final e in entries) {
      if (after(e.at) || before(e.at) || e.type == LedgerType.opening) continue;
      running += e.balanceEffect;
      debit += e.debit;
      final isPaymentCredit = e.type == LedgerType.payment;
      if (isPaymentCredit) {
        paymentsIn += e.credit;
      } else {
        otherCredit += e.credit;
      }
      StmtRow post(StmtRowKind kind, String description, {Money? totalPrice, String? voucher}) => StmtRow(
            kind: kind,
            date: e.at,
            voucher: voucher ?? e.refNumber,
            description: description,
            totalPrice: totalPrice,
            debit: e.debit,
            credit: e.credit,
            balance: running,
          );

      switch (e.refType) {
        case 'sale':
          final s = sales[e.refId];
          if (s == null) {
            rows.add(post(StmtRowKind.invoiceTotal, 'Sales invoice (details not available)'));
            break;
          }
          invoiceIds.add(s.id);
          // The invoice as it was billed; later edits follow as their own rows.
          final billed = s.edits.isEmpty ? s.items : s.edits.first.beforeItems;
          final billedDisc = s.edits.isEmpty ? s.invoiceDiscount : s.edits.first.beforeDiscount;
          for (final it in billed) {
            rows.add(StmtRow(
              kind: StmtRowKind.saleItem,
              date: e.at,
              voucher: s.number,
              description: lineText(it),
              qty: it.qty,
              unitPrice: it.unitPrice,
              totalPrice: it.net,
            ));
          }
          if (billedDisc.isPositive) {
            rows.add(StmtRow(kind: StmtRowKind.invoiceDiscount, date: e.at, voucher: s.number, description: 'Less: invoice discount', totalPrice: -billedDisc));
          }
          rows.add(post(StmtRowKind.invoiceTotal, 'Invoice total (${billed.length} item${billed.length == 1 ? '' : 's'})${s.edited ? ' - edited later' : ''}',
              totalPrice: e.debit));
          // Edits that did not change the total have no ledger entry: note them here.
          for (final ed in s.edits.where((x) => x.difference.isZero)) {
            rows.addAll(editRows(s, ed, ed.at));
            rows.add(StmtRow(
                kind: StmtRowKind.editItem,
                date: ed.at,
                voucher: s.number,
                description: 'Invoice edited on ${_dmy(ed.at)} (total unchanged)${ed.reason.isEmpty ? '' : '\nReason: ${ed.reason}'}'));
          }
        case 'sale_edit':
          final s = sales[e.refId];
          SaleEdit? ed;
          if (s != null) {
            for (final x in s.edits) {
              if (x.at == e.at && !x.difference.isZero) ed = x;
            }
          }
          if (s != null && ed != null) rows.addAll(editRows(s, ed, e.at));
          rows.add(post(
              StmtRowKind.invoiceEdit,
              ed == null
                  ? 'Invoice ${e.refNumber} edited${_reason(e.note, '')}'
                  : 'Invoice ${e.refNumber} edited: total ${_amt(ed.beforeTotal)} to ${_amt(ed.afterTotal)}${ed.reason.isEmpty ? '' : '\nReason: ${ed.reason}'}',
              totalPrice: ed?.difference));
        case 'payment':
          final p = payments[e.refId];
          final voided = p != null && p.voided ? ' (voided later)' : '';
          if (e.type == LedgerType.refund) {
            final ret = p != null && p.refType == 'sales_return' ? returns[p.refId] : null;
            rows.add(post(
                StmtRowKind.refund,
                'Refund paid to customer${p == null ? '' : ' - ${p.method.label}'}'
                '${ret == null ? '' : ' for return ${ret.number} (invoice ${ret.originalNumber})'}$voided',
                voucher: p?.number));
          } else {
            var against = '';
            if (p != null) {
              if (p.refType == 'sale') {
                final s = sales[p.refId];
                final atSale = s != null && p.at == s.date && p.amount == s.paidAtSale;
                against = atSale ? ' - paid at sale, invoice ${s.number}' : ' - against invoice ${s?.number ?? p.refId}';
              } else if (p.refType == 'repair') {
                against = ' - repair job ${repairs[p.refId]?.number ?? ''}'.trimRight();
              } else {
                against = ' - on account';
                if (!p.voided) onAccount += p.amount;
              }
            }
            final note = p == null || p.note.trim().isEmpty ? '' : '\nNote: ${p.note.trim()}';
            rows.add(post(StmtRowKind.payment, 'Payment received${p == null ? '' : ' - ${p.method.label}'}$against$voided$note', voucher: p?.number));
          }
        case 'payment_void':
          rows.add(post(StmtRowKind.paymentVoid, 'Payment ${e.refNumber} voided${_reason(e.note, 'Void: ')}'));
        case 'sale_cancel':
          rows.add(post(StmtRowKind.invoiceCancel, 'Invoice ${e.refNumber} cancelled${_reason(e.note, 'Cancelled: ')}'));
        case 'sales_return':
          // One credit row per return voucher (the ledger entry), so a
          // return is counted exactly once.
          returnCredit += e.credit;
          final r = returns[e.refId];
          if (r != null) {
            for (final l in r.lines) {
              returnLines.add(StatementReturn(
                returnId: r.id,
                date: r.date,
                number: r.number,
                invoiceNumber: r.originalNumber,
                productName: l.name,
                serials: l.serials,
                qty: l.qty,
                amount: l.amount,
                reason: r.reason,
                condition: l.condition,
                refundMode: r.refundMode,
              ));
              rows.add(StmtRow(
                kind: StmtRowKind.returnItem,
                date: e.at,
                voucher: r.number,
                description: 'Returned: ${l.name}${serialText(l.serials)}\n'
                    'Condition: ${returnConditionLabel(l.condition)} - ${returnConditionStock(l.condition)}',
                qty: l.qty,
                unitPrice: l.qty.isPositive ? l.amount.perUnit(l.qty) : null,
                totalPrice: l.amount,
              ));
            }
          }
          final how = r == null ? '' : (r.refundMode == RefundMode.cash ? ' - refunded in cash' : ' - credited to account');
          final reason = (r?.reason ?? e.note).trim();
          rows.add(post(StmtRowKind.returnTotal,
              'Sales return${r == null ? '' : ' against invoice ${r.originalNumber}'}$how${reason.isEmpty ? '' : '\nReason: $reason'}',
              totalPrice: r?.total));
        case 'repair':
          final j = repairs[e.refId];
          if (j != null) {
            for (final part in j.parts) {
              rows.add(StmtRow(
                kind: StmtRowKind.repairItem,
                date: e.at,
                voucher: j.number,
                description: 'Repair part: ${part.name}',
                qty: part.qty,
                unitPrice: part.qty.isPositive ? part.price.perUnit(part.qty) : null,
                totalPrice: part.price,
              ));
            }
            if (j.serviceCharges.isPositive) {
              rows.add(StmtRow(kind: StmtRowKind.repairItem, date: e.at, voucher: j.number, description: 'Repair service charges', totalPrice: j.serviceCharges));
            }
          }
          rows.add(post(StmtRowKind.repairTotal, 'Repair charges${j == null ? '' : ' - ${j.productName}${j.serial.isEmpty ? '' : ' (S/N ${j.serial})'}'}'));
        case 'adjustment':
          rows.add(post(StmtRowKind.adjustment, 'Adjustment${e.debit.isPositive ? ' (added)' : ' (reduced)'}${_reason(e.note, '')}'));
        default:
          rows.add(post(StmtRowKind.other, '${_typeLabel(e.type)}${_reason(e.note, '')}'));
      }
    }

    // Invoice status, using what was saved up to the statement end.
    bool inRange(DateTime at) => !after(at);
    final invoices = <InvoiceStatus>[];
    for (final id in invoiceIds) {
      final s = sales[id]!;
      final rets = returns.values.where((r) => r.originalId == s.id && inRange(r.date)).toList();
      final retIds = {for (final r in rets) r.id};
      final retTotal = Money.sum(rets.map((r) => r.total));
      final paidIn = Money.sum(payments.values
          .where((p) => !p.voided && p.direction == PaymentDirection.received && p.refType == 'sale' && p.refId == s.id && inRange(p.at))
          .map((p) => p.amount));
      final refunds = Money.sum(payments.values
          .where((p) => !p.voided && p.direction == PaymentDirection.paid && p.refType == 'sales_return' && retIds.contains(p.refId) && inRange(p.at))
          .map((p) => p.amount));
      final paid = paidIn - refunds;
      final due = s.total - retTotal - paid;
      final cancelled = s.status == DocStatus.cancelled;
      final state = cancelled
          ? InvoiceState.cancelled
          : !due.isPositive
              ? InvoiceState.paid
              : paid.isPositive
                  ? InvoiceState.partlyPaid
                  : InvoiceState.unpaid;
      invoices.add(InvoiceStatus(s.id, s.number, s.date, s.total, retTotal, paid, cancelled ? const Money.zero() : due, state));
    }

    final closing = opening + debit - paymentsIn - otherCredit;
    // The running balance and the totals are two views of the same entries.
    assert(closing == running);
    return CustomerStatement(
      customer: customer,
      from: f,
      to: t,
      generatedAt: now,
      period: period,
      openingBalance: opening,
      rows: rows,
      totalDebit: debit,
      totalPayments: paymentsIn,
      totalReturnsAdjustments: otherCredit,
      totalReturns: returnCredit,
      returns: returnLines,
      closingBalance: running,
      onAccountPayments: onAccount,
      invoices: invoices,
      accountBalance: accountBalance,
    );
  }

  static String _reason(String note, String prefix) {
    var n = note.trim();
    if (prefix.isNotEmpty && n.startsWith(prefix)) n = n.substring(prefix.length).trim();
    return n.isEmpty ? '' : ': $n';
  }

  static String _typeLabel(LedgerType t) => switch (t) {
        LedgerType.sale => 'Sale',
        LedgerType.payment => 'Payment received',
        LedgerType.salesReturn => 'Sales return',
        LedgerType.adjustment => 'Adjustment',
        LedgerType.reversal => 'Reversal',
        LedgerType.repairCharge => 'Repair charges',
        LedgerType.refund => 'Refund',
        LedgerType.opening => 'Opening balance',
        LedgerType.purchase => 'Purchase',
        LedgerType.purchaseReturn => 'Purchase return',
      };
}

String _two(int n) => n.toString().padLeft(2, '0');
String _dmy(DateTime d) => '${_two(d.day)}/${_two(d.month)}/${d.year}';
String _amt(Money m) => m.format(symbol: 'Rs');
