typedef Json = Map<String, dynamic>;

/// Box (table) names. Each entity lives in its own box.
abstract final class Boxes {
  static const users = 'users';
  static const loginHistory = 'login_history';
  static const employees = 'employees';
  static const categories = 'categories';
  static const brands = 'brands';
  static const products = 'products';
  static const barcodes = 'barcodes'; // code -> productId (unique index)
  static const serials = 'serials'; // key = BRAND|SERIAL (unique)
  static const serialIndex = 'serial_index'; // serial -> {keys: [...]}
  static const inspections = 'inspections';
  static const costLayers = 'cost_layers';
  static const stockMovements = 'stock_movements';
  static const suppliers = 'suppliers';
  static const customers = 'customers';
  static const purchases = 'purchases';
  static const purchaseReturns = 'purchase_returns';
  static const sales = 'sales';
  static const salesReturns = 'sales_returns';
  static const payments = 'payments';
  static const ledger = 'ledger';
  static const techTxns = 'technician_txns';
  static const techHoldings = 'technician_holdings';
  static const quotations = 'quotations';
  static const warrantyClaims = 'warranty_claims';
  static const repairs = 'repairs';
  static const auditLogs = 'audit_logs';
  static const settings = 'settings';
  static const meta = 'meta'; // counters, schema version
  static const errorLog = 'error_log';
  static const expenses = 'expenses'; // shop running costs

  static const all = [
    users, loginHistory, employees, categories, brands, products, barcodes,
    serials, serialIndex, inspections, costLayers, stockMovements, suppliers, customers, purchases,
    purchaseReturns, sales, salesReturns, payments, ledger, techTxns,
    techHoldings, quotations, warrantyClaims, repairs, expenses, auditLogs, settings,
    meta, errorLog,
  ];
}

class WriteOp {
  final String box;
  final String key;
  final Json? value; // null = delete
  const WriteOp(this.box, this.key, this.value);

  Json toJson() => {'b': box, 'k': key, 'v': value};
  static WriteOp fromJson(Map m) =>
      WriteOp(m['b'] as String, m['k'] as String, m['v'] == null ? null : deepJson(m['v'] as Map));
}

/// Converts Hive's `Map<dynamic, dynamic>` trees into [Json] trees.
Json deepJson(Map m) => m.map((k, v) => MapEntry(k.toString(), _deep(v)));
Object? _deep(Object? v) {
  if (v is Map) return deepJson(v);
  if (v is List) return v.map(_deep).toList();
  return v;
}

/// Storage abstraction. Reads are synchronous (boxes are held in memory);
/// writes go through [commit], which must apply all ops atomically.
abstract class DataStore {
  Json? read(String box, String key);
  Iterable<Json> values(String box);
  Iterable<String> keys(String box);
  int count(String box);

  /// Change counter of [box]. It increases whenever a commit (or
  /// [clearAll]) changes the box, synchronously, before the commit completes.
  /// Read caches use it to know when decoded data is stale.
  int revision(String box);

  /// Consistent point-in-time copy of [box] for backups: key -> function that
  /// returns the record as JSON text. Taking it is cheap (no decoding) and
  /// later commits do not change it, so the JSON can be produced gradually.
  Map<String, String Function()> jsonSnapshot(String box);

  Future<void> commit(List<WriteOp> ops);
  Future<void> clearAll();

  /// Stream of box names changed by a commit (for UI refresh).
  Stream<Set<String>> get changes;
}

/// Collects writes for one business operation. Reads see pending writes.
class UnitOfWork {
  final DataStore store;
  final Map<String, Map<String, Json?>> _pending = {};
  UnitOfWork(this.store);

  Json? read(String box, String key) {
    final p = _pending[box];
    if (p != null && p.containsKey(key)) return p[key];
    return store.read(box, key);
  }

  /// All values of a box including pending changes.
  List<Json> values(String box) {
    final p = _pending[box];
    if (p == null) return store.values(box).toList();
    final out = <String, Json>{};
    for (final k in store.keys(box)) {
      final v = store.read(box, k);
      if (v != null) out[k] = v;
    }
    p.forEach((k, v) => v == null ? out.remove(k) : out[k] = v);
    return out.values.toList();
  }

  /// Pending (uncommitted) writes for [box]: key -> value, null = delete.
  Map<String, Json?> pendingOf(String box) => _pending[box] ?? const {};

  void put(String box, String key, Json value) => (_pending[box] ??= {})[key] = value;
  void delete(String box, String key) => (_pending[box] ??= {})[key] = null;

  bool get isEmpty => _pending.isEmpty;

  Future<void> commit() async {
    final ops = <WriteOp>[];
    _pending.forEach((box, m) => m.forEach((k, v) => ops.add(WriteOp(box, k, v))));
    if (ops.isEmpty) return;
    await store.commit(ops);
    _pending.clear();
  }
}
