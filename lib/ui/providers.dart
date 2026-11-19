import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/store/data_store.dart';
import '../domain/models/user.dart';
import '../domain/services/app_services.dart';

/// Overridden in main() with the real instance.
final servicesProvider = Provider<AppServices>((ref) => throw UnimplementedError('servicesProvider not initialised'));

/// Emits whenever any box changes; watch it to rebuild with fresh data.
final dataVersionProvider = StreamProvider<int>((ref) {
  final store = ref.watch(servicesProvider).ctx.store;
  var n = 0;
  // Writes that only add to the internal error log change nothing on screen,
  // so they do not rebuild every page.
  return store.changes.where((boxes) => boxes.any((b) => b != Boxes.errorLog)).map((_) => ++n);
});

/// The services, re-published after every data change. Every page and
/// detail dialog watches this, so whatever a commit changes (new record,
/// edit, archive, restore, sale, purchase, payment, stock, balances,
/// expenses, settings) appears on screen at once, wherever it is shown.
///
/// It is a [Notifier] on purpose: the value is always the same
/// [AppServices] object, and a plain `Provider` only notifies listeners
/// when its value is a different object, so it never told the screens that
/// the data had changed (they refreshed only when something else rebuilt
/// them, such as switching pages). [_LiveServices.updateShouldNotify]
/// returns true, so each data change reaches every watching widget.
final liveServicesProvider = NotifierProvider<_LiveServices, AppServices>(_LiveServices.new);

class _LiveServices extends Notifier<AppServices> {
  @override
  AppServices build() {
    ref.watch(dataVersionProvider);
    return ref.watch(servicesProvider);
  }

  @override
  bool updateShouldNotify(AppServices previous, AppServices next) => true;
}

final currentUserProvider = StateProvider<AppUser?>((ref) => null);

enum NavItem {
  dashboard('Dashboard'),
  products('Products'),
  categories('Categories'),
  purchases('Purchases'),
  pos('Sales / POS'),
  inventory('Inventory'),
  serials('Serial Numbers'),
  technicians('Technicians'),
  customers('Customers'),
  suppliers('Suppliers'),
  returns('Returns'),
  quotations('Quotations'),
  warranty('Warranty'),
  repairs('Repair Management'),
  ledgers('Payments & Ledgers'),
  expenses('Expenses'),
  finance('Profit & Loss'),
  reports('Reports'),
  backup('Backup & Restore'),
  settings('Settings');

  final String label;
  const NavItem(this.label);
}

final navProvider = StateProvider<NavItem>((ref) => NavItem.dashboard);

final themeModeProvider = StateProvider<bool>((ref) => true); // true = dark
