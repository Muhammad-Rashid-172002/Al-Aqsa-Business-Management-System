import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors.dart';
import '../../core/money.dart';
import '../../domain/models/documents.dart';
import '../../domain/models/party.dart';
import '../../domain/models/user.dart';
import '../../domain/services/party_service.dart';
import '../../export/tabular.dart';
import '../../printing/pdf_docs.dart';
import '../customer_statement_flow.dart';
import '../edit_invoice_dialog.dart';
import 'sales_page.dart' show showInvoiceDetail;
import '../print_actions.dart';
import '../record_actions.dart';
import '../../domain/services/whatsapp.dart';
import '../providers.dart';
import '../whatsapp_actions.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/forms.dart';

String partyWord(PartyKind k) => k == PartyKind.customer ? 'Customer' : 'Supplier';

/// Customers or suppliers list with balances.
class PartiesPage extends ConsumerStatefulWidget {
  final PartyKind kind;
  const PartiesPage({super.key, required this.kind});
  @override
  ConsumerState<PartiesPage> createState() => _PartiesPageState();
}

/// Tabs of the Customers / Suppliers list.
enum PartyTab { all, due, paid, advance }

class _PartiesPageState extends ConsumerState<PartiesPage> {
  String _q = '';
  PartyTab _tab = PartyTab.all;
  bool _inactive = false;

  static bool _inTab(PartyTab t, Party p) => switch (t) {
        PartyTab.all => true,
        PartyTab.due => p.balance.isPositive,
        PartyTab.paid => p.balance.isZero,
        PartyTab.advance => p.balance.isNegative,
      };

  String _tabLabel(PartyTab t) => switch (t) {
        PartyTab.all => 'All',
        PartyTab.due => widget.kind == PartyKind.customer ? 'Balance due (baqaya)' : 'To pay',
        PartyTab.paid => widget.kind == PartyKind.customer ? 'Paid up' : 'Settled',
        PartyTab.advance => widget.kind == PartyKind.customer ? 'Advance / credit' : 'Advance paid',
      };

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    final app = ref.watch(liveServicesProvider);
    final k = widget.kind;
    final word = partyWord(k);
    final all = app.parties.list(k, query: _q, includeInactive: _inactive);
    final rows = all.where((p) => _inTab(_tab, p)).toList();
    final totals = app.parties.accountTotals(k);
    final total = k == PartyKind.customer ? app.parties.totalReceivables() : app.parties.totalPayables();
    Widget tabChip(PartyTab t) {
      final list = all.where((p) => _inTab(t, p)).toList();
      final sum = Money.sum(list.map((p) => p.balance));
      final tone = switch (t) { PartyTab.due => c.warning, PartyTab.advance => c.accent, _ => c.text };
      return ChoiceChip(
        key: ValueKey('ptab-${t.name}'),
        selected: _tab == t,
        onSelected: (_) => setState(() => _tab = t),
        label: Text.rich(TextSpan(children: [
          TextSpan(text: '${_tabLabel(t)}  ${list.length}', style: const TextStyle(fontWeight: FontWeight.w600)),
          if (t == PartyTab.due || t == PartyTab.advance) TextSpan(text: '  •  ${sum.abs().format()}', style: TextStyle(color: tone, fontWeight: FontWeight.w700)),
        ])),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PageHeader(
          title: '${word}s',
          subtitle: '${k == PartyKind.customer ? 'Total receivable' : 'Total payable'}: ${total.format()}',
          breadcrumbs: ['${word}s'],
          actions: [
            ExportMenu(tables: () => [_table(rows, totals)]),
            if (k == PartyKind.customer)
              OutlinedButton.icon(
                key: const ValueKey('print-customer-statement'),
                onPressed: () => showCustomerStatement(context, ref),
                icon: const Icon(Icons.receipt_long_outlined, size: 18),
                label: const Text('Print Customer Statement'),
              ),
            FilledButton.icon(onPressed: () => showPartyForm(context, ref, k), icon: const Icon(Icons.add), label: Text('Add $word')),
          ],
        ),
        Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SearchBox(hint: 'Search name, phone, company…', onChanged: (v) => setState(() => _q = v)),
          FilterChip(label: const Text('Show inactive'), selected: _inactive, onSelected: (v) => setState(() => _inactive = v)),
        ]),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [for (final t in PartyTab.values) tabChip(t)]),
        const SizedBox(height: 16),
        Expanded(
          child: SingleChildScrollView(
            child: AppTable<Party>(
              rows: rows,
              onRowTap: (p) => showPartyDetail(context, ref, p),
              empty: EmptyState(icon: Icons.people_outline, title: 'No ${word.toLowerCase()}s', message: 'Add your first ${word.toLowerCase()} account.'),
              columns: [
                AppColumn('Name', flex: 4, minWidth: 160, (p) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(p.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                      if (p.company.isNotEmpty) Text(p.company, style: TextStyle(color: c.textMuted, fontSize: 12)),
                    ])),
                AppColumn('Phone', (p) => Text(p.phone)),
                AppColumn(k == PartyKind.customer ? 'Total billed' : 'Total bought', numeric: true, (p) => Text((totals[p.id]?.billed ?? p.balance).format())),
                AppColumn('Paid', numeric: true, (p) => Text((totals[p.id]?.paid ?? const Money.zero()).format(), style: TextStyle(color: c.accent))),
                AppColumn(k == PartyKind.customer ? 'Balance (baqaya)' : 'Balance', numeric: true, (p) {
                  final tone = p.balance.isPositive ? c.warning : (p.balance.isNegative ? c.accent : c.textMuted);
                  return Text(p.balance.isNegative ? '${p.balance.abs().format()} adv.' : p.balance.format(), style: TextStyle(color: tone, fontWeight: FontWeight.w700));
                }),
                AppColumn('Last payment', (p) {
                  final d = totals[p.id]?.lastPayment;
                  return Text(d == null ? '—' : dateFmt.format(d), style: TextStyle(color: c.textMuted));
                }),
                AppColumn('Status', flex: 1, (p) => p.active ? StatusPill('Active', c.accent) : StatusPill('Inactive', c.textMuted)),
                if (k == PartyKind.customer)
                  AppColumn<Party>('', flex: 1, minWidth: 48, numeric: true, (p) => Align(alignment: Alignment.centerRight, child: WhatsAppButton(party: p))),
                actionsColumn<Party>((p) {
                  final can = app.ctx.can(k == PartyKind.customer ? Permission.manageCustomers : Permission.manageSuppliers);
                  return RowActionsMenu(
                    onView: () => showPartyDetail(context, ref, p),
                    onEdit: can ? () => showPartyForm(context, ref, k, existing: p) : null,
                    onDelete: can && (p.active || app.ctx.can(Permission.permanentDelete)) ? () => deletePartyRecord(context, ref, p) : null,
                    extra: [
                      if (k == PartyKind.customer)
                        RowAction('Print Customer Statement', Icons.receipt_long_outlined, () => showCustomerStatement(context, ref, customer: p), keyName: 'row-statement'),
                      if (can && !p.active)
                        RowAction('Restore', Icons.unarchive_outlined, () => runAction(context, () => app.parties.restore(k, p.id), success: '"${p.name}" restored'), keyName: 'row-restore'),
                    ],
                  );
                }),
],
            ),
          ),
        ),
      ]),
    );
  }

  ExportTable _table(List<Party> rows, Map<String, PartyTotals> totals) =>
      ExportTable('${partyWord(widget.kind)}s — ${_tabLabel(_tab)}', ['Name', 'Company', 'Phone', 'Address', 'Total billed', 'Paid', 'Balance', 'Last payment'], [
        for (final p in rows)
          [p.name, p.company, p.phone, p.address, (totals[p.id]?.billed ?? p.balance).paisa / 100, (totals[p.id]?.paid ?? const Money.zero()).paisa / 100, p.balance.paisa / 100, totals[p.id]?.lastPayment]
      ], footer: [
        ['Total (${rows.length})', null, null, null, Money.sum(rows.map((p) => totals[p.id]?.billed ?? p.balance)).paisa / 100, Money.sum(rows.map((p) => totals[p.id]?.paid ?? const Money.zero())).paisa / 100, Money.sum(rows.map((p) => p.balance)).paisa / 100, null]
      ]);
}

/// Add / edit form. Returns the saved party.
Future<Party?> showPartyForm(BuildContext context, WidgetRef ref, PartyKind kind, {Party? existing}) {
  final name = TextEditingController(text: existing?.name);
  final company = TextEditingController(text: existing?.company);
  final contact = TextEditingController(text: existing?.contactPerson);
  final phone = TextEditingController(text: existing?.phone);
  final altPhone = TextEditingController(text: existing?.altPhone);
  final address = TextEditingController(text: existing?.address);
  final email = TextEditingController(text: existing?.email);
  final notes = TextEditingController(text: existing?.notes);
  final opening = TextEditingController();
  var openingSign = 1;
  var active = existing?.active ?? true;
  final key = GlobalKey<FormState>();
  final word = partyWord(kind);
  return showDialog<Party>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
      Future<void> save() async {
        if (!key.currentState!.validate()) return;
        final app = ref.read(servicesProvider);
        try {
          Party saved;
          if (existing == null) {
            final ob = Money.tryParse(opening.text) ?? const Money.zero();
            saved = await app.parties.create(
              kind: kind,
              name: name.text,
              company: company.text,
              contactPerson: contact.text,
              phone: phone.text,
              altPhone: altPhone.text,
              address: address.text,
              email: email.text,
              notes: notes.text,
              openingBalance: openingSign < 0 ? -ob : ob,
            );
          } else {
            saved = await app.parties.update(existing.copyWith(
                name: name.text, company: company.text, contactPerson: contact.text, phone: phone.text, altPhone: altPhone.text, address: address.text, email: email.text, notes: notes.text, active: active));
          }
          if (ctx.mounted) {
            showToast(ctx, '$word saved');
            Navigator.pop(ctx, saved);
          }
        } catch (e) {
          if (ctx.mounted) showToast(ctx, friendlyError(e), error: true);
        }
      }

      return FormDialog(
        title: existing == null ? 'Add $word' : 'Edit $word',
        body: Form(
          key: key,
          child: Column(children: [
            FieldRow([LabeledField('Name *', name, autofocus: true, validator: (v) => (v ?? '').trim().isEmpty ? 'Required' : null)]),
            FieldRow([
              LabeledField('Mobile (e.g. 03001234567 or +971501234567)', phone, validator: _phoneValidator),
              LabeledField('Alternate number (optional)', altPhone, validator: _phoneValidator),
            ]),
            FieldRow([LabeledField(kind == PartyKind.supplier ? 'Company name' : 'Company (optional)', company)]),
            FieldRow([LabeledField('Contact person', contact), LabeledField('Email (optional)', email)]),
            FieldRow([LabeledField('Address', address)]),
            if (existing == null)
              FieldRow([
                LabeledField('Opening balance (Rs)', opening, formatters: moneyInput, validator: (v) => moneyValidator(v, required: false)),
                AppDropdown<int>(
                  value: openingSign,
                  decoration: const InputDecoration(labelText: 'Opening balance is'),
                  items: [
                    DropdownMenuItem(value: 1, child: Text(kind == PartyKind.customer ? 'They owe us' : 'We owe them')),
                    DropdownMenuItem(value: -1, child: Text(kind == PartyKind.customer ? 'Advance from them' : 'Advance paid to them')),
                  ],
                  onChanged: (v) => setS(() => openingSign = v ?? 1),
                ),
              ]),
            FieldRow([LabeledField('Notes', notes, maxLines: 2)]),
            if (existing != null)
              SwitchListTile(contentPadding: EdgeInsets.zero, value: active, onChanged: (v) => setS(() => active = v), title: const Text('Account active')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: save, child: Text('Save $word')),
        ],
      );
    }),
  );
}

Future<void> showPartyDetail(BuildContext context, WidgetRef ref, Party party) =>
    showDialog<void>(context: context, builder: (_) => _PartyDetail(partyId: party.id, kind: party.kind));

class _PartyDetail extends ConsumerStatefulWidget {
  final String partyId;
  final PartyKind kind;
  const _PartyDetail({required this.partyId, required this.kind});
  @override
  ConsumerState<_PartyDetail> createState() => _PartyDetailState();
}

class _PartyDetailState extends ConsumerState<_PartyDetail> {
  DateTime? _from;
  DateTime? _to;

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    final app = ref.watch(liveServicesProvider);
    final user = ref.watch(currentUserProvider)!;
    final p0 = app.parties.byId(widget.kind, widget.partyId);
    if (p0 == null) return RecordGone(widget.kind == PartyKind.customer ? 'customer' : 'supplier');
    final p = p0;
    final st = app.parties.statement(widget.kind, p.id, from: _from, to: _to);
    final isC = widget.kind == PartyKind.customer;
    final docs = isC
        ? app.sales.list(customerId: p.id).where((s0) => s0.status != DocStatus.draft).map((s0) => (s0.number, s0.date, s0.total, s0.status)).toList()
        : app.purchases.list(supplierId: p.id).map((x) => (x.number, x.date, x.total, x.status)).toList();
    return Dialog(
      insetPadding: EdgeInsets.all(MediaQuery.sizeOf(context).width < 1000 ? 12 : 32),
      child: SizedBox(
        width: 1000,
        height: MediaQuery.sizeOf(context).height * 0.92,
        child: DefaultTabController(
          length: 3,
          // Short windows scroll the whole account view instead of crushing the ledger.
          child: MinSizeScroll(
          minHeight: 540,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 14, 0),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: c.text)),
                    Text([p.phone, p.altPhone, p.address].where((e) => e.isNotEmpty).join(' • '), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: c.textMuted)),
                  ]),
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text(isC ? 'Receivable' : 'Payable', style: TextStyle(color: c.textMuted, fontSize: 12)),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(p.balance.format(), style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: p.balance.isPositive ? c.warning : c.accent)),
                    ),
                  ]),
                ),
                const SizedBox(width: 8),
                IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
              child: Wrap(spacing: 10, runSpacing: 10, children: [
                if (isC) ...[
                  FilledButton.icon(
                    key: const ValueKey('detail-whatsapp'),
                    style: FilledButton.styleFrom(backgroundColor: whatsAppGreen, foregroundColor: Colors.white),
                    onPressed: () => showWhatsAppComposer(context, ref, p),
                    icon: const WhatsAppIcon(size: 18),
                    label: const Text('WhatsApp'),
                  ),
                  PopupMenuButton<WaTemplate>(
                    key: const ValueKey('detail-wa-templates'),
                    tooltip: 'WhatsApp message templates',
                    onSelected: (t) => showWhatsAppComposer(context, ref, p, initial: t),
                    itemBuilder: (_) => [for (final t in WaTemplate.values) PopupMenuItem(value: t, child: Text(t.label))],
                    child: IgnorePointer(child: OutlinedButton.icon(onPressed: () {}, icon: const Icon(Icons.quickreply_outlined, size: 18), label: const Text('Message templates'))),
                  ),
                ],
                if (user.can(Permission.manageLedgers))
                  FilledButton.icon(
                    onPressed: () => showPaymentDialog(context, ref, p),
                    icon: Icon(isC ? Icons.call_received : Icons.call_made, size: 18),
                    label: Text(isC ? 'Receive Payment' : 'Pay Supplier'),
                  ),
                if (user.can(Permission.manageLedgers))
                  OutlinedButton.icon(onPressed: () => _adjust(p), icon: const Icon(Icons.tune, size: 18), label: const Text('Adjustment')),
                if (isC)
                  OutlinedButton.icon(
                    key: const ValueKey('detail-customer-statement'),
                    onPressed: () => showCustomerStatement(context, ref, customer: p, from: _from, to: _to),
                    icon: const Icon(Icons.receipt_long_outlined, size: 18),
                    label: const Text('Print Customer Statement'),
                  )
                else
                  OutlinedButton.icon(
                    onPressed: () => showPdf(context, app.ctx.settings, () => statementPdf(app.ctx.settings, st, from: _from, to: _to), name: 'Statement ${p.name}'),
                    icon: const Icon(Icons.print_outlined, size: 18),
                    label: const Text('Print Statement'),
                  ),
                OutlinedButton.icon(onPressed: () => showPartyForm(context, ref, p.kind, existing: p), icon: const Icon(Icons.edit_outlined, size: 18), label: const Text('Edit')),
              ]),
            ),
            const TabBar(isScrollable: true, tabs: [Tab(text: 'Ledger'), Tab(text: 'Documents'), Tab(text: 'Payments')]),
            Expanded(
              child: TabBarView(children: [
                Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(children: [
                      Expanded(
                        child: DateRangeBar(
                          from: _from ?? DateTime(2020),
                          to: _to ?? DateTime.now(),
                          onChanged: (a, b) => setState(() {
                            _from = a;
                            _to = b;
                          }),
                        ),
                      ),
                      TextButton(onPressed: () => setState(() => _from = _to = null), child: const Text('All time')),
                      if (isC)
                        IconButton(
                          key: const ValueKey('ledger-customer-statement'),
                          tooltip: 'Print Customer Statement',
                          onPressed: () => showCustomerStatement(context, ref, customer: p, from: _from, to: _to),
                          icon: const Icon(Icons.receipt_long_outlined),
                        ),
                    ]),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: AppTable<StatementLine>(
                        pageSize: 50,
                        rows: st.lines.reversed.toList(),
                        onRowTap: (l) => (l.entry.refType == 'sale' || l.entry.refType == 'sale_edit') && app.sales.byId(l.entry.refId) != null
                            ? showInvoiceDetail(context, ref, l.entry.refId)
                            : null,
                        empty: const Padding(padding: EdgeInsets.all(30), child: Text('No entries in this period')),
                        columns: [
                          AppColumn('Date', (l) => Text(dateFmt.format(l.entry.at))),
                          AppColumn('Type', (l) => Text(l.entry.type.name)),
                          AppColumn('Reference', flex: 4, (l) => Text('${l.entry.refNumber}${l.entry.note.isEmpty ? '' : ' • ${l.entry.note}'}', overflow: TextOverflow.ellipsis)),
                          AppColumn('Debit', numeric: true, (l) => Text(l.entry.debit.isZero ? '' : l.entry.debit.format())),
                          AppColumn('Credit', numeric: true, (l) => Text(l.entry.credit.isZero ? '' : l.entry.credit.format())),
                          AppColumn('Balance', numeric: true, (l) => Text(l.runningBalance.format(), style: const TextStyle(fontWeight: FontWeight.w600))),
                          if (isC && app.ctx.can(Permission.editInvoices))
                            AppColumn('', flex: 1, (l) {
                              final sale = l.entry.refType == 'sale' ? app.sales.byId(l.entry.refId) : null;
                              if (sale == null || sale.status != DocStatus.completed) return const SizedBox.shrink();
                              return IconButton(
                                key: ValueKey('ledger-edit-${sale.number}'),
                                tooltip: 'Edit invoice ${sale.number}',
                                onPressed: () => showEditInvoice(context, ref, sale),
                                icon: const Icon(Icons.edit_outlined, size: 18),
                              );
                            }),
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Wrap(spacing: 20, runSpacing: 4, children: [
                      Text('Opening for period: ${st.openingBalance.format()}', style: TextStyle(color: c.textMuted)),
                      Text('Closing: ${st.closingBalance.format()}', style: TextStyle(color: c.textMuted)),
                    ]),
                  ),
                ]),
                SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: AppTable<(String, DateTime, Money, DocStatus)>(
                    rows: docs,
                    empty: const Padding(padding: EdgeInsets.all(30), child: Text('No documents')),
                    columns: [
                      AppColumn(isC ? 'Invoice' : 'Purchase', (d) => Text(d.$1)),
                      AppColumn('Date', (d) => Text(dateFmt.format(d.$2))),
                      AppColumn('Total', numeric: true, (d) => Text(d.$3.format())),
                      AppColumn('Status', (d) => StatusPill(d.$4.name, d.$4 == DocStatus.cancelled ? c.danger : c.accent)),
                    ],
                  ),
                ),
                SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: AppTable<Payment>(
                    rows: app.parties.payments(kind: widget.kind, partyId: p.id),
                    onRowTap: (pay) => showPaymentActions(context, ref, pay),
                    empty: const Padding(padding: EdgeInsets.all(30), child: Text('No payments')),
                    columns: [
                      AppColumn('No', (x) => Text(x.number)),
                      AppColumn('Date', (x) => Text(dateTimeFmt.format(x.at))),
                      AppColumn('Method', (x) => Text(x.method.label)),
                      AppColumn('Amount', numeric: true, (x) => Text('${x.direction == PaymentDirection.received ? '+' : '−'}${x.amount.format()}')),
                      AppColumn('Status', (x) => x.voided ? StatusPill('Voided', c.danger) : StatusPill('OK', c.accent)),
                      actionsColumn<Payment>((x) => RowActionsMenu(
                            onView: () => showPaymentActions(context, ref, x),
                            onDelete: !x.voided && app.ctx.can(Permission.cancelTransactions) ? () => deletePaymentRecord(context, ref, x, partyName: p.name) : null,
                          )),
],
                  ),
                ),
              ]),
            ),
          ]),
          ),
        ),
      ),
    );
  }

  Future<void> _adjust(Party p) async {
    final amount = TextEditingController(), note = TextEditingController();
    var increase = true;
    final key = GlobalKey<FormState>();
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => FormDialog(
          title: 'Balance adjustment • ${p.name}',
          width: 480,
          body: Form(
            key: key,
            child: Column(children: [
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: true, label: Text(p.kind == PartyKind.customer ? 'Increase (they owe more)' : 'Increase (we owe more)')),
                  const ButtonSegment(value: false, label: Text('Decrease')),
                ],
                selected: {increase},
                onSelectionChanged: (s) => setS(() => increase = s.first),
              ),
              const SizedBox(height: 14),
              FieldRow([LabeledField('Amount (Rs)', amount, formatters: moneyInput, autofocus: true, validator: (v) => moneyValidator(v, allowZero: false))]),
              FieldRow([LabeledField('Reason (required, kept in audit log)', note, validator: (v) => (v ?? '').trim().isEmpty ? 'Required' : null)]),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                if (!key.currentState!.validate()) return;
                final ok = await runAction(ctx, () => ref.read(servicesProvider).parties.adjust(kind: p.kind, partyId: p.id, amount: Money.parse(amount.text), increaseBalance: increase, note: note.text),
                    success: 'Adjustment posted');
                if (ok && ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Post'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Receive from customer / pay supplier, optionally against a document.
Future<void> showPaymentDialog(BuildContext context, WidgetRef ref, Party p) async {
  final app = ref.read(servicesProvider);
  final isC = p.kind == PartyKind.customer;
  final amount = TextEditingController(text: p.balance.isPositive ? p.balance.toDecimalString() : '');
  final note = TextEditingController();
  var method = PaymentMethod.cash;
  String? docId;
  final docs = isC
      ? app.sales.list(customerId: p.id, status: DocStatus.completed).where((s0) => s0.remaining.isPositive).map((s0) => (s0.id, s0.number, s0.remaining)).toList()
      : app.purchases.list(supplierId: p.id, includeCancelled: false).where((x) => x.remaining.isPositive).map((x) => (x.id, x.number, x.remaining)).toList();
  final key = GlobalKey<FormState>();
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) => FormDialog(
        title: isC ? 'Receive payment • ${p.name}' : 'Pay supplier • ${p.name}',
        width: 520,
        body: Form(
          key: key,
          child: Column(children: [
            InfoRow(isC ? 'Current receivable' : 'Current payable', p.balance.format(), strong: true),
            const SizedBox(height: 12),
            FieldRow([
              LabeledField('Amount (Rs)', amount, formatters: moneyInput, autofocus: true, validator: (v) => moneyValidator(v, allowZero: false)),
              AppDropdown<PaymentMethod>(
                value: method,
                decoration: const InputDecoration(labelText: 'Method'),
                items: [for (final m0 in PaymentMethod.values) DropdownMenuItem(value: m0, child: Text(m0.label))],
                onChanged: (v) => setS(() => method = v ?? method),
              ),
            ]),
            if (docs.isNotEmpty)
              FieldRow([
                AppDropdown<String?>(
                  value: docId,
                  decoration: InputDecoration(labelText: isC ? 'Against invoice (optional)' : 'Against purchase (optional)'),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('General account payment')),
                    for (final d in docs) DropdownMenuItem(value: d.$1, child: Text('${d.$2} • due at the time ${d.$3.format()}')),
                  ],
                  onChanged: (v) => setS(() => docId = v),
                ),
              ]),
            FieldRow([LabeledField('Note (cheque no, bank ref…)', note)]),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              if (!key.currentState!.validate()) return;
              try {
                final docNum = docs.where((d) => d.$1 == docId).map((d) => d.$2).firstOrNull ?? '';
                final pay = await app.parties.addPayment(kind: p.kind, partyId: p.id, amount: Money.parse(amount.text), method: method, note: note.text, againstDocId: docId, againstDocNumber: docNum);
                if (!ctx.mounted) return;
                Navigator.pop(ctx);
                showToast(context, 'Payment ${pay.number} recorded');
                final after = app.parties.byId(p.kind, p.id)!.balance;
                if (context.mounted) {
                  await showPdf(context, app.ctx.settings, () => paymentReceiptPdf(app.ctx.settings, pay, party: p, balanceAfter: after), name: pay.number);
                }
              } catch (e) {
                if (ctx.mounted) showToast(ctx, friendlyError(e), error: true);
              }
            },
            child: const Text('Save & Receipt'),
          ),
        ],
      ),
    ),
  );
}

/// Reprint or void a payment.
Future<void> showPaymentActions(BuildContext context, WidgetRef ref, Payment pay) async {
  final app = ref.read(servicesProvider);
  final party = pay.partyKind == null || pay.partyId == null ? null : app.parties.byId(pay.partyKind!, pay.partyId!);
  await showDialog<void>(
    context: context,
    builder: (ctx) => FormDialog(
      title: 'Payment ${pay.number}',
      width: 460,
      body: Column(children: [
        InfoRow('Date', dateTimeFmt.format(pay.at)),
        InfoRow('Account', party?.name ?? 'Walk-in'),
        InfoRow('Direction', pay.direction == PaymentDirection.received ? 'Received' : 'Paid'),
        InfoRow('Method', pay.method.label),
        InfoRow('Amount', pay.amount.format(), strong: true),
        if (pay.note.isNotEmpty) InfoRow('Note', pay.note),
        if (pay.voided) InfoRow('Voided', pay.voidReason, color: AppTheme.of(ctx).danger),
      ]),
      actions: [
        if (!pay.voided && app.ctx.can(Permission.cancelTransactions))
          TextButton(
            onPressed: () async {
              final reason = await promptText(ctx, title: 'Void payment', label: 'Reason');
              if (reason == null || !ctx.mounted) return;
              final ok = await runAction(ctx, () => app.parties.voidPayment(pay.id, reason), success: 'Payment voided (reversal entry posted)');
              if (ok && ctx.mounted) Navigator.pop(ctx);
            },
            child: Text('Void', style: TextStyle(color: AppTheme.of(ctx).danger)),
          ),
        OutlinedButton.icon(
          onPressed: () => showPdf(ctx, app.ctx.settings, () => paymentReceiptPdf(app.ctx.settings, pay, party: party), name: pay.number),
          icon: const Icon(Icons.print_outlined, size: 18),
          label: const Text('Receipt'),
        ),
        FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
      ],
    ),
  );
}

/// Empty is fine (the number is optional); otherwise it must look like a
/// phone number. Landlines are allowed here; WhatsApp buttons simply skip
/// numbers WhatsApp cannot use.
String? _phoneValidator(String? v) {
  final s0 = (v ?? '').trim();
  if (s0.isEmpty) return null;
  return normalizeWhatsAppNumber(s0) == null && !RegExp(r'^\+?[\d\s\-()/]{6,}$').hasMatch(s0) ? 'Enter a valid phone number' : null;
}
