// UI: WhatsApp buttons open the selected customer's own chat with the
// message pre-filled (the URL opener is replaced, so nothing really opens).
import 'package:al_aqsa_cctv/domain/models/party.dart';
import 'package:al_aqsa_cctv/ui/providers.dart';
import 'package:al_aqsa_cctv/ui/shell/app_shell.dart';
import 'package:al_aqsa_cctv/ui/theme.dart';
import 'package:al_aqsa_cctv/ui/whatsapp_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pump();
  await tester.tap(f);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  late List<Uri> opened;
  late bool desktop;
  setUp(() {
    opened = [];
    desktop = false;
    whatsAppUrlOpener = (u) async {
      opened.add(u);
      return true;
    };
    whatsAppDesktopCheck = () async => desktop;
  });
  tearDown(() {
    whatsAppUrlOpener = systemOpenUrl;
    whatsAppDesktopCheck = systemHasWhatsAppDesktop;
  });

  testWidgets('table button opens the right customer; no number shows a message; details composer sends edited text', (tester) async {
    final env = (await tester.runAsync(TestEnv.create))!;
    late Party ali, bilal, noPhone;
    await tester.runAsync(() async {
      ali = await env.app.parties.create(kind: PartyKind.customer, name: 'Ali Traders', phone: '0300-1234567');
      bilal = await env.app.parties.create(kind: PartyKind.customer, name: 'Bilal', phone: '+971 50 123 4567');
      noPhone = await env.app.parties.create(kind: PartyKind.customer, name: 'Walk-in Zahid');
    });
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [servicesProvider.overrideWithValue(env.app)],
      child: MaterialApp(theme: AppTheme.build(AppColors.darkPalette), home: const Root()),
    ));
    final c = ProviderScope.containerOf(tester.element(find.byType(Root)));
    c.read(currentUserProvider.notifier).state = env.app.auth.findByUsername('owner');
    await tester.pump();
    c.read(navProvider.notifier).state = NavItem.customers;
    await tester.pump(const Duration(milliseconds: 600));

    // The ⋮ menu is still there next to the WhatsApp button.
    expect(find.byKey(const ValueKey('row-menu')), findsNWidgets(3));

    await _tap(tester, find.byKey(ValueKey('wa-${bilal.id}')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 300));
    expect(opened.single.toString().startsWith('https://wa.me/971501234567?text='), isTrue);
    expect(opened.single.queryParameters['text']!.contains('Bilal'), isTrue);

    opened.clear();
    await _tap(tester, find.byKey(ValueKey('wa-${noPhone.id}')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(opened, isEmpty);
    expect(find.textContaining('has no valid mobile number'), findsOneWidget);

    // WhatsApp Desktop installed: the whatsapp:// link is used.
    desktop = true;
    await _tap(tester, find.byKey(ValueKey('wa-${ali.id}')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 300));
    expect(opened.single.scheme, 'whatsapp');
    expect(opened.single.queryParameters['phone'], '923001234567');

    // Details screen → composer: balance templates are disabled (nothing owed),
    // the message can be edited and is passed through exactly.
    opened.clear();
    desktop = false;
    await _tap(tester, find.text('Ali Traders'));
    await _tap(tester, find.byKey(const ValueKey('detail-whatsapp')));
    expect(find.byKey(const ValueKey('wa-composer')), findsOneWidget);
    final reminder = tester.widget<ChoiceChip>(find.byKey(const ValueKey('wa-t-paymentReminder')));
    expect(reminder.onSelected, isNull);
    await tester.enterText(find.byKey(const ValueKey('wa-message')), 'Assalam o Alaikum Ali Traders, aap ka order tayyar hai.');
    await _tap(tester, find.byKey(const ValueKey('wa-open')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 300));
    expect(opened.single.toString().startsWith('https://wa.me/923001234567?text='), isTrue);
    expect(opened.single.queryParameters['text'], 'Assalam o Alaikum Ali Traders, aap ka order tayyar hai.');

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(env.dispose);
  });
}
