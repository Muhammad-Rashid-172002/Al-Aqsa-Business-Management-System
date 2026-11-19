import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors.dart';
import '../../core/money.dart';
import '../../core/qty.dart';
import '../../domain/models/documents.dart';
import '../../domain/models/party.dart';
import '../../domain/models/product.dart';
import '../../domain/models/user.dart';
import '../../domain/services/purchase_service.dart';
import '../../domain/services/serial_service.dart';
import '../../export/tabular.dart';
import '../../printing/pdf_docs.dart';
import '../print_actions.dart';
import '../record_actions.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/forms.dart';
import '../widgets/serial_entry.dart';
import 'parties_page.dart';
import 'returns_page.dart';

class PurchasesPage extends ConsumerStatefulWidget {
  const PurchasesPage({super.key});
  @override
  ConsumerState<PurchasesPage> createState() => _PurchasesPageState();
}

class _PurchasesPageState extends ConsumerState<PurchasesPage> {
  DateTime _from = DateTime(DateTime.now().year, DateTime.now().month - 2);
  DateTime _to = DateTime.now();
  String _q = '';
  String? _supplier;

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    final app = ref.watch(liveServicesProvider);
    final rows = app.purchases.list(
      from: _from,
      to: _to,
      supplierId: _supplier,
      query: _q,
    );
    final suppliers = app.parties.list(
      PartyKind.supplier,
      includeInactive: true,
    );
    final names = {for (final s0 in suppliers) s0.id: s0.name};
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Purchases',
            breadcrumbs: const ['Purchases'],
            subtitle:
                '${rows.length} purchase(s) • ${Money.sum(rows.where((p) => p.status == DocStatus.completed).map((p) => p.total)).format()}',
            actions: [
              ExportMenu(tables: () => [ExportTable(
                        'Purchases',
                        [
                          'Purchase',
                          'Date',
                          'Supplier',
                          'Supplier Inv',
                          'Total',
                          'Paid',
                          'Status',
                        ],
                        [
                          for (final p in rows)
                            [
                              p.number,
                              dateFmt.format(p.date),
                              names[p.supplierId] ?? '',
                              p.supplierInvoiceNo,
                              p.total.paisa / 100,
                              p.paidAtPurchase.paisa / 100,
                              p.status.name,
                            ],
                        ],
                      )]),
              FilledButton.icon(
                onPressed: () => showNewPurchase(context, ref),
                icon: const Icon(Icons.add),
                label: const Text('New Purchase'),
              ),
            ],
          ),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SearchBox(
                hint: 'Purchase no / supplier invoice…',
                width: 260,
                onChanged: (v) => setState(() => _q = v),
              ),
              SizedBox(
                width: 230,
                child: AppDropdown<String?>(
                  value: _supplier,
                  isDense: true,
                  decoration: const InputDecoration(labelText: 'Supplier'),
                  items: [
                    const DropdownMenuItem(
                      value: null,
                      child: Text('All suppliers'),
                    ),
                    for (final s0 in suppliers)
                      DropdownMenuItem(value: s0.id, child: Text(s0.name)),
                  ],
                  onChanged: (v) => setState(() => _supplier = v),
                ),
              ),
              DateRangeBar(
                from: _from,
                to: _to,
                onChanged:
                    (a, b) => setState(() {
                      _from = a;
                      _to = b;
                    }),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: SingleChildScrollView(
              child: AppTable<Purchase>(
                rows: rows,
                onRowTap: (p) => showPurchaseDetail(context, ref, p.id),
                empty: EmptyState(
                  icon: Icons.local_shipping_outlined,
                  title: 'No purchases in this period',
                  message: 'Record stock you buy from suppliers.',
                  action: FilledButton.icon(
                    onPressed: () => showNewPurchase(context, ref),
                    icon: const Icon(Icons.add),
                    label: const Text('New Purchase'),
                  ),
                ),
                columns: [
                  AppColumn(
                    'Purchase',
                    (p) => Text(
                      p.number,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  AppColumn('Date', (p) => Text(dateFmt.format(p.date))),
                  AppColumn(
                    'Supplier',
                    flex: 3,
                    (p) => Text(names[p.supplierId] ?? ''),
                  ),
                  AppColumn('Supplier Inv', (p) => Text(p.supplierInvoiceNo)),
                  AppColumn('Items', flex: 1, (p) => Text('${p.items.length}')),
                  AppColumn(
                    'Total',
                    numeric: true,
                    (p) => Text(p.total.format()),
                  ),
                  AppColumn(
                    'Status',
                    (p) => StatusPill(
                      p.status.name,
                      p.status == DocStatus.cancelled ? c.danger : c.accent,
                    ),
                  ),
actionsColumn<Purchase>((p) => RowActionsMenu(
                    onView: () => showPurchaseDetail(context, ref, p.id),
                    onDelete: p.status == DocStatus.completed && app.ctx.can(Permission.cancelTransactions) ? () => deletePurchaseRecord(context, ref, p, names[p.supplierId] ?? '') : null,
                  )),
],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PLine {
  final Product product;
  final TextEditingController qty;
  final TextEditingController cost;
  final TextEditingController disc = TextEditingController();
  final TextEditingController tax = TextEditingController();
  List<String> serials = [];
  _PLine(this.product)
    : qty = TextEditingController(text: product.requiresSerial ? '' : '1'),
      cost = TextEditingController(
        text: product.purchasePrice.toDecimalString(),
      );

  /// Serial products: the quantity typed (or set in the serial dialog); it
  /// must equal the number of serials entered before saving.
  Qty get q => Qty.tryParse(qty.text) ?? const Qty.zero();
  int get serialsRequired => int.tryParse(qty.text.trim()) ?? 0;
  bool get serialsComplete => !product.requiresSerial || (serialsRequired > 0 && serials.length == serialsRequired);
  Money get net =>
      (Money.tryParse(cost.text) ?? const Money.zero()).timesQty(q) -
      (Money.tryParse(disc.text) ?? const Money.zero()) +
      (Money.tryParse(tax.text) ?? const Money.zero());

  PurchaseLineInput toInput() => PurchaseLineInput(
    productId: product.id,
    qty: q,
    unitCost: Money.tryParse(cost.text) ?? const Money.zero(),
    discount: Money.tryParse(disc.text) ?? const Money.zero(),
    tax: Money.tryParse(tax.text) ?? const Money.zero(),
    serials: serials,
  );
}

/// New purchase. With [product], that existing product is already on the
/// purchase (repeat purchase / restock), and its serial entry opens.
Future<void> showNewPurchase(BuildContext context, WidgetRef ref, {Product? product}) => openNewPurchase(context, product: product);

Future<void> openNewPurchase(BuildContext context, {Product? product}) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _NewPurchase(product: product),
    );

class _NewPurchase extends ConsumerStatefulWidget {
  final Product? product;
  const _NewPurchase({this.product});
  @override
  ConsumerState<_NewPurchase> createState() => _NewPurchaseState();
}

class _NewPurchaseState extends ConsumerState<_NewPurchase> {
  Party? _supplier;
  final _inv = TextEditingController();
  final _paid = TextEditingController();
  final _notes = TextEditingController();
  DateTime _date = DateTime.now();
  PaymentMethod _method = PaymentMethod.cash;
  final _lines = <_PLine>[];
  bool _saving = false;

  Money get _total => Money.sum(_lines.map((l) => l.net));

  @override
  void initState() {
    super.initState();
    final p = widget.product;
    if (p != null) WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _add(p) : null);
  }

  void _add(Product p) {
    if (_lines.any((l) => l.product.id == p.id)) {
      final l = _lines.firstWhere((l) => l.product.id == p.id);
      if (!p.requiresSerial) {
        l.qty.text =
            ((Qty.tryParse(l.qty.text) ?? const Qty.zero()) + const Qty.one())
                .format();
      }
      setState(() {});
      if (p.requiresSerial) _editSerials(l);
      return;
    }
    final l = _PLine(p);
    setState(() => _lines.add(l));
    if (p.requiresSerial) _editSerials(l);
  }

  void _scan(String code) {
    final app = ref.read(servicesProvider);
    final r = app.catalog.lookup(code);
    if (r != null) return _add(r.product);
    final m0 = app.catalog.search(code);
    if (m0.length == 1) return _add(m0.first);
    showToast(
      context,
      'No product matches "$code". Create it in Products first.',
      error: true,
    );
  }

  Future<void> _pickProduct() async {
    final app = ref.read(servicesProvider);
    final p = await pickFromList<Product>(
      context,
      title: 'Add product',
      items: app.catalog.products(),
      label: (p) => p.name,
      subtitle:
          (p) =>
              '${p.brand} ${p.model} • stock ${p.stockQty.format()} • last cost ${p.purchasePrice.format()}',
    );
    if (p != null) _add(p);
  }

  Future<void> _editSerials(_PLine l) async {
    final res = await showSerialEntry(
      context,
      app: ref.read(servicesProvider),
      productName: l.product.name,
      brandKey: l.product.brandKey,
      productId: l.product.id,
      quantity: l.serialsRequired,
      initial: l.serials,
    );
    if (res == null) return;
    setState(() {
      l.serials = res.serials;
      l.qty.text = '${res.quantity}';
    });
  }

  Future<void> _save({Set<String> approved = const {}}) async {
    if (_supplier == null) {
      return showToast(context, 'Select a supplier.', error: true);
    }
    if (_lines.isEmpty) {
      return showToast(context, 'Add at least one product.', error: true);
    }
    final missing = _lines.where((l) => !l.serialsComplete).toList();
    if (missing.isNotEmpty) {
      final l = missing.first;
      return showToast(
        context,
        '"${l.product.name}" needs ${l.serialsRequired} serial number(s): ${l.serials.length} entered. Every unit needs its own serial.',
        error: true,
      );
    }
    final paid = Money.tryParse(_paid.text) ?? const Money.zero();
    setState(() => _saving = true);
    final app = ref.read(servicesProvider);
    try {
      final p = await app.purchases.create(
        supplierId: _supplier!.id,
        supplierInvoiceNo: _inv.text,
        date: _date,
        lines: _lines.map((l) => l.toInput()).toList(),
        paid: paid,
        method: _method,
        notes: _notes.text,
        approvedSerialConflicts: approved,
      );
      if (!mounted) return;
      Navigator.pop(context);
      showToast(context, 'Purchase ${p.number} saved. Stock updated.');
    } on SerialConflictException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      final ok = await _approveConflicts(e.conflicts);
      if (ok) {
        await _save(
          approved: {...approved, ...e.conflicts.map((c) => c.serial)},
        );
      }
    } catch (e) {
      if (mounted) showToast(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _approveConflicts(List<SerialConflict> conflicts) async {
    final canApprove = ref
        .read(servicesProvider)
        .ctx
        .can(Permission.resolveSerialConflicts);
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final c = AppTheme.of(ctx);
        return FormDialog(
          title: 'Possible duplicate serial numbers',
          width: 640,
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'These serials already exist. Approve only if they are genuinely different physical units (for example another brand uses the same number, or the manufacturer repeated a serial).',
              ),
              const SizedBox(height: 12),
              for (final cf in conflicts)
                ListTile(
                  dense: true,
                  leading: Icon(
                    cf.kind == SerialConflictKind.sameBrand
                        ? Icons.error_outline
                        : Icons.info_outline,
                    color:
                        cf.kind == SerialConflictKind.sameBrand
                            ? c.danger
                            : c.warning,
                  ),
                  title: Text(
                    cf.serial,
                    style: const TextStyle(fontFamily: 'Consolas'),
                  ),
                  subtitle: Text(
                    cf.kind == SerialConflictKind.sameBrand
                        ? 'Same brand already has this serial (${cf.existing.status.label})'
                        : 'Exists under brand ${cf.existing.brandKey} (${cf.existing.status.label})',
                  ),
                ),
              if (!canApprove)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Only the owner can approve duplicates.',
                    style: TextStyle(color: c.danger),
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Go back and fix'),
            ),
            if (canApprove)
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Approve as genuine units'),
              ),
          ],
        );
      },
    );
    return r ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    final app = ref.watch(liveServicesProvider);
    return AppShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true):
            () => _save(),
      },
      child: Dialog(
        insetPadding: EdgeInsets.all(
          MediaQuery.sizeOf(context).width < 1000 ? 10 : 24,
        ),
        child: SizedBox(
          width: 1150,
          height: MediaQuery.sizeOf(context).height * 0.94,
          // Short windows: the whole form scrolls rather than squeezing the line list.
          child: MinSizeScroll(
            minHeight: 520,
            child: LayoutBuilder(
              builder: (context, dlg) {
                final narrow = dlg.maxWidth < 900;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 18, 12, 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              'New Purchase',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                                color: c.text,
                              ),
                            ),
                          ),
                          Text(
                            'Ctrl+S to save',
                            style: TextStyle(color: c.textMuted, fontSize: 12),
                          ),
                          IconButton(
                            onPressed: () async {
                              if (_lines.isEmpty ||
                                  await confirmDialog(
                                    context,
                                    title: 'Discard purchase?',
                                    message: 'Unsaved lines will be lost.',
                                    confirm: 'Discard',
                                    danger: true,
                                  )) {
                                if (context.mounted) Navigator.pop(context);
                              }
                            },
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: InkWell(
                              onTap: () async {
                                final s0 = await pickFromList<Party>(
                                  context,
                                  title: 'Supplier',
                                  items: app.parties.list(PartyKind.supplier),
                                  label: (p) => p.name,
                                  subtitle:
                                      (p) =>
                                          '${p.company} • payable ${p.balance.format()}',
                                  footer: Align(
                                    alignment: Alignment.centerRight,
                                    child: FilledButton.icon(
                                      onPressed: () async {
                                        final created = await showPartyForm(
                                          context,
                                          ref,
                                          PartyKind.supplier,
                                        );
                                        if (created != null &&
                                            context.mounted) {
                                          Navigator.of(context).pop();
                                          setState(() => _supplier = created);
                                        }
                                      },
                                      icon: const Icon(Icons.add, size: 18),
                                      label: const Text('New supplier'),
                                    ),
                                  ),
                                );
                                if (s0 != null) setState(() => _supplier = s0);
                              },
                              child: InputDecorator(
                                decoration: const InputDecoration(
                                  labelText: 'Supplier *',
                                  prefixIcon: Icon(Icons.storefront_outlined),
                                ),
                                child: Text(
                                  _supplier?.name ?? 'Select supplier…',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            flex: 2,
                            child: TextField(
                              controller: _inv,
                              decoration: const InputDecoration(
                                labelText: 'Supplier invoice no',
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            flex: 2,
                            child: InkWell(
                              onTap: () async {
                                final d = await showDatePicker(
                                  context: context,
                                  firstDate: DateTime(2020),
                                  lastDate: DateTime.now().add(
                                    const Duration(days: 1),
                                  ),
                                  initialDate: _date,
                                );
                                if (d != null) {
                                  setState(
                                    () =>
                                        _date = DateTime(
                                          d.year,
                                          d.month,
                                          d.day,
                                          DateTime.now().hour,
                                          DateTime.now().minute,
                                        ),
                                  );
                                }
                              },
                              child: InputDecorator(
                                decoration: const InputDecoration(
                                  labelText: 'Purchase date',
                                  prefixIcon: Icon(Icons.event),
                                ),
                                child: Text(dateFmt.format(_date), maxLines: 1),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: ScannerField(
                              onScan: _scan,
                              hint:
                                  'Scan product barcode / QR or type and press Enter',
                            ),
                          ),
                          const SizedBox(width: 10),
                          narrow
                              ? IconButton.outlined(
                                tooltip: 'Browse products',
                                onPressed: _pickProduct,
                                icon: const Icon(Icons.playlist_add),
                              )
                              : OutlinedButton.icon(
                                onPressed: _pickProduct,
                                icon: const Icon(Icons.playlist_add, size: 18),
                                label: const Text('Browse products'),
                              ),
                        ],
                      ),
                    ),
                    Expanded(
                      child:
                          _lines.isEmpty
                              ? const EmptyState(
                                icon: Icons.add_shopping_cart,
                                title: 'No items yet',
                                message:
                                    'Scan or browse products to add them to this purchase.',
                              )
                              : ListView.builder(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 24,
                                ),
                                itemCount: _lines.length,
                                itemBuilder: (_, i) {
                                  final l = _lines[i];
                                  final info = Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        l.product.name,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      Text(
                                        'In stock ${l.product.stockQty.format()} ${l.product.unit}',
                                        style: TextStyle(
                                          color: c.textMuted,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  );
                                  final fields = <Widget>[
                                    Expanded(
                                      child:
                                          l.product.requiresSerial
                                              ? OutlinedButton.icon(
                                                key: ValueKey(
                                                  'pline-serials-${l.product.id}',
                                                ),
                                                style: OutlinedButton.styleFrom(
                                                  foregroundColor:
                                                      l.serialsComplete
                                                          ? c.accent
                                                          : c.danger,
                                                ),
                                                onPressed:
                                                    () => _editSerials(l),
                                                icon: Icon(
                                                  l.serialsComplete
                                                      ? Icons.check_circle
                                                      : Icons.qr_code_scanner,
                                                  size: 16,
                                                ),
                                                label: Text(
                                                  '${l.serials.length}/${l.serialsRequired} S/N',
                                                  maxLines: 1,
                                                ),
                                              )
                                              : TextField(
                                                controller: l.qty,
                                                inputFormatters: qtyInput,
                                                decoration: InputDecoration(
                                                  labelText:
                                                      'Qty (${l.product.unit})',
                                                ),
                                                onChanged:
                                                    (_) => setState(() {}),
                                              ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: TextField(
                                        controller: l.cost,
                                        inputFormatters: moneyInput,
                                        decoration: const InputDecoration(
                                          labelText: 'Unit cost',
                                        ),
                                        onChanged: (_) => setState(() {}),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: TextField(
                                        controller: l.disc,
                                        inputFormatters: moneyInput,
                                        decoration: const InputDecoration(
                                          labelText: 'Discount',
                                        ),
                                        onChanged: (_) => setState(() {}),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: TextField(
                                        controller: l.tax,
                                        inputFormatters: moneyInput,
                                        decoration: const InputDecoration(
                                          labelText: 'Tax',
                                        ),
                                        onChanged: (_) => setState(() {}),
                                      ),
                                    ),
                                  ];
                                  final net = SizedBox(
                                    width: 130,
                                    child: Align(
                                      alignment: Alignment.centerRight,
                                      child: FittedBox(
                                        fit: BoxFit.scaleDown,
                                        child: Text(
                                          l.net.format(),
                                          maxLines: 1,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                  final remove = IconButton(
                                    tooltip: 'Remove line',
                                    onPressed:
                                        () =>
                                            setState(() => _lines.removeAt(i)),
                                    icon: Icon(
                                      Icons.delete_outline,
                                      color: c.danger,
                                    ),
                                  );
                                  return Container(
                                    margin: const EdgeInsets.only(bottom: 8),
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: c.surfaceHigh,
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(color: c.border),
                                    ),
                                    // Narrow windows: product + total on top, the four inputs underneath.
                                    child:
                                        narrow
                                            ? Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.stretch,
                                              children: [
                                                Row(
                                                  children: [
                                                    Expanded(child: info),
                                                    net,
                                                    remove,
                                                  ],
                                                ),
                                                const SizedBox(height: 8),
                                                Row(children: fields),
                                              ],
                                            )
                                            : Row(
                                              children: [
                                                Expanded(flex: 4, child: info),
                                                ...fields,
                                                net,
                                                remove,
                                              ],
                                            ),
                                  );
                                },
                              ),
                    ),
                    Container(
                      padding: const EdgeInsets.fromLTRB(24, 14, 24, 18),
                      decoration: BoxDecoration(
                        border: Border(top: BorderSide(color: c.border)),
                      ),
                      child: Builder(
                        builder: (context) {
                          final notes = TextField(
                            controller: _notes,
                            decoration: const InputDecoration(
                              labelText: 'Notes',
                            ),
                          );
                          final method = AppDropdown<PaymentMethod>(
                            value: _method,
                            decoration: const InputDecoration(
                              labelText: 'Payment method',
                            ),
                            items: [
                              for (final m0 in PaymentMethod.values)
                                DropdownMenuItem(
                                  value: m0,
                                  child: Text(m0.label),
                                ),
                            ],
                            onChanged:
                                (v) => setState(() => _method = v ?? _method),
                          );
                          final paid = TextField(
                            controller: _paid,
                            inputFormatters: moneyInput,
                            decoration: const InputDecoration(
                              labelText: 'Amount paid now',
                            ),
                            onChanged: (_) => setState(() {}),
                          );
                          final totals = Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  'Total ${_total.format()}',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w800,
                                    color: c.accent,
                                  ),
                                ),
                              ),
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  'Credit (payable): ${(_total - (Money.tryParse(_paid.text) ?? const Money.zero())).format()}',
                                  style: TextStyle(color: c.textMuted),
                                ),
                              ),
                            ],
                          );
                          final save = FilledButton.icon(
                            onPressed: _saving ? null : () => _save(),
                            icon: const Icon(Icons.save_outlined),
                            label: const Text('Save Purchase'),
                          );
                          if (!narrow) {
                            return Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Expanded(flex: 3, child: notes),
                                const SizedBox(width: 12),
                                SizedBox(width: 190, child: method),
                                const SizedBox(width: 12),
                                SizedBox(width: 170, child: paid),
                                const SizedBox(width: 20),
                                Flexible(flex: 2, child: totals),
                                const SizedBox(width: 16),
                                save,
                              ],
                            );
                          }
                          // Narrow: inputs on one row, totals + save underneath.
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Expanded(flex: 3, child: notes),
                                  const SizedBox(width: 10),
                                  Expanded(flex: 2, child: method),
                                  const SizedBox(width: 10),
                                  Expanded(flex: 2, child: paid),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  Expanded(
                                    child: Align(
                                      alignment: Alignment.centerLeft,
                                      child: totals,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  save,
                                ],
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> showPurchaseDetail(
  BuildContext context,
  WidgetRef ref,
  String id,
) => showDialog<void>(
  context: context,
  builder:
      (ctx) => Consumer(
        builder: (ctx, ref, _) {
          final c = AppTheme.of(ctx);
          final app = ref.watch(liveServicesProvider);
          final p0 = app.purchases.byId(id);
          final sup0 = p0 == null ? null : app.parties.byId(PartyKind.supplier, p0.supplierId);
          if (p0 == null || sup0 == null) return const RecordGone('purchase');
          final p = p0;
          final sup = sup0;
          final st = app.ctx.settings;
          return FormDialog(
            title: 'Purchase ${p.number}',
            width: 820,
            headerTrailing: StatusPill(
              p.status.name.toUpperCase(),
              p.status == DocStatus.cancelled ? c.danger : c.accent,
            ),
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                InfoRow('Supplier', sup.name),
                InfoRow('Date', dateFmt.format(p.date)),
                if (p.supplierInvoiceNo.isNotEmpty)
                  InfoRow('Supplier invoice', p.supplierInvoiceNo),
                if (p.status == DocStatus.cancelled)
                  InfoRow('Cancel reason', p.cancelReason, color: c.danger),
                const Divider(),
                for (final it in p.items)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text('${it.name}  ×  ${it.qty.format()}'),
                    subtitle: Text(
                      [
                        '${it.unitCost.format()} each',
                        if (!it.discount.isZero)
                          'discount ${it.discount.format()}',
                        if (!it.tax.isZero) 'tax ${it.tax.format()}',
                        if (it.serials.isNotEmpty)
                          'S/N ${it.serials.map(SerialRecord.displayOf).join(', ')}',
                        if (it.returnedQty.isPositive)
                          'returned ${it.returnedQty.format()}',
                      ].join(' • '),
                    ),
                    trailing: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 150),
                      child: Text(it.net.format(), textAlign: TextAlign.right),
                    ),
                  ),
                const Divider(),
                InfoRow('Total', p.total.format(), strong: true),
                InfoRow(
                  'Paid at purchase (${p.method.label})',
                  p.paidAtPurchase.format(),
                ),
                InfoRow(
                  'Supplier account now',
                  sup.balance.format(),
                  color: sup.balance.isPositive ? c.warning : null,
                ),
                if (p.notes.isNotEmpty) InfoRow('Notes', p.notes),
              ],
            ),
            actions: [
              if (p.status == DocStatus.completed &&
                  app.ctx.can(Permission.cancelTransactions))
                TextButton(
                  onPressed: () async {
                    final reason = await promptText(
                      ctx,
                      title: 'Cancel ${p.number}?',
                      label: 'Reason',
                      confirm: 'Cancel purchase',
                    );
                    if (reason != null && ctx.mounted) {
                      await runAction(
                        ctx,
                        () => app.purchases.cancel(p.id, reason),
                        success: 'Purchase cancelled',
                      );
                    }
                  },
                  child: Text(
                    'Cancel purchase',
                    style: TextStyle(color: c.danger),
                  ),
                ),
              if (p.status == DocStatus.completed)
                OutlinedButton.icon(
                  onPressed: () => showPurchaseReturnDialog(ctx, ref, p),
                  icon: const Icon(Icons.undo, size: 18),
                  label: const Text('Return to supplier'),
                ),
              if (sup.balance.isPositive &&
                  app.ctx.can(Permission.manageLedgers))
                OutlinedButton.icon(
                  onPressed: () => showPaymentDialog(ctx, ref, sup),
                  icon: const Icon(Icons.payments_outlined, size: 18),
                  label: const Text('Pay supplier'),
                ),
              FilledButton.icon(
                onPressed:
                    () => showPdf(
                      ctx,
                      st,
                      () => purchasePdf(st, p, sup),
                      name: p.number,
                    ),
                icon: const Icon(Icons.print, size: 18),
                label: const Text('Print'),
              ),
            ],
          );
        },
      ),
);
