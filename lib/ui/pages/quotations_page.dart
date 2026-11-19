import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors.dart';
import '../../core/money.dart';
import '../../core/qty.dart';
import '../../domain/models/documents.dart';
import '../../domain/models/party.dart';
import '../../domain/models/product.dart';
import '../../printing/pdf_docs.dart';
import '../../export/tabular.dart';
import '../print_actions.dart';
import '../record_actions.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/forms.dart';
import 'pos_page.dart';

Color quoteTone(AppColors c, QuotationStatus s) => switch (s) {
      QuotationStatus.approved || QuotationStatus.converted => c.accent,
      QuotationStatus.rejected || QuotationStatus.expired => c.danger,
      QuotationStatus.sent => const Color(0xFF6FB8FF),
      QuotationStatus.draft => c.textMuted,
    };

class QuotationsPage extends ConsumerStatefulWidget {
  const QuotationsPage({super.key});
  @override
  ConsumerState<QuotationsPage> createState() => _QuotationsPageState();
}

class _QuotationsPageState extends ConsumerState<QuotationsPage> {
  QuotationStatus? _status;
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    final app = ref.watch(liveServicesProvider);
    final now = app.ctx.now();
    final ql = _q.toLowerCase();
    final rows = app.quotations.list().where((x) => (_status == null || x.statusOn(now) == _status) && (ql.isEmpty || x.number.toLowerCase().contains(ql) || x.customerName.toLowerCase().contains(ql))).toList();
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PageHeader(title: 'Quotations', breadcrumbs: const ['Quotations'], subtitle: 'Quotations never change stock until converted to a sale.', actions: [
          ExportMenu(
            tables: () => [
              ExportTable('Quotations', ['Quotation', 'Date', 'Customer', 'Valid Until', 'Status', 'Items', 'Total'], [
                for (final x in rows) [x.number, x.date, x.customerName, x.expiryDate, x.statusOn(now).name, x.items.length, x.total.paisa / 100]
              ]),
            ],
          ),
          FilledButton.icon(onPressed: () => showQuotationEditor(context, ref), icon: const Icon(Icons.add), label: const Text('New Quotation')),
        ]),
        Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SearchBox(hint: 'Quotation no or customer…', width: 260, onChanged: (v) => setState(() => _q = v)),
          ChoiceChip(label: const Text('All'), selected: _status == null, onSelected: (_) => setState(() => _status = null)),
          for (final s0 in QuotationStatus.values) ChoiceChip(label: Text(s0.name), selected: _status == s0, onSelected: (_) => setState(() => _status = s0)),
        ]),
        const SizedBox(height: 14),
        Expanded(
          child: SingleChildScrollView(
            child: AppTable<Quotation>(
              rows: rows,
              onRowTap: (x) => showQuotationEditor(context, ref, existing: x),
              empty: const EmptyState(icon: Icons.request_quote_outlined, title: 'No quotations', message: 'Create professional quotations and convert approved ones into invoices.'),
              columns: [
                AppColumn('Quotation', (x) => Text(x.number, style: const TextStyle(fontWeight: FontWeight.w600))),
                AppColumn('Date', (x) => Text(dateFmt.format(x.date))),
                AppColumn('Customer', flex: 3, (x) => Text(x.customerName)),
                AppColumn('Valid until', (x) => Text(dateFmt.format(x.expiryDate))),
                AppColumn('Total', numeric: true, (x) => Text(x.total.format())),
                AppColumn('Status', (x) => StatusPill(x.statusOn(now).name, quoteTone(c, x.statusOn(now)))),
actionsColumn<Quotation>((x) => RowActionsMenu(
                    onView: () => showQuotationEditor(context, ref, existing: x),
                    onDelete: x.status == QuotationStatus.converted ? null : () => deleteQuotationRecord(context, ref, x),
                  )),
],
            ),
          ),
        ),
      ]),
    );
  }
}

Future<void> showQuotationEditor(BuildContext context, WidgetRef ref, {Quotation? existing}) =>
    showDialog<void>(context: context, barrierDismissible: false, builder: (_) => _QuoteEditor(existing: existing));

class _QLine {
  final String productId;
  final String name;
  final bool decimal;
  final TextEditingController qty;
  final TextEditingController price;
  final TextEditingController disc;
  _QLine(this.productId, this.name, this.decimal, Qty q, Money p, Money d)
      : qty = TextEditingController(text: q.format()),
        price = TextEditingController(text: p.toDecimalString()),
        disc = TextEditingController(text: d.isZero ? '' : d.toDecimalString());

  QuotationItem toItem() => QuotationItem(
      productId: productId, name: name, qty: Qty.tryParse(qty.text) ?? const Qty.zero(), unitPrice: Money.tryParse(price.text) ?? const Money.zero(), discount: Money.tryParse(disc.text) ?? const Money.zero());
}

class _QuoteEditor extends ConsumerStatefulWidget {
  final Quotation? existing;
  const _QuoteEditor({this.existing});
  @override
  ConsumerState<_QuoteEditor> createState() => _QuoteEditorState();
}

class _QuoteEditorState extends ConsumerState<_QuoteEditor> {
  late Quotation _q;
  late final _name = TextEditingController(text: _q.customerName);
  late final _terms = TextEditingController(text: _q.terms);
  late final _notes = TextEditingController(text: _q.notes);
  late final _disc = TextEditingController(text: _q.invoiceDiscount.isZero ? '' : _q.invoiceDiscount.toDecimalString());
  late final List<_QLine> _lines;

  @override
  void initState() {
    super.initState();
    final app = ref.read(servicesProvider);
    _q = widget.existing ?? app.quotations.newDraft();
    _lines = [
      for (final it in _q.items) _QLine(it.productId, it.name, app.catalog.byId(it.productId)?.allowDecimal ?? false, it.qty, it.unitPrice, it.discount),
    ];
  }

  Quotation _build() => _q.copyWith(
        customerName: _name.text.trim(),
        items: _lines.map((l) => l.toItem()).toList(),
        terms: _terms.text,
        notes: _notes.text,
        invoiceDiscount: Money.tryParse(_disc.text) ?? const Money.zero(),
      );

  Future<Quotation?> _save() async {
    try {
      final saved = await ref.read(servicesProvider).quotations.save(_build());
      setState(() => _q = saved);
      if (mounted) showToast(context, 'Quotation ${saved.number} saved');
      return saved;
    } catch (e) {
      if (mounted) showToast(context, friendlyError(e), error: true);
      return null;
    }
  }

  void _add(Product p) {
    setState(() => _lines.add(_QLine(p.id, p.name, p.allowDecimal, const Qty.one(), p.sellingPrice, const Money.zero())));
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    final app = ref.watch(liveServicesProvider);
    final status = _q.statusOn(app.ctx.now());
    final locked = status == QuotationStatus.converted;
    final total = Money.sum(_lines.map((l) => l.toItem().net)) - (Money.tryParse(_disc.text) ?? const Money.zero());
    final st = app.ctx.settings;
    final customer = _q.customerId == null ? null : app.parties.byId(PartyKind.customer, _q.customerId!);
    return FormDialog(
      title: widget.existing == null ? 'New Quotation' : 'Quotation ${_q.number}',
      width: 980,
      headerTrailing: StatusPill(status.name, quoteTone(c, status)),
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AdaptiveSplit(breakpoint: 560, spacing: 12, flex: const [3, 1], children: [
          TextField(
              controller: _name,
              enabled: !locked,
              decoration: InputDecoration(
                labelText: 'Customer name *',
                suffixIcon: IconButton(
                  tooltip: 'Pick customer account',
                  icon: const Icon(Icons.person_search),
                  onPressed: locked
                      ? null
                      : () async {
                          final p = await pickFromList<Party>(context, title: 'Customer', items: app.parties.list(PartyKind.customer), label: (x) => x.name, subtitle: (x) => x.phone);
                          if (p != null) {
                            setState(() {
                              _q = _q.copyWith(customerId: p.id, customerName: p.name);
                              _name.text = p.name;
                            });
                          }
                        },
                ),
              ),
            ),
          InkWell(
              onTap: locked
                  ? null
                  : () async {
                      final d = await showDatePicker(context: context, firstDate: DateTime.now().subtract(const Duration(days: 1)), lastDate: DateTime.now().add(const Duration(days: 365)), initialDate: _q.expiryDate);
                      if (d != null) setState(() => _q = _q.copyWith(expiryDate: d));
                    },
              child: InputDecorator(decoration: const InputDecoration(labelText: 'Valid until'), child: Text(dateFmt.format(_q.expiryDate), maxLines: 1)),
            ),
        ]),
        const SizedBox(height: 12),
        if (!locked)
          Row(children: [
            Expanded(
              child: ScannerField(
                autofocus: false,
                hint: 'Scan or type product and press Enter',
                onScan: (code) {
                  final r = app.catalog.lookup(code);
                  final m0 = r == null ? app.catalog.search(code) : [r.product];
                  if (m0.length == 1) {
                    _add(m0.first);
                  } else {
                    showToast(context, m0.isEmpty ? 'No product found' : 'Several matches; use Browse', error: true);
                  }
                },
              ),
            ),
            const SizedBox(width: 10),
            OutlinedButton.icon(
              icon: const Icon(Icons.playlist_add, size: 18),
              label: const Text('Browse products'),
              onPressed: () async {
                final p = await pickFromList<Product>(context, title: 'Product', items: app.catalog.products(), label: (x) => x.name, subtitle: (x) => '${x.sellingPrice.format()} • stock ${x.stockQty.format()}');
                if (p != null) _add(p);
              },
            ),
          ]),
        const SizedBox(height: 10),
        for (var i = 0; i < _lines.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: LayoutBuilder(builder: (context, cons) {
              final name = Text(_lines[i].name, style: const TextStyle(fontWeight: FontWeight.w600));
              final fields = <Widget>[
                Expanded(child: TextField(controller: _lines[i].qty, enabled: !locked, inputFormatters: qtyInput, decoration: const InputDecoration(labelText: 'Qty'), onChanged: (_) => setState(() {}))),
                const SizedBox(width: 8),
                Expanded(child: TextField(controller: _lines[i].price, enabled: !locked, inputFormatters: moneyInput, decoration: const InputDecoration(labelText: 'Price'), onChanged: (_) => setState(() {}))),
                const SizedBox(width: 8),
                Expanded(child: TextField(controller: _lines[i].disc, enabled: !locked, inputFormatters: moneyInput, decoration: const InputDecoration(labelText: 'Discount'), onChanged: (_) => setState(() {}))),
              ];
              final net = SizedBox(
                width: 120,
                child: Align(alignment: Alignment.centerRight, child: FittedBox(fit: BoxFit.scaleDown, child: Text(_lines[i].toItem().net.format(), maxLines: 1, style: const TextStyle(fontWeight: FontWeight.w600)))),
              );
              final remove = IconButton(tooltip: 'Remove line', onPressed: () => setState(() => _lines.removeAt(i)), icon: Icon(Icons.delete_outline, color: c.danger));
              if (cons.maxWidth < 640) {
                return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(children: [Expanded(child: name), net, if (!locked) remove]),
                  const SizedBox(height: 6),
                  Row(children: fields),
                ]);
              }
              return Row(children: [Expanded(flex: 4, child: name), ...fields, net, if (!locked) remove]);
            }),
          ),
        if (_lines.isEmpty) Padding(padding: const EdgeInsets.all(20), child: Center(child: Text('Add products to the quotation', style: TextStyle(color: c.textMuted)))),
        const Divider(),
        AdaptiveSplit(breakpoint: 600, spacing: 16, flex: const [3, 2], children: [
          TextField(controller: _terms, enabled: !locked, maxLines: 3, decoration: const InputDecoration(labelText: 'Terms & conditions')),
          Column(children: [
              TextField(controller: _disc, enabled: !locked, inputFormatters: moneyInput, decoration: const InputDecoration(labelText: 'Overall discount'), onChanged: (_) => setState(() {})),
              const SizedBox(height: 10),
              InfoRow('Total', total.format(), strong: true),
            ]),
        ]),
        const SizedBox(height: 10),
        TextField(controller: _notes, enabled: !locked, decoration: const InputDecoration(labelText: 'Internal notes')),
      ]),
      actions: [
        if (widget.existing != null && !locked) ...[
          PopupMenuButton<QuotationStatus>(
            tooltip: 'Set status',
            onSelected: (s0) async {
              final ok = await runAction(context, () async => _q = await app.quotations.setStatus(_q.id, s0), success: 'Status set to ${s0.name}');
              if (ok) setState(() {});
            },
            itemBuilder: (_) => [for (final s0 in [QuotationStatus.draft, QuotationStatus.sent, QuotationStatus.approved, QuotationStatus.rejected]) PopupMenuItem(value: s0, child: Text('Mark ${s0.name}'))],
            child: const Padding(padding: EdgeInsets.all(12), child: Text('Set status ▾')),
          ),
          if (status == QuotationStatus.approved)
            OutlinedButton.icon(
              icon: const Icon(Icons.point_of_sale, size: 18),
              label: const Text('Convert to Invoice'),
              onPressed: () async {
                try {
                  final draft = await app.quotations.convertToInvoice(_q.id);
                  ref.read(posDraftProvider.notifier).state = draft;
                  ref.read(navProvider.notifier).state = NavItem.pos;
                  if (context.mounted) {
                    Navigator.pop(context);
                    showToast(context, 'Draft invoice opened in POS. Check stock/serials and complete the sale.');
                  }
                } catch (e) {
                  if (context.mounted) showToast(context, friendlyError(e), error: true);
                }
              },
            ),
        ],
        if (widget.existing != null)
          OutlinedButton.icon(
            icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
            label: const Text('PDF / Print'),
            onPressed: () async {
              final q = locked ? _q : await _save();
              if (q != null && context.mounted) await showPdf(context, st, () => quotationPdf(st, q, customer: customer), name: q.number);
            },
          ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        if (!locked)
          FilledButton(
            onPressed: () async {
              final saved = await _save();
              if (saved != null && widget.existing == null && context.mounted) {
                Navigator.pop(context);
                await showQuotationEditor(context, ref, existing: saved);
              }
            },
            child: const Text('Save'),
          ),
      ],
    );
  }
}
