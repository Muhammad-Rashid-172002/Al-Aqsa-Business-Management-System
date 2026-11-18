import '../../core/errors.dart';
import '../../data/store/data_store.dart';
import '../models/operations.dart';
import '../models/user.dart';
import 'context.dart';

class SettingsService {
  final ServiceContext ctx;
  SettingsService(this.ctx);

  AppSettings get current => ctx.settings;

  /// The business name shipped by earlier versions; shops that never changed
  /// it get the official name on invoices and reports.
  static const previousDefaultName = 'AL AQSA CCTV';

  /// Called at start-up. Changes nothing when the owner typed their own name.
  Future<bool> applyOfficialName() async {
    final j = ctx.store.read(Boxes.settings, 'app');
    if (j == null || j['businessName'] != previousDefaultName) return false;
    final uow = ctx.uow()..put(Boxes.settings, 'app', {...j, 'businessName': const AppSettings().businessName});
    ctx.audit(uow, 'update', 'settings', 'app', 'business name updated to the official name');
    await uow.commit();
    return true;
  }

  Future<AppSettings> save(Map<String, dynamic> changes) async {
    ctx.require(Permission.manageSettings);
    final next = current.merge(changes);
    if (next.businessName.trim().isEmpty) throw const ValidationException('Business name is required.');
    for (final p in [next.invoicePrefix, next.quotationPrefix, next.purchasePrefix, next.repairPrefix]) {
      if (!RegExp(r'^[A-Za-z0-9]{1,8}$').hasMatch(p)) throw const ValidationException('Prefixes must be 1-8 letters or digits.');
    }
    if (next.labelWidthMm < 20 || next.labelWidthMm > 150 || next.labelHeightMm < 10 || next.labelHeightMm > 100) {
      throw const ValidationException('Label size must be 20-150 mm wide and 10-100 mm high.');
    }
    if (next.backupHour < 0 || next.backupHour > 23 || next.backupMinute < 0 || next.backupMinute > 59) {
      throw const ValidationException('Backup time must be between 00:00 and 23:59.');
    }
    if (next.scannerKeyGapMs < 10 || next.scannerKeyGapMs > 200) throw const ValidationException('Scanner key speed must be 10-200 ms.');
    if (next.scannerMinLength < 1 || next.scannerMinLength > 20) throw const ValidationException('Scanner minimum code length must be 1-20.');
    if (next.scannerDuplicateMs < 0 || next.scannerDuplicateMs > 5000) throw const ValidationException('Duplicate-scan time must be 0-5000 ms.');
    if (next.backupKeep < 3) throw const ValidationException('Keep at least 3 automatic backups.');
    if (next.quotationValidityDays < 1) throw const ValidationException('Quotation validity must be at least 1 day.');
    final w = ctx.uow()..put(Boxes.settings, 'app', next.toJson());
    ctx.audit(w, 'update', 'settings', 'app', changes.keys.join(', '));
    await w.commit();
    return next;
  }

  /// Theme is a personal display preference; any logged-in user may change it.
  Future<void> setTheme(String theme) async {
    final next = current.merge({'theme': theme});
    await ctx.store.commit([WriteOp(Boxes.settings, 'app', next.toJson())]);
  }
}
