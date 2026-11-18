import 'dart:io';

import 'package:al_aqsa_cctv/core/password_hasher.dart';
import 'package:al_aqsa_cctv/data/store/memory_store.dart';
import 'package:al_aqsa_cctv/domain/models/user.dart';
import 'package:al_aqsa_cctv/domain/services/app_services.dart';
import 'package:al_aqsa_cctv/ui/providers.dart';
import 'package:al_aqsa_cctv/ui/shell/app_shell.dart';
import 'package:al_aqsa_cctv/ui/splash/splash_screen.dart';
import 'package:al_aqsa_cctv/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

Future<ProviderContainer> _launch(WidgetTester tester, AppServices app) async {
  await tester.binding.setSurfaceSize(const Size(1600, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [servicesProvider.overrideWithValue(app)],
      child: MaterialApp(
        theme: AppTheme.build(AppColors.darkPalette),
        home: const Root(),
      ),
    ),
  );
  return ProviderScope.containerOf(tester.element(find.byType(Root)));
}

/// No login, registration or password field anywhere on the screen.
void _expectNoCredentialsUi() {
  expect(
    find.byType(TextField),
    findsNothing,
    reason: 'startup must not ask for anything',
  );
  for (final s in [
    'Sign In',
    'Sign in to continue',
    'Username',
    'Password',
    'Create the owner account',
    'Log out',
    'Change password',
  ]) {
    expect(
      find.textContaining(s),
      findsNothing,
      reason: '"$s" must not be shown',
    );
  }
}

Future<void> _finishSplash(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 700));
  await tester.pump(
    const Duration(milliseconds: 1000),
  ); // minimum splash time elapsed
  await tester.pump(const Duration(milliseconds: 500)); // switch animation
  await tester.pump(const Duration(seconds: 2)); // dashboard counters
}

void main() {
  testWidgets(
    'existing shop data: splash, then Dashboard directly — no login',
    (tester) async {
      final env =
          (await tester.runAsync(() async {
            final e = await TestEnv.create();
            await e.product('Hikvision 4MP Dome');
            await e.customer();
            e.app.auth.logout(); // a fresh app start: no session yet
            return e;
          }))!;
      final app = env.app;
      final owner = app.auth.findByUsername('owner')!;
      final usersBefore = app.auth.users().length;
      final productsBefore = app.catalog.products().length;

      final c = await _launch(tester, app);
      // Splash branding + animation, no credentials.
      expect(find.byType(SplashScreen), findsOneWidget);
      expect(find.text('AL-AQSA CCTV & SOLAR SYSTEM'), findsOneWidget);
      expect(find.text('Opening your shop data…'), findsOneWidget);
      _expectNoCredentialsUi();

      await _finishSplash(tester);
      expect(find.byType(SplashScreen), findsNothing);
      expect(find.byType(AppShell), findsOneWidget);
      expect(c.read(navProvider), NavItem.dashboard);
      expect(find.text('Gross Profit (period)'), findsOneWidget);
      _expectNoCredentialsUi();

      // Session is the existing owner; no records were added or reset.
      expect(c.read(currentUserProvider)!.id, owner.id);
      expect(
        c.read(currentUserProvider)!.can(Permission.viewFinancials),
        isTrue,
      );
      expect(app.auth.users().length, usersBefore);
      expect(app.catalog.products().length, productsBefore);

      // No account management left in the top bar or Settings.
      expect(find.byTooltip('Account'), findsNothing);
      expect(find.byKey(const ValueKey('theme-toggle')), findsOneWidget);
      c.read(navProvider.notifier).state = NavItem.settings;
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Business & Documents'), findsOneWidget);
      expect(find.text('Audit & Data'), findsOneWidget);
      expect(find.text('Users'), findsNothing);
      expect(find.text('New user'), findsNothing);

      await tester.pumpWidget(const SizedBox()); // unmount (stops clock timer)
      await tester.runAsync(env.dispose);
    },
  );

  testWidgets(
    'fresh install (empty database): splash, then Dashboard — no account setup',
    (tester) async {
      final tmp =
          (await tester.runAsync(
            () => Directory.systemTemp.createTemp('aqsa_fresh'),
          ))!;
      final app = AppServices(
        MemoryStore(),
        localBackupDir: '${tmp.path}/local',
        hasher: const PasswordHasher(iterations: 10),
      );
      expect(app.auth.users(), isEmpty);

      final c = await _launch(tester, app);
      expect(find.byType(SplashScreen), findsOneWidget);
      _expectNoCredentialsUi();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      ); // let the store write the owner record
      await _finishSplash(tester);

      expect(find.byType(AppShell), findsOneWidget);
      expect(find.text('Gross Profit (period)'), findsOneWidget);
      _expectNoCredentialsUi();
      final u = c.read(currentUserProvider)!;
      expect(u.role, UserRole.owner);
      expect(
        app.auth.users().length,
        1,
        reason: 'exactly one owner record is created',
      );

      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => tmp.delete(recursive: true));
    },
  );
}
