import '../../core/errors.dart';
import '../../core/ids.dart';
import '../../core/money.dart';
import '../../data/store/data_store.dart';
import '../models/documents.dart';
import '../models/party.dart';
import '../models/user.dart';
import 'context.dart';
import 'sales_service.dart';

/// Quotations never touch stock or accounts. Converting one creates a draft
/// invoice which is completed through the normal sales flow.
class QuotationService {
  final ServiceContext ctx;
  final SalesService sales;
  QuotationService(this.ctx, this.sales);

  List<Quotation> list() => ctx.all(Boxes.quotations, Quotation.fromJson).toList()..sort((a, b) => b.date.compareTo(a.date));

  Quotation? byId(String id) {
    final j = ctx.store.read(Boxes.quotations, id);
    return j == null ? null : Quotation.fromJson(j);
  }

  Quotation newDraft({String? customerId, String customerName = ''}) {
    final st = ctx.settings;
    return Quotation(
      id: newId(),
      number: 'DRAFT',
      customerId: customerId,
      customerName: customerName,
      date: ctx.now(),
      expiryDate: ctx.now().add(Duration(days: st.quotationValidityDays)),
      items: const [],
      terms: st.quotationTerms,
      createdBy: ctx.userId,
    );
  }

  Future<Quotation> save(Quotation q) async {
    ctx.require(Permission.manageQuotations);
    if (q.items.isEmpty) throw const ValidationException('Add at least one product.');
    if (q.customerName.trim().isEmpty) throw const ValidationException('Customer name is required.');
    for (final it in q.items) {
      if (!it.qty.isPositive) throw const ValidationException('Quantity must be greater than zero.');
      if (it.net.isNegative) throw ValidationException('Discount on "${it.name}" is too large.');
    }
    if (q.total.isNegative) throw const ValidationException('Discount is larger than the total.');
    final existing = byId(q.id);
    if (existing != null && existing.status == QuotationStatus.converted) {
      throw const BusinessException('A converted quotation cannot be edited.');
    }
    final uow = ctx.uow();
    var toSave = q;
    if (existing == null) {
      toSave = Quotation.fromJson({...q.toJson(), 'number': ctx.nextNumber(uow, 'quotation', ctx.settings.quotationPrefix)});
    }
    uow.put(Boxes.quotations, toSave.id, toSave.toJson());
    ctx.audit(uow, existing == null ? 'create' : 'update', 'quotation', toSave.id, toSave.number);
    await uow.commit();
    return toSave;
  }

  Future<Quotation> setStatus(String id, QuotationStatus status) async {
    ctx.require(Permission.manageQuotations);
    final q = byId(id);
    if (q == null) throw const NotFoundException('Quotation not found.');
    if (q.status == QuotationStatus.converted) throw const BusinessException('Quotation is already converted.');
    if (status == QuotationStatus.converted) throw const BusinessException('Use "Convert to Invoice".');
    final updated = q.copyWith(status: status);
    final uow = ctx.uow()..put(Boxes.quotations, id, updated.toJson());
    ctx.audit(uow, 'status', 'quotation', id, status.name);
    await uow.commit();
    return updated;
  }

  /// Deletes a quotation. Quotations never touch stock or accounts, so this
  /// is safe, except for one converted to an invoice: that one is kept with
  /// the invoice.
  Future<void> delete(String id) async {
    ctx.require(Permission.manageQuotations);
    final q = byId(id);
    if (q == null) throw const NotFoundException('Quotation not found.');
    if (q.status == QuotationStatus.converted) {
      throw const BusinessException('This quotation was converted to an invoice and is kept with it.');
    }
    final uow = ctx.uow()..delete(Boxes.quotations, id);
    ctx.audit(uow, 'delete', 'quotation', id, q.number);
    await uow.commit();
  }

  /// Creates a draft invoice from an approved quotation.
  Future<Sale> convertToInvoice(String id) async {
    ctx.require(Permission.manageSales);
    final q = byId(id);
    if (q == null) throw const NotFoundException('Quotation not found.');
    final st = q.statusOn(ctx.now());
    if (st == QuotationStatus.converted) throw const BusinessException('Already converted.');
    if (st == QuotationStatus.expired) throw const BusinessException('This quotation has expired. Update the expiry date first.');
    if (st == QuotationStatus.rejected) throw const BusinessException('This quotation was rejected.');
    if (st != QuotationStatus.approved) throw const BusinessException('Mark the quotation as Approved before converting.');
    if (q.customerId != null) {
      final c = ctx.store.read(Boxes.customers, q.customerId!);
      if (c == null || !Party.fromJson(c).active) throw const BusinessException('Customer account is missing or inactive.');
    }
    final draft = Sale(
      id: newId(),
      number: 'DRAFT',
      customerId: q.customerId,
      customerName: q.customerName,
      date: ctx.now(),
      items: q.items.map((e) => SaleItem(productId: e.productId, name: e.name, qty: e.qty, unitPrice: e.unitPrice, discount: e.discount)).toList(),
      invoiceDiscount: q.invoiceDiscount,
      paidAtSale: const Money.zero(),
      notes: 'From quotation ${q.number}',
      createdBy: ctx.userId,
      createdAt: ctx.now(),
      quotationId: q.id,
    );
    final uow = ctx.uow()
      ..put(Boxes.sales, draft.id, draft.toJson())
      ..put(Boxes.quotations, q.id, q.copyWith(status: QuotationStatus.converted, convertedSaleId: draft.id).toJson());
    ctx.audit(uow, 'convert', 'quotation', q.id, draft.id);
    await uow.commit();
    return draft;
  }
}
