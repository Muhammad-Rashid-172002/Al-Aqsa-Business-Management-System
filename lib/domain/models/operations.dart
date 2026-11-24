import '../../core/money.dart';
import '../../core/qty.dart';
import '../../core/scan_detector.dart';
import 'json_utils.dart';

// ───────────────────────── Technician material ─────────────────────────

enum TechTxnType { issue, returnUnused, returnUsed, returnDamaged, returnFaulty, installed }

extension TechTxnTypeLabel on TechTxnType {
  String get label => switch (this) {
        TechTxnType.issue => 'Issued',
        TechTxnType.returnUnused => 'Returned (Unused)',
        TechTxnType.returnUsed => 'Returned (Used)',
        TechTxnType.returnDamaged => 'Returned (Damaged)',
        TechTxnType.returnFaulty => 'Returned (Faulty)',
        TechTxnType.installed => 'Installed at Customer',
      };
  bool get isReturn => this != TechTxnType.issue && this != TechTxnType.installed;
}

class TechTxn {
  final String id;
  final String technicianId;
  final TechTxnType type;
  final DateTime at;
  final String productId;
  final String productName;
  final Qty qty;
  final Money cost; // total cost value moved
  final List<String> serials;
  final String jobRef;
  final String? customerId;
  final String reason;
  final String notes;
  final String userId;
  final String? invoicedSaleId; // for installed material once invoiced
  final Qty invoicedQty;
  final String? inspectionId; // for used/damaged/faulty returns

  const TechTxn({
    required this.id,
    required this.technicianId,
    required this.type,
    required this.at,
    required this.productId,
    required this.productName,
    required this.qty,
    required this.cost,
    this.serials = const [],
    this.jobRef = '',
    this.customerId,
    this.reason = '',
    this.notes = '',
    required this.userId,
    this.invoicedSaleId,
    this.invoicedQty = const Qty.zero(),
    this.inspectionId,
  });

  TechTxn clearInvoice() => TechTxn.fromJson({...toJson(), 'invoicedSaleId': null, 'invoicedQty': 0});

  TechTxn markInvoiced(String saleId, Qty qtyInvoiced) => TechTxn(
        id: id,
        technicianId: technicianId,
        type: type,
        at: at,
        productId: productId,
        productName: productName,
        qty: qty,
        cost: cost,
        serials: serials,
        jobRef: jobRef,
        customerId: customerId,
        reason: reason,
        notes: notes,
        userId: userId,
        invoicedSaleId: saleId,
        invoicedQty: qtyInvoiced,
        inspectionId: inspectionId,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'technicianId': technicianId,
        'type': type.name,
        'at': at.toIso8601String(),
        'productId': productId,
        'productName': productName,
        'qty': qty.milli,
        'cost': cost.paisa,
        'serials': serials,
        'jobRef': jobRef,
        'customerId': customerId,
        'reason': reason,
        'notes': notes,
        'userId': userId,
        'invoicedSaleId': invoicedSaleId,
        'invoicedQty': invoicedQty.milli,
        'inspectionId': inspectionId,
      };

  factory TechTxn.fromJson(Map<String, dynamic> j) => TechTxn(
        id: s(j['id']),
        technicianId: s(j['technicianId']),
        type: enumByName(TechTxnType.values, j['type'], TechTxnType.issue),
        at: parseDate(j['at']),
        productId: s(j['productId']),
        productName: s(j['productName']),
        qty: qy(j['qty']),
        cost: m(j['cost']),
        serials: strList(j['serials']),
        jobRef: s(j['jobRef']),
        customerId: sn(j['customerId']),
        reason: s(j['reason']),
        notes: s(j['notes']),
        userId: s(j['userId']),
        invoicedSaleId: sn(j['invoicedSaleId']),
        invoicedQty: qy(j['invoicedQty']),
        inspectionId: sn(j['inspectionId']),
      );
}

/// What one technician currently holds of one product (qty + cost value).
class TechHolding {
  final String technicianId;
  final String productId;
  final Qty qty;
  final Money cost;
  const TechHolding({required this.technicianId, required this.productId, required this.qty, required this.cost});

  String get key => keyFor(technicianId, productId);
  static String keyFor(String techId, String productId) => '$techId|$productId';

  /// Cost of [n] units at the holding's average cost (last units take the remainder).
  Money costOf(Qty n) => n >= qty ? cost : cost.shareQty(n, qty);

  Map<String, dynamic> toJson() => {'technicianId': technicianId, 'productId': productId, 'qty': qty.milli, 'cost': cost.paisa};
  factory TechHolding.fromJson(Map<String, dynamic> j) =>
      TechHolding(technicianId: s(j['technicianId']), productId: s(j['productId']), qty: qy(j['qty']), cost: m(j['cost']));
}

// ───────────────────────── Warranty ─────────────────────────

enum ClaimStatus { open, sentForRepair, repaired, replaced, rejected, closed }

class WarrantyClaim {
  final String id;
  final String number;
  final String serial;
  final String productId;
  final String? customerId;
  final String? saleId;
  final DateTime date;
  final String issue;
  final ClaimStatus status;
  final String resolution;
  final String? replacementSerial;
  final String? repairJobId;
  final String userId;

  const WarrantyClaim({
    required this.id,
    required this.number,
    required this.serial,
    required this.productId,
    this.customerId,
    this.saleId,
    required this.date,
    required this.issue,
    this.status = ClaimStatus.open,
    this.resolution = '',
    this.replacementSerial,
    this.repairJobId,
    required this.userId,
  });

  WarrantyClaim copyWith({ClaimStatus? status, String? resolution, String? replacementSerial, String? repairJobId}) => WarrantyClaim(
        id: id,
        number: number,
        serial: serial,
        productId: productId,
        customerId: customerId,
        saleId: saleId,
        date: date,
        issue: issue,
        status: status ?? this.status,
        resolution: resolution ?? this.resolution,
        replacementSerial: replacementSerial ?? this.replacementSerial,
        repairJobId: repairJobId ?? this.repairJobId,
        userId: userId,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'number': number,
        'serial': serial,
        'productId': productId,
        'customerId': customerId,
        'saleId': saleId,
        'date': date.toIso8601String(),
        'issue': issue,
        'status': status.name,
        'resolution': resolution,
        'replacementSerial': replacementSerial,
        'repairJobId': repairJobId,
        'userId': userId,
      };
  factory WarrantyClaim.fromJson(Map<String, dynamic> j) => WarrantyClaim(
        id: s(j['id']),
        number: s(j['number']),
        serial: s(j['serial']),
        productId: s(j['productId']),
        customerId: sn(j['customerId']),
        saleId: sn(j['saleId']),
        date: parseDate(j['date']),
        issue: s(j['issue']),
        status: enumByName(ClaimStatus.values, j['status'], ClaimStatus.open),
        resolution: s(j['resolution']),
        replacementSerial: sn(j['replacementSerial']),
        repairJobId: sn(j['repairJobId']),
        userId: s(j['userId']),
      );
}

// ───────────────────────── Repairs ─────────────────────────

enum RepairStatus { received, diagnosing, waitingForParts, inProgress, repaired, notRepairable, readyForCollection, delivered }

extension RepairStatusLabel on RepairStatus {
  String get label => switch (this) {
        RepairStatus.received => 'Received',
        RepairStatus.diagnosing => 'Diagnosing',
        RepairStatus.waitingForParts => 'Waiting for Parts',
        RepairStatus.inProgress => 'In Progress',
        RepairStatus.repaired => 'Repaired',
        RepairStatus.notRepairable => 'Not Repairable',
        RepairStatus.readyForCollection => 'Ready for Collection',
        RepairStatus.delivered => 'Delivered',
      };
  bool get isOpen => this != RepairStatus.delivered;
}

class RepairPart {
  final String productId;
  final String name;
  final Qty qty;
  final Money cost; // total FIFO cost consumed
  final Money price; // total charged to customer
  const RepairPart({required this.productId, required this.name, required this.qty, required this.cost, required this.price});
  Map<String, dynamic> toJson() => {'productId': productId, 'name': name, 'qty': qty.milli, 'cost': cost.paisa, 'price': price.paisa};
  factory RepairPart.fromJson(Map<String, dynamic> j) =>
      RepairPart(productId: s(j['productId']), name: s(j['name']), qty: qy(j['qty']), cost: m(j['cost']), price: m(j['price']));
}

class RepairStatusEvent {
  final DateTime at;
  final RepairStatus status;
  final String note;
  final String userId;
  const RepairStatusEvent({required this.at, required this.status, this.note = '', this.userId = ''});
  Map<String, dynamic> toJson() => {'at': at.toIso8601String(), 'status': status.name, 'note': note, 'userId': userId};
  factory RepairStatusEvent.fromJson(Map<String, dynamic> j) => RepairStatusEvent(
      at: parseDate(j['at']), status: enumByName(RepairStatus.values, j['status'], RepairStatus.received), note: s(j['note']), userId: s(j['userId']));
}

class RepairJob {
  final String id;
  final String number;
  final String? customerId;
  final String customerName;
  final String customerPhone;
  final String? productId;
  final String productName;
  final String serial;
  final DateTime receivedDate;
  final String reportedIssue;
  final String physicalCondition;
  final String? technicianId;
  final String repairNotes;
  final List<RepairPart> parts;
  final Money serviceCharges;
  final bool underWarranty;
  final RepairStatus status;
  final List<RepairStatusEvent> history;
  final DateTime? completionDate;
  final DateTime? deliveryDate;
  final bool chargesPosted;
  final String? warrantyClaimId;

  const RepairJob({
    required this.id,
    required this.number,
    this.customerId,
    required this.customerName,
    this.customerPhone = '',
    this.productId,
    required this.productName,
    this.serial = '',
    required this.receivedDate,
    required this.reportedIssue,
    this.physicalCondition = '',
    this.technicianId,
    this.repairNotes = '',
    this.parts = const [],
    this.serviceCharges = const Money.zero(),
    this.underWarranty = false,
    this.status = RepairStatus.received,
    this.history = const [],
    this.completionDate,
    this.deliveryDate,
    this.chargesPosted = false,
    this.warrantyClaimId,
  });

  Money get partsPrice => Money.sum(parts.map((e) => e.price));
  Money get partsCost => Money.sum(parts.map((e) => e.cost));
  Money get totalCharges => serviceCharges + partsPrice;

  RepairJob copyWith({
    String? technicianId,
    String? repairNotes,
    List<RepairPart>? parts,
    Money? serviceCharges,
    RepairStatus? status,
    List<RepairStatusEvent>? history,
    DateTime? completionDate,
    DateTime? deliveryDate,
    bool? chargesPosted,
    String? physicalCondition,
    String? reportedIssue,
  }) =>
      RepairJob(
        id: id,
        number: number,
        customerId: customerId,
        customerName: customerName,
        customerPhone: customerPhone,
        productId: productId,
        productName: productName,
        serial: serial,
        receivedDate: receivedDate,
        reportedIssue: reportedIssue ?? this.reportedIssue,
        physicalCondition: physicalCondition ?? this.physicalCondition,
        technicianId: technicianId ?? this.technicianId,
        repairNotes: repairNotes ?? this.repairNotes,
        parts: parts ?? this.parts,
        serviceCharges: serviceCharges ?? this.serviceCharges,
        underWarranty: underWarranty,
        status: status ?? this.status,
        history: history ?? this.history,
        completionDate: completionDate ?? this.completionDate,
        deliveryDate: deliveryDate ?? this.deliveryDate,
        chargesPosted: chargesPosted ?? this.chargesPosted,
        warrantyClaimId: warrantyClaimId,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'number': number,
        'customerId': customerId,
        'customerName': customerName,
        'customerPhone': customerPhone,
        'productId': productId,
        'productName': productName,
        'serial': serial,
        'receivedDate': receivedDate.toIso8601String(),
        'reportedIssue': reportedIssue,
        'physicalCondition': physicalCondition,
        'technicianId': technicianId,
        'repairNotes': repairNotes,
        'parts': parts.map((e) => e.toJson()).toList(),
        'serviceCharges': serviceCharges.paisa,
        'underWarranty': underWarranty,
        'status': status.name,
        'history': history.map((e) => e.toJson()).toList(),
        'completionDate': dateOrNull(completionDate),
        'deliveryDate': dateOrNull(deliveryDate),
        'chargesPosted': chargesPosted,
        'warrantyClaimId': warrantyClaimId,
      };

  factory RepairJob.fromJson(Map<String, dynamic> j) => RepairJob(
        id: s(j['id']),
        number: s(j['number']),
        customerId: sn(j['customerId']),
        customerName: s(j['customerName']),
        customerPhone: s(j['customerPhone']),
        productId: sn(j['productId']),
        productName: s(j['productName']),
        serial: s(j['serial']),
        receivedDate: parseDate(j['receivedDate']),
        reportedIssue: s(j['reportedIssue']),
        physicalCondition: s(j['physicalCondition']),
        technicianId: sn(j['technicianId']),
        repairNotes: s(j['repairNotes']),
        parts: mapList(j['parts']).map(RepairPart.fromJson).toList(),
        serviceCharges: m(j['serviceCharges']),
        underWarranty: b(j['underWarranty']),
        status: enumByName(RepairStatus.values, j['status'], RepairStatus.received),
        history: mapList(j['history']).map(RepairStatusEvent.fromJson).toList(),
        completionDate: parseDateOrNull(j['completionDate']),
        deliveryDate: parseDateOrNull(j['deliveryDate']),
        chargesPosted: b(j['chargesPosted']),
        warrantyClaimId: sn(j['warrantyClaimId']),
      );
}

// ───────────────────────── Settings ─────────────────────────

enum WarrantyStartPolicy { saleDate, installationDate }

class AppSettings {
  final String businessName;
  final String address;
  final String phone;
  final String? logoPath;
  final String invoicePrefix;
  final String quotationPrefix;
  final String purchasePrefix;
  final String repairPrefix;
  final String currencySymbol;
  final String dateFormat;
  final String receiptFormat; // a4 | thermal80 | thermal58
  final String? printerName;
  final int labelWidthMm;
  final int labelHeightMm;
  final String defaultPaymentMethod;
  final bool lowStockAlerts;
  final String? backupDirectory;
  final bool autoBackup;
  final int backupKeep;
  final String theme; // dark | light
  final WarrantyStartPolicy warrantyStartPolicy;
  final String quotationTerms;
  final int quotationValidityDays;
  final String email;
  final String receiptFooter;
  final bool autoPrintReceipt;
  final bool labelShowPrice;
  final int backupHour; // hour of day for the automatic backup (0-23)
  final int backupMinute; // minute of that hour (0-59)
  // USB barcode / QR scanner (keyboard mode)
  final String scannerSuffix; // auto | enter | tab | none
  final int scannerKeyGapMs;
  final int scannerMinLength;
  final int scannerDuplicateMs; // 0 = off
  // Shop contact shown on every customer document, with a WhatsApp link.
  final String contactPerson;
  final String contactPhone;
  final String? whatsappIconPath; // optional icon image (e.g. the official WhatsApp icon file)

  const AppSettings({
    this.businessName = 'AL-AQSA CCTV & SOLAR SYSTEM',
    this.address = '',
    this.phone = '',
    this.logoPath,
    this.invoicePrefix = 'INV',
    this.quotationPrefix = 'QT',
    this.purchasePrefix = 'PUR',
    this.repairPrefix = 'RJ',
    this.currencySymbol = 'Rs',
    this.dateFormat = 'dd/MM/yyyy',
    this.receiptFormat = 'thermal80',
    this.printerName,
    this.labelWidthMm = 50,
    this.labelHeightMm = 25,
    this.defaultPaymentMethod = 'cash',
    this.lowStockAlerts = true,
    this.backupDirectory,
    this.autoBackup = true,
    this.backupKeep = 30,
    this.theme = 'dark',
    this.warrantyStartPolicy = WarrantyStartPolicy.saleDate,
    this.quotationTerms = 'Prices are valid until the expiry date. Installation charges are separate unless stated.',
    this.quotationValidityDays = 15,
    this.email = '',
    this.receiptFooter = 'Thank you for your business!',
    this.autoPrintReceipt = false,
    this.labelShowPrice = true,
    this.backupHour = 0,
    this.backupMinute = 0,
    this.scannerSuffix = 'auto',
    this.scannerKeyGapMs = 40,
    this.scannerMinLength = 4,
    this.scannerDuplicateMs = 700,
    this.contactPerson = 'M. Osama',
    this.contactPhone = '0371-5263580',
    this.whatsappIconPath,
  });

  ScannerConfig get scanner => ScannerConfig(
        suffix: ScanSuffix.parse(scannerSuffix),
        maxKeyGap: Duration(milliseconds: scannerKeyGapMs),
        minLength: scannerMinLength,
        duplicateWindow: Duration(milliseconds: scannerDuplicateMs),
      );

  Map<String, dynamic> toJson() => {
        'businessName': businessName,
        'address': address,
        'phone': phone,
        'logoPath': logoPath,
        'invoicePrefix': invoicePrefix,
        'quotationPrefix': quotationPrefix,
        'purchasePrefix': purchasePrefix,
        'repairPrefix': repairPrefix,
        'currencySymbol': currencySymbol,
        'dateFormat': dateFormat,
        'receiptFormat': receiptFormat,
        'printerName': printerName,
        'labelWidthMm': labelWidthMm,
        'labelHeightMm': labelHeightMm,
        'defaultPaymentMethod': defaultPaymentMethod,
        'lowStockAlerts': lowStockAlerts,
        'backupDirectory': backupDirectory,
        'autoBackup': autoBackup,
        'backupKeep': backupKeep,
        'theme': theme,
        'warrantyStartPolicy': warrantyStartPolicy.name,
        'quotationTerms': quotationTerms,
        'quotationValidityDays': quotationValidityDays,
        'email': email,
        'receiptFooter': receiptFooter,
        'autoPrintReceipt': autoPrintReceipt,
        'labelShowPrice': labelShowPrice,
        'backupHour': backupHour,
        'backupMinute': backupMinute,
        'scannerSuffix': scannerSuffix,
        'scannerKeyGapMs': scannerKeyGapMs,
        'scannerMinLength': scannerMinLength,
        'scannerDuplicateMs': scannerDuplicateMs,
        'contactPerson': contactPerson,
        'contactPhone': contactPhone,
        'whatsappIconPath': whatsappIconPath,
      };

  factory AppSettings.fromJson(Map<String, dynamic> j) {
    const d = AppSettings();
    return AppSettings(
      businessName: sn(j['businessName']) ?? d.businessName,
      address: s(j['address']),
      phone: s(j['phone']),
      logoPath: sn(j['logoPath']),
      invoicePrefix: sn(j['invoicePrefix']) ?? d.invoicePrefix,
      quotationPrefix: sn(j['quotationPrefix']) ?? d.quotationPrefix,
      purchasePrefix: sn(j['purchasePrefix']) ?? d.purchasePrefix,
      repairPrefix: sn(j['repairPrefix']) ?? d.repairPrefix,
      currencySymbol: sn(j['currencySymbol']) ?? d.currencySymbol,
      dateFormat: sn(j['dateFormat']) ?? d.dateFormat,
      receiptFormat: sn(j['receiptFormat']) ?? d.receiptFormat,
      printerName: sn(j['printerName']),
      labelWidthMm: (j['labelWidthMm'] as num?)?.toInt() ?? d.labelWidthMm,
      labelHeightMm: (j['labelHeightMm'] as num?)?.toInt() ?? d.labelHeightMm,
      defaultPaymentMethod: sn(j['defaultPaymentMethod']) ?? d.defaultPaymentMethod,
      lowStockAlerts: b(j['lowStockAlerts'], true),
      backupDirectory: sn(j['backupDirectory']),
      autoBackup: b(j['autoBackup'], true),
      backupKeep: (j['backupKeep'] as num?)?.toInt() ?? d.backupKeep,
      theme: sn(j['theme']) ?? d.theme,
      warrantyStartPolicy: enumByName(WarrantyStartPolicy.values, j['warrantyStartPolicy'], WarrantyStartPolicy.saleDate),
      quotationTerms: sn(j['quotationTerms']) ?? d.quotationTerms,
      quotationValidityDays: (j['quotationValidityDays'] as num?)?.toInt() ?? d.quotationValidityDays,
      email: s(j['email']),
      receiptFooter: sn(j['receiptFooter']) ?? d.receiptFooter,
      autoPrintReceipt: b(j['autoPrintReceipt']),
      labelShowPrice: b(j['labelShowPrice'], true),
      backupHour: (j['backupHour'] as num?)?.toInt() ?? 0,
      backupMinute: (j['backupMinute'] as num?)?.toInt() ?? 0,
      scannerSuffix: ScanSuffix.parse(j['scannerSuffix']).name,
      scannerKeyGapMs: (j['scannerKeyGapMs'] as num?)?.toInt() ?? d.scannerKeyGapMs,
      scannerMinLength: (j['scannerMinLength'] as num?)?.toInt() ?? d.scannerMinLength,
      scannerDuplicateMs: (j['scannerDuplicateMs'] as num?)?.toInt() ?? d.scannerDuplicateMs,
      contactPerson: sn(j['contactPerson']) ?? d.contactPerson,
      contactPhone: sn(j['contactPhone']) ?? d.contactPhone,
      whatsappIconPath: sn(j['whatsappIconPath']),
    );
  }

  AppSettings merge(Map<String, dynamic> changes) => AppSettings.fromJson({...toJson(), ...changes});
}
