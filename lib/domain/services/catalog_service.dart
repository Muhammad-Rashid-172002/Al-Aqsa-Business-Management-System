import '../../core/errors.dart';
import '../../core/ids.dart';
import '../../core/money.dart';
import '../../core/qty.dart';
import '../../data/store/data_store.dart';
import '../models/documents.dart';
import '../models/product.dart';
import '../models/user.dart';
import 'context.dart';
import 'inventory_engine.dart';

/// Result of a scanner/search lookup.
class ScanResult {
  final Product product;
  final SerialRecord? serial; // set when a unit serial number was scanned
  final List<SerialRecord> otherMatches; // same serial under other brands/units
  const ScanResult(this.product, [this.serial, this.otherMatches = const []]);
}

class ProductInput {
  final String name;
  final String sku;
  final String? categoryId;
  final String brand;
  final String model;
  final String description;
  final Money purchasePrice;
  final Money sellingPrice;
  final Money? wholesalePrice;
  final Qty minStock;
  final String unit;
  final bool allowDecimal;
  final List<String> companyBarcodes;
  final bool requiresSerial;
  final int warrantyMonths;
  final String? imagePath;

  const ProductInput({
    required this.name,
    this.sku = '',
    this.categoryId,
    this.brand = '',
    this.model = '',
    this.description = '',
    required this.purchasePrice,
    required this.sellingPrice,
    this.wholesalePrice,
    this.minStock = const Qty.zero(),
    this.unit = 'pcs',
    this.allowDecimal = false,
    this.companyBarcodes = const [],
    this.requiresSerial = false,
    this.warrantyMonths = 0,
    this.imagePath,
  });
}

class CatalogService {
  final ServiceContext ctx;
  final InventoryEngine inv;
  CatalogService(this.ctx, this.inv);

  // ───────── Categories & brands ─────────

  List<ProductCategory> categories() =>
      ctx.all(Boxes.categories, ProductCategory.fromJson).toList()..sort((a, b) => a.name.compareTo(b.name));

  Future<ProductCategory> saveCategory(String name, {String? id}) async {
    ctx.require(Permission.manageProducts);
    final n = name.trim();
    if (n.isEmpty) throw const ValidationException('Category name is required.');
    if (categories().any((c) => c.name.toLowerCase() == n.toLowerCase() && c.id != id)) {
      throw DuplicateException('Category "$n" already exists.');
    }
    final c = ProductCategory(id: id ?? newId(), name: n);
    final w = ctx.uow()..put(Boxes.categories, c.id, c.toJson());
    ctx.audit(w, id == null ? 'create' : 'update', 'category', c.id, n);
    await w.commit();
    return c;
  }

  Future<void> deleteCategory(String id) async {
    ctx.require(Permission.manageProducts);
    if (products(includeArchived: true).any((p) => p.categoryId == id)) {
      throw const BusinessException('This category has products. Move them to another category first.');
    }
    final w = ctx.uow()..delete(Boxes.categories, id);
    ctx.audit(w, 'delete', 'category', id);
    await w.commit();
  }

  List<String> brands() {
    final set = <String>{for (final p in products(includeArchived: true)) if (p.brand.isNotEmpty) p.brand};
    return set.toList()..sort();
  }

  // ───────── Products ─────────

  /// Every product sorted by name, with its lower-cased search text
  /// (cached until products change).
  List<(Product, String)> _sorted() => ctx.derived('productsSorted', const [Boxes.products], () {
        final list = ctx.all(Boxes.products, Product.fromJson).map((p) => (p, p.name.toLowerCase())).toList()
          ..sort((a, b) => a.$2.compareTo(b.$2));
        return List<(Product, String)>.unmodifiable(list);
      });

  List<Product> products({bool includeArchived = false}) => [
        for (final (p, _) in _sorted())
          if (includeArchived || !p.archived) p,
      ];

  /// SKU (upper case) -> first product with it, in name order.
  Map<String, Product> _bySku() => ctx.derived('productsBySku', const [Boxes.products], () {
        final m = <String, Product>{};
        for (final (p, _) in _sorted()) {
          m.putIfAbsent(p.sku.toUpperCase(), () => p);
        }
        return m;
      });

  /// Lower-cased name/SKU/model/brand/barcodes of each product, in name order.
  List<(Product, String, String, String, String, List<String>)> _searchIndex() =>
      ctx.derived('productsSearch', const [Boxes.products], () => List.unmodifiable([
            for (final (p, name) in _sorted())
              (p, name, p.sku.toLowerCase(), p.model.toLowerCase(), p.brand.toLowerCase(), [for (final c in p.barcodes) c.toLowerCase()]),
          ]));

  Product? byId(String id) {
    final j = ctx.store.read(Boxes.products, id);
    return j == null ? null : Product.fromJson(j);
  }

  List<Product> search(String query, {String? categoryId, String? brand, bool includeArchived = false}) {
    final q = query.trim().toLowerCase();
    return [
      for (final (p, name, sku, model, br, codes) in _searchIndex())
        if ((includeArchived || !p.archived) &&
            (categoryId == null || p.categoryId == categoryId) &&
            (brand == null || brand.isEmpty || p.brand == brand) &&
            (q.isEmpty || name.contains(q) || sku.contains(q) || model.contains(q) || br.contains(q) || codes.any((c) => c.contains(q))))
          p,
    ];
  }

  /// Possible duplicates: same name+model+brand, or same SKU.
  List<Product> findDuplicates(ProductInput input, {String? excludeId}) {
    final name = input.name.trim().toLowerCase();
    final sku = input.sku.trim().toLowerCase();
    return products(includeArchived: true).where((p) {
      if (p.id == excludeId) return false;
      if (sku.isNotEmpty && p.sku.toLowerCase() == sku) return true;
      return p.name.toLowerCase() == name &&
          p.model.toLowerCase() == input.model.trim().toLowerCase() &&
          p.brand.toLowerCase() == input.brand.trim().toLowerCase();
    }).toList();
  }

  String _nextInternalCode(UnitOfWork uow) {
    final number = ctx.nextNumber(uow, 'product_code', 'AQ', pad: 8);
    return number.replaceAll('-', '');
  }

  void _validate(ProductInput input) {
    if (input.name.trim().isEmpty) throw const ValidationException('Product name is required.');
    if (input.purchasePrice.isNegative || input.sellingPrice.isNegative) {
      throw const ValidationException('Prices cannot be negative.');
    }
    if (input.minStock.isNegative) throw const ValidationException('Minimum stock cannot be negative.');
    if (input.requiresSerial && input.allowDecimal) throw const ValidationException('Serial-tracked products cannot use decimal quantities.');
    if (input.warrantyMonths < 0) throw const ValidationException('Warranty cannot be negative.');
  }

  void _indexCodes(UnitOfWork uow, String productId, List<String> codes, {List<String> previous = const []}) {
    for (final old in previous) {
      if (!codes.contains(old)) uow.delete(Boxes.barcodes, indexKey(old));
    }
    for (final c in codes) {
      final existing = uow.read(Boxes.barcodes, indexKey(c));
      if (existing != null && existing['productId'] != productId) {
        final other = uow.read(Boxes.products, existing['productId'] as String);
        throw DuplicateException('Barcode "$c" is already used by "${other?['name'] ?? 'another product'}".');
      }
      if (c.length <= 100 && uow.read(Boxes.serialIndex, c) != null) {
        throw DuplicateException('"$c" is already registered as a device serial number.');
      }
      uow.put(Boxes.barcodes, indexKey(c), {'productId': productId, 'code': c});
    }
  }

  Future<Product> create(ProductInput input, {bool allowDuplicate = false}) async {
    final uow = ctx.uow();
    final p = stageNew(uow, input, allowDuplicate: allowDuplicate);
    await uow.commit();
    return p;
  }

  /// Adds a new product to [uow] without committing (so it can be saved
  /// together with its first purchase in one step).
  Product stageNew(UnitOfWork uow, ProductInput input, {bool allowDuplicate = false}) {
    ctx.require(Permission.manageProducts);
    _validate(input);
    if (!allowDuplicate) {
      final d = findDuplicates(input);
      if (d.isNotEmpty) throw DuplicateException('A similar product already exists: "${d.first.name}".');
    }
    final code = _nextInternalCode(uow);
    final codes = {code, ...input.companyBarcodes.map(normalizeCode).where((c) => c.isNotEmpty)}.toList();
    final now = ctx.now();
    final p = Product(
      id: newId(),
      name: input.name.trim(),
      sku: input.sku.trim().isEmpty ? code : input.sku.trim(),
      categoryId: input.categoryId,
      brand: input.brand.trim(),
      model: input.model.trim(),
      description: input.description.trim(),
      purchasePrice: input.purchasePrice,
      sellingPrice: input.sellingPrice,
      wholesalePrice: input.wholesalePrice,
      minStock: input.minStock,
      unit: input.unit.trim().isEmpty ? 'pcs' : input.unit.trim(),
      allowDecimal: input.allowDecimal,
      internalCode: code,
      barcodes: codes,
      requiresSerial: input.requiresSerial,
      warrantyMonths: input.warrantyMonths,
      imagePath: input.imagePath,
      createdAt: now,
      updatedAt: now,
    );
    _indexCodes(uow, p.id, codes);
    uow.put(Boxes.products, p.id, p.toJson());
    ctx.audit(uow, 'create', 'product', p.id, p.name);
    return p;
  }

  /// Updates product master data. Stock quantities are never edited here
  /// (use stock adjustment) and historical invoices keep their own snapshots.
  Future<Product> update(String id, ProductInput input) async {
    ctx.require(Permission.manageProducts);
    _validate(input);
    final d = findDuplicates(input, excludeId: id);
    if (d.isNotEmpty) throw DuplicateException('A similar product already exists: "${d.first.name}".');
    final uow = ctx.uow();
    final p = inv.product(uow, id);
    final hasAnyStock = Qty.sum(StockBucket.values.map(p.bucket)).milli != 0;
    if (p.requiresSerial != input.requiresSerial && hasAnyStock) {
      throw const BusinessException('Serial tracking can only be changed when the product has no stock.');
    }
    if (p.requiresSerial && p.brandKey != Product.fromJson({...p.toJson(), 'brand': input.brand}).brandKey && ctx.all(Boxes.serials, SerialRecord.fromJson).any((s) => s.productId == id)) {
      throw const BusinessException('Brand cannot be changed after serial numbers are registered (serial identity uses the brand).');
    }
    final codes = {p.internalCode, ...input.companyBarcodes.map(normalizeCode).where((c) => c.isNotEmpty)}.toList();
    _indexCodes(uow, id, codes, previous: p.barcodes);
    final updated = p.copyWith(
      name: input.name.trim(),
      sku: input.sku.trim().isEmpty ? p.sku : input.sku.trim(),
      categoryId: input.categoryId,
      clearCategory: input.categoryId == null,
      brand: input.brand.trim(),
      model: input.model.trim(),
      description: input.description.trim(),
      purchasePrice: input.purchasePrice,
      sellingPrice: input.sellingPrice,
      wholesalePrice: input.wholesalePrice,
      clearWholesale: input.wholesalePrice == null,
      minStock: input.minStock,
      unit: input.unit.trim().isEmpty ? p.unit : input.unit.trim(),
      allowDecimal: input.allowDecimal,
      barcodes: codes,
      requiresSerial: input.requiresSerial,
      warrantyMonths: input.warrantyMonths,
      imagePath: input.imagePath,
      updatedAt: ctx.now(),
    );
    uow.put(Boxes.products, id, updated.toJson());
    final changes = <String>[];
    if (p.sellingPrice != updated.sellingPrice) changes.add('price ${p.sellingPrice} -> ${updated.sellingPrice}');
    ctx.audit(uow, 'update', 'product', id, changes.join('; '));
    await uow.commit();
    return updated;
  }

  bool hasTransactions(String productId) =>
      ctx.store.values(Boxes.stockMovements).any((j) => j['productId'] == productId) || // not cached (large)
      ctx.all(Boxes.quotations, Quotation.fromJson).any((q) => q.items.any((it) => it.productId == productId));

  /// Deletes products without history; archives products with history.
  /// Returns true if archived, false if deleted.
  Future<bool> deleteOrArchive(String id) async {
    ctx.require(Permission.manageProducts);
    final uow = ctx.uow();
    final p = inv.product(uow, id);
    if (hasTransactions(id) || Qty.sum(StockBucket.values.map(p.bucket)).milli != 0) {
      uow.put(Boxes.products, id, p.copyWith(archived: true).toJson());
      ctx.audit(uow, 'archive', 'product', id, p.name);
      await uow.commit();
      return true;
    }
    for (final c in p.barcodes) {
      uow.delete(Boxes.barcodes, indexKey(c));
    }
    uow.delete(Boxes.products, id);
    ctx.audit(uow, 'delete', 'product', id, p.name);
    await uow.commit();
    return false;
  }

  Future<void> restore(String id) async {
    ctx.require(Permission.manageProducts);
    final uow = ctx.uow();
    final p = inv.product(uow, id);
    uow.put(Boxes.products, id, p.copyWith(archived: false).toJson());
    ctx.audit(uow, 'restore', 'product', id, p.name);
    await uow.commit();
  }

  /// Scanner lookup. Accepts a product barcode/QR/internal code, a SKU, or a
  /// unit serial number. Returns null for unknown codes.
  ScanResult? lookup(String raw) {
    final code = normalizeCode(raw);
    if (code.isEmpty) return null;
    final idx = ctx.store.read(Boxes.barcodes, indexKey(code));
    if (idx != null) {
      final p = byId(idx['productId'] as String);
      if (p != null) return ScanResult(p);
    }
    final keys = code.length > 100 ? const <String>[] : ((ctx.store.read(Boxes.serialIndex, code)?['keys'] as List?) ?? const []);
    final recs = keys.map((k) => ctx.store.read(Boxes.serials, k.toString())).whereType<Map<String, dynamic>>().map(SerialRecord.fromJson).toList();
    if (recs.isNotEmpty) {
      // Prefer a unit that is in the shop.
      recs.sort((a, b) => (a.status == SerialStatus.inStock ? 0 : 1).compareTo(b.status == SerialStatus.inStock ? 0 : 1));
      final sr = recs.first;
      final p = byId(sr.productId);
      if (p != null) return ScanResult(p, sr, recs.skip(1).toList());
    }
    final bySku = _bySku()[code];
    return bySku == null ? null : ScanResult(bySku);
  }

  /// Bulk import from spreadsheet rows. Keys (case-insensitive): name, sku,
  /// category, brand, model, purchase_price, selling_price, min_stock, unit,
  /// decimal (yes/no), barcode, serial (yes/no), warranty_months.
  Future<List<String>> bulkImport(List<Map<String, String>> rows) async {
    ctx.require(Permission.manageProducts);
    final messages = <String>[];
    final catsByName = {for (final c in categories()) c.name.toLowerCase(): c.id};
    for (var r = 0; r < rows.length; r++) {
      final row = {for (final e in rows[r].entries) e.key.trim().toLowerCase().replaceAll(' ', '_'): e.value.trim()};
      try {
        final purchase = Money.parse(row['purchase_price'] ?? '0');
        final selling = Money.parse(row['selling_price'] ?? '0');
        if ((row['name'] ?? '').trim().isEmpty) throw const ValidationException('Product name is required.');
        String? catId;
        final catName = row['category'] ?? '';
        if (catName.isNotEmpty) {
          catId = catsByName[catName.toLowerCase()];
          if (catId == null) {
            final c = await saveCategory(catName);
            catsByName[catName.toLowerCase()] = c.id;
            catId = c.id;
          }
        }
        final serialFlag = (row['serial'] ?? '').toLowerCase();
        await create(ProductInput(
          name: row['name'] ?? '',
          sku: row['sku'] ?? '',
          categoryId: catId,
          brand: row['brand'] ?? '',
          model: row['model'] ?? '',
          purchasePrice: purchase,
          sellingPrice: selling,
          minStock: Qty.tryParse(row['min_stock'] ?? '') ?? const Qty.zero(),
          unit: row['unit'] ?? 'pcs',
          allowDecimal: ['yes', 'y', 'true', '1'].contains((row['decimal'] ?? '').toLowerCase()),
          companyBarcodes: [if ((row['barcode'] ?? '').isNotEmpty) row['barcode']!],
          requiresSerial: serialFlag == 'yes' || serialFlag == 'y' || serialFlag == 'true' || serialFlag == '1',
          warrantyMonths: int.tryParse(row['warranty_months'] ?? '') ?? 0,
        ));
        messages.add('Row ${r + 2}: imported');
      } catch (e) {
        messages.add('Row ${r + 2}: skipped - ${friendlyError(e)}');
      }
    }
    return messages;
  }
}
