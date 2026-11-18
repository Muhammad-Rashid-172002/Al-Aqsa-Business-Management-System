import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/operations.dart';
import '../../domain/models/party.dart';
import '../../domain/models/product.dart';
import '../../domain/models/user.dart';
import '../../domain/services/warranty_repair_service.dart';
import '../../export/tabular.dart';
import '../print_actions.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/forms.dart';
import 'repairs_page.dart';
import 'serials_page.dart';

class WarrantyPage extends ConsumerStatefulWidget {
  const WarrantyPage({super.key});
  @override
  ConsumerState<WarrantyPage> createState() => _WarrantyPageState();
}

class _WarrantyPageState extends ConsumerState<WarrantyPage> {
  String? _lookup;

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    final app = ref.watch(liveServicesProvider);
    final custNames = {for (final p in app.parties.list(PartyKind.customer, includeInactive: true)) p.id: p.name};
    final products = {for (final p in app.catalog.products(includeArchived: true)) p.id: p.name};
    final results = _lookup == null ? const <SerialRecord>[] : app.serials.findAll(_lookup!);
    Widget wList(List<WarrantyInfo> rows) => SingleChildScrollView(
          padding: const EdgeInsets.only(top: 12),
          child: AppTable<WarrantyInfo>(
            rows: rows,
            onRowTap: (w) => showSerialDetail(context, ref, w.serial.key),
            empty: const Padding(padding: EdgeInsets.all(30), child: Text('None')),
            columns: [
              AppColumn('Serial', (w) => Text(w.serial.display, style: const TextStyle(fontFamily: 'Consolas'))),
              AppColumn('Product', flex: 3, (w) => Text(w.product?.name ?? '')),
              AppColumn('Customer', flex: 2, (w) => Text(custNames[w.serial.customerId] ?? '')),
              AppColumn('Start', (w) => Text(w.serial.warrantyStart == null ? '' : dateFmt.format(w.serial.warrantyStart!))),
              AppColumn('Expiry', (w) => Text(dateFmt.format(w.serial.warrantyExpiry!))),
              AppColumn('Status', (w) => StatusPill(w.state == WarrantyState.active ? '${w.daysLeft} days left' : 'Expired', w.state == WarrantyState.active ? (w.daysLeft <= 30 ? c.warning : c.accent) : c.danger)),
            ],
          ),
        );
    final active = app.warranty.all(state: WarrantyState.active);
    final expiring = app.warranty.expiringWithin(30);
    final expired = app.warranty.all(state: WarrantyState.expired);
    final claims = app.warranty.claims();
    return DefaultTabController(
      length: 4,
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          PageHeader(title: 'Warranty', breadcrumbs: const ['Warranty'], subtitle: 'Warranty starts on ${app.ctx.settings.warrantyStartPolicy == WarrantyStartPolicy.saleDate ? 'the invoice date' : 'the installation date'} (change in Settings).', actions: [
            ExportMenu(tables: () => [ExportTable('Warranty', ['Serial', 'Product', 'Customer', 'Start', 'Expiry', 'Status'], [
                for (final w in [...active, ...expired])
                  [w.serial.display, w.product?.name ?? '', custNames[w.serial.customerId] ?? '', w.serial.warrantyStart == null ? '' : dateFmt.format(w.serial.warrantyStart!), dateFmt.format(w.serial.warrantyExpiry!), w.state.name]
              ])]),
          ]),
          AppCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Check warranty', style: TextStyle(fontWeight: FontWeight.w700, color: c.text)),
              const SizedBox(height: 10),
              ScannerField(autofocus: false, hint: 'Scan or type the device serial number', onScan: (v) => setState(() => _lookup = v)),
              if (_lookup != null && results.isEmpty) Padding(padding: const EdgeInsets.only(top: 10), child: Text('Serial "${_lookup!.toUpperCase()}" is not registered in this shop.', style: TextStyle(color: c.danger))),
              for (final r in results) _WarrantyResult(record: r, productName: products[r.productId] ?? '', customer: custNames[r.customerId]),
            ]),
          ),
          const SizedBox(height: 14),
          TabBar(isScrollable: true, labelColor: c.accent, tabs: [
            Tab(text: 'Claims (${claims.where((x) => x.status == ClaimStatus.open || x.status == ClaimStatus.sentForRepair).length} open)'),
            Tab(text: 'Expiring in 30 days (${expiring.length})'),
            Tab(text: 'Active (${active.length})'),
            Tab(text: 'Expired (${expired.length})'),
          ]),
          Expanded(
            child: TabBarView(children: [
              SingleChildScrollView(
                padding: const EdgeInsets.only(top: 12),
                child: AppTable<WarrantyClaim>(
                  rows: claims,
                  onRowTap: (x) => _claimActions(context, x),
                  empty: const Padding(padding: EdgeInsets.all(30), child: Text('No warranty claims')),
                  columns: [
                    AppColumn('Claim', (x) => Text(x.number, style: const TextStyle(fontWeight: FontWeight.w600))),
                    AppColumn('Date', (x) => Text(dateFmt.format(x.date))),
                    AppColumn('Serial', (x) => Text(SerialRecord.displayOf(x.serial))),
                    AppColumn('Product', flex: 2, (x) => Text(products[x.productId] ?? '')),
                    AppColumn('Customer', flex: 2, (x) => Text(custNames[x.customerId] ?? '')),
                    AppColumn('Issue', flex: 3, (x) => Text(x.issue, overflow: TextOverflow.ellipsis)),
                    AppColumn('Status', (x) => StatusPill(x.status.name, x.status == ClaimStatus.open || x.status == ClaimStatus.sentForRepair ? c.warning : c.accent)),
                  ],
                ),
              ),
              wList(expiring),
              wList(active),
              wList(expired),
            ]),
          ),
        ]),
      ),
    );
  }

  Future<void> _claimActions(BuildContext context, WarrantyClaim cl) async {
    final app = ref.read(servicesProvider);
    final open = cl.status == ClaimStatus.open || cl.status == ClaimStatus.sentForRepair;
    await showDialog<void>(
      context: context,
      builder: (ctx) => FormDialog(
        title: 'Claim ${cl.number}',
        width: 560,
        body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          InfoRow('Serial', SerialRecord.displayOf(cl.serial)),
          InfoRow('Opened', dateTimeFmt.format(cl.date)),
          InfoRow('Issue', cl.issue),
          InfoRow('Status', cl.status.name),
          if (cl.resolution.isNotEmpty) InfoRow('Resolution', cl.resolution),
          if (cl.replacementSerial != null) InfoRow('Replacement unit', SerialRecord.displayOf(cl.replacementSerial!)),
        ]),
        actions: [
          if (open && app.ctx.can(Permission.manageWarranty)) ...[
            TextButton(
              onPressed: () async {
                final r = await promptText(ctx, title: 'Reject claim', label: 'Reason');
                if (r != null && ctx.mounted && await runAction(ctx, () => app.warranty.reject(cl.id, r), success: 'Claim rejected') && ctx.mounted) Navigator.pop(ctx);
              },
              child: Text('Reject', style: TextStyle(color: AppTheme.of(ctx).danger)),
            ),
            OutlinedButton(
              onPressed: () async {
                final r = await promptText(ctx, title: 'Repaired', label: 'What was done?');
                if (r != null && ctx.mounted && await runAction(ctx, () => app.warranty.resolveRepaired(cl.id, r), success: 'Marked repaired') && ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Repaired & returned'),
            ),
            FilledButton(
              onPressed: () async {
                final avail = app.serials.inStockFor(cl.productId);
                final pick = await pickFromList<SerialRecord>(ctx, title: 'Replacement unit from stock', items: avail, label: (r) => r.display);
                if (pick == null || !ctx.mounted) return;
                if (await runAction(ctx, () => app.warranty.replace(cl.id, pick.key, 'Replaced with ${pick.display}'), success: 'Unit replaced') && ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Replace unit'),
            ),
          ] else
            FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }
}

class _WarrantyResult extends ConsumerWidget {
  final SerialRecord record;
  final String productName;
  final String? customer;
  const _WarrantyResult({required this.record, required this.productName, this.customer});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AppTheme.of(context);
    final app = ref.watch(liveServicesProvider);
    final w = app.warranty.check(record.key)!;
    final (txt, tone) = switch (w.state) {
      WarrantyState.active => ('UNDER WARRANTY • ${w.daysLeft} days left (until ${dateFmt.format(record.warrantyExpiry!)})', c.accent),
      WarrantyState.expired => ('WARRANTY EXPIRED on ${dateFmt.format(record.warrantyExpiry!)}', c.danger),
      WarrantyState.none => ('Sold without warranty', c.warning),
      WarrantyState.notSold => ('Not sold yet (${record.status.label})', c.textMuted),
    };
    final info = Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(w.state == WarrantyState.active ? Icons.verified : Icons.info_outline, color: tone, size: 30),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${record.display} • $productName (${record.brandKey})', style: const TextStyle(fontWeight: FontWeight.w700)),
            Text(txt, style: TextStyle(color: tone, fontWeight: FontWeight.w600)),
            if (customer != null) Text('Customer: $customer', style: TextStyle(color: c.textMuted)),
          ]),
        ),
    ]);
    final buttons = Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton(onPressed: () => showSerialDetail(context, ref, record.key), child: const Text('History')),
        if (w.state == WarrantyState.active && app.ctx.can(Permission.manageWarranty))
          FilledButton(
            onPressed: () async {
              final issue = await promptText(context, title: 'Open warranty claim', label: 'Problem reported by customer');
              if (issue == null || !context.mounted) return;
              await runAction(context, () => app.warranty.openClaim(record.key, issue), success: 'Claim opened. The unit is marked under repair.');
            },
            child: const Text('Open claim'),
          ),
        if (app.ctx.can(Permission.manageRepairs))
          OutlinedButton(
            onPressed: () => showReceiveRepair(context, ref,
                customerId: record.customerId, customerName: customer ?? '', productId: record.productId, productName: productName, serial: record.serial),
            child: const Text('Repair job'),
          ),
    ]);
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: tone.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12), border: Border.all(color: tone.withValues(alpha: 0.4))),
      // Buttons move under the details when the card is narrow.
      child: LayoutBuilder(builder: (context, cons) => cons.maxWidth < 760
          ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [info, const SizedBox(height: 10), Padding(padding: const EdgeInsets.only(left: 44), child: buttons)])
          : Row(children: [Expanded(child: info), const SizedBox(width: 12), buttons])),
    );
  }
}
