// UI for permanent deletion (owner only):
//   1. "Delete <type>": the record's name and type, what is linked to it,
//      what will be erased / kept. Blocked records show why and offer the
//      safe alternative (archive, cancel) instead. Buttons: Cancel / Delete.
//   2. "Permanently delete?": cannot be undone; backups are not changed.
//      Requires ticking "I understand". Buttons: Cancel / Permanently Delete.
//   3. Erase + verify (one transaction), success shown only after the check.
//   4. If backup files still hold the record: keep them (default) or purge,
//      which needs typing PURGE and reports exactly which files were
//      rewritten, checked, unreadable or failed.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../core/errors.dart';
import '../domain/services/backup_service.dart';
import '../domain/services/permanent_delete_service.dart';
import 'providers.dart';
import 'theme.dart';
import 'widgets/common.dart';

/// Runs the whole flow. [archive] is the safe alternative offered when the
/// record cannot be erased (null = none).
Future<void> permanentDeleteFlow(BuildContext context, WidgetRef ref, DeletableKind kind, String id, {Future<void> Function()? archive, String archiveLabel = 'Archive instead'}) async {
  final app = ref.read(servicesProvider);
  final DeleteCheck chk;
  try {
    chk = app.erase.check(kind, id);
  } catch (e) {
    showToast(context, friendlyError(e), error: true);
    return;
  }
  final step1 = await showDialog<String>(context: context, builder: (_) => _ImpactDialog(chk: chk, archiveLabel: archive == null ? null : archiveLabel));
  if (!context.mounted || step1 == null) return;
  if (step1 == 'archive') {
    await runAction(context, archive!, success: '${chk.kind.label} archived');
    return;
  }
  final ok = await showDialog<bool>(context: context, barrierDismissible: false, builder: (_) => _FinalConfirm(chk: chk));
  if (ok != true || !context.mounted) return;

  final spec = chk.spec; // the plan, kept for the backup step
  PermanentDeleteResult? res;
  final done = await runAction(context, () async => res = await app.erase.deletePermanently(kind, id));
  if (!done || res == null || !context.mounted) return;
  final r = res!;
  showToast(context,
      '${chk.kind.label} "${chk.name}" and ${r.recordsRemoved - 1} linked record(s) permanently deleted and verified.${r.filesDeleted.isEmpty ? '' : ' ${r.filesDeleted.length} file(s) erased.'}${r.fileErrors.isEmpty ? '' : ' ${r.fileErrors.length} file(s) could not be erased.'}');

  // Backups: look, then let the owner decide.
  BackupScan scan;
  try {
    scan = await app.backup.findRecord(spec);
  } catch (_) {
    return;
  }
  if (!context.mounted || (scan.containing.isEmpty && scan.unreadable.isEmpty)) return;
  final purge = await showDialog<bool>(context: context, builder: (_) => _BackupsDialog(chk: chk, scan: scan));
  if (purge != true || !context.mounted) return;
  final typed = await showDialog<String>(context: context, barrierDismissible: false, builder: (_) => _PurgeConfirm(chk: chk, scan: scan));
  if (typed == null || !context.mounted) return;
  PurgeReport? report;
  final ok2 = await runAction(context, () async => report = await app.backup.purgeRecord(spec, confirmation: typed));
  if (!ok2 || report == null || !context.mounted) return;
  await showDialog<void>(context: context, builder: (_) => _PurgeReportDialog(chk: chk, report: report!));
}

Widget _bullets(List<String> items, Color color, {IconData icon = Icons.circle}) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final s in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(padding: const EdgeInsets.only(top: 4, right: 8), child: Icon(icon, size: icon == Icons.circle ? 6 : 16, color: color)),
              Expanded(child: Text(s)),
            ]),
          ),
      ],
    );

Widget _recordBox(AppColors c, DeleteCheck chk) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(color: c.danger.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(10), border: Border.all(color: c.danger.withValues(alpha: 0.25))),
      child: Row(children: [
        StatusPill(chk.kind.label, c.danger),
        const SizedBox(width: 10),
        Expanded(child: Text(chk.name, key: const ValueKey('pd-name'), style: TextStyle(fontWeight: FontWeight.w700, color: c.text))),
      ]),
    );

class _ImpactDialog extends StatelessWidget {
  final DeleteCheck chk;
  final String? archiveLabel;
  const _ImpactDialog({required this.chk, this.archiveLabel});
  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    return AlertDialog(
      key: const ValueKey('pd-impact'),
      scrollable: true,
      title: Text('Delete ${chk.kind.label.toLowerCase()}'),
      content: SizedBox(
        width: 480,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _recordBox(c, chk),
          const SizedBox(height: 14),
          if (!chk.allowed) ...[
            Text('This record cannot be permanently deleted:', style: TextStyle(fontWeight: FontWeight.w700, color: c.text)),
            const SizedBox(height: 6),
            _bullets(chk.blockers, c.danger, icon: Icons.block),
            const SizedBox(height: 8),
            Text('Deleting it would break invoices, ledgers, stock or profit figures. Instead:', style: TextStyle(color: c.textMuted)),
            const SizedBox(height: 6),
            _bullets(chk.safeAlternative, c.accent, icon: Icons.check_circle_outline),
          ] else ...[
            Text('Will be erased from the database (${chk.eraseTotal} record(s)):', style: TextStyle(fontWeight: FontWeight.w700, color: c.text)),
            const SizedBox(height: 6),
            Table(
              key: const ValueKey('pd-counts'),
              columnWidths: const {0: FlexColumnWidth(), 1: IntrinsicColumnWidth()},
              children: [
                for (final e in chk.erase.entries)
                  TableRow(children: [
                    Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Text(boxLabels[e.key] ?? e.key)),
                    Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Text('${e.value}', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w700, color: c.danger))),
                  ]),
              ],
            ),
            const SizedBox(height: 4),
            _bullets([
              'Their names and details in the audit log',
              for (final f in chk.exclusiveFiles) 'File: ${p.basename(f)}',
            ], c.text),
            if (chk.unlinkTotal > 0) ...[
              const SizedBox(height: 8),
              Text('Kept, but their link to it is removed (${chk.unlinkTotal}):', style: TextStyle(color: c.textMuted)),
              _bullets([for (final e in chk.unlink.entries) '${e.value} ${boxLabels[e.key] ?? e.key}'], c.textMuted),
            ],
            if (chk.sharedFiles.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('Kept (still used by other records):', style: TextStyle(color: c.textMuted)),
              _bullets([for (final f in chk.sharedFiles) 'File: ${p.basename(f)}'], c.textMuted),
            ],
            if (chk.effects.isNotEmpty) ...[
              const SizedBox(height: 8),
              _bullets(chk.effects, c.warning, icon: Icons.info_outline),
            ],
          ],
        ]),
      ),
      actions: [
        TextButton(key: const ValueKey('pd-cancel'), onPressed: () => Navigator.pop(context), child: Text(chk.allowed ? 'Cancel' : 'Close')),
        if (!chk.allowed && archiveLabel != null)
          FilledButton(key: const ValueKey('pd-archive'), onPressed: () => Navigator.pop(context, 'archive'), child: Text(archiveLabel!)),
        if (chk.allowed)
          FilledButton(
            key: const ValueKey('pd-delete'),
            style: FilledButton.styleFrom(backgroundColor: c.danger),
            onPressed: () => Navigator.pop(context, 'delete'),
            child: const Text('Delete'),
          ),
      ],
    );
  }
}

class _FinalConfirm extends StatefulWidget {
  final DeleteCheck chk;
  const _FinalConfirm({required this.chk});
  @override
  State<_FinalConfirm> createState() => _FinalConfirmState();
}

class _FinalConfirmState extends State<_FinalConfirm> {
  bool _understood = false;
  bool _pressed = false; // no double execution
  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    return AlertDialog(
      key: const ValueKey('pd-final'),
      scrollable: true,
      icon: Icon(Icons.delete_forever, color: c.danger, size: 34),
      title: const Text('Permanently delete?'),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _recordBox(c, widget.chk),
          const SizedBox(height: 12),
          Text('This cannot be undone. ${widget.chk.eraseTotal} record(s) are erased from the database now and will not come back after a restart.', style: TextStyle(color: c.text, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text('Backup files are NOT changed by this step: they are your recovery copies. You will be told if any backup still contains this record.', style: TextStyle(color: c.textMuted, fontSize: 13)),
          const SizedBox(height: 10),
          CheckboxListTile(
            key: const ValueKey('pd-understand'),
            contentPadding: EdgeInsets.zero,
            value: _understood,
            onChanged: (v) => setState(() => _understood = v ?? false),
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('I understand this cannot be undone'),
          ),
        ]),
      ),
      actions: [
        TextButton(key: const ValueKey('pd-final-cancel'), onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('pd-final-delete'),
          style: FilledButton.styleFrom(backgroundColor: c.danger),
          onPressed: !_understood || _pressed
              ? null
              : () {
                  setState(() => _pressed = true);
                  Navigator.pop(context, true);
                },
          child: const Text('Permanently Delete'),
        ),
      ],
    );
  }
}

String _when(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

class _BackupsDialog extends StatelessWidget {
  final DeleteCheck chk;
  final BackupScan scan;
  const _BackupsDialog({required this.chk, required this.scan});
  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    return AlertDialog(
      key: const ValueKey('pd-backups'),
      scrollable: true,
      title: Text(scan.containing.isEmpty ? 'Some backups could not be checked' : 'Backups still contain this record'),
      content: SizedBox(
        width: 520,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(
              scan.containing.isEmpty
                  ? 'The record is gone from the current database, and none of the ${scan.checkedClean} backup file(s) that could be opened contains it. But not every backup could be checked:'
                  : 'The record is gone from the current database. ${scan.containing.length} backup file(s) made earlier still contain it, so restoring one of them would bring it back.',
              style: TextStyle(color: c.text)),
          const SizedBox(height: 10),
          _bullets([for (final h in scan.containing) '${p.basename(h.path)}  •  ${_when(h.createdAt)}  •  ${h.label}  •  ${p.dirname(h.path)}'], c.textMuted),
          if (scan.unreadable.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('${scan.unreadable.length} backup file(s) could not be opened and were not checked:', style: TextStyle(color: c.warning)),
            _bullets([for (final f in scan.unreadable) f], c.warning),
          ],
          const SizedBox(height: 10),
          Text('Checked folders: ${scan.folders.join('  |  ')}', style: TextStyle(color: c.textMuted, fontSize: 12)),
          const SizedBox(height: 10),
          Text('Keeping the backups is recommended: they are your recovery copies.', style: TextStyle(color: c.accent)),
        ]),
      ),
      actions: [
        FilledButton(key: const ValueKey('pd-keep-backups'), onPressed: () => Navigator.pop(context, false), child: const Text('Keep backups')),
        if (scan.containing.isNotEmpty)
          TextButton(
            key: const ValueKey('pd-purge'),
            onPressed: () => Navigator.pop(context, true),
            child: Text('Purge from backups…', style: TextStyle(color: c.danger)),
          ),
      ],
    );
  }
}

class _PurgeConfirm extends StatefulWidget {
  final DeleteCheck chk;
  final BackupScan scan;
  const _PurgeConfirm({required this.chk, required this.scan});
  @override
  State<_PurgeConfirm> createState() => _PurgeConfirmState();
}

class _PurgeConfirmState extends State<_PurgeConfirm> {
  final _ctl = TextEditingController();
  bool _pressed = false;
  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    final ok = _ctl.text.trim() == 'PURGE';
    return AlertDialog(
      key: const ValueKey('pd-purge-confirm'),
      scrollable: true,
      icon: Icon(Icons.warning_amber_rounded, color: c.danger, size: 34),
      title: const Text('Destroy recovery copies?'),
      content: SizedBox(
        width: 520,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _recordBox(c, widget.chk),
          const SizedBox(height: 12),
          Text('${widget.scan.containing.length} backup file(s) will be rewritten without this record. After this it can NOT be recovered from these backups.', style: TextStyle(color: c.text, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text('Everything else in those backups is kept and each rewritten file is fully re-checked before it replaces the original. '
              'Backup copies outside these folders (USB drive, cloud) cannot be seen by the app; restoring any backup on this computer will skip this record from now on.',
              style: TextStyle(color: c.textMuted, fontSize: 13)),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('pd-purge-type'),
            controller: _ctl,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Type PURGE to confirm'),
            onChanged: (_) => setState(() {}),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('pd-purge-go'),
          style: FilledButton.styleFrom(backgroundColor: c.danger),
          onPressed: !ok || _pressed
              ? null
              : () {
                  setState(() => _pressed = true);
                  Navigator.pop(context, _ctl.text.trim());
                },
          child: const Text('Purge from backups'),
        ),
      ],
    );
  }
}

class _PurgeReportDialog extends StatelessWidget {
  final DeleteCheck chk;
  final PurgeReport report;
  const _PurgeReportDialog({required this.chk, required this.report});
  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    return AlertDialog(
      key: const ValueKey('pd-purge-report'),
      scrollable: true,
      title: Text(report.complete ? 'Removed from all checked backups' : 'Backup purge incomplete'),
      content: SizedBox(
        width: 520,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _bullets([
            '${report.rewritten} backup file(s) rewritten and verified',
            '${report.checkedClean} backup file(s) checked: do not contain it',
            if (report.unreadable.isNotEmpty) '${report.unreadable.length} backup file(s) could not be opened (NOT checked)',
            if (report.failed.isNotEmpty) '${report.failed.length} file(s) failed (original kept unchanged)',
          ], report.complete ? c.accent : c.warning, icon: Icons.check),
          for (final f in report.failed) Text('${p.basename(f.path)}: ${f.error}', style: TextStyle(color: c.danger, fontSize: 12)),
          for (final f in report.unreadable) Text('Not checked: $f', style: TextStyle(color: c.warning, fontSize: 12)),
          const SizedBox(height: 10),
          Text('Checked folders: ${report.folders.join('  |  ')}', style: TextStyle(color: c.textMuted, fontSize: 12)),
          const SizedBox(height: 6),
          Text('Copies outside these folders were not changed; restoring them here will skip this record.', style: TextStyle(color: c.textMuted, fontSize: 12)),
        ]),
      ),
      actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
    );
  }
}
