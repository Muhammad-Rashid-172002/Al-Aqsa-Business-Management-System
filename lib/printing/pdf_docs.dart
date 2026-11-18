import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../core/money.dart';
import '../core/qty.dart';
import '../domain/models/documents.dart';
import '../domain/models/operations.dart';
import '../domain/models/party.dart';
import '../domain/models/product.dart';
import '../domain/services/party_service.dart';
import '../export/tabular.dart';

/// Paper formats used by the shop.
enum PaperKind { a4, thermal80, thermal58 }

PaperKind paperFromSetting(String s) => switch (s) { 'a4' => PaperKind.a4, 'thermal58' => PaperKind.thermal58, _ => PaperKind.thermal80 };

final _d = DateFormat('dd/MM/yyyy');
final _dt = DateFormat('dd/MM/yyyy hh:mm a');
const _emerald = PdfColor.fromInt(0xFF087F5B);
const _grey = PdfColor.fromInt(0xFF6B7280);
const _line = PdfColor.fromInt(0xFFD9E2DD);

/// PDFs use the built-in Helvetica font, so text is kept ASCII-safe.
String ascii(String s) => s
    .replaceAll('•', '-')
    .replaceAll('–', '-')
    .replaceAll('—', '-')
    .replaceAll('’', "'")
    .replaceAll('‘', "'")
    .replaceAll('“', '"')
    .replaceAll('”', '"')
    .replaceAll(RegExp(r'[^\x20-\x7E\n]'), '');

String money(Money m0, AppSettings st) => m0.format(symbol: st.currencySymbol);

class PdfHelper {
  final AppSettings st;
  PdfHelper(this.st);

  pw.ImageProvider? get logo {
    final path = st.logoPath;
    if (path == null || path.isEmpty) return null;
    try {
      final f = File(path);
      return f.existsSync() ? pw.MemoryImage(f.readAsBytesSync()) : null;
    } catch (_) {
      return null;
    }
  }

  pw.Widget header(String docTitle, List<(String, String)> meta) {
    final lg = logo;
    return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
      pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        if (lg != null) pw.Container(width: 54, height: 54, margin: const pw.EdgeInsets.only(right: 12), child: pw.Image(lg)),
        pw.Expanded(
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text(ascii(st.businessName), style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold, color: _emerald)),
            if (st.address.isNotEmpty) pw.Text(ascii(st.address), style: const pw.TextStyle(fontSize: 9, color: _grey)),
            if (st.phone.isNotEmpty || st.email.isNotEmpty)
              pw.Text(ascii([if (st.phone.isNotEmpty) 'Phone: ${st.phone}', if (st.email.isNotEmpty) st.email].join('   ')), style: const pw.TextStyle(fontSize: 9, color: _grey)),
          ]),
        ),
        pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
          pw.Text(docTitle.toUpperCase(), style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 4),
          for (final m0 in meta) pw.Text(ascii('${m0.$1}: ${m0.$2}'), style: const pw.TextStyle(fontSize: 9)),
        ]),
      ]),
      pw.SizedBox(height: 10),
      pw.Container(height: 2, color: _emerald),
      pw.SizedBox(height: 12),
    ]);
  }

  pw.Widget table(List<String> headers, List<List<String>> rows, {Map<int, pw.Alignment>? align, Map<int, pw.TableColumnWidth>? widths}) => pw.TableHelper.fromTextArray(
        headers: headers.map(ascii).toList(),
        data: rows.map((r) => r.map(ascii).toList()).toList(),
        headerStyle: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, color: PdfColors.white),
        headerDecoration: const pw.BoxDecoration(color: _emerald),
        cellStyle: const pw.TextStyle(fontSize: 9),
        cellAlignments: align ?? {},
        columnWidths: widths,
        border: const pw.TableBorder(horizontalInside: pw.BorderSide(color: _line, width: 0.5), bottom: pw.BorderSide(color: _line, width: 0.5)),
        cellPadding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4),
      );

  pw.Widget totals(List<(String, String, bool)> rows) => pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.Container(
          width: 230,
          margin: const pw.EdgeInsets.only(top: 10),
          child: pw.Column(children: [
            for (final r in rows)
              pw.Padding(
                padding: const pw.EdgeInsets.symmetric(vertical: 2),
                child: pw.Row(children: [
                  pw.Expanded(child: pw.Text(ascii(r.$1), style: pw.TextStyle(fontSize: r.$3 ? 11 : 9.5, fontWeight: r.$3 ? pw.FontWeight.bold : pw.FontWeight.normal))),
                  pw.Text(ascii(r.$2), style: pw.TextStyle(fontSize: r.$3 ? 11 : 9.5, fontWeight: r.$3 ? pw.FontWeight.bold : pw.FontWeight.normal)),
                ]),
              ),
          ]),
        ),
      );

  pw.Widget footer(String text) => pw.Column(children: [
        pw.SizedBox(height: 24),
        pw.Divider(color: _line),
        pw.Text(ascii(text), style: const pw.TextStyle(fontSize: 8.5, color: _grey), textAlign: pw.TextAlign.center),
      ]);
}

String _serialLine(List<String> keys) => keys.isEmpty ? '' : '\nS/N: ${keys.map(SerialRecord.displayOf).join(', ')}';

// ───────────────────────── Sales invoice / receipt ─────────────────────────

Future<Uint8List> invoicePdf(AppSettings st, Sale sale, {Party? customer, PaperKind paper = PaperKind.a4, String cashier = ''}) async {
  if (paper != PaperKind.a4) return _thermalInvoice(st, sale, paper, cashier: cashier);
  final h = PdfHelper(st);
  final doc = pw.Document(title: sale.number, author: st.businessName);
  final remaining = sale.remaining;
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(32),
    build: (_) => [
      h.header(sale.status == DocStatus.cancelled ? 'Invoice (CANCELLED)' : 'Invoice', [
        ('Invoice No', sale.number),
        ('Date', _dt.format(sale.date)),
        if (cashier.isNotEmpty) ('Served by', cashier),
      ]),
      pw.Text('Bill To', style: const pw.TextStyle(fontSize: 9, color: _grey)),
      pw.Text(ascii(sale.customerName), style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
      if (customer != null && customer.phone.isNotEmpty) pw.Text(ascii(customer.phone), style: const pw.TextStyle(fontSize: 9)),
      if (customer != null && customer.address.isNotEmpty) pw.Text(ascii(customer.address), style: const pw.TextStyle(fontSize: 9)),
      pw.SizedBox(height: 12),
      h.table(
        ['#', 'Item', 'Qty', 'Unit Price', 'Discount', 'Amount'],
        [
          for (var k = 0; k < sale.items.length; k++)
            [
              '${k + 1}',
              '${sale.items[k].name}${_serialLine(sale.items[k].serials)}',
              sale.items[k].qty.format(),
              money(sale.items[k].unitPrice, st),
              sale.items[k].discount.isZero ? '-' : money(sale.items[k].discount, st),
              money(sale.items[k].net, st),
            ]
        ],
        align: {2: pw.Alignment.centerRight, 3: pw.Alignment.centerRight, 4: pw.Alignment.centerRight, 5: pw.Alignment.centerRight},
        widths: {0: const pw.FixedColumnWidth(22), 1: const pw.FlexColumnWidth(4), 2: const pw.FlexColumnWidth(1)},
      ),
      h.totals([
        ('Subtotal', money(sale.subtotal, st), false),
        if (!sale.lineDiscounts.isZero) ('Line discounts', '- ${money(sale.lineDiscounts, st)}', false),
        if (!sale.invoiceDiscount.isZero) ('Invoice discount', '- ${money(sale.invoiceDiscount, st)}', false),
        ('Grand Total', money(sale.total, st), true),
        ('Paid (${sale.method.label})', money(sale.paidAtSale, st), false),
        ('Balance Due', money(remaining, st), remaining.isPositive),
      ]),
      if (sale.notes.isNotEmpty) pw.Padding(padding: const pw.EdgeInsets.only(top: 12), child: pw.Text(ascii('Notes: ${sale.notes}'), style: const pw.TextStyle(fontSize: 9))),
      h.footer(st.receiptFooter),
    ],
  ));
  return doc.save();
}

Future<Uint8List> _thermalInvoice(AppSettings st, Sale sale, PaperKind paper, {String cashier = ''}) async {
  final width = paper == PaperKind.thermal58 ? 58.0 : 80.0;
  final fs = paper == PaperKind.thermal58 ? 7.5 : 8.5;
  final doc = pw.Document(title: sale.number);
  pw.Widget row(String a, String b, {bool bold = false}) => pw.Row(children: [
        pw.Expanded(child: pw.Text(ascii(a), style: pw.TextStyle(fontSize: fs, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal))),
        pw.Text(ascii(b), style: pw.TextStyle(fontSize: fs, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
      ]);
  doc.addPage(pw.Page(
    pageFormat: PdfPageFormat(width * PdfPageFormat.mm, double.infinity, marginAll: 3 * PdfPageFormat.mm),
    build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
      pw.Text(ascii(st.businessName), textAlign: pw.TextAlign.center, style: pw.TextStyle(fontSize: fs + 4, fontWeight: pw.FontWeight.bold)),
      if (st.address.isNotEmpty) pw.Text(ascii(st.address), textAlign: pw.TextAlign.center, style: pw.TextStyle(fontSize: fs - 1)),
      if (st.phone.isNotEmpty) pw.Text(ascii(st.phone), textAlign: pw.TextAlign.center, style: pw.TextStyle(fontSize: fs - 1)),
      pw.Divider(borderStyle: pw.BorderStyle.dashed),
      row('Invoice', sale.number, bold: true),
      row('Date', _dt.format(sale.date)),
      row('Customer', sale.customerName),
      if (cashier.isNotEmpty) row('Cashier', cashier),
      if (sale.status == DocStatus.cancelled) pw.Text('*** CANCELLED ***', textAlign: pw.TextAlign.center, style: pw.TextStyle(fontSize: fs + 1, fontWeight: pw.FontWeight.bold)),
      pw.Divider(borderStyle: pw.BorderStyle.dashed),
      for (final it in sale.items) ...[
        pw.Text(ascii(it.name), style: pw.TextStyle(fontSize: fs, fontWeight: pw.FontWeight.bold)),
        row('  ${it.qty.format()} x ${money(it.unitPrice, st)}${it.discount.isZero ? '' : ' - ${money(it.discount, st)}'}', money(it.net, st)),
        if (it.serials.isNotEmpty) pw.Text(ascii('  S/N: ${it.serials.map(SerialRecord.displayOf).join(', ')}'), style: pw.TextStyle(fontSize: fs - 1)),
      ],
      pw.Divider(borderStyle: pw.BorderStyle.dashed),
      row('Subtotal', money(sale.subtotal - sale.lineDiscounts, st)),
      if (!sale.invoiceDiscount.isZero) row('Discount', '- ${money(sale.invoiceDiscount, st)}'),
      row('TOTAL', money(sale.total, st), bold: true),
      row('Paid (${sale.method.label})', money(sale.paidAtSale, st)),
      if (sale.remaining.isPositive) row('Balance due', money(sale.remaining, st), bold: true),
      pw.Divider(borderStyle: pw.BorderStyle.dashed),
      pw.Text(ascii(st.receiptFooter), textAlign: pw.TextAlign.center, style: pw.TextStyle(fontSize: fs - 0.5)),
      pw.SizedBox(height: 8),
    ]),
  ));
  return doc.save();
}

// ───────────────────────── Quotation ─────────────────────────

Future<Uint8List> quotationPdf(AppSettings st, Quotation q, {Party? customer}) async {
  final h = PdfHelper(st);
  final doc = pw.Document(title: q.number);
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(32),
    build: (_) => [
      h.header('Quotation', [('Quotation No', q.number), ('Date', _d.format(q.date)), ('Valid until', _d.format(q.expiryDate))]),
      pw.Text('Prepared for', style: const pw.TextStyle(fontSize: 9, color: _grey)),
      pw.Text(ascii(q.customerName), style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
      if (customer != null && customer.phone.isNotEmpty) pw.Text(ascii(customer.phone), style: const pw.TextStyle(fontSize: 9)),
      pw.SizedBox(height: 12),
      h.table(
        ['#', 'Item', 'Qty', 'Unit Price', 'Discount', 'Amount'],
        [
          for (var k = 0; k < q.items.length; k++)
            ['${k + 1}', q.items[k].name, q.items[k].qty.format(), money(q.items[k].unitPrice, st), q.items[k].discount.isZero ? '-' : money(q.items[k].discount, st), money(q.items[k].net, st)]
        ],
        align: {2: pw.Alignment.centerRight, 3: pw.Alignment.centerRight, 4: pw.Alignment.centerRight, 5: pw.Alignment.centerRight},
        widths: {0: const pw.FixedColumnWidth(22), 1: const pw.FlexColumnWidth(4)},
      ),
      h.totals([
        ('Subtotal', money(Money.sum(q.items.map((e) => e.net)), st), false),
        if (!q.invoiceDiscount.isZero) ('Discount', '- ${money(q.invoiceDiscount, st)}', false),
        ('Total', money(q.total, st), true),
      ]),
      if (q.terms.isNotEmpty) ...[
        pw.SizedBox(height: 16),
        pw.Text('Terms & Conditions', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
        pw.Text(ascii(q.terms), style: const pw.TextStyle(fontSize: 9)),
      ],
      h.footer('This is a quotation, not an invoice. Prices are valid until ${_d.format(q.expiryDate)}.'),
    ],
  ));
  return doc.save();
}

// ───────────────────────── Purchase ─────────────────────────

Future<Uint8List> purchasePdf(AppSettings st, Purchase p, Party supplier) async {
  final h = PdfHelper(st);
  final doc = pw.Document(title: p.number);
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(32),
    build: (_) => [
      h.header(p.status == DocStatus.cancelled ? 'Purchase (CANCELLED)' : 'Purchase', [
        ('Purchase No', p.number),
        ('Date', _d.format(p.date)),
        if (p.supplierInvoiceNo.isNotEmpty) ('Supplier Inv', p.supplierInvoiceNo),
      ]),
      pw.Text('Supplier', style: const pw.TextStyle(fontSize: 9, color: _grey)),
      pw.Text(ascii(supplier.name), style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
      if (supplier.phone.isNotEmpty) pw.Text(ascii(supplier.phone), style: const pw.TextStyle(fontSize: 9)),
      pw.SizedBox(height: 12),
      h.table(
        ['#', 'Item', 'Qty', 'Unit Cost', 'Discount', 'Tax', 'Amount'],
        [
          for (var k = 0; k < p.items.length; k++)
            [
              '${k + 1}',
              '${p.items[k].name}${_serialLine(p.items[k].serials)}${p.items[k].returnedQty.isPositive ? '\nReturned: ${p.items[k].returnedQty.format()}' : ''}',
              p.items[k].qty.format(),
              money(p.items[k].unitCost, st),
              money(p.items[k].discount, st),
              money(p.items[k].tax, st),
              money(p.items[k].net, st),
            ]
        ],
        align: {2: pw.Alignment.centerRight, 3: pw.Alignment.centerRight, 4: pw.Alignment.centerRight, 5: pw.Alignment.centerRight, 6: pw.Alignment.centerRight},
        widths: {0: const pw.FixedColumnWidth(22), 1: const pw.FlexColumnWidth(4)},
      ),
      h.totals([
        ('Subtotal', money(p.subtotal, st), false),
        ('Discount', '- ${money(p.discountTotal, st)}', false),
        ('Tax', money(p.taxTotal, st), false),
        ('Total', money(p.total, st), true),
        ('Paid (${p.method.label})', money(p.paidAtPurchase, st), false),
        ('Balance', money(p.remaining, st), true),
      ]),
      h.footer('Generated by ${st.businessName}'),
    ],
  ));
  return doc.save();
}

// ───────────────────────── Payment receipt ─────────────────────────

Future<Uint8List> paymentReceiptPdf(AppSettings st, Payment pay, {Party? party, Money? balanceAfter}) async {
  final h = PdfHelper(st);
  final doc = pw.Document(title: pay.number);
  final isReceipt = pay.direction == PaymentDirection.received;
  doc.addPage(pw.Page(
    pageFormat: PdfPageFormat.a5.landscape,
    margin: const pw.EdgeInsets.all(28),
    build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
      h.header(isReceipt ? 'Payment Receipt' : 'Payment Voucher', [('No', pay.number), ('Date', _dt.format(pay.at))]),
      pw.Text(isReceipt ? 'Received from' : 'Paid to', style: const pw.TextStyle(fontSize: 9, color: _grey)),
      pw.Text(ascii(party?.name ?? 'Walk-in Customer'), style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
      pw.SizedBox(height: 14),
      pw.Container(
        padding: const pw.EdgeInsets.all(12),
        decoration: pw.BoxDecoration(border: pw.Border.all(color: _emerald), borderRadius: pw.BorderRadius.circular(6)),
        child: pw.Row(children: [
          pw.Expanded(child: pw.Text('Amount (${ascii(pay.method.label)})', style: const pw.TextStyle(fontSize: 11))),
          pw.Text(ascii(money(pay.amount, st)), style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold, color: _emerald)),
        ]),
      ),
      if (pay.note.isNotEmpty) pw.Padding(padding: const pw.EdgeInsets.only(top: 8), child: pw.Text(ascii('Note: ${pay.note}'), style: const pw.TextStyle(fontSize: 9))),
      if (balanceAfter != null) pw.Padding(padding: const pw.EdgeInsets.only(top: 8), child: pw.Text(ascii('Account balance after this payment: ${money(balanceAfter, st)}'), style: const pw.TextStyle(fontSize: 9))),
      if (pay.voided) pw.Padding(padding: const pw.EdgeInsets.only(top: 8), child: pw.Text(ascii('VOIDED: ${pay.voidReason}'), style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold, color: PdfColors.red))),
      pw.Spacer(),
      pw.Row(children: [
        pw.Expanded(child: pw.Text('Signature: ______________________', style: const pw.TextStyle(fontSize: 9))),
        pw.Text(ascii(st.businessName), style: const pw.TextStyle(fontSize: 9, color: _grey)),
      ]),
    ]),
  ));
  return doc.save();
}

// ───────────────────────── Repair receipt ─────────────────────────

Future<Uint8List> repairReceiptPdf(AppSettings st, RepairJob job, {String technicianName = ''}) async {
  final h = PdfHelper(st);
  final doc = pw.Document(title: job.number);
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(32),
    build: (_) => [
      h.header('Repair Job', [('Job No', job.number), ('Received', _dt.format(job.receivedDate)), ('Status', job.status.label)]),
      pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Expanded(
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text('Customer', style: const pw.TextStyle(fontSize: 9, color: _grey)),
            pw.Text(ascii(job.customerName), style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
            if (job.customerPhone.isNotEmpty) pw.Text(ascii(job.customerPhone), style: const pw.TextStyle(fontSize: 9)),
          ]),
        ),
        pw.Expanded(
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text('Device', style: const pw.TextStyle(fontSize: 9, color: _grey)),
            pw.Text(ascii(job.productName), style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
            if (job.serial.isNotEmpty) pw.Text(ascii('S/N: ${job.serial}'), style: const pw.TextStyle(fontSize: 9)),
            pw.Text(job.underWarranty ? 'Under warranty' : 'Not under warranty', style: const pw.TextStyle(fontSize: 9)),
          ]),
        ),
      ]),
      pw.SizedBox(height: 12),
      pw.Text('Reported issue', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
      pw.Text(ascii(job.reportedIssue), style: const pw.TextStyle(fontSize: 9.5)),
      if (job.physicalCondition.isNotEmpty) ...[
        pw.SizedBox(height: 6),
        pw.Text('Physical condition', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
        pw.Text(ascii(job.physicalCondition), style: const pw.TextStyle(fontSize: 9.5)),
      ],
      if (job.repairNotes.isNotEmpty) ...[
        pw.SizedBox(height: 6),
        pw.Text('Repair notes', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
        pw.Text(ascii(job.repairNotes), style: const pw.TextStyle(fontSize: 9.5)),
      ],
      if (technicianName.isNotEmpty) pw.Padding(padding: const pw.EdgeInsets.only(top: 6), child: pw.Text(ascii('Technician: $technicianName'), style: const pw.TextStyle(fontSize: 9.5))),
      pw.SizedBox(height: 12),
      if (job.parts.isNotEmpty)
        h.table(['Part', 'Qty', 'Amount'], [for (final p in job.parts) [p.name, p.qty.format(), money(p.price, st)]],
            align: {1: pw.Alignment.centerRight, 2: pw.Alignment.centerRight}),
      h.totals([
        ('Service charges', money(job.serviceCharges, st), false),
        ('Parts', money(job.partsPrice, st), false),
        ('Total', money(job.totalCharges, st), true),
      ]),
      pw.SizedBox(height: 20),
      pw.Text('Please bring this receipt when collecting your device. Devices not collected within 60 days may be disposed of.',
          style: const pw.TextStyle(fontSize: 8.5, color: _grey)),
      pw.SizedBox(height: 30),
      pw.Row(children: [
        pw.Expanded(child: pw.Text('Customer signature: ______________', style: const pw.TextStyle(fontSize: 9))),
        pw.Text('Shop signature: ______________', style: const pw.TextStyle(fontSize: 9)),
      ]),
    ],
  ));
  return doc.save();
}

// ───────────────────────── Account statement ─────────────────────────

Future<Uint8List> statementPdf(AppSettings st, PartyStatement s, {DateTime? from, DateTime? to}) async {
  final h = PdfHelper(st);
  final doc = pw.Document(title: 'Statement ${s.party.name}');
  final isCustomer = s.party.kind == PartyKind.customer;
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(32),
    build: (_) => [
      h.header('Account Statement', [
        ('Account', isCustomer ? 'Customer' : 'Supplier'),
        ('Period', '${from == null ? 'Start' : _d.format(from)} - ${to == null ? 'Today' : _d.format(to)}'),
      ]),
      pw.Text(ascii(s.party.name), style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
      if (s.party.phone.isNotEmpty) pw.Text(ascii(s.party.phone), style: const pw.TextStyle(fontSize: 9)),
      pw.SizedBox(height: 10),
      h.table(
        ['Date', 'Type', 'Reference', 'Debit', 'Credit', 'Balance'],
        [
          ['', 'Opening balance', '', '', '', money(s.openingBalance, st)],
          for (final l in s.lines)
            [
              _d.format(l.entry.at),
              l.entry.type.name,
              '${l.entry.refNumber}${l.entry.note.isEmpty ? '' : ' - ${l.entry.note}'}',
              l.entry.debit.isZero ? '' : money(l.entry.debit, st),
              l.entry.credit.isZero ? '' : money(l.entry.credit, st),
              money(l.runningBalance, st),
            ]
        ],
        align: {3: pw.Alignment.centerRight, 4: pw.Alignment.centerRight, 5: pw.Alignment.centerRight},
        widths: {2: const pw.FlexColumnWidth(3)},
      ),
      h.totals([
        (isCustomer ? 'Amount receivable' : 'Amount payable', money(s.closingBalance, st), true),
      ]),
      h.footer(isCustomer ? 'Positive balance = amount the customer owes ${st.businessName}.' : 'Positive balance = amount ${st.businessName} owes the supplier.'),
    ],
  ));
  return doc.save();
}

// ───────────────────────── Labels ─────────────────────────

class LabelJob {
  final Product product;
  final int copies;
  final String? serialKey; // print a unit serial label instead of product code
  const LabelJob(this.product, this.copies, {this.serialKey});
}

/// Product / serial labels: QR + Code128 barcode + name (+ price).
Future<Uint8List> labelsPdf(AppSettings st, List<LabelJob> jobs) async {
  final w = st.labelWidthMm * PdfPageFormat.mm;
  final hgt = st.labelHeightMm * PdfPageFormat.mm;
  final doc = pw.Document(title: 'Labels');
  final small = hgt < 22 * PdfPageFormat.mm;
  for (final j in jobs) {
    final code = j.serialKey == null ? j.product.internalCode : SerialRecord.displayOf(j.serialKey!);
    for (var k = 0; k < j.copies; k++) {
      doc.addPage(pw.Page(
        pageFormat: PdfPageFormat(w, hgt, marginAll: 1.5 * PdfPageFormat.mm),
        build: (_) => pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.center, children: [
          pw.SizedBox(width: hgt - 4 * PdfPageFormat.mm, height: hgt - 4 * PdfPageFormat.mm, child: pw.BarcodeWidget(barcode: pw.Barcode.qrCode(), data: code, drawText: false)),
          pw.SizedBox(width: 2 * PdfPageFormat.mm),
          pw.Expanded(
            child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, mainAxisAlignment: pw.MainAxisAlignment.center, children: [
              pw.Text(ascii(j.product.name), maxLines: small ? 1 : 2, style: pw.TextStyle(fontSize: small ? 5.5 : 6.5, fontWeight: pw.FontWeight.bold)),
              if (st.labelShowPrice && j.serialKey == null) pw.Text(ascii(money(j.product.sellingPrice, st)), style: pw.TextStyle(fontSize: small ? 6 : 7.5, fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 1),
              pw.SizedBox(height: small ? 6 * PdfPageFormat.mm : 8 * PdfPageFormat.mm, child: pw.BarcodeWidget(barcode: pw.Barcode.code128(), data: code, drawText: false)),
              pw.Text(ascii(j.serialKey == null ? code : 'S/N $code'), style: const pw.TextStyle(fontSize: 5.5)),
            ]),
          ),
        ]),
      ));
    }
  }
  return doc.save();
}

// ───────────────────────── Generic report ─────────────────────────

Future<Uint8List> reportPdf(AppSettings st, ExportTable t, {String subtitle = '', bool landscape = false}) =>
    reportPdfMulti(st, [t], subtitle: subtitle, landscape: landscape);

/// A4 report with one section per table: business name, report title,
/// generation date, period / filters, the column header repeated at the top
/// of every page, bold totals, and "Page x of y" on every page.
Future<Uint8List> reportPdfMulti(AppSettings st, List<ExportTable> tables, {String subtitle = '', bool landscape = false}) async {
  final h = PdfHelper(st);
  final doc = pw.Document(title: tables.isEmpty ? '' : tables.first.title, author: st.businessName);
  final generated = _dt.format(DateTime.now());
  for (var ti = 0; ti < tables.length; ti++) {
    final t = tables[ti];
    final body = [for (final r in t.rows) r.map(exportCellText).toList()];
    final foot = [for (final r in t.footer) r.map(exportCellText).toList()];
    final firstRow = t.rows.isNotEmpty ? t.rows.first : (t.footer.isNotEmpty ? t.footer.first : const <Object?>[]);
    final align = {
      for (var k = 0; k < t.headers.length; k++)
        if (firstRow.length > k && firstRow[k] is num) k: pw.Alignment.centerRight,
    };
    // One large table that spans many pages is laid out again for every page
    // (time grows with rows x pages). The rows are laid out in blocks
    // instead, with fixed column widths proportional to the longest text in
    // each column, and the header row repeated at the top of every page.
    final widths = _columnWidths(t.headers, [...body, ...foot.where((r) => r.length == t.headers.length)]);
    pw.Widget headerRow() => h.table(t.headers, const [], align: align, widths: widths);
    pw.Widget block(List<List<String>> part, {bool bold = false}) => pw.TableHelper.fromTextArray(
          headers: null,
          data: [for (final r in part) r.map(ascii).toList()],
          cellStyle: pw.TextStyle(fontSize: 9, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal),
          cellAlignments: align,
          columnWidths: widths,
          cellDecoration: bold ? (_, _, _) => const pw.BoxDecoration(color: PdfColor.fromInt(0xFFE8F3EF)) : null,
          border: const pw.TableBorder(horizontalInside: pw.BorderSide(color: _line, width: 0.5), bottom: pw.BorderSide(color: _line, width: 0.5)),
          cellPadding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4),
        );
    const blockRows = 20;
    int? firstPage;
    final wide = landscape || t.headers.length > 6;
    final meta = <(String, String)>[
      ('Generated', generated),
      if (subtitle.isNotEmpty && t.info.isEmpty) ('Period', subtitle),
    ];
    doc.addPage(pw.MultiPage(
      pageFormat: wide ? PdfPageFormat.a4.landscape : PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(28),
      header: (ctx) {
        firstPage ??= ctx.pageNumber;
        return ctx.pageNumber == firstPage
            ? pw.SizedBox()
            : pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
                pw.Text(ascii('${st.businessName} - ${t.title} (continued)'), style: const pw.TextStyle(fontSize: 8, color: _grey)),
                pw.SizedBox(height: 4),
                headerRow(),
              ]);
      },
      build: (_) => [
        h.header(t.title, meta),
        for (final i in t.info) pw.Text(ascii(i), style: const pw.TextStyle(fontSize: 9, color: _grey)),
        if (t.info.isNotEmpty) pw.SizedBox(height: 8),
        headerRow(),
        if (body.isEmpty)
          pw.Padding(padding: const pw.EdgeInsets.all(12), child: pw.Text('No records match this report.', style: const pw.TextStyle(fontSize: 10, color: _grey))),
        for (var s = 0; s < body.length; s += blockRows) block(body.sublist(s, s + blockRows > body.length ? body.length : s + blockRows)),
        for (final r in foot)
          r.length == t.headers.length && r.skip(1).any((c) => c.isNotEmpty)
              ? block([r], bold: true)
              : pw.Padding(padding: const pw.EdgeInsets.only(top: 6), child: pw.Text(ascii(r.where((c) => c.isNotEmpty).join('  ')), style: pw.TextStyle(fontSize: 8.5, fontStyle: pw.FontStyle.italic))),
      ],
      footer: (ctx) => pw.Row(children: [
        pw.Expanded(child: pw.Text(ascii('${st.businessName} - ${t.title} - generated $generated'), style: const pw.TextStyle(fontSize: 8, color: _grey))),
        pw.Text('Page ${ctx.pageNumber} of ${ctx.pagesCount}', style: const pw.TextStyle(fontSize: 8, color: _grey)),
      ]),
    ));
  }
  return doc.save();
}

/// Builds [reportPdf] on a background isolate so the window stays responsive.
Future<Uint8List> reportPdfInBackground(AppSettings st, ExportTable t, {String subtitle = '', bool landscape = false}) =>
    Isolate.run(() => reportPdf(st, t, subtitle: subtitle, landscape: landscape));

/// [reportPdfMulti] on a background isolate.
Future<Uint8List> reportPdfMultiInBackground(AppSettings st, List<ExportTable> tables, {String subtitle = '', bool landscape = false}) =>
    Isolate.run(() => reportPdfMulti(st, tables, subtitle: subtitle, landscape: landscape));

/// Column widths proportional to the longest text (header or cell) in each
/// column, with a floor so short columns stay readable.
Map<int, pw.TableColumnWidth> _columnWidths(List<String> headers, List<List<String>> rows) {
  final n = headers.length;
  final w = [for (final hd in headers) hd.length.toDouble()];
  for (final r in rows) {
    for (var k = 0; k < n && k < r.length; k++) {
      if (r[k].length > w[k]) w[k] = r[k].length.toDouble();
    }
  }
  return {for (var k = 0; k < n; k++) k: pw.FlexColumnWidth((w[k].clamp(4, 40)).toDouble())};
}

String qtyText(Qty q, String unit) => '${q.format()} $unit';
