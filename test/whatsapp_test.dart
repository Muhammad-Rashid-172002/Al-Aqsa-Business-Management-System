// WhatsApp click-to-chat: number normalisation, URL encoding and message
// templates built from the customer's real records.
import 'package:al_aqsa_cctv/core/money.dart';
import 'package:al_aqsa_cctv/domain/models/documents.dart';
import 'package:al_aqsa_cctv/domain/models/party.dart';
import 'package:al_aqsa_cctv/domain/services/purchase_service.dart';
import 'package:al_aqsa_cctv/domain/services/whatsapp.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  test('Pakistani numbers in every common format become 92XXXXXXXXXX', () {
    for (final raw in [
      '03001234567',
      '0300-1234567',
      '0300 123 4567',
      '(0300) 1234567',
      ' 0300.1234567 '.replaceAll('.', ''),
      '3001234567',
      '923001234567',
      '+923001234567',
      '+92 300 1234567',
      '+92-300-1234567',
      '0092 300 1234567',
      '+92 0300 1234567',
      '0345/1234567',
    ]) {
      expect(normalizeWhatsAppNumber(raw), raw.contains('0345') ? '923451234567' : '923001234567', reason: raw);
    }
  });

  test('international numbers keep their own country code', () {
    expect(normalizeWhatsAppNumber('+971 50 123 4567'), '971501234567');
    expect(normalizeWhatsAppNumber('00971501234567'), '971501234567');
    expect(normalizeWhatsAppNumber('+44 7700 900123'), '447700900123');
    expect(normalizeWhatsAppNumber('+1 (415) 555-2671'), '14155552671');
    expect(normalizeWhatsAppNumber('971501234567'), '971501234567');
    expect(normalizeWhatsAppNumber('+966 55 123 4567'), '966551234567');
  });

  test('missing, malformed and non-mobile numbers are rejected', () {
    for (final raw in [null, '', '   ', 'abc', '0300-12345', '030012345678', '051-1234567', '04235761234', '12345', '+0300123456', '+92 51 1234567', '+92 300 12', '0300 1234567 ext 2', '++923001234567', '+92+3001234567', '1234567890123456']) {
      expect(normalizeWhatsAppNumber(raw), isNull, reason: '$raw');
    }
  });

  test('chat links: wa.me and whatsapp:// with the message URL-encoded', () {
    const msg = 'Assalam o Alaikum Ali & Sons,\nBalance: Rs 1,500.00 (50% paid) #12?';
    final web = whatsAppWebLink('923001234567', msg);
    expect(web.toString().startsWith('https://wa.me/923001234567?text='), isTrue);
    expect(web.toString().contains(' '), isFalse);
    expect(web.toString().contains('&'), isFalse); // "&" in the text is encoded
    expect(web.queryParameters['text'], msg); // decodes back to the exact text
    expect(web.toString().contains('%0A'), isTrue); // new line kept
    final app = whatsAppAppLink('923001234567', msg);
    expect(app.scheme, 'whatsapp');
    expect(app.queryParameters['phone'], '923001234567');
    expect(app.queryParameters['text'], msg);
    expect(whatsAppWebLink('923001234567').toString(), 'https://wa.me/923001234567');
    expect(displayWhatsAppNumber('923001234567'), '+92 300 1234567');
    expect(displayWhatsAppNumber('971501234567'), '+971501234567');
  });

  test('customer numbers: main first, alternate second, invalid and duplicates skipped', () {
    Party p(String a, String b) => Party(id: 'x', kind: PartyKind.customer, name: 'A', phone: a, altPhone: b, createdAt: DateTime(2026));
    expect(whatsAppNumbersOf(p('0300-1234567', '+971501234567')), ['923001234567', '971501234567']);
    expect(whatsAppNumbersOf(p('051-1234567', '0333 7654321')), ['923337654321']);
    expect(whatsAppNumbersOf(p('03001234567', '+92 300 1234567')), ['923001234567']);
    expect(whatsAppNumbersOf(p('', '')), isEmpty);
  });

  test('templates use the real customer name, ledger balance and latest invoice', () async {
    final env = await TestEnv.create();
    try {
      await _templates(env);
    } finally {
      await env.dispose();
    }
  });
}

Future<void> _templates(TestEnv env) async {
    final app = env.app;
    final cam = await env.product('Camera', cost: 4000, price: 6000);
    final sup = await env.supplier();
    await app.purchases.create(supplierId: sup.id, date: env.clock.now, lines: [PurchaseLineInput(productId: cam.id, qty: q(5), unitCost: rs(4000))]);
    final ali = await app.parties.create(kind: PartyKind.customer, name: 'Ali Traders', phone: '0300-1234567', altPhone: '+971 50 123 4567');
    expect(app.parties.byId(PartyKind.customer, ali.id)!.altPhone, '+971 50 123 4567');

    // No invoice and nothing owed: balance/invoice templates are unavailable.
    var x = waContextFor(app, app.parties.byId(PartyKind.customer, ali.id)!);
    expect(x.balance, const Money.zero());
    expect(waTemplateUnavailable(WaTemplate.paymentReminder, x), isNotNull);
    expect(waTemplateUnavailable(WaTemplate.outstandingBalance, x), isNotNull);
    expect(waTemplateUnavailable(WaTemplate.invoiceFollowUp, x), isNotNull);
    Object? err;
    try {
      waMessage(WaTemplate.paymentReminder, x);
    } catch (e) {
      err = e;
    }
    expect(err is StateError, isTrue); // never a reminder with no real balance
    final general = waMessage(WaTemplate.general, x);
    expect(general, 'Assalam o Alaikum Ali Traders, umeed hai aap khairiyat se honge. AL-AQSA CCTV & SOLAR SYSTEM ki taraf se aap se rabta kar rahe hain.');
    expect(waMessage(WaTemplate.thankYou, x).contains('invoice'), isFalse);

    // Sale of 2 cameras (12,000), 5,000 paid, then 2,000 on account: owes 5,000.
    final d = app.sales.newDraft().copyWith(customerId: ali.id, customerName: ali.name, items: [app.sales.lineFor(env.reload(cam.id), qty: q(2))]);
    final sale = await app.sales.complete(d.copyWith(paidAtSale: rs(5000)));
    await app.parties.addPayment(kind: PartyKind.customer, partyId: ali.id, amount: rs(2000), method: PaymentMethod.cash);
    // A cancelled invoice must not be used as the "latest invoice".
    env.clock.advance(const Duration(days: 1));
    final d2 = app.sales.newDraft().copyWith(customerId: ali.id, customerName: ali.name, items: [app.sales.lineFor(env.reload(cam.id))]);
    final s2 = await app.sales.complete(d2.copyWith(paidAtSale: d2.total));
    await app.sales.cancel(s2.id, 'mistake');

    x = waContextFor(app, app.parties.byId(PartyKind.customer, ali.id)!);
    expect(x.balance, rs(5000));
    expect(x.lastInvoice!.id, sale.id);
    final reminder = waMessage(WaTemplate.paymentReminder, x);
    expect(reminder.contains('Ali Traders'), isTrue);
    expect(reminder.contains(rs(5000).format()), isTrue);
    final outstanding = waMessage(WaTemplate.outstandingBalance, x);
    expect(outstanding.contains('Baqaya raqam: ${rs(5000).format()}'), isTrue);
    expect(outstanding.contains(sale.number), isTrue);
    expect(outstanding.contains(s2.number), isFalse);
    final follow = waMessage(WaTemplate.invoiceFollowUp, x);
    expect(follow.contains(sale.number) && follow.contains(sale.total.format()), isTrue);
    expect(waMessage(WaTemplate.thankYou, x).contains(sale.number), isTrue);
    // The link carries the exact edited text.
    final edited = '$reminder\nJazakAllah';
    expect(whatsAppWebLink(whatsAppNumbersOf(x.lastInvoice == null ? ali : app.parties.byId(PartyKind.customer, ali.id)!).first, edited).queryParameters['text'], edited);

    // Customer in credit (advance): reminders stay unavailable.
    await app.parties.addPayment(kind: PartyKind.customer, partyId: ali.id, amount: rs(6000), method: PaymentMethod.cash);
    x = waContextFor(app, app.parties.byId(PartyKind.customer, ali.id)!);
    expect(x.balance.isNegative, isTrue);
    expect(waTemplateUnavailable(WaTemplate.paymentReminder, x), isNotNull);
    expect(x.lastInvoice!.status, DocStatus.completed);
}
