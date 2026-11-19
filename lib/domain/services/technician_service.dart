import '../../core/errors.dart';
import '../../core/ids.dart';
import '../../core/money.dart';
import '../../core/qty.dart';
import '../../data/store/data_store.dart';
import '../models/operations.dart';
import '../models/product.dart';
import '../models/user.dart';
import 'auth_service.dart';
import 'context.dart';
import 'inspection_service.dart';
import 'inventory_engine.dart';
import 'serial_service.dart';

class IssueLine {
  final String productId;
  final Qty qty;
  final List<String> serials;
  const IssueLine({required this.productId, required this.qty, this.serials = const []});
}

class TechnicianSummary {
  final Employee technician;
  final Qty issued;
  final Qty returnedUnused; // returned unused straight to stock
  final Qty installed;
  final Qty returnedForInspection; // used / damaged / faulty -> owner inspection
  final Qty remaining;
  final Money remainingValue;
  final List<TechHolding> holdings;
  const TechnicianSummary({
    required this.technician,
    required this.issued,
    required this.returnedUnused,
    required this.installed,
    required this.returnedForInspection,
    required this.remaining,
    required this.remainingValue,
    required this.holdings,
  });
}

/// Material issued to technicians, returned, and installed at customer sites.
///
/// Issued stock is NOT a sale: it moves from "available" to "issued" and the
/// technician is accountable for it until it is returned or recorded as
/// installed. Installed material is invoiced to the customer later (its cost
/// becomes COGS on that invoice).
class TechnicianService {
  final ServiceContext ctx;
  final InventoryEngine inv;
  final SerialService serials;
  final AuthService auth;
  final InspectionService inspections;
  TechnicianService(this.ctx, this.inv, this.serials, this.auth, this.inspections);

  List<Employee> technicians({bool includeInactive = false}) =>
      ctx.all(Boxes.employees, Employee.fromJson).where((e) => includeInactive || e.active).toList()
        ..sort((a, b) => a.name.compareTo(b.name));

  Employee requireTech(UnitOfWork uow, String id) {
    final j = uow.read(Boxes.employees, id);
    if (j == null) throw const NotFoundException('Technician not found.');
    return Employee.fromJson(j);
  }

  /// Creates a technician profile and (optionally) a login account.
  Future<Employee> create({
    required String name,
    String phone = '',
    String address = '',
    DateTime? joiningDate,
    String notes = '',
    String? username,
    String? password,
  }) async {
    ctx.require(Permission.manageTechnicians);
    if (name.trim().isEmpty) throw const ValidationException('Name is required.');
    final uow = ctx.uow();
    final code = ctx.nextNumber(uow, 'employee', 'EMP', pad: 3);
    var emp = Employee(id: newId(), code: code, name: name.trim(), phone: phone.trim(), address: address.trim(), joiningDate: joiningDate ?? ctx.now(), notes: notes);
    if (username != null && username.trim().isNotEmpty) {
      final u = await auth.createUser(
          username: username, password: password ?? '', displayName: emp.name, role: UserRole.technician, employeeId: emp.id, uow: uow);
      emp = emp.copyWith(userId: u.id);
    }
    uow.put(Boxes.employees, emp.id, emp.toJson());
    ctx.audit(uow, 'create', 'technician', emp.id, emp.name);
    await uow.commit();
    return emp;
  }

  Future<Employee> update(Employee e) async {
    ctx.require(Permission.manageTechnicians);
    final uow = ctx.uow();
    requireTech(uow, e.id);
    uow.put(Boxes.employees, e.id, e.toJson());
    if (!e.active && e.userId != null) {
      final uj = uow.read(Boxes.users, e.userId!);
      if (uj != null) uow.put(Boxes.users, e.userId!, AppUser.fromJson(uj).copyWith(active: false).toJson());
    }
    ctx.audit(uow, 'update', 'technician', e.id);
    await uow.commit();
    return e;
  }

  /// Deletes a technician with no history; archives (deactivates, login
  /// disabled) one with material transactions or repair jobs. Refused while
  /// the technician still holds material. Returns true when archived.
  Future<bool> deleteOrArchive(String id) async {
    ctx.require(Permission.manageTechnicians);
    final uow = ctx.uow();
    final e = requireTech(uow, id);
    final holds = ctx.store.values(Boxes.techHoldings).map(TechHolding.fromJson).where((h) => h.technicianId == id && h.qty.milli != 0);
    if (holds.isNotEmpty) {
      throw BusinessException('${e.name} still holds material. Return it or record it as installed first.');
    }
    final history = ctx.store.values(Boxes.techTxns).any((j) => j['technicianId'] == id) || ctx.store.values(Boxes.repairs).any((j) => j['technicianId'] == id);
    if (e.userId != null) {
      final uj = uow.read(Boxes.users, e.userId!);
      if (uj != null) uow.put(Boxes.users, e.userId!, AppUser.fromJson(uj).copyWith(active: false).toJson());
    }
    if (history) {
      uow.put(Boxes.employees, id, e.copyWith(active: false).toJson());
      ctx.audit(uow, 'archive', 'technician', id, e.name);
      await uow.commit();
      return true;
    }
    uow.delete(Boxes.employees, id);
    ctx.audit(uow, 'delete', 'technician', id, e.name);
    await uow.commit();
    return false;
  }

  TechHolding _holding(UnitOfWork uow, String techId, String productId) {
    final j = uow.read(Boxes.techHoldings, TechHolding.keyFor(techId, productId));
    return j == null ? TechHolding(technicianId: techId, productId: productId, qty: const Qty.zero(), cost: const Money.zero()) : TechHolding.fromJson(j);
  }

  void _saveHolding(UnitOfWork uow, TechHolding h) {
    if (h.qty.isZero) {
      uow.delete(Boxes.techHoldings, h.key);
    } else {
      uow.put(Boxes.techHoldings, h.key, h.toJson());
    }
  }

  void _requireSelfOrManager(String techId, Permission managerPerm) {
    final u = ctx.session.requireUser;
    if (u.can(managerPerm)) return;
    if (u.can(Permission.submitOwnUsage) && u.employeeId == techId) return;
    throw const PermissionException();
  }

  /// Issues stock to a technician.
  Future<List<TechTxn>> issue({required String technicianId, required List<IssueLine> lines, String jobRef = '', String notes = ''}) async {
    ctx.require(Permission.issueStock);
    if (lines.isEmpty) throw const ValidationException('Add at least one product.');
    final uow = ctx.uow();
    final tech = requireTech(uow, technicianId);
    if (!tech.active) throw const BusinessException('This technician account is inactive.');
    final ref = newId();
    final out = <TechTxn>[];
    for (final l in lines) {
      final p = inv.product(uow, l.productId);
      inv.checkQty(p, l.qty);
      var recs = <SerialRecord>[];
      if (p.requiresSerial) {
        final raw = serials.normalizeList(l.serials, expectedQty: l.qty.wholeUnits, productName: p.name);
        recs = serials.requireAll(uow, raw, p.id, {SerialStatus.inStock}, 'issuing');
      }
      final sers = recs.map((r) => r.key).toList();
      final cost = inv.stockOut(uow, productId: p.id, qty: l.qty, type: 'techIssue', refType: 'tech_issue', refId: ref, reason: tech.name, units: recs);
      inv.changeBucket(uow, p.id, StockBucket.issued, l.qty, 'techIssue', 'tech_issue', ref, tech.name, cost);
      final h = _holding(uow, technicianId, p.id);
      _saveHolding(uow, TechHolding(technicianId: technicianId, productId: p.id, qty: h.qty + l.qty, cost: h.cost + cost));
      for (final r in recs) {
        serials.save(uow,
            r.transition(SerialStatus.issuedToTechnician, at: ctx.now(), note: 'Issued to ${tech.name}', refType: 'tech_issue', refId: ref, userId: ctx.userId, technicianId: technicianId));
      }
      final t = TechTxn(
          id: newId(),
          technicianId: technicianId,
          type: TechTxnType.issue,
          at: ctx.now(),
          productId: p.id,
          productName: p.name,
          qty: l.qty,
          cost: cost,
          serials: sers,
          jobRef: jobRef,
          notes: notes,
          userId: ctx.userId);
      uow.put(Boxes.techTxns, t.id, t.toJson());
      out.add(t);
    }
    ctx.audit(uow, 'issue', 'technician', technicianId, '${lines.length} line(s) $jobRef');
    await uow.commit();
    return out;
  }

  /// Technician returns material. Unused goes straight back to sellable
  /// stock; Used, Damaged and Faulty go to the owner's inspection queue.
  Future<TechTxn> returnMaterial({
    required String technicianId,
    required String productId,
    required Qty qty,
    required TechTxnType type,
    List<String> serialNumbers = const [],
    String reason = '',
    DateTime? date,
  }) async {
    _requireSelfOrManager(technicianId, Permission.issueStock);
    if (!type.isReturn) throw ArgumentError('Not a return type');
    final uow = ctx.uow();
    final tech = requireTech(uow, technicianId);
    final p = inv.product(uow, productId);
    inv.checkQty(p, qty);
    final h = _holding(uow, technicianId, productId);
    if (qty > h.qty) throw StockException('${tech.name} holds only ${h.qty.format()} ${p.unit} of "${p.name}".');
    if (type != TechTxnType.returnUnused && reason.trim().isEmpty) throw const ValidationException('Please describe the condition / reason.');
    var recs = <SerialRecord>[];
    final ref = newId();
    if (p.requiresSerial) {
      final raw = serials.normalizeList(serialNumbers, expectedQty: qty.wholeUnits, productName: p.name);
      recs = serials.requireAll(uow, raw, p.id, {SerialStatus.issuedToTechnician}, 'return');
      for (final r in recs) {
        if (r.technicianId != technicianId) throw ValidationException('Serial "${r.display}" is not issued to ${tech.name}.');
      }
    }
    // Serial units carry their own batch cost; other items use the average.
    final cost = _cappedUnitsCost(recs, h) ?? h.costOf(qty);
    _saveHolding(uow, TechHolding(technicianId: technicianId, productId: productId, qty: h.qty - qty, cost: h.cost - cost));
    inv.changeBucket(uow, productId, StockBucket.issued, -qty, 'techReturn', 'tech_return', ref, '${type.label} - ${tech.name}', cost);
    String? inspectionId;
    if (type == TechTxnType.returnUnused) {
      if (recs.isNotEmpty) {
        inv.stockInUnits(uow, productId: productId, units: recs, fallbackTotal: cost, type: 'techReturn', refType: 'tech_return', refId: ref, reason: reason);
      } else {
        inv.stockIn(uow, productId: productId, qty: qty, unitCost: cost.perUnit(qty), totalCost: cost, type: 'techReturn', refType: 'tech_return', refId: ref, reason: reason);
      }
      for (final r in recs) {
        serials.save(uow, r.transition(SerialStatus.inStock, at: ctx.now(), note: 'Returned unused by ${tech.name}', refType: 'tech_return', refId: ref, userId: ctx.userId, clearTechnician: true));
      }
    } else {
      final cond = switch (type) { TechTxnType.returnUsed => 'used', TechTxnType.returnDamaged => 'damaged', _ => 'faulty' };
      inspectionId = inspections
          .enqueue(uow, product: p, qty: qty, cost: cost, serialRecords: recs, sourceType: 'tech_return', sourceId: ref, technicianId: technicianId, condition: cond, reason: reason)
          .id;
    }
    final t = TechTxn(
        id: ref,
        technicianId: technicianId,
        type: type,
        at: date ?? ctx.now(),
        productId: productId,
        productName: p.name,
        qty: qty,
        cost: cost,
        serials: recs.map((r) => r.key).toList(),
        reason: reason,
        userId: ctx.userId,
        inspectionId: inspectionId);
    uow.put(Boxes.techTxns, t.id, t.toJson());
    ctx.audit(uow, 'tech_return', 'technician', technicianId, '${p.name} x${qty.format()} ${type.name}');
    await uow.commit();
    return t;
  }

  /// Records material installed at a customer site (not yet invoiced).
  Future<TechTxn> recordInstalled({
    required String technicianId,
    required String productId,
    required Qty qty,
    List<String> serialNumbers = const [],
    String? customerId,
    String jobRef = '',
    String notes = '',
    DateTime? date,
  }) async {
    _requireSelfOrManager(technicianId, Permission.issueStock);
    final uow = ctx.uow();
    final tech = requireTech(uow, technicianId);
    final p = inv.product(uow, productId);
    inv.checkQty(p, qty);
    final h = _holding(uow, technicianId, productId);
    if (qty > h.qty) throw StockException('${tech.name} holds only ${h.qty.format()} ${p.unit} of "${p.name}".');
    final ref = newId();
    var sers = <String>[];
    var recs = <SerialRecord>[];
    if (p.requiresSerial) {
      final raw = serials.normalizeList(serialNumbers, expectedQty: qty.wholeUnits, productName: p.name);
      recs = serials.requireAll(uow, raw, p.id, {SerialStatus.issuedToTechnician}, 'installation');
      sers = recs.map((r) => r.key).toList();
      for (final r in recs) {
        if (r.technicianId != technicianId) throw ValidationException('Serial "${r.serial}" is not issued to ${tech.name}.');
        serials.save(uow,
            r.transition(SerialStatus.installed,
                at: date ?? ctx.now(), note: 'Installed by ${tech.name} $jobRef', refType: 'tech_install', refId: ref, userId: ctx.userId, customerId: customerId));
      }
    }
    final cost = _cappedUnitsCost(recs, h) ?? h.costOf(qty);
    _saveHolding(uow, TechHolding(technicianId: technicianId, productId: productId, qty: h.qty - qty, cost: h.cost - cost));
    inv.changeBucket(uow, productId, StockBucket.issued, -qty, 'techInstalled', 'tech_install', ref, '${tech.name} $jobRef', cost);
    final t = TechTxn(
        id: ref,
        technicianId: technicianId,
        type: TechTxnType.installed,
        at: date ?? ctx.now(),
        productId: productId,
        productName: p.name,
        qty: qty,
        cost: cost,
        serials: sers,
        jobRef: jobRef,
        customerId: customerId,
        notes: notes,
        userId: ctx.userId);
    uow.put(Boxes.techTxns, t.id, t.toJson());
    ctx.audit(uow, 'tech_install', 'technician', technicianId, '${p.name} x${qty.format()} $jobRef');
    await uow.commit();
    return t;
  }

  List<TechTxn> history({String? technicianId, String? productId}) =>
      ctx.all(Boxes.techTxns, TechTxn.fromJson).where((t) {
        if (technicianId != null && t.technicianId != technicianId) return false;
        if (productId != null && t.productId != productId) return false;
        return true;
      }).toList()
        ..sort((a, b) => b.at.compareTo(a.at));

  List<TechHolding> holdings({String? technicianId}) =>
      ctx.all(Boxes.techHoldings, TechHolding.fromJson).where((h) => technicianId == null || h.technicianId == technicianId).toList();

  /// Installed material that has not been invoiced yet.
  List<TechTxn> pendingInstallations({String? customerId}) => history()
      .where((t) => t.type == TechTxnType.installed && t.invoicedSaleId == null && (customerId == null || t.customerId == customerId))
      .toList();

  TechnicianSummary summary(String technicianId) {
    final tech = Employee.fromJson(ctx.store.read(Boxes.employees, technicianId)!);
    var issued = const Qty.zero(), back = const Qty.zero(), installed = const Qty.zero(), inspect = const Qty.zero();
    for (final t in history(technicianId: technicianId)) {
      switch (t.type) {
        case TechTxnType.issue:
          issued += t.qty;
        case TechTxnType.returnUnused:
          back += t.qty;
        case TechTxnType.returnUsed:
        case TechTxnType.returnDamaged:
        case TechTxnType.returnFaulty:
          inspect += t.qty;
        case TechTxnType.installed:
          installed += t.qty;
      }
    }
    final hs = holdings(technicianId: technicianId);
    return TechnicianSummary(
      technician: tech,
      issued: issued,
      returnedUnused: back,
      installed: installed,
      returnedForInspection: inspect,
      remaining: Qty.sum(hs.map((h) => h.qty)),
      remainingValue: Money.sum(hs.map((h) => h.cost)),
      holdings: hs,
    );
  }
}

/// The serial units' own batch cost, never more than the holding's cost
/// (null when the units have no recorded cost).
Money? _cappedUnitsCost(List<SerialRecord> recs, TechHolding h) {
  final c = InventoryEngine.unitsCost(recs);
  if (c == null) return null;
  return c > h.cost ? h.cost : c;
}
