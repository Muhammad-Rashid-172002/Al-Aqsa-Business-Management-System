import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../core/money.dart';
import '../core/qty.dart';
import '../domain/models/documents.dart';
import '../domain/models/labour.dart';
import '../domain/models/operations.dart';
import '../domain/models/party.dart';
import '../domain/models/product.dart';
import '../domain/services/customer_statement.dart';
import '../domain/services/party_service.dart';
import '../domain/services/whatsapp.dart' show normalizeWhatsAppNumber;
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

  /// wa.me link for the shop contact number, or null if it is not a
  /// valid mobile number.
  String? get waLink {
    final n = normalizeWhatsAppNumber(st.contactPhone);
    return n == null ? null : 'https://wa.me/$n';
  }

  static const _waGreen = PdfColor.fromInt(0xFF25D366);
  // A plain phone handset (Material "call" glyph), white on a green circle,
  // used when no WhatsApp icon image has been chosen in Settings.
  static const _handset =
      'M6.62 10.79c1.44 2.83 3.76 5.14 6.59 6.59l2.2-2.2c.27-.27.67-.36 1.02-.24 1.12.37 2.33.57 3.57.57.55 0 1 .45 1 1V20c0 .55-.45 1-1 1-9.39 0-17-7.61-17-17 0-.55.45-1 1-1h3.5c.55 0 1 .45 1 1 0 1.25.2 2.45.57 3.57.11.35.03.74-.25 1.02l-2.2 2.2z';

  pw.Widget waIcon(double size) {
    final path = st.whatsappIconPath;
    if (path != null && path.isNotEmpty) {
      try {
        final f = File(path);
        if (f.existsSync()) return pw.SizedBox(width: size, height: size, child: pw.Image(pw.MemoryImage(f.readAsBytesSync())));
      } catch (_) {}
    }
    return pw.Container(
      width: size,
      height: size,
      padding: pw.EdgeInsets.all(size * 0.2),
      decoration: const pw.BoxDecoration(color: _waGreen, shape: pw.BoxShape.circle),
      child: pw.SvgImage(svg: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path fill="#FFFFFF" d="$_handset"/></svg>'),
    );
  }

  bool get hasContact => st.contactPerson.trim().isNotEmpty || st.contactPhone.trim().isNotEmpty;

  /// "Contact: M. Osama  (icon) 0371-5263580"; the icon and number open
  /// WhatsApp in PDF readers that support links.
  pw.Widget contactLine({double fontSize = 9.5, pw.MainAxisAlignment align = pw.MainAxisAlignment.start}) {
    final person = st.contactPerson.trim();
    final phone = st.contactPhone.trim();
    final link = waLink;
    final number = pw.Row(mainAxisSize: pw.MainAxisSize.min, children: [
      waIcon(fontSize + 3),
      pw.SizedBox(width: 3),
      pw.Text(ascii(phone), style: pw.TextStyle(fontSize: fontSize, fontWeight: pw.FontWeight.bold, color: const PdfColor.fromInt(0xFF128C7E))),
    ]);
    return pw.Row(mainAxisAlignment: align, mainAxisSize: pw.MainAxisSize.min, crossAxisAlignment: pw.CrossAxisAlignment.center, children: [
      if (person.isNotEmpty) pw.Text(ascii('Contact: $person'), style: pw.TextStyle(fontSize: fontSize, fontWeight: pw.FontWeight.bold)),
      if (person.isNotEmpty && phone.isNotEmpty) pw.SizedBox(width: 8),
      if (phone.isNotEmpty) link == null ? number : pw.UrlLink(destination: link, child: number),
    ]);
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
            if (hasContact) pw.Padding(padding: const pw.EdgeInsets.only(top: 3), child: contactLine()),
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

/// Item name for a bill line, marking non-stock items and services.
String _lineName(SaleItem it) => switch (it.kind) {
      SaleLineKind.product => it.name,
      SaleLineKind.nonStock => '${it.name}${it.unit.isEmpty ? '' : ' (${it.unit})'}',
      SaleLineKind.service => '${it.name} [Labour${it.unit.isEmpty ? '' : ', ${it.unit}'}]',
    };

/// [paid] is what has been paid against the invoice so far (all payments,
/// not only at the counter); defaults to the amount paid at sale.
Future<Uint8List> invoicePdf(AppSettings st, Sale sale, {Party? customer, PaperKind paper = PaperKind.a4, String cashier = '', Money? paid}) async {
  if (paper != PaperKind.a4) return _thermalInvoice(st, sale, paper, cashier: cashier, paid: paid);
  final h = PdfHelper(st);
  final doc = pw.Document(title: sale.number, author: st.businessName);
  final paidSoFar = paid ?? sale.paidAtSale;
  final remaining = sale.total - paidSoFar;
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(32),
    build: (_) => [
      h.header(sale.status == DocStatus.cancelled ? 'Invoice (CANCELLED)' : 'Invoice', [
        ('Invoice No', sale.number),
        ('Date', _dt.format(sale.date)),
        if (sale.edited) ('Revised', _dt.format(sale.edits.last.at)),
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
              '${_lineName(sale.items[k])}${_serialLine(sale.items[k].serials)}',
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
        (paid == null ? 'Paid (${sale.method.label})' : 'Paid to date', money(paidSoFar, st), false),
        (remaining.isNegative ? 'Paid in excess (credit)' : 'Balance Due', money(remaining.isNegative ? -remaining : remaining, st), remaining.isPositive),
      ]),
      if (sale.notes.isNotEmpty) pw.Padding(padding: const pw.EdgeInsets.only(top: 12), child: pw.Text(ascii('Notes: ${sale.notes}'), style: const pw.TextStyle(fontSize: 9))),
      h.footer(st.receiptFooter),
    ],
  ));
  return doc.save();
}

Future<Uint8List> _thermalInvoice(AppSettings st, Sale sale, PaperKind paper, {String cashier = '', Money? paid}) async {
  final paidSoFar = paid ?? sale.paidAtSale;
  final remaining = sale.total - paidSoFar;
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
      if (PdfHelper(st).hasContact)
        pw.Padding(padding: const pw.EdgeInsets.only(top: 2), child: pw.Center(child: PdfHelper(st).contactLine(fontSize: fs, align: pw.MainAxisAlignment.center))),
      pw.Divider(borderStyle: pw.BorderStyle.dashed),
      row('Invoice', sale.number, bold: true),
      row('Date', _dt.format(sale.date)),
      if (sale.edited) row('Revised', _dt.format(sale.edits.last.at)),
      row('Customer', sale.customerName),
      if (cashier.isNotEmpty) row('Cashier', cashier),
      if (sale.status == DocStatus.cancelled) pw.Text('*** CANCELLED ***', textAlign: pw.TextAlign.center, style: pw.TextStyle(fontSize: fs + 1, fontWeight: pw.FontWeight.bold)),
      pw.Divider(borderStyle: pw.BorderStyle.dashed),
      for (final it in sale.items) ...[
        pw.Text(ascii(_lineName(it)), style: pw.TextStyle(fontSize: fs, fontWeight: pw.FontWeight.bold)),
        row('  ${it.qty.format()} x ${money(it.unitPrice, st)}${it.discount.isZero ? '' : ' - ${money(it.discount, st)}'}', money(it.net, st)),
        if (it.serials.isNotEmpty) pw.Text(ascii('  S/N: ${it.serials.map(SerialRecord.displayOf).join(', ')}'), style: pw.TextStyle(fontSize: fs - 1)),
      ],
      pw.Divider(borderStyle: pw.BorderStyle.dashed),
      row('Subtotal', money(sale.subtotal - sale.lineDiscounts, st)),
      if (!sale.invoiceDiscount.isZero) row('Discount', '- ${money(sale.invoiceDiscount, st)}'),
      row('TOTAL', money(sale.total, st), bold: true),
      row(paid == null ? 'Paid (${sale.method.label})' : 'Paid to date', money(paidSoFar, st)),
      if (remaining.isPositive) row('Balance due', money(remaining, st), bold: true),
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

// ───────────────────────── Labour bill (worker / karegar) ─────────────────────────

/// Labour / installation bill: the worker's charges, separate from the shop
/// invoice.
Future<Uint8List> labourBillPdf(AppSettings st, LabourBill b) async {
  final h = PdfHelper(st);
  final doc = pw.Document(title: b.number);
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a5,
    margin: const pw.EdgeInsets.all(24),
    build: (_) => [
      h.header('Labour / Installation Bill', [
        ('Bill No', b.number),
        ('Date', _dt.format(b.date)),
        if (b.saleNumber.isNotEmpty) ('With invoice', b.saleNumber),
      ]),
      pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Expanded(
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text('Customer', style: const pw.TextStyle(fontSize: 9, color: _grey)),
            pw.Text(ascii(b.customerName), style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
            if (b.customerPhone.isNotEmpty) pw.Text(ascii(b.customerPhone), style: const pw.TextStyle(fontSize: 9)),
          ]),
        ),
        if (b.workerName.isNotEmpty)
          pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
            pw.Text('Worker (karegar)', style: const pw.TextStyle(fontSize: 9, color: _grey)),
            pw.Text(ascii(b.workerName), style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
          ]),
      ]),
      pw.SizedBox(height: 10),
      h.table(
        ['Labour / installation', 'Qty', 'Rate', 'Amount'],
        [
          for (final l in b.lines) ['${l.description}${l.unit.isEmpty ? '' : ' (${l.unit})'}', l.qty.format(), money(l.rate, st), money(l.amount, st)]
        ],
        align: {1: pw.Alignment.centerRight, 2: pw.Alignment.centerRight, 3: pw.Alignment.centerRight},
        widths: {0: const pw.FlexColumnWidth(4), 1: const pw.FlexColumnWidth(1), 2: const pw.FlexColumnWidth(1.6), 3: const pw.FlexColumnWidth(1.8)},
      ),
      h.totals([
        if (b.discount.isPositive) ('Subtotal', money(b.subtotal, st), false),
        if (b.discount.isPositive) ('Discount', '- ${money(b.discount, st)}', false),
        ('Labour total', money(b.total, st), true),
        ('Received', money(b.collected, st), false),
        ('Balance due', money(b.due, st), b.due.isPositive),
      ]),
      pw.SizedBox(height: 6),
      pw.Text('Labour charges belong to the worker and are billed separately from the shop invoice.', style: const pw.TextStyle(fontSize: 8, color: _grey)),
      if (b.cancelled) pw.Text(ascii('CANCELLED: ${b.cancelReason}'), style: pw.TextStyle(fontSize: 10, color: PdfColors.red, fontWeight: pw.FontWeight.bold)),
      if (b.notes.isNotEmpty) pw.Padding(padding: const pw.EdgeInsets.only(top: 4), child: pw.Text(ascii('Notes: ${b.notes}'), style: const pw.TextStyle(fontSize: 9))),
    ],
  ));
  return doc.save();
}

// ───────────────────────── Return receipt / credit note ─────────────────────────

/// Receipt for a customer return: a cash refund receipt, or a credit note
/// when the amount was adjusted in the customer's account.
Future<Uint8List> returnReceiptPdf(AppSettings st, ReturnDoc r, {Party? customer, Money? balanceAfter}) async {
  final h = PdfHelper(st);
  final cash = r.refundMode == RefundMode.cash;
  final doc = pw.Document(title: r.number);
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a5,
    margin: const pw.EdgeInsets.all(24),
    build: (_) => [
      h.header(cash ? 'Return Receipt - Cash Refund' : 'Credit Note - Account Adjustment', [
        ('Return No', r.number),
        ('Date', _dt.format(r.date)),
        ('Invoice', r.originalNumber),
      ]),
      pw.Text('Customer', style: const pw.TextStyle(fontSize: 9, color: _grey)),
      pw.Text(ascii(customer?.name ?? 'Walk-in Customer'), style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
      if (customer != null && customer.phone.isNotEmpty) pw.Text(ascii(customer.phone), style: const pw.TextStyle(fontSize: 9)),
      pw.SizedBox(height: 10),
      h.table(
        ['Returned product', 'Qty', 'Condition', 'Amount'],
        [
          for (final l in r.lines)
            [
              '${l.name}${_serialLine(l.serials)}',
              l.qty.format(),
              returnConditionLabel(l.condition),
              money(l.amount, st),
            ]
        ],
        align: {1: pw.Alignment.centerRight, 3: pw.Alignment.centerRight},
        widths: {0: const pw.FlexColumnWidth(4), 1: const pw.FlexColumnWidth(1), 2: const pw.FlexColumnWidth(1.6), 3: const pw.FlexColumnWidth(1.8)},
      ),
      h.totals([
        (cash ? 'Cash refunded (${r.method.label})' : 'Credited to customer account', money(r.total, st), true),
      ]),
      pw.SizedBox(height: 6),
      pw.Text(ascii('Reason: ${r.reason}'), style: const pw.TextStyle(fontSize: 9)),
      if (balanceAfter != null)
        pw.Padding(
          padding: const pw.EdgeInsets.only(top: 4),
          child: pw.Text(
              ascii(balanceAfter.isNegative
                  ? 'Customer credit after this return: ${money(-balanceAfter, st)} (adjusted against future invoices)'
                  : 'Customer balance after this return: ${money(balanceAfter, st)}'),
              style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
        ),
      pw.SizedBox(height: 30),
      pw.Row(children: [
        pw.Expanded(child: pw.Text('Customer signature: ________________', style: const pw.TextStyle(fontSize: 9))),
        pw.Text('Authorised: ________________', style: const pw.TextStyle(fontSize: 9)),
      ]),
    ],
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

// ───────────────────────── Detailed customer statement (A4) ─────────────────────────

String _num(Money m0) => m0.isNegative ? '-${(-m0).format(symbol: '').trim()}' : m0.format(symbol: '').trim();
String _bal(Money m0) => m0.isNegative ? '${_num(-m0)} Adv' : _num(m0);

/// Full customer statement on A4: shop and customer details, every invoice
/// with its product lines, payments, returns and adjustments with a running
/// balance, a summary, and the paid / partly paid / unpaid state of every
/// invoice. Column headers repeat on every page; pages are numbered.
Future<Uint8List> customerStatementPdf(AppSettings st, CustomerStatement s) async {
  final h = PdfHelper(st);
  final c = s.customer;
  final doc = pw.Document(title: 'Customer Statement ${c.name}');
  final period = s.from == null && s.to == null
      ? 'Complete history (to ${_d.format(s.generatedAt)})'
      : '${s.from == null ? 'Start' : _d.format(s.from!)} to ${_d.format(s.to ?? s.generatedAt)}';
  const fs = 7.6;
  const head = ['Date', 'Voucher / Inv. No.', 'Product / Transaction Description', 'Qty', 'Unit Price', 'Total Price', 'Debit', 'Credit', 'Balance'];
  const widths = <int, pw.TableColumnWidth>{
    0: pw.FixedColumnWidth(50),
    1: pw.FixedColumnWidth(56),
    2: pw.FlexColumnWidth(),
    3: pw.FixedColumnWidth(28),
    4: pw.FixedColumnWidth(48),
    5: pw.FixedColumnWidth(52),
    6: pw.FixedColumnWidth(52),
    7: pw.FixedColumnWidth(52),
    8: pw.FixedColumnWidth(58),
  };
  const right = {3, 4, 5, 6, 7, 8};
  const border = PdfColor.fromInt(0xFF9CA3AF);

  PdfColor? shade(StmtRowKind k) => switch (k) {
        StmtRowKind.opening => const PdfColor.fromInt(0xFFE5E7EB),
        StmtRowKind.invoiceTotal || StmtRowKind.repairTotal => const PdfColor.fromInt(0xFFEFF6F2),
        StmtRowKind.payment => const PdfColor.fromInt(0xFFE7F5EC),
        StmtRowKind.returnTotal || StmtRowKind.invoiceCancel || StmtRowKind.adjustment => const PdfColor.fromInt(0xFFFFF4E0),
        StmtRowKind.refund || StmtRowKind.paymentVoid => const PdfColor.fromInt(0xFFFDECEC),
        StmtRowKind.invoiceEdit => const PdfColor.fromInt(0xFFE8F0FE),
        _ => null,
      };

  pw.Widget cell(String text, int col, {bool bold = false, PdfColor color = PdfColors.black}) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 3),
        child: pw.Text(ascii(text),
            textAlign: right.contains(col) ? pw.TextAlign.right : pw.TextAlign.left,
            style: pw.TextStyle(fontSize: fs, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal, color: color)),
      );

  final invoiceState = {for (final i in s.invoices) i.number: i};
  final tableRows = <pw.TableRow>[
    pw.TableRow(
      repeat: true,
      decoration: const pw.BoxDecoration(color: _emerald),
      children: [
        for (var i = 0; i < head.length; i++)
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 4),
            child: pw.Text(head[i],
                textAlign: right.contains(i) ? pw.TextAlign.right : pw.TextAlign.left,
                style: pw.TextStyle(fontSize: fs, fontWeight: pw.FontWeight.bold, color: PdfColors.white)),
          ),
      ],
    ),
  ];
  for (final r in s.rows) {
    final posting = r.isPosting;
    final bold = posting;
    var desc = r.description;
    if (r.kind == StmtRowKind.invoiceTotal) {
      final inv = invoiceState[r.voucher];
      if (inv != null) {
        desc += switch (inv.state) {
          InvoiceState.paid => ' - PAID',
          InvoiceState.partlyPaid => ' - PARTLY PAID (due ${_num(inv.due)})',
          InvoiceState.unpaid => ' - UNPAID',
          InvoiceState.cancelled => ' - CANCELLED',
        };
      }
    }
    final grey = posting ? PdfColors.black : const PdfColor.fromInt(0xFF374151);
    tableRows.add(pw.TableRow(
      decoration: shade(r.kind) == null ? null : pw.BoxDecoration(color: shade(r.kind)),
      children: [
        cell(r.date == null ? '' : _d.format(r.date!), 0, color: grey),
        cell(r.voucher, 1, color: grey),
        cell(desc, 2, bold: bold),
        cell(r.qty?.format() ?? '', 3),
        cell(r.unitPrice == null ? '' : _num(r.unitPrice!), 4),
        cell(r.totalPrice == null ? '' : _num(r.totalPrice!), 5, bold: bold && r.totalPrice != null),
        cell(posting && r.debit.isPositive ? _num(r.debit) : '', 6, bold: true),
        cell(posting && r.credit.isPositive ? _num(r.credit) : '', 7, bold: true),
        cell(posting ? _bal(r.balance!) : '', 8, bold: true),
      ],
    ));
  }
  tableRows.add(pw.TableRow(
    decoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFE5E7EB)),
    children: [
      cell('', 0),
      cell('', 1),
      cell('TOTAL (opening + transactions)', 2, bold: true),
      cell('', 3),
      cell('', 4),
      cell('', 5),
      cell(_num(s.totalDebit + (s.openingBalance.isPositive ? s.openingBalance : const Money.zero())), 6, bold: true),
      cell(_num(s.totalCredit + (s.openingBalance.isNegative ? -s.openingBalance : const Money.zero())), 7, bold: true),
      cell(_bal(s.closingBalance), 8, bold: true),
    ],
  ));

  pw.Widget infoBox(String title, List<String> lines, {pw.CrossAxisAlignment align = pw.CrossAxisAlignment.start}) => pw.Container(
        padding: const pw.EdgeInsets.all(8),
        decoration: pw.BoxDecoration(border: pw.Border.all(color: border, width: 0.6)),
        child: pw.Column(crossAxisAlignment: align, children: [
          pw.Text(title, style: const pw.TextStyle(fontSize: 7.5, color: _grey)),
          pw.SizedBox(height: 2),
          for (var i = 0; i < lines.length; i++)
            pw.Text(ascii(lines[i]), style: pw.TextStyle(fontSize: i == 0 ? 11 : 8.5, fontWeight: i == 0 ? pw.FontWeight.bold : pw.FontWeight.normal)),
        ]),
      );

  final closingWord = s.closingBalance.isNegative ? 'Advance with us' : 'Closing outstanding balance';
  final summary = <(String, String, bool)>[
    ('Opening balance', _bal(s.openingBalance), false),
    ('Total purchases / debit (+)', _num(s.totalDebit), false),
    ('Total payments received (-)', _num(s.totalPayments), false),
    ('Total returns (-)', _num(s.totalReturns), false),
    ('Adjustments / cancellations (-)', _num(s.totalOtherCredits), false),
    ('$closingWord (Rs)', _bal(s.closingBalance), true),
  ];

  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.fromLTRB(24, 24, 24, 28),
    maxPages: 1000,
    header: (ctx) => ctx.pageNumber == 1
        ? pw.SizedBox()
        : pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 6),
            child: pw.Row(children: [
              pw.Expanded(child: pw.Text(ascii('${st.businessName} - Customer Statement: ${c.name}'), style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold, color: _emerald))),
              pw.Text(ascii(period), style: const pw.TextStyle(fontSize: 8, color: _grey)),
            ]),
          ),
    footer: (ctx) => pw.Container(
      margin: const pw.EdgeInsets.only(top: 6),
      padding: const pw.EdgeInsets.only(top: 3),
      decoration: const pw.BoxDecoration(border: pw.Border(top: pw.BorderSide(color: _line, width: 0.6))),
      child: pw.Row(children: [
        pw.Expanded(child: pw.Text(ascii('Generated ${_dt.format(s.generatedAt)} - ${st.businessName}'), style: const pw.TextStyle(fontSize: 7.5, color: _grey))),
        if (h.hasContact) ...[h.contactLine(fontSize: 7.5), pw.SizedBox(width: 12)],
        pw.Text('Page ${ctx.pageNumber} of ${ctx.pagesCount}', style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
      ]),
    ),
    build: (_) => [
      h.header('Customer Statement', [
        ('Statement date', _d.format(s.generatedAt)),
        ('Period', period),
        ('Currency', st.currencySymbol),
      ]),
      pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Expanded(
          flex: 3,
          child: infoBox('CUSTOMER', [
            c.name,
            if (c.company.isNotEmpty) c.company,
            [if (c.phone.isNotEmpty) 'Mobile: ${c.phone}', if (c.altPhone.isNotEmpty) 'Alt: ${c.altPhone}'].join('   '),
            if (c.address.isNotEmpty) c.address,
            if (c.email.isNotEmpty) c.email,
          ].where((e) => e.isNotEmpty).toList()),
        ),
        pw.SizedBox(width: 10),
        pw.Expanded(
          flex: 2,
          child: infoBox(closingWord.toUpperCase(), [
            '${st.currencySymbol} ${_bal(s.closingBalance)}',
            'Opening: ${_bal(s.openingBalance)}',
            'Debit: ${_num(s.totalDebit)}   Credit: ${_num(s.totalCredit)}',
          ], align: pw.CrossAxisAlignment.end),
        ),
      ]),
      pw.SizedBox(height: 10),
      pw.Table(
        columnWidths: widths,
        border: pw.TableBorder.all(color: border, width: 0.5),
        children: tableRows,
      ),
      pw.SizedBox(height: 4),
      pw.Text('Debit = goods / charges added to the account. Credit = payments, returns and adjustments. Balance = amount the customer owes; "Adv" = advance held for the customer.',
          style: const pw.TextStyle(fontSize: 7, color: _grey)),
      pw.SizedBox(height: 10),
      pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Expanded(
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text(ascii('Customer: ${c.name}'), style: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold)),
            pw.Text(ascii('Invoices: ${s.invoices.length}  -  Paid: ${s.invoices.where((i) => i.state == InvoiceState.paid).length}  -  '
                'Partly paid: ${s.invoices.where((i) => i.state == InvoiceState.partlyPaid).length}  -  Unpaid: ${s.invoices.where((i) => i.state == InvoiceState.unpaid).length}'
                '${s.invoices.any((i) => i.state == InvoiceState.cancelled) ? '  -  Cancelled: ${s.invoices.where((i) => i.state == InvoiceState.cancelled).length}' : ''}'),
                style: const pw.TextStyle(fontSize: 8)),
            if (s.onAccountPayments.isPositive) ...[
              pw.SizedBox(height: 4),
              pw.Text(ascii('Payments received on account (not against a specific invoice): ${_num(s.onAccountPayments)}. They reduce the account balance, not a single invoice.'),
                  style: const pw.TextStyle(fontSize: 7, color: _grey)),
            ],
          ]),
        ),
        pw.SizedBox(width: 14),
        pw.Container(
          width: 215,
          padding: const pw.EdgeInsets.all(8),
          decoration: pw.BoxDecoration(border: pw.Border.all(color: _emerald, width: 1)),
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
            pw.Text('STATEMENT SUMMARY', style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, color: _emerald)),
            pw.SizedBox(height: 4),
            for (final r in summary)
              pw.Container(
                padding: const pw.EdgeInsets.symmetric(vertical: 2.5),
                decoration: r.$3 ? const pw.BoxDecoration(border: pw.Border(top: pw.BorderSide(color: PdfColors.black, width: 0.8))) : null,
                child: pw.Row(children: [
                  pw.Expanded(child: pw.Text(r.$1, style: pw.TextStyle(fontSize: r.$3 ? 9 : 8, fontWeight: r.$3 ? pw.FontWeight.bold : pw.FontWeight.normal))),
                  pw.Text(r.$2, style: pw.TextStyle(fontSize: r.$3 ? 10 : 8, fontWeight: r.$3 ? pw.FontWeight.bold : pw.FontWeight.normal)),
                ]),
              ),
            pw.SizedBox(height: 3),
            pw.Text('Closing = Opening + Debit - Credit', style: const pw.TextStyle(fontSize: 6.5, color: _grey)),
            if (s.coversToday && s.closingBalance != s.accountBalance)
              pw.Text(ascii('Note: the account balance in the software is ${_bal(s.accountBalance)}.'), style: const pw.TextStyle(fontSize: 7, color: PdfColors.red)),
          ]),
        ),
      ]),
      pw.SizedBox(height: 12),
      pw.Text('INVOICE STATUS', style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, color: _emerald)),
      pw.SizedBox(height: 4),
      if (s.invoices.isEmpty)
        pw.Text('No invoices in this period.', style: const pw.TextStyle(fontSize: 8, color: _grey))
      else
        pw.TableHelper.fromTextArray(
          headers: ['Invoice', 'Date', 'Invoice amount', 'Returns', 'Paid against invoice', 'Due', 'Status'],
          data: [
            for (final i in s.invoices)
              [i.number, _d.format(i.date), _num(i.total), i.returns.isZero ? '' : _num(i.returns), _num(i.paid), i.state == InvoiceState.cancelled ? '' : _bal(i.due), i.state.label],
          ],
          headerStyle: pw.TextStyle(fontSize: 7.5, fontWeight: pw.FontWeight.bold),
          headerDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFE5E7EB)),
          cellStyle: const pw.TextStyle(fontSize: 7.5),
          cellAlignments: {2: pw.Alignment.centerRight, 3: pw.Alignment.centerRight, 4: pw.Alignment.centerRight, 5: pw.Alignment.centerRight},
          border: pw.TableBorder.all(color: border, width: 0.5),
          cellPadding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 2.5),
        ),
      pw.SizedBox(height: 12),
      pw.Text('PRODUCT RETURNS', style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, color: _emerald)),
      pw.SizedBox(height: 4),
      if (s.returns.isEmpty)
        pw.Text('No returns in this period.', style: const pw.TextStyle(fontSize: 8, color: _grey))
      else ...[
        pw.TableHelper.fromTextArray(
          headers: ['Return date', 'Return No.', 'Invoice', 'Returned product', 'Qty', 'Amount', 'Condition', 'Reason', 'Settled as'],
          data: [
            for (final r in s.returns)
              [
                _d.format(r.date),
                r.number,
                r.invoiceNumber,
                '${r.productName}${r.serials.isEmpty ? '' : '\nS/N: ${r.serials.map(SerialRecord.displayOf).join(', ')}'}',
                r.qty.format(),
                _num(r.amount),
                returnConditionLabel(r.condition),
                r.reason,
                r.refundMode == RefundMode.cash ? 'Cash refund' : 'Account credit',
              ].map(ascii).toList(),
          ],
          headerStyle: pw.TextStyle(fontSize: 7.2, fontWeight: pw.FontWeight.bold),
          headerDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFFFF4E0)),
          cellStyle: const pw.TextStyle(fontSize: 7.2),
          columnWidths: const {
            0: pw.FixedColumnWidth(46),
            1: pw.FixedColumnWidth(50),
            2: pw.FixedColumnWidth(50),
            3: pw.FlexColumnWidth(2),
            4: pw.FixedColumnWidth(24),
            5: pw.FixedColumnWidth(48),
            6: pw.FixedColumnWidth(44),
            7: pw.FlexColumnWidth(1.4),
            8: pw.FixedColumnWidth(48),
          },
          cellAlignments: {4: pw.Alignment.centerRight, 5: pw.Alignment.centerRight},
          border: pw.TableBorder.all(color: border, width: 0.5),
          cellPadding: const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 2.5),
        ),
        pw.SizedBox(height: 3),
        pw.Text(
            ascii('Total returns: ${_num(s.totalReturns)} (credit). Saleable items went back to stock; faulty items are kept aside for inspection; damaged items are kept as damaged stock. '
                'A cash refund also appears as a debit row, because the money was paid back.'),
            style: const pw.TextStyle(fontSize: 7, color: _grey)),
      ],
      pw.SizedBox(height: 34),
      pw.Row(children: [
        pw.Expanded(child: pw.Column(children: [pw.Container(height: 0.6, color: PdfColors.black, margin: const pw.EdgeInsets.symmetric(horizontal: 30)), pw.SizedBox(height: 3), pw.Text('Customer signature', style: const pw.TextStyle(fontSize: 8))])),
        pw.Expanded(child: pw.Column(children: [pw.Container(height: 0.6, color: PdfColors.black, margin: const pw.EdgeInsets.symmetric(horizontal: 30)), pw.SizedBox(height: 3), pw.Text('Authorised signature', style: const pw.TextStyle(fontSize: 8))])),
      ]),
      if (st.receiptFooter.trim().isNotEmpty) ...[
        pw.SizedBox(height: 10),
        pw.Center(child: pw.Text(ascii(st.receiptFooter.trim()), style: const pw.TextStyle(fontSize: 8, color: _grey))),
      ],
    ],
  ));
  return doc.save();
}

/// Builds [customerStatementPdf] on a background isolate (large histories).
Future<Uint8List> customerStatementPdfInBackground(AppSettings st, CustomerStatement s) => Isolate.run(() => customerStatementPdf(st, s));

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
