import '../../core/errors.dart';
import '../../core/ids.dart';
import '../../data/store/data_store.dart';
import '../models/operations.dart';
import '../models/user.dart';

/// Holds the logged-in user for this app session.
class Session {
  AppUser? _user;
  AppUser? get user => _user;
  bool get isLoggedIn => _user != null;
  void start(AppUser u) => _user = u;
  void end() => _user = null;

  AppUser get requireUser {
    final u = _user;
    if (u == null) throw const PermissionException('Please log in first.');
    return u;
  }
}

/// Shared dependencies for all services.
class ServiceContext {
  final DataStore store;
  final Session session;
  final DateTime Function() clock;

  ServiceContext({required this.store, Session? session, DateTime Function()? clock})
      : session = session ?? Session(),
        clock = clock ?? DateTime.now;

  DateTime now() => clock();
  UnitOfWork uow() => UnitOfWork(store);

  String get userId => session.user?.id ?? 'system';

  void require(Permission p) {
    final u = session.requireUser;
    if (!u.active) throw const PermissionException('This account is deactivated.');
    if (!u.can(p)) throw const PermissionException();
  }

  bool can(Permission p) => session.user?.can(p) ?? false;

  AppSettings get settings => derived('settings', const [Boxes.settings], () {
        final j = store.read(Boxes.settings, 'app');
        return j == null ? const AppSettings() : AppSettings.fromJson(j);
      });

  // ── Read cache ────────────────────────────────────────────────────────
  // Decoding a box (Hive map -> JSON copy -> model) is the main cost of every
  // screen, report and search. Decoded lists are kept per box and reused
  // until the box's revision changes (any commit touching it), so data is
  // never stale: a commit bumps the revision synchronously before it
  // completes. Models are immutable; returned lists are unmodifiable.
  final Map<String, (Object, Object)> _cache = {};

  /// All records of [box], decoded with [decode] (cached until the box changes).
  List<T> all<T>(String box, T Function(Json) decode) {
    final rev = store.revision(box);
    final key = '$box#$T';
    final hit = _cache[key];
    if (hit != null && hit.$1 == rev) return hit.$2 as List<T>;
    final list = List<T>.unmodifiable(store.values(box).map(decode));
    _cache[key] = (rev, list);
    return list;
  }

  /// A value computed from [boxes], cached until any of them changes.
  /// [build] must only read data from [boxes].
  R derived<R extends Object>(String name, List<String> boxes, R Function() build) {
    final rev = [for (final b in boxes) store.revision(b)].join(',');
    final key = '~$name';
    final hit = _cache[key];
    if (hit != null && hit.$1 == rev) return hit.$2 as R;
    final v = build();
    _cache[key] = (rev, v);
    return v;
  }

  /// Drops all cached data (e.g. after a restore or for memory pressure).
  void clearCache() => _cache.clear();

  /// Next document number in a sequence, e.g. INV-000042. Counter is updated
  /// in the same unit of work as the document, so numbers are never reused.
  String nextNumber(UnitOfWork uow, String sequence, String prefix, {int pad = 6}) {
    final j = uow.read(Boxes.meta, 'seq_$sequence');
    final n = ((j?['value'] as num?)?.toInt() ?? 0) + 1;
    uow.put(Boxes.meta, 'seq_$sequence', {'value': n});
    return '$prefix-${n.toString().padLeft(pad, '0')}';
  }

  void audit(UnitOfWork uow, String action, String entity, String entityId, [String details = '']) {
    final log = AuditLog(id: newId(), at: now(), userId: userId, action: action, entity: entity, entityId: entityId, details: details);
    uow.put(Boxes.auditLogs, log.id, log.toJson());
  }

  Future<void> logError(Object error, StackTrace? st) async {
    final id = newId();
    await store.commit([
      WriteOp(Boxes.errorLog, id, {'id': id, 'at': now().toIso8601String(), 'error': error.toString(), 'stack': st?.toString() ?? ''}),
    ]);
  }
}
