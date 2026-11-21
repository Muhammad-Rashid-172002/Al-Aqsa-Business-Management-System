// Customers: billed / paid / balance per customer, tabs (due / paid up /
// advance), and bills typed at the POS saving the customer.
import 'package:al_aqsa_cctv/core/money.dart';
import 'package:al_aqsa_cctv/domain/models/party.dart';
import 'package:al_aqsa_cctv/domain/services/party_service.dart';
import 'package:al_aqsa_cctv/domain/services/purchase_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() async => env.dispose());

  test('billed / paid / balance per customer from the ledger (opening balance, invoices, payments, a voided payment)', () async {
    final app = env.app;
    final cable = await env.product('Cable', cost: 100, price: 1000);
    final sup = await env.supplier();
    await app.purchases.create(supplierId: sup.id, date: env.clock.now, lines: [PurchaseLineInput(productId: cable.id, qty: q(20), unitCost: rs(100))]);
    final ali = await app.parties.create(kind: PartyKind.customer, name: 'Ali', phone: '0300-1234567', openingBalance: rs(500));
    final paidUp = await app.parties.create(kind: PartyKind.customer, name: 'Bilal');
    final adv = await app.parties.create(kind: PartyKind.customer, name: 'Cash Advance');
    Future<void> sell(Party c, int qty, int paid) async {
      final d = app.sales.newDraft().copyWith(customerId: c.id, customerName: c.name, items: [app.sales.lineFor(env.reload(cable.id), qty: q(qty))]);
      await app.sales.complete(d.copyWith(paidAtSale: rs(paid)));
    }

    await sell(ali, 3, 1000); // billed 3000, paid 1000 at sale
    await sell(ali, 2, 0); // billed 2000 on credit
    final pay = await app.parties.addPayment(kind: PartyKind.customer, partyId: ali.id, amount: rs(1500), method: PaymentMethod.cash);
    await app.parties.addPayment(kind: PartyKind.customer, partyId: ali.id, amount: rs(700), method: PaymentMethod.cash);
    await app.parties.voidPayment(pay.id, 'typo'); // must not count as paid
    await sell(paidUp, 1, 1000);
    await app.parties.addPayment(kind: PartyKind.customer, partyId: adv.id, amount: rs(2000), method: PaymentMethod.cash);

    final t = app.parties.accountTotals(PartyKind.customer);
    expect(t[ali.id]!.paid, rs(1000 + 700));
    expect(t[ali.id]!.billed, rs(500 + 3000 + 2000));
    expect(app.parties.byId(PartyKind.customer, ali.id)!.balance, rs(500 + 3000 + 2000 - 1700));
    expect(t[ali.id]!.lastPayment, isNotNull);
    expect(t[paidUp.id]!.paid, rs(1000));
    expect(app.parties.byId(PartyKind.customer, paidUp.id)!.balance, const Money.zero());
    expect(t[adv.id]!.paid, rs(2000));
    expect(app.parties.byId(PartyKind.customer, adv.id)!.balance, rs(-2000));
    // The three tabs: due / paid up / advance.
    final list = app.parties.list(PartyKind.customer);
    expect(list.where((p) => p.balance.isPositive).map((p) => p.name), ['Ali']);
    expect(list.where((p) => p.balance.isZero).map((p) => p.name), ['Bilal']);
    expect(list.where((p) => p.balance.isNegative).map((p) => p.name), ['Cash Advance']);
  });

  test('POS quick customer: a typed name / mobile is saved to Customers; same mobile reuses the customer', () async {
    final app = env.app;
    final a = await app.parties.findOrCreateCustomer(name: 'Zahid Electric', phone: '0333 7654321');
    expect(app.parties.byId(PartyKind.customer, a.id)!.phone, '0333 7654321');
    for (final same in ['+92 333 7654321', '923337654321', '03337654321', '3337654321']) {
      final b = await app.parties.findOrCreateCustomer(name: 'Other spelling', phone: same);
      expect(b.id, a.id, reason: same);
    }
    final c = await app.parties.findOrCreateCustomer(phone: '0300 1112223');
    expect(c.name, 'Customer 0300 1112223');
    final d = await app.parties.findOrCreateCustomer(name: 'Only Name');
    expect(d.phone, '');
    final d2 = await app.parties.findOrCreateCustomer(name: 'only  name');
    expect(d2.id, d.id);
    expect(app.parties.list(PartyKind.customer).length, 3);
    expect(PartyService.phoneKey('051-1234567'), '0511234567');
    expect(PartyService.phoneKey('12'), '');
    Object? err;
    try {
      await app.parties.findOrCreateCustomer();
    } catch (e) {
      err = e;
    }
    expect(err, isNotNull);
  });

  test('same name without a mobile reuses the customer; 4 bills in a day land on one account', () async {
    final app = env.app;
    final cable = await env.product('Cable', cost: 100, price: 1000);
    final sup = await env.supplier();
    await app.purchases.create(supplierId: sup.id, date: env.clock.now, lines: [PurchaseLineInput(productId: cable.id, qty: q(50), unitCost: rs(100))]);
    Future<void> bill(String name, String phone, int qty, int paid) async {
      final c = await app.parties.findOrCreateCustomer(name: name, phone: phone);
      final d = app.sales.newDraft().copyWith(customerId: c.id, customerName: c.name, items: [app.sales.lineFor(env.reload(cable.id), qty: q(qty))]);
      await app.sales.complete(d.copyWith(paidAtSale: rs(paid)));
    }

    await bill('Ahmed', '', 10, 10000);
    await bill('  ahmed ', '', 5, 2000); // case / spaces ignored
    await bill('AHMED', '', 8, 0);
    await bill('Ahmed', '0300 1234567', 2, 2000); // number added to the same customer
    final ahmeds = app.parties.list(PartyKind.customer).where((p) => PartyService.nameKey(p.name) == 'ahmed').toList();
    expect(ahmeds.length, 1);
    final a = ahmeds.first;
    expect(a.phone, '0300 1234567');
    final t = app.parties.accountTotals(PartyKind.customer)[a.id]!;
    expect(t.billed, rs(25000));
    expect(t.paid, rs(14000));
    expect(a.balance, rs(11000));
    expect(app.sales.list().where((s) => s.customerId == a.id).length, 4);
    // Now known by mobile too, whatever name is typed.
    expect(app.parties.matchCustomer(phone: '+92 300 1234567')!.id, a.id);
    expect(app.parties.matchCustomer(name: 'Ahmed')!.id, a.id);
    // Same name, different mobile = a different person.
    final other = await app.parties.findOrCreateCustomer(name: 'Ahmed', phone: '0311 9998887');
    expect(other.id == a.id, isFalse);
    expect(app.parties.matchCustomer(name: 'Nobody'), isNull);
  });
}
