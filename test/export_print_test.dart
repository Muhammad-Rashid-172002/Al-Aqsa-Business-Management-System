import 'dart:convert';
import 'dart:io';

import 'package:al_aqsa_cctv/domain/models/documents.dart';
import 'package:al_aqsa_cctv/domain/models/party.dart';
import 'package:al_aqsa_cctv/domain/services/purchase_service.dart';
import 'package:al_aqsa_cctv/export/tabular.dart';
import 'package:al_aqsa_cctv/printing/pdf_docs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'helpers.dart';

bool isPdf(List<int> b) => b.length > 500 && String.fromCharCodes(b.sublist(0, 5)) == '%PDF-';

void main() {
  test('XLSX export round-trips text and numbers', () {
    final t = ExportTable('Stock & Value', ['Product', 'Qty', 'Value'], [
      ['Cable "Cat6" <305m>', 1.5, 120.25],
      ['DVR', 2, 9000],
    ], footer: [
      ['Total', 3.5, 9120.25]
    ]);
    final bytes = buildXlsx([t]);
    final rows = readXlsx(bytes);
    // Title, generation time, blank line, then the table.
    expect(rows[0], ['Stock & Value']);
    expect(rows[1].single.startsWith('Generated: '), isTrue);
    expect(rows[3], ['Product', 'Qty', 'Value']);
    expect(rows[4], ['Cable "Cat6" <305m>', '1.5', '120.25']);
    expect(rows.last, ['Total', '3.5', '9120.25']);
  });

  test('CSV export and parsing handle quotes, commas and new lines', () {
    final csv = buildCsv(ExportTable('', ['name', 'note'], [
      ['A, B', 'say "hi"'],
      ['Line', 'one\ntwo'],
    ]));
    final rows = parseCsv(csv);
    expect(rows, [
      ['name', 'note'],
      ['A, B', 'say "hi"'],
      ['Line', 'one\ntwo'],
    ]);
    final maps = rowsToMaps(rows);
    expect(maps.first['name'], 'A, B');
  });

  test('Bulk product import from spreadsheet rows', () async {
    final env = await TestEnv.create();
    final rows = rowsToMaps(parseCsv('name,brand,category,purchase_price,selling_price,min_stock,unit,decimal,serial,warranty_months,barcode\n'
        'Cat6 Cable,Generic,Cables,40,70,50,m,yes,no,0,\n'
        'Dome 2MP,Hikvision,Cameras,4000,6000,5,pcs,no,yes,12,6941264012345\n'
        ',,,,,,,,,,\n'
        'Bad Price,X,Y,abc,1,1,pcs,no,no,0,\n'));
    final msgs = await env.app.catalog.bulkImport(rows);
    expect(msgs.where((m0) => m0.contains('imported')).length, 2);
    expect(msgs.any((m0) => m0.contains('skipped')), isTrue);
    final cable = env.app.catalog.search('Cat6').single;
    expect(cable.allowDecimal, isTrue);
    expect(cable.minStock, q(50));
    expect(env.app.catalog.lookup('6941264012345')!.product.name, 'Dome 2MP');
    expect(env.app.catalog.categories().length, 2);
    await env.dispose();
  });

  test('All printable documents render valid PDFs', () async {
    final env = await TestEnv.create();
    final app = env.app;
    final st = app.ctx.settings;
    final s = await env.supplier();
    final c = await env.customer();
    final cam = await env.product('IP Camera 4MP', serial: true, brand: 'Dahua');
    final cable = await env.product('Cable', decimal: true, cost: 40, price: 70);
    final pur = await app.purchases.create(supplierId: s.id, date: env.clock.now, lines: [
      PurchaseLineInput(productId: cam.id, qty: q(2), unitCost: rs(5000), serials: ['D1', 'D2']),
      PurchaseLineInput(productId: cable.id, qty: q(100), unitCost: rs(40)),
    ], paid: rs(1000));
    final sale = await app.sales.complete(app.sales.newDraft().copyWith(customerId: c.id, items: [
      SaleItem(productId: cam.id, name: cam.name, qty: q(1), unitPrice: rs(7500), serials: ['D1']),
      SaleItem(productId: cable.id, name: cable.name, qty: Qty.parse('12.5'), unitPrice: rs(70)),
    ], paidAtSale: rs(5000)));
    for (final paper in PaperKind.values) {
      expect(isPdf(await invoicePdf(st, sale, customer: c, paper: paper, cashier: 'Owner')), isTrue);
    }
    expect(isPdf(await purchasePdf(st, pur, s)), isTrue);
    final quote = await app.quotations.save(app.quotations.newDraft(customerId: c.id, customerName: c.name).copyWith(items: [
      QuotationItem(productId: cam.id, name: cam.name, qty: q(4), unitPrice: rs(7000)),
    ]));
    expect(isPdf(await quotationPdf(st, quote, customer: c)), isTrue);
    final pay = await app.parties.addPayment(kind: PartyKind.customer, partyId: c.id, amount: rs(2000), method: PaymentMethod.cash);
    expect(isPdf(await paymentReceiptPdf(st, pay, party: c, balanceAfter: app.parties.byId(PartyKind.customer, c.id)!.balance)), isTrue);
    final job = await app.repairs.receive(customerName: 'Walk-in', productName: 'NVR', reportedIssue: 'No HDD detected');
    expect(isPdf(await repairReceiptPdf(st, job)), isTrue);
    expect(isPdf(await statementPdf(st, app.parties.statement(PartyKind.customer, c.id))), isTrue);
    expect(isPdf(await labelsPdf(st, [LabelJob(cam, 2), LabelJob(cam, 1, serialKey: 'DAHUA|D2')])), isTrue);
    expect(isPdf(await reportPdf(st, ExportTable('Sales', ['Invoice', 'Total'], [['INV-1', 100.0]]))), isTrue);
    await env.dispose();
  });

  // Regression test for the image 4.11.0 PNG decoder bug (ZLibDecoder.decodeLazy
  // missing from archive 4.0.x). A PNG shop logo goes pdf -> image.decodeImage ->
  // PngDecoder -> archive zlib inflate, so this exercises the exact failing path.
  test('PNG shop logo is decoded and embedded in printed documents', () async {
    final env = await TestEnv.create();
    final app = env.app;
    final dir = await Directory.systemTemp.createTemp('aqsa_logo');
    final logo = img.Image(width: 64, height: 48, numChannels: 4);
    img.fill(logo, color: img.ColorRgba8(8, 127, 91, 255));
    img.fillRect(logo, x1: 10, y1: 10, x2: 40, y2: 30, color: img.ColorRgba8(25, 199, 132, 128));
    final file = File('${dir.path}/logo.png')..writeAsBytesSync(img.encodePng(logo));
    final decoded = img.decodePng(file.readAsBytesSync());
    expect(decoded, isNotNull);
    expect(decoded!.width, 64);
    expect(decoded.getPixel(2, 2).g.toInt(), 127); // outside the blended rect

    final st = await app.settings.save({'logoPath': file.path});
    expect(st.logoPath, file.path);
    final c = await env.customer();
    final job = await app.repairs.receive(customerName: c.name, productName: 'DVR', reportedIssue: 'No video');
    for (final bytes in [
      await repairReceiptPdf(st, job),
      await statementPdf(st, app.parties.statement(PartyKind.customer, c.id)),
      await reportPdf(st, ExportTable('Stock', ['Item'], [['Cable']])),
    ]) {
      expect(isPdf(bytes), isTrue);
      expect(RegExp(r'/Subtype\s*/Image').hasMatch(latin1.decode(bytes)), isTrue, reason: 'logo image XObject missing');
    }
    await env.dispose();
    await dir.delete(recursive: true);
  });
}
