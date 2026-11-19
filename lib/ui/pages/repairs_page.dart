import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors.dart';
import '../../core/money.dart';
import '../../core/qty.dart';
import '../../domain/models/operations.dart';
import '../../domain/models/party.dart';
import '../../domain/models/product.dart';
import '../../domain/models/user.dart';
import '../../printing/pdf_docs.dart';
import '../../export/tabular.dart';
import '../print_actions.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/forms.dart';

Color repairTone(AppColors c, RepairStatus s) => switch (s) {
      RepairStatus.delivered => c.textMuted,
      RepairStatus.repaired || RepairStatus.readyForCollection => c.accent,
      RepairStatus.notRepairable => c.danger,
      RepairStatus.waitingForParts => c.warning,
      _ => const Color(0xFF6FB8FF),
    };

class RepairsPage extends ConsumerStatefulWidget {
  const RepairsPage({super.key});
  @override
  ConsumerState<RepairsPage> createState() => _RepairsPageState();
}

class _RepairsPageState extends ConsumerState<RepairsPage> {
  bool _openOnly = true;
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    final app = ref.watch(liveServicesProvider);
    final ql = _q.toLowerCase();
    final techs = {for (final t in app.technicians.technicians(includeInactive: true)) t.id: t.name};
    final jobs = app.repairs
        .visibleJobs()
        .where((j) => (!_openOnly || j.status.isOpen) && (ql.isEmpty || j.number.toLowerCase().contains(ql) || j.customerName.toLowerCase().contains(ql) || j.serial.toLowerCase().contains(ql)))
        .toList();
    final canManage = app.ctx.can(Permission.manageRepairs);
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PageHeader(title: canManage ? 'Repair Management' : 'My Repair Jobs', breadcrumbs: const ['Repairs'], subtitle: '${jobs.length} job(s)', actions: [
          ExportMenu(
            tables: () => [
              ExportTable('Repair Jobs', ['Job', 'Received', 'Customer', 'Phone', 'Device', 'Serial', 'Technician', 'Status', 'Charges', 'Delivered'], [
                for (final j in jobs)
                  [j.number, j.receivedDate, j.customerName, j.customerPhone, j.productName, j.serial, techs[j.technicianId] ?? '', j.status.label, j.totalCharges.paisa / 100, j.deliveryDate]
              ], footer: [
                ['Total (${jobs.length})', null, null, null, null, null, null, null, jobs.fold<double>(0, (a, j) => a + j.totalCharges.paisa / 100), null]
              ]),
            ],
          ),
          if (canManage) FilledButton.icon(onPressed: () => showReceiveRepair(context, ref), icon: const Icon(Icons.add), label: const Text('Receive Device')),
        ]),
        Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SearchBox(hint: 'Job no, customer, serial…', width: 280, onChanged: (v) => setState(() => _q = v)),
          FilterChip(label: const Text('Open jobs only'), selected: _openOnly, onSelected: (v) => setState(() => _openOnly = v)),
          for (final s0 in RepairStatus.values)
            if (app.repairs.visibleJobs().any((j) => j.status == s0)) StatusPill('${s0.label}: ${app.repairs.visibleJobs().where((j) => j.status == s0).length}', repairTone(c, s0)),
        ]),
        const SizedBox(height: 14),
        Expanded(
          child: SingleChildScrollView(
            child: AppTable<RepairJob>(
              rows: jobs,
              onRowTap: (j) => showRepairDetail(context, ref, j.id),
              empty: const EmptyState(icon: Icons.build_circle_outlined, title: 'No repair jobs', message: 'Devices received for repair appear here.'),
              columns: [
                AppColumn('Job', (j) => Text(j.number, style: const TextStyle(fontWeight: FontWeight.w600))),
                AppColumn('Received', (j) => Text(dateFmt.format(j.receivedDate))),
                AppColumn('Customer', flex: 2, (j) => Text(j.customerName)),
                AppColumn('Device', flex: 3, minWidth: 150, (j) => Text('${j.productName}${j.serial.isEmpty ? '' : ' • ${j.serial}'}', overflow: TextOverflow.ellipsis)),
                AppColumn('Technician', (j) => Text(techs[j.technicianId] ?? '—')),
                AppColumn('Charges', numeric: true, (j) => Text(j.totalCharges.format())),
                AppColumn('Status', (j) => StatusPill(j.status.label, repairTone(c, j.status))),
              ],
            ),
          ),
        ),
      ]),
    );
  }
}

Future<void> showReceiveRepair(BuildContext context, WidgetRef ref, {String? customerId, String customerName = '', String? productId, String productName = '', String serial = ''}) async {
  final app = ref.read(servicesProvider);
  var custId = customerId;
  final name = TextEditingController(text: customerName);
  final phone = TextEditingController();
  final product = TextEditingController(text: productName);
  final sn = TextEditingController(text: serial);
  final issue = TextEditingController();
  final cond = TextEditingController();
  final charges = TextEditingController();
  String? techId;
  final key = GlobalKey<FormState>();
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) => FormDialog(
        title: 'Receive device for repair',
        body: Form(
          key: key,
          child: Column(children: [
            FieldRow([
              TextFormField(
                controller: name,
                validator: (v) => (v ?? '').trim().isEmpty ? 'Required' : null,
                decoration: InputDecoration(
                  labelText: 'Customer name *',
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.person_search),
                    onPressed: () async {
                      final p = await pickFromList<Party>(ctx, title: 'Customer', items: app.parties.list(PartyKind.customer), label: (x) => x.name, subtitle: (x) => x.phone);
                      if (p != null) {
                        setS(() {
                          custId = p.id;
                          name.text = p.name;
                          phone.text = p.phone;
                        });
                      }
                    },
                  ),
                ),
              ),
              LabeledField('Phone', phone),
            ]),
            FieldRow([LabeledField('Device / product *', product, validator: (v) => (v ?? '').trim().isEmpty ? 'Required' : null), LabeledField('Serial number', sn)]),
            FieldRow([LabeledField('Reported issue *', issue, maxLines: 2, validator: (v) => (v ?? '').trim().isEmpty ? 'Required' : null)]),
            FieldRow([LabeledField('Physical condition (scratches, missing parts…)', cond)]),
            FieldRow([
              AppDropdown<String?>(
                value: techId,
                decoration: const InputDecoration(labelText: 'Assign technician'),
                items: [const DropdownMenuItem(value: null, child: Text('Not assigned')), for (final t in app.technicians.technicians()) DropdownMenuItem(value: t.id, child: Text(t.name))],
                onChanged: (v) => setS(() => techId = v),
              ),
              LabeledField('Estimated service charges', charges, formatters: moneyInput, validator: (v) => moneyValidator(v, required: false)),
            ]),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              if (!key.currentState!.validate()) return;
              try {
                final job = await app.repairs.receive(
                  customerId: custId,
                  customerName: name.text,
                  customerPhone: phone.text,
                  productId: productId,
                  productName: product.text,
                  serial: sn.text,
                  reportedIssue: issue.text,
                  physicalCondition: cond.text,
                  technicianId: techId,
                  serviceCharges: Money.tryParse(charges.text) ?? const Money.zero(),
                );
                if (!ctx.mounted) return;
                Navigator.pop(ctx);
                showToast(context, 'Job ${job.number} created${job.underWarranty ? ' (device is under warranty)' : ''}');
                if (context.mounted) await showPdf(context, app.ctx.settings, () => repairReceiptPdf(app.ctx.settings, job), name: job.number);
              } catch (e) {
                if (ctx.mounted) showToast(ctx, friendlyError(e), error: true);
              }
            },
            child: const Text('Create job & print receipt'),
          ),
        ],
      ),
    ),
  );
}

Future<void> showRepairDetail(BuildContext context, WidgetRef ref, String id) => showDialog<void>(
      context: context,
      builder: (ctx) => Consumer(builder: (ctx, ref, _) {
        final c = AppTheme.of(ctx);
        final app = ref.watch(liveServicesProvider);
        final j0 = app.repairs.list().where((x) => x.id == id).firstOrNull;
        if (j0 == null) return const RecordGone('repair job');
        final j = j0;
        final canManage = app.ctx.can(Permission.manageRepairs);
        final techs = {for (final t in app.technicians.technicians(includeInactive: true)) t.id: t.name};
        final st = app.ctx.settings;
        return FormDialog(
          title: 'Repair ${j.number}',
          width: 820,
          headerTrailing: StatusPill(j.status.label, repairTone(c, j.status)),
          body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            InfoRow('Customer', '${j.customerName}${j.customerPhone.isEmpty ? '' : ' • ${j.customerPhone}'}'),
            InfoRow('Device', '${j.productName}${j.serial.isEmpty ? '' : ' • S/N ${j.serial}'}'),
            InfoRow('Warranty', j.underWarranty ? 'Under warranty' : 'Not under warranty', color: j.underWarranty ? c.accent : null),
            InfoRow('Received', dateTimeFmt.format(j.receivedDate)),
            InfoRow('Technician', techs[j.technicianId] ?? 'Not assigned'),
            InfoRow('Reported issue', j.reportedIssue),
            if (j.physicalCondition.isNotEmpty) InfoRow('Condition', j.physicalCondition),
            if (j.repairNotes.isNotEmpty) InfoRow('Repair notes', j.repairNotes),
            const Divider(),
            Text('Parts used', style: TextStyle(fontWeight: FontWeight.w700, color: c.text)),
            for (final p in j.parts) InfoRow('${p.name} × ${p.qty.format()}', p.price.format()),
            if (j.parts.isEmpty) Text('None', style: TextStyle(color: c.textMuted)),
            const Divider(),
            InfoRow('Service charges', j.serviceCharges.format()),
            InfoRow('Total charges', j.totalCharges.format(), strong: true),
            const Divider(),
            Text('Status history', style: TextStyle(fontWeight: FontWeight.w700, color: c.text)),
            for (final h in j.history.reversed) InfoRow('${dateTimeFmt.format(h.at)} • ${h.status.label}', h.note),
          ]),
          actions: [
            if (j.status.isOpen) ...[
              OutlinedButton(onPressed: () => _updateStatus(ctx, ref, j, canManage, techs), child: const Text('Update status')),
              if (canManage) OutlinedButton(onPressed: () => _addPart(ctx, ref, j), child: const Text('Add part')),
              if (canManage) FilledButton(onPressed: () => _deliver(ctx, ref, j), child: const Text('Deliver')),
            ],
            OutlinedButton.icon(
                onPressed: () => showPdf(ctx, st, () => repairReceiptPdf(st, j, technicianName: techs[j.technicianId] ?? ''), name: j.number), icon: const Icon(Icons.print, size: 18), label: const Text('Receipt')),
          ],
        );
      }),
    );

Future<void> _updateStatus(BuildContext context, WidgetRef ref, RepairJob j, bool canManage, Map<String, String> techs) async {
  final app = ref.read(servicesProvider);
  var status = j.status == RepairStatus.received ? RepairStatus.diagnosing : j.status;
  String? tech = j.technicianId;
  final note = TextEditingController();
  final notes = TextEditingController(text: j.repairNotes);
  final charges = TextEditingController(text: j.serviceCharges.toDecimalString());
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) => FormDialog(
        title: 'Update ${j.number}',
        width: 560,
        body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final s0 in RepairStatus.values.where((s0) => s0 != RepairStatus.delivered)) ChoiceChip(label: Text(s0.label), selected: status == s0, onSelected: (_) => setS(() => status = s0)),
          ]),
          const SizedBox(height: 12),
          if (canManage)
            AppDropdown<String?>(
              value: tech,
              decoration: const InputDecoration(labelText: 'Technician'),
              items: [const DropdownMenuItem(value: null, child: Text('Not assigned')), for (final e in techs.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
              onChanged: (v) => setS(() => tech = v),
            ),
          const SizedBox(height: 12),
          TextField(controller: notes, maxLines: 2, decoration: const InputDecoration(labelText: 'Repair notes')),
          const SizedBox(height: 12),
          if (canManage) TextField(controller: charges, inputFormatters: moneyInput, decoration: const InputDecoration(labelText: 'Service charges')),
          const SizedBox(height: 12),
          TextField(controller: note, decoration: const InputDecoration(labelText: 'Status note')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final ok = await runAction(
                  ctx, () => app.repairs.updateStatus(j.id, status, note: note.text, technicianId: tech, repairNotes: notes.text, serviceCharges: Money.tryParse(charges.text)),
                  success: 'Job updated');
              if (ok && ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}

Future<void> _addPart(BuildContext context, WidgetRef ref, RepairJob j) async {
  final app = ref.read(servicesProvider);
  final p = await pickFromList<Product>(context,
      title: 'Part from stock', items: app.catalog.products().where((p) => !p.requiresSerial && p.stockQty.isPositive).toList(), label: (x) => x.name, subtitle: (x) => 'Stock ${x.stockQty.format()} • ${x.sellingPrice.format()}');
  if (p == null || !context.mounted) return;
  final qty = TextEditingController(text: '1');
  final price = TextEditingController(text: p.sellingPrice.toDecimalString());
  await showDialog<void>(
    context: context,
    builder: (ctx) => FormDialog(
      title: 'Add ${p.name}',
      width: 420,
      body: FieldRow([
        LabeledField('Quantity (${p.unit})', qty, formatters: qtyInput, autofocus: true),
        LabeledField('Charge per unit', price, formatters: moneyInput),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
          onPressed: () async {
            final ok = await runAction(ctx, () => app.repairs.addPart(j.id, p.id, Qty.tryParse(qty.text) ?? const Qty.zero(), Money.tryParse(price.text) ?? const Money.zero()),
                success: 'Part added (stock reduced)');
            if (ok && ctx.mounted) Navigator.pop(ctx);
          },
          child: const Text('Add'),
        ),
      ],
    ),
  );
}

Future<void> _deliver(BuildContext context, WidgetRef ref, RepairJob j) async {
  final app = ref.read(servicesProvider);
  final paid = TextEditingController(text: j.totalCharges.toDecimalString());
  var method = PaymentMethod.cash;
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) => FormDialog(
        title: 'Deliver ${j.number}',
        width: 460,
        body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          InfoRow('Total charges', j.totalCharges.format(), strong: true),
          if (j.customerId == null) const Text('No customer account: full payment is required.'),
          const SizedBox(height: 10),
          FieldRow([
            LabeledField('Amount received', paid, formatters: moneyInput),
            AppDropdown<PaymentMethod>(
              value: method,
              decoration: const InputDecoration(labelText: 'Method'),
              items: [for (final m0 in PaymentMethod.values) DropdownMenuItem(value: m0, child: Text(m0.label))],
              onChanged: (v) => setS(() => method = v ?? method),
            ),
          ]),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final ok = await runAction(ctx, () => app.repairs.deliver(j.id, paid: Money.tryParse(paid.text) ?? const Money.zero(), method: method), success: 'Device delivered');
              if (ok && ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Deliver'),
          ),
        ],
      ),
    ),
  );
}
