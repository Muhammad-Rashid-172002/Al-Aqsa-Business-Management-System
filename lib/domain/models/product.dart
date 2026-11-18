import '../../core/ids.dart';
import '../../core/money.dart';
import '../../core/qty.dart';
import 'json_utils.dart';

class ProductCategory {
  final String id;
  final String name;
  final bool active;
  const ProductCategory({required this.id, required this.name, this.active = true});
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'active': active};
  factory ProductCategory.fromJson(Map<String, dynamic> j) => ProductCategory(id: s(j['id']), name: s(j['name']), active: b(j['active'], true));
}

class Product {
  final String id;
  final String name;
  final String sku;
  final String? categoryId;
  final String brand;
  final String model;
  final String description;
  final Money purchasePrice; // last purchase price (reference only)
  final Money sellingPrice;
  final Money? wholesalePrice;
  final Qty stockQty; // available, sellable
  final Qty issuedQty; // with technicians
  final Qty damagedQty;
  final Qty inspectionQty; // returned, waiting for owner inspection
  final Qty repairableQty; // approved as repairable, not sellable yet
  final Qty minStock;
  final String unit;
  final bool allowDecimal; // e.g. cable sold per metre
  final String internalCode;
  final List<String> barcodes;
  final bool requiresSerial;
  final int warrantyMonths;
  final String? imagePath;
  final bool archived;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Product({
    required this.id,
    required this.name,
    required this.sku,
    this.categoryId,
    this.brand = '',
    this.model = '',
    this.description = '',
    required this.purchasePrice,
    required this.sellingPrice,
    this.wholesalePrice,
    this.stockQty = const Qty.zero(),
    this.issuedQty = const Qty.zero(),
    this.damagedQty = const Qty.zero(),
    this.inspectionQty = const Qty.zero(),
    this.repairableQty = const Qty.zero(),
    this.minStock = const Qty.zero(),
    this.unit = 'pcs',
    this.allowDecimal = false,
    required this.internalCode,
    this.barcodes = const [],
    this.requiresSerial = false,
    this.warrantyMonths = 0,
    this.imagePath,
    this.archived = false,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get isLowStock => stockQty.isPositive && stockQty <= minStock;
  bool get isOutOfStock => !stockQty.isPositive;

  /// Brand part of serial-number identity.
  String get brandKey {
    final k = normalizeCode(brand).replaceAll('|', '');
    return k.isEmpty ? 'GENERIC' : k;
  }

  Qty bucket(StockBucket bk) => switch (bk) {
        StockBucket.available => stockQty,
        StockBucket.issued => issuedQty,
        StockBucket.damaged => damagedQty,
        StockBucket.inspection => inspectionQty,
        StockBucket.repairable => repairableQty,
      };

  Product withBucket(StockBucket bk, Qty v) => switch (bk) {
        StockBucket.available => copyWith(stockQty: v),
        StockBucket.issued => copyWith(issuedQty: v),
        StockBucket.damaged => copyWith(damagedQty: v),
        StockBucket.inspection => copyWith(inspectionQty: v),
        StockBucket.repairable => copyWith(repairableQty: v),
      };

  Product copyWith({
    String? name,
    String? sku,
    String? categoryId,
    bool clearCategory = false,
    String? brand,
    String? model,
    String? description,
    Money? purchasePrice,
    Money? sellingPrice,
    Money? wholesalePrice,
    bool clearWholesale = false,
    Qty? stockQty,
    Qty? issuedQty,
    Qty? damagedQty,
    Qty? inspectionQty,
    Qty? repairableQty,
    Qty? minStock,
    String? unit,
    bool? allowDecimal,
    List<String>? barcodes,
    bool? requiresSerial,
    int? warrantyMonths,
    String? imagePath,
    bool? archived,
    DateTime? updatedAt,
  }) =>
      Product(
        id: id,
        name: name ?? this.name,
        sku: sku ?? this.sku,
        categoryId: clearCategory ? null : (categoryId ?? this.categoryId),
        brand: brand ?? this.brand,
        model: model ?? this.model,
        description: description ?? this.description,
        purchasePrice: purchasePrice ?? this.purchasePrice,
        sellingPrice: sellingPrice ?? this.sellingPrice,
        wholesalePrice: clearWholesale ? null : (wholesalePrice ?? this.wholesalePrice),
        stockQty: stockQty ?? this.stockQty,
        issuedQty: issuedQty ?? this.issuedQty,
        damagedQty: damagedQty ?? this.damagedQty,
        inspectionQty: inspectionQty ?? this.inspectionQty,
        repairableQty: repairableQty ?? this.repairableQty,
        minStock: minStock ?? this.minStock,
        unit: unit ?? this.unit,
        allowDecimal: allowDecimal ?? this.allowDecimal,
        internalCode: internalCode,
        barcodes: barcodes ?? this.barcodes,
        requiresSerial: requiresSerial ?? this.requiresSerial,
        warrantyMonths: warrantyMonths ?? this.warrantyMonths,
        imagePath: imagePath ?? this.imagePath,
        archived: archived ?? this.archived,
        createdAt: createdAt,
        updatedAt: updatedAt ?? DateTime.now(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'sku': sku,
        'categoryId': categoryId,
        'brand': brand,
        'model': model,
        'description': description,
        'purchasePrice': purchasePrice.paisa,
        'sellingPrice': sellingPrice.paisa,
        'wholesalePrice': wholesalePrice?.paisa,
        'stockQty': stockQty.milli,
        'issuedQty': issuedQty.milli,
        'damagedQty': damagedQty.milli,
        'inspectionQty': inspectionQty.milli,
        'repairableQty': repairableQty.milli,
        'minStock': minStock.milli,
        'unit': unit,
        'allowDecimal': allowDecimal,
        'internalCode': internalCode,
        'barcodes': barcodes,
        'requiresSerial': requiresSerial,
        'warrantyMonths': warrantyMonths,
        'imagePath': imagePath,
        'archived': archived,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory Product.fromJson(Map<String, dynamic> j) => Product(
        id: s(j['id']),
        name: s(j['name']),
        sku: s(j['sku']),
        categoryId: sn(j['categoryId']),
        brand: s(j['brand']),
        model: s(j['model']),
        description: s(j['description']),
        purchasePrice: m(j['purchasePrice']),
        sellingPrice: m(j['sellingPrice']),
        wholesalePrice: j['wholesalePrice'] == null ? null : m(j['wholesalePrice']),
        stockQty: qy(j['stockQty']),
        issuedQty: qy(j['issuedQty']),
        damagedQty: qy(j['damagedQty']),
        inspectionQty: qy(j['inspectionQty']),
        repairableQty: qy(j['repairableQty']),
        minStock: qy(j['minStock']),
        unit: s(j['unit']),
        allowDecimal: b(j['allowDecimal']),
        internalCode: s(j['internalCode']),
        barcodes: strList(j['barcodes']),
        requiresSerial: b(j['requiresSerial']),
        warrantyMonths: i(j['warrantyMonths']),
        imagePath: sn(j['imagePath']),
        archived: b(j['archived']),
        createdAt: parseDate(j['createdAt']),
        updatedAt: parseDate(j['updatedAt']),
      );
}

/// One FIFO cost layer: a batch of units at one unit cost.
class CostLayer {
  final String id;
  final String productId;
  final String sourceType;
  final String sourceId;
  final DateTime date;
  final Qty qtyIn;
  final Qty qtyRemaining;
  final Money unitCost;

  const CostLayer({
    required this.id,
    required this.productId,
    required this.sourceType,
    required this.sourceId,
    required this.date,
    required this.qtyIn,
    required this.qtyRemaining,
    required this.unitCost,
  });

  CostLayer withRemaining(Qty r) => CostLayer(
      id: id, productId: productId, sourceType: sourceType, sourceId: sourceId, date: date, qtyIn: qtyIn, qtyRemaining: r, unitCost: unitCost);

  Map<String, dynamic> toJson() => {
        'id': id,
        'productId': productId,
        'sourceType': sourceType,
        'sourceId': sourceId,
        'date': date.toIso8601String(),
        'qtyIn': qtyIn.milli,
        'qtyRemaining': qtyRemaining.milli,
        'unitCost': unitCost.paisa,
      };
  factory CostLayer.fromJson(Map<String, dynamic> j) => CostLayer(
        id: s(j['id']),
        productId: s(j['productId']),
        sourceType: s(j['sourceType']),
        sourceId: s(j['sourceId']),
        date: parseDate(j['date']),
        qtyIn: qy(j['qtyIn']),
        qtyRemaining: qy(j['qtyRemaining']),
        unitCost: m(j['unitCost']),
      );
}

enum StockBucket { available, issued, damaged, inspection, repairable }

extension StockBucketLabel on StockBucket {
  String get label => switch (this) {
        StockBucket.available => 'Available',
        StockBucket.issued => 'With Technicians',
        StockBucket.damaged => 'Damaged',
        StockBucket.inspection => 'Awaiting Inspection',
        StockBucket.repairable => 'Repairable',
      };
}

class StockMovement {
  final String id;
  final String productId;
  final DateTime at;
  final String type;
  final StockBucket bucket;
  final Qty qty; // signed change in the bucket
  final Qty before;
  final Qty after;
  final Money value; // cost value moved (positive), when known
  final String refType;
  final String refId;
  final String reason;
  final String userId;

  const StockMovement({
    required this.id,
    required this.productId,
    required this.at,
    required this.type,
    required this.bucket,
    required this.qty,
    required this.before,
    required this.after,
    this.value = const Money.zero(),
    this.refType = '',
    this.refId = '',
    this.reason = '',
    required this.userId,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'productId': productId,
        'at': at.toIso8601String(),
        'type': type,
        'bucket': bucket.name,
        'qty': qty.milli,
        'before': before.milli,
        'after': after.milli,
        'value': value.paisa,
        'refType': refType,
        'refId': refId,
        'reason': reason,
        'userId': userId,
      };
  factory StockMovement.fromJson(Map<String, dynamic> j) => StockMovement(
        id: s(j['id']),
        productId: s(j['productId']),
        at: parseDate(j['at']),
        type: s(j['type']),
        bucket: enumByName(StockBucket.values, j['bucket'], StockBucket.available),
        qty: qy(j['qty']),
        before: qy(j['before']),
        after: qy(j['after']),
        value: m(j['value']),
        refType: s(j['refType']),
        refId: s(j['refId']),
        reason: s(j['reason']),
        userId: s(j['userId']),
      );
}

enum SerialStatus {
  inStock,
  issuedToTechnician,
  installed,
  sold,
  returned,
  underRepair,
  replaced,
  damaged,
  returnedToSupplier,
  pendingInspection,
  awaitingRepair,
}

extension SerialStatusLabel on SerialStatus {
  String get label => switch (this) {
        SerialStatus.inStock => 'In Stock',
        SerialStatus.issuedToTechnician => 'Issued to Technician',
        SerialStatus.installed => 'Installed',
        SerialStatus.sold => 'Sold',
        SerialStatus.returned => 'Returned',
        SerialStatus.underRepair => 'Under Repair (Warranty)',
        SerialStatus.replaced => 'Replaced',
        SerialStatus.damaged => 'Damaged',
        SerialStatus.returnedToSupplier => 'Returned to Supplier',
        SerialStatus.pendingInspection => 'Awaiting Inspection',
        SerialStatus.awaitingRepair => 'Repairable (Not Sellable)',
      };

  /// Unit is counted in some stock bucket of the shop (not with customer/supplier).
  bool get isActiveInShop => this != SerialStatus.sold && this != SerialStatus.returnedToSupplier && this != SerialStatus.replaced;
}

class SerialEvent {
  final DateTime at;
  final SerialStatus status;
  final String note;
  final String refType;
  final String refId;
  final String userId;
  const SerialEvent({required this.at, required this.status, this.note = '', this.refType = '', this.refId = '', this.userId = ''});
  Map<String, dynamic> toJson() =>
      {'at': at.toIso8601String(), 'status': status.name, 'note': note, 'refType': refType, 'refId': refId, 'userId': userId};
  factory SerialEvent.fromJson(Map<String, dynamic> j) => SerialEvent(
        at: parseDate(j['at']),
        status: enumByName(SerialStatus.values, j['status'], SerialStatus.inStock),
        note: s(j['note']),
        refType: s(j['refType']),
        refId: s(j['refId']),
        userId: s(j['userId']),
      );
}

/// One physical unit. Identity = brand + serial number. The storage [key] is
/// "BRAND|SERIAL" (plus "|n" when the owner approved a genuine manufacturer
/// duplicate within the same brand).
class SerialRecord {
  final String key;
  final String serial; // normalized serial as printed on the device
  final String brandKey;
  final String productId;
  final String? supplierId;
  final String? purchaseId;
  final DateTime? purchaseDate;
  final Money cost;
  final SerialStatus status;
  final String? technicianId;
  final String? customerId;
  final String? saleId;
  final DateTime? warrantyStart;
  final DateTime? warrantyExpiry;
  final String? duplicateApprovedBy; // owner who approved a duplicate registration
  final List<SerialEvent> history;

  const SerialRecord({
    required this.key,
    required this.serial,
    required this.brandKey,
    required this.productId,
    this.supplierId,
    this.purchaseId,
    this.purchaseDate,
    required this.cost,
    required this.status,
    this.technicianId,
    this.customerId,
    this.saleId,
    this.warrantyStart,
    this.warrantyExpiry,
    this.duplicateApprovedBy,
    this.history = const [],
  });

  static String keyFor(String brandKey, String serial, [int n = 1]) => n <= 1 ? '$brandKey|$serial' : '$brandKey|$serial|$n';
  static bool isKey(String v) => v.contains('|');
  static String displayOf(String keyOrSerial) {
    if (!isKey(keyOrSerial)) return keyOrSerial;
    final parts = keyOrSerial.split('|');
    return parts.length > 2 ? '${parts[1]} (#${parts[2]})' : parts[1];
  }

  String get display => displayOf(key);

  bool warrantyActiveOn(DateTime d) => warrantyExpiry != null && !d.isAfter(warrantyExpiry!);

  SerialRecord transition(
    SerialStatus newStatus, {
    required DateTime at,
    String note = '',
    String refType = '',
    String refId = '',
    String userId = '',
    String? technicianId,
    bool clearTechnician = false,
    String? customerId,
    bool clearCustomer = false,
    String? saleId,
    bool clearSale = false,
    DateTime? warrantyStart,
    DateTime? warrantyExpiry,
    bool clearWarranty = false,
  }) =>
      SerialRecord(
        key: key,
        serial: serial,
        brandKey: brandKey,
        productId: productId,
        supplierId: supplierId,
        purchaseId: purchaseId,
        purchaseDate: purchaseDate,
        cost: cost,
        status: newStatus,
        technicianId: clearTechnician ? null : (technicianId ?? this.technicianId),
        customerId: clearCustomer ? null : (customerId ?? this.customerId),
        saleId: clearSale ? null : (saleId ?? this.saleId),
        warrantyStart: clearWarranty ? null : (warrantyStart ?? this.warrantyStart),
        warrantyExpiry: clearWarranty ? null : (warrantyExpiry ?? this.warrantyExpiry),
        duplicateApprovedBy: duplicateApprovedBy,
        history: [...history, SerialEvent(at: at, status: newStatus, note: note, refType: refType, refId: refId, userId: userId)],
      );

  /// Re-registers a unit that came back from the supplier (keeps history).
  SerialRecord repurchased({required String supplierId, required String purchaseId, required DateTime date, required Money cost, required String note, required String userId}) =>
      SerialRecord(
        key: key,
        serial: serial,
        brandKey: brandKey,
        productId: productId,
        supplierId: supplierId,
        purchaseId: purchaseId,
        purchaseDate: date,
        cost: cost,
        status: SerialStatus.inStock,
        duplicateApprovedBy: duplicateApprovedBy,
        history: [...history, SerialEvent(at: date, status: SerialStatus.inStock, note: note, refType: 'purchase', refId: purchaseId, userId: userId)],
      );

  Map<String, dynamic> toJson() => {
        'key': key,
        'serial': serial,
        'brandKey': brandKey,
        'productId': productId,
        'supplierId': supplierId,
        'purchaseId': purchaseId,
        'purchaseDate': dateOrNull(purchaseDate),
        'cost': cost.paisa,
        'status': status.name,
        'technicianId': technicianId,
        'customerId': customerId,
        'saleId': saleId,
        'warrantyStart': dateOrNull(warrantyStart),
        'warrantyExpiry': dateOrNull(warrantyExpiry),
        'duplicateApprovedBy': duplicateApprovedBy,
        'history': history.map((e) => e.toJson()).toList(),
      };

  factory SerialRecord.fromJson(Map<String, dynamic> j) => SerialRecord(
        key: s(j['key']),
        serial: s(j['serial']),
        brandKey: s(j['brandKey']),
        productId: s(j['productId']),
        supplierId: sn(j['supplierId']),
        purchaseId: sn(j['purchaseId']),
        purchaseDate: parseDateOrNull(j['purchaseDate']),
        cost: m(j['cost']),
        status: enumByName(SerialStatus.values, j['status'], SerialStatus.inStock),
        technicianId: sn(j['technicianId']),
        customerId: sn(j['customerId']),
        saleId: sn(j['saleId']),
        warrantyStart: parseDateOrNull(j['warrantyStart']),
        warrantyExpiry: parseDateOrNull(j['warrantyExpiry']),
        duplicateApprovedBy: sn(j['duplicateApprovedBy']),
        history: mapList(j['history']).map(SerialEvent.fromJson).toList(),
      );
}

enum InspectionDecision { sellable, repairable, damaged }

enum InspectionStatus { pending, repairable, resolved }

/// Goods returned in Used/Damaged/Faulty condition. They are not sellable
/// until the owner inspects them and decides.
class InspectionItem {
  final String id;
  final String productId;
  final String productName;
  final Qty qty;
  final Money cost;
  final List<String> serials; // serial keys
  final String sourceType; // tech_return | sales_return
  final String sourceId;
  final String? technicianId;
  final String reportedCondition; // used | damaged | faulty
  final String reason;
  final InspectionStatus status;
  final InspectionDecision? decision;
  final String decisionNote;
  final DateTime createdAt;
  final DateTime? resolvedAt;
  final String? resolvedBy;

  const InspectionItem({
    required this.id,
    required this.productId,
    required this.productName,
    required this.qty,
    required this.cost,
    this.serials = const [],
    required this.sourceType,
    required this.sourceId,
    this.technicianId,
    required this.reportedCondition,
    this.reason = '',
    this.status = InspectionStatus.pending,
    this.decision,
    this.decisionNote = '',
    required this.createdAt,
    this.resolvedAt,
    this.resolvedBy,
  });

  StockBucket get currentBucket => status == InspectionStatus.repairable ? StockBucket.repairable : StockBucket.inspection;

  InspectionItem copyWith({Qty? qty, Money? cost, List<String>? serials, InspectionStatus? status, InspectionDecision? decision, String? decisionNote, DateTime? resolvedAt, String? resolvedBy, String? id}) =>
      InspectionItem(
        id: id ?? this.id,
        productId: productId,
        productName: productName,
        qty: qty ?? this.qty,
        cost: cost ?? this.cost,
        serials: serials ?? this.serials,
        sourceType: sourceType,
        sourceId: sourceId,
        technicianId: technicianId,
        reportedCondition: reportedCondition,
        reason: reason,
        status: status ?? this.status,
        decision: decision ?? this.decision,
        decisionNote: decisionNote ?? this.decisionNote,
        createdAt: createdAt,
        resolvedAt: resolvedAt ?? this.resolvedAt,
        resolvedBy: resolvedBy ?? this.resolvedBy,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'productId': productId,
        'productName': productName,
        'qty': qty.milli,
        'cost': cost.paisa,
        'serials': serials,
        'sourceType': sourceType,
        'sourceId': sourceId,
        'technicianId': technicianId,
        'reportedCondition': reportedCondition,
        'reason': reason,
        'status': status.name,
        'decision': decision?.name,
        'decisionNote': decisionNote,
        'createdAt': createdAt.toIso8601String(),
        'resolvedAt': dateOrNull(resolvedAt),
        'resolvedBy': resolvedBy,
      };

  factory InspectionItem.fromJson(Map<String, dynamic> j) => InspectionItem(
        id: s(j['id']),
        productId: s(j['productId']),
        productName: s(j['productName']),
        qty: qy(j['qty']),
        cost: m(j['cost']),
        serials: strList(j['serials']),
        sourceType: s(j['sourceType']),
        sourceId: s(j['sourceId']),
        technicianId: sn(j['technicianId']),
        reportedCondition: s(j['reportedCondition']),
        reason: s(j['reason']),
        status: enumByName(InspectionStatus.values, j['status'], InspectionStatus.pending),
        decision: j['decision'] == null ? null : enumByName(InspectionDecision.values, j['decision'], InspectionDecision.damaged),
        decisionNote: s(j['decisionNote']),
        createdAt: parseDate(j['createdAt']),
        resolvedAt: parseDateOrNull(j['resolvedAt']),
        resolvedBy: sn(j['resolvedBy']),
      );
}
