import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/party.dart';
import '../../domain/models/product.dart';
import '../../domain/models/user.dart';
import '../../domain/services/warranty_repair_service.dart';
import '../../export/tabular.dart';
import '../../printing/pdf_docs.dart';
import '../print_actions.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/forms.dart';

class SerialsPage extends ConsumerStatefulWidget {
  const SerialsPage({super.key});
  @override
  ConsumerState<SerialsPage> createState() => _SerialsPageState();
}

class _SerialsPageState extends ConsumerState<SerialsPage> {
  String _q = '';
  SerialStatus? _status;
  String? _product;
  bool _dupsOnly = false;

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    final app = ref.watch(liveServicesProvider);
    final products = {for (final p in app.catalog.products(includeArchived: true).where((p) => p.requiresSerial)) p.id: p};
    var rows = app.serials.search(query: _q, status: _status, productId: _product);
    if (_dupsOnly) {
      final dupKeys = app.serials.duplicates().expand((g) => g.map((r) => r.key)).toSet();
      rows = rows.where((r) => dupKeys.contains(r.key)).toList();
    }
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PageHeader(title: 'Serial Numbers', breadcrumbs: const ['Serial Numbers'], subtitle: '${rows.length} unit(s)', actions: [
          ExportMenu(tables: () => [ExportTable('Serial Numbers', ['Serial', 'Brand', 'Product', 'Status', 'Purchased', 'Warranty until'], [
              for (final r in rows)
                [r.serial, r.brandKey, products[r.productId]?.name ?? '', r.status.label, r.purchaseDate == null ? '' : dateFmt.format(r.purchaseDate!), r.warrantyExpiry == null ? '' : dateFmt.format(r.warrantyExpiry!)]
            ])]),
        ]),
        Row(children: [
          Expanded(child: ScannerField(onScan: (v) => setState(() => _q = v), onChanged: (v) => setState(() => _q = v), hint: 'Scan or type a serial number')),
        ]),
        const SizedBox(height: 12),
        Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 200, maxWidth: 260),
            child: AppDropdown<SerialStatus?>(
              key: const ValueKey('serial-status-filter'),
              value: _status,
              isDense: true,
              decoration: const InputDecoration(labelText: 'Status'),
              items: [const DropdownMenuItem(value: null, child: Text('All statuses')), for (final s0 in SerialStatus.values) DropdownMenuItem(value: s0, child: Text(s0.label))],
              onChanged: (v) => setState(() => _status = v),
            ),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 200, maxWidth: 280),
            child: AppDropdown<String?>(
              value: _product,
              isDense: true,
              decoration: const InputDecoration(labelText: 'Product'),
              items: [const DropdownMenuItem(value: null, child: Text('All products')), for (final p in products.values) DropdownMenuItem(value: p.id, child: Text(p.name, overflow: TextOverflow.ellipsis))],
              onChanged: (v) => setState(() => _product = v),
            ),
          ),
          FilterChip(label: const Text('Shared / duplicate serials'), selected: _dupsOnly, onSelected: (v) => setState(() => _dupsOnly = v)),
        ]),
        const SizedBox(height: 12),
        Expanded(
          child: SingleChildScrollView(
            child: AppTable<SerialRecord>(
              rows: rows,
              pageSize: 40,
              onRowTap: (r) => showSerialDetail(context, ref, r.key),
              empty: const EmptyState(icon: Icons.qr_code_2, title: 'No serial numbers', message: 'Serial numbers are registered when you purchase serial-tracked products.'),
              columns: [
                AppColumn('Serial', minWidth: 120, (r) => Text(r.display, style: const TextStyle(fontFamily: 'Consolas', fontWeight: FontWeight.w600))),
                AppColumn('Brand', flex: 1, minWidth: 80, (r) => Text(r.brandKey, maxLines: 1, overflow: TextOverflow.ellipsis)),
                AppColumn('Product', flex: 3, minWidth: 160, (r) => Text(products[r.productId]?.name ?? '')),
                // Longest label is "Repairable (Not Sellable)": give the column
                // room and let the pill ellipsize (tooltip has the full text).
                AppColumn('Status', flex: 3, minWidth: 170, (r) => StatusPill(r.status.label, _tone(c, r.status))),
                AppColumn('Warranty', (r) => Text(r.warrantyExpiry == null ? '—' : 'until ${dateFmt.format(r.warrantyExpiry!)}')),
              ],
            ),
          ),
        ),
      ]),
    );
  }
}

Color _tone(AppColors c, SerialStatus s) => switch (s) {
      SerialStatus.inStock => c.accent,
      SerialStatus.sold || SerialStatus.installed => const Color(0xFF6FB8FF),
      SerialStatus.issuedToTechnician || SerialStatus.pendingInspection || SerialStatus.awaitingRepair || SerialStatus.underRepair => c.warning,
      SerialStatus.damaged || SerialStatus.replaced => c.danger,
      _ => c.textMuted,
    };

Future<void> showSerialDetail(BuildContext context, WidgetRef ref, String key) => showDialog<void>(
      context: context,
      builder: (ctx) => Consumer(builder: (ctx, ref, _) {
        final c = AppTheme.of(ctx);
        final app = ref.watch(liveServicesProvider);
        final r = app.serials.byKey(key)!;
        final p = app.catalog.byId(r.productId);
        final w = app.warranty.check(r.key);
        final customer = r.customerId == null ? null : app.parties.byId(PartyKind.customer, r.customerId!);
        final supplier = r.supplierId == null ? null : app.parties.byId(PartyKind.supplier, r.supplierId!);
        final tech = r.technicianId == null ? null : app.technicians.technicians(includeInactive: true).where((t) => t.id == r.technicianId).firstOrNull;
        return FormDialog(
          title: 'Serial ${r.display}',
          width: 720,
          headerTrailing: StatusPill(r.status.label, _tone(c, r.status)),
          body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            InfoRow('Product', p?.name ?? ''),
            InfoRow('Brand identity', r.brandKey),
            if (supplier != null) InfoRow('Supplier', supplier.name),
            if (r.purchaseDate != null) InfoRow('Purchased', dateFmt.format(r.purchaseDate!)),
            if (app.ctx.can(Permission.viewPurchasePrice)) InfoRow('Purchase cost', r.cost.format()),
            if (tech != null) InfoRow('With technician', tech.name),
            if (customer != null) InfoRow('Customer', customer.name),
            if (w != null && w.state != WarrantyState.notSold)
              InfoRow('Warranty', switch (w.state) {
                WarrantyState.active => 'Active until ${dateFmt.format(r.warrantyExpiry!)} (${w.daysLeft} days left)',
                WarrantyState.expired => 'Expired on ${dateFmt.format(r.warrantyExpiry!)}',
                _ => 'No warranty',
              }, color: w.state == WarrantyState.active ? c.accent : c.warning),
            if (r.duplicateApprovedBy != null) InfoRow('Duplicate', 'Registered with owner approval', color: c.warning),
            const Divider(),
            Text('History', style: TextStyle(fontWeight: FontWeight.w700, color: c.text)),
            const SizedBox(height: 6),
            for (final h in r.history.reversed)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.circle, size: 10, color: _tone(c, h.status)),
                title: Text(h.status.label),
                subtitle: Text([dateTimeFmt.format(h.at), if (h.note.isNotEmpty) h.note].join(' • ')),
              ),
          ]),
          actions: [
            if (p != null)
              OutlinedButton.icon(
                onPressed: () => showPdf(ctx, app.ctx.settings, () => labelsPdf(app.ctx.settings, [LabelJob(p, 1, serialKey: r.key)]), name: 'Label ${r.display}'),
                icon: const Icon(Icons.qr_code, size: 18),
                label: const Text('Print label'),
              ),
            FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
          ],
        );
      }),
    );
