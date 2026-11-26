// Shop contact (M. Osama, 0371-5263580) with a WhatsApp link on every
// customer-facing PDF: invoices (A4 and thermal), payment receipt, return
// receipt / credit note, statements, quotation, repair receipt.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:al_aqsa_cctv/domain/models/documents.dart';
import 'package:al_aqsa_cctv/domain/models/operations.dart';
import 'package:al_aqsa_cctv/domain/models/party.dart';
import 'package:al_aqsa_cctv/domain/services/purchase_service.dart';
import 'package:al_aqsa_cctv/printing/pdf_docs.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

final _png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() async => env.dispose());

  test('defaults and the WhatsApp link', () {
    const st = AppSettings();
    expect((st.contactPerson, st.contactPhone), ('M. Osama', '0371-5263580'));
    expect(PdfHelper(st).waLink, 'https://wa.me/923715263580');
    // Older saved settings without the fields get the defaults.
    final old = AppSettings.fromJson({'businessName': 'AL-AQSA CCTV & SOLAR SYSTEM'});
    expect((old.contactPerson, old.contactPhone), ('M. Osama', '0371-5263580'));
    // Kept through save / load; can be changed or cleared.
    final changed = AppSettings.fromJson(st.merge({'contactPerson': 'Ali', 'contactPhone': '+92 300 1234567'}).toJson());
    expect(PdfHelper(changed).waLink, 'https://wa.me/923001234567');
    expect(PdfHelper(AppSettings.fromJson(st.merge({'contactPerson': '', 'contactPhone': ''}).toJson())).hasContact, isFalse);
    expect(PdfHelper(AppSettings.fromJson(st.merge({'contactPhone': '051-1234567'}).toJson())).waLink, isNull); // landline: no link
  });

  test('every customer document builds with the contact line and link', () async {
    final app = env.app;
    final out = Platform.environment['CONTACT_PDF_OUT'];
    final cam = await env.product('Dahua 4MP Dome', cost: 4000, price: 6500);
    final sup = await env.supplier();
    await app.purchases.create(supplierId: sup.id, date: env.clock.now, lines: [PurchaseLineInput(productId: cam.id, qty: q(5), unitCost: rs(4000))]);
    final c = await app.parties.create(kind: PartyKind.customer, name: 'DEMO Contact Grahak', phone: '0300 1112223', openingBalance: rs(1000));
    final sale = await app.sales.complete(app.sales.newDraft().copyWith(customerId: c.id, customerName: c.name, items: [
      app.sales.lineFor(env.reload(cam.id), qty: q(2)),
      SaleItem.custom(kind: SaleLineKind.nonStock, name: 'Cable Clips', qty: q(500), unitPrice: rs(2), unit: 'pcs'),
    ]).copyWith(paidAtSale: rs(10000)));
    final pay = await app.parties.addPayment(kind: PartyKind.customer, partyId: c.id, amount: rs(3000), method: PaymentMethod.cash);
    final ret = await app.sales.createReturn(saleId: sale.id, lines: [ReturnLineInput(productId: cam.id, qty: q(1))], reason: 'extra', refundMode: RefundMode.accountCredit);
    final st = app.ctx.settings;
    final docs = <String, Uint8List>{
      'invoice_a4': await invoicePdf(st, sale, customer: c, paid: app.sales.paidAgainst(sale.id)),
      'invoice_thermal80': await invoicePdf(st, sale, customer: c, paper: PaperKind.thermal80),
      'invoice_thermal58': await invoicePdf(st, sale, customer: c, paper: PaperKind.thermal58),
      'payment_receipt': await paymentReceiptPdf(st, pay, party: c, balanceAfter: app.parties.byId(PartyKind.customer, c.id)!.balance),
      'return_receipt': await returnReceiptPdf(st, ret, customer: c, balanceAfter: app.sales.customerBalanceAfterReturn(ret)),
      'customer_statement': await customerStatementPdf(st, app.customerStatements.build(c.id)),
      'account_statement': await statementPdf(st, app.parties.statement(PartyKind.customer, c.id)),
    };
    for (final e in docs.entries) {
      expect(String.fromCharCodes(e.value.take(4)), '%PDF', reason: e.key);
      // The link annotation is written as plain text in the PDF.
      expect(latin1.decode(e.value, allowInvalid: true).contains('https://wa.me/923715263580'), isTrue, reason: '${e.key}: WhatsApp link');
      if (out != null) await File('$out/${e.key}.pdf').writeAsBytes(e.value);
    }

    // A chosen icon image is used instead of the built-in badge.
    final icon = File('${env.tmp.path}/wa.png')..writeAsBytesSync(_png);
    final st2 = AppSettings.fromJson(st.merge({'whatsappIconPath': icon.path}).toJson());
    final withIcon = await invoicePdf(st2, sale, customer: c);
    expect(String.fromCharCodes(withIcon.take(4)), '%PDF');
    expect(latin1.decode(withIcon, allowInvalid: true).contains('/Subtype /Image') || latin1.decode(withIcon, allowInvalid: true).contains('/Image'), isTrue);
  });
}
