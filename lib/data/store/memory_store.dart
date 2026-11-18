import 'dart:async';
import 'dart:convert';

import 'data_store.dart';

/// In-memory store used by tests. Values are deep-copied via JSON so callers
/// can never mutate stored data by accident (same behaviour as Hive).
class MemoryStore implements DataStore {
  final Map<String, Map<String, String>> _boxes = {};
  final _changes = StreamController<Set<String>>.broadcast();
  final Map<String, int> _revisions = {};

  @override
  Map<String, String Function()> jsonSnapshot(String box) => {for (final e in (_boxes[box] ?? const <String, String>{}).entries) e.key: () => e.value};

  @override
  int revision(String box) => _revisions[box] ?? 0;
  void _bump(String box) => _revisions[box] = (_revisions[box] ?? 0) + 1;

  @override
  Json? read(String box, String key) {
    final s = _boxes[box]?[key];
    return s == null ? null : jsonDecode(s) as Json;
  }

  @override
  Iterable<Json> values(String box) =>
      (_boxes[box]?.values ?? const <String>[]).map((s) => jsonDecode(s) as Json);

  @override
  Iterable<String> keys(String box) => _boxes[box]?.keys.toList() ?? const [];

  @override
  int count(String box) => _boxes[box]?.length ?? 0;

  @override
  Future<void> commit(List<WriteOp> ops) async {
    // Validate encoding of all ops first so a bad value aborts everything.
    final encoded = ops.map((o) => o.value == null ? null : jsonEncode(o.value)).toList();
    for (var i = 0; i < ops.length; i++) {
      final b = _boxes.putIfAbsent(ops[i].box, () => {});
      _bump(ops[i].box);
      if (encoded[i] == null) {
        b.remove(ops[i].key);
      } else {
        b[ops[i].key] = encoded[i]!;
      }
    }
    _changes.add(ops.map((o) => o.box).toSet());
  }

  @override
  Future<void> clearAll() async {
    _boxes.clear();
    Boxes.all.forEach(_bump);
    _changes.add(Boxes.all.toSet());
  }

  @override
  Stream<Set<String>> get changes => _changes.stream;
}
