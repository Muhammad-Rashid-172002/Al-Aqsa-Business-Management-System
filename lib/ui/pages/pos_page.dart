import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors.dart';
import '../../core/money.dart';
import '../../core/qty.dart';
import '../../core/scan_detector.dart';
import '../../domain/models/documents.dart';
import '../../domain/models/party.dart';
import '../../domain/models/product.dart';
import '../../domain/models/user.dart';
import '../../domain/services/app_services.dart';
import '../../domain/services/auth_service.dart';
import '../../printing/pdf_docs.dart';
import '../bill_lines.dart';
import '../print_actions.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/forms.dart';
import '../widgets/scanner_input.dart';
import 'parties_page.dart' show showPartyForm;

/// Current POS bill (kept when switching screens).
final posDraftProvider = StateProvider<Sale?>((ref) => null);

class PosPage extends ConsumerStatefulWidget {
  const PosPage({super.key});
  @override
  ConsumerState<PosPage> createState() => _PosPageState();
}

class _PosPageState extends ConsumerState<PosPage> {
  final _scanFocus = FocusNode();
  final _scanCtl = TextEditingController();
  late final _dupGuard = DuplicateScanGuard(
    app.ctx.settings.scanner.duplicateWindow,
  );
  final _paidCtl = TextEditingController();
  final _discCtl = TextEditingController();
  // Quick customer: typed at the bill instead of picking one; saved to
  // Customers together with the bill.
  final _qcName = TextEditingController();
  final _qcPhone = TextEditingController();
  String _search = '';
  bool _paidTouched = false;

  AppServices get app => ref.read(servicesProvider);
  late final Sale _fallback = app.sales.newDraft();

  Sale get draft => ref.read(posDraftProvider) ?? _fallback;

  void _qcChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _qcName.addListener(_qcChanged);
    _qcPhone.addListener(_qcChanged);
    Future.microtask(() {
      if (!mounted) return;
      final n = ref.read(posDraftProvider.notifier);
      n.state ??= _fallback;
      final d = n.state!;
      if (d.items.isNotEmpty) {
        _paidCtl.text =
            (d.paidAtSale.isZero ? d.total : d.paidAtSale).toDecimalString();
      }
      if (!d.invoiceDiscount.isZero) {
        _discCtl.text = d.invoiceDiscount.toDecimalString();
      }
    });
  }

  // Bill items and product grid scroll on their own, with a visible,
  // draggable scrollbar (mouse wheel, trackpad, scrollbar drag).
  final _billScroll = ScrollController();
  final _worker = TextEditingController();
  final _gridScroll = ScrollController();

  void _set(Sale s) {
    final before = ref.read(posDraftProvider)?.items.length ?? 0;
    ref.read(posDraftProvider.notifier).state = s;
    if (s.items.length > before) _revealNewLine();
    if (!_paidTouched && s.customerId == null) {
      _paidCtl.text = s.total.toDecimalString();
    }
  }

  /// Scrolls the bill so a line just added is visible.
  void _revealNewLine() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_billScroll.hasClients) return;
      final pos = _billScroll.position;
      final target = _billLinesEnd ?? pos.maxScrollExtent;
      _billScroll.animateTo(target.clamp(0, pos.maxScrollExtent), duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
    });
  }

  /// Offset at which the last bill line ends, in layouts where the totals
  /// scroll with the lines (very short windows); null otherwise.
  double? _billLinesEnd;
  final _linesEndKey = GlobalKey();

  @override
  void dispose() {
    _billScroll.dispose();
    _worker.dispose();
    _gridScroll.dispose();
    _scanFocus.dispose();
    _scanCtl.dispose();
    _paidCtl.dispose();
    _discCtl.dispose();
    _qcName.dispose();
    _qcPhone.dispose();
    super.dispose();
  }

  void _toast(String m, {bool error = false}) =>
      showToast(context, m, error: error);

  // ───────── adding items ─────────

  /// A code from a USB scanner (detected by its typing speed), wherever the
  /// focus was. Only exact matches are added; repeated reads are ignored.
  void _onScanner(String code) {
    setState(() => _search = _scanCtl.text);
    final window = app.ctx.settings.scanner.duplicateWindow;
    _dupGuard.window = window;
    if (!_dupGuard.accept(code, app.ctx.now())) {
      return _toast(
        'Ignored a repeated scan of "$code" (same code within ${window.inMilliseconds} ms). Scan again to add another.',
      );
    }
    _onScan(code, fromScanner: true);
  }

  void _onScan(String code, {bool fromScanner = false}) {
    final r = app.catalog.lookup(code);
    if (r == null && fromScanner) {
      // Never guess from a partial match for scanned codes.
      return _toast(
        'Unknown code "$code": no product barcode, QR code, SKU or serial number matches. Add it to a product first.',
        error: true,
      );
    }
    if (r == null) {
      final matches = app.catalog.search(code);
      if (matches.length == 1) {
        _addProduct(matches.first);
      } else {
        setState(() => _search = code);
        if (matches.isEmpty) {
          _toast(
            'Unknown code "$code". Add it to a product first.',
            error: true,
          );
        }
      }
      return;
    }
    if (r.product.archived) {
      return _toast('"${r.product.name}" is archived.', error: true);
    }
    final sr = r.serial;
    if (sr != null) {
      // The same serial number can exist under two brands: if more than one
      // such unit is in stock, ask which one is being sold.
      final inStock =
          [
            sr,
            ...r.otherMatches,
          ].where((x) => x.status == SerialStatus.inStock).toList();
      if (inStock.length > 1) {
        _pickUnit(code, inStock);
        return;
      }
      if (sr.status != SerialStatus.inStock) {
        return _toast(
          'Serial ${sr.display} is ${sr.status.label}, not in stock.',
          error: true,
        );
      }
      _addSerial(r.product, sr.key);
    } else {
      _addProduct(r.product);
    }
  }

  Future<void> _pickUnit(String code, List<SerialRecord> units) async {
    final names = {
      for (final u in units) u.key: app.catalog.byId(u.productId)?.name ?? '',
    };
    final u = await pickFromList<SerialRecord>(
      context,
      title: 'Which unit is serial $code?',
      items: units,
      label: (x) => '${x.display} • ${names[x.key]}',
      subtitle: (x) => 'Brand ${x.brandKey}',
    );
    if (u == null || !mounted) return;
    final p = app.catalog.byId(u.productId);
    if (p != null) _addSerial(p, u.key);
  }

  Future<void> _addProduct(Product p, {Qty? qty}) async {
    if (p.requiresSerial) {
      final keys = await _pickSerials(p);
      if (keys == null || keys.isEmpty) return;
      for (final k in keys) {
        _addSerial(p, k);
      }
      return;
    }
    final d = draft;
    final idx = d.items.indexWhere(
      (e) => e.productId == p.id && e.techUsageId == null,
    );
    final add = qty ?? const Qty.one();
    final items = [...d.items];
    if (idx >= 0) {
      items[idx] = items[idx].copyWith(qty: items[idx].qty + add);
    } else {
      items.add(app.sales.lineFor(p, qty: add));
    }
    _set(d.copyWith(items: items));
    if (p.stockQty < items[idx >= 0 ? idx : items.length - 1].qty) {
      _toast(
        'Only ${p.stockQty.format()} ${p.unit} of "${p.name}" in stock.',
        error: true,
      );
    }
  }

  void _addSerial(Product p, String key) {
    final d = draft;
    if (d.items.any((e) => e.serials.contains(key))) {
      return _toast(
        'Serial ${SerialRecord.displayOf(key)} is already on this bill.',
        error: true,
      );
    }
    final idx = d.items.indexWhere(
      (e) => e.productId == p.id && e.techUsageId == null,
    );
    final items = [...d.items];
    if (idx >= 0) {
      final s0 = [...items[idx].serials, key];
      items[idx] = items[idx].copyWith(serials: s0, qty: Qty.units(s0.length));
    } else {
      items.add(app.sales.lineFor(p, serials: [key]));
    }
    _set(d.copyWith(items: items));
  }

  Future<List<String>?> _pickSerials(Product p) async {
    final inBill = draft.items.expand((e) => e.serials).toSet();
    final avail =
        app.serials
            .inStockFor(p.id)
            .where((r) => !inBill.contains(r.key))
            .toList();
    if (avail.isEmpty) {
      _toast('No serial numbers of "${p.name}" are in stock.', error: true);
      return null;
    }
    final chosen = <String>{};
    return showDialog<List<String>>(
      context: context,
      builder:
          (ctx) => StatefulBuilder(
            builder: (ctx, setS) {
              final c = AppTheme.of(ctx);
              return FormDialog(
                title: 'Select serial numbers • ${p.name}',
                width: 520,
                body: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ScannerField(
                      hint: 'Scan unit serial',
                      onScan: (code) {
                        final match =
                            avail
                                .where(
                                  (r) =>
                                      r.serial == code.trim().toUpperCase() ||
                                      r.key == code.trim(),
                                )
                                .toList();
                        if (match.isEmpty) {
                          showToast(
                            ctx,
                            'Serial not in stock for this product',
                            error: true,
                          );
                        } else {
                          setS(() => chosen.add(match.first.key));
                        }
                      },
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '${chosen.length} selected of ${avail.length} in stock',
                      style: TextStyle(color: c.textMuted),
                    ),
                    const SizedBox(height: 6),
                    SizedBox(
                      height: (MediaQuery.sizeOf(ctx).height * 0.45).clamp(
                        160.0,
                        320.0,
                      ),
                      child: ListView.builder(
                        itemCount: avail.length,
                        itemBuilder: (_, i) {
                          final r = avail[i];
                          return CheckboxListTile(
                            dense: true,
                            value: chosen.contains(r.key),
                            title: Text(
                              r.display,
                              style: const TextStyle(fontFamily: 'Consolas'),
                            ),
                            subtitle:
                                r.purchaseDate == null
                                    ? null
                                    : Text(
                                      'Purchased ${dateFmt.format(r.purchaseDate!)}',
                                    ),
                            onChanged:
                                (v) => setS(
                                  () =>
                                      v == true
                                          ? chosen.add(r.key)
                                          : chosen.remove(r.key),
                                ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed:
                        chosen.isEmpty
                            ? null
                            : () => Navigator.pop(ctx, chosen.toList()),
                    child: Text('Add ${chosen.length}'),
                  ),
                ],
              );
            },
          ),
    );
  }

  void _addInstallations(Party customer) {
    final pending = app.technicians.pendingInstallations(
      customerId: customer.id,
    );
    final d = draft;
    final items = [...d.items];
    for (final u in pending) {
      if (items.any((e) => e.techUsageId == u.id)) continue;
      final p = app.catalog.byId(u.productId);
      if (p == null) continue;
      items.add(
        SaleItem(
          productId: p.id,
          name:
              '${p.name} (installed${u.jobRef.isEmpty ? '' : ' - ${u.jobRef}'})',
          qty: u.qty,
          unitPrice: p.sellingPrice,
          serials: u.serials,
          techUsageId: u.id,
        ),
      );
    }
    _set(d.copyWith(items: items));
  }

  // ───────── editing ─────────

  void _updateLine(int i, SaleItem it) {
    final items = [...draft.items]..[i] = it;
    _set(draft.copyWith(items: items));
  }

  void _removeLine(int i) {
    final items = [...draft.items]..removeAt(i);
    _set(draft.copyWith(items: items));
  }

  /// "+ Add Item": a stock product, a non-stock item or a service.
  Future<void> _addItem() async {
    final kind = await chooseLineKind(context);
    if (kind == null || !mounted) return;
    if (kind == SaleLineKind.product) {
      final p = await pickFromList<Product>(
        context,
        title: 'Add stock product',
        items: app.catalog.products(),
        label: (x) => x.name,
        subtitle: (x) => '${x.sellingPrice.format()}  •  in stock ${x.stockQty.format()} ${x.unit}',
      );
      if (p != null && mounted) await _addProduct(p);
      return;
    }
    final line = await showCustomLineDialog(context, ref, kind: kind);
    if (line == null || !mounted) return;
    _set(draft.copyWith(items: [...draft.items, line]));
  }

  Future<void> _editLine(int i) async {
    final it = draft.items[i];
    if (!it.isStock) {
      final line = await showCustomLineDialog(context, ref, kind: it.kind, existing: it);
      if (line != null && mounted) _updateLine(i, line);
      return;
    }
    final p = app.catalog.byId(it.productId);
    final qty = TextEditingController(text: it.qty.format());
    final price = TextEditingController(text: it.unitPrice.toDecimalString());
    final disc = TextEditingController(
      text: it.discount.isZero ? '' : it.discount.toDecimalString(),
    );
    final key = GlobalKey<FormState>();
    final fixedQty = p == null || p.requiresSerial || it.techUsageId != null;
    final res = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => FormDialog(
            title: it.name,
            width: 460,
            body: Form(
              key: key,
              child: Column(
                children: [
                  FieldRow([
                    LabeledField(
                      'Quantity${p == null ? '' : ' (${p.unit})'}',
                      qty,
                      formatters: qtyInput,
                      enabled: !fixedQty,
                      autofocus: !fixedQty,
                      validator:
                          (v) => qtyValidator(
                            v,
                            allowDecimal: p?.allowDecimal ?? false,
                          ),
                    ),
                    LabeledField(
                      'Unit price',
                      price,
                      formatters: moneyInput,
                      validator: moneyValidator,
                      autofocus: fixedQty,
                    ),
                  ]),
                  FieldRow([
                    LabeledField(
                      'Line discount (Rs)',
                      disc,
                      formatters: moneyInput,
                      validator: (v) => moneyValidator(v, required: false),
                    ),
                  ]),
                  if (p != null && p.wholesalePrice != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed:
                            () =>
                                price.text =
                                    p.wholesalePrice!.toDecimalString(),
                        child: Text(
                          'Use wholesale price ${p.wholesalePrice!.format()}',
                        ),
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed:
                    () =>
                        key.currentState!.validate()
                            ? Navigator.pop(ctx, true)
                            : null,
                child: const Text('Update'),
              ),
            ],
          ),
    );
    if (res != true) return;
    _updateLine(
      i,
      it.copyWith(
        qty: Qty.parse(qty.text),
        unitPrice: Money.parse(price.text),
        discount: Money.tryParse(disc.text) ?? const Money.zero(),
      ),
    );
  }

  Future<void> _chooseCustomer() async {
    final list = app.parties.list(PartyKind.customer);
    final picked = await pickFromList<Party>(
      context,
      title: 'Select customer',
      items: list,
      label: (p) => p.name,
      subtitle:
          (p) => [
            p.phone,
            if (p.balance.isPositive) 'Owes ${p.balance.format()}',
          ].where((e) => e.isNotEmpty).join(' • '),
      footer: Align(
        alignment: Alignment.centerRight,
        child: FilledButton.icon(
          icon: const Icon(Icons.person_add_alt_1, size: 18),
          label: const Text('New customer'),
          onPressed: () async {
            final created = await showPartyForm(
              context,
              ref,
              PartyKind.customer,
            );
            if (created != null && mounted) {
              Navigator.of(context).pop();
              _setCustomer(created);
            }
          },
        ),
      ),
    );
    if (picked != null) _setCustomer(picked);
  }

  void _setCustomer(Party? p) {
    final d = draft;
    _set(
      p == null
          ? d.copyWith(clearCustomer: true, customerName: 'Walk-in Customer')
          : d.copyWith(customerId: p.id, customerName: p.name),
    );
    if (p != null &&
        app.technicians.pendingInstallations(customerId: p.id).isNotEmpty) {
      _toast(
        '${p.name} has installed material that is not invoiced yet. Use "Add installed items".',
      );
    }
  }

  // ───────── hold / complete ─────────

  Future<void> _hold() async {
    final d = draft;
    if (d.items.isEmpty) return;
    final ok = await runAction(
      context,
      () => app.sales.saveDraft(d),
      success: 'Bill held. Find it under "Held bills".',
    );
    if (ok) _newBill();
  }

  void _newBill() {
    _paidTouched = false;
    _paidCtl.clear();
    _discCtl.clear();
    _qcName.clear();
    _qcPhone.clear();
    ref.read(posDraftProvider.notifier).state = app.sales.newDraft();
    _scanFocus.requestFocus();
  }

  Future<void> _complete() async {
    if (draft.items.isEmpty) return _toast('Add products first.', error: true);
    // A name or mobile typed for a walk-in: save that customer with the bill
    // (an existing customer with the same mobile number is reused).
    if (draft.customerId == null && (_qcName.text.trim().isNotEmpty || _qcPhone.text.trim().isNotEmpty)) {
      try {
        final p = await app.parties.findOrCreateCustomer(name: _qcName.text, phone: _qcPhone.text);
        if (!mounted) return;
        _setCustomer(p);
      } catch (e) {
        if (mounted) _toast(friendlyError(e), error: true);
        return;
      }
    }
    // Labour / installation stays on the customer's invoice (part of what
    // they pay); it is marked with the worker's name and kept out of shop
    // sales and profit.
    final worker = _worker.text.trim();
    var d = draft.copyWith(items: [
      for (final it in draft.items) it.kind == SaleLineKind.service && worker.isNotEmpty ? it.copyWith(worker: worker) : it,
    ]);
    final paid = Money.tryParse(_paidCtl.text) ?? const Money.zero();
    final change = paid > d.total ? paid - d.total : const Money.zero();
    final shopPaid = paid > d.total ? d.total : paid;
    d = d.copyWith(paidAtSale: shopPaid);
    if (d.paidAtSale < d.total && d.customerId == null) {
      final go = await confirmDialog(
        context,
        title: 'Credit sale',
        message:
            'Unpaid balance ${(d.total - d.paidAtSale).format()} must go on a customer account.\nSelect an existing customer or create one for this walk-in customer.',
        confirm: 'Choose customer',
      );
      if (!go) return;
      await _chooseCustomer();
      return;
    }
    Authorization? approval;
    if (app.sales.needsCreditApproval(d)) {
      // No sign-in: the app always runs as the shop owner, whose own
      // authority approves the credit (recorded on the invoice as before).
      approval = app.auth.selfAuthorization(Permission.approveCredit);
      if (approval == null) {
        _toast('Credit needs the owner\'s approval.', error: true);
        return;
      }
    }
    Sale sale;
    try {
      sale = await app.sales.complete(d, creditApproval: approval);
    } catch (e) {
      if (mounted) _toast(friendlyError(e), error: true);
      return;
    }
    if (!mounted) return;
    _newBill();
    _worker.clear();
    await _afterSale(sale, change);
  }

  Future<void> _afterSale(Sale sale, Money change) async {
    final st = app.ctx.settings;
    final cashier = ref.read(currentUserProvider)?.displayName ?? '';
    final customer =
        sale.customerId == null
            ? null
            : app.parties.byId(PartyKind.customer, sale.customerId!);
    final paper = paperFromSetting(st.receiptFormat);
    if (st.autoPrintReceipt && (st.printerName ?? '').isNotEmpty) {
      final bytes = await invoicePdf(
        st,
        sale,
        customer: customer,
        paper: paper,
        cashier: cashier,
      );
      if (mounted) await quickPrint(context, st, bytes, name: sale.number);
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final c = AppTheme.of(ctx);
        return AppShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.enter):
                () => Navigator.pop(ctx),
          },
          child: Dialog(
            child: SizedBox(
              width: 440,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: 1),
                      duration: const Duration(milliseconds: 600),
                      curve: Curves.elasticOut,
                      builder:
                          (_, t, child) =>
                              Transform.scale(scale: t, child: child),
                      child: Icon(
                        Icons.check_circle_rounded,
                        size: 72,
                        color: c.accent,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Sale completed',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: c.text,
                      ),
                    ),
                    Text(sale.number, style: TextStyle(color: c.textMuted)),
                    const SizedBox(height: 18),
                    InfoRow('Total', sale.total.format(), strong: true),
                    InfoRow('Paid', sale.paidAtSale.format()),
                    if (change.isPositive)
                      InfoRow(
                        'Change to return',
                        change.format(),
                        strong: true,
                        color: c.warning,
                      ),
                    if (sale.remaining.isPositive)
                      InfoRow(
                        'On account (${sale.customerName})',
                        sale.remaining.format(),
                        color: c.warning,
                      ),
                    if (sale.labourRevenue.isPositive)
                      InfoRow(
                        "Of which labour (worker's, not shop profit)",
                        sale.labourRevenue.format(),
                      ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.receipt_long, size: 18),
                            label: const Text('Receipt'),
                            onPressed:
                                () => showPdf(
                                  ctx,
                                  st,
                                  () => invoicePdf(
                                    st,
                                    sale,
                                    customer: customer,
                                    paper: paper,
                                    cashier: cashier,
                                  ),
                                  name: sale.number,
                                ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(
                              Icons.description_outlined,
                              size: 18,
                            ),
                            label: const Text('A4 Invoice'),
                            onPressed:
                                () => showPdf(
                                  ctx,
                                  st,
                                  () => invoicePdf(
                                    st,
                                    sale,
                                    customer: customer,
                                    cashier: cashier,
                                  ),
                                  name: sale.number,
                                ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('New sale  (Enter)'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
    _scanFocus.requestFocus();
  }

  Future<void> _openHeld() async {
    final held =
        app.sales
            .list(status: DocStatus.draft)
            .where((s0) => s0.items.isNotEmpty)
            .toList();
    if (held.isEmpty) return _toast('No held bills.');
    final pick = await pickFromList<Sale>(
      context,
      title: 'Held bills',
      items: held,
      label: (s0) => '${s0.customerName} • ${s0.items.length} item(s)',
      subtitle:
          (s0) =>
              '${dateTimeFmt.format(s0.date)}${s0.notes.isEmpty ? '' : ' • ${s0.notes}'}',
      trailing: (s0) => Text(s0.total.format()),
    );
    if (pick == null || !mounted) return;
    if (draft.items.isNotEmpty) {
      final go = await confirmDialog(
        context,
        title: 'Replace current bill?',
        message: 'The current bill will be held first.',
        confirm: 'Hold & open',
      );
      if (!go) return;
      await app.sales.saveDraft(draft);
      if (!mounted) return;
    }
    ref.read(posDraftProvider.notifier).state = pick;
    _paidCtl.text =
        pick.paidAtSale.isZero
            ? pick.total.toDecimalString()
            : pick.paidAtSale.toDecimalString();
    _discCtl.text =
        pick.invoiceDiscount.isZero
            ? ''
            : pick.invoiceDiscount.toDecimalString();
  }

  // ───────── UI ─────────

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    ref.watch(dataVersionProvider);
    final d = ref.watch(posDraftProvider) ?? draft;
    final products = app.catalog.search(_search).take(60).toList();
    final customer =
        d.customerId == null
            ? null
            : app.parties.byId(PartyKind.customer, d.customerId!);
    final pendingInstall =
        customer == null
            ? 0
            : app.technicians
                .pendingInstallations(customerId: customer.id)
                .where((u) => !d.items.any((e) => e.techUsageId == u.id))
                .length;
    final heldCount =
        app.sales
            .list(status: DocStatus.draft)
            .where((s0) => s0.items.isNotEmpty && s0.id != d.id)
            .length;
    final paid = Money.tryParse(_paidCtl.text) ?? const Money.zero();
    final change = paid > d.total ? paid - d.total : const Money.zero();
    final due = d.total - (paid > d.total ? d.total : paid);
    // Labour lines stay on the invoice; shown apart as the worker's money.
    final labourLines = d.items.where((e) => e.kind == SaleLineKind.service).toList();
    final labourTotal = Money.sum(labourLines.map((e) => e.net));
    final shopTotal = d.total - labourTotal;

    return ScannerKeyboardListener(
      config: app.ctx.settings.scanner,
      onScan: _onScanner,
      scanController: _scanCtl,
      scanFocus: _scanFocus,
      onScanFieldChanged: (v) => setState(() => _search = v),
      child: AppShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.f9): _complete,
          const SingleActivator(LogicalKeyboardKey.enter, control: true):
              _complete,
          const SingleActivator(LogicalKeyboardKey.f8): _hold,
          const SingleActivator(LogicalKeyboardKey.f4): _chooseCustomer,
          const SingleActivator(LogicalKeyboardKey.f3):
              () => _scanFocus.requestFocus(),
        },
        child: LayoutBuilder(
          builder: (context, outer) {
            // Bill panel: 460 px on wide screens, shrinking to 340 px so the
            // product grid keeps at least two usable columns on small laptops.
            final pad = outer.maxWidth < 1000 ? 14.0 : 20.0;
            final billWidth = (outer.maxWidth * 0.42).clamp(340.0, 460.0);
            return Padding(
              padding: EdgeInsets.all(pad),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ── Left: scan + product grid
                  Expanded(
                    flex: 5,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Wrap(
                          alignment: WrapAlignment.spaceBetween,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 12,
                          runSpacing: 4,
                          children: [
                            Text(
                              'Point of Sale',
                              style: TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.w700,
                                color: c.text,
                              ),
                            ),
                            Text(
                              'F3 scan • F4 customer • F8 hold • F9 pay',
                              style: TextStyle(
                                color: c.textMuted,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        ScannerField(
                          focusNode: _scanFocus,
                          controller: _scanCtl,
                          onScan: _onScan,
                          onChanged: (v) => setState(() => _search = v),
                        ),
                        const SizedBox(height: 12),
                        Expanded(
                          child:
                              products.isEmpty
                                  ? const EmptyState(
                                    icon: Icons.search_off,
                                    title: 'No products found',
                                    message:
                                        'Scan a barcode or type part of a name, SKU or model.',
                                  )
                                  : LayoutBuilder(
                                    builder: (_, cons) {
                                      final cols = (cons.maxWidth / 190)
                                          .floor()
                                          .clamp(1, 6);
                                      // Fixed tile height: an aspect ratio made tiles too short
                                      // for a two-line name on narrow windows.
                                      return Scrollbar(
                                        controller: _gridScroll,
                                        thumbVisibility: true,
                                        interactive: true,
                                        thickness: 8,
                                        child: GridView.builder(
                                        key: const ValueKey('pos-grid'),
                                        controller: _gridScroll,
                                        padding: const EdgeInsets.only(right: 12),
                                        itemCount: products.length,
                                        gridDelegate:
                                            SliverGridDelegateWithFixedCrossAxisCount(
                                              crossAxisCount: cols,
                                              mainAxisSpacing: 12,
                                              crossAxisSpacing: 12,
                                              mainAxisExtent: 128,
                                            ),
                                        itemBuilder:
                                            (_, k) => _ProductTile(
                                              product: products[k],
                                              onTap:
                                                  () =>
                                                      _addProduct(products[k]),
                                            ),
                                      ),
                                      );
                                    },
                                  ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: pad),
                  // ── Right: bill
                  SizedBox(
                    width: billWidth,
                    child: AppCard(
                      padding: const EdgeInsets.all(16),
                      child: LayoutBuilder(
                        builder: (context, bill) {
                          // Three layouts by height, each with ONE scrolling area for
                          // the bill lines (no list nested inside another scroll view,
                          // which trapped the mouse wheel and hid lines):
                          //  * tall: customer on top, lines scroll, totals fixed below;
                          //  * medium: customer and lines scroll together, totals fixed;
                          //  * very short: everything scrolls as one page.
                          final tall = bill.maxHeight >= 760;
                          final tiny = bill.maxHeight < 520;
                          Widget line(int i) => _CartLine(
                                item: d.items[i],
                                product: app.catalog.byId(d.items[i].productId),
                                onEdit: () => _editLine(i),
                                onRemove: () => _removeLine(i),
                                onQty: (q) => _updateLine(i, d.items[i].copyWith(qty: q)),
                              );
                          final emptyCart = Padding(
                            padding: const EdgeInsets.symmetric(vertical: 24),
                            child: Center(
                              child: Text(
                                'Scan or click a product to start',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: c.textMuted),
                              ),
                            ),
                          );
                          Widget bar(Widget child) => ScrollbarTheme(
                                data: ScrollbarThemeData(
                                  thumbColor: WidgetStatePropertyAll(c.textMuted.withValues(alpha: 0.55)),
                                  radius: const Radius.circular(8),
                                ),
                                child: Scrollbar(
                                  controller: _billScroll,
                                  thumbVisibility: true,
                                  interactive: true,
                                  thickness: 8,
                                  child: child,
                                ),
                              );
                          final cart =
                              d.items.isEmpty
                                  ? emptyCart
                                  : ListView.separated(
                                    key: const ValueKey('pos-cart'),
                                    controller: _billScroll,
                                    padding: const EdgeInsets.only(right: 12),
                                    itemCount: d.items.length,
                                    separatorBuilder:
                                        (_, __) =>
                                            Divider(height: 1, color: c.border),
                                    itemBuilder:
                                        (_, i) => _CartLine(
                                          item: d.items[i],
                                          product: app.catalog.byId(
                                            d.items[i].productId,
                                          ),
                                          onEdit: () => _editLine(i),
                                          onRemove: () => _removeLine(i),
                                          onQty:
                                              (q) => _updateLine(
                                                i,
                                                d.items[i].copyWith(qty: q),
                                              ),
                                        ),
                                  );
                          final addItem = Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton.icon(
                                key: const ValueKey('pos-add-item'),
                                onPressed: _addItem,
                                icon: const Icon(Icons.add, size: 18),
                                label: const Text('Add Item (product, non-stock, service)'),
                              ),
                            ),
                          );
                          final top = <Widget>[
                            Row(
                              children: [
                                Icon(
                                  Icons.person_outline,
                                  color: c.textMuted,
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        d.customerName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontWeight: FontWeight.w700,
                                          color: c.text,
                                        ),
                                      ),
                                      if (customer != null)
                                        Text(
                                          'Balance ${customer.balance.format()}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 12,
                                            color:
                                                customer.balance.isPositive
                                                    ? c.warning
                                                    : c.textMuted,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                if (customer != null)
                                  IconButton(
                                    tooltip: 'Walk-in',
                                    onPressed: () => _setCustomer(null),
                                    icon: const Icon(Icons.close, size: 18),
                                  ),
                                TextButton(
                                  onPressed: _chooseCustomer,
                                  child: Text(
                                    customer == null
                                        ? 'Customer (F4)'
                                        : 'Change',
                                  ),
                                ),
                              ],
                            ),
                            if (customer == null)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Row(children: [
                                  Expanded(
                                    child: TextField(
                                      key: const ValueKey('pos-qc-name'),
                                      controller: _qcName,
                                      decoration: const InputDecoration(isDense: true, labelText: 'Customer name (optional)'),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: TextField(
                                      key: const ValueKey('pos-qc-phone'),
                                      controller: _qcPhone,
                                      keyboardType: TextInputType.phone,
                                      decoration: const InputDecoration(isDense: true, labelText: 'Mobile (optional)'),
                                    ),
                                  ),
                                ]),
                              ),
                            if (customer == null)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Builder(builder: (_) {
                                  final typed = _qcName.text.trim().isNotEmpty || _qcPhone.text.trim().isNotEmpty;
                                  final match = typed ? app.parties.matchCustomer(name: _qcName.text, phone: _qcPhone.text) : null;
                                  if (match == null) {
                                    return Text(
                                        typed
                                            ? 'New customer: saved to Customers with this bill.'
                                            : 'Filled in: the customer is saved to Customers with this bill.',
                                        key: const ValueKey('pos-qc-hint'),
                                        style: TextStyle(color: c.textMuted, fontSize: 11));
                                  }
                                  final bal = match.balance;
                                  final balText = bal.isPositive
                                      ? 'baqaya ${bal.format()}'
                                      : bal.isNegative
                                          ? 'advance ${(-bal).format()}'
                                          : 'no balance';
                                  final ph = match.phone.isEmpty ? '' : ' · ${match.phone}';
                                  return Text('Existing customer: ${match.name}$ph ($balText). This bill goes to the same account.',
                                      key: const ValueKey('pos-qc-hint'),
                                      style: TextStyle(color: c.accent, fontSize: 11, fontWeight: FontWeight.w600));
                                }),
                              ),
                            if (pendingInstall > 0)
                              Container(
                                margin: const EdgeInsets.only(top: 6),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: c.warning.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Wrap(
                                  alignment: WrapAlignment.spaceBetween,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    Text(
                                      '$pendingInstall installed item(s) not invoiced',
                                      style: TextStyle(
                                        color: c.warning,
                                        fontSize: 12.5,
                                      ),
                                    ),
                                    TextButton(
                                      onPressed:
                                          () => _addInstallations(customer!),
                                      child: const Text('Add installed items'),
                                    ),
                                  ],
                                ),
                              ),
                            const Divider(height: 20),
                          ];
                          final bottom = <Widget>[
                            const Divider(height: 16),
                            InfoRow(
                              'Subtotal',
                              (d.subtotal - d.lineDiscounts).format(),
                            ),
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'Bill discount',
                                    style: TextStyle(color: c.textMuted),
                                  ),
                                ),
                                SizedBox(
                                  width: 130,
                                  child: TextField(
                                    controller: _discCtl,
                                    inputFormatters: moneyInput,
                                    textAlign: TextAlign.right,
                                    decoration: const InputDecoration(
                                      isDense: true,
                                      hintText: '0',
                                    ),
                                    onChanged:
                                        (v) => _set(
                                          d.copyWith(
                                            invoiceDiscount:
                                                Money.tryParse(v) ??
                                                const Money.zero(),
                                          ),
                                        ),
                                  ),
                                ),
                              ],
                            ),
                            if (labourLines.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              InfoRow('Shop items (products + non-stock)', shopTotal.format()),
                              InfoRow("Labour / installation (karegar's)", labourTotal.format(), color: c.warning),
                              const SizedBox(height: 4),
                              TextField(
                                key: const ValueKey('pos-worker'),
                                controller: _worker,
                                decoration: const InputDecoration(
                                  isDense: true,
                                  labelText: 'Karegar / worker name',
                                  hintText: 'who did the installation',
                                ),
                              ),
                            ],
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Text(
                                  'TOTAL',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    color: c.text,
                                    letterSpacing: 1,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Align(
                                    alignment: Alignment.centerRight,
                                    child: FittedBox(
                                      fit: BoxFit.scaleDown,
                                      child: AnimatedSwitcher(
                                        duration: const Duration(
                                          milliseconds: 200,
                                        ),
                                        transitionBuilder:
                                            (w, a) => ScaleTransition(
                                              scale: Tween(
                                                begin: 0.9,
                                                end: 1.0,
                                              ).animate(a),
                                              child: w,
                                            ),
                                        child: Text(
                                          d.total.format(),
                                          key: ValueKey(d.total),
                                          style: TextStyle(
                                            fontSize: 28,
                                            fontWeight: FontWeight.w800,
                                            color: c.accent,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            // Payment method dropdown expands to its slot (AppDropdown sets
                            // isExpanded) so "JazzCash / Easypaisa" can never overflow.
                            FieldRow(gap: 10, [
                              AppDropdown<PaymentMethod>(
                                key: const ValueKey('pos-payment-method'),
                                value: d.method,
                                isDense: true,
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
                                onChanged: (v) => _set(d.copyWith(method: v)),
                              ),
                              TextField(
                                controller: _paidCtl,
                                inputFormatters: moneyInput,
                                decoration: const InputDecoration(
                                  labelText: 'Amount received',
                                ),
                                onChanged:
                                    (_) => setState(() => _paidTouched = true),
                                onSubmitted: (_) => _complete(),
                              ),
                            ]),
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                ActionChip(
                                  label: const Text('Exact'),
                                  onPressed:
                                      () => setState(
                                        () =>
                                            _paidCtl.text =
                                                d.total.toDecimalString(),
                                      ),
                                ),
                                for (final n in [500, 1000, 5000])
                                  ActionChip(
                                    label: Text('+$n'),
                                    onPressed:
                                        () => setState(() {
                                          _paidTouched = true;
                                          _paidCtl.text =
                                              ((Money.tryParse(_paidCtl.text) ??
                                                          const Money.zero()) +
                                                      Money.rupees(n))
                                                  .toDecimalString();
                                        }),
                                  ),
                                ActionChip(
                                  label: const Text('Credit (0)'),
                                  onPressed:
                                      () => setState(() {
                                        _paidTouched = true;
                                        _paidCtl.text = '0';
                                      }),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            if (change.isPositive)
                              InfoRow(
                                'Change',
                                change.format(),
                                strong: true,
                                color: c.warning,
                              ),
                            if (due.isPositive && d.items.isNotEmpty)
                              InfoRow(
                                'On credit',
                                due.format(),
                                color: c.warning,
                              ),
                            const SizedBox(height: 10),
                            LayoutBuilder(
                              builder: (context, row) {
                                final secondary = <Widget>[
                                  OutlinedButton(
                                    onPressed: d.items.isEmpty ? null : _hold,
                                    child: const Text('Hold (F8)'),
                                  ),
                                  const SizedBox(width: 8),
                                  Badge(
                                    isLabelVisible: heldCount > 0,
                                    label: Text('$heldCount'),
                                    child: OutlinedButton(
                                      onPressed: _openHeld,
                                      child: const Text('Held'),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  IconButton(
                                    tooltip: 'Clear bill',
                                    onPressed:
                                        d.items.isEmpty
                                            ? null
                                            : () async {
                                              if (await confirmDialog(
                                                context,
                                                title: 'Clear bill?',
                                                message:
                                                    'Remove all items from this bill?',
                                                confirm: 'Clear',
                                                danger: true,
                                              )) {
                                                if (app.sales.byId(d.id) !=
                                                    null) {
                                                  await app.sales.deleteDraft(
                                                    d.id,
                                                  );
                                                }
                                                _newBill();
                                              }
                                            },
                                    icon: Icon(
                                      Icons.delete_sweep_outlined,
                                      color: c.danger,
                                    ),
                                  ),
                                ];
                                final complete = FilledButton.icon(
                                  style: FilledButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 22,
                                      vertical: 18,
                                    ),
                                  ),
                                  onPressed: d.items.isEmpty ? null : _complete,
                                  icon: const Icon(Icons.check_rounded),
                                  label: const Text('Complete (F9)'),
                                );
                                // OverflowBar measures the buttons at the current text size:
                                // one row when they fit, otherwise Complete moves underneath
                                // (a fixed width breakpoint overflowed at 115% text size).
                                return OverflowBar(
                                  alignment: MainAxisAlignment.spaceBetween,
                                  overflowAlignment: OverflowBarAlignment.end,
                                  spacing: 8,
                                  overflowSpacing: 8,
                                  children: [
                                    Wrap(
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      children: secondary,
                                    ),
                                    SizedBox(
                                      width:
                                          row.maxWidth < 400
                                              ? row.maxWidth
                                              : null,
                                      child: complete,
                                    ),
                                  ],
                                );
                              },
                            ),
                          ];
                          if (tall) {
                            _billLinesEnd = null;
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                ...top,
                                addItem,
                                Expanded(child: d.items.isEmpty ? cart : bar(cart)),
                                ...bottom,
                              ],
                            );
                          }
                          // Lines are laid out inline in the single scroll area.
                          final lines = <Widget>[
                            if (d.items.isEmpty) emptyCart,
                            for (var i = 0; i < d.items.length; i++) ...[
                              if (i > 0) Divider(height: 1, color: c.border),
                              line(i),
                            ],
                            SizedBox(key: _linesEndKey, height: 1),
                          ];
                          if (tiny) {
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              final box = _linesEndKey.currentContext?.findRenderObject() as RenderBox?;
                              final view = _billScroll.hasClients ? _billScroll.position : null;
                              if (box == null || view == null || !box.attached) return;
                              final viewport = RenderAbstractViewport.maybeOf(box);
                              if (viewport == null) return;
                              _billLinesEnd = (viewport.getOffsetToReveal(box, 1.0).offset).clamp(0, view.maxScrollExtent).toDouble();
                            });
                          } else {
                            _billLinesEnd = null;
                          }
                          final area = bar(
                            SingleChildScrollView(
                              key: const ValueKey('pos-bill-scroll'),
                              controller: _billScroll,
                              padding: const EdgeInsets.only(right: 12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  ...top,
                                  addItem,
                                  ...lines,
                                  if (tiny) ...bottom,
                                ],
                              ),
                            ),
                          );
                          if (tiny) return area;
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(child: area),
                              ...bottom,
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ProductTile extends StatelessWidget {
  final Product product;
  final VoidCallback onTap;
  const _ProductTile({required this.product, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    final p = product;
    final tone =
        p.isOutOfStock ? c.danger : (p.isLowStock ? c.warning : c.accent);
    return AppCard(
      hoverLift: true,
      onTap: onTap,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            p.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontWeight: FontWeight.w600, color: c.text),
          ),
          Text(
            [p.brand, p.model].where((e) => e.isNotEmpty).join(' '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11.5, color: c.textMuted),
          ),
          const Spacer(),
          Row(
            children: [
              Expanded(
                child: Text(
                  p.sellingPrice.format(showDecimals: false),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontWeight: FontWeight.w700, color: c.text),
                ),
              ),
              if (p.requiresSerial)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Icon(Icons.qr_code_2, size: 14, color: c.textMuted),
                ),
              Flexible(
                child: StatusPill('${p.stockQty.format()} ${p.unit}', tone),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Serial numbers of a bill line; long lists show the first few with
/// "+N more" so one line with 50 cameras does not fill the whole bill.
class _SerialChips extends StatefulWidget {
  final List<String> serials;
  const _SerialChips(this.serials);
  @override
  State<_SerialChips> createState() => _SerialChipsState();
}

class _SerialChipsState extends State<_SerialChips> {
  static const _shown = 4;
  bool _all = false;
  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    final list = widget.serials;
    final visible = _all || list.length <= _shown + 1 ? list : list.take(_shown).toList();
    return Wrap(spacing: 4, runSpacing: 4, children: [
      for (final k in visible) StatusPill(SerialRecord.displayOf(k), c.textMuted),
      if (list.length > _shown + 1)
        InkWell(
          key: const ValueKey('pos-serials-more'),
          onTap: () => setState(() => _all = !_all),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: Text(_all ? 'Show less' : '+${list.length - _shown} more', style: TextStyle(fontSize: 12, color: c.accent, fontWeight: FontWeight.w600)),
          ),
        ),
    ]);
  }
}

class _CartLine extends StatelessWidget {
  final SaleItem item;
  final Product? product;
  final VoidCallback onEdit;
  final VoidCallback onRemove;
  final ValueChanged<Qty> onQty;
  const _CartLine({
    required this.item,
    required this.product,
    required this.onEdit,
    required this.onRemove,
    required this.onQty,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    final fixed = item.isStock &&
        (product == null || product!.requiresSerial || item.techUsageId != null);
    final step = const Qty.one();
    return InkWell(
      onTap: onEdit,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          item.name,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: c.text,
                          ),
                        ),
                      ),
                      if (!item.isStock) ...[
                        const SizedBox(width: 6),
                        LineKindPill(item),
                      ],
                    ],
                  ),
                  Text(
                    '${item.unitPrice.format()} × ${item.qty.format()} ${item.isStock ? (product?.unit ?? '') : item.unit}${item.discount.isZero ? '' : '  − ${item.discount.format()}'}',
                    style: TextStyle(fontSize: 12, color: c.textMuted),
                  ),
                  if (item.serials.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: _SerialChips(item.serials),
                    ),
                ],
              ),
            ),
            if (!fixed) ...[
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed:
                    item.qty > step ? () => onQty(item.qty - step) : null,
                icon: const Icon(Icons.remove_circle_outline, size: 20),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: () => onQty(item.qty + step),
                icon: const Icon(Icons.add_circle_outline, size: 20),
              ),
            ],
            SizedBox(
              width: 96,
              child: Align(
                alignment: Alignment.centerRight,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    item.net.format(showDecimals: false),
                    maxLines: 1,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: c.text,
                    ),
                  ),
                ),
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: 'Remove',
              onPressed: onRemove,
              icon: Icon(Icons.close, size: 18, color: c.danger),
            ),
          ],
        ),
      ),
    );
  }
}
