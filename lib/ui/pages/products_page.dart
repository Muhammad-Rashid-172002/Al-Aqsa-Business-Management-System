import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors.dart';
import '../../core/ids.dart';
import '../../core/money.dart';
import '../../core/qty.dart';
import '../../domain/models/product.dart';
import '../../domain/models/user.dart';
import '../../domain/services/catalog_service.dart';
import '../../domain/models/documents.dart';
import '../../domain/models/party.dart';
import '../../domain/services/app_services.dart';
import '../../domain/services/serial_service.dart';
import '../../export/tabular.dart';
import '../../printing/pdf_docs.dart';
import '../print_actions.dart';
import '../providers.dart';
import '../widgets/file_browser.dart';
import '../widgets/forms.dart';
import '../widgets/serial_entry.dart';
import '../theme.dart';
import '../widgets/common.dart';

class ProductsPage extends ConsumerStatefulWidget {
  const ProductsPage({super.key});
  @override
  ConsumerState<ProductsPage> createState() => _ProductsPageState();
}

class _ProductsPageState extends ConsumerState<ProductsPage> {
  String _q = '';
  String? _cat;
  String? _brand;
  bool _archived = false;

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    final app = ref.watch(liveServicesProvider);
    final user = ref.watch(currentUserProvider)!;
    final showCost = user.can(Permission.viewPurchasePrice);
    final cats = app.catalog.categories();
    final catName = {for (final x in cats) x.id: x.name};
    final rows =
        app.catalog
            .search(
              _q,
              categoryId: _cat,
              brand: _brand,
              includeArchived: _archived,
            )
            .where((p) => !_archived || p.archived)
            .toList();

    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Products',
            subtitle: '${rows.length} product(s)',
            breadcrumbs: const ['Products'],
            actions: [
              OutlinedButton.icon(
                onPressed: () => _importProducts(context, ref),
                icon: const Icon(Icons.upload_file, size: 18),
                label: const Text('Import Excel/CSV'),
              ),
              ExportMenu(tables: () => [ExportTable(
                        'Products',
                        [
                          'name',
                          'sku',
                          'category',
                          'brand',
                          'model',
                          'purchase_price',
                          'selling_price',
                          'min_stock',
                          'unit',
                          'decimal',
                          'serial',
                          'warranty_months',
                          'barcode',
                          'stock',
                        ],
                        [
                          for (final p in rows)
                            [
                              p.name,
                              p.sku,
                              catName[p.categoryId] ?? '',
                              p.brand,
                              p.model,
                              p.purchasePrice.paisa / 100,
                              p.sellingPrice.paisa / 100,
                              p.minStock.asDouble,
                              p.unit,
                              p.allowDecimal ? 'yes' : 'no',
                              p.requiresSerial ? 'yes' : 'no',
                              p.warrantyMonths,
                              p.barcodes
                                  .where((b0) => b0 != p.internalCode)
                                  .join(' '),
                              p.stockQty.asDouble,
                            ],
                        ],
                      )]),
              OutlinedButton.icon(
                onPressed: () => _printLabels(context, ref, rows),
                icon: const Icon(Icons.qr_code_2, size: 18),
                label: const Text('Print Labels'),
              ),
              FilledButton.icon(
                onPressed: () => showProductDialog(context, ref),
                icon: const Icon(Icons.add),
                label: const Text('Add Product'),
              ),
            ],
          ),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SearchBox(
                hint: 'Search name, SKU, model, barcode…',
                onChanged: (v) => setState(() => _q = v),
              ),
              SizedBox(
                width: 200,
                child: AppDropdown<String?>(
                  value: _cat,
                  decoration: const InputDecoration(labelText: 'Category'),
                  items: [
                    const DropdownMenuItem(
                      value: null,
                      child: Text('All categories'),
                    ),
                    for (final x in cats)
                      DropdownMenuItem(value: x.id, child: Text(x.name)),
                  ],
                  onChanged: (v) => setState(() => _cat = v),
                ),
              ),
              SizedBox(
                width: 180,
                child: AppDropdown<String?>(
                  value: _brand,
                  decoration: const InputDecoration(labelText: 'Brand'),
                  items: [
                    const DropdownMenuItem(
                      value: null,
                      child: Text('All brands'),
                    ),
                    for (final b0 in app.catalog.brands())
                      DropdownMenuItem(value: b0, child: Text(b0)),
                  ],
                  onChanged: (v) => setState(() => _brand = v),
                ),
              ),
              FilterChip(
                label: const Text('Show archived'),
                selected: _archived,
                onSelected: (v) => setState(() => _archived = v),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: SingleChildScrollView(
              child: AppTable<Product>(
                rows: rows,
                onRowTap: (p) => showProductDialog(context, ref, existing: p),
                empty: EmptyState(
                  icon: Icons.inventory_2_outlined,
                  title:
                      _q.isEmpty
                          ? 'No products yet'
                          : 'No products match your search',
                  message:
                      _q.isEmpty
                          ? 'Add your first CCTV product to start tracking stock.'
                          : 'Try a different name, SKU or barcode.',
                  action:
                      _q.isEmpty
                          ? FilledButton.icon(
                            onPressed: () => showProductDialog(context, ref),
                            icon: const Icon(Icons.add),
                            label: const Text('Add Product'),
                          )
                          : null,
                ),
                columns: [
                  AppColumn(
                    'Product',
                    flex: 4,
                    minWidth: 180,
                    (p) => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          p.name,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          [
                            p.brand,
                            p.model,
                            catName[p.categoryId] ?? '',
                          ].where((e) => e.isNotEmpty).join(' • '),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: c.textMuted, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  AppColumn(
                    'Code / SKU',
                    flex: 2,
                    (p) => Text(
                      p.sku,
                      style: TextStyle(
                        color: c.textMuted,
                        fontFamily: 'Consolas',
                      ),
                    ),
                  ),
                  if (showCost)
                    AppColumn(
                      'Cost',
                      numeric: true,
                      (p) => Text(p.purchasePrice.format(showDecimals: false)),
                    ),
                  AppColumn(
                    'Price',
                    numeric: true,
                    (p) => Text(
                      p.sellingPrice.format(showDecimals: false),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  AppColumn('Stock', numeric: true, (p) {
                    final tone =
                        p.isOutOfStock
                            ? c.danger
                            : (p.stockQty <= p.minStock ? c.warning : c.accent);
                    return StatusPill('${p.stockQty.format()} ${p.unit}', tone);
                  }),
                  AppColumn(
                    'With Techs',
                    numeric: true,
                    (p) =>
                        Text(p.issuedQty.isZero ? '—' : p.issuedQty.format()),
                  ),
                  AppColumn(
                    'Tracking',
                    flex: 2,
                    minWidth: 120,
                    (p) => Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        if (p.requiresSerial)
                          Tooltip(
                            message: 'Show serial numbers',
                            child: InkWell(
                              borderRadius: BorderRadius.circular(8),
                              onTap:
                                  () => showProductDetails(
                                    context,
                                    p.id,
                                    initialTab: 1,
                                  ),
                              child: StatusPill('Serial', c.accent),
                            ),
                          ),
                        if (p.warrantyMonths > 0)
                          StatusPill(
                            '${p.warrantyMonths}m warranty',
                            const Color(0xFF6FB8FF),
                          ),
                        if (p.archived) StatusPill('Archived', c.textMuted),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _importProducts(BuildContext context, WidgetRef ref) async {
  final path = await browseFiles(
    context,
    mode: BrowseMode.openFile,
    title: 'Choose Excel (.xlsx) or CSV file',
    extensions: const ['.xlsx', '.csv'],
  );
  if (path == null || !context.mounted) return;
  try {
    final bytes = await File(path).readAsBytes();
    final rows =
        path.toLowerCase().endsWith('.csv')
            ? parseCsv(utf8.decode(bytes, allowMalformed: true))
            : readXlsx(bytes);
    // Files exported by this app start with a title block: read from the
    // row that holds the column names.
    final start = rows.indexWhere(
      (r0) => r0.any((c0) => c0.trim().toLowerCase() == 'name'),
    );
    final maps = rowsToMaps(start <= 0 ? rows : rows.sublist(start));
    if (maps.isEmpty) throw const FormatException('The file has no data rows.');
    final msgs = await ref.read(servicesProvider).catalog.bulkImport(maps);
    if (!context.mounted) return;
    final ok = msgs.where((m0) => m0.endsWith('imported')).length;
    await showDialog<void>(
      context: context,
      builder:
          (ctx) => FormDialog(
            title: 'Import finished: $ok of ${msgs.length} imported',
            width: 620,
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final m0 in msgs)
                  Text(
                    m0,
                    style: TextStyle(
                      color:
                          m0.endsWith('imported')
                              ? null
                              : AppTheme.of(ctx).danger,
                    ),
                  ),
              ],
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('OK'),
              ),
            ],
          ),
    );
  } catch (e) {
    if (context.mounted) {
      showToast(
        context,
        'Import failed: ${friendlyError(e)}. Columns: name, sku, category, brand, model, purchase_price, selling_price, min_stock, unit, decimal, serial, warranty_months, barcode',
        error: true,
      );
    }
  }
}

Future<void> _printLabels(
  BuildContext context,
  WidgetRef ref,
  List<Product> products,
) async {
  final app = ref.read(servicesProvider);
  final copies = <String, int>{};
  await showDialog<void>(
    context: context,
    builder:
        (ctx) => StatefulBuilder(
          builder:
              (ctx, setS) => FormDialog(
                title: 'Print QR / barcode labels',
                width: 640,
                body: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Label size ${app.ctx.settings.labelWidthMm} × ${app.ctx.settings.labelHeightMm} mm (change in Settings). Labels use the product\'s internal code, which the scanner recognises.',
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      height: (MediaQuery.sizeOf(ctx).height * 0.5).clamp(
                        200.0,
                        380.0,
                      ),
                      child: ListView.builder(
                        itemCount: products.length,
                        itemBuilder: (_, i) {
                          final p = products[i];
                          return ListTile(
                            dense: true,
                            title: Text(p.name),
                            subtitle: Text(
                              '${p.internalCode} • stock ${p.stockQty.format()}',
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  onPressed:
                                      (copies[p.id] ?? 0) > 0
                                          ? () => setS(
                                            () =>
                                                copies[p.id] =
                                                    copies[p.id]! - 1,
                                          )
                                          : null,
                                  icon: const Icon(Icons.remove_circle_outline),
                                ),
                                SizedBox(
                                  width: 28,
                                  child: Text(
                                    '${copies[p.id] ?? 0}',
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                                IconButton(
                                  onPressed:
                                      () => setS(
                                        () =>
                                            copies[p.id] =
                                                (copies[p.id] ?? 0) + 1,
                                      ),
                                  icon: const Icon(Icons.add_circle_outline),
                                ),
                                TextButton(
                                  onPressed:
                                      p.stockQty.isPositive &&
                                              p.stockQty.isWhole
                                          ? () => setS(
                                            () =>
                                                copies[p.id] =
                                                    p.stockQty.wholeUnits,
                                          )
                                          : null,
                                  child: const Text('= stock'),
                                ),
                              ],
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
                    onPressed: () {
                      final jobs = [
                        for (final p in products)
                          if ((copies[p.id] ?? 0) > 0)
                            LabelJob(p, copies[p.id]!),
                      ];
                      if (jobs.isEmpty) {
                        return showToast(
                          ctx,
                          'Choose how many labels to print.',
                          error: true,
                        );
                      }
                      Navigator.pop(ctx);
                      showPdf(
                        context,
                        app.ctx.settings,
                        () => labelsPdf(app.ctx.settings, jobs),
                        name: 'Labels',
                      );
                    },
                    child: const Text('Preview & print'),
                  ),
                ],
              ),
        ),
  );
}

Future<void> showProductDialog(
  BuildContext context,
  WidgetRef ref, {
  Product? existing,
}) => showDialog<void>(
  context: context,
  builder: (_) => _ProductDialog(existing: existing),
);

class _ProductDialog extends ConsumerStatefulWidget {
  final Product? existing;
  const _ProductDialog({this.existing});
  @override
  ConsumerState<_ProductDialog> createState() => _ProductDialogState();
}

class _ProductDialogState extends ConsumerState<_ProductDialog> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.existing?.name);
  late final _sku = TextEditingController(text: widget.existing?.sku);
  late final _brand = TextEditingController(text: widget.existing?.brand);
  late final _model = TextEditingController(text: widget.existing?.model);
  late final _desc = TextEditingController(text: widget.existing?.description);
  late final _cost = TextEditingController(
    text: widget.existing?.purchasePrice.toDecimalString(),
  );
  late final _price = TextEditingController(
    text: widget.existing?.sellingPrice.toDecimalString(),
  );
  late final _whole = TextEditingController(
    text: widget.existing?.wholesalePrice?.toDecimalString(),
  );
  late final _min = TextEditingController(
    text: widget.existing?.minStock.format() ?? '2',
  );
  late final _unit = TextEditingController(
    text: widget.existing?.unit ?? 'pcs',
  );
  late final _warranty = TextEditingController(
    text: '${widget.existing?.warrantyMonths ?? 0}',
  );
  late final _barcodes = TextEditingController(
    text:
        widget.existing?.barcodes
            .where((b0) => b0 != widget.existing!.internalCode)
            .join(', ') ??
        '',
  );
  late String? _cat = widget.existing?.categoryId;
  late bool _serial = widget.existing?.requiresSerial ?? false;
  late bool _decimal = widget.existing?.allowDecimal ?? false;
  late String? _image = widget.existing?.imagePath;
  // Stock received with a new product (one purchase from the supplier).
  final _recvQty = TextEditingController();
  final _recvInv = TextEditingController();
  final _recvPaid = TextEditingController();
  String? _supplierId;
  List<String> _serials = [];
  bool _saving = false;

  @override
  void dispose() {
    for (final c0 in [_name, _sku, _brand, _model, _desc, _cost, _price, _whole, _min, _unit, _warranty, _barcodes, _recvQty, _recvInv, _recvPaid]) {
      c0.dispose();
    }
    super.dispose();
  }

  Qty get _receiving => Qty.tryParse(_recvQty.text.trim()) ?? const Qty.zero();
  String get _brandKey {
    final k = normalizeCode(_brand.text).replaceAll('|', '');
    return k.isEmpty ? 'GENERIC' : k;
  }

  Future<void> _pickImage() async {
    final path = await browseFiles(
      context,
      mode: BrowseMode.openFile,
      title: 'Product image (PNG/JPG)',
      extensions: const ['.png', '.jpg', '.jpeg', '.webp', '.bmp'],
    );
    if (path == null || !mounted) return;
    await runAction(context, () async {
      final saved = await ref
          .read(servicesProvider)
          .importMedia(path, folder: 'products');
      setState(() => _image = saved);
    });
  }

  Future<void> _enterSerials() async {
    final res = await showSerialEntry(
      context,
      app: ref.read(servicesProvider),
      productName: _name.text.trim().isEmpty ? 'New product' : _name.text.trim(),
      brandKey: _brandKey,
      quantity: _receiving.isWhole ? _receiving.wholeUnits : 0,
      initial: _serials,
    );
    if (res == null) return;
    setState(() {
      _serials = res.serials;
      _recvQty.text = '${res.quantity}';
    });
  }

  Future<void> _newSupplier() async {
    final ctl = TextEditingController();
    final phone = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('New supplier'),
            content: SizedBox(
              width: 340,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: ctl,
                    autofocus: true,
                    decoration: const InputDecoration(labelText: 'Supplier name'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: phone,
                    decoration: const InputDecoration(labelText: 'Phone'),
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
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Add'),
              ),
            ],
          ),
    );
    if (ok != true || ctl.text.trim().isEmpty || !mounted) return;
    await runAction(context, () async {
      final s0 = await ref
          .read(servicesProvider)
          .parties
          .create(kind: PartyKind.supplier, name: ctl.text, phone: phone.text);
      setState(() => _supplierId = s0.id);
    });
  }

  String? _money(String? v, {bool required = true}) {
    if ((v ?? '').trim().isEmpty) return required ? 'Required' : null;
    return Money.tryParse(v!) == null ? 'Enter a valid amount' : null;
  }

  String? _int(String? v) =>
      int.tryParse((v ?? '').trim()) == null ? 'Whole number' : null;
  String? _qty(String? v) =>
      Qty.tryParse((v ?? '').trim()) == null ? 'Enter a number' : null;

  ProductInput _input() => ProductInput(
    name: _name.text,
    sku: _sku.text,
    categoryId: _cat,
    brand: _brand.text,
    model: _model.text,
    description: _desc.text,
    purchasePrice: Money.parse(_cost.text),
    sellingPrice: Money.parse(_price.text),
    wholesalePrice:
        _whole.text.trim().isEmpty ? null : Money.parse(_whole.text),
    minStock: Qty.parse(_min.text.trim()),
    unit: _unit.text,
    allowDecimal: _decimal && !_serial,
    companyBarcodes:
        _barcodes.text
            .split(RegExp(r'[,\n]'))
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList(),
    requiresSerial: _serial,
    warrantyMonths: int.parse(_warranty.text.trim()),
    imagePath: _image,
  );

  /// New product with stock: product + purchase saved together.
  Future<bool> _saveWithStock(ProductInput input) async {
    final app = ref.read(servicesProvider);
    final qty = _receiving;
    var allowDuplicate = false;
    var approved = <String>{};
    while (true) {
      try {
        await app.createProductWithStock(
          input,
          allowDuplicate: allowDuplicate,
          supplierId: _supplierId!,
          qty: qty,
          unitCost: input.purchasePrice,
          serials: _serial ? _serials : const [],
          supplierInvoiceNo: _recvInv.text,
          paid: Money.tryParse(_recvPaid.text) ?? const Money.zero(),
          approvedSerialConflicts: approved,
        );
        return true;
      } on SerialConflictException catch (e) {
        if (!mounted) return false;
        final go = await confirmDialog(
          context,
          title: 'Serial numbers already exist',
          message:
              '${e.conflicts.map((c0) => '${c0.serial}: ${c0.kind == SerialConflictKind.sameBrand ? 'already registered for this brand (${c0.existing.status.label})' : 'exists under brand ${c0.existing.brandKey}'}').join('\n')}\n\n'
              'Approve only if these are genuinely different physical units.',
          confirm: 'Approve and save',
          danger: true,
        );
        if (!go) return false;
        approved = {...approved, ...e.conflicts.map((c0) => c0.serial)};
      } on DuplicateException catch (e) {
        if (!mounted || allowDuplicate) rethrow;
        final go = await confirmDialog(
          context,
          title: 'Possible duplicate',
          message: '${e.message}\n\nSave anyway?',
          confirm: 'Save anyway',
        );
        if (!go) return false;
        allowDuplicate = true;
      }
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final receiving = widget.existing == null && _receiving.isPositive;
    if (receiving) {
      if (_supplierId == null) {
        return showToast(context, 'Select the supplier the stock came from.', error: true);
      }
      if (_serial && _serials.length != _receiving.wholeUnits) {
        return showToast(
          context,
          'Enter one serial number per unit: ${_serials.length} of ${_receiving.wholeUnits} entered.',
          error: true,
        );
      }
    }
    setState(() => _saving = true);
    final app = ref.read(servicesProvider);
    try {
      final input = _input();
      if (receiving) {
        if (!await _saveWithStock(input)) return;
      } else if (widget.existing == null) {
        try {
          await app.catalog.create(input);
        } on DuplicateException catch (e) {
          if (!mounted) return;
          final go = await confirmDialog(
            context,
            title: 'Possible duplicate',
            message: '${e.message}\n\nSave anyway?',
            confirm: 'Save anyway',
          );
          if (!go) return;
          await app.catalog.create(input, allowDuplicate: true);
        }
      } else {
        await app.catalog.update(widget.existing!.id, input);
      }
      if (mounted) {
        showToast(
          context,
          widget.existing != null
              ? 'Product updated'
              : receiving
              ? 'Product added with ${_receiving.format()} ${_unit.text.trim().isEmpty ? 'pcs' : _unit.text.trim()} in stock'
              : 'Product added',
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) showToast(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _newCategory() async {
    final ctl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('New category'),
            content: SizedBox(
              width: 320,
              child: TextField(
                controller: ctl,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Category name'),
                onSubmitted: (v) => Navigator.pop(ctx, v),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, ctl.text),
                child: const Text('Add'),
              ),
            ],
          ),
    );
    if (name == null || name.trim().isEmpty || !mounted) return;
    await runAction(context, () async {
      final cat = await ref.read(servicesProvider).catalog.saveCategory(name);
      setState(() => _cat = cat.id);
    });
  }

  Widget _imageRow(AppColors c) {
    final path = _image;
    final exists = path != null && path.isNotEmpty && File(path).existsSync();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              border: Border.all(color: c.border),
              borderRadius: BorderRadius.circular(10),
            ),
            clipBehavior: Clip.antiAlias,
            child:
                exists
                    ? Image.file(File(path), fit: BoxFit.cover, cacheWidth: 128)
                    : Icon(Icons.image_outlined, color: c.textMuted),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton.icon(
                  key: const ValueKey('product-image'),
                  onPressed: _pickImage,
                  icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
                  label: Text(exists ? 'Change image' : 'Add product image'),
                ),
                if (path != null && path.isNotEmpty)
                  TextButton(
                    onPressed: () => setState(() => _image = null),
                    child: const Text('Remove image'),
                  ),
                if (path != null && path.isNotEmpty && !exists)
                  Text(
                    'Image file missing',
                    style: TextStyle(color: c.warning, fontSize: 12),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _receiveSection(AppColors c, AppServices app) {
    final qty = _receiving;
    final units = qty.isWhole ? qty.wholeUnits : 0;
    final serialsOk = !_serial || (units > 0 && _serials.length == units);
    final suppliers = app.parties.list(PartyKind.supplier);
    return Container(
      margin: const EdgeInsets.only(top: 8, bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Stock received now (optional)',
            style: TextStyle(fontWeight: FontWeight.w700, color: c.text),
          ),
          const SizedBox(height: 4),
          Text(
            'Bought several identical units? Create ONE product and enter the quantity here — '
            'it is saved as a purchase from the supplier together with the product.'
            '${_serial ? ' Each unit needs its own serial number.' : ''}',
            style: TextStyle(color: c.textMuted, fontSize: 12),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 160,
                child: TextField(
                  key: const ValueKey('receive-qty'),
                  controller: _recvQty,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(
                      RegExp(_decimal && !_serial ? r'[0-9.]' : r'[0-9]'),
                    ),
                  ],
                  decoration: const InputDecoration(labelText: 'Quantity received'),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              SizedBox(
                width: 260,
                child: Row(
                  children: [
                    Expanded(
                      child: AppDropdown<String?>(
                        key: const ValueKey('receive-supplier'),
                        value: _supplierId,
                        decoration: const InputDecoration(labelText: 'Supplier'),
                        items: [
                          const DropdownMenuItem(value: null, child: Text('Select supplier')),
                          for (final s0 in suppliers)
                            DropdownMenuItem(value: s0.id, child: Text(s0.name)),
                        ],
                        onChanged: (v) => setState(() => _supplierId = v),
                      ),
                    ),
                    IconButton(
                      tooltip: 'New supplier',
                      onPressed: _newSupplier,
                      icon: const Icon(Icons.person_add_alt),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 170,
                child: TextField(
                  controller: _recvInv,
                  decoration: const InputDecoration(labelText: 'Supplier invoice no.'),
                ),
              ),
              SizedBox(
                width: 150,
                child: TextField(
                  controller: _recvPaid,
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
                  decoration: const InputDecoration(labelText: 'Paid now (Rs)'),
                ),
              ),
            ],
          ),
          if (_serial && qty.isPositive) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton.tonalIcon(
                  key: const ValueKey('receive-serials'),
                  onPressed: _enterSerials,
                  icon: Icon(serialsOk ? Icons.check_circle : Icons.qr_code_scanner, size: 18),
                  label: Text(_serials.isEmpty ? 'Enter $units serial numbers' : 'Edit serial numbers'),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Required $units • Entered ${_serials.length} • Remaining ${(units - _serials.length).clamp(0, units)}',
                    key: const ValueKey('receive-serial-progress'),
                    style: TextStyle(
                      color: serialsOk ? c.accent : c.warning,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (qty.isPositive) ...[
            const SizedBox(height: 8),
            Text(
              'Purchase value: ${((Money.tryParse(_cost.text) ?? const Money.zero()).timesQty(qty)).format()} at the purchase price above.',
              style: TextStyle(color: c.textMuted, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    final app = ref.watch(liveServicesProvider);
    final ex = widget.existing;
    Widget row(List<Widget> children) => Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: LayoutBuilder(
        builder: (_, cons) {
          // Three fields side by side need ~540 px; below that use two per row.
          final perRow =
              children.length <= 1
                  ? 1
                  : (cons.maxWidth < 360
                      ? 1
                      : (cons.maxWidth < 540 ? 2 : children.length));
          final w = (cons.maxWidth - (perRow - 1) * 14) / perRow;
          return Wrap(
            spacing: 14,
            runSpacing: 14,
            children: [
              for (final ch in children) SizedBox(width: w, child: ch),
            ],
          );
        },
      ),
    );
    final moneyFmt = [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))];
    final intFmt = [FilteringTextInputFormatter.digitsOnly];

    return AppShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
      },
      child: Dialog(
        insetPadding: EdgeInsets.symmetric(
          horizontal: MediaQuery.sizeOf(context).width < 700 ? 12 : 40,
          vertical: MediaQuery.sizeOf(context).height < 600 ? 12 : 24,
        ),
        child: SizedBox(
          width: 760,
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 22, 16, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Wrap(
                          spacing: 16,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              ex == null ? 'Add Product' : 'Edit Product',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                                color: c.text,
                              ),
                            ),
                            if (ex != null)
                              Text(
                                'Code: ${ex.internalCode}',
                                style: TextStyle(
                                  color: c.textMuted,
                                  fontFamily: 'Consolas',
                                ),
                              ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
                    child: Column(
                      children: [
                        row([
                          TextFormField(
                            controller: _name,
                            autofocus: true,
                            decoration: const InputDecoration(
                              labelText: 'Product name *',
                            ),
                            validator:
                                (v) =>
                                    (v ?? '').trim().isEmpty
                                        ? 'Required'
                                        : null,
                          ),
                        ]),
                        row([
                          Row(
                            children: [
                              Expanded(
                                child: AppDropdown<String?>(
                                  value: _cat,
                                  decoration: const InputDecoration(
                                    labelText: 'Category',
                                  ),
                                  items: [
                                    const DropdownMenuItem(
                                      value: null,
                                      child: Text('None'),
                                    ),
                                    for (final x in app.catalog.categories())
                                      DropdownMenuItem(
                                        value: x.id,
                                        child: Text(x.name),
                                      ),
                                  ],
                                  onChanged: (v) => setState(() => _cat = v),
                                ),
                              ),
                              IconButton(
                                tooltip: 'New category',
                                onPressed: _newCategory,
                                icon: const Icon(Icons.add_circle_outline),
                              ),
                            ],
                          ),
                          TextFormField(
                            controller: _brand,
                            decoration: const InputDecoration(
                              labelText: 'Brand (e.g. Hikvision, Dahua)',
                            ),
                          ),
                          TextFormField(
                            controller: _model,
                            decoration: const InputDecoration(
                              labelText: 'Model',
                            ),
                          ),
                        ]),
                        row([
                          TextFormField(
                            controller: _cost,
                            inputFormatters: moneyFmt,
                            decoration: const InputDecoration(
                              labelText: 'Purchase price (Rs) *',
                            ),
                            validator: (v) => _money(v),
                          ),
                          TextFormField(
                            controller: _price,
                            inputFormatters: moneyFmt,
                            decoration: const InputDecoration(
                              labelText: 'Selling price (Rs) *',
                            ),
                            validator: (v) => _money(v),
                          ),
                          TextFormField(
                            controller: _whole,
                            inputFormatters: moneyFmt,
                            decoration: const InputDecoration(
                              labelText: 'Wholesale price (optional)',
                            ),
                            validator: (v) => _money(v, required: false),
                          ),
                        ]),
                        row([
                          TextFormField(
                            controller: _min,
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(
                                RegExp(r'[0-9.]'),
                              ),
                            ],
                            decoration: const InputDecoration(
                              labelText: 'Minimum stock alert',
                            ),
                            validator: _qty,
                          ),
                          TextFormField(
                            controller: _unit,
                            decoration: const InputDecoration(
                              labelText: 'Unit (pcs, roll, box)',
                            ),
                          ),
                          TextFormField(
                            controller: _warranty,
                            inputFormatters: intFmt,
                            decoration: const InputDecoration(
                              labelText: 'Warranty (months)',
                            ),
                            validator: _int,
                          ),
                        ]),
                        row([
                          TextFormField(
                            controller: _sku,
                            decoration: const InputDecoration(
                              labelText: 'SKU (leave empty to auto-generate)',
                            ),
                          ),
                          TextFormField(
                            controller: _barcodes,
                            decoration: const InputDecoration(
                              labelText:
                                  'Company barcode(s) — scan here, comma separated',
                              prefixIcon: Icon(Icons.qr_code_scanner),
                            ),
                          ),
                        ]),
                        row([
                          TextFormField(
                            controller: _desc,
                            maxLines: 2,
                            decoration: const InputDecoration(
                              labelText: 'Description',
                            ),
                          ),
                        ]),
                        _imageRow(c),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          value: _decimal && !_serial,
                          onChanged:
                              _serial
                                  ? null
                                  : (v) => setState(() => _decimal = v),
                          title: const Text('Allow decimal quantities'),
                          subtitle: Text(
                            'For items sold by length or weight, e.g. cable 1.5 m. Not available for serial-tracked items.',
                            style: TextStyle(color: c.textMuted, fontSize: 12),
                          ),
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          value: _serial,
                          onChanged: (v) => setState(() => _serial = v),
                          title: const Text('Track individual serial numbers'),
                          subtitle: Text(
                            'Turn on for DVR, NVR, cameras, hard disks. Each unit will need its own serial when bought and sold.',
                            style: TextStyle(color: c.textMuted, fontSize: 12),
                          ),
                        ),
                        if (ex == null) _receiveSection(c, app),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
                  // Left group (archive/history) and right group (save) wrap onto
                  // separate lines on narrow windows instead of overflowing.
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    runSpacing: 8,
                    children: [
                      Wrap(
                        spacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (ex != null)
                            TextButton.icon(
                              style: TextButton.styleFrom(
                                foregroundColor:
                                    ex.archived ? c.accent : c.danger,
                              ),
                              onPressed: () async {
                                final cat = ref.read(servicesProvider).catalog;
                                if (ex.archived) {
                                  await runAction(
                                    context,
                                    () => cat.restore(ex.id),
                                    success: 'Product restored',
                                  );
                                } else {
                                  final ok = await confirmDialog(
                                    context,
                                    title: 'Remove product?',
                                    message:
                                        'Products with history are archived (hidden but kept for reports). Products with no history are deleted.',
                                    confirm: 'Remove',
                                    danger: true,
                                  );
                                  if (!ok || !context.mounted) return;
                                  await runAction(context, () async {
                                    final archived = await cat.deleteOrArchive(
                                      ex.id,
                                    );
                                    if (context.mounted) {
                                      showToast(
                                        context,
                                        archived
                                            ? 'Product archived'
                                            : 'Product deleted',
                                      );
                                    }
                                  });
                                }
                                if (context.mounted) Navigator.pop(context);
                              },
                              icon: Icon(
                                ex.archived
                                    ? Icons.unarchive_outlined
                                    : Icons.archive_outlined,
                              ),
                              label: Text(
                                ex.archived ? 'Restore' : 'Archive / Delete',
                              ),
                            ),
                          if (ex != null)
                            TextButton.icon(
                              onPressed: () => _history(context, ref, ex),
                              icon: const Icon(Icons.history, size: 18),
                              label: Text(ex.requiresSerial ? 'Stock & serial numbers' : 'Stock & history'),
                            ),
                        ],
                      ),
                      Wrap(
                        spacing: 10,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            'Ctrl+S to save',
                            style: TextStyle(color: c.textMuted, fontSize: 12),
                          ),
                          OutlinedButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('Cancel'),
                          ),
                          FilledButton(
                            onPressed: _saving ? null : _save,
                            child:
                                _saving
                                    ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                    : const Text('Save Product'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _history(BuildContext context, WidgetRef ref, Product p) =>
    showProductDetails(context, p.id);

/// Product details: stock by unit status, every serial number with its full
/// story, purchases and sales.
Future<void> showProductDetails(
  BuildContext context,
  String productId, {
  int initialTab = 0,
}) => showDialog<void>(
  context: context,
  builder: (_) => _ProductDetails(productId: productId, initialTab: initialTab),
);

class _ProductDetails extends ConsumerStatefulWidget {
  final String productId;
  final int initialTab;
  const _ProductDetails({required this.productId, required this.initialTab});
  @override
  ConsumerState<_ProductDetails> createState() => _ProductDetailsState();
}

class _ProductDetailsState extends ConsumerState<_ProductDetails> {
  final _q = TextEditingController();
  SerialStatus? _status;

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  /// Units grouped the way the shop thinks about them.
  static const faulty = {
    SerialStatus.damaged,
    SerialStatus.underRepair,
    SerialStatus.awaitingRepair,
    SerialStatus.pendingInspection,
    SerialStatus.returned,
  };

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    final app = ref.watch(liveServicesProvider);
    final p = app.catalog.byId(widget.productId);
    if (p == null) {
      return FormDialog(
        title: 'Product',
        body: const Text('This product no longer exists.'),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      );
    }
    final sales =
        app.sales
            .list(status: DocStatus.completed)
            .where((s0) => s0.items.any((i0) => i0.productId == p.id))
            .take(100)
            .toList();
    final purchases =
        app.purchases
            .list(includeCancelled: false)
            .where((x) => x.items.any((i0) => i0.productId == p.id))
            .take(100)
            .toList();
    final counts = p.requiresSerial ? app.serials.statusCounts(p.id) : const <SerialStatus, int>{};
    int n(Iterable<SerialStatus> s0) => s0.fold(0, (a, b) => a + (counts[b] ?? 0));
    final all = app.serials.search(productId: p.id);
    final shown =
        all.where((r) {
          if (_status != null && r.status != _status) return false;
          final q = normalizeCode(_q.text);
          return q.isEmpty || r.serial.contains(q);
        }).toList();
    final suppliers = {for (final x in app.parties.list(PartyKind.supplier, includeInactive: true)) x.id: x.name};
    final customers = {for (final x in app.parties.list(PartyKind.customer, includeInactive: true)) x.id: x.name};
    final techs = {for (final x in app.technicians.technicians(includeInactive: true)) x.id: x.name};

    Widget stat(String label, String value, Color color) => Container(
      width: 150,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: color)),
          Text(label, style: TextStyle(color: c.textMuted, fontSize: 12)),
        ],
      ),
    );

    final stock = ListView(
      padding: const EdgeInsets.only(top: 12),
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children:
              p.requiresSerial
                  ? [
                    stat('Total units (all serials)', '${all.length}', c.text),
                    stat('Available (in stock)', '${n([SerialStatus.inStock])}', c.accent),
                    stat('Sold', '${n([SerialStatus.sold])}', c.primary),
                    stat('Installed', '${n([SerialStatus.installed])}', c.primary),
                    stat('With technicians', '${n([SerialStatus.issuedToTechnician])}', c.warning),
                    stat('Faulty / repair', '${n(faulty)}', c.danger),
                    stat('Returned to supplier', '${n([SerialStatus.returnedToSupplier, SerialStatus.replaced])}', c.textMuted),
                  ]
                  : [
                    stat('In stock', '${p.stockQty.format()} ${p.unit}', c.accent),
                    stat('With technicians', '${p.issuedQty.format()} ${p.unit}', c.warning),
                    stat('Damaged', '${p.damagedQty.format()} ${p.unit}', c.danger),
                    stat('Awaiting inspection', '${p.inspectionQty.format()} ${p.unit}', c.textMuted),
                  ],
        ),
        const SizedBox(height: 14),
        InfoRow('Sellable stock', '${p.stockQty.format()} ${p.unit}'),
        InfoRow('Brand / model', '${p.brand} ${p.model}'.trim().isEmpty ? '—' : '${p.brand} ${p.model}'),
        InfoRow('Purchase / selling price', '${p.purchasePrice.format()} / ${p.sellingPrice.format()}'),
        InfoRow('Warranty', p.warrantyMonths == 0 ? 'None' : '${p.warrantyMonths} months'),
        if (p.requiresSerial && n([SerialStatus.inStock]) != p.stockQty.milli ~/ 1000)
          InfoRow('Check', 'Serials in stock differ from the stock quantity — run Backup & Restore › Data integrity check.', color: c.danger),
      ],
    );

    Widget serialRow(SerialRecord r) {
      final pur = r.purchaseId == null ? null : app.purchases.byId(r.purchaseId!);
      final sale = r.saleId == null ? null : app.sales.byId(r.saleId!);
      final installed = r.history.lastWhereOrNull((e) => e.status == SerialStatus.installed);
      String d(DateTime? x) => x == null ? '—' : dateFmt.format(x);
      final details = <String>[
        'Bought ${d(r.purchaseDate)} from ${suppliers[r.supplierId] ?? '—'}${pur == null ? '' : ' • ${pur.number}${pur.supplierInvoiceNo.isEmpty ? '' : ' (inv ${pur.supplierInvoiceNo})'}'}',
        if (sale != null || r.customerId != null)
          'Sold ${d(sale?.date)} to ${customers[r.customerId] ?? sale?.customerName ?? '—'}${sale == null ? '' : ' • ${sale.number}'}',
        if (r.warrantyExpiry != null)
          'Warranty until ${d(r.warrantyExpiry)}${r.warrantyActiveOn(DateTime.now()) ? '' : ' (expired)'}',
        if (r.technicianId != null) 'Technician: ${techs[r.technicianId] ?? '—'}',
        if (installed != null) 'Installed ${d(installed.at)}${installed.note.isEmpty ? '' : ' • ${installed.note}'}',
      ];
      final color = switch (r.status) {
        SerialStatus.inStock => c.accent,
        SerialStatus.sold || SerialStatus.installed => c.primary,
        SerialStatus.issuedToTechnician => c.warning,
        _ when faulty.contains(r.status) => c.danger,
        _ => c.textMuted,
      };
      return ListTile(
        dense: true,
        title: Text(r.display, style: const TextStyle(fontFamily: 'Consolas', fontWeight: FontWeight.w600)),
        subtitle: Text(details.join('\n'), style: TextStyle(color: c.textMuted, fontSize: 12)),
        isThreeLine: details.length > 1,
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
          child: Text(r.status.label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
        ),
      );
    }

    final serialTab = Column(
      children: [
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 240,
              child: TextField(
                key: const ValueKey('serial-search'),
                controller: _q,
                decoration: const InputDecoration(labelText: 'Search serial number', prefixIcon: Icon(Icons.search)),
                onChanged: (_) => setState(() {}),
              ),
            ),
            SizedBox(
              width: 230,
              child: AppDropdown<SerialStatus?>(
                key: const ValueKey('serial-status-filter'),
                value: _status,
                decoration: const InputDecoration(labelText: 'Status'),
                items: [
                  DropdownMenuItem(value: null, child: Text('All (${all.length})')),
                  for (final s0 in SerialStatus.values)
                    if ((counts[s0] ?? 0) > 0)
                      DropdownMenuItem(value: s0, child: Text('${s0.label} (${counts[s0]})')),
                ],
                onChanged: (v) => setState(() => _status = v),
              ),
            ),
            Text('${shown.length} shown', style: TextStyle(color: c.textMuted)),
          ],
        ),
        const SizedBox(height: 6),
        Expanded(
          child:
              shown.isEmpty
                  ? Center(child: Text(all.isEmpty ? 'No serial numbers registered yet.' : 'No serial matches.', style: TextStyle(color: c.textMuted)))
                  : ListView.builder(itemCount: shown.length, itemBuilder: (_, i) => serialRow(shown[i])),
        ),
      ],
    );

    return DefaultTabController(
      length: p.requiresSerial ? 4 : 3,
      initialIndex: widget.initialTab.clamp(0, p.requiresSerial ? 3 : 2),
      child: FormDialog(
        title: p.name,
        width: 820,
        body: SizedBox(
          height: (MediaQuery.sizeOf(context).height * 0.62).clamp(260.0, 560.0),
          child: Column(
            children: [
              TabBar(
                isScrollable: true,
                tabs: [
                  const Tab(text: 'Stock'),
                  if (p.requiresSerial) Tab(text: 'Serial Numbers (${all.length})'),
                  const Tab(text: 'Purchases'),
                  const Tab(text: 'Sales'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    stock,
                    if (p.requiresSerial) serialTab,
                    ListView(
                      children: [
                        for (final x in purchases)
                          for (final it in x.items.where((i0) => i0.productId == p.id))
                            ListTile(
                              dense: true,
                              title: Text('${x.number} • ${dateFmt.format(x.date)} • ${suppliers[x.supplierId] ?? ''}'),
                              subtitle: Text('${it.qty.format()} ${p.unit} @ ${it.unitCost.format()}${it.serials.isEmpty ? '' : ' • ${it.serials.length} serial(s)'}'),
                              trailing: Text(it.net.format()),
                            ),
                      ],
                    ),
                    ListView(
                      children: [
                        for (final x in sales)
                          for (final it in x.items.where((i0) => i0.productId == p.id))
                            ListTile(
                              dense: true,
                              title: Text('${x.number} • ${dateFmt.format(x.date)} • ${x.customerName}'),
                              subtitle: Text(
                                '${it.qty.format()} ${p.unit} @ ${it.unitPrice.format()}${it.serials.isEmpty ? '' : ' • S/N ${it.serials.map(SerialRecord.displayOf).join(', ')}'}',
                              ),
                              trailing: Text(it.net.format()),
                            ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        ],
      ),
    );
  }
}

extension _LastWhere<T> on List<T> {
  T? lastWhereOrNull(bool Function(T) test) {
    for (var i = length - 1; i >= 0; i--) {
      if (test(this[i])) return this[i];
    }
    return null;
  }
}
