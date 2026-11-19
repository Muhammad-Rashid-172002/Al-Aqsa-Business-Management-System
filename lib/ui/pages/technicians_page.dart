import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors.dart';
import '../../core/qty.dart';
import '../../domain/models/operations.dart';
import '../../domain/models/party.dart';
import '../../domain/models/product.dart';
import '../../domain/models/user.dart';
import '../../domain/services/technician_service.dart';
import '../../export/tabular.dart';
import '../print_actions.dart';
import '../record_actions.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/forms.dart';

class TechniciansPage extends ConsumerWidget {
  const TechniciansPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider)!;
    if (!user.can(Permission.issueStock)) {
      if (user.employeeId == null) {
        return const EmptyState(
          icon: Icons.engineering_outlined,
          title: 'No technician profile',
          message: 'Ask the owner to link your login to a technician profile.',
        );
      }
      return Padding(
        padding: const EdgeInsets.all(28),
        child: TechnicianDetail(technicianId: user.employeeId!, selfView: true),
      );
    }
    return const _TechList();
  }
}

class _TechList extends ConsumerStatefulWidget {
  const _TechList();
  @override
  ConsumerState<_TechList> createState() => _TechListState();
}

class _TechListState extends ConsumerState<_TechList> {
  bool _inactive = false;

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    final app = ref.watch(liveServicesProvider);
    final techs = app.technicians.technicians(includeInactive: _inactive);
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Technicians',
            breadcrumbs: const ['Technicians'],
            subtitle: '${techs.length} technician(s)',
            actions: [
              OutlinedButton.icon(
                onPressed: () => showIssueDialog(context, ref),
                icon: const Icon(Icons.outbox_outlined, size: 18),
                label: const Text('Issue Material'),
              ),
              if (app.ctx.can(Permission.manageTechnicians))
                FilledButton.icon(
                  onPressed: () => showTechForm(context, ref),
                  icon: const Icon(Icons.person_add_alt_1),
                  label: const Text('Add Technician'),
                ),
            ],
          ),
          FilterChip(
            label: const Text('Show inactive'),
            selected: _inactive,
            onSelected: (v) => setState(() => _inactive = v),
          ),
          const SizedBox(height: 14),
          Expanded(
            child:
                techs.isEmpty
                    ? const EmptyState(
                      icon: Icons.engineering_outlined,
                      title: 'No technicians yet',
                      message:
                          'Add your technicians to issue material and track accountability.',
                    )
                    : LayoutBuilder(
                      builder: (_, cons) {
                        final cols = (cons.maxWidth / 300).floor().clamp(1, 5);
                        // Fixed card height (an aspect ratio gave giant single-column
                        // cards and squeezed ones on narrow windows).
                        return GridView.builder(
                          itemCount: techs.length,
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: cols,
                                mainAxisSpacing: 14,
                                crossAxisSpacing: 14,
                                mainAxisExtent: 176,
                              ),
                          itemBuilder: (_, k) {
                            final t = techs[k];
                            final s0 = app.technicians.summary(t.id);
                            void openDetail() => showDialog<void>(
                                    context: context,
                                    builder:
                                        (ctx) => Dialog(
                                          insetPadding: EdgeInsets.all(
                                            MediaQuery.sizeOf(ctx).width < 1000
                                                ? 12
                                                : 32,
                                          ),
                                          child: SizedBox(
                                            width: 1000,
                                            height:
                                                MediaQuery.sizeOf(ctx).height *
                                                0.92,
                                            child: MinSizeScroll(
                                              minHeight: 520,
                                              child: Padding(
                                                padding: const EdgeInsets.all(
                                                  20,
                                                ),
                                                child: TechnicianDetail(
                                                  technicianId: t.id,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                  );
                            return AppCard(
                              hoverLift: true,
                              onTap: openDetail,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      CircleAvatar(
                                        backgroundColor: c.primary,
                                        child: Text(
                                          t.name[0].toUpperCase(),
                                          style: const TextStyle(
                                            color: Colors.white,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              t.name,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontWeight: FontWeight.w700,
                                                color: c.text,
                                              ),
                                            ),
                                            Text(
                                              '${t.code} • ${t.phone}',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: c.textMuted,
                                                fontSize: 12,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      if (!t.active)
                                        StatusPill('Inactive', c.textMuted),
                                      RowActionsMenu(
                                        onView: openDetail,
                                        onEdit: app.ctx.can(Permission.manageTechnicians) ? () => showTechForm(context, ref, existing: t) : null,
                                        onDelete: app.ctx.can(Permission.manageTechnicians) && (t.active || app.ctx.can(Permission.permanentDelete)) ? () => deleteTechnicianRecord(context, ref, t) : null,
                                        extra: [
                                          if (app.ctx.can(Permission.manageTechnicians) && !t.active)
                                            RowAction('Restore', Icons.unarchive_outlined, () => runAction(context, () => app.technicians.update(t.copyWith(active: true)), success: '"${t.name}" restored'), keyName: 'row-restore'),
                                        ],
                                      ),
                                    ],
                                  ),
                                  const Spacer(),
                                  Row(
                                    children: [
                                      _stat(
                                        c,
                                        'Holding',
                                        s0.remaining.format(),
                                        s0.remaining.isPositive
                                            ? c.warning
                                            : c.accent,
                                      ),
                                      _stat(
                                        c,
                                        'Installed',
                                        s0.installed.format(),
                                        c.text,
                                      ),
                                      _stat(
                                        c,
                                        'Returned',
                                        s0.returnedUnused.format(),
                                        c.text,
                                      ),
                                    ],
                                  ),
                                  if (app.ctx.can(Permission.viewFinancials))
                                    Text(
                                      'Value held: ${s0.remainingValue.format()}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: c.textMuted,
                                        fontSize: 12,
                                      ),
                                    ),
                                ],
                              ),
                            );
                          },
                        );
                      },
                    ),
          ),
        ],
      ),
    );
  }

  Widget _stat(AppColors c, String label, String v, Color tone) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: c.textMuted, fontSize: 11.5),
        ),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            v,
            maxLines: 1,
            style: TextStyle(
              color: tone,
              fontWeight: FontWeight.w700,
              fontSize: 18,
            ),
          ),
        ),
      ],
    ),
  );
}

Future<void> showTechForm(
  BuildContext context,
  WidgetRef ref, {
  Employee? existing,
}) async {
  final app = ref.read(servicesProvider);
  final name = TextEditingController(text: existing?.name);
  final phone = TextEditingController(text: existing?.phone);
  final address = TextEditingController(text: existing?.address);
  final notes = TextEditingController(text: existing?.notes);
  var active = existing?.active ?? true;
  final key = GlobalKey<FormState>();
  await showDialog<void>(
    context: context,
    builder:
        (ctx) => StatefulBuilder(
          builder:
              (ctx, setS) => FormDialog(
                title:
                    existing == null
                        ? 'Add Technician'
                        : 'Edit ${existing.name}',
                body: Form(
                  key: key,
                  child: Column(
                    children: [
                      FieldRow([
                        LabeledField(
                          'Name *',
                          name,
                          autofocus: true,
                          validator:
                              (v) =>
                                  (v ?? '').trim().isEmpty ? 'Required' : null,
                        ),
                        LabeledField('Phone', phone),
                      ]),
                      FieldRow([LabeledField('Address', address)]),
                      FieldRow([LabeledField('Notes', notes)]),
                      if (existing != null)
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          value: active,
                          onChanged: (v) => setS(() => active = v),
                          title: const Text('Active'),
                        ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: () async {
                      if (!key.currentState!.validate()) return;
                      final ok = await runAction(ctx, () async {
                        if (existing == null) {
                          await app.technicians.create(
                            name: name.text,
                            phone: phone.text,
                            address: address.text,
                            notes: notes.text,
                          );
                        } else {
                          await app.technicians.update(
                            existing.copyWith(
                              name: name.text,
                              phone: phone.text,
                              address: address.text,
                              notes: notes.text,
                              active: active,
                            ),
                          );
                        }
                      }, success: 'Technician saved');
                      if (ok && ctx.mounted) Navigator.pop(ctx);
                    },
                    child: const Text('Save'),
                  ),
                ],
              ),
        ),
  );
}

class TechnicianDetail extends ConsumerWidget {
  final String technicianId;
  final bool selfView;
  const TechnicianDetail({
    super.key,
    required this.technicianId,
    this.selfView = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AppTheme.of(context);
    final app = ref.watch(liveServicesProvider);
    final s0 = app.technicians.summary(technicianId);
    final t = s0.technician;
    final hist = app.technicians.history(technicianId: technicianId);
    final names = {
      for (final p in app.catalog.products(includeArchived: true)) p.id: p,
    };
    final custNames = {
      for (final p in app.parties.list(
        PartyKind.customer,
        includeInactive: true,
      ))
        p.id: p.name,
    };
    return DefaultTabController(
      length: 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      selfView ? 'My Material' : t.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: c.text,
                      ),
                    ),
                    Text(
                      '${t.code} • ${t.phone} • joined ${dateFmt.format(t.joiningDate)}',
                      style: TextStyle(color: c.textMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (!selfView && app.ctx.can(Permission.issueStock))
                      FilledButton.icon(
                        onPressed:
                            () => showIssueDialog(
                              context,
                              ref,
                              technicianId: technicianId,
                            ),
                        icon: const Icon(Icons.outbox, size: 18),
                        label: const Text('Issue'),
                      ),
                    if (!selfView && app.ctx.can(Permission.manageTechnicians))
                      OutlinedButton.icon(
                        onPressed:
                            () => showTechForm(context, ref, existing: t),
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        label: const Text('Edit'),
                      ),
                    if (!selfView)
                      ExportMenu(tables: () => [ExportTable(
                                'Technician ${t.name}',
                                [
                                  'Date',
                                  'Type',
                                  'Product',
                                  'Qty',
                                  'Job',
                                  'Customer',
                                  'Reason',
                                ],
                                [
                                  for (final h in hist)
                                    [
                                      dateTimeFmt.format(h.at),
                                      h.type.label,
                                      h.productName,
                                      h.qty.asDouble,
                                      h.jobRef,
                                      custNames[h.customerId] ?? '',
                                      h.reason,
                                    ],
                                ],
                              )]),
                  ],
                ),
              ),
              if (!selfView)
                IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.maybePop(context),
                  icon: const Icon(Icons.close),
                ),
            ],
          ),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, cons) {
              final cards = [
                for (final e
                    in {
                      'Total issued': s0.issued,
                      'Returned unused': s0.returnedUnused,
                      'Installed / used': s0.installed,
                      'Returned for inspection': s0.returnedForInspection,
                      'Still holding': s0.remaining,
                    }.entries)
                  SizedBox(
                    width: 190,
                    child: StatCard(
                      label: e.key,
                      icon: Icons.inventory_2_outlined,
                      value: Text(e.value.format()),
                    ),
                  ),
              ];
              // All five fit on one line: wrap. Otherwise keep one row and scroll
              // sideways so the tables below keep their height.
              if (cons.maxWidth >= 5 * 190 + 4 * 12) {
                return Wrap(spacing: 12, runSpacing: 12, children: cards);
              }
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (var k = 0; k < cards.length; k++) ...[
                      if (k > 0) const SizedBox(width: 12),
                      cards[k],
                    ],
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 10),
          TabBar(
            isScrollable: true,
            labelColor: c.accent,
            tabs: const [Tab(text: 'Currently holding'), Tab(text: 'History')],
          ),
          Expanded(
            child: TabBarView(
              children: [
                SingleChildScrollView(
                  padding: const EdgeInsets.only(top: 12),
                  child: AppTable<TechHolding>(
                    rows: s0.holdings,
                    empty: const Padding(
                      padding: EdgeInsets.all(30),
                      child: Text(
                        'Nothing held. All material is accounted for.',
                      ),
                    ),
                    columns: [
                      AppColumn(
                        'Product',
                        flex: 4,
                        (h) => Text(names[h.productId]?.name ?? ''),
                      ),
                      AppColumn(
                        'Quantity',
                        numeric: true,
                        (h) => Text(
                          '${h.qty.format()} ${names[h.productId]?.unit ?? ''}',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      if (app.ctx.can(Permission.viewFinancials))
                        AppColumn(
                          'Cost value',
                          numeric: true,
                          (h) => Text(h.cost.format()),
                        ),
                      AppColumn(
                        '',
                        flex: 4,
                        numeric: true,
                        (h) => Wrap(
                          spacing: 6,
                          children: [
                            OutlinedButton(
                              onPressed:
                                  () => showReturnDialog(
                                    context,
                                    ref,
                                    technicianId,
                                    h,
                                  ),
                              child: const Text('Return'),
                            ),
                            FilledButton(
                              onPressed:
                                  () => showInstallDialog(
                                    context,
                                    ref,
                                    technicianId,
                                    h,
                                  ),
                              child: const Text('Installed'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                SingleChildScrollView(
                  padding: const EdgeInsets.only(top: 12),
                  child: AppTable<TechTxn>(
                    rows: hist,
                    pageSize: 30,
                    empty: const Padding(
                      padding: EdgeInsets.all(30),
                      child: Text('No transactions yet'),
                    ),
                    columns: [
                      AppColumn('Date', (h) => Text(dateTimeFmt.format(h.at))),
                      AppColumn(
                        'Type',
                        (h) => StatusPill(
                          h.type.label,
                          h.type == TechTxnType.issue
                              ? c.warning
                              : (h.type == TechTxnType.installed
                                  ? const Color(0xFF6FB8FF)
                                  : c.accent),
                        ),
                      ),
                      AppColumn('Product', flex: 3, (h) => Text(h.productName)),
                      AppColumn(
                        'Qty',
                        numeric: true,
                        flex: 1,
                        (h) => Text(h.qty.format()),
                      ),
                      AppColumn(
                        'Details',
                        flex: 4,
                        (h) => Text(
                          [
                            if (h.jobRef.isNotEmpty) 'Job ${h.jobRef}',
                            if (h.customerId != null)
                              custNames[h.customerId] ?? '',
                            if (h.serials.isNotEmpty)
                              'S/N ${h.serials.map(SerialRecord.displayOf).join(', ')}',
                            if (h.reason.isNotEmpty) h.reason,
                            if (h.type == TechTxnType.installed)
                              h.invoicedSaleId == null
                                  ? 'not invoiced'
                                  : 'invoiced',
                          ].join(' • '),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _IssueRow {
  final Product product;
  final TextEditingController qty = TextEditingController(text: '1');
  final Set<String> serials = {};
  _IssueRow(this.product);
}

Future<void> showIssueDialog(
  BuildContext context,
  WidgetRef ref, {
  String? technicianId,
}) async {
  final app = ref.read(servicesProvider);
  var techId = technicianId;
  final rows = <_IssueRow>[];
  final job = TextEditingController();
  final notes = TextEditingController();
  await showDialog<void>(
    context: context,
    builder:
        (ctx) => StatefulBuilder(
          builder: (ctx, setS) {
            final c = AppTheme.of(ctx);
            void add(Product p, [String? serialKey]) {
              var r = rows.where((x) => x.product.id == p.id).firstOrNull;
              if (r == null) {
                r = _IssueRow(p);
                rows.add(r);
              } else if (!p.requiresSerial) {
                r.qty.text =
                    ((Qty.tryParse(r.qty.text) ?? const Qty.zero()) +
                            const Qty.one())
                        .format();
              }
              if (serialKey != null) r.serials.add(serialKey);
              setS(() {});
            }

            return FormDialog(
              title: 'Issue material to technician',
              width: 820,
              body: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AppDropdown<String>(
                    value: techId,
                    decoration: const InputDecoration(
                      labelText: 'Technician *',
                    ),
                    items: [
                      for (final t in app.technicians.technicians())
                        DropdownMenuItem(
                          value: t.id,
                          child: Text('${t.name} (${t.code})'),
                        ),
                    ],
                    onChanged: (v) => setS(() => techId = v),
                  ),
                  const SizedBox(height: 12),
                  FieldRow([
                    LabeledField('Job reference (optional)', job),
                    LabeledField('Notes', notes),
                  ]),
                  ScannerField(
                    hint: 'Scan product or unit serial to add',
                    onScan: (code) {
                      final r = app.catalog.lookup(code);
                      if (r == null) {
                        return showToast(
                          ctx,
                          'Unknown code "$code"',
                          error: true,
                        );
                      }
                      if (r.serial != null) {
                        if (r.serial!.status != SerialStatus.inStock) {
                          return showToast(
                            ctx,
                            'Serial ${r.serial!.display} is ${r.serial!.status.label}',
                            error: true,
                          );
                        }
                        add(r.product, r.serial!.key);
                      } else {
                        add(r.product);
                      }
                    },
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      icon: const Icon(Icons.playlist_add),
                      label: const Text('Browse products'),
                      onPressed: () async {
                        final p = await pickFromList<Product>(
                          ctx,
                          title: 'Product',
                          items:
                              app.catalog
                                  .products()
                                  .where((p) => p.stockQty.isPositive)
                                  .toList(),
                          label: (p) => p.name,
                          subtitle:
                              (p) =>
                                  'In stock ${p.stockQty.format()} ${p.unit}',
                        );
                        if (p != null) add(p);
                      },
                    ),
                  ),
                  for (final r in rows)
                    Container(
                      margin: const EdgeInsets.only(top: 8),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        border: Border.all(color: c.border),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${r.product.name}  •  stock ${r.product.stockQty.format()} ${r.product.unit}',
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (r.product.requiresSerial)
                            Expanded(
                              flex: 2,
                              child: Wrap(
                                spacing: 4,
                                runSpacing: 4,
                                children: [
                                  for (final s1 in app.serials.inStockFor(
                                    r.product.id,
                                  ))
                                    FilterChip(
                                      label: Text(s1.display),
                                      selected: r.serials.contains(s1.key),
                                      onSelected:
                                          (v) => setS(
                                            () =>
                                                v
                                                    ? r.serials.add(s1.key)
                                                    : r.serials.remove(s1.key),
                                          ),
                                    ),
                                ],
                              ),
                            )
                          else
                            SizedBox(
                              width: 120,
                              child: TextField(
                                controller: r.qty,
                                inputFormatters: qtyInput,
                                decoration: InputDecoration(
                                  labelText: 'Qty (${r.product.unit})',
                                ),
                              ),
                            ),
                          IconButton(
                            onPressed: () => setS(() => rows.remove(r)),
                            icon: Icon(Icons.delete_outline, color: c.danger),
                          ),
                        ],
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
                  onPressed: () async {
                    if (techId == null) {
                      return showToast(
                        ctx,
                        'Select a technician.',
                        error: true,
                      );
                    }
                    final lines = [
                      for (final r in rows)
                        IssueLine(
                          productId: r.product.id,
                          qty:
                              r.product.requiresSerial
                                  ? Qty.units(r.serials.length)
                                  : (Qty.tryParse(r.qty.text) ??
                                      const Qty.zero()),
                          serials: r.serials.toList(),
                        ),
                    ];
                    final ok = await runAction(
                      ctx,
                      () => app.technicians.issue(
                        technicianId: techId!,
                        lines: lines,
                        jobRef: job.text,
                        notes: notes.text,
                      ),
                      success: 'Material issued',
                    );
                    if (ok && ctx.mounted) Navigator.pop(ctx);
                  },
                  child: const Text('Issue'),
                ),
              ],
            );
          },
        ),
  );
}

Future<void> showReturnDialog(
  BuildContext context,
  WidgetRef ref,
  String techId,
  TechHolding h,
) async {
  final app = ref.read(servicesProvider);
  final p = app.catalog.byId(h.productId)!;
  final qty = TextEditingController(text: h.qty.format());
  final reason = TextEditingController();
  var type = TechTxnType.returnUnused;
  final mine = app.serials.search(
    productId: p.id,
    status: SerialStatus.issuedToTechnician,
    technicianId: techId,
  );
  final chosen = <String>{};
  await showDialog<void>(
    context: context,
    builder:
        (ctx) => StatefulBuilder(
          builder:
              (ctx, setS) => FormDialog(
                title: 'Return • ${p.name}',
                width: 560,
                body: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    InfoRow('Holding', '${h.qty.format()} ${p.unit}'),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final t in [
                          TechTxnType.returnUnused,
                          TechTxnType.returnUsed,
                          TechTxnType.returnDamaged,
                          TechTxnType.returnFaulty,
                        ])
                          ChoiceChip(
                            label: Text(t.label.replaceFirst('Returned ', '')),
                            selected: type == t,
                            onSelected: (_) => setS(() => type = t),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      type == TechTxnType.returnUnused
                          ? 'Goes straight back to sellable stock.'
                          : 'Goes to the owner\'s inspection queue. Not sellable until approved.',
                      style: TextStyle(
                        color: AppTheme.of(ctx).textMuted,
                        fontSize: 12.5,
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (p.requiresSerial)
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final r in mine)
                            FilterChip(
                              label: Text(r.display),
                              selected: chosen.contains(r.key),
                              onSelected:
                                  (v) => setS(
                                    () =>
                                        v
                                            ? chosen.add(r.key)
                                            : chosen.remove(r.key),
                                  ),
                            ),
                        ],
                      )
                    else
                      TextField(
                        controller: qty,
                        inputFormatters: qtyInput,
                        decoration: InputDecoration(
                          labelText: 'Quantity (${p.unit})',
                        ),
                      ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: reason,
                      decoration: InputDecoration(
                        labelText:
                            type == TechTxnType.returnUnused
                                ? 'Reason (optional)'
                                : 'Condition / reason (required)',
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
                    onPressed: () async {
                      final q =
                          p.requiresSerial
                              ? Qty.units(chosen.length)
                              : (Qty.tryParse(qty.text) ?? const Qty.zero());
                      final ok = await runAction(
                        ctx,
                        () => app.technicians.returnMaterial(
                          technicianId: techId,
                          productId: p.id,
                          qty: q,
                          type: type,
                          serialNumbers: chosen.toList(),
                          reason: reason.text,
                        ),
                        success: 'Return recorded',
                      );
                      if (ok && ctx.mounted) Navigator.pop(ctx);
                    },
                    child: const Text('Record return'),
                  ),
                ],
              ),
        ),
  );
}

Future<void> showInstallDialog(
  BuildContext context,
  WidgetRef ref,
  String techId,
  TechHolding h,
) async {
  final app = ref.read(servicesProvider);
  final p = app.catalog.byId(h.productId)!;
  final qty = TextEditingController(text: h.qty.format());
  final job = TextEditingController();
  final notes = TextEditingController();
  Party? customer;
  final mine = app.serials.search(
    productId: p.id,
    status: SerialStatus.issuedToTechnician,
    technicianId: techId,
  );
  final chosen = <String>{};
  await showDialog<void>(
    context: context,
    builder:
        (ctx) => StatefulBuilder(
          builder:
              (ctx, setS) => FormDialog(
                title: 'Installed at customer site • ${p.name}',
                width: 560,
                body: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Installed material is not a sale yet. It appears in POS for this customer so it can be invoiced.',
                    ),
                    const SizedBox(height: 12),
                    InkWell(
                      onTap: () async {
                        final picked = await pickFromList<Party>(
                          ctx,
                          title: 'Customer',
                          items: app.parties.list(PartyKind.customer),
                          label: (x) => x.name,
                          subtitle: (x) => x.phone,
                        );
                        if (picked != null) setS(() => customer = picked);
                      },
                      child: InputDecorator(
                        decoration: const InputDecoration(
                          labelText: 'Customer (recommended)',
                        ),
                        child: Text(
                          customer?.name ?? 'Select…',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (p.requiresSerial)
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final r in mine)
                            FilterChip(
                              label: Text(r.display),
                              selected: chosen.contains(r.key),
                              onSelected:
                                  (v) => setS(
                                    () =>
                                        v
                                            ? chosen.add(r.key)
                                            : chosen.remove(r.key),
                                  ),
                            ),
                        ],
                      )
                    else
                      TextField(
                        controller: qty,
                        inputFormatters: qtyInput,
                        decoration: InputDecoration(
                          labelText: 'Quantity used (${p.unit})',
                        ),
                      ),
                    const SizedBox(height: 12),
                    FieldRow([
                      LabeledField('Job / site reference', job),
                      LabeledField('Notes', notes),
                    ]),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: () async {
                      final q =
                          p.requiresSerial
                              ? Qty.units(chosen.length)
                              : (Qty.tryParse(qty.text) ?? const Qty.zero());
                      try {
                        await app.technicians.recordInstalled(
                          technicianId: techId,
                          productId: p.id,
                          qty: q,
                          serialNumbers: chosen.toList(),
                          customerId: customer?.id,
                          jobRef: job.text,
                          notes: notes.text,
                        );
                        if (ctx.mounted) {
                          Navigator.pop(ctx);
                          showToast(context, 'Installation recorded');
                        }
                      } catch (e) {
                        if (ctx.mounted) {
                          showToast(ctx, friendlyError(e), error: true);
                        }
                      }
                    },
                    child: const Text('Record installation'),
                  ),
                ],
              ),
        ),
  );
}
