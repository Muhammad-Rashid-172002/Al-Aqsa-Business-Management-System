import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../domain/models/party.dart';
import '../../domain/models/product.dart';
import '../../domain/models/user.dart';
import '../../domain/services/warranty_repair_service.dart';
import '../splash/splash_screen.dart';
import '../pages/dashboard_page.dart';
import '../pages/backup_page.dart';
import '../pages/categories_page.dart';
import '../pages/inventory_page.dart';
import '../pages/ledgers_page.dart';
import '../pages/parties_page.dart';
import '../pages/purchases_page.dart';
import '../pages/quotations_page.dart';
import '../pages/repairs_page.dart';
import '../pages/expenses_page.dart';
import '../pages/finance_page.dart';
import '../pages/reports_page.dart';
import '../pages/returns_page.dart';
import '../pages/sales_page.dart';
import '../pages/serials_page.dart';
import '../pages/settings_page.dart';
import '../pages/technicians_page.dart';
import '../pages/warranty_page.dart';
import '../pages/products_page.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';

const _icons = <NavItem, IconData>{
  NavItem.dashboard: Icons.space_dashboard_outlined,
  NavItem.products: Icons.inventory_2_outlined,
  NavItem.categories: Icons.category_outlined,
  NavItem.purchases: Icons.local_shipping_outlined,
  NavItem.pos: Icons.point_of_sale_outlined,
  NavItem.inventory: Icons.warehouse_outlined,
  NavItem.serials: Icons.qr_code_2_outlined,
  NavItem.technicians: Icons.engineering_outlined,
  NavItem.customers: Icons.people_alt_outlined,
  NavItem.suppliers: Icons.storefront_outlined,
  NavItem.returns: Icons.assignment_return_outlined,
  NavItem.quotations: Icons.request_quote_outlined,
  NavItem.warranty: Icons.verified_user_outlined,
  NavItem.repairs: Icons.build_circle_outlined,
  NavItem.ledgers: Icons.account_balance_wallet_outlined,
  NavItem.expenses: Icons.receipt_long_outlined,
  NavItem.finance: Icons.account_balance_outlined,
  NavItem.reports: Icons.insights_outlined,
  NavItem.backup: Icons.backup_outlined,
  NavItem.settings: Icons.settings_outlined,
};

const _required = <NavItem, Permission>{
  NavItem.dashboard: Permission.viewDashboard,
  NavItem.products: Permission.manageProducts,
  NavItem.categories: Permission.manageProducts,
  NavItem.purchases: Permission.managePurchases,
  NavItem.pos: Permission.manageSales,
  NavItem.inventory: Permission.manageProducts,
  NavItem.serials: Permission.manageProducts,
  NavItem.technicians: Permission.viewOwnStock,
  NavItem.customers: Permission.manageCustomers,
  NavItem.suppliers: Permission.manageSuppliers,
  NavItem.returns: Permission.manageSales,
  NavItem.quotations: Permission.manageQuotations,
  NavItem.warranty: Permission.manageWarranty,
  NavItem.repairs: Permission.viewAssignedRepairs,
  NavItem.ledgers: Permission.manageLedgers,
  NavItem.expenses: Permission.manageExpenses,
  NavItem.finance: Permission.viewFinancials,
  NavItem.reports: Permission.viewReports,
  NavItem.backup: Permission.backupRestore,
  NavItem.settings: Permission.manageSettings,
};

bool canSee(AppUser u, NavItem item) {
  if (item == NavItem.technicians) {
    return u.can(Permission.issueStock) || u.can(Permission.viewOwnStock);
  }
  if (item == NavItem.repairs) {
    return u.can(Permission.manageRepairs) ||
        u.can(Permission.viewAssignedRepairs);
  }
  return u.can(_required[item]!);
}

class Root extends ConsumerWidget {
  const Root({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 400),
      child:
          user == null
              ? const SplashScreen(key: ValueKey('splash'))
              : const AppShell(key: ValueKey('shell')),
    );
  }
}

class AppShell extends ConsumerWidget {
  const AppShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AppTheme.of(context);
    final nav = ref.watch(navProvider);
    final user = ref.watch(currentUserProvider)!;
    final visible = NavItem.values.where((n) => canSee(user, n)).toList();
    final current =
        visible.contains(nav)
            ? nav
            : (visible.isEmpty ? NavItem.dashboard : visible.first);

    return AppShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true):
            () => showGlobalSearch(context, ref),
        const SingleActivator(LogicalKeyboardKey.f2): () {
          if (canSee(user, NavItem.pos)) {
            ref.read(navProvider.notifier).state = NavItem.pos;
          }
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: Row(
            children: [
              _Sidebar(items: visible, current: current),
              Expanded(
                child: Column(
                  children: [
                    const _TopBar(),
                    Expanded(
                      child: Container(
                        color: c.bg,
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 260),
                          switchInCurve: Curves.easeOutCubic,
                          transitionBuilder:
                              (child, anim) => FadeTransition(
                                opacity: anim,
                                child: SlideTransition(
                                  position: Tween(
                                    begin: const Offset(0.015, 0),
                                    end: Offset.zero,
                                  ).animate(anim),
                                  child: child,
                                ),
                              ),
                          // Below ~720 x 560 the page scrolls instead of squeezing
                          // panels (1366x768 laptops at 150% scaling, 1024x600).
                          child: KeyedSubtree(
                            key: ValueKey(current),
                            child: MinSizeScroll(
                              minWidth: 720,
                              minHeight: 560,
                              child: pageFor(current),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget pageFor(NavItem item) => switch (item) {
    NavItem.dashboard => const DashboardPage(),
    NavItem.products => const ProductsPage(),
    NavItem.categories => const CategoriesPage(),
    NavItem.purchases => const PurchasesPage(),
    NavItem.pos => const SalesPage(),
    NavItem.inventory => const InventoryPage(),
    NavItem.serials => const SerialsPage(),
    NavItem.technicians => const TechniciansPage(),
    NavItem.customers => const PartiesPage(kind: PartyKind.customer),
    NavItem.suppliers => const PartiesPage(kind: PartyKind.supplier),
    NavItem.returns => const ReturnsPage(),
    NavItem.quotations => const QuotationsPage(),
    NavItem.warranty => const WarrantyPage(),
    NavItem.repairs => const RepairsPage(),
    NavItem.ledgers => const LedgersPage(),
    NavItem.expenses => const ExpensesPage(),
    NavItem.finance => const FinancePage(),
    NavItem.reports => const ReportsPage(),
    NavItem.backup => const BackupPage(),
    NavItem.settings => const SettingsPage(),
  };
}

class _Sidebar extends ConsumerStatefulWidget {
  final List<NavItem> items;
  final NavItem current;
  const _Sidebar({required this.items, required this.current});
  @override
  ConsumerState<_Sidebar> createState() => _SidebarState();
}

class _SidebarState extends ConsumerState<_Sidebar> {
  /// null = automatic (collapsed when the window is narrower than 1180 px).
  bool? _userCollapsed;

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    final collapsed = _userCollapsed ?? MediaQuery.sizeOf(context).width < 1180;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
      width: collapsed ? 76 : 248,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [c.surface, c.bg],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
        border: Border(right: BorderSide(color: c.border)),
      ),
      // Labels follow the *current* (animating) width, so nothing overflows
      // while the sidebar opens or closes.
      child: LayoutBuilder(
        builder: (context, cons) {
          final narrow = cons.maxWidth < 170;
          return Column(
            children: [
              SizedBox(
                height: 72,
                child: Row(
                  children: [
                    SizedBox(width: narrow ? (cons.maxWidth - 36) / 2 : 20),
                    const AppLogo(size: 36),
                    if (!narrow) ...[
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'AL-AQSA',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              softWrap: false,
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                color: c.text,
                                letterSpacing: 1.2,
                              ),
                            ),
                            Text(
                              'CCTV & Solar System',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              softWrap: false,
                              style: TextStyle(
                                fontSize: 11,
                                color: c.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.symmetric(
                    horizontal: narrow ? 10 : 12,
                    vertical: 8,
                  ),
                  children: [
                    for (final item in widget.items)
                      _NavTile(
                        icon: _icons[item]!,
                        label: item.label,
                        selected: item == widget.current,
                        collapsed: narrow,
                        onTap:
                            () => ref.read(navProvider.notifier).state = item,
                      ),
                  ],
                ),
              ),
              IconButton(
                tooltip: collapsed ? 'Expand menu' : 'Collapse menu',
                onPressed: () => setState(() => _userCollapsed = !collapsed),
                icon: Icon(
                  collapsed
                      ? Icons.keyboard_double_arrow_right
                      : Icons.keyboard_double_arrow_left,
                  color: c.textMuted,
                ),
              ),
              const SizedBox(height: 10),
            ],
          );
        },
      ),
    );
  }
}

class _NavTile extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final bool collapsed;
  final VoidCallback onTap;
  const _NavTile({
    required this.icon,
    required this.label,
    required this.selected,
    required this.collapsed,
    required this.onTap,
  });
  @override
  State<_NavTile> createState() => _NavTileState();
}

class _NavTileState extends State<_NavTile> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    final active = widget.selected;
    final tile = MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: EdgeInsets.symmetric(
            horizontal: widget.collapsed ? 0 : 14,
            vertical: 11,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            gradient:
                active
                    ? LinearGradient(
                      colors: [
                        c.primary.withValues(alpha: 0.9),
                        c.primary.withValues(alpha: 0.55),
                      ],
                    )
                    : null,
            color:
                active ? null : (_hover ? c.surfaceHigh : Colors.transparent),
            boxShadow:
                active
                    ? [
                      BoxShadow(
                        color: c.primary.withValues(alpha: 0.35),
                        blurRadius: 14,
                        offset: const Offset(0, 4),
                      ),
                    ]
                    : null,
          ),
          child: Row(
            mainAxisAlignment:
                widget.collapsed
                    ? MainAxisAlignment.center
                    : MainAxisAlignment.start,
            children: [
              Icon(
                widget.icon,
                size: 20,
                color: active ? Colors.white : (_hover ? c.text : c.textMuted),
              ),
              if (!widget.collapsed) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    widget.label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                      color: active ? Colors.white : c.text,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    return widget.collapsed
        ? Tooltip(message: widget.label, child: tile)
        : tile;
  }
}

class _TopBar extends ConsumerStatefulWidget {
  const _TopBar();
  @override
  ConsumerState<_TopBar> createState() => _TopBarState();
}

class _TopBarState extends ConsumerState<_TopBar> {
  late Timer _timer;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(
      const Duration(seconds: 20),
      (_) => setState(() => _now = DateTime.now()),
    );
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    final app = ref.watch(liveServicesProvider);
    final user = ref.watch(currentUserProvider)!;
    final notes = <AppNote>[];
    if (user.can(Permission.approveInspection)) {
      final n = app.inspections.list().length;
      if (n > 0) {
        notes.add((
          Icons.fact_check_outlined,
          '$n returned item(s) awaiting your inspection',
          NavItem.inventory,
        ));
      }
    }
    if (user.can(Permission.backupRestore)) {
      final last = app.backup.lastBackupAt;
      if (last == null || DateTime.now().difference(last).inHours > 36) {
        notes.add((
          Icons.backup_outlined,
          'No backup in the last 36 hours',
          NavItem.backup,
        ));
      }
      if (app.backup.backupDirectory == null) {
        notes.add((
          Icons.usb,
          'Set an external backup folder (USB drive)',
          NavItem.backup,
        ));
      }
      final err = app.backup.lastBackupError;
      if (err != null) {
        notes.add((Icons.error_outline, 'Last backup failed: $err', NavItem.backup));
      }
    }
    if (user.can(Permission.manageProducts) &&
        app.ctx.settings.lowStockAlerts) {
      final low =
          app.catalog
              .products()
              .where(
                (p) =>
                    p.stockQty <= p.minStock &&
                    !(p.stockQty.isZero && p.minStock.isZero),
              )
              .toList();
      if (low.isNotEmpty) {
        notes.add((
          Icons.warning_amber_rounded,
          '${low.length} product(s) low or out of stock',
          NavItem.inventory,
        ));
      }
    }
    if (user.can(Permission.manageRepairs)) {
      final open = app.repairs.list(openOnly: true).length;
      if (open > 0) {
        notes.add((
          Icons.build_circle_outlined,
          '$open repair job(s) pending',
          NavItem.repairs,
        ));
      }
    }
    if (user.can(Permission.manageWarranty)) {
      final exp = app.warranty.expiringWithin(30).length;
      if (exp > 0) {
        notes.add((
          Icons.verified_user_outlined,
          '$exp warranty(ies) expiring in 30 days',
          NavItem.warranty,
        ));
      }
    }

    return LayoutBuilder(
      builder: (context, cons) {
        final w = cons.maxWidth;
        final compact = w < 900; // icon-only New Sale, short date, avatar only
        final tiny = w < 720; // search collapses to an icon button
        return Container(
          height: 64,
          padding: EdgeInsets.symmetric(horizontal: compact ? 14 : 24),
          decoration: BoxDecoration(
            color: c.surface,
            border: Border(bottom: BorderSide(color: c.border)),
          ),
          child: Row(
            children: [
              if (tiny)
                IconButton(
                  tooltip: 'Search (Ctrl+K)',
                  onPressed: () => showGlobalSearch(context, ref),
                  icon: Icon(Icons.search, color: c.text),
                )
              else
                Flexible(
                  flex: 3,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 360),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => showGlobalSearch(context, ref),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: c.surfaceHigh,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: c.border),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.search, size: 18, color: c.textMuted),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Search or scan product, serial, customer…',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: c.textMuted,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: c.border),
                              ),
                              child: Text(
                                'Ctrl K',
                                style: TextStyle(
                                  color: c.textMuted,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              const SizedBox(width: 12),
              if (canSee(user, NavItem.pos))
                compact
                    ? IconButton.filled(
                      tooltip: 'New Sale (F2)',
                      onPressed:
                          () =>
                              ref.read(navProvider.notifier).state =
                                  NavItem.pos,
                      icon: const Icon(Icons.add_shopping_cart, size: 18),
                    )
                    : FilledButton.icon(
                      onPressed:
                          () =>
                              ref.read(navProvider.notifier).state =
                                  NavItem.pos,
                      icon: const Icon(Icons.add_shopping_cart, size: 18),
                      label: const Text('New Sale  (F2)'),
                    ),
              const Spacer(),
              if (!tiny) ...[
                Text(
                  DateFormat(
                    compact ? 'd MMM • h:mm a' : 'EEE, d MMM yyyy  •  h:mm a',
                  ).format(_now),
                  maxLines: 1,
                  style: TextStyle(color: c.textMuted, fontSize: 13),
                ),
                const SizedBox(width: 12),
              ],
              NotificationBell(
                notes: notes,
                onSelected: (n) => ref.read(navProvider.notifier).state = n,
              ),
              const SizedBox(width: 8),
              // No accounts: this single-computer shop app opens straight to the
              // Dashboard, so the former account menu is reduced to its theme toggle.
              IconButton(
                key: const ValueKey('theme-toggle'),
                tooltip: 'Toggle light / dark theme',
                onPressed:
                    () =>
                        ref.read(themeModeProvider.notifier).state =
                            !ref.read(themeModeProvider),
                icon: Icon(
                  ref.watch(themeModeProvider)
                      ? Icons.light_mode_outlined
                      : Icons.dark_mode_outlined,
                  color: c.text,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// One notification: icon, message, page it opens.
typedef AppNote = (IconData, String, NavItem);

/// Bell with unread badge and the notification panel.
///
/// The panel is 240-380 px wide (never wider than the window), messages wrap
/// onto as many lines as they need, and the badge shows "9+" beyond nine.
class NotificationBell extends StatelessWidget {
  final List<AppNote> notes;
  final ValueChanged<NavItem> onSelected;
  const NotificationBell({
    super.key,
    required this.notes,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    final screen = MediaQuery.sizeOf(context);
    final panelWidth = (screen.width - 24).clamp(240.0, 380.0);
    return PopupMenuButton<NavItem>(
      key: const ValueKey('notifications-button'),
      tooltip: 'Notifications',
      offset: const Offset(0, 48),
      // Menus default to max 280 px wide; give the panel room for full
      // sentences but never more than the window allows.
      constraints: BoxConstraints(minWidth: panelWidth, maxWidth: panelWidth),
      // Very long lists scroll inside the menu (Flutter caps menu height to the window).
      onSelected: onSelected,
      itemBuilder:
          (_) => [
            PopupMenuItem<NavItem>(
              enabled: false,
              height: 36,
              child: Text(
                notes.isEmpty
                    ? 'Notifications'
                    : 'Notifications (${notes.length})',
                style: TextStyle(fontWeight: FontWeight.w700, color: c.text),
              ),
            ),
            const PopupMenuDivider(height: 1),
            if (notes.isEmpty)
              PopupMenuItem<NavItem>(
                enabled: false,
                child: Row(
                  children: [
                    Icon(Icons.check_circle_outline, size: 18, color: c.accent),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'You are all caught up',
                        style: TextStyle(color: c.textMuted),
                      ),
                    ),
                  ],
                ),
              )
            else
              for (final n in notes)
                PopupMenuItem<NavItem>(
                  value: n.$3,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Icon(n.$1, size: 18, color: c.warning),
                        ),
                        const SizedBox(width: 10),
                        // Wraps onto extra lines instead of overflowing the menu.
                        Expanded(
                          child: Text(
                            n.$2,
                            style: TextStyle(color: c.text, fontSize: 13.5),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Icon(Icons.chevron_right, size: 18, color: c.textMuted),
                      ],
                    ),
                  ),
                ),
          ],
      child: Badge(
        isLabelVisible: notes.isNotEmpty,
        label: Text(notes.length > 9 ? '9+' : '${notes.length}'),
        backgroundColor: c.danger,
        offset: const Offset(-2, 2),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(Icons.notifications_none_rounded, color: c.text),
        ),
      ),
    );
  }
}

Future<void> showGlobalSearch(BuildContext context, WidgetRef ref) async {
  final app = ref.read(servicesProvider);
  final c = AppTheme.of(context);
  await showDialog<void>(
    context: context,
    builder: (ctx) {
      var q = '';
      return StatefulBuilder(
        builder: (ctx, setState) {
          final scan = q.isEmpty ? null : app.catalog.lookup(q);
          final products =
              q.isEmpty
                  ? const <Product>[]
                  : app.catalog.search(q).take(8).toList();
          final customers =
              q.isEmpty
                  ? const <Party>[]
                  : app.parties
                      .list(PartyKind.customer, query: q)
                      .take(5)
                      .toList();
          final w =
              scan?.serial == null
                  ? null
                  : app.warranty.check(scan!.serial!.serial);
          final screen = MediaQuery.sizeOf(ctx);
          return Dialog(
            alignment: const Alignment(0, -0.6),
            insetPadding: EdgeInsets.symmetric(
              horizontal: screen.width < 700 ? 12 : 40,
              vertical: 24,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 640,
                maxHeight: screen.height * 0.85,
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      autofocus: true,
                      decoration: const InputDecoration(
                        hintText:
                            'Type or scan a barcode, QR, serial number, product or customer',
                        prefixIcon: Icon(Icons.qr_code_scanner),
                      ),
                      onChanged: (v) => setState(() => q = v),
                      onSubmitted: (v) => setState(() => q = v),
                    ),
                    const SizedBox(height: 12),
                    if (q.isNotEmpty &&
                        scan == null &&
                        products.isEmpty &&
                        customers.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          'No match for "$q". If this is a new barcode, add it to a product.',
                          style: TextStyle(color: c.textMuted),
                        ),
                      ),
                    if (scan != null)
                      ListTile(
                        leading: Icon(
                          scan.serial != null ? Icons.memory : Icons.qr_code,
                          color: c.accent,
                        ),
                        title: Text(scan.product.name),
                        subtitle: Text(
                          scan.serial != null
                              ? 'Serial ${scan.serial!.serial} • ${scan.serial!.status.label}${w == null ? '' : ' • Warranty: ${w.state.name}${w.state == WarrantyState.active ? ' (${w.daysLeft} days left)' : ''}'}'
                              : 'In stock: ${scan.product.stockQty} • Price: ${scan.product.sellingPrice.format()}',
                        ),
                      ),
                    for (final p in products)
                      if (scan == null || p.id != scan.product.id)
                        ListTile(
                          dense: true,
                          leading: const Icon(Icons.inventory_2_outlined),
                          title: Text(p.name),
                          subtitle: Text(
                            '${p.brand} ${p.model} • Stock ${p.stockQty}',
                          ),
                          trailing: Text(p.sellingPrice.format()),
                          onTap: () {
                            ref.read(navProvider.notifier).state =
                                NavItem.products;
                            Navigator.pop(ctx);
                          },
                        ),
                    for (final cu in customers)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.person_outline),
                        title: Text(cu.name),
                        subtitle: Text(cu.phone),
                        trailing: Text('Balance ${cu.balance.format()}'),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    },
  );
}
