import '../../core/errors.dart';
import '../../core/ids.dart';
import '../../core/money.dart';
import '../../core/qty.dart';
import '../../data/store/data_store.dart';
import '../models/operations.dart';
import '../models/party.dart';
import '../models/product.dart';
import '../models/user.dart';
import 'context.dart';
import 'inventory_engine.dart';
import 'party_service.dart';
import 'serial_service.dart';

enum WarrantyState { active, expired, none, notSold }

class WarrantyInfo {
  final SerialRecord serial;
  final Product? product;
  final WarrantyState state;
  final int daysLeft;
  const WarrantyInfo(this.serial, this.product, this.state, this.daysLeft);
}

class WarrantyService {
  final ServiceContext ctx;
  final InventoryEngine inv;
  final SerialService serials;
  WarrantyService(this.ctx, this.inv, this.serials);

  WarrantyInfo? check(String serial) {
    final r = serials.find(serial);
    if (r == null) return null;
    return _info(r);
  }

  WarrantyInfo _info(SerialRecord r) {
    final p = ctx.derived('productsById', const [Boxes.products], () => {for (final x in ctx.all(Boxes.products, Product.fromJson)) x.id: x})[r.productId];
    if (r.saleId == null && r.status != SerialStatus.sold && r.status != SerialStatus.underRepair) {
      return WarrantyInfo(r, p, WarrantyState.notSold, 0);
    }
    if (r.warrantyExpiry == null) return WarrantyInfo(r, p, WarrantyState.none, 0);
    final now = ctx.now();
    final left = r.warrantyExpiry!.difference(now).inDays;
    return WarrantyInfo(r, p, r.warrantyActiveOn(now) ? WarrantyState.active : WarrantyState.expired, left < 0 ? 0 : left);
  }

  List<WarrantyInfo> all({WarrantyState? state}) => ctx.all(Boxes.serials, SerialRecord.fromJson)
      .where((r) => r.warrantyExpiry != null)
      .map(_info)
      .where((w) => state == null || w.state == state)
      .toList()
    ..sort((a, b) => a.serial.warrantyExpiry!.compareTo(b.serial.warrantyExpiry!));

  List<WarrantyInfo> expiringWithin(int days) => all(state: WarrantyState.active).where((w) => w.daysLeft <= days).toList();

  List<WarrantyClaim> claims() => ctx.all(Boxes.warrantyClaims, WarrantyClaim.fromJson).toList()..sort((a, b) => b.date.compareTo(a.date));

  Future<WarrantyClaim> openClaim(String serial, String issue) async {
    ctx.require(Permission.manageWarranty);
    if (issue.trim().isEmpty) throw const ValidationException('Describe the problem.');
    final uow = ctx.uow();
    final matches = serials.findAll(serial).where((x) => x.saleId != null).toList();
    if (matches.isEmpty) throw NotFoundException('No sold unit with serial "${normalizeCode(serial)}" was found.');
    if (matches.length > 1) throw const BusinessException('More than one sold unit has this serial. Open the claim from the exact unit.');
    final r = matches.first;
    final info = _info(r);
    if (info.state == WarrantyState.notSold) throw const BusinessException('This unit has not been sold.');
    if (info.state != WarrantyState.active) throw const BusinessException('Warranty is not active for this unit.');
    if (claims().any((c) => c.serial == r.key && (c.status == ClaimStatus.open || c.status == ClaimStatus.sentForRepair))) {
      throw const BusinessException('There is already an open claim for this serial.');
    }
    final c = WarrantyClaim(
      id: newId(),
      number: ctx.nextNumber(uow, 'warranty', 'WC'),
      serial: r.key,
      productId: r.productId,
      customerId: r.customerId,
      saleId: r.saleId,
      date: ctx.now(),
      issue: issue.trim(),
      userId: ctx.userId,
    );
    uow.put(Boxes.warrantyClaims, c.id, c.toJson());
    serials.save(uow, r.transition(SerialStatus.underRepair, at: ctx.now(), note: 'Warranty claim ${c.number}', refType: 'warranty', refId: c.id, userId: ctx.userId));
    ctx.audit(uow, 'open', 'warranty_claim', c.id, r.display);
    await uow.commit();
    return c;
  }

  WarrantyClaim _claim(UnitOfWork uow, String id) {
    final j = uow.read(Boxes.warrantyClaims, id);
    if (j == null) throw const NotFoundException('Claim not found.');
    return WarrantyClaim.fromJson(j);
  }

  /// Unit repaired and returned to the customer; warranty continues.
  Future<void> resolveRepaired(String claimId, String resolution) async {
    ctx.require(Permission.manageWarranty);
    final uow = ctx.uow();
    final c = _claim(uow, claimId);
    final r = serials.resolve(uow, c.serial, c.productId);
    uow.put(Boxes.warrantyClaims, c.id, c.copyWith(status: ClaimStatus.repaired, resolution: resolution).toJson());
    serials.save(uow, r.transition(SerialStatus.sold, at: ctx.now(), note: 'Repaired under ${c.number}', refType: 'warranty', refId: c.id, userId: ctx.userId));
    ctx.audit(uow, 'repaired', 'warranty_claim', c.id, resolution);
    await uow.commit();
  }

  Future<void> reject(String claimId, String reason) async {
    ctx.require(Permission.manageWarranty);
    final uow = ctx.uow();
    final c = _claim(uow, claimId);
    final r = serials.resolve(uow, c.serial, c.productId);
    uow.put(Boxes.warrantyClaims, c.id, c.copyWith(status: ClaimStatus.rejected, resolution: reason).toJson());
    serials.save(uow, r.transition(SerialStatus.sold, at: ctx.now(), note: 'Claim rejected: $reason', refType: 'warranty', refId: c.id, userId: ctx.userId));
    ctx.audit(uow, 'rejected', 'warranty_claim', c.id, reason);
    await uow.commit();
  }

  /// Replaces the faulty unit with a new one from stock. The new unit takes
  /// over the remaining warranty of the old one; the faulty unit goes to
  /// damaged stock (it can later be returned to the supplier).
  Future<void> replace(String claimId, String newSerial, String resolution) async {
    ctx.require(Permission.manageWarranty);
    final uow = ctx.uow();
    final c = _claim(uow, claimId);
    final old = serials.resolve(uow, c.serial, c.productId);
    final repl = serials.requireAll(uow, [newSerial], old.productId, {SerialStatus.inStock}, 'replacement').first;
    final ref = c.id;
    inv.stockOut(uow, productId: old.productId, qty: const Qty.one(), type: 'warrantyReplacement', refType: 'warranty', refId: ref, reason: c.number, units: [repl]);
    inv.changeBucket(uow, old.productId, StockBucket.damaged, const Qty.one(), 'warrantyReplacement', 'warranty', ref, 'Faulty unit ${old.display}');
    serials.save(uow,
        old.transition(SerialStatus.damaged, at: ctx.now(), note: 'Replaced by ${repl.display} (${c.number})', refType: 'warranty', refId: ref, userId: ctx.userId, clearCustomer: true));
    serials.save(
        uow,
        repl.transition(SerialStatus.sold,
            at: ctx.now(),
            note: 'Warranty replacement for ${old.display}',
            refType: 'warranty',
            refId: ref,
            userId: ctx.userId,
            customerId: old.customerId,
            saleId: old.saleId,
            warrantyStart: old.warrantyStart,
            warrantyExpiry: old.warrantyExpiry));
    uow.put(Boxes.warrantyClaims, c.id, c.copyWith(status: ClaimStatus.replaced, resolution: resolution, replacementSerial: repl.key).toJson());
    ctx.audit(uow, 'replaced', 'warranty_claim', c.id, '${old.display} -> ${repl.display}');
    await uow.commit();
  }
}

class RepairService {
  final ServiceContext ctx;
  final InventoryEngine inv;
  final PartyService parties;
  final SerialService serials;
  RepairService(this.ctx, this.inv, this.parties, this.serials);

  List<RepairJob> list({bool openOnly = false, String? technicianId}) => ctx.all(Boxes.repairs, RepairJob.fromJson)
      .where((r) => (!openOnly || r.status.isOpen) && (technicianId == null || r.technicianId == technicianId))
      .toList()
    ..sort((a, b) => b.receivedDate.compareTo(a.receivedDate));

  /// Technicians see only their assigned jobs.
  List<RepairJob> visibleJobs() {
    final u = ctx.session.requireUser;
    if (u.can(Permission.manageRepairs)) return list();
    if (u.can(Permission.viewAssignedRepairs) && u.employeeId != null) return list(technicianId: u.employeeId);
    throw const PermissionException();
  }

  RepairJob _job(UnitOfWork uow, String id) {
    final j = uow.read(Boxes.repairs, id);
    if (j == null) throw const NotFoundException('Repair job not found.');
    return RepairJob.fromJson(j);
  }

  Future<RepairJob> receive({
    String? customerId,
    required String customerName,
    String customerPhone = '',
    String? productId,
    required String productName,
    String serial = '',
    required String reportedIssue,
    String physicalCondition = '',
    String? technicianId,
    Money serviceCharges = const Money.zero(),
  }) async {
    ctx.require(Permission.manageRepairs);
    if (customerName.trim().isEmpty) throw const ValidationException('Customer name is required.');
    if (productName.trim().isEmpty) throw const ValidationException('Product is required.');
    if (reportedIssue.trim().isEmpty) throw const ValidationException('Describe the reported issue.');
    final uow = ctx.uow();
    var underWarranty = false;
    final sn = normalizeCode(serial);
    if (sn.isNotEmpty) {
      underWarranty = serials.findAll(sn).any((r) => r.warrantyActiveOn(ctx.now()) && (customerId == null || r.customerId == customerId));
    }
    final job = RepairJob(
      id: newId(),
      number: ctx.nextNumber(uow, 'repair', ctx.settings.repairPrefix),
      customerId: customerId,
      customerName: customerName.trim(),
      customerPhone: customerPhone.trim(),
      productId: productId,
      productName: productName.trim(),
      serial: sn,
      receivedDate: ctx.now(),
      reportedIssue: reportedIssue.trim(),
      physicalCondition: physicalCondition.trim(),
      technicianId: technicianId,
      serviceCharges: serviceCharges,
      underWarranty: underWarranty,
      history: [RepairStatusEvent(at: ctx.now(), status: RepairStatus.received, userId: ctx.userId)],
    );
    uow.put(Boxes.repairs, job.id, job.toJson());
    ctx.audit(uow, 'receive', 'repair', job.id, job.number);
    await uow.commit();
    return job;
  }

  Future<RepairJob> updateStatus(String id, RepairStatus status, {String note = '', String? technicianId, String? repairNotes, Money? serviceCharges}) async {
    final u = ctx.session.requireUser;
    final uow = ctx.uow();
    var job = _job(uow, id);
    final isAssignedTech = u.can(Permission.viewAssignedRepairs) && u.employeeId != null && u.employeeId == job.technicianId;
    if (!u.can(Permission.manageRepairs) && !isAssignedTech) throw const PermissionException();
    if (job.status == RepairStatus.delivered) throw const BusinessException('This job is already delivered.');
    if (status == RepairStatus.delivered) throw const BusinessException('Use "Deliver" to close the job.');
    job = job.copyWith(
      status: status,
      technicianId: u.can(Permission.manageRepairs) ? technicianId : null,
      repairNotes: repairNotes,
      serviceCharges: u.can(Permission.manageRepairs) ? serviceCharges : null,
      completionDate: (status == RepairStatus.repaired || status == RepairStatus.notRepairable) ? ctx.now() : null,
      history: [...job.history, RepairStatusEvent(at: ctx.now(), status: status, note: note, userId: ctx.userId)],
    );
    uow.put(Boxes.repairs, id, job.toJson());
    ctx.audit(uow, 'status', 'repair', id, status.name);
    await uow.commit();
    return job;
  }

  /// Uses a part from stock (FIFO cost) and adds it to the job.
  Future<RepairJob> addPart(String id, String productId, Qty qty, Money priceEach) async {
    ctx.require(Permission.manageRepairs);
    final uow = ctx.uow();
    var job = _job(uow, id);
    if (job.status == RepairStatus.delivered) throw const BusinessException('This job is already delivered.');
    final p = inv.product(uow, productId);
    if (p.requiresSerial) throw const BusinessException('Serial-tracked items cannot be used as repair parts. Use a warranty replacement or sale.');
    final cost = inv.stockOut(uow, productId: productId, qty: qty, type: 'repairPart', refType: 'repair', refId: id, reason: job.number);
    job = job.copyWith(parts: [...job.parts, RepairPart(productId: productId, name: p.name, qty: qty, cost: cost, price: priceEach.timesQty(qty))]);
    uow.put(Boxes.repairs, id, job.toJson());
    ctx.audit(uow, 'add_part', 'repair', id, '${p.name} x${qty.format()}');
    await uow.commit();
    return job;
  }

  /// Delivers the job: posts charges to the customer account (if any) and
  /// records payment received.
  Future<RepairJob> deliver(String id, {Money paid = const Money.zero(), PaymentMethod method = PaymentMethod.cash}) async {
    ctx.require(Permission.manageRepairs);
    final uow = ctx.uow();
    var job = _job(uow, id);
    if (job.status == RepairStatus.delivered) throw const BusinessException('Already delivered.');
    final charges = job.totalCharges;
    if (paid > charges) throw const ValidationException('Paid amount is more than the charges.');
    if (job.customerId == null && paid != charges) {
      throw const ValidationException('Unpaid charges need a customer account. Take full payment or link a customer.');
    }
    if (job.customerId != null && charges.isPositive) {
      parties.post(uow,
          kind: PartyKind.customer, partyId: job.customerId!, type: LedgerType.repairCharge, debit: charges, refType: 'repair', refId: id, refNumber: job.number);
    }
    if (paid.isPositive) {
      parties.recordPayment(uow,
          kind: job.customerId == null ? null : PartyKind.customer,
          partyId: job.customerId,
          amount: paid,
          method: method,
          direction: PaymentDirection.received,
          refType: 'repair',
          refId: id,
          refNumber: job.number);
    }
    job = job.copyWith(
      status: RepairStatus.delivered,
      deliveryDate: ctx.now(),
      chargesPosted: true,
      history: [...job.history, RepairStatusEvent(at: ctx.now(), status: RepairStatus.delivered, userId: ctx.userId)],
    );
    uow.put(Boxes.repairs, id, job.toJson());
    ctx.audit(uow, 'deliver', 'repair', id, charges.format());
    await uow.commit();
    return job;
  }
}
