import 'store/data_store.dart';

/// Database schema versioning. Each migration transforms the full data set
/// (box -> key -> record). Migrations run on app start and on restored
/// backups, so a backup from an older version can be restored safely.
class Migrator {
  static const currentSchema = 2;

  /// Ordered migrations: key is the target version.
  static final Map<int, void Function(Map<String, Map<String, Json>> data)> _steps = {
    2: _toV2,
  };

  /// v2: decimal quantities (stored as thousandths) and brand-aware serial keys.
  static void _toV2(Map<String, Map<String, Json>> data) {
    int k1000(Object? v) => ((v as num?)?.toInt() ?? 0) * 1000;
    void scale(Json r, List<String> fields) {
      for (final f in fields) {
        if (r.containsKey(f)) r[f] = k1000(r[f]);
      }
    }

    void scaleList(Json r, String listField, List<String> fields) {
      for (final it in (r[listField] as List? ?? const [])) {
        scale(it as Json, fields);
      }
    }

    data[Boxes.products]?.values.forEach((r) => scale(r, ['stockQty', 'issuedQty', 'damagedQty', 'minStock']));
    data[Boxes.costLayers]?.values.forEach((r) => scale(r, ['qtyIn', 'qtyRemaining']));
    data[Boxes.stockMovements]?.values.forEach((r) => scale(r, ['qty', 'before', 'after']));
    data[Boxes.purchases]?.values.forEach((r) => scaleList(r, 'items', ['qty', 'returnedQty']));
    data[Boxes.sales]?.values.forEach((r) => scaleList(r, 'items', ['qty', 'returnedQty']));
    data[Boxes.salesReturns]?.values.forEach((r) => scaleList(r, 'lines', ['qty']));
    data[Boxes.purchaseReturns]?.values.forEach((r) => scaleList(r, 'lines', ['qty']));
    data[Boxes.quotations]?.values.forEach((r) => scaleList(r, 'items', ['qty']));
    data[Boxes.techTxns]?.values.forEach((r) => scale(r, ['qty', 'invoicedQty']));
    data[Boxes.techHoldings]?.values.forEach((r) => scale(r, ['qty']));
    data[Boxes.repairs]?.values.forEach((r) => scaleList(r, 'parts', ['qty']));

    // Serial records: key "BRAND|SERIAL" + index.
    String brandOf(String? productId) {
      final b = (data[Boxes.products]?[productId]?['brand'] as String? ?? '').trim().toUpperCase().replaceAll(RegExp(r'\s+'), '').replaceAll('|', '');
      return b.isEmpty ? 'GENERIC' : b;
    }

    final oldSerials = data[Boxes.serials] ?? {};
    final newSerials = <String, Json>{};
    final index = <String, Json>{};
    final keyOf = <String, String>{}; // old serial -> new key
    oldSerials.forEach((oldKey, r) {
      final serial = (r['serial'] as String?) ?? oldKey;
      final brand = brandOf(r['productId'] as String?);
      final key = '$brand|$serial';
      r['key'] = key;
      r['serial'] = serial;
      r['brandKey'] = brand;
      newSerials[key] = r;
      keyOf[serial] = key;
      ((index[serial] ??= {'keys': <String>[]})['keys'] as List).add(key);
    });
    data[Boxes.serials] = newSerials;
    data[Boxes.serialIndex] = index;
    List<String> mapKeys(Object? l) => (l as List? ?? const []).map((e) => keyOf[e.toString()] ?? e.toString()).toList();
    for (final box in [Boxes.purchases, Boxes.sales]) {
      data[box]?.values.forEach((r) {
        for (final it in (r['items'] as List? ?? const [])) {
          (it as Json)['serials'] = mapKeys(it['serials']);
        }
      });
    }
    for (final box in [Boxes.salesReturns, Boxes.purchaseReturns]) {
      data[box]?.values.forEach((r) {
        for (final it in (r['lines'] as List? ?? const [])) {
          (it as Json)['serials'] = mapKeys(it['serials']);
        }
      });
    }
    data[Boxes.techTxns]?.values.forEach((r) => r['serials'] = mapKeys(r['serials']));
    data[Boxes.warrantyClaims]?.values.forEach((r) {
      r['serial'] = keyOf[r['serial']] ?? r['serial'];
      if (r['replacementSerial'] != null) r['replacementSerial'] = keyOf[r['replacementSerial']] ?? r['replacementSerial'];
    });
  }

  static int schemaOf(DataStore store) => (store.read(Boxes.meta, 'schema')?['version'] as num?)?.toInt() ?? 0;

  /// Migrates an exported data set in memory.
  static Map<String, Map<String, Json>> migrateData(Map<String, Map<String, Json>> data, int fromVersion) {
    if (fromVersion > currentSchema) {
      throw StateError('This backup was made by a newer version of the app (schema $fromVersion). Please update the app first.');
    }
    for (var v = fromVersion + 1; v <= currentSchema; v++) {
      _steps[v]?.call(data);
    }
    (data[Boxes.meta] ??= {})['schema'] = {'version': currentSchema};
    return data;
  }

  /// Migrates the live store if needed.
  static Future<void> run(DataStore store) async {
    final from = schemaOf(store);
    if (from == currentSchema) return;
    if (from == 0 && store.count(Boxes.users) == 0) {
      await store.commit([WriteOp(Boxes.meta, 'schema', {'version': currentSchema})]);
      return;
    }
    final data = exportAll(store);
    migrateData(data, from);
    await replaceAll(store, data);
  }

  static Map<String, Map<String, Json>> exportAll(DataStore store) => {
        for (final box in Boxes.all)
          box: {for (final k in store.keys(box)) k: store.read(box, k)!},
      };

  /// Replaces all data in one atomic commit (deletes + puts).
  static Future<void> replaceAll(DataStore store, Map<String, Map<String, Json>> data) async {
    final ops = <WriteOp>[];
    for (final box in Boxes.all) {
      final incoming = data[box] ?? const {};
      for (final k in store.keys(box)) {
        if (!incoming.containsKey(k)) ops.add(WriteOp(box, k, null));
      }
      incoming.forEach((k, v) => ops.add(WriteOp(box, k, v)));
    }
    await store.commit(ops);
  }
}
