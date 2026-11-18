import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/errors.dart';
import '../../data/store/data_store.dart';
import '../../data/windows_backup_task.dart';
import '../../domain/services/backup_service.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/file_browser.dart';
import '../widgets/forms.dart';

String fileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}

/// Opens a folder in Windows Explorer (Finder on macOS).
Future<void> openFolder(String dir) async {
  await Directory(dir).create(recursive: true);
  if (Platform.isWindows) {
    await Process.run('explorer', [dir]);
  } else if (Platform.isMacOS) {
    await Process.run('open', [dir]);
  } else {
    await Process.run('xdg-open', [dir]);
  }
}

class BackupPage extends ConsumerStatefulWidget {
  const BackupPage({super.key});
  @override
  ConsumerState<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends ConsumerState<BackupPage> {
  bool _busy = false;
  String _busyText = '';
  List<BackupEntry> _local = [];
  List<BackupEntry> _main = [];
  String? _folderProblem;
  bool _folderChecked = false;
  bool? _taskRegistered;
  String? _taskError;
  List<String> _issues = [];
  bool _checked = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final app = ref.read(servicesProvider);
    final dir = app.backup.backupDirectory;
    final problem = dir == null ? null : await BackupService.folderProblem(dir);
    final l = await app.backup.history(app.backup.localBackupDir);
    final m = (dir == null || problem != null) ? <BackupEntry>[] : await app.backup.history(dir);
    final task = await WindowsBackupTask.exists();
    if (mounted) {
      setState(() {
        _local = l;
        _main = m;
        _folderProblem = problem;
        _folderChecked = true;
        _taskRegistered = Platform.isWindows ? task : null;
      });
    }
  }

  Future<void> _syncTask() async {
    final st = ref.read(servicesProvider).ctx.settings;
    final err = await WindowsBackupTask.sync(enabled: st.autoBackup, hour: st.backupHour, minute: st.backupMinute);
    if (mounted) setState(() => _taskError = Platform.isWindows ? err : null);
  }

  Future<void> _saveSchedule(Map<String, dynamic> changes) async {
    final ok = await runAction(context, () => ref.read(servicesProvider).settings.save(changes));
    if (ok) {
      await _syncTask();
      await _reload();
    }
  }

  Future<void> _backupNow() async {
    setState(() {
      _busy = true;
      _busyText = 'Creating backup…';
    });
    try {
      final files = await ref.read(servicesProvider).backup.backupNow();
      if (mounted) {
        showToast(context, 'Backup created and verified: ${files.map((f) => p.basename(f.path)).toSet().join(', ')}');
      }
    } on BackupFolderUnavailable catch (e) {
      if (mounted) await _folderUnavailable(e);
    } catch (e) {
      if (mounted) showToast(context, 'Backup FAILED: ${friendlyError(e)}', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
      await _reload();
    }
  }

  Future<void> _folderUnavailable(BackupFolderUnavailable e) async {
    final choose = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.error_outline, color: AppTheme.of(ctx).danger, size: 40),
        title: const Text('Backup NOT saved to the backup folder'),
        content: SizedBox(
          width: 480,
          child: Text(
            '${e.message}\n\n'
            '${e.localCopy != null ? 'A copy was saved on this computer only:\n${e.localCopy!.path}\n\nThat copy is lost if Windows is reinstalled. ' : ''}'
            'Connect the drive, or choose another backup location (for example a USB drive).',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Later')),
          FilledButton.icon(onPressed: () => Navigator.pop(ctx, true), icon: const Icon(Icons.folder_open), label: const Text('Choose another location')),
        ],
      ),
    );
    if (choose == true) await _chooseFolder();
  }

  Future<void> _chooseFolder() async {
    final app = ref.read(servicesProvider);
    final dir = await browseFiles(
      context,
      mode: BrowseMode.pickFolder,
      title: 'Choose backup folder (another drive or a USB drive)',
      startDir: app.backup.backupDirectory,
    );
    if (dir == null || !mounted) return;
    final appRoot = p.dirname(app.backup.localBackupDir);
    if (p.isWithin(appRoot, dir) || p.equals(appRoot, dir)) {
      showToast(context, 'Choose a different drive or folder. Backups must not sit only next to the database.', error: true);
      return;
    }
    final problem = await BackupService.folderProblem(dir);
    if (!mounted) return;
    if (problem != null) {
      showToast(context, problem, error: true);
      return;
    }
    await runAction(context, () => app.settings.save({'backupDirectory': dir}), success: 'Backup location set to $dir');
    await _reload();
  }

  Future<void> _useDefault() async {
    await runAction(context, () => ref.read(servicesProvider).settings.save({'backupDirectory': null}), success: 'Using the default backup location');
    await _reload();
  }

  Future<void> _pickAndRestore() async {
    final path = await browseFiles(
      context,
      mode: BrowseMode.openFile,
      title: 'Choose a backup file (AL-AQSA_Backup_….zip)',
      extensions: const [backupExtension, legacyBackupExtension],
      startDir: ref.read(servicesProvider).backup.backupDirectory,
    );
    if (path != null) await _restore(path);
  }

  Future<void> _restore(String path) async {
    final app = ref.read(servicesProvider);
    setState(() {
      _busy = true;
      _busyText = 'Checking backup…';
    });
    BackupPreview preview;
    try {
      preview = await app.backup.inspect(path);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            icon: Icon(Icons.gpp_bad_outlined, color: AppTheme.of(ctx).danger, size: 40),
            title: const Text('This backup cannot be restored'),
            content: Text('${friendlyError(e)}\n\nYour current data was not changed.'),
            actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
          ),
        );
      }
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    final ok = await showDialog<bool>(context: context, builder: (_) => _RestorePreview(preview: preview));
    if (ok != true || !mounted) return;
    setState(() {
      _busy = true;
      _busyText = 'Restoring… do not close the application';
    });
    try {
      final r = await app.backup.restore(path);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          icon: Icon(Icons.check_circle, color: AppTheme.of(ctx).accent, size: 40),
          title: const Text('Restore complete and verified'),
          content: Text(
            '${r.records} records and ${r.files} image(s) restored and checked.\n\n'
            'Your data from before the restore was saved to:\n${r.safetyBackup.path}\n\n'
            'The application now re-opens the restored data.',
          ),
          actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Open restored data'))],
        ),
      );
      ref.read(currentUserProvider.notifier).state = null; // splash re-opens the data
    } catch (e) {
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            icon: Icon(Icons.error_outline, color: AppTheme.of(ctx).danger, size: 40),
            title: const Text('Restore failed'),
            content: Text('${friendlyError(e)}\n\nYour current data was kept. A safety backup of it is in the local backup folder.'),
            actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      await _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    final app = ref.watch(liveServicesProvider);
    final st = app.ctx.settings;
    final b = app.backup;
    final dir = b.backupDirectory;
    final last = b.lastBackupAt;
    final err = b.lastBackupError;
    String hm(int h, int m) => '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';

    Widget banner(IconData icon, Color color, String text, {Widget? action}) => Container(
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: color.withValues(alpha: 0.4)),
          ),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 8,
            children: [
              Icon(icon, color: color),
              ConstrainedBox(constraints: const BoxConstraints(maxWidth: 820), child: Text(text)),
              if (action != null) action,
            ],
          ),
        );

    Widget list(String title, List<BackupEntry> rows, String? folder) => AppCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                Expanded(child: Text(title, style: TextStyle(fontWeight: FontWeight.w700, color: c.text))),
                if (folder != null)
                  TextButton.icon(onPressed: () => openFolder(folder), icon: const Icon(Icons.folder_open, size: 18), label: const Text('Open folder')),
              ]),
              const SizedBox(height: 8),
              if (rows.isEmpty) Text('No backups found', style: TextStyle(color: c.textMuted)),
              for (final e in rows.take(20))
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(e.manifest.label == 'auto' ? Icons.schedule : (e.manifest.label == 'before_restore' ? Icons.shield_outlined : Icons.backup_outlined), color: c.accent),
                  title: Text('${dateTimeFmt.format(e.manifest.createdAt)}  •  ${p.basename(e.file.path)}', maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    '${switch (e.manifest.label) { 'auto' => 'automatic', 'before_restore' => 'safety copy before a restore', _ => e.manifest.label }} • ${fileSize(e.size)} • ${e.manifest.totalRecords} records • ${e.manifest.fileCount} image(s) • v${e.manifest.appVersion}',
                    style: TextStyle(color: c.textMuted, fontSize: 12),
                  ),
                  trailing: TextButton(onPressed: _busy ? null : () => _restore(e.file.path), child: const Text('Restore')),
                ),
            ],
          ),
        );

    return SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Backup & Restore',
            breadcrumbs: const ['Backup & Restore'],
            actions: [
              OutlinedButton.icon(
                key: const ValueKey('restore-backup'),
                onPressed: _busy ? null : _pickAndRestore,
                icon: const Icon(Icons.restore, size: 18),
                label: const Text('Restore Backup'),
              ),
              FilledButton.icon(
                key: const ValueKey('backup-now'),
                onPressed: _busy ? null : _backupNow,
                icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.backup),
                label: const Text('Create Backup Now'),
              ),
            ],
          ),
          if (_busy) Padding(padding: const EdgeInsets.only(bottom: 12), child: Row(children: [const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)), const SizedBox(width: 10), Text(_busyText)])),
          if (err != null)
            banner(Icons.error_outline, c.danger, 'Last backup FAILED${b.lastBackupErrorAt == null ? '' : ' (${dateTimeFmt.format(b.lastBackupErrorAt!)})'}: $err',
                action: TextButton(onPressed: _chooseFolder, child: const Text('Choose another location'))),
          if (dir == null)
            banner(Icons.warning_amber_rounded, c.warning,
                'No backup folder is set. Backups are only stored on this computer. Choose another drive or a USB drive so a copy survives a Windows reinstall.',
                action: TextButton(onPressed: _chooseFolder, child: const Text('Choose folder')))
          else if (_folderChecked && _folderProblem != null)
            banner(Icons.usb_off, c.danger, 'Backup location unavailable: $_folderProblem Backups cannot be saved there until it is connected.',
                action: TextButton(onPressed: _chooseFolder, child: const Text('Choose another location'))),
          AdaptiveSplit(
            breakpoint: 980,
            children: [
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Backup location', style: TextStyle(fontWeight: FontWeight.w700, color: c.text)),
                    const SizedBox(height: 8),
                    InfoRow('Current location', dir == null ? 'Not set' : '$dir${b.usingDefaultFolder ? '  (default)' : ''}', color: _folderProblem != null ? c.danger : null),
                    InfoRow('Status', !_folderChecked ? 'Checking…' : (dir == null ? 'Not set' : (_folderProblem == null ? 'Available' : 'Not available')), color: _folderProblem == null && dir != null ? c.accent : c.danger),
                    InfoRow('Second copy (this computer)', b.localBackupDir),
                    InfoRow('Last successful backup', last == null ? 'Never' : dateTimeFmt.format(last), color: last == null ? c.danger : null),
                    if (b.lastBackupFile != null) InfoRow('Last backup file', b.lastBackupFile!),
                    InfoRow('Last backup error', err ?? 'None', color: err == null ? null : c.danger),
                    const SizedBox(height: 10),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      OutlinedButton.icon(onPressed: _chooseFolder, icon: const Icon(Icons.drive_folder_upload, size: 18), label: const Text('Change backup location')),
                      if (!b.usingDefaultFolder && b.defaultBackupDir != null)
                        TextButton(onPressed: _useDefault, child: Text('Use default (${b.defaultBackupDir})')),
                      if (dir != null && _folderProblem == null)
                        TextButton.icon(onPressed: () => openFolder(dir), icon: const Icon(Icons.folder_open, size: 18), label: const Text('Open Backup Folder')),
                    ]),
                    const SizedBox(height: 12),
                    Text(
                      'A backup on drive D: protects your data when Windows is reinstalled, but only if the D: partition '
                      'itself is not formatted or deleted. It does NOT protect against the hard disk failing or the computer '
                      'being lost: also copy backups regularly to a USB drive or external disk (set it as the location, or '
                      'copy the files from the backup folder).',
                      style: TextStyle(color: c.textMuted, fontSize: 12),
                    ),
                  ],
                ),
              ),
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Automatic backup', style: TextStyle(fontWeight: FontWeight.w700, color: c.text)),
                    SwitchListTile(
                      key: const ValueKey('auto-backup'),
                      contentPadding: EdgeInsets.zero,
                      value: st.autoBackup,
                      title: Text('Automatic daily backup ${st.autoBackup ? 'ON' : 'OFF'}'),
                      subtitle: Text(
                        st.autoBackup
                            ? 'Every day at ${hm(st.backupHour, st.backupMinute)}. If the computer is off or the app is closed then, it runs as soon as possible afterwards.'
                            : 'No automatic backups are made.',
                      ),
                      onChanged: (v) => _saveSchedule({'autoBackup': v}),
                    ),
                    Wrap(
                      spacing: 24,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Row(mainAxisSize: MainAxisSize.min, children: [
                          const Text('Daily backup time'),
                          const SizedBox(width: 12),
                          AppDropdownButton<int>(
                            key: const ValueKey('backup-hour'),
                            value: st.backupHour,
                            items: [for (var h = 0; h < 24; h++) DropdownMenuItem(value: h, child: Text(h.toString().padLeft(2, '0')))],
                            onChanged: (v) => _saveSchedule({'backupHour': v}),
                          ),
                          const Text(' : '),
                          AppDropdownButton<int>(
                            key: const ValueKey('backup-minute'),
                            value: st.backupMinute - st.backupMinute % 5,
                            items: [for (var m = 0; m < 60; m += 5) DropdownMenuItem(value: m, child: Text(m.toString().padLeft(2, '0')))],
                            onChanged: (v) => _saveSchedule({'backupMinute': v}),
                          ),
                        ]),
                        Row(mainAxisSize: MainAxisSize.min, children: [
                          const Text('Keep last'),
                          const SizedBox(width: 12),
                          AppDropdownButton<int>(
                            value: [7, 14, 30, 60, 90].contains(st.backupKeep) ? st.backupKeep : 30,
                            items: [for (final n in [7, 14, 30, 60, 90]) DropdownMenuItem(value: n, child: Text('$n automatic backups'))],
                            onChanged: (v) => _saveSchedule({'backupKeep': v}),
                          ),
                        ]),
                      ],
                    ),
                    const SizedBox(height: 8),
                    InfoRow('Last automatic backup', b.lastAutoBackupAt == null ? 'Never' : dateTimeFmt.format(b.lastAutoBackupAt!)),
                    if (st.autoBackup) InfoRow('Next automatic backup', b.autoBackupDue ? 'Due now (runs within a minute)' : dateTimeFmt.format(b.nextScheduledTime())),
                    if (_taskRegistered != null)
                      InfoRow(
                        'Windows scheduled task',
                        _taskError != null ? 'Could not register: $_taskError' : (_taskRegistered! ? 'Registered (runs even when the app is closed)' : (st.autoBackup ? 'Not registered — backups run while the app is open' : 'Off')),
                        color: _taskError != null ? c.warning : null,
                      ),
                    const SizedBox(height: 8),
                    Text(
                      'Retention: only automatic backups older than the newest ${st.backupKeep} are deleted, in each folder. '
                      'Manual backups and the safety copies made before a restore are never deleted automatically. '
                      'An existing backup file is never overwritten.',
                      style: TextStyle(color: c.textMuted, fontSize: 12),
                    ),
                    const Divider(height: 28),
                    Text('Data integrity check', style: TextStyle(fontWeight: FontWeight.w700, color: c.text)),
                    const SizedBox(height: 6),
                    Text('Verifies balances against the ledger, stock against FIFO layers and movements, technician holdings, inspection queue and serial numbers.',
                        style: TextStyle(color: c.textMuted)),
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: () => setState(() {
                          _issues = app.integrity.check().map((e) => e.toString()).toList();
                          _checked = true;
                        }),
                        icon: const Icon(Icons.health_and_safety_outlined, size: 18),
                        label: const Text('Run check'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (_checked && _issues.isEmpty)
                      Row(children: [Icon(Icons.check_circle, color: c.accent), const SizedBox(width: 8), const Expanded(child: Text('All records are consistent.'))]),
                    for (final i in _issues) Text('• $i', style: TextStyle(color: c.danger)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          AdaptiveSplit(
            breakpoint: 980,
            children: [
              list('Backup history — ${dir ?? 'no backup folder'}', _main, dir != null && _folderProblem == null ? dir : null),
              list('Second copy on this computer', _local, b.localBackupDir),
            ],
          ),
        ],
      ),
    );
  }
}

class _RestorePreview extends StatefulWidget {
  final BackupPreview preview;
  const _RestorePreview({required this.preview});
  @override
  State<_RestorePreview> createState() => _RestorePreviewState();
}

class _RestorePreviewState extends State<_RestorePreview> {
  bool _understood = false;

  @override
  Widget build(BuildContext context) {
    final c = AppTheme.of(context);
    final m = widget.preview.manifest;
    final rows = <(String, int)>[
      ('Products', m.count(Boxes.products)),
      ('Serial numbers (units)', m.count(Boxes.serials)),
      ('Categories', m.count(Boxes.categories)),
      ('Purchases', m.count(Boxes.purchases)),
      ('Sales invoices', m.count(Boxes.sales)),
      ('Quotations', m.count(Boxes.quotations)),
      ('Returns', m.count(Boxes.salesReturns) + m.count(Boxes.purchaseReturns)),
      ('Customers', m.count(Boxes.customers)),
      ('Suppliers', m.count(Boxes.suppliers)),
      ('Payments', m.count(Boxes.payments)),
      ('Ledger entries', m.count(Boxes.ledger)),
      ('Technician records', m.count(Boxes.employees) + m.count(Boxes.techTxns)),
      ('Warranty claims & repairs', m.count(Boxes.warrantyClaims) + m.count(Boxes.repairs)),
      ('Images (products, logo)', m.fileCount),
    ];
    return FormDialog(
      title: 'Restore this backup?',
      width: 600,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InfoRow('File', p.basename(widget.preview.path)),
          InfoRow('Backup date', dateTimeFmt.format(m.createdAt)),
          InfoRow('Made by', '${m.app} v${m.appVersion}'),
          InfoRow('Check', 'Integrity verified (checksums, record counts${m.format >= 2 ? ', images' : ''})', color: c.accent),
          if (m.format < 2) InfoRow('Images', 'Not included (backup from an older version)', color: c.warning),
          if (m.missingFiles.isNotEmpty) InfoRow('Missing when backed up', '${m.missingFiles.length} image file(s)', color: c.warning),
          const SizedBox(height: 10),
          Text('Contents', style: TextStyle(fontWeight: FontWeight.w700, color: c.text)),
          const SizedBox(height: 4),
          Wrap(spacing: 18, runSpacing: 4, children: [
            for (final (label, n) in rows) SizedBox(width: 250, child: Text('$label: $n')),
          ]),
          const SizedBox(height: 14),
          if (widget.preview.olderThanLatest)
            Container(
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(color: c.warning.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10), border: Border.all(color: c.warning.withValues(alpha: 0.4))),
              child: Text(
                'This is an OLDER backup. Your latest backup is from ${dateTimeFmt.format(widget.preview.latestBackupAt!)}. '
                'Everything entered after ${dateTimeFmt.format(m.createdAt)} will be replaced.',
                style: TextStyle(color: c.text),
              ),
            ),
          Text(
            'ALL current data on this computer will be replaced by this backup. A safety backup of the current data is made first, '
            'and nothing is changed if the backup cannot be restored completely.',
          ),
          CheckboxListTile(
            key: const ValueKey('restore-understood'),
            contentPadding: EdgeInsets.zero,
            value: _understood,
            onChanged: (v) => setState(() => _understood = v ?? false),
            title: const Text('I understand the current data will be replaced'),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('restore-confirm'),
          style: FilledButton.styleFrom(backgroundColor: c.danger),
          onPressed: _understood ? () => Navigator.pop(context, true) : null,
          child: const Text('Restore'),
        ),
      ],
    );
  }
}
