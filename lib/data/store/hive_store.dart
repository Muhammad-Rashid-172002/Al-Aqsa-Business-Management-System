import 'dart:async';
import 'dart:convert';

import 'package:hive_ce/hive.dart';

import 'data_store.dart';

/// Hive CE implementation.
///
/// Atomicity: Hive has no multi-box transactions, so every commit is written
/// first to a `journal` box (write-ahead log) and flushed to disk. Only then
/// are the ops applied to their boxes. After all boxes are flushed the journal
/// entry is removed. If the app is closed or crashes mid-way, [open] replays
/// any journal entries left behind. Replays are idempotent (plain put/delete),
/// so a business operation is either fully applied or fully re-applied.
class HiveStore implements DataStore {
  static const _journal = '_journal';
  final Map<String, Box<Map>> _boxes = {};
  late Box<Map> _journalBox;
  final _changes = StreamController<Set<String>>.broadcast();
  final Map<String, int> _revisions = {};
  Future<void> _queue = Future.value();

  HiveStore._();

  /// Opens every box. [onSettings] is called with the stored app settings
  /// (or null) as soon as the small settings box is open, before the large
  /// boxes, so the window can show the splash in the right theme.
  static Future<HiveStore> open(String directory, {void Function(Json? appSettings)? onSettings}) async {
    Hive.init(directory);
    final s = HiveStore._();
    s._journalBox = await Hive.openBox<Map>(_journal);
    s._boxes[Boxes.settings] = await Hive.openBox<Map>(Boxes.settings);
    onSettings?.call(s.read(Boxes.settings, 'app'));
    for (final name in Boxes.all) {
      s._boxes[name] ??= await Hive.openBox<Map>(name);
    }
    await s._recover();
    return s;
  }

  int recoveredTransactions = 0;

  Future<void> _recover() async {
    if (_journalBox.isEmpty) return;
    final keys = _journalBox.keys.toList()..sort((a, b) => a.toString().compareTo(b.toString()));
    for (final k in keys) {
      final entry = _journalBox.get(k);
      if (entry == null) continue;
      final ops = (entry['ops'] as List).map((e) => WriteOp.fromJson(e as Map)).toList();
      await _apply(ops);
      await _journalBox.delete(k);
      recoveredTransactions++;
    }
    await _journalBox.flush();
  }

  Box<Map> _box(String name) {
    final b = _boxes[name];
    if (b == null) throw StateError('Unknown box $name');
    return b;
  }

  @override
  Json? read(String box, String key) {
    final v = _box(box).get(key);
    return v == null ? null : deepJson(v);
  }

  @override
  Iterable<Json> values(String box) => _box(box).values.map(deepJson);

  @override
  Iterable<String> keys(String box) => _box(box).keys.map((k) => k.toString());

  @override
  int count(String box) => _box(box).length;

  @override
  Map<String, String Function()> jsonSnapshot(String box) {
    // Hive replaces a record's map on put and never changes it in place, so
    // holding the current maps is a consistent snapshot.
    final m = _box(box).toMap();
    return {for (final e in m.entries) e.key.toString(): () => jsonEncode(e.value)};
  }

  @override
  int revision(String box) => _revisions[box] ?? 0;

  void _bump(String box) => _revisions[box] = (_revisions[box] ?? 0) + 1;

  @override
  Future<void> commit(List<WriteOp> ops) {
    // Serialize commits so journal order equals apply order.
    final next = _queue.then((_) => _commitNow(ops));
    _queue = next.catchError((_) {});
    return next;
  }

  Future<void> _commitNow(List<WriteOp> ops) async {
    final txKey = DateTime.now().microsecondsSinceEpoch.toString().padLeft(20, '0');
    await _journalBox.put(txKey, {'ops': ops.map((o) => o.toJson()).toList()});
    await _journalBox.flush();
    await _apply(ops);
    await _journalBox.delete(txKey);
    _changes.add(ops.map((o) => o.box).toSet());
  }

  Future<void> _apply(List<WriteOp> ops) async {
    final touched = <String>{};
    for (final op in ops) {
      final b = _box(op.box);
      // Bumped before and after every write and after the flush below, so a
      // cache built while a commit is in progress is never reused.
      _bump(op.box);
      if (op.value == null) {
        await b.delete(op.key);
      } else {
        await b.put(op.key, op.value!);
      }
      _bump(op.box);
      touched.add(op.box);
    }
    for (final t in touched) {
      await _box(t).flush();
    }
    touched.forEach(_bump);
  }

  @override
  Future<void> clearAll() async {
    for (final b in _boxes.values) {
      await b.clear();
      await b.flush();
    }
    Boxes.all.forEach(_bump);
    _changes.add(Boxes.all.toSet());
  }

  Future<void> close() async {
    await _queue;
    await Hive.close();
  }

  @override
  Stream<Set<String>> get changes => _changes.stream;
}
