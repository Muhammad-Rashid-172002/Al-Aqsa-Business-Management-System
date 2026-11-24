import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors.dart';
import '../../core/scan_detector.dart';
import '../../data/store/data_store.dart';
import '../../domain/models/operations.dart';
import '../../domain/models/party.dart';
import '../../domain/services/app_services.dart';
import '../../domain/models/user.dart';
import '../../domain/services/report_tables.dart';
import '../../printing/pdf_docs.dart';
import '../print_actions.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/file_browser.dart';
import '../widgets/forms.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});
  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  late AppSettings _s = ref.read(servicesProvider).ctx.settings;
  late final _name = TextEditingController(text: _s.businessName);
  late final _addr = TextEditingController(text: _s.address);
  late final _phone = TextEditingController(text: _s.phone);
  late final _email = TextEditingController(text: _s.email);
  late final _contactPerson = TextEditingController(text: _s.contactPerson);
  late final _contactPhone = TextEditingController(text: _s.contactPhone);
  late final _footer = TextEditingController(text: _s.receiptFooter);
  late final _inv = TextEditingController(text: _s.invoicePrefix);
  late final _quo = TextEditingController(text: _s.quotationPrefix);
  late final _pur = TextEditingController(text: _s.purchasePrefix);
  late final _rep = TextEditingController(text: _s.repairPrefix);
  late final _terms = TextEditingController(text: _s.quotationTerms);
  late final _validity = TextEditingController(
    text: '${_s.quotationValidityDays}',
  );
  late final _lw = TextEditingController(text: '${_s.labelWidthMm}');
  late final _lh = TextEditingController(text: '${_s.labelHeightMm}');
  late final _scanGap = TextEditingController(text: '${_s.scannerKeyGapMs}');
  late final _scanMin = TextEditingController(text: '${_s.scannerMinLength}');
  late final _scanDup = TextEditingController(text: '${_s.scannerDuplicateMs}');
  List<String> _printers = [];

  @override
  void initState() {
    super.initState();
    availablePrinters().then((p) {
      if (mounted) setState(() => _printers = p);
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _addr.dispose();
    _phone.dispose();
    _email.dispose();
    _contactPerson.dispose();
    _contactPhone.dispose();
    _footer.dispose();
    _inv.dispose();
    _quo.dispose();
    _pur.dispose();
    _rep.dispose();
    _terms.dispose();
    _validity.dispose();
    _lw.dispose();
    _lh.dispose();
    _scanGap.dispose();
    _scanMin.dispose();
    _scanDup.dispose();
    super.dispose();
  }

  Future<void> _save(Map<String, dynamic> extra) async {
    final changes = {
      'businessName': _name.text.trim(),
      'address': _addr.text.trim(),
      'phone': _phone.text.trim(),
      'email': _email.text.trim(),
      'contactPerson': _contactPerson.text.trim(),
      'contactPhone': _contactPhone.text.trim(),
      'receiptFooter': _footer.text.trim(),
      'invoicePrefix': _inv.text.trim().toUpperCase(),
      'quotationPrefix': _quo.text.trim().toUpperCase(),
      'purchasePrefix': _pur.text.trim().toUpperCase(),
      'repairPrefix': _rep.text.trim().toUpperCase(),
      'quotationTerms': _terms.text.trim(),
      'quotationValidityDays': int.tryParse(_validity.text) ?? 15,
      'labelWidthMm': int.tryParse(_lw.text) ?? 50,
      'labelHeightMm': int.tryParse(_lh.text) ?? 25,
      'scannerKeyGapMs': int.tryParse(_scanGap.text) ?? 40,
      'scannerMinLength': int.tryParse(_scanMin.text) ?? 4,
      'scannerDuplicateMs': int.tryParse(_scanDup.text) ?? 700,
      ...extra,
    };
    try {
      final saved = await ref.read(servicesProvider).settings.save(changes);
      setState(() => _s = saved);
      if (mounted) showToast(context, 'Settings saved');
    } catch (e) {
      if (mounted) showToast(context, friendlyError(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    final app = ref.watch(liveServicesProvider);
    Widget section(String title, List<Widget> children) => Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 16,
                color: c.text,
              ),
            ),
            const SizedBox(height: 14),
            ...children,
          ],
        ),
      ),
    );
    return DefaultTabController(
      length: 3,
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PageHeader(
              title: 'Settings',
              breadcrumbs: const ['Settings'],
              actions: [
                FilledButton.icon(
                  onPressed: () => _save({}),
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('Save Settings'),
                ),
              ],
            ),
            TabBar(
              isScrollable: true,
              labelColor: c.accent,
              tabs: const [
                Tab(text: 'Business & Documents'),
                Tab(text: 'Printing & Labels'),
                Tab(text: 'Audit & Data'),
              ],
            ),
            const SizedBox(height: 14),
            Expanded(
              child: TabBarView(
                children: [
                  SingleChildScrollView(
                    child: Column(
                      children: [
                        section('Business', [
                          FieldRow([
                            LabeledField('Business name', _name),
                            LabeledField('Phone', _phone),
                          ]),
                          FieldRow([
                            LabeledField('Address', _addr),
                            LabeledField('Email', _email),
                          ]),
                          FieldRow([
                            LabeledField('Contact person (on invoices)', _contactPerson, key: const ValueKey('set-contact-person')),
                            LabeledField('Contact / WhatsApp number (on invoices)', _contactPhone, key: const ValueKey('set-contact-phone')),
                          ]),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'WhatsApp icon on printouts: ${(_s.whatsappIconPath ?? '').isEmpty ? 'green phone badge (no image chosen)' : _s.whatsappIconPath}',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(color: c.textMuted),
                                ),
                              ),
                              const SizedBox(width: 8),
                              OutlinedButton.icon(
                                key: const ValueKey('set-wa-icon'),
                                icon: const Icon(Icons.image_outlined, size: 18),
                                label: const Text('Choose WhatsApp icon'),
                                onPressed: () async {
                                  final path = await browseFiles(
                                    context,
                                    mode: BrowseMode.openFile,
                                    title: 'WhatsApp icon image (PNG/JPG)',
                                    extensions: const ['.png', '.jpg', '.jpeg'],
                                  );
                                  if (path != null) {
                                    final saved = await ref.read(servicesProvider).importMedia(path, folder: 'branding');
                                    await _save({'whatsappIconPath': saved});
                                  }
                                },
                              ),
                              if ((_s.whatsappIconPath ?? '').isNotEmpty)
                                TextButton(
                                  onPressed: () => _save({'whatsappIconPath': null}),
                                  child: const Text('Remove'),
                                ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'Logo: ${(_s.logoPath ?? '').isEmpty ? 'none' : _s.logoPath}',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(color: c.textMuted),
                                ),
                              ),
                              const SizedBox(width: 8),
                              OutlinedButton.icon(
                                icon: const Icon(
                                  Icons.image_outlined,
                                  size: 18,
                                ),
                                label: const Text('Choose logo'),
                                onPressed: () async {
                                  final path = await browseFiles(
                                    context,
                                    mode: BrowseMode.openFile,
                                    title: 'Logo image (PNG/JPG)',
                                    extensions: const ['.png', '.jpg', '.jpeg'],
                                  );
                                  if (path != null) {
                                    // Kept in the app's media folder so it is
                                    // included in backups and restored.
                                    final saved = await ref
                                        .read(servicesProvider)
                                        .importMedia(path, folder: 'logo');
                                    await _save({'logoPath': saved});
                                  }
                                },
                              ),
                              if ((_s.logoPath ?? '').isNotEmpty)
                                TextButton(
                                  onPressed: () => _save({'logoPath': null}),
                                  child: const Text('Remove'),
                                ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            children: [
                              const Text('Currency: '),
                              Text(
                                'Pakistani Rupee (${_s.currencySymbol})',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ]),
                        section('Document numbering', [
                          ResponsiveGrid(
                            minItemWidth: 170,
                            spacing: 14,
                            children: [
                              LabeledField('Invoice prefix', _inv),
                              LabeledField('Quotation prefix', _quo),
                              LabeledField('Purchase prefix', _pur),
                              LabeledField('Repair prefix', _rep),
                            ],
                          ),
                        ]),
                        section('Sales, quotations & warranty', [
                          ResponsiveGrid(
                            minItemWidth: 220,
                            spacing: 14,
                            children: [
                              AppDropdown<String>(
                                value: _s.defaultPaymentMethod,
                                decoration: const InputDecoration(
                                  labelText: 'Default payment method',
                                ),
                                items: [
                                  for (final m0 in PaymentMethod.values)
                                    DropdownMenuItem(
                                      value: m0.name,
                                      child: Text(m0.label),
                                    ),
                                ],
                                onChanged:
                                    (v) => _save({'defaultPaymentMethod': v}),
                              ),
                              AppDropdown<WarrantyStartPolicy>(
                                value: _s.warrantyStartPolicy,
                                decoration: const InputDecoration(
                                  labelText: 'Warranty starts from',
                                ),
                                items: const [
                                  DropdownMenuItem(
                                    value: WarrantyStartPolicy.saleDate,
                                    child: Text('Invoice date (default)'),
                                  ),
                                  DropdownMenuItem(
                                    value: WarrantyStartPolicy.installationDate,
                                    child: Text('Installation date'),
                                  ),
                                ],
                                onChanged:
                                    (v) =>
                                        _save({'warrantyStartPolicy': v?.name}),
                              ),
                              LabeledField(
                                'Quotation validity (days)',
                                _validity,
                                formatters: intInput,
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          LabeledField(
                            'Default quotation terms',
                            _terms,
                            maxLines: 3,
                          ),
                          const SizedBox(height: 14),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            value: _s.lowStockAlerts,
                            title: const Text(
                              'Low stock alerts in the notification bell',
                            ),
                            onChanged: (v) => _save({'lowStockAlerts': v}),
                          ),
                        ]),
                      ],
                    ),
                  ),
                  SingleChildScrollView(
                    child: Column(
                      children: [
                        section('Receipts & printer', [
                          Row(
                            children: [
                              Expanded(
                                child: AppDropdown<String>(
                                  value: _s.receiptFormat,
                                  decoration: const InputDecoration(
                                    labelText: 'POS receipt format',
                                  ),
                                  items: const [
                                    DropdownMenuItem(
                                      value: 'thermal80',
                                      child: Text('Thermal 80 mm'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'thermal58',
                                      child: Text('Thermal 58 mm'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'a4',
                                      child: Text('A4 invoice'),
                                    ),
                                  ],
                                  onChanged: (v) => _save({'receiptFormat': v}),
                                ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: AppDropdown<String?>(
                                  value:
                                      _printers.contains(_s.printerName)
                                          ? _s.printerName
                                          : null,
                                  decoration: InputDecoration(
                                    labelText:
                                        _printers.isEmpty
                                            ? 'Printer (none detected)'
                                            : 'Quick-print printer',
                                  ),
                                  items: [
                                    const DropdownMenuItem(
                                      value: null,
                                      child: Text('Ask every time'),
                                    ),
                                    for (final p in _printers)
                                      DropdownMenuItem(
                                        value: p,
                                        child: Text(
                                          p,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                  ],
                                  onChanged: (v) => _save({'printerName': v}),
                                ),
                              ),
                              IconButton(
                                tooltip: 'Refresh printers',
                                onPressed: () async {
                                  final p = await availablePrinters();
                                  setState(() => _printers = p);
                                },
                                icon: const Icon(Icons.refresh),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            value: _s.autoPrintReceipt,
                            title: const Text(
                              'Print receipt automatically after each sale',
                            ),
                            subtitle: const Text(
                              'Needs a quick-print printer above.',
                            ),
                            onChanged: (v) => _save({'autoPrintReceipt': v}),
                          ),
                          LabeledField('Receipt footer text', _footer),
                        ]),
                        section('Barcode / QR scanner (USB)', [
                          Text(
                            'Any USB scanner set to keyboard (HID) mode works without a driver or internet. '
                            'On the POS screen a scan is recognised by its typing speed and added to the bill, '
                            'whichever field has focus; normal typing still searches.',
                            style: TextStyle(color: c.textMuted, fontSize: 12),
                          ),
                          const SizedBox(height: 12),
                          AppDropdown<String>(
                            key: const ValueKey('scanner-suffix'),
                            value: _s.scannerSuffix,
                            decoration: const InputDecoration(
                              labelText: 'Key the scanner sends after the code',
                            ),
                            items: [
                              for (final s0 in ScanSuffix.values)
                                DropdownMenuItem(
                                  value: s0.name,
                                  child: Text(s0.label),
                                ),
                            ],
                            onChanged: (v) {
                              if (v != null) _save({'scannerSuffix': v});
                            },
                          ),
                          const SizedBox(height: 14),
                          FieldRow([
                            LabeledField(
                              'Max time between characters (ms)',
                              _scanGap,
                              formatters: intInput,
                            ),
                            LabeledField(
                              'Shortest code (characters)',
                              _scanMin,
                              formatters: intInput,
                            ),
                            LabeledField(
                              'Ignore same code again within (ms, 0 = off)',
                              _scanDup,
                              formatters: intInput,
                            ),
                          ]),
                        ]),
                        section('Product labels (QR + barcode)', [
                          FieldRow([
                            LabeledField(
                              'Label width (mm)',
                              _lw,
                              formatters: intInput,
                            ),
                            LabeledField(
                              'Label height (mm)',
                              _lh,
                              formatters: intInput,
                            ),
                          ]),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final sz in const [
                                (50, 25),
                                (40, 30),
                                (38, 25),
                                (58, 40),
                                (100, 50),
                              ])
                                ActionChip(
                                  label: Text('${sz.$1} × ${sz.$2} mm'),
                                  onPressed: () {
                                    _lw.text = '${sz.$1}';
                                    _lh.text = '${sz.$2}';
                                    _save({});
                                  },
                                ),
                            ],
                          ),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            value: _s.labelShowPrice,
                            title: const Text('Show price on product labels'),
                            onChanged: (v) => _save({'labelShowPrice': v}),
                          ),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: OutlinedButton.icon(
                              icon: const Icon(Icons.qr_code, size: 18),
                              label: const Text('Print a test label'),
                              onPressed: () {
                                final p = app.catalog.products().firstOrNull;
                                if (p == null) {
                                  return showToast(
                                    context,
                                    'Add a product first.',
                                    error: true,
                                  );
                                }
                                showPdf(
                                  context,
                                  app.ctx.settings,
                                  () => labelsPdf(app.ctx.settings, [
                                    LabelJob(p, 1),
                                  ]),
                                  name: 'Test label',
                                );
                              },
                            ),
                          ),
                        ]),
                        section('Appearance', [
                          SegmentedButton<String>(
                            segments: const [
                              ButtonSegment(
                                value: 'dark',
                                label: Text('Dark emerald'),
                              ),
                              ButtonSegment(
                                value: 'light',
                                label: Text('Light'),
                              ),
                            ],
                            selected: {_s.theme},
                            onSelectionChanged: (v) async {
                              await app.settings.setTheme(v.first);
                              ref.read(themeModeProvider.notifier).state =
                                  v.first == 'dark';
                              setState(() => _s = app.ctx.settings);
                            },
                          ),
                        ]),
                      ],
                    ),
                  ),
                  _AuditTab(app: app),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AuditTab extends StatefulWidget {
  final AppServices app;
  const _AuditTab({required this.app});
  @override
  State<_AuditTab> createState() => _AuditTabState();
}

class _AuditTabState extends State<_AuditTab> {
  String _q = '';
  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    final store = widget.app.ctx.store;
    final users = {
      for (final j in store.values(Boxes.users))
        j['id'] as String: j['displayName'] as String,
    };
    final ql = _q.toLowerCase();
    final logs =
        store
            .values(Boxes.auditLogs)
            .map(AuditLog.fromJson)
            .where(
              (l) =>
                  ql.isEmpty ||
                  '${l.action} ${l.entity} ${l.details}'.toLowerCase().contains(
                    ql,
                  ),
            )
            .toList()
          ..sort((a, b) => b.at.compareTo(a.at));
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final b in dataBoxesForOverview)
                StatusPill('$b: ${store.count(b)}', c.textMuted),
            ],
          ),
          const SizedBox(height: 14),
          SearchBox(
            hint: 'Search audit log…',
            onChanged: (v) => setState(() => _q = v),
          ),
          const SizedBox(height: 10),
          AppTable<AuditLog>(
            rows: logs,
            pageSize: 30,
            columns: [
              AppColumn('Time', (l) => Text(dateTimeFmt.format(l.at))),
              AppColumn('User', (l) => Text(users[l.userId] ?? l.userId)),
              AppColumn('Action', (l) => Text(l.action)),
              AppColumn('Record', (l) => Text(l.entity)),
              AppColumn(
                'Details',
                flex: 4,
                (l) => Text(l.details, overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
