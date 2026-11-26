import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/ids.dart';
import '../../core/password_hasher.dart';
import '../../data/store/data_store.dart';
import '../../core/errors.dart';
import '../../core/money.dart';
import '../../core/qty.dart';
import '../models/documents.dart';
import '../models/party.dart';
import '../models/product.dart';
import 'permanent_delete_service.dart';
import 'auth_service.dart';
import 'backup_service.dart';
import 'catalog_service.dart';
import 'context.dart';
import 'customer_statement.dart';
import 'labour_service.dart';
import 'expense_service.dart';
import 'inspection_service.dart';
import 'integrity_service.dart';
import 'inventory_engine.dart';
import 'party_service.dart';
import 'purchase_service.dart';
import 'quotation_service.dart';
import 'report_service.dart';
import 'sales_service.dart';
import 'serial_service.dart';
import 'settings_service.dart';
import 'technician_service.dart';
import 'warranty_repair_service.dart';

/// Composition root: builds every service on top of one store.
class AppServices {
  final ServiceContext ctx;
  late final AuthService auth = AuthService(ctx, hasher: _hasher);
  late final InventoryEngine inventory = InventoryEngine(ctx);
  late final SerialService serials = SerialService(ctx);
  late final CatalogService catalog = CatalogService(ctx, inventory);
  late final PartyService parties = PartyService(ctx);
  late final LabourService labour = LabourService(ctx);
  late final CustomerStatementService customerStatements = CustomerStatementService(ctx, parties);
  late final PurchaseService purchases = PurchaseService(ctx, inventory, parties, serials);
  late final InspectionService inspections = InspectionService(ctx, inventory, serials);
  late final SalesService sales = SalesService(ctx, inventory, parties, serials, inspections);
  late final TechnicianService technicians = TechnicianService(ctx, inventory, serials, auth, inspections);
  late final QuotationService quotations = QuotationService(ctx, sales);
  late final WarrantyService warranty = WarrantyService(ctx, inventory, serials);
  late final RepairService repairs = RepairService(ctx, inventory, parties, serials);
  late final ReportService reports = ReportService(ctx, inventory, parties);
  late final IntegrityService integrity = IntegrityService(ctx);
  late final SettingsService settings = SettingsService(ctx);
  late final ExpenseService expenses = ExpenseService(ctx);
  late final PermanentDeleteService erase = PermanentDeleteService(ctx);
  final BackupService backup;

  /// Folder inside the app data folder where product photos and the shop
  /// logo are kept (copied there, so they survive the original file being
  /// moved and are included in backups).
  final String mediaDir;

  final PasswordHasher? _hasher;
  AppServices._(this.ctx, this.backup, this._hasher, this.mediaDir);

  /// Copies an image chosen by the user into [mediaDir]/[folder] and returns
  /// the new path (the original file is not touched).
  Future<String> importMedia(String sourcePath, {required String folder, bool allowPdf = false}) async {
    final src = File(sourcePath);
    if (!await src.exists()) throw const ValidationException('The chosen file no longer exists.');
    final ext = p.extension(sourcePath).toLowerCase();
    if (!['.png', '.jpg', '.jpeg', '.webp', '.bmp', if (allowPdf) '.pdf'].contains(ext)) {
      throw ValidationException(allowPdf ? 'Choose a PDF or an image (PNG, JPG, WEBP, BMP).' : 'Choose a PNG, JPG, WEBP or BMP image.');
    }
    if (await src.length() > 15 * 1024 * 1024) throw const ValidationException('The image is larger than 15 MB.');
    final dir = Directory(p.join(mediaDir, folder));
    await dir.create(recursive: true);
    final dest = p.join(dir.path, '${newId()}$ext');
    await src.copy(dest);
    return dest;
  }

  /// Decodes the data the Dashboard and the main screens read, so the first
  /// screen opens without a pause. Called while the splash screen shows;
  /// yields between steps so the splash keeps animating. Read-only.
  Future<void> warmUp() async {
    final steps = <void Function()>[
      () => catalog.products(),
      () => catalog.search(''),
      () => sales.list(),
      () => purchases.list(),
      () => reports.stock(),
      () => parties.list(PartyKind.customer),
      () => parties.list(PartyKind.supplier),
      () => parties.payments(),
      () => parties.entries(PartyKind.customer, ''),
      () => sales.returns(),
      () => purchases.returns(),
      () => repairs.list(openOnly: true),
      () => warranty.claims(),
      () => warranty.expiringWithin(30),
      () => inspections.list(),
      () => technicians.holdings(),
      () => inventory.openLayers(ctx.uow(), ''),
    ];
    for (final s in steps) {
      s();
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Creates ONE product and receives its first stock (with one serial per
  /// unit for serial-tracked products) as a purchase from [supplierId], in a
  /// single atomic save: either both are saved or nothing is.
  Future<(Product, Purchase)> createProductWithStock(
    ProductInput input, {
    bool allowDuplicate = false,
    required String supplierId,
    required Qty qty,
    required Money unitCost,
    List<String> serials = const [],
    String supplierInvoiceNo = '',
    DateTime? date,
    Money paid = const Money.zero(),
    PaymentMethod method = PaymentMethod.cash,
    Set<String> approvedSerialConflicts = const {},
  }) async {
    if (!qty.isPositive) throw const ValidationException('Quantity received must be more than zero.');
    final uow = ctx.uow();
    final p = catalog.stageNew(uow, input, allowDuplicate: allowDuplicate);
    final pur = purchases.stage(uow,
        supplierId: supplierId,
        supplierInvoiceNo: supplierInvoiceNo,
        date: date ?? ctx.now(),
        lines: [PurchaseLineInput(productId: p.id, qty: qty, unitCost: unitCost, serials: serials)],
        paid: paid,
        method: method,
        notes: 'Opening stock for new product',
        approvedSerialConflicts: approvedSerialConflicts);
    await uow.commit();
    return (catalog.byId(p.id)!, pur);
  }

  factory AppServices(
    DataStore store, {
    required String localBackupDir,
    String? mediaDir,
    String? defaultBackupDir,
    DateTime Function()? clock,
    PasswordHasher? hasher,
  }) {
    final ctx = ServiceContext(store: store, clock: clock);
    final media = mediaDir ?? p.join(p.dirname(localBackupDir), 'media');
    return AppServices._(ctx, BackupService(ctx, localBackupDir: localBackupDir, mediaDir: media, defaultBackupDir: defaultBackupDir), hasher, media);
  }
}
