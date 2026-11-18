// Responsive layout / overflow tests.
//
// Drives the real app shell (Root -> AppShell -> every page) with realistic,
// deliberately long data at the desktop sizes the shop may use, including
// Windows display scaling (125% / 150%) and maximised-window client areas.
// Any FlutterError during layout or paint (RenderFlex overflow, unbounded
// constraints, ...) is recorded and fails the test with the page, viewport
// and the widget that overflowed.
//
// Fonts: flutter_test normally draws every glyph as a 1em square, which makes
// text far wider than on Windows. These tests load Roboto from the Flutter SDK
// (very close to Segoe UI metrics) under the app's font family names, and the
// text-scale test adds 15% on top to cover wider fonts / accessibility sizes.
import 'dart:io';

import 'package:al_aqsa_cctv/domain/models/documents.dart';
import 'package:al_aqsa_cctv/domain/models/party.dart';
import 'package:al_aqsa_cctv/domain/models/product.dart';
import 'package:al_aqsa_cctv/domain/services/purchase_service.dart';
import 'package:al_aqsa_cctv/domain/services/report_tables.dart';
import 'package:al_aqsa_cctv/domain/services/technician_service.dart';
import 'package:al_aqsa_cctv/domain/models/operations.dart';
import 'package:al_aqsa_cctv/ui/pages/pos_page.dart';
import 'package:al_aqsa_cctv/ui/providers.dart';
import 'package:al_aqsa_cctv/ui/shell/app_shell.dart';
import 'package:al_aqsa_cctv/ui/theme.dart';
import 'package:al_aqsa_cctv/ui/widgets/forms.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

/// (label, physical screen/window size, devicePixelRatio = Windows scaling)
const viewports = <(String, Size, double)>[
  ('1024x600 @100%', Size(1024, 600), 1.0),
  ('1280x720 @100%', Size(1280, 720), 1.0),
  ('1366x768 @100%', Size(1366, 768), 1.0),
  ('1440x900 @100%', Size(1440, 900), 1.0),
  ('1600x900 @100%', Size(1600, 900), 1.0),
  ('1920x1080 @100%', Size(1920, 1080), 1.0),
  ('1280x720 @125%', Size(1280, 720), 1.25),
  ('1366x768 @125%', Size(1366, 768), 1.25),
  ('1366x768 @150%', Size(1366, 768), 1.5),
  ('1920x1080 @125%', Size(1920, 1080), 1.25),
  ('1920x1080 @150%', Size(1920, 1080), 1.5),
  // Maximised window client area (screen minus taskbar and title bar).
  ('1366x768 @150% maximised (911x433)', Size(1366, 650), 1.5),
  ('1024x600 maximised (1024x529)', Size(1024, 529), 1.0),
  // Smallest window the Windows runner allows (800x500 logical).
  ('min window 800x500', Size(800, 500), 1.0),
];

/// Small set used for the heavier dialog / form sweeps.
final smallViewports =
    viewports
        .where(
          (v) => const {
            '1024x600 @100%',
            '1366x768 @150%',
            '1366x768 @150% maximised (911x433)',
            'min window 800x500',
            '1920x1080 @100%',
          }.contains(v.$1),
        )
        .toList();

// ───────────────────────── harness ─────────────────────────

class _Problems {
  final List<String> found = [];
  String where = '';
  FlutterExceptionHandler? _orig;

  void start() {
    _orig = FlutterError.onError;
    FlutterError.onError = (details) {
      final lines = details.toString().split('\n');
      found.add('[$where] ${lines.take(40).join('\n')}');
    };
  }

  void stop() => FlutterError.onError = _orig;

  void expectNone() {
    if (found.isNotEmpty) {
      fail(
        '${found.length} layout problem(s):\n\n${found.take(6).join('\n\n────────\n\n')}',
      );
    }
  }
}

bool _fontsLoaded = false;

Future<void> _loadRealFonts() async {
  if (_fontsLoaded) return;
  _fontsLoaded = true;
  String? root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) {
    // .../flutter/bin/cache/artifacts/engine/<platform>/flutter_tester
    final exe = File(Platform.resolvedExecutable);
    root = exe.parent.parent.parent.parent.parent.parent.path;
  }
  final dir = Directory('$root/bin/cache/artifacts/material_fonts');
  if (!dir.existsSync()) {
    // ignore: avoid_print
    print(
      'WARNING: Flutter material fonts not found at ${dir.path}; using the test font.',
    );
    return;
  }
  final roboto =
      dir.listSync().whereType<File>().where((f) {
        final n = f.uri.pathSegments.last;
        return n.startsWith('Roboto-') &&
            n.endsWith('.ttf') &&
            !n.contains('Italic');
      }).toList();
  for (final family in const ['Segoe UI', 'Roboto', 'Consolas']) {
    final loader = FontLoader(family);
    for (final f in roboto) {
      loader.addFont(f.readAsBytes().then((b) => ByteData.view(b.buffer)));
    }
    await loader.load();
  }
  final icons = File('${dir.path}/MaterialIcons-Regular.otf');
  if (icons.existsSync()) {
    await (FontLoader('MaterialIcons')..addFont(
      icons.readAsBytes().then((b) => ByteData.view(b.buffer)),
    )).load();
  }
}

/// Realistic shop data with long names and every status that has a badge.
Future<void> _seed(TestEnv env) async {
  final app = env.app;
  final sup = await env.supplier(
    'Rawalpindi CCTV Wholesale & Security Systems Distributors (Pvt) Ltd',
  );
  final cam = await env.product(
    'Hikvision DS-2CD2143G2-IU 4MP AcuSense Fixed Turret Network Camera with Built-in Microphone',
    serial: true,
    brand: 'Hikvision',
    cost: 15250,
    price: 18999,
  );
  final nvr = await env.product(
    'Dahua DHI-NVR5216-16P-4KS2E 16-Channel 1U 16PoE 4K & H.265 Pro Network Video Recorder',
    serial: true,
    brand: 'Dahua',
    cost: 52000,
    price: 64500,
  );
  final cable = await env.product(
    'Cat6 Outdoor UV-resistant Copper Cable (per metre)',
    decimal: true,
    cost: 40,
    price: 70,
  );
  final hdd = await env.product(
    'Seagate SkyHawk 4TB Surveillance Hard Drive',
    cost: 21000,
    price: 25500,
    minStock: 5,
  );
  for (var i = 1; i <= 26; i++) {
    await env.product(
      'Accessory item number $i with a fairly long descriptive name',
      cost: 100 + i,
      price: 180 + i,
      minStock: i.isEven ? 50 : 1,
    );
  }
  final camSerials = [for (var i = 1; i <= 8; i++) 'HKV-2026-00012345$i'];
  await app.purchases.create(
    supplierId: sup.id,
    supplierInvoiceNo: 'RW-2026-INV-000918273',
    date: env.clock.now,
    lines: [
      PurchaseLineInput(
        productId: cam.id,
        qty: q(8),
        unitCost: rs(15250),
        serials: camSerials,
      ),
      PurchaseLineInput(
        productId: nvr.id,
        qty: q(3),
        unitCost: rs(52000),
        serials: ['DH-NVR-7781001', 'DH-NVR-7781002', 'DH-NVR-7781003'],
      ),
      PurchaseLineInput(
        productId: cable.id,
        qty: Qty.parse('305'),
        unitCost: rs(40),
      ),
      PurchaseLineInput(productId: hdd.id, qty: q(2), unitCost: rs(21000)),
    ],
    paid: rs(50000),
  );

  final cust = await app.parties.create(
    kind: PartyKind.customer,
    name:
        'Muhammad Abdullah Electronics & Security Solutions, Saddar Rawalpindi',
    phone: '0300-1234567',
    address: 'Shop 14, Bank Road, Saddar, Rawalpindi Cantt',
    openingBalance: rs(125000),
  );
  await env.customer('Ali Traders');
  final keys = [for (final r in app.serials.inStockFor(cam.id)) r.key];
  await app.sales.complete(
    app.sales.newDraft().copyWith(
      customerId: cust.id,
      items: [
        SaleItem(
          productId: cam.id,
          name: cam.name,
          qty: q(2),
          unitPrice: rs(18999),
          serials: keys.take(2).toList(),
        ),
        SaleItem(
          productId: cable.id,
          name: cable.name,
          qty: Qty.parse('42.5'),
          unitPrice: rs(70),
        ),
      ],
      paidAtSale: rs(5000),
      method: PaymentMethod.mobileWallet,
    ),
  );
  await app.parties.addPayment(
    kind: PartyKind.customer,
    partyId: cust.id,
    amount: rs(10000),
    method: PaymentMethod.bankTransfer,
  );

  final tech = await app.technicians.create(
    name: 'Waqas Ahmed Qureshi (Senior Installer)',
    phone: '0333-7654321',
  );
  await app.technicians.issue(
    technicianId: tech.id,
    jobRef: 'F-7/2 House 22',
    lines: [
      IssueLine(
        productId: cam.id,
        qty: q(3),
        serials: [camSerials[2], camSerials[3], camSerials[4]],
      ),
      IssueLine(productId: cable.id, qty: Qty.parse('50')),
    ],
  );
  await app.technicians.recordInstalled(
    technicianId: tech.id,
    productId: cam.id,
    qty: q(1),
    serialNumbers: [camSerials[2]],
    customerId: cust.id,
    jobRef: 'F-7/2 House 22',
  );
  await app.technicians.returnMaterial(
    technicianId: tech.id,
    productId: cam.id,
    qty: q(1),
    type: TechTxnType.returnFaulty,
    serialNumbers: [camSerials[3]],
    reason: 'IR LEDs not working at night',
  );
  await app.technicians.returnMaterial(
    technicianId: tech.id,
    productId: cable.id,
    qty: Qty.parse('2.5'),
    type: TechTxnType.returnUsed,
    reason: 'Cut pieces',
  );

  final stock = app.serials.inStockFor(cam.id).map((r) => r.key).toList();
  await app.inventory.markDamaged(
    cam.id,
    q(1),
    'Dropped during unpacking',
    serialKeys: [stock.first],
  );

  await app.repairs.receive(
    customerName: cust.name,
    customerPhone: cust.phone,
    productName: nvr.name,
    serial: 'DH-NVR-OLD-55',
    reportedIssue: 'No HDD detected after power failure; beeps continuously',
  );
  final sold = app.serials.search(productId: cam.id, status: SerialStatus.sold);
  if (sold.isNotEmpty) {
    await app.warranty.openClaim(
      sold.first.key,
      'Image turns pink in daylight',
    );
  }
  await app.quotations.save(
    app.quotations
        .newDraft(customerId: cust.id, customerName: cust.name)
        .copyWith(
          items: [
            QuotationItem(
              productId: cam.id,
              name: cam.name,
              qty: q(16),
              unitPrice: rs(18500),
            ),
            QuotationItem(
              productId: nvr.id,
              name: nvr.name,
              qty: q(1),
              unitPrice: rs(63000),
            ),
          ],
        ),
  );
}

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 450));
  await t.pump(const Duration(milliseconds: 1100));
}

void _setView(WidgetTester t, Size physical, double dpr) {
  t.view.physicalSize = physical;
  t.view.devicePixelRatio = dpr;
}

Future<(TestEnv, ProviderContainer)> _start(
  WidgetTester tester,
  Size physical,
  double dpr, {
  double textScale = 1.0,
}) async {
  await tester.runAsync(_loadRealFonts);
  final env =
      (await tester.runAsync(() async {
        final e = await TestEnv.create();
        await _seed(e);
        return e;
      }))!;
  _setView(tester, physical, dpr);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [servicesProvider.overrideWithValue(env.app)],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.build(AppColors.darkPalette),
        home: const Root(),
      ),
    ),
  );
  final container = ProviderScope.containerOf(
    tester.element(find.byType(Root)),
  );
  container.read(currentUserProvider.notifier).state = env.app.auth
      .findByUsername('owner');
  await _settle(tester);
  return (env, container);
}

Future<void> _finish(WidgetTester tester, TestEnv env) async {
  await tester.pumpWidget(const SizedBox()); // unmount (stops the clock timer)
  await tester.runAsync(env.dispose);
}

Future<void> _go(WidgetTester tester, ProviderContainer c, NavItem item) async {
  c.read(navProvider.notifier).state = item;
  await _settle(tester);
}

/// Taps a widget after scrolling it into view.
Future<void> _tap(WidgetTester tester, Finder f) async {
  expect(f, findsWidgets, reason: 'expected to find $f');
  await tester.ensureVisible(f.first);
  await tester.pump();
  await tester.tap(f.first, warnIfMissed: false);
  await _settle(tester);
}

/// Closes the top-most dialog / menu route.
Future<void> _closeTop(WidgetTester tester) async {
  final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
  nav.pop();
  await _settle(tester);
}

/// Every visible text must be inside the window (no clipped or off-screen labels).
void _expectInsideWindow(WidgetTester tester, Finder f, String what) {
  final size = tester.view.physicalSize / tester.view.devicePixelRatio;
  for (final e in f.evaluate()) {
    final box = e.renderObject as RenderBox?;
    if (box == null || !box.hasSize || !box.attached) continue;
    final r = box.localToGlobal(Offset.zero) & box.size;
    expect(
      r.left >= -0.5 &&
          r.top >= -0.5 &&
          r.right <= size.width + 0.5 &&
          r.bottom <= size.height + 0.5,
      isTrue,
      reason:
          '$what is outside the ${size.width.toStringAsFixed(0)}x${size.height.toStringAsFixed(0)} window: $r',
    );
  }
}

// ───────────────────────── regression helpers ─────────────────────────

final _dd = find.byWidgetPredicate(
  (w) => w is AppDropdown || w is AppDropdownButton,
  description: 'AppDropdown',
);
final _menuItems = find.byWidgetPredicate(
  (w) => w is DropdownMenuItem,
  description: 'open dropdown menu item',
);

/// Opens every AppDropdown on the current screen (or in the top dialog):
/// field inside the window, menu opens, whole menu inside the window, Esc closes it.
Future<List<String>> _exerciseDropdowns(
  WidgetTester tester,
  _Problems p,
  String where, {
  bool inDialog = false,
}) async {
  Finder scope() =>
      inDialog
          ? find.descendant(of: find.byType(Dialog).last, matching: _dd)
          : _dd;
  final n = scope().evaluate().length;
  final visited = <String>[];
  for (var k = 0; k < n; k++) {
    final f = scope().at(k);
    p.where = '$where • dropdown ${k + 1}/$n';
    await tester.ensureVisible(f);
    await tester.pump();
    _expectInsideWindow(tester, f, '$where dropdown ${k + 1}');
    await tester.tap(f, warnIfMissed: false);
    await _settle(tester);
    expect(
      _menuItems,
      findsWidgets,
      reason: '$where dropdown ${k + 1} did not open',
    );
    final menu =
        find
            .ancestor(of: _menuItems.first, matching: find.byType(Scrollable))
            .first;
    _expectInsideWindow(tester, menu, '$where dropdown ${k + 1} menu');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(tester);
    expect(
      _menuItems,
      findsNothing,
      reason: '$where dropdown ${k + 1}: Esc did not close the menu',
    );
    visited.add('$where #${k + 1}');
  }
  return visited;
}

/// Adds a product to the POS bill the way a cashier does: type / scan in the
/// POS scanner field and press Enter. (The product grid is lazily built and
/// shows the catalogue alphabetically, so items late in the list are not on
/// screen at small window sizes; tapping a tile that was never built cannot work.)
Future<void> _posScan(WidgetTester tester, String query) async {
  final field = find.descendant(
    of: find.byType(ScannerField).first,
    matching: find.byType(TextField),
  );
  await tester.enterText(field, query);
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await _settle(tester);
}

/// Filters a list page with its search box (the products table shows 25 rows
/// per page, so later products are on page 2 until the user searches).
Future<void> _search(WidgetTester tester, String hint, String query) async {
  final box = find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.hintText == hint,
    description: 'search "$hint"',
  );
  expect(box, findsOneWidget);
  await tester.enterText(box, query);
  await _settle(tester);
}

Future<void> _key(
  WidgetTester tester,
  LogicalKeyboardKey k, {
  bool control = false,
}) async {
  if (control) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(k);
  if (control) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await _settle(tester);
}

// ───────────────────────── tests ─────────────────────────

void main() {
  for (final (label, physical, dpr) in viewports) {
    testWidgets('every page and tab renders without overflow at $label', (
      tester,
    ) async {
      final p = _Problems()..start();
      try {
        final (env, c) = await _start(tester, physical, dpr);
        for (final item in NavItem.values) {
          p.where = '$label • ${item.label}';
          await _go(tester, c, item);
          // Visit every tab of the page (Sales/Invoices, Inventory, Settings…).
          final tabs = find.byType(Tab);
          final n = tabs.evaluate().length;
          for (var k = 1; k < n; k++) {
            p.where = '$label • ${item.label} • tab ${k + 1}';
            await _tap(tester, find.byType(Tab).at(k));
          }
        }
        await _finish(tester, env);
      } finally {
        p.stop();
      }
      p.expectNone();
    });
  }

  for (final (label, physical, dpr) in viewports) {
    testWidgets('POS payment method dropdown fits the billing panel at $label', (
      tester,
    ) async {
      final p = _Problems()..start();
      try {
        final (env, c) = await _start(tester, physical, dpr);
        p.where = '$label • POS';
        await _go(tester, c, NavItem.pos);
        // Put items on the bill (one long-named product, one cable line).
        await _posScan(tester, 'Seagate SkyHawk');
        await _posScan(tester, 'Cat6 Outdoor');
        expect(c.read(posDraftProvider)!.items.length, 2);
        final dd = find.byKey(const ValueKey('pos-payment-method'));
        expect(dd, findsOneWidget);
        // The field must sit fully inside the bill card and the window.
        _expectInsideWindow(tester, dd, 'Payment method field');
        p.where = '$label • POS • payment menu open';
        await _tap(tester, dd);
        for (final m in PaymentMethod.values) {
          final item = find.text(m.label);
          expect(item, findsWidgets);
          _expectInsideWindow(
            tester,
            item.last,
            'Payment menu item "${m.label}"',
          );
        }
        await tester.tap(
          find.text(PaymentMethod.mobileWallet.label).last,
          warnIfMissed: false,
        );
        await _settle(tester);
        expect(c.read(posDraftProvider)!.method, PaymentMethod.mobileWallet);
        // Selected long label is shown (ellipsized if needed) without overflow.
        expect(
          find.descendant(
            of: dd,
            matching: find.text(PaymentMethod.mobileWallet.label),
          ),
          findsWidgets,
        );
        _expectInsideWindow(
          tester,
          find.text('Complete (F9)'),
          'Complete button',
        );
        await _finish(tester, env);
      } finally {
        p.stop();
      }
      p.expectNone();
    });
  }

  for (final (label, physical, dpr) in viewports) {
    testWidgets(
      'serial number status filter, badges and detail fit at $label',
      (tester) async {
        final p = _Problems()..start();
        try {
          final (env, c) = await _start(tester, physical, dpr);
          p.where = '$label • Serial Numbers';
          await _go(tester, c, NavItem.serials);
          // Longest status labels must render as badges without overflow.
          for (final s in [
            SerialStatus.issuedToTechnician,
            SerialStatus.pendingInspection,
            SerialStatus.damaged,
            SerialStatus.sold,
            SerialStatus.underRepair,
          ]) {
            if (find.text(s.label).evaluate().isNotEmpty) {
              _expectInsideWindow(
                tester,
                find.text(s.label).first,
                'Status badge "${s.label}"',
              );
            }
          }
          final filter = find.byKey(const ValueKey('serial-status-filter'));
          expect(filter, findsOneWidget);
          p.where = '$label • Serial Numbers • status menu';
          await _tap(tester, filter);
          final longest = find.text(SerialStatus.awaitingRepair.label);
          expect(longest, findsWidgets);
          _expectInsideWindow(tester, longest.last, 'Status menu item');
          await tester.tap(longest.last, warnIfMissed: false);
          await _settle(tester);
          await _tap(tester, filter);
          await tester.tap(find.text('All statuses').last, warnIfMissed: false);
          await _settle(tester);
          p.where = '$label • Serial detail dialog';
          await _tap(tester, find.text('HKV-2026-000123454'));
          expect(find.byType(Dialog), findsOneWidget);
          await _closeTop(tester);
          await _finish(tester, env);
        } finally {
          p.stop();
        }
        p.expectNone();
      },
    );
  }

  for (final (label, physical, dpr) in viewports) {
    testWidgets('notification bell, badge and panel fit at $label', (
      tester,
    ) async {
      final p = _Problems()..start();
      try {
        final (env, c) = await _start(tester, physical, dpr);
        p.where = '$label • notifications';
        final bell = find.byKey(const ValueKey('notifications-button'));
        expect(bell, findsOneWidget);
        _expectInsideWindow(tester, bell, 'Notification bell');
        await _tap(tester, bell);
        final texts = [
          find.textContaining('awaiting your inspection'),
          find.textContaining('No backup in the last 36 hours'),
          find.textContaining('external backup folder'),
          find.textContaining('low or out of stock'),
          find.textContaining('repair job(s) pending'),
        ];
        for (final f in texts) {
          expect(f, findsOneWidget);
          _expectInsideWindow(tester, f, 'Notification text');
        }
        // Choosing a notification navigates to its page.
        await tester.tap(
          find.textContaining('repair job(s) pending'),
          warnIfMissed: false,
        );
        await _settle(tester);
        expect(c.read(navProvider), NavItem.repairs);
        await _finish(tester, env);
      } finally {
        p.stop();
      }
      p.expectNone();
    });
  }

  for (final (label, physical, dpr) in smallViewports) {
    testWidgets('dialogs and forms fit at $label', (tester) async {
      final p = _Problems()..start();
      try {
        final (env, c) = await _start(tester, physical, dpr);
        Future<void> dialog(String where, Future<void> Function() open) async {
          p.where = '$label • $where';
          await open();
          expect(
            find.byType(Dialog),
            findsWidgets,
            reason: '$where did not open',
          );
          await _closeTop(tester);
        }

        await _go(tester, c, NavItem.products);
        await dialog(
          'Add Product dialog',
          () => _tap(tester, find.widgetWithText(FilledButton, 'Add Product')),
        );
        await _search(
          tester,
          'Search name, SKU, model, barcode…',
          'Hikvision DS-2CD2143G2',
        );
        await dialog(
          'Edit Product dialog',
          () => _tap(tester, find.textContaining('Hikvision DS-2CD2143G2')),
        );

        await _go(tester, c, NavItem.purchases);
        await dialog(
          'Purchase detail',
          () => _tap(tester, find.textContaining('PUR-').first),
        );
        p.where = '$label • New Purchase dialog';
        await _tap(tester, find.widgetWithText(FilledButton, 'New Purchase'));
        await tester.enterText(
          find.descendant(
            of: find.descendant(
              of: find.byType(Dialog),
              matching: find.byType(ScannerField),
            ),
            matching: find.byType(TextField),
          ),
          'Seagate',
        );
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await _settle(tester);
        // A line was added: its four inputs and total must fit.
        expect(
          find.descendant(
            of: find.byType(Dialog),
            matching: find.textContaining('Seagate'),
          ),
          findsWidgets,
        );
        await _closeTop(tester);

        await _go(tester, c, NavItem.pos);
        await dialog(
          'POS customer picker',
          () => _tap(tester, find.text('Customer (F4)')),
        );
        await _tap(tester, find.text('Invoices'));
        await dialog(
          'Invoice detail',
          () => _tap(tester, find.textContaining('INV-').first),
        );

        await _go(tester, c, NavItem.customers);
        await dialog(
          'Customer account',
          () => _tap(
            tester,
            find.textContaining('Muhammad Abdullah Electronics'),
          ),
        );
        p.where = '$label • Receive payment dialog';
        await _tap(
          tester,
          find.textContaining('Muhammad Abdullah Electronics'),
        );
        await _tap(tester, find.text('Receive Payment'));
        await _closeTop(tester);
        await _closeTop(tester);

        await _go(tester, c, NavItem.technicians);
        await dialog(
          'Technician detail',
          () => _tap(tester, find.textContaining('Waqas Ahmed Qureshi')),
        );
        await dialog(
          'Issue material',
          () => _tap(tester, find.text('Issue Material')),
        );

        await _go(tester, c, NavItem.inventory);
        await _tap(tester, find.text('Inspection queue'));
        await dialog(
          'Inspection decision',
          () => _tap(tester, find.text('Sellable')),
        );

        await _go(tester, c, NavItem.quotations);
        await dialog(
          'Quotation editor',
          () => _tap(tester, find.textContaining('QT-').first),
        );
        await dialog(
          'New quotation',
          () =>
              _tap(tester, find.widgetWithText(FilledButton, 'New Quotation')),
        );

        await _go(tester, c, NavItem.repairs);
        await dialog(
          'Repair detail',
          () => _tap(tester, find.textContaining('DH-NVR-OLD-55')),
        );
        await dialog(
          'Receive device',
          () => _tap(tester, find.text('Receive Device')),
        );

        await _go(tester, c, NavItem.warranty);
        p.where = '$label • Warranty lookup result';
        await tester.enterText(
          find.byType(TextField).first,
          'HKV-2026-000123451',
        );
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await _settle(tester);

        await _go(tester, c, NavItem.settings);
        // (The Users tab was removed with the login system.)
        await _tap(tester, find.text('Audit & Data'));

        await _go(tester, c, NavItem.reports);
        for (final r in ReportKind.values) {
          p.where = '$label • Report "${r.title}"';
          await _tap(tester, find.text(r.title).first);
        }

        p.where = '$label • Global search';
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await _settle(tester);
        if (find.byType(Dialog).evaluate().isNotEmpty) {
          await tester.enterText(
            find.descendant(
              of: find.byType(Dialog),
              matching: find.byType(TextField),
            ),
            'hik',
          );
          await _settle(tester);
          await _closeTop(tester);
        }
        await _finish(tester, env);
      } finally {
        p.stop();
      }
      p.expectNone();
    });
  }

  testWidgets(
    'sidebar expand / collapse animation never overflows (1024x600)',
    (tester) async {
      final p = _Problems()..start();
      try {
        final (env, c) = await _start(tester, const Size(1024, 600), 1.0);
        p.where = 'sidebar animation';
        // Auto-collapsed below 1180 px: labels hidden, icons only.
        expect(find.text('CCTV & Solar System'), findsNothing);
        for (final tip in ['Expand menu', 'Collapse menu']) {
          await tester.tap(find.byTooltip(tip));
          for (var k = 0; k < 8; k++) {
            await tester.pump(
              const Duration(milliseconds: 35),
            ); // mid-animation frames
          }
          await _settle(tester);
        }
        await _go(tester, c, NavItem.dashboard);
        await _finish(tester, env);
      } finally {
        p.stop();
      }
      p.expectNone();
    },
  );

  for (final (label, physical, dpr) in [
    viewports[2],
    viewports[0],
    viewports[8],
  ]) {
    testWidgets('pages fit with 115% text size at $label', (tester) async {
      final p = _Problems()..start();
      try {
        final (env, c) = await _start(tester, physical, dpr, textScale: 1.15);
        for (final item in const [
          NavItem.dashboard,
          NavItem.pos,
          NavItem.serials,
          NavItem.inventory,
          NavItem.customers,
          NavItem.ledgers,
          NavItem.reports,
          NavItem.backup,
          NavItem.settings,
        ]) {
          p.where = '$label • text 115% • ${item.label}';
          await _go(tester, c, item);
        }
        p.where = '$label • text 115% • notifications';
        await _tap(tester, find.byKey(const ValueKey('notifications-button')));
        await _closeTop(tester);
        await _finish(tester, env);
      } finally {
        p.stop();
      }
      p.expectNone();
    });
  }

  // ── Regression: every migrated dropdown (24 locations) ──
  for (final (label, physical, dpr) in [
    viewports[0],
    viewports[11],
    viewports[13],
    viewports[5],
  ]) {
    testWidgets(
      'all 24 AppDropdown locations open on screen and close with Esc at $label',
      (tester) async {
        final p = _Problems()..start();
        final visited = <String>[];
        try {
          final (env, c) = await _start(tester, physical, dpr);
          Future<void> page(NavItem item, {String? tab}) async {
            await _go(tester, c, item);
            if (tab != null) await _tap(tester, find.text(tab));
            visited.addAll(
              await _exerciseDropdowns(
                tester,
                p,
                '$label • ${item.label}${tab == null ? '' : ' • $tab'}',
              ),
            );
          }

          Future<void> inDialog(
            String name,
            Future<void> Function() open, {
            int close = 1,
          }) async {
            await open();
            visited.addAll(
              await _exerciseDropdowns(
                tester,
                p,
                '$label • $name',
                inDialog: true,
              ),
            );
            for (var k = 0; k < close; k++) {
              await _closeTop(tester);
            }
          }

          await page(NavItem.products); // category, brand
          await inDialog(
            'Product dialog',
            () =>
                _tap(tester, find.widgetWithText(FilledButton, 'Add Product')),
          ); // category
          await page(NavItem.purchases); // supplier
          await inDialog(
            'New Purchase',
            () =>
                _tap(tester, find.widgetWithText(FilledButton, 'New Purchase')),
          ); // payment method
          await page(NavItem.serials); // status, product
          await page(NavItem.inventory, tab: 'Stock movements'); // product
          await page(
            NavItem.settings,
          ); // default payment method, warranty start
          await page(
            NavItem.settings,
            tab: 'Printing & Labels',
          ); // receipt format, printer
          await page(NavItem.backup); // backup hour, keep last
          await page(NavItem.pos); // payment method
          await _tap(tester, find.text('Invoices'));
          visited.addAll(
            await _exerciseDropdowns(tester, p, '$label • Invoices'),
          ); // status filter
          await inDialog('Return dialog', () async {
            await _tap(tester, find.textContaining('INV-').first);
            await _tap(tester, find.text('Return items'));
            // Customer invoices default to "Adjust account"; the refund method
            // dropdown belongs to a cash refund.
            await _tap(tester, find.text('Cash refund'));
          }, close: 2); // refund method
          await _go(tester, c, NavItem.customers);
          await inDialog(
            'Add customer',
            () =>
                _tap(tester, find.widgetWithText(FilledButton, 'Add Customer')),
          ); // opening balance sign
          await inDialog('Receive payment', () async {
            await _tap(
              tester,
              find.textContaining('Muhammad Abdullah Electronics'),
            );
            await _tap(tester, find.text('Receive Payment'));
          }, close: 2); // method, against invoice
          await _go(tester, c, NavItem.technicians);
          await inDialog(
            'Issue material',
            () => _tap(tester, find.text('Issue Material')),
          ); // technician
          await _go(tester, c, NavItem.repairs);
          await inDialog(
            'Receive device',
            () => _tap(tester, find.text('Receive Device')),
          ); // technician
          await inDialog('Update repair status', () async {
            await _tap(tester, find.textContaining('DH-NVR-OLD-55'));
            await _tap(tester, find.text('Update status'));
          }, close: 2); // technician
          await inDialog('Deliver repair', () async {
            await _tap(tester, find.textContaining('DH-NVR-OLD-55'));
            await _tap(tester, find.widgetWithText(FilledButton, 'Deliver'));
          }, close: 2); // method
          // ignore: avoid_print
          print(
            'Dropdowns exercised at $label (${visited.length}):\n  ${visited.join('\n  ')}',
          );
          expect(
            visited.length,
            24,
            reason:
                'expected the 24 migrated dropdowns, found:\n${visited.join('\n')}',
          );
          await _finish(tester, env);
        } finally {
          p.stop();
        }
        p.expectNone();
      },
    );
  }

  testWidgets(
    'dropdowns work with the keyboard (arrows + Enter) and Tab focus',
    (tester) async {
      final p = _Problems()..start();
      try {
        final (env, c) = await _start(tester, const Size(1024, 600), 1.0);
        p.where = 'keyboard • POS payment method';
        await _go(tester, c, NavItem.pos);
        await _posScan(tester, 'Seagate SkyHawk');
        final dd = find.byKey(const ValueKey('pos-payment-method'));
        await _tap(tester, dd); // opens with Cash highlighted
        for (
          var k = 0;
          k < PaymentMethod.values.indexOf(PaymentMethod.mobileWallet);
          k++
        ) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.pump();
        }
        await _key(tester, LogicalKeyboardKey.enter);
        expect(_menuItems, findsNothing);
        expect(c.read(posDraftProvider)!.method, PaymentMethod.mobileWallet);
        // Re-open from the keyboard: focus the field and press Enter/Space.
        p.where = 'keyboard • reopen with Space';
        final focusable =
            find.descendant(of: dd, matching: find.byType(Focus)).first;
        Focus.of(tester.element(focusable)).requestFocus();
        await tester.pump();
        await _key(tester, LogicalKeyboardKey.space);
        expect(
          _menuItems,
          findsWidgets,
          reason: 'Space on a focused dropdown should open it',
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump();
        await _key(tester, LogicalKeyboardKey.enter);
        expect(c.read(posDraftProvider)!.method, PaymentMethod.cheque);
        await _finish(tester, env);
      } finally {
        p.stop();
      }
      p.expectNone();
    },
  );

  // ── Regression: notifications with very long text and many unread ──
  for (final (label, physical, dpr) in [
    viewports[13],
    viewports[0],
    viewports[8],
    viewports[5],
  ]) {
    testWidgets('notification panel with 12 unread and very long messages at $label', (
      tester,
    ) async {
      await tester.runAsync(_loadRealFonts);
      _setView(tester, physical, dpr);
      addTearDown(tester.view.reset);
      final p = _Problems()..start();
      NavItem? picked;
      final long =
          'Serial HKV-2026-000123454 returned by technician Waqas Ahmed Qureshi (Senior Installer) from job F-7/2 House 22 '
          'with condition "IR LEDs not working at night, housing cracked, cable gland missing" is still waiting for owner inspection '
          'and cannot be sold until it is approved as sellable, repairable or damaged.';
      final notes = <AppNote>[
        for (var k = 0; k < 12; k++)
          (
            Icons.warning_amber_rounded,
            k.isEven ? '$long (#${k + 1})' : 'Short notice #${k + 1}',
            NavItem.values[k % NavItem.values.length],
          ),
      ];
      try {
        p.where = '$label • notification bell';
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.build(AppColors.darkPalette),
            home: Scaffold(
              appBar: AppBar(
                actions: [
                  NotificationBell(notes: notes, onSelected: (n) => picked = n),
                  const SizedBox(width: 8),
                ],
              ),
            ),
          ),
        );
        await _settle(tester);
        expect(
          find.text('9+'),
          findsOneWidget,
          reason: 'badge should cap at 9+',
        );
        _expectInsideWindow(tester, find.text('9+'), 'Unread badge');
        p.where = '$label • notification panel open';
        await _tap(tester, find.byKey(const ValueKey('notifications-button')));
        expect(find.text('Notifications (12)'), findsOneWidget);
        final panel =
            find
                .ancestor(
                  of: find.text('Notifications (12)'),
                  matching: find.byType(Scrollable),
                )
                .first;
        _expectInsideWindow(tester, panel, 'Notification panel');
        // Long messages wrap fully (never cut off with maxLines/clip).
        final first = tester.renderObject<RenderParagraph>(
          find.text(notes.first.$2),
        );
        expect(first.didExceedMaxLines, isFalse);
        expect(
          first.size.height,
          greaterThan(40),
          reason: 'long message should wrap onto several lines',
        );
        // The last notification is reachable by scrolling the panel and opens its page.
        final last = find.text(notes.last.$2);
        await tester.scrollUntilVisible(last, 120, scrollable: panel);
        await tester.pump();
        _expectInsideWindow(tester, last, 'Last notification');
        await tester.tap(last);
        await _settle(tester);
        expect(picked, notes.last.$3);
        // Empty state.
        p.where = '$label • empty panel';
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.build(AppColors.darkPalette),
            home: Scaffold(
              appBar: AppBar(
                actions: [
                  NotificationBell(notes: const [], onSelected: (_) {}),
                ],
              ),
            ),
          ),
        );
        await _settle(tester);
        expect(find.text('9+'), findsNothing);
        await _tap(tester, find.byKey(const ValueKey('notifications-button')));
        expect(find.text('You are all caught up'), findsOneWidget);
        await _closeTop(tester);
      } finally {
        p.stop();
      }
      p.expectNone();
    });
  }

  // ── Regression: full POS billing flow at 1024x600 and 1366x768 ──
  for (final (label, physical, dpr) in [viewports[0], viewports[2]]) {
    testWidgets(
      'POS billing end-to-end at $label (12 lines, customer, credit, F9)',
      (tester) async {
        final p = _Problems()..start();
        try {
          final (env, c) = await _start(tester, physical, dpr);
          final app = env.app;
          p.where = '$label • POS add lines';
          await _go(tester, c, NavItem.pos);
          await _posScan(tester, 'Seagate SkyHawk');
          await _posScan(tester, 'Cat6 Outdoor');
          for (var i = 1; i <= 10; i++) {
            await _posScan(tester, 'Accessory item number $i with');
          }
          expect(c.read(posDraftProvider)!.items.length, 12);
          p.where = '$label • POS customer via F4';
          await _key(tester, LogicalKeyboardKey.f4);
          await tester.enterText(
            find.descendant(
              of: find.byType(Dialog),
              matching: find.byType(TextField),
            ),
            'Muhammad Abdullah',
          );
          await tester.testTextInput.receiveAction(TextInputAction.done);
          await _settle(tester);
          final cust = app.parties
              .list(PartyKind.customer)
              .firstWhere((x) => x.name.startsWith('Muhammad Abdullah'));
          expect(c.read(posDraftProvider)!.customerId, cust.id);
          // Banner for installed-but-not-invoiced material, balance line, every control reachable.
          expect(
            find.textContaining('installed item(s) not invoiced'),
            findsOneWidget,
          );
          for (final f in [
            find.byKey(const ValueKey('pos-payment-method')),
            find.text('Amount received'),
            find.text('Exact'),
            find.text('Credit (0)'),
            find.text('Hold (F8)'),
            find.text('Held'),
            find.text('Complete (F9)'),
          ]) {
            await tester.ensureVisible(f.first);
            await tester.pump();
            _expectInsideWindow(tester, f.first, 'POS control $f');
          }
          p.where = '$label • POS credit sale via F9';
          await _tap(tester, find.text('Credit (0)'));
          final before = app.parties.byId(PartyKind.customer, cust.id)!.balance;
          final total = c.read(posDraftProvider)!.total;
          await tester.runAsync(() async {
            await tester.sendKeyEvent(LogicalKeyboardKey.f9);
            await Future<void>.delayed(const Duration(milliseconds: 300));
          });
          await _settle(tester);
          expect(find.text('Sale completed'), findsOneWidget);
          _expectInsideWindow(
            tester,
            find.text('New sale  (Enter)'),
            'Sale-completed dialog button',
          );
          await _key(tester, LogicalKeyboardKey.enter);
          expect(find.text('Sale completed'), findsNothing);
          expect(
            app.parties.byId(PartyKind.customer, cust.id)!.balance,
            before + total,
            reason: 'credit sale must post to the customer ledger',
          );
          expect(
            c.read(posDraftProvider)!.items,
            isEmpty,
            reason: 'new bill after completing',
          );
          expect(app.integrity.check(), isEmpty);
          await _finish(tester, env);
        } finally {
          p.stop();
        }
        p.expectNone();
      },
    );
  }

  testWidgets('keyboard shortcuts still work: F2, F3, F8, Ctrl+K, Ctrl+S', (
    tester,
  ) async {
    final p = _Problems()..start();
    try {
      final (env, c) = await _start(tester, const Size(1366, 768), 1.0);
      p.where = 'shortcuts';
      await _go(tester, c, NavItem.pos); // POS autofocuses its scanner…
      await _go(
        tester,
        c,
        NavItem.dashboard,
      ); // …which is disposed here: focus falls back to the route scope
      await _key(tester, LogicalKeyboardKey.f2);
      expect(c.read(navProvider), NavItem.pos, reason: 'F2 opens POS');
      await _posScan(tester, 'Seagate SkyHawk');
      expect(c.read(posDraftProvider)!.items, isNotEmpty);
      // Focus away from the scanner (as a click on an empty area does):
      // shortcuts must keep working from any focus.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      final heldBefore =
          env.app.sales
              .list(status: DocStatus.draft)
              .where((s) => s.items.isNotEmpty)
              .length;
      await tester.runAsync(() async {
        await tester.sendKeyEvent(LogicalKeyboardKey.f8);
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await _settle(tester);
      expect(
        env.app.sales
            .list(status: DocStatus.draft)
            .where((s) => s.items.isNotEmpty)
            .length,
        heldBefore + 1,
        reason: 'F8 holds the bill',
      );
      expect(c.read(posDraftProvider)!.items, isEmpty);
      await _key(tester, LogicalKeyboardKey.f3);
      expect(
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<ScannerField>(),
        isNotNull,
        reason: 'F3 focuses the scanner',
      );
      await _go(tester, c, NavItem.dashboard);
      await _key(tester, LogicalKeyboardKey.keyK, control: true);
      expect(
        find.textContaining('Type or scan a barcode'),
        findsOneWidget,
        reason: 'Ctrl+K opens search',
      );
      await _closeTop(tester);
      await _go(tester, c, NavItem.products);
      await _tap(tester, find.widgetWithText(FilledButton, 'Add Product'));
      await tester.enterText(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.widgetWithText(TextFormField, 'Product name *'),
        ),
        'Shortcut Test Camera',
      );
      final costField = find.descendant(
        of: find.byType(Dialog),
        matching: find.widgetWithText(TextFormField, 'Purchase price (Rs) *'),
      );
      await tester.enterText(costField, '1000');
      await tester.enterText(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.widgetWithText(TextFormField, 'Selling price (Rs) *'),
        ),
        '1500',
      );
      await tester.runAsync(() async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await _settle(tester);
      expect(
        env.app.catalog.search('Shortcut Test Camera'),
        isNotEmpty,
        reason: 'Ctrl+S saves the product',
      );
      await _finish(tester, env);
    } finally {
      p.stop();
    }
    p.expectNone();
  });
}
