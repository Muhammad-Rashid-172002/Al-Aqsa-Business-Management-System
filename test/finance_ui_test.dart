// UI: add an expense, see it in Profit & Loss; reports page filters.
import 'package:al_aqsa_cctv/domain/services/report_tables.dart';
import 'package:al_aqsa_cctv/ui/providers.dart';
import 'package:al_aqsa_cctv/ui/shell/app_shell.dart';
import 'package:al_aqsa_cctv/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

Future<(TestEnv, ProviderContainer)> _open(WidgetTester tester, NavItem page) async {
  final env = (await tester.runAsync(TestEnv.create))!;
  await tester.binding.setSurfaceSize(const Size(1600, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ProviderScope(
    overrides: [servicesProvider.overrideWithValue(env.app)],
    child: MaterialApp(theme: AppTheme.build(AppColors.darkPalette), home: const Root()),
  ));
  final c = ProviderScope.containerOf(tester.element(find.byType(Root)));
  c.read(currentUserProvider.notifier).state = env.app.auth.findByUsername('owner');
  await tester.pump();
  c.read(navProvider.notifier).state = page;
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  return (env, c);
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pump();
  await tester.tap(f);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _close(WidgetTester tester, TestEnv env) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpWidget(const SizedBox());
  await tester.runAsync(env.dispose);
}

void main() {
  testWidgets('add an expense; Profit & Loss shows it and the net operating profit', (tester) async {
    final (env, c) = await _open(tester, NavItem.expenses);
    await _tap(tester, find.byKey(const ValueKey('add-expense')));
    await tester.enterText(find.byKey(const ValueKey('expense-title')), 'November rent');
    await tester.enterText(find.byKey(const ValueKey('expense-amount')), '30000');
    await _tap(tester, find.byKey(const ValueKey('expense-save')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 400));
    final list = env.app.expenses.list();
    expect(list.single.title, 'November rent');
    expect(list.single.category, 'Shop rent');
    expect(find.text('November rent'), findsOneWidget);
    expect(find.byKey(const ValueKey('export-menu')), findsOneWidget);

    c.read(navProvider.notifier).state = NavItem.finance;
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('GROSS PROFIT'), findsOneWidget);
    expect(find.text('NET OPERATING PROFIT'), findsOneWidget);
    expect(find.text('Rs 30,000.00').evaluate().isNotEmpty, isTrue);
    await _close(tester, env);
  });

  testWidgets('reports page shows filters for the chosen report and all four actions', (tester) async {
    final (env, _) = await _open(tester, NavItem.reports);
    for (final k in const ['report-excel', 'report-pdf', 'report-print', 'report-preview']) {
      expect(find.byKey(ValueKey(k)), findsOneWidget);
    }
    await _tap(tester, find.text(ReportKind.salesInvoices.title).first);
    expect(find.byKey(const ValueKey('rf-customer')), findsOneWidget);
    expect(find.byKey(const ValueKey('rf-payment')), findsOneWidget);
    expect(find.byKey(const ValueKey('rf-serial')), findsOneWidget);
    await _tap(tester, find.text(ReportKind.techIssued.title).first);
    expect(find.byKey(const ValueKey('rf-technician')), findsOneWidget);
    await _tap(tester, find.text(ReportKind.profitLoss.title).first);
    expect(find.byKey(const ValueKey('rf-customer')), findsNothing);
    await _close(tester, env);
  });
}
