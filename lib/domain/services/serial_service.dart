import '../../core/errors.dart';
import '../../core/ids.dart';
import '../../core/money.dart';
import '../../data/store/data_store.dart';
import '../models/product.dart';
import '../models/user.dart';
import 'context.dart';

enum SerialConflictKind {
  /// Same brand + same serial already registered and active.
  sameBrand,

  /// Same serial exists under a different brand (often legitimate).
  otherBrand,
}

class SerialConflict {
  final String serial;
  final SerialConflictKind kind;
  final SerialRecord existing;
  const SerialConflict(this.serial, this.kind, this.existing);
}

/// Thrown when new serials clash with existing ones. The owner can approve
/// the listed serials (see [SerialService.registerPurchased]).
class SerialConflictException extends DuplicateException {
  final List<SerialConflict> conflicts;
  SerialConflictException(this.conflicts) : super(_message(conflicts));

  static String _message(List<SerialConflict> c) {
    final first = c.first;
    final what = first.kind == SerialConflictKind.sameBrand
        ? 'is already registered for this brand (status: ${first.existing.status.label})'
        : 'already exists under brand ${first.existing.brandKey}';
    return 'Serial "${first.serial}" $what${c.length > 1 ? ' (+${c.length - 1} more)' : ''}. Owner approval is required.';
  }
}

/// Result of checking one entered serial before it is saved.
enum SerialIssue {
  /// Characters a printed serial does not contain (or too short / long).
  invalid,

  /// Entered twice in this list.
  repeated,

  /// Already registered for this brand (owner approval needed on save).
  alreadyRegistered,

  /// Exists under another brand (owner approval needed on save).
  otherBrand,

  /// Is a product barcode, not a device serial.
  productBarcode,
}

class SerialCheck {
  final String input;
  final String serial; // normalized
  final SerialIssue? issue;
  final String message;
  const SerialCheck(this.input, this.serial, this.issue, this.message);
  bool get ok => issue == null;

  /// Problems that must be fixed in the list (cannot be approved).
  bool get blocking => issue == SerialIssue.invalid || issue == SerialIssue.repeated || issue == SerialIssue.productBarcode;
}

/// Serial-number identity = brand + serial. Records are stored under
/// "BRAND|SERIAL"; an index maps each plain serial to all its record keys.
class SerialService {
  final ServiceContext ctx;
  SerialService(this.ctx);

  List<String> keysFor(UnitOfWork? uow, String serial) {
    final sn = normalizeCode(serial);
    if (sn.isEmpty || sn.length > 100) return const [];
    final j = uow != null ? uow.read(Boxes.serialIndex, sn) : ctx.store.read(Boxes.serialIndex, sn);
    return (j?['keys'] as List?)?.map((e) => e.toString()).toList() ?? const [];
  }

  SerialRecord? byKey(String key) {
    final j = ctx.store.read(Boxes.serials, key);
    return j == null ? null : SerialRecord.fromJson(j);
  }

  /// All records for a plain serial (several if different brands share it).
  List<SerialRecord> findAll(String serialOrKey) {
    if (SerialRecord.isKey(serialOrKey)) {
      final r = byKey(serialOrKey);
      return r == null ? const [] : [r];
    }
    return keysFor(null, serialOrKey).map(byKey).whereType<SerialRecord>().toList();
  }

  /// First match (most recent registration) for display lookups.
  SerialRecord? find(String serialOrKey) {
    final all = findAll(serialOrKey);
    return all.isEmpty ? null : all.last;
  }

  /// Resolves user input (plain serial or key) to the record of [productId].
  SerialRecord resolve(UnitOfWork uow, String input, String productId, {Set<SerialStatus>? preferStatus}) {
    if (SerialRecord.isKey(input)) {
      final j = uow.read(Boxes.serials, input);
      if (j == null) throw NotFoundException('Serial "${SerialRecord.displayOf(input)}" is not registered.');
      return SerialRecord.fromJson(j);
    }
    final candidates = keysFor(uow, input)
        .map((k) => uow.read(Boxes.serials, k))
        .whereType<Map<String, dynamic>>()
        .map(SerialRecord.fromJson)
        .where((r) => r.productId == productId)
        .toList();
    if (candidates.isEmpty) {
      final any = keysFor(uow, input).isNotEmpty;
      throw NotFoundException(any ? 'Serial "${normalizeCode(input)}" belongs to a different product.' : 'Serial "${normalizeCode(input)}" is not registered.');
    }
    if (candidates.length == 1) return candidates.first;
    if (preferStatus != null) {
      final pick = candidates.where((r) => preferStatus.contains(r.status)).toList();
      if (pick.length == 1) return pick.first;
    }
    throw BusinessException('Serial "${normalizeCode(input)}" has ${candidates.length} registered units of this product. Pick the exact unit from the list.');
  }

  void save(UnitOfWork uow, SerialRecord r) => uow.put(Boxes.serials, r.key, r.toJson());

  void _index(UnitOfWork uow, String serial, String key) {
    final j = uow.read(Boxes.serialIndex, serial);
    final keys = (j?['keys'] as List?)?.map((e) => e.toString()).toList() ?? <String>[];
    if (!keys.contains(key)) keys.add(key);
    uow.put(Boxes.serialIndex, serial, {'keys': keys});
  }

  void _unindex(UnitOfWork uow, String serial, String key) {
    final j = uow.read(Boxes.serialIndex, serial);
    final keys = (j?['keys'] as List?)?.map((e) => e.toString()).toList() ?? <String>[];
    keys.remove(key);
    if (keys.isEmpty) {
      uow.delete(Boxes.serialIndex, serial);
    } else {
      uow.put(Boxes.serialIndex, serial, {'keys': keys});
    }
  }

  /// Deletes a record (only used when cancelling a purchase).
  void remove(UnitOfWork uow, SerialRecord r) {
    uow.delete(Boxes.serials, r.key);
    _unindex(uow, r.serial, r.key);
  }

  /// Validates a list of serials typed/scanned for one line: no blanks, no
  /// duplicates within the list. Returns normalized serials (or keys).
  List<String> normalizeList(List<String> raw, {required int expectedQty, required String productName}) {
    final out = <String>[];
    for (final r in raw) {
      final n = SerialRecord.isKey(r) ? r.trim() : normalizeCode(r);
      if (n.isEmpty) continue;
      if (n.length > 120) throw ValidationException('Serial "$n" is too long (max 100 characters).');
      if (out.contains(n)) throw DuplicateException('Serial "${SerialRecord.displayOf(n)}" was entered twice for $productName.');
      out.add(n);
    }
    if (out.length != expectedQty) {
      throw ValidationException('$productName needs $expectedQty serial number(s); ${out.length} entered.');
    }
    return out;
  }

  /// Checks serials about to be bought for [product] against existing ones.
  List<SerialConflict> conflicts(UnitOfWork? uow, Product product, Iterable<String> serials) {
    final out = <SerialConflict>[];
    for (final raw in serials) {
      final sn = normalizeCode(raw);
      for (final k in keysFor(uow, sn)) {
        final j = uow != null ? uow.read(Boxes.serials, k) : ctx.store.read(Boxes.serials, k);
        if (j == null) continue;
        final r = SerialRecord.fromJson(j);
        if (r.brandKey == product.brandKey) {
          // A unit that went back to the supplier may come back: not a conflict.
          if (r.status == SerialStatus.returnedToSupplier && r.productId == product.id) continue;
          out.add(SerialConflict(sn, SerialConflictKind.sameBrand, r));
        } else {
          out.add(SerialConflict(sn, SerialConflictKind.otherBrand, r));
        }
      }
    }
    return out;
  }

  /// Registers new units bought from a supplier. Serials in [approved] were
  /// confirmed by the owner as genuine despite a conflict.
  void registerPurchased(
    UnitOfWork uow, {
    required List<String> serials,
    required Product product,
    required String supplierId,
    required String purchaseId,
    required String purchaseNumber,
    required DateTime date,
    required Money unitCost,
    Set<String> approved = const {},
    required List<String> outKeys,
  }) {
    final found = conflicts(uow, product, serials);
    final unapproved = found.where((c) => !approved.contains(c.serial)).toList();
    if (unapproved.isNotEmpty) throw SerialConflictException(unapproved);
    if (found.isNotEmpty) ctx.require(Permission.resolveSerialConflicts);

    for (final raw in serials) {
      final sn = normalizeCode(raw);
      if (sn.isEmpty) continue;
      if (uow.read(Boxes.barcodes, indexKey(sn)) != null) throw DuplicateException('"$sn" is already used as a product barcode.');
      final brand = product.brandKey;
      final baseKey = SerialRecord.keyFor(brand, sn);
      final existingJ = uow.read(Boxes.serials, baseKey);
      if (existingJ != null) {
        final ex = SerialRecord.fromJson(existingJ);
        if (ex.status == SerialStatus.returnedToSupplier && ex.productId == product.id) {
          save(uow, ex.repurchased(supplierId: supplierId, purchaseId: purchaseId, date: date, cost: unitCost, note: 'Re-purchased $purchaseNumber', userId: ctx.userId));
          outKeys.add(ex.key);
          continue;
        }
      }
      var n = 1;
      var key = baseKey;
      while (uow.read(Boxes.serials, key) != null) {
        n++;
        key = SerialRecord.keyFor(brand, sn, n);
      }
      final isApprovedDup = found.any((c) => c.serial == sn);
      final rec = SerialRecord(
        key: key,
        serial: sn,
        brandKey: brand,
        productId: product.id,
        supplierId: supplierId,
        purchaseId: purchaseId,
        purchaseDate: date,
        cost: unitCost,
        status: SerialStatus.inStock,
        duplicateApprovedBy: isApprovedDup ? ctx.userId : null,
      ).transition(SerialStatus.inStock,
          at: ctx.now(),
          note: 'Purchased $purchaseNumber${isApprovedDup ? ' (duplicate approved by owner)' : ''}',
          refType: 'purchase',
          refId: purchaseId,
          userId: ctx.userId);
      save(uow, rec);
      _index(uow, sn, key);
      outKeys.add(key);
      if (isApprovedDup) ctx.audit(uow, 'serial_duplicate_approved', 'serial', key, purchaseNumber);
    }
  }

  /// Splits scanned / pasted / imported text into entries: one per line, or
  /// separated by comma, semicolon or tab. Blank entries are dropped.
  static List<String> splitEntries(String text) =>
      text.split(RegExp(r'[\r\n,;\t]+')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

  static final _validSerial = RegExp(r'^[A-Z0-9][A-Z0-9\-_/.:#+]*$');

  /// Checks serials about to be registered for a product of [brandKey]
  /// (existing product: pass [productId] so a unit returned to the supplier
  /// can be bought again). Read-only; used for live feedback while typing.
  List<SerialCheck> checkNew(List<String> entries, {required String brandKey, String? productId}) {
    final seen = <String>{};
    final out = <SerialCheck>[];
    for (final raw in entries) {
      final sn = normalizeCode(raw);
      if (sn.length < 2 || sn.length > 100 || !_validSerial.hasMatch(sn)) {
        out.add(SerialCheck(raw, sn, SerialIssue.invalid,
            sn.length < 2 ? 'Too short' : (sn.length > 100 ? 'Too long (max 100 characters)' : 'Contains characters that are not allowed')));
        continue;
      }
      if (!seen.add(sn)) {
        out.add(SerialCheck(raw, sn, SerialIssue.repeated, 'Entered twice in this list'));
        continue;
      }
      if (ctx.store.read(Boxes.barcodes, indexKey(sn)) != null) {
        out.add(SerialCheck(raw, sn, SerialIssue.productBarcode, 'This is a product barcode, not a serial number'));
        continue;
      }
      SerialCheck? found;
      for (final k in keysFor(null, sn)) {
        final r = byKey(k);
        if (r == null) continue;
        if (r.brandKey == brandKey) {
          if (r.status == SerialStatus.returnedToSupplier && r.productId == productId) continue;
          found = SerialCheck(raw, sn, SerialIssue.alreadyRegistered, 'Already registered (${r.status.label})');
          break;
        }
        found ??= SerialCheck(raw, sn, SerialIssue.otherBrand, 'Exists under brand ${r.brandKey}');
      }
      out.add(found ?? SerialCheck(raw, sn, null, ''));
    }
    return out;
  }

  /// Units by status for every product (cached until serials change).
  Map<String, Map<SerialStatus, int>> statusCountsByProduct() => ctx.derived('serialCountsByProduct', const [Boxes.serials], () {
        final m = <String, Map<SerialStatus, int>>{};
        for (final r in ctx.all(Boxes.serials, SerialRecord.fromJson)) {
          final c = m[r.productId] ??= {};
          c[r.status] = (c[r.status] ?? 0) + 1;
        }
        return m;
      });

  /// Units of [productId] by status (each unit counted once).
  Map<SerialStatus, int> statusCounts(String productId) {
    final m = <SerialStatus, int>{};
    for (final r in ctx.all(Boxes.serials, SerialRecord.fromJson)) {
      if (r.productId == productId) m[r.status] = (m[r.status] ?? 0) + 1;
    }
    return m;
  }

  /// Resolves each input to a record of [productId] with an allowed status.
  List<SerialRecord> requireAll(UnitOfWork uow, List<String> inputs, String productId, Set<SerialStatus> allowed, String action) {
    final seen = <String>{};
    return inputs.map((input) {
      final r = resolve(uow, input, productId, preferStatus: allowed);
      if (r.productId != productId) throw ValidationException('Serial "${r.display}" belongs to a different product.');
      if (!allowed.contains(r.status)) {
        throw BusinessException('Serial "${r.display}" cannot be used for $action (current status: ${r.status.label}).');
      }
      if (!seen.add(r.key)) throw DuplicateException('Serial "${r.display}" was entered twice.');
      return r;
    }).toList();
  }

  List<SerialRecord> search({String query = '', String? productId, SerialStatus? status, String? customerId, String? technicianId}) {
    final q = normalizeCode(query);
    return ctx.all(Boxes.serials, SerialRecord.fromJson).where((r) {
      if (q.isNotEmpty && !r.serial.contains(q)) return false;
      if (productId != null && r.productId != productId) return false;
      if (status != null && r.status != status) return false;
      if (customerId != null && r.customerId != customerId) return false;
      if (technicianId != null && r.technicianId != technicianId) return false;
      return true;
    }).toList()
      ..sort((a, b) => a.serial.compareTo(b.serial));
  }

  List<SerialRecord> inStockFor(String productId) => search(productId: productId, status: SerialStatus.inStock);

  /// Serials registered more than once (same serial, any brand) for review.
  List<List<SerialRecord>> duplicates() {
    final out = <List<SerialRecord>>[];
    for (final k in ctx.store.keys(Boxes.serialIndex)) {
      final recs = findAll(k);
      if (recs.length > 1) out.add(recs);
    }
    return out;
  }
}
