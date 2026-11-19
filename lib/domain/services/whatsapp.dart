// WhatsApp click-to-chat: phone-number normalisation, chat links and
// customer message templates. Pure Dart (no UI), so it is unit-tested.
//
// Nothing here sends a message. A link only opens the chat with the text
// pre-filled; the user reviews it and presses Send in WhatsApp.
import 'package:intl/intl.dart';

import '../../core/money.dart';
import '../models/documents.dart';
import '../models/party.dart';
import 'app_services.dart';
import 'backup_service.dart' show appDisplayName;

/// Country code used for local numbers that start with 0 (Pakistan).
const defaultCountryCode = '92';

/// Converts a phone number as typed into the digits WhatsApp expects
/// (country code + number, no "+", spaces or symbols).
/// Returns null when the number is missing or not a plausible WhatsApp
/// (mobile) number, so no broken link is ever opened.
///
///  * `0300-1234567`, `0300 123 4567`, `(0300)1234567` → `923001234567`
///  * `3001234567` (10 digits, leading 0 dropped) → `923001234567`
///  * `+92 300 1234567`, `0092 300 1234567`, `923001234567` → `923001234567`
///  * `+971 50 123 4567`, `00971501234567`, `+44 7700 900123` → kept as is
///  * other local numbers starting with 0 (Pakistani landlines such as
///    051-1234567) and anything too short or too long → null
String? normalizeWhatsAppNumber(String? raw) {
  if (raw == null) return null;
  final t = raw.trim();
  if (t.isEmpty) return null;
  // Only digits, spaces and the usual separators are allowed.
  if (!RegExp(r'^[\d\s\-().+/]+$').hasMatch(t)) return null;
  final plus = t.startsWith('+');
  if (t.indexOf('+', 1) >= 0) return null;
  var d = t.replaceAll(RegExp(r'\D'), '');
  if (d.isEmpty) return null;

  bool international = plus;
  if (!plus && d.startsWith('00')) {
    d = d.substring(2);
    international = true;
  }
  if (international) {
    if (d.startsWith('0')) return null; // country codes never start with 0
    if (d.startsWith(defaultCountryCode)) return _pakistaniMobile(d.substring(2));
    return d.length >= 8 && d.length <= 15 ? d : null; // E.164 limits
  }
  // Local Pakistani formats.
  if (d.startsWith('0')) return _pakistaniMobile(d.substring(1));
  if (d.length == 10 && d.startsWith('3')) return _pakistaniMobile(d);
  if (d.startsWith(defaultCountryCode) && d.length == 12) return _pakistaniMobile(d.substring(2));
  // Digits with a country code but without "+" (e.g. 971501234567).
  return d.length >= 11 && d.length <= 15 ? d : null;
}

/// Pakistani mobile numbers are 3XX XXXXXXX (10 digits after +92).
/// A stray 0 after +92 (`+92 0300 1234567`) is tolerated.
String? _pakistaniMobile(String national) {
  final n = national.length == 11 && national.startsWith('03') ? national.substring(1) : national;
  return RegExp(r'^3\d{9}$').hasMatch(n) ? '$defaultCountryCode$n' : null;
}

/// Readable form of a normalised number: `+92 300 1234567`.
String displayWhatsAppNumber(String normalized) {
  if (normalized.startsWith(defaultCountryCode) && normalized.length == 12) {
    return '+92 ${normalized.substring(2, 5)} ${normalized.substring(5)}';
  }
  return '+$normalized';
}

/// `https://wa.me/<number>?text=<encoded>`: opens the chat in WhatsApp
/// Desktop (if installed, after the browser hands over) or WhatsApp Web.
Uri whatsAppWebLink(String normalized, [String message = '']) => Uri.parse(
    'https://wa.me/$normalized${message.trim().isEmpty ? '' : '?text=${Uri.encodeComponent(message)}'}');

/// `whatsapp://send?phone=<number>&text=<encoded>`: opens WhatsApp Desktop
/// directly when it is installed.
Uri whatsAppAppLink(String normalized, [String message = '']) => Uri.parse(
    'whatsapp://send?phone=$normalized${message.trim().isEmpty ? '' : '&text=${Uri.encodeComponent(message)}'}');

/// The customer's usable WhatsApp numbers: main phone first, then the
/// alternate number (duplicates and invalid numbers removed).
List<String> whatsAppNumbersOf(Party p) {
  final out = <String>[];
  for (final raw in [p.phone, p.altPhone]) {
    final n = normalizeWhatsAppNumber(raw);
    if (n != null && !out.contains(n)) out.add(n);
  }
  return out;
}

enum WaTemplate {
  general('General Message'),
  paymentReminder('Payment Reminder'),
  outstandingBalance('Outstanding Balance Reminder'),
  invoiceFollowUp('Invoice Follow-up'),
  thankYou('Thank You Message');

  final String label;
  const WaTemplate(this.label);
}

/// Facts a template may use. Everything comes from the customer's records;
/// [balance] must be the ledger balance (positive = the customer owes us).
class WaContext {
  final String customerName;
  final String businessName;
  final Money balance;
  final Sale? lastInvoice; // latest completed invoice, if any
  final DateTime today;
  const WaContext({required this.customerName, required this.businessName, required this.balance, this.lastInvoice, required this.today});
}

final _d = DateFormat('dd/MM/yyyy');

/// Why a template can't be used for this customer (null when it can).
/// Balance templates need a real amount owed; invoice templates need an
/// invoice. Nothing is ever made up.
String? waTemplateUnavailable(WaTemplate t, WaContext x) => switch (t) {
      WaTemplate.paymentReminder || WaTemplate.outstandingBalance =>
        x.balance.isPositive ? null : 'No amount is outstanding for this customer.',
      WaTemplate.invoiceFollowUp => x.lastInvoice == null ? 'This customer has no completed invoice.' : null,
      _ => null,
    };

/// The message text for [t]. Throws [StateError] when the template is not
/// available (see [waTemplateUnavailable]).
String waMessage(WaTemplate t, WaContext x) {
  final why = waTemplateUnavailable(t, x);
  if (why != null) throw StateError(why);
  final n = x.customerName.trim().isEmpty ? 'Sahib' : x.customerName.trim();
  final biz = x.businessName;
  final inv = x.lastInvoice;
  return switch (t) {
    WaTemplate.general => 'Assalam o Alaikum $n, umeed hai aap khairiyat se honge. '
        '$biz ki taraf se aap se rabta kar rahe hain.',
    WaTemplate.paymentReminder => 'Assalam o Alaikum $n,\n'
        '$biz ki taraf se yaad dehani: hamare record ke mutabiq ${_d.format(x.today)} tak aap ke account mein '
        '${x.balance.format()} ki adaigi baqi hai. Baraye meharbani suhoolat ke mutabiq adaigi kar dein.\n'
        'Agar aap adaigi kar chuke hain to is message ko nazar andaz kar dein. Shukriya.',
    WaTemplate.outstandingBalance => 'Assalam o Alaikum $n,\n'
        '$biz – account balance\n'
        'Tareekh: ${_d.format(x.today)}\n'
        'Baqaya raqam: ${x.balance.format()}\n'
        '${inv == null ? '' : 'Aakhri invoice: ${inv.number} (${_d.format(inv.date)}) – ${inv.total.format()}\n'}'
        'Kisi bhi sawal ke liye isi number par rabta karein. Shukriya.',
    WaTemplate.invoiceFollowUp => 'Assalam o Alaikum $n,\n'
        'Invoice ${inv!.number} (${_d.format(inv.date)}) – ${inv.total.format()} ke hawale se rabta kar rahe hain. '
        'Umeed hai aap saman/service se mutmaeen hain. Koi masla ho to zaroor batayein.\n$biz',
    WaTemplate.thankYou => 'Assalam o Alaikum $n,\n'
        '$biz par aitmaad karne ka bohat shukriya${inv == null ? '' : ' (invoice ${inv.number})'}. '
        'Aap ki khidmat hamare liye aizaz hai. CCTV ya solar system ki kisi bhi zaroorat ke liye hum hazir hain.',
  };
}

/// The facts the templates may use, all from this customer's own records:
/// the ledger balance (not the cached total) and the latest completed invoice.
WaContext waContextFor(AppServices app, Party p) {
  final invoices = app.sales.list(customerId: p.id, status: DocStatus.completed)..sort((a, b) => b.date.compareTo(a.date));
  final name = app.ctx.settings.businessName.trim();
  return WaContext(
    customerName: p.name,
    businessName: name.isEmpty ? appDisplayName : name,
    balance: app.parties.statement(p.kind, p.id).closingBalance,
    lastInvoice: invoices.isEmpty ? null : invoices.first,
    today: app.ctx.now(),
  );
}

