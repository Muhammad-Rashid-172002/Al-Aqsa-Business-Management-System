// Delete / archive / cancel actions used by the ⋮ row menus.
//
// Every action first shows [confirmDelete] with the record's name. Records
// linked to stock, money or history are never erased: products, customers,
// suppliers and technicians with history are archived; completed invoices
// and purchases are cancelled (stock and accounts reversed by new entries,
// the document kept); payments are voided with a reversal entry; expenses
// are soft-deleted and can be restored.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/qty.dart';
import '../domain/models/documents.dart';
import '../domain/models/expense.dart';
import '../domain/models/party.dart';
import '../domain/models/product.dart';
import '../domain/models/user.dart';
import '../domain/services/permanent_delete_service.dart';
import 'permanent_delete_flow.dart';
import 'providers.dart';
import 'widgets/common.dart';

const _archiveNote = 'It has history, so it will be archived: hidden from lists and pickers, '
    'but kept in invoices, ledgers and reports. You can restore it later with "Show inactive".';

bool _canErase(WidgetRef ref) => ref.read(servicesProvider).ctx.can(Permission.permanentDelete);

Future<void> deleteProductRecord(BuildContext context, WidgetRef ref, Product p) async {
  final cat = ref.read(servicesProvider).catalog;
  if (_canErase(ref)) {
    return permanentDeleteFlow(context, ref, DeletableKind.product, p.id, archive: p.archived ? null : () async => cat.deleteOrArchive(p.id), archiveLabel: 'Archive product instead');
  }
  final archive = cat.hasTransactions(p.id) || Qty.sum(StockBucket.values.map(p.bucket)).milli != 0;
  final ok = await confirmDelete(
    context,
    name: p.sku.isEmpty ? p.name : '${p.name}  (${p.sku})',
    note: archive
        ? 'This product has stock or transaction history, so it will be archived: hidden from lists and the POS, '
            'but kept in invoices, purchases and reports. You can restore it with "Show archived".'
        : 'It has no stock or history and will be removed permanently.',
  );
  if (ok == null || !context.mounted) return;
  await runAction(context, () async {
    final archived = await cat.deleteOrArchive(p.id);
    if (context.mounted) showToast(context, archived ? '"${p.name}" archived' : '"${p.name}" deleted');
  });
}

Future<void> deletePartyRecord(BuildContext context, WidgetRef ref, Party p) async {
  final parties = ref.read(servicesProvider).parties;
  if (_canErase(ref)) {
    return permanentDeleteFlow(context, ref, p.kind == PartyKind.customer ? DeletableKind.customer : DeletableKind.supplier, p.id,
        archive: p.active ? () async => parties.deleteOrArchive(p.kind, p.id) : null, archiveLabel: 'Archive instead');
  }
  final archive = !p.balance.isZero || parties.hasHistory(p.kind, p.id);
  final word = p.kind == PartyKind.customer ? 'customer' : 'supplier';
  final ok = await confirmDelete(
    context,
    name: p.phone.isEmpty ? p.name : '${p.name}  •  ${p.phone}',
    note: archive
        ? '${p.balance.isZero ? '' : 'Balance ${p.balance.format()} is not zero. '}$_archiveNote'
        : 'This $word has no transactions and will be removed permanently.',
  );
  if (ok == null || !context.mounted) return;
  await runAction(context, () async {
    final archived = await parties.deleteOrArchive(p.kind, p.id);
    if (context.mounted) showToast(context, archived ? '"${p.name}" archived' : '"${p.name}" deleted');
  });
}

Future<void> deleteCategoryRecord(BuildContext context, WidgetRef ref, ProductCategory x, {int productCount = 0}) async {
  if (_canErase(ref)) return permanentDeleteFlow(context, ref, DeletableKind.category, x.id);
  final ok = await confirmDelete(
    context,
    name: x.name,
    note: productCount > 0
        ? 'This category has $productCount product(s). Move them to another category first; the delete will be refused until then.'
        : 'The empty category will be removed.',
  );
  if (ok == null || !context.mounted) return;
  await runAction(context, () => ref.read(servicesProvider).catalog.deleteCategory(x.id), success: 'Category "${x.name}" deleted');
}

Future<void> deleteExpenseRecord(BuildContext context, WidgetRef ref, Expense e) async {
  if (_canErase(ref)) return permanentDeleteFlow(context, ref, DeletableKind.expense, e.id);
  final reason = await confirmDelete(
    context,
    name: '${e.number}  •  ${e.title}  •  ${e.amount.format()}',
    note: 'It will no longer count in reports. It stays in the history and can be restored with "Show deleted".',
    askReason: true,
  );
  if (reason == null || !context.mounted) return;
  await runAction(context, () => ref.read(servicesProvider).expenses.delete(e.id, reason: reason), success: 'Expense ${e.number} deleted');
}

Future<void> deleteQuotationRecord(BuildContext context, WidgetRef ref, Quotation q) async {
  if (_canErase(ref)) return permanentDeleteFlow(context, ref, DeletableKind.quotation, q.id);
  final ok = await confirmDelete(
    context,
    name: '${q.number}  •  ${q.customerName}  •  ${q.total.format()}',
    note: 'Quotations do not affect stock or accounts. It will be removed permanently.',
  );
  if (ok == null || !context.mounted) return;
  await runAction(context, () => ref.read(servicesProvider).quotations.delete(q.id), success: 'Quotation ${q.number} deleted');
}

/// Draft invoices are deleted; completed invoices are cancelled.
Future<void> deleteSaleRecord(BuildContext context, WidgetRef ref, Sale s) async {
  final app = ref.read(servicesProvider);
  final name = '${s.number}  •  ${s.customerName}  •  ${s.total.format()}';
  if (s.status == DocStatus.draft && _canErase(ref)) return permanentDeleteFlow(context, ref, DeletableKind.draftInvoice, s.id);
  if (s.status == DocStatus.draft) {
    final ok = await confirmDelete(context, name: name, note: 'This is an unsaved draft. It will be removed permanently.');
    if (ok == null || !context.mounted) return;
    await runAction(context, () => app.sales.deleteDraft(s.id), success: 'Draft ${s.number} deleted');
    return;
  }
  final reason = await confirmDelete(
    context,
    name: name,
    note: 'Completed invoices are never erased. It will be CANCELLED: stock, serial numbers and the customer account are '
        'reversed by new entries and the invoice is kept, marked cancelled.',
    reasonRequired: true,
    confirmLabel: 'Delete (cancel invoice)',
  );
  if (reason == null || !context.mounted) return;
  await runAction(context, () => app.sales.cancel(s.id, reason), success: 'Invoice ${s.number} cancelled. Stock and account reversed.');
}

Future<void> deletePurchaseRecord(BuildContext context, WidgetRef ref, Purchase p, String supplierName) async {
  final reason = await confirmDelete(
    context,
    name: '${p.number}  •  $supplierName  •  ${p.total.format()}',
    note: 'Completed purchases are never erased. It will be CANCELLED (stock and supplier account reversed, the purchase kept). '
        'This is refused if any of its stock has already been sold or used.',
    reasonRequired: true,
    confirmLabel: 'Delete (cancel purchase)',
  );
  if (reason == null || !context.mounted) return;
  await runAction(context, () => ref.read(servicesProvider).purchases.cancel(p.id, reason), success: 'Purchase ${p.number} cancelled');
}

Future<void> deletePaymentRecord(BuildContext context, WidgetRef ref, Payment pay, {String partyName = ''}) async {
  final reason = await confirmDelete(
    context,
    name: '${pay.number}${partyName.isEmpty ? '' : '  •  $partyName'}  •  ${pay.amount.format()}',
    note: 'Payments are never erased. It will be VOIDED: a reversal entry is posted to the ledger and the payment is kept, marked void.',
    reasonRequired: true,
    confirmLabel: 'Delete (void payment)',
  );
  if (reason == null || !context.mounted) return;
  await runAction(context, () => ref.read(servicesProvider).parties.voidPayment(pay.id, reason), success: 'Payment ${pay.number} voided (reversal entry posted)');
}

Future<void> deleteTechnicianRecord(BuildContext context, WidgetRef ref, Employee t) async {
  final tech = ref.read(servicesProvider).technicians;
  if (_canErase(ref)) {
    return permanentDeleteFlow(context, ref, DeletableKind.technician, t.id, archive: t.active ? () async => tech.deleteOrArchive(t.id) : null, archiveLabel: 'Archive (deactivate) instead');
  }
  final ok = await confirmDelete(
    context,
    name: t.phone.isEmpty ? t.name : '${t.name}  •  ${t.phone}',
    note: 'A technician with material or repair history is archived (marked inactive, login disabled) and kept in reports. '
        'One with no history is removed. Refused while the technician still holds material.',
  );
  if (ok == null || !context.mounted) return;
  await runAction(context, () async {
    final archived = await tech.deleteOrArchive(t.id);
    if (context.mounted) showToast(context, archived ? '"${t.name}" archived' : '"${t.name}" deleted');
  });
}
