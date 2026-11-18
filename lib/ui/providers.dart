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

/// Watches data changes and returns the services (convenience for pages).
final liveServicesProvider = Provider<AppServices>((ref) {
  ref.watch(dataVersionProvider);
  return ref.watch(servicesProvider);
});

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
