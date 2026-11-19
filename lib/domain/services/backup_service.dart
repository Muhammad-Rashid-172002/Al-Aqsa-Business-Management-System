import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../core/errors.dart';
import '../../data/migrations.dart';
import '../../data/store/data_store.dart';
import '../models/user.dart';
import 'context.dart';

const appVersion = '1.1.0';
const appDisplayName = 'AL-AQSA CCTV & SOLAR SYSTEM';

/// Default backup folder on Windows. A second partition survives a Windows
/// reinstall as long as the partition itself is not formatted.
const defaultWindowsBackupDir = r'D:\AL-AQSA_Backups';

/// Backup files: `AL-AQSA_Backup_2026-11-18.zip` (a second one on the same
/// day gets `_2`, `_3` …; nothing is ever overwritten). Files from older
/// versions (`alaqsa_*.aqbak`) are still listed and restorable.
const backupFilePrefix = 'AL-AQSA_Backup_';
const backupExtension = '.zip';
const legacyBackupExtension = '.aqbak';

const _backupAppName = appDisplayName;
const _legacyAppNames = {'AL AQSA CCTV'};

bool isBackupFileName(String path) {
  final n = p.basename(path);
  return (n.startsWith(backupFilePrefix) && n.toLowerCase().endsWith(backupExtension)) || n.toLowerCase().endsWith(legacyBackupExtension);
}

class BackupManifest {
  final String app;
  final int format;
  final int schemaVersion;
  final String appVersion;
  final DateTime createdAt;
  final String sha256;
  final Map<String, int> counts;
  final String label;
  final int fileCount;
  final int fileBytes;
  final String filesSha256;
  final List<String> missingFiles;
  const BackupManifest({
    required this.app,
    required this.format,
    required this.schemaVersion,
    required this.appVersion,
    required this.createdAt,
    required this.sha256,
    required this.counts,
    this.label = '',
    this.fileCount = 0,
    this.fileBytes = 0,
    this.filesSha256 = '',
    this.missingFiles = const [],
  });

  Map<String, dynamic> toJson() => {
        'app': app,
        'format': format,
        'schemaVersion': schemaVersion,
        'appVersion': appVersion,
        'createdAt': createdAt.toIso8601String(),
        'sha256': sha256,
        'counts': counts,
        'label': label,
        'fileCount': fileCount,
        'fileBytes': fileBytes,
        'filesSha256': filesSha256,
        'missingFiles': missingFiles,
      };
  factory BackupManifest.fromJson(Map<String, dynamic> j) => BackupManifest(
        app: j['app'] as String? ?? '',
        format: (j['format'] as num?)?.toInt() ?? 0,
        schemaVersion: (j['schemaVersion'] as num?)?.toInt() ?? 0,
        appVersion: j['appVersion'] as String? ?? '',
        createdAt: DateTime.parse(j['createdAt'] as String),
        sha256: j['sha256'] as String? ?? '',
        counts: (j['counts'] as Map? ?? {}).map((k, v) => MapEntry(k.toString(), (v as num).toInt())),
        label: j['label'] as String? ?? '',
        fileCount: (j['fileCount'] as num?)?.toInt() ?? 0,
        fileBytes: (j['fileBytes'] as num?)?.toInt() ?? 0,
        filesSha256: j['filesSha256'] as String? ?? '',
        missingFiles: (j['missingFiles'] as List? ?? const []).map((e) => e.toString()).toList(),
      );

  int get totalRecords => counts.values.fold(0, (a, b) => a + b);
  int count(String box) => counts[box] ?? 0;
}

/// One image / document stored in a backup.
/// A complete deletion plan for one permanently deleted record and
/// everything that belonged only to it. Used on the live database and,
/// when the owner explicitly purges, on every backup file, so both end up
/// the same. Holds internal ids only (no names), so it can be kept as a
/// restore block ("tombstone") without retaining deleted business data.
class PurgeSpec {
  final String kind;
  final Map<String, List<String>> keys; // box -> keys of records to erase
  /// Kept records lose their links to erased ones: an erased id is replaced
  /// by the mapped value (null = link removed; for purchases a new opaque
  /// batch id, so serial units keep their own batch cost).
  final Map<String, String?> relink;
  final List<String> ids; // audit entries about these ids lose their details
  final List<String> files; // file paths used only by erased records
  final List<String> anonymizeUsers; // login accounts kept (they have activity) but stripped of the person
  const PurgeSpec({required this.kind, required this.keys, this.relink = const {}, required this.ids, this.files = const [], this.anonymizeUsers = const []});

  Map<String, dynamic> toJson() => {'kind': kind, 'keys': keys, 'relink': relink, 'ids': ids, 'anonymizeUsers': anonymizeUsers};
  factory PurgeSpec.fromJson(Map<String, dynamic> j) => PurgeSpec(
        kind: '${j['kind']}',
        keys: (j['keys'] as Map? ?? {}).map((k, v) => MapEntry('$k', [for (final x in v as List) '$x'])),
        relink: (j['relink'] as Map? ?? {}).map((k, v) => MapEntry('$k', v?.toString())),
        ids: [for (final x in j['ids'] as List? ?? const []) '$x'],
        anonymizeUsers: [for (final x in j['anonymizeUsers'] as List? ?? const []) '$x'],
      );

  int get recordCount => keys.values.fold(0, (a, b) => a + b.length);

  static const linkedNote = '[linked record permanently deleted]';
  static const deletedInvoiceMarker = 'deleted-invoice';
  static const _textFields = {'note', 'notes', 'reason', 'jobRef'};

  /// [v] with every erased id replaced. Returns [v] itself when unchanged.
  Object? relinkValue(Object? v, [String? field]) {
    if (v is String) {
      if (!relink.containsKey(v)) return v;
      if (field == 'invoicedSaleId') return deletedInvoiceMarker; // stays "invoiced": never re-billed
      return relink[v];
    }
    if (v is List) {
      var changed = false;
      final out = <Object?>[];
      for (final e in v) {
        final r = relinkValue(e);
        if (!identical(r, e)) changed = true;
        if (r == null && e is String) continue; // drop the link from the list
        out.add(r);
      }
      return changed ? out : v;
    }
    if (v is Map) {
      var changed = false;
      var direct = false; // one of this record's own fields pointed at an erased record
      final out = <String, dynamic>{};
      for (final e in v.entries) {
        final r = relinkValue(e.value, '${e.key}');
        if (!identical(r, e.value)) {
          changed = true;
          if (e.value is String) direct = true;
        }
        out['${e.key}'] = r;
      }
      if (!changed) return v;
      // Text that described the erased record (invoice number, name) goes too.
      if (direct) {
        for (final f in _textFields) {
          if (out[f] is String && (out[f] as String).isNotEmpty) out[f] = linkedNote;
        }
      }
      return out;
    }
    return v;
  }

  Json anonymizedUser(Json u) => {...u, 'username': 'deleted_${'${u['id']}'.substring(0, 8)}', 'displayName': 'Deleted user', 'employeeId': null, 'active': false};

  /// Applies the plan to a decoded backup / restore data set. Returns how
  /// many records were erased.
  int applyTo(Map<String, Map<String, Json>> data) {
    var n = 0;
    for (final e in keys.entries) {
      for (final k in e.value) {
        if (data[e.key]?.remove(k) != null) n++;
      }
    }
    final idSet = ids.toSet();
    for (final b in data.entries) {
      if (b.key == Boxes.auditLogs) {
        for (final a in b.value.values) {
          if (idSet.contains(a['entityId']) && a['action'] != 'permanent_delete' && a['action'] != 'backup_purge') a['details'] = '[permanently deleted]';
        }
        continue;
      }
      for (final r in b.value.entries.toList()) {
        var v = relinkValue(r.value) as Json;
        if (b.key == Boxes.users && anonymizeUsers.contains(r.key)) v = anonymizedUser(v);
        if (!identical(v, r.value)) b.value[r.key] = v;
      }
    }
    return n;
  }

  bool presentIn(Map<String, Map<String, Json>> data) {
    for (final e in keys.entries) {
      if (e.value.any((k) => data[e.key]?.containsKey(k) ?? false)) return true;
    }
    return false;
  }
}

/// A backup file found to contain a record.
class BackupHit {
  final String path;
  final DateTime createdAt;
  final String label;
  const BackupHit(this.path, this.createdAt, this.label);
}

/// Where a record was looked for in backups, and what was found.
class BackupScan {
  final List<String> folders; // every folder that was checked
  final List<BackupHit> containing;
  final int checkedClean; // readable backups that do not contain it
  final List<String> unreadable; // could not be checked (damaged, locked)
  const BackupScan(this.folders, this.containing, this.checkedClean, this.unreadable);
}

class PurgeFileResult {
  final String path;
  final bool rewritten;
  final String? error;
  const PurgeFileResult(this.path, {required this.rewritten, this.error});
}

class PurgeReport {
  final List<String> folders;
  final List<PurgeFileResult> files;
  final int checkedClean;
  final List<String> unreadable;
  const PurgeReport(this.folders, this.files, this.checkedClean, this.unreadable);
  int get rewritten => files.where((f) => f.rewritten).length;
  List<PurgeFileResult> get failed => files.where((f) => f.error != null).toList();
  /// True only when every backup in every known folder was checked and none
  /// still contains the record.
  bool get complete => failed.isEmpty && unreadable.isEmpty;
}

class BackupFileEntry {
  final String zipPath; // files/media/products/x.jpg or files/external/3_logo.png
  final String original; // path on the computer the backup was made on
  final int size;
  final String sha256;
  const BackupFileEntry(this.zipPath, this.original, this.size, this.sha256);
  Map<String, dynamic> toJson() => {'zip': zipPath, 'original': original, 'size': size, 'sha256': sha256};
  factory BackupFileEntry.fromJson(Map<String, dynamic> j) =>
      BackupFileEntry(j['zip'] as String, j['original'] as String? ?? '', (j['size'] as num?)?.toInt() ?? 0, j['sha256'] as String? ?? '');
}

class BackupEntry {
  final File file;
  final BackupManifest manifest;
  final int size;
  const BackupEntry(this.file, this.manifest, this.size);
}

/// A checked backup, ready to be restored.
class BackupPreview {
  final String path;
  final BackupManifest manifest;
  final List<BackupFileEntry> files;

  /// A newer successful backup exists: restoring this one loses later work.
  final bool olderThanLatest;
  final DateTime? latestBackupAt;
  const BackupPreview(this.path, this.manifest, this.files, {required this.olderThanLatest, this.latestBackupAt});
}

/// The backup folder (e.g. D:) could not be used. A copy was still written
/// to the local folder inside the app data when [localCopy] is set.
class BackupFolderUnavailable extends BusinessException {
  final String folder;
  final File? localCopy;
  const BackupFolderUnavailable(super.message, {required this.folder, this.localCopy});
}

class BackupRunResult {
  final List<File> files;
  final File? mainFile; // in the backup folder
  final String? error;
  const BackupRunResult(this.files, this.mainFile, this.error);
  bool get ok => error == null;
}

class RestoreResult {
  final File safetyBackup;
  final int records;
  final int files;
  const RestoreResult(this.safetyBackup, this.records, this.files);
}

/// Backups are zip files holding `manifest.json` (version, record counts,
/// SHA-256 checksums), `data.json` (every record, taken as one consistent
/// snapshot), `files.json` + `files/…` (product images, shop logo and any
/// other files kept in the app's media folder).
///
/// Two copies are written: one to the backup folder (default
/// D:\AL-AQSA_Backups on Windows, changeable) and one to the local folder
/// inside the app data.
class BackupService {
  final ServiceContext ctx;
  final String localBackupDir; // inside the app data folder (second copy)
  final String mediaDir;

  /// Used when the owner has not chosen a backup folder (null in tests).
  final String? defaultBackupDir;

  BackupService(this.ctx, {required this.localBackupDir, required this.mediaDir, this.defaultBackupDir});

  /// The folder backups go to (owner's choice, else the default).
  String? get backupDirectory {
    final s = ctx.settings.backupDirectory;
    if (s != null && s.trim().isNotEmpty) return s.trim();
    return defaultBackupDir;
  }

  bool get usingDefaultFolder {
    final s = ctx.settings.backupDirectory;
    return (s == null || s.trim().isEmpty) && defaultBackupDir != null;
  }

  /// Null when [dir] can be written; otherwise a message saying why not
  /// (drive missing, read-only, no permission). Creates the folder if needed.
  static Future<String?> folderProblem(String dir) async {
    final root = p.rootPrefix(dir);
    if (Platform.isWindows && root.isNotEmpty && !await Directory(root).exists()) {
      return 'Drive ${root.replaceAll(RegExp(r'[\\/]+$'), '')} is not available (not connected, removed or renamed).';
    }
    try {
      await Directory(dir).create(recursive: true);
      final probe = File(p.join(dir, '.write_test_${DateTime.now().microsecondsSinceEpoch}'));
      await probe.writeAsString('ok', flush: true);
      await probe.delete();
      return null;
    } on FileSystemException catch (e) {
      return 'Cannot write to "$dir" (${e.osError?.message ?? e.message}).';
    }
  }

  // ── Creating backups ────────────────────────────────────────────────

  /// Files to include: everything in the media folder, plus image / logo
  /// files referenced by the data but kept elsewhere.
  List<String> _filesToInclude(Map<String, Map<String, String Function()>> snapshot) {
    final out = <String>{};
    final media = Directory(mediaDir);
    if (media.existsSync()) {
      for (final f in media.listSync(recursive: true, followLinks: false).whereType<File>()) {
        final rel = p.relative(f.path, from: mediaDir);
        if (rel.split(p.separator).any((s0) => s0.startsWith('.'))) continue; // staging / temp
        out.add(f.path);
      }
    }
    for (final ref in referencedFiles(snapshot)) {
      out.add(ref);
    }
    return out.toList()..sort();
  }

  /// Paths of images the records point to (product images, shop logo).
  static Iterable<String> referencedFiles(Map<String, Map<String, String Function()>> snapshot) sync* {
    for (final r in (snapshot[Boxes.products] ?? const {}).values) {
      final v = (jsonDecode(r()) as Map)['imagePath'];
      if (v is String && v.isNotEmpty) yield v;
    }
    final app = snapshot[Boxes.settings]?['app'];
    if (app != null) {
      final v = (jsonDecode(app()) as Map)['logoPath'];
      if (v is String && v.isNotEmpty) yield v;
    }
  }

  /// Backup bytes. The snapshot of all records is taken in one step (cheap
  /// and consistent: commits made afterwards are not included). Its JSON text
  /// is then produced in small slices that let the window keep drawing;
  /// reading the files, SHA-256 and zip compression run on a background
  /// isolate. Account passwords (hashes) are never written to a backup.
  Future<List<int>> _encode({String label = ''}) async {
    final createdAt = ctx.now();
    final snapshot = {
      for (final box in Boxes.all)
        if (box != Boxes.errorLog) box: ctx.store.jsonSnapshot(box),
    };
    final users = snapshot[Boxes.users]!;
    snapshot[Boxes.users] = {
      for (final e in users.entries)
        e.key: () {
          final m = jsonDecode(e.value()) as Map<String, dynamic>;
          if (m.containsKey('passwordHash')) m['passwordHash'] = '';
          return jsonEncode(m);
        },
    };
    final files = _filesToInclude(snapshot);
    final out = BytesBuilder(copy: false);
    final buf = StringBuffer('{');
    final slice = Stopwatch()..start();
    var firstBox = true;
    for (final b in snapshot.entries) {
      if (!firstBox) buf.write(',');
      firstBox = false;
      buf
        ..write(jsonEncode(b.key))
        ..write(':{');
      var first = true;
      for (final r in b.value.entries) {
        if (!first) buf.write(',');
        first = false;
        buf
          ..write(jsonEncode(r.key))
          ..write(':')
          ..write(r.value());
        if (slice.elapsedMilliseconds >= 12) {
          out.add(utf8.encode(buf.toString()));
          buf.clear();
          await Future<void>.delayed(Duration.zero);
          slice.reset();
        }
      }
      buf.write('}');
    }
    buf.write('}');
    out.add(utf8.encode(buf.toString()));
    final counts = {for (final b in snapshot.entries) b.key: b.value.length};
    return _zipInBackground(out.takeBytes(), counts, label, createdAt, files, mediaDir);
  }

  String _date(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// A name that does not exist yet in [dir]: never overwrites a backup.
  String _freeName(Directory dir, String label) {
    final suffix = switch (label) {
      'before_restore' => '_before-restore',
      _ => '',
    };
    final base = '$backupFilePrefix${_date(ctx.now())}$suffix';
    var name = '$base$backupExtension';
    for (var n = 2; File(p.join(dir.path, name)).existsSync() || File(p.join(dir.path, '$name.tmp')).existsSync(); n++) {
      name = '${base}_$n$backupExtension';
    }
    return name;
  }

  /// Writes a backup to [directory]. Uses write-to-temp + rename so a
  /// half-written file is never mistaken for a valid backup, then reads it
  /// back and checks it.
  Future<File> backupTo(String directory, {String label = 'manual'}) async {
    return _writeBackup(directory, await _encode(label: label), label: label);
  }

  Future<File> _writeBackup(String directory, List<int> bytes, {required String label}) async {
    final dir = Directory(directory);
    if (!await dir.exists()) await dir.create(recursive: true);
    final name = _freeName(dir, label);
    final tmp = File(p.join(dir.path, '$name.tmp'));
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      final file = await tmp.rename(p.join(dir.path, name));
      await _manifestInBackground(file.path, full: true); // read back and verify
      return file;
    } catch (_) {
      if (await tmp.exists()) await tmp.delete();
      rethrow;
    }
  }

  /// Creates a backup now. Writes to the backup folder and to the local
  /// folder. If the backup folder cannot be used, the local copy is still
  /// written and [BackupFolderUnavailable] is thrown so the owner can choose
  /// another folder — it is never reported as a success.
  Future<List<File>> backupNow({String label = 'manual'}) async {
    ctx.require(Permission.backupRestore);
    final r = await _run(label: label);
    if (r.error != null) {
      throw BackupFolderUnavailable(r.error!, folder: backupDirectory ?? '', localCopy: r.files.isEmpty ? null : r.files.last);
    }
    return r.files;
  }

  Future<BackupRunResult> _run({required String label}) async {
    final now = ctx.now();
    final List<int> bytes;
    try {
      bytes = await _encode(label: label); // one snapshot for both copies
    } catch (e) {
      await _setMeta('lastBackupAttempt', now.toIso8601String());
      await _setError('Backup could not be created: $e');
      rethrow;
    }
    await _setMeta('lastBackupAttempt', now.toIso8601String());
    final out = <File>[];
    File? main;
    String? error;
    final dir = backupDirectory;
    if (dir != null) {
      final problem = await folderProblem(dir);
      if (problem != null) {
        error = '$problem The backup was NOT saved to $dir.';
      } else {
        try {
          main = await _writeBackup(dir, bytes, label: label);
          out.add(main);
          await _rotate(dir);
        } catch (e) {
          error = 'Could not write the backup to "$dir": $e';
        }
      }
    }
    try {
      out.add(await _writeBackup(localBackupDir, bytes, label: label));
      await _rotate(localBackupDir);
    } catch (e) {
      error = error == null ? 'Could not write the local backup copy: $e' : '$error Local copy also failed: $e';
    }
    if (error != null) {
      await _setError(error);
    } else {
      await _setMeta('lastBackup', ctx.now().toIso8601String());
      await _setMeta('lastBackupFile', (main ?? out.last).path);
      await _setMeta('lastBackupError', '');
      await _setMeta('lastExternalBackupError', '');
    }
    return BackupRunResult(out, main, error);
  }

  Future<void> _setError(String message) async {
    await _setMeta('lastBackupError', message);
    await _setMeta('lastBackupErrorAt', ctx.now().toIso8601String());
    await _setMeta('lastExternalBackupError', '${ctx.now().toIso8601String()}: $message');
  }

  // ── Daily schedule ──────────────────────────────────────────────────

  /// The scheduled time that most recently passed (today's, or yesterday's
  /// when today's has not come yet).
  DateTime lastScheduledTime([DateTime? at]) {
    final st = ctx.settings;
    final now = at ?? ctx.now();
    final today = DateTime(now.year, now.month, now.day, st.backupHour, st.backupMinute);
    return now.isBefore(today) ? today.subtract(const Duration(days: 1)) : today;
  }

  DateTime nextScheduledTime([DateTime? at]) => lastScheduledTime(at).add(const Duration(days: 1));

  /// True when the automatic backup should run now: it is on, and no
  /// successful automatic backup was made since the last scheduled time.
  /// This also covers the computer being off or the app closed at the
  /// scheduled time: the backup runs as soon as the app (or the Windows
  /// scheduled task) starts afterwards.
  bool get autoBackupDue {
    final st = ctx.settings;
    if (!st.autoBackup) return false;
    final last = _metaDate('lastAutoBackup');
    final due = lastScheduledTime();
    if (last != null && !last.isBefore(due)) return false;
    // After a failed attempt wait an hour before trying again.
    final failedAt = _metaDate('lastAutoAttemptFailed');
    if (failedAt != null && ctx.now().difference(failedAt) < const Duration(hours: 1) && !failedAt.isBefore(due)) return false;
    return true;
  }

  /// Runs the automatic backup if it is due (called at start-up, every
  /// minute while the app runs, and by the Windows scheduled task).
  Future<BackupRunResult?> runAutoBackupIfDue() async {
    if (!autoBackupDue) return null;
    final r = await _run(label: 'auto');
    if (r.ok) {
      await _setMeta('lastAutoBackup', ctx.now().toIso8601String());
      await _setMeta('lastAutoAttemptFailed', '');
    } else {
      await _setMeta('lastAutoAttemptFailed', ctx.now().toIso8601String());
    }
    return r;
  }

  DateTime? _metaDate(String key) {
    final v = ctx.store.read(Boxes.meta, key)?['value'] as String?;
    return (v == null || v.isEmpty) ? null : DateTime.tryParse(v);
  }

  String? _metaString(String key) {
    final v = ctx.store.read(Boxes.meta, key)?['value'] as String?;
    return (v == null || v.isEmpty) ? null : v;
  }

  /// Last successful backup (manual or automatic) to the backup folder.
  DateTime? get lastBackupAt {
    final ds = [_metaDate('lastBackup'), _metaDate('lastAutoBackup')].whereType<DateTime>().toList()..sort();
    return ds.isEmpty ? null : ds.last;
  }

  DateTime? get lastAutoBackupAt => _metaDate('lastAutoBackup');
  String? get lastBackupFile => _metaString('lastBackupFile');
  DateTime? get lastAttemptAt => _metaDate('lastBackupAttempt');

  /// Error of the most recent backup, or null when it succeeded.
  String? get lastBackupError => _metaString('lastBackupError');
  DateTime? get lastBackupErrorAt => _metaDate('lastBackupErrorAt');

  /// Kept for older screens: same as [lastBackupError].
  String? get lastExternalBackupError => lastBackupError;

  Future<void> _setMeta(String key, String value) => ctx.store.commit([WriteOp(Boxes.meta, key, {'value': value})]);

  /// Retention: in each folder the newest [AppSettings.backupKeep]
  /// automatic backups are kept; older automatic ones are deleted. Manual
  /// backups and safety copies made before a restore are never deleted.
  Future<void> _rotate(String directory) async {
    final keep = ctx.settings.backupKeep;
    final files = (await history(directory)).where((e) => e.manifest.label == 'auto').toList();
    for (final e in files.skip(keep)) {
      try {
        await e.file.delete();
      } catch (_) {}
    }
  }

  Future<List<BackupEntry>> history(String directory) async {
    final dir = Directory(directory);
    if (!await dir.exists()) return [];
    final out = <BackupEntry>[];
    await for (final e in dir.list()) {
      if (e is File && isBackupFileName(e.path)) {
        try {
          out.add(BackupEntry(e, await _manifestInBackground(e.path), await e.length()));
        } catch (_) {
          // not a readable backup: not listed
        }
      }
    }
    out.sort((a, b) => b.manifest.createdAt.compareTo(a.manifest.createdAt));
    return out;
  }

  // ── Purging a permanently deleted record from backups ─────────────────

  /// Every folder this app writes backups to (backup folder + local copy,
  /// which also holds the safety copies made before a restore).
  List<String> backupFolders() => {if (backupDirectory != null) backupDirectory!, localBackupDir}.toList();

  Future<List<File>> _backupFiles(String dir) async {
    final d = Directory(dir);
    if (!await d.exists()) return [];
    return [await for (final e in d.list()) if (e is File && isBackupFileName(e.path)) e];
  }

  /// Opens every backup in [backupFolders] and lists those holding [spec].
  Future<BackupScan> findRecord(PurgeSpec spec) async {
    final folders = backupFolders();
    final hits = <BackupHit>[];
    final bad = <String>[];
    var clean = 0;
    for (final dir in folders) {
      for (final f in await _backupFiles(dir)) {
        final path = f.path;
        try {
          final (m, found) = await Isolate.run(() {
            final (m, data, _) = _checkBackup(path);
            return (m, spec.presentIn(data));
          });
          if (found) {
            hits.add(BackupHit(path, m.createdAt, m.label));
          } else {
            clean++;
          }
        } catch (e) {
          bad.add('$path — ${e is BusinessException ? e.message : e}'); // with the reason
        }
      }
    }
    return BackupScan(folders, hits, clean, bad);
  }

  /// Removes [spec] from every backup that holds it. This DESTROYS the
  /// recovery copies of that record. Each affected file is rewritten to a
  /// temporary file, fully re-checked, verified not to contain the record,
  /// and only then put in place of the original (a failure leaves the
  /// original untouched and is reported). First a restore block is saved:
  /// restoring any backup — also copies kept elsewhere (USB, cloud) that
  /// this app cannot see — skips these records.
  Future<PurgeReport> purgeRecord(PurgeSpec spec, {required String confirmation}) async {
    ctx.require(Permission.backupRestore);
    ctx.require(Permission.permanentDelete);
    if (confirmation != 'PURGE') throw const ValidationException('Type PURGE to confirm.');
    await _addTombstone(spec);
    final scan = await findRecord(spec);
    final results = <PurgeFileResult>[];
    for (final h in scan.containing) {
      final path = h.path;
      try {
        await Isolate.run(() => _purgeFile(path, spec));
        results.add(PurgeFileResult(path, rewritten: true));
      } catch (e) {
        results.add(PurgeFileResult(path, rewritten: false, error: e is BusinessException ? e.message : '$e'));
      }
    }
    // Check again from scratch: success is what the files say now.
    final after = await findRecord(spec);
    final still = {for (final h in after.containing) h.path};
    final finalResults = [
      for (final r in results)
        if (still.contains(r.path) && r.error == null) PurgeFileResult(r.path, rewritten: false, error: 'Still contains the record after rewriting.') else r,
    ];
    final uow = ctx.uow();
    ctx.audit(uow, 'backup_purge', spec.kind, spec.ids.first,
        '${finalResults.where((r) => r.rewritten).length} backup file(s) rewritten, ${after.checkedClean} checked without it, ${after.unreadable.length} unreadable, ${finalResults.where((r) => r.error != null).length} failed');
    await uow.commit();
    return PurgeReport(after.folders, finalResults, after.checkedClean, after.unreadable);
  }

  static const _tombstoneKey = 'purgedRecords';

  List<PurgeSpec> tombstones() {
    final v = ctx.store.read(Boxes.meta, _tombstoneKey)?['value'];
    if (v is! List) return const [];
    return [for (final e in v) PurgeSpec.fromJson(Map<String, dynamic>.from(e as Map))];
  }

  Future<void> _addTombstone(PurgeSpec spec) async {
    final list = [for (final t in tombstones()) t.toJson(), spec.toJson()];
    await ctx.store.commit([WriteOp(Boxes.meta, _tombstoneKey, {'value': list})]);
  }

  // ── Restoring ───────────────────────────────────────────────────────

  /// Reads and fully checks a backup file (zip structure, checksums, record
  /// counts, every image). Throws [BusinessException] if anything is wrong.
  /// Runs on a background isolate.
  Future<(BackupManifest, Map<String, Map<String, Json>>)> validate(String path) async {
    final (m, data, _) = await _validateInBackground(path);
    return (m, data);
  }

  /// Checks a backup and describes it for the owner before restoring.
  Future<BackupPreview> inspect(String path) async {
    final (m, _, files) = await Isolate.run(() => _checkBackup(path, withData: false));
    final latest = lastBackupAt;
    final older = latest != null && m.createdAt.isBefore(latest.subtract(const Duration(minutes: 1)));
    return BackupPreview(path, m, files, olderThanLatest: older, latestBackupAt: latest);
  }

  /// Restores a backup: check it completely → safety backup of the current
  /// data → unpack its images to a staging folder → replace all records in
  /// one atomic commit → move the images into place → verify.
  /// If anything fails before the commit the current data is untouched.
  Future<RestoreResult> restore(String path) async {
    ctx.require(Permission.backupRestore);
    final (manifest, data, files) = await _validateInBackground(path);
    final keepStatus = {
      for (final k in const ['lastBackup', 'lastAutoBackup', 'lastBackupFile', 'lastBackupError', 'lastBackupErrorAt', 'lastBackupAttempt', 'lastExternalBackupError', _tombstoneKey])
        if (ctx.store.read(Boxes.meta, k) != null) k: ctx.store.read(Boxes.meta, k)!,
    };
    final safety = await backupTo(localBackupDir, label: 'before_restore');
    final staging = Directory(p.join(mediaDir, '.restore_${DateTime.now().microsecondsSinceEpoch}'));
    late final Map<String, String> moved; // staged path -> final path
    try {
      final st = staging.path;
      final staged = await Isolate.run(() => _extractFiles(path, files, st));
      final pathMap = <String, String>{}; // original path -> new path
      moved = {};
      for (final f in files) {
        final rel = f.zipPath.substring('files/'.length);
        final finalPath = rel.startsWith('media/')
            ? p.joinAll([mediaDir, ...rel.substring('media/'.length).split('/')])
            : p.joinAll([mediaDir, 'restored', ...rel.substring('external/'.length).split('/')]);
        moved[staged[f.zipPath]!] = finalPath;
        if (f.original.isNotEmpty) pathMap[f.original] = finalPath;
      }
      final migrated = Migrator.migrateData(data, manifest.schemaVersion);
      // Records purged from backups never come back, whichever copy is used.
      for (final t in tombstones()) {
        t.applyTo(migrated);
      }
      _remapPaths(migrated, pathMap);
      await Migrator.replaceAll(ctx.store, migrated);
      // Data is restored; now the images.
      for (final e in moved.entries) {
        final dest = File(e.value);
        await dest.parent.create(recursive: true);
        await File(e.key).copy(dest.path);
      }
      await ctx.store.commit([for (final e in keepStatus.entries) WriteOp(Boxes.meta, e.key, e.value)]);
      for (final box in Boxes.all) {
        if (box == Boxes.errorLog) continue;
        final expected = migrated[box]?.length ?? 0;
        if (box == Boxes.meta) continue; // backup status kept from before
        if (ctx.store.count(box) != expected) {
          throw BusinessException('Restore verification failed for "$box". Your previous data is saved in ${safety.path}.');
        }
      }
      for (final dest in moved.values) {
        if (!File(dest).existsSync()) throw BusinessException('Restore verification failed: image "$dest" is missing.');
      }
      await ctx.store.commit([WriteOp(Boxes.meta, 'lastRestore', {'value': '${ctx.now().toIso8601String()} from ${p.basename(path)}'})]);
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
    }
    ctx.clearCache();
    ctx.session.end(); // the app re-opens the restored data
    return RestoreResult(safety, manifest.totalRecords, moved.length);
  }

  /// Points image references at the restored copies on this computer.
  static void _remapPaths(Map<String, Map<String, Json>> data, Map<String, String> pathMap) {
    if (pathMap.isEmpty) return;
    for (final rec in (data[Boxes.products] ?? const <String, Json>{}).values) {
      final v = rec['imagePath'];
      if (v is String && pathMap.containsKey(v)) rec['imagePath'] = pathMap[v];
    }
    final app = data[Boxes.settings]?['app'];
    if (app != null) {
      final v = app['logoPath'];
      if (v is String && pathMap.containsKey(v)) app['logoPath'] = pathMap[v];
    }
  }
}

// ── Background isolate work (top-level: closures must not capture state) ──

Future<List<int>> _zipInBackground(Uint8List dataBytes, Map<String, int> counts, String label, DateTime createdAt, List<String> files, String mediaDir) =>
    Isolate.run(() => _zipBackup(dataBytes, counts, label, createdAt, files, mediaDir));

Future<(BackupManifest, Map<String, Map<String, Json>>, List<BackupFileEntry>)> _validateInBackground(String path) => Isolate.run(() => _checkBackup(path));

Future<BackupManifest> _manifestInBackground(String path, {bool full = false}) =>
    Isolate.run(() => full ? _checkBackup(path, withData: false).$1 : _readManifest(path));

List<int> _zipBackup(Uint8List dataBytes, Map<String, int> counts, String label, DateTime createdAt, List<String> files, String mediaDir) {
  final archive = Archive();
  final entries = <BackupFileEntry>[];
  final missing = <String>[];
  var total = 0;
  var ext = 0;
  for (final path in files) {
    final f = File(path);
    if (!f.existsSync()) {
      missing.add(path);
      continue;
    }
    final bytes = f.readAsBytesSync();
    final inMedia = p.isWithin(mediaDir, path);
    final rel = inMedia ? 'media/${p.split(p.relative(path, from: mediaDir)).join('/')}' : 'external/${ext++}_${p.basename(path)}';
    final zipPath = 'files/$rel';
    entries.add(BackupFileEntry(zipPath, path, bytes.length, sha256.convert(bytes).toString()));
    archive.addFile(ArchiveFile(zipPath, bytes.length, bytes));
    total += bytes.length;
  }
  final filesJson = utf8.encode(jsonEncode([for (final e in entries) e.toJson()]));
  final manifest = BackupManifest(
    app: _backupAppName,
    format: 2,
    schemaVersion: Migrator.currentSchema,
    appVersion: appVersion,
    createdAt: createdAt,
    sha256: sha256.convert(dataBytes).toString(),
    counts: counts,
    label: label,
    fileCount: entries.length,
    fileBytes: total,
    filesSha256: sha256.convert(filesJson).toString(),
    missingFiles: missing,
  );
  final mBytes = utf8.encode(jsonEncode(manifest.toJson()));
  archive
    ..addFile(ArchiveFile('manifest.json', mBytes.length, mBytes))
    ..addFile(ArchiveFile('data.json', dataBytes.length, dataBytes))
    ..addFile(ArchiveFile('files.json', filesJson.length, filesJson));
  return ZipEncoder().encode(archive);
}

Archive _open(String path) {
  final f = File(path);
  if (!f.existsSync()) throw const BusinessException('Backup file not found.');
  try {
    return ZipDecoder().decodeBytes(f.readAsBytesSync(), verify: true);
  } catch (_) {
    throw const BusinessException('This file is not a valid backup: it is damaged or incomplete (cannot be opened).');
  }
}

BackupManifest _manifestOf(Archive archive) {
  final mf = archive.findFile('manifest.json');
  if (mf == null) throw const BusinessException('Backup is incomplete (manifest missing).');
  final BackupManifest m;
  try {
    m = BackupManifest.fromJson(jsonDecode(utf8.decode(mf.content)) as Map<String, dynamic>);
  } catch (_) {
    throw const BusinessException('Backup is damaged (manifest cannot be read).');
  }
  if (m.app != _backupAppName && !_legacyAppNames.contains(m.app)) throw const BusinessException('This backup is not from AL-AQSA CCTV & SOLAR SYSTEM.');
  return m;
}

/// Light check for listing backup history: the zip opens and has a manifest.
BackupManifest _readManifest(String path) => _manifestOf(_open(path));

/// Full check of a backup file. With [withData] false the decoded records
/// are dropped instead of being sent back.
(BackupManifest, Map<String, Map<String, Json>>, List<BackupFileEntry>) _checkBackup(String path, {bool withData = true}) {
  final archive = _open(path);
  final manifest = _manifestOf(archive);
  final df = archive.findFile('data.json');
  if (df == null) throw const BusinessException('Backup is incomplete (data missing).');
  final List<int> dataBytes;
  try {
    dataBytes = df.content;
  } catch (_) {
    throw const BusinessException('Backup integrity check failed: the file is damaged.');
  }
  if (sha256.convert(dataBytes).toString() != manifest.sha256) {
    throw const BusinessException('Backup integrity check failed: the file is damaged.');
  }
  if (manifest.schemaVersion > Migrator.currentSchema) {
    throw const BusinessException('This backup was made by a newer version of the app. Please update first.');
  }
  final raw = jsonDecode(utf8.decode(dataBytes)) as Map<String, dynamic>;
  final data = raw.map((box, recs) => MapEntry(box, (recs as Map).map((k, v) => MapEntry(k.toString(), Map<String, dynamic>.from(v as Map)))));
  for (final e in manifest.counts.entries) {
    if ((data[e.key]?.length ?? 0) != e.value) throw const BusinessException('Backup record count mismatch: the file is incomplete.');
  }
  if ((data[Boxes.users]?.length ?? 0) == 0) throw const BusinessException('Backup contains no user accounts.');
  var files = <BackupFileEntry>[];
  if (manifest.format >= 2) {
    final ff = archive.findFile('files.json');
    if (ff == null) throw const BusinessException('Backup is incomplete (file list missing).');
    final fb = ff.content;
    if (sha256.convert(fb).toString() != manifest.filesSha256) throw const BusinessException('Backup integrity check failed: the file list is damaged.');
    files = [for (final e in jsonDecode(utf8.decode(fb)) as List) BackupFileEntry.fromJson(Map<String, dynamic>.from(e as Map))];
    if (files.length != manifest.fileCount) throw const BusinessException('Backup is incomplete (images missing).');
    for (final e in files) {
      if (!e.zipPath.startsWith('files/media/') && !e.zipPath.startsWith('files/external/')) throw const BusinessException('Backup contains an unexpected file.');
      if (e.zipPath.split('/').contains('..')) throw const BusinessException('Backup contains an unsafe file path.');
      final af = archive.findFile(e.zipPath);
      if (af == null) throw BusinessException('Backup is incomplete: "${e.zipPath}" is missing.');
      final List<int> b;
      try {
        b = af.content;
      } catch (_) {
        throw BusinessException('Backup is damaged: "${e.zipPath}" cannot be read.');
      }
      if (b.length != e.size || sha256.convert(b).toString() != e.sha256) throw BusinessException('Backup is damaged: "${e.zipPath}" does not match its checksum.');
    }
  }
  return (manifest, withData ? data : const <String, Map<String, Json>>{}, files);
}

/// Unpacks the backup's files into [stagingDir] (checked again) and returns
/// zip path -> staged path.
Map<String, String> _extractFiles(String path, List<BackupFileEntry> files, String stagingDir) {
  if (files.isEmpty) return const {};
  final archive = _open(path);
  final out = <String, String>{};
  var i = 0;
  for (final e in files) {
    final b = archive.findFile(e.zipPath)!.content;
    if (sha256.convert(b).toString() != e.sha256) throw BusinessException('Backup is damaged: "${e.zipPath}".');
    final dest = File(p.join(stagingDir, '${i++}_${p.basename(e.zipPath)}'));
    dest.parent.createSync(recursive: true);
    dest.writeAsBytesSync(b, flush: true);
    out[e.zipPath] = dest.path;
  }
  return out;
}

/// Rewrites one backup without [spec] (see [BackupService.purgeRecord]).
/// The original is replaced only after the new file passed the full check.
void _purgeFile(String path, PurgeSpec spec) {
  final archive = _open(path);
  final m = _manifestOf(archive);
  final (_, data, files) = _checkBackup(path);
  if (!spec.presentIn(data)) return;
  spec.applyTo(data);
  // Drop files only the purged record used (no remaining record mentions them).
  final dataText = jsonEncode(data);
  final keep = [
    for (final f in files)
      if (!(spec.files.contains(f.original) && !dataText.contains(jsonEncode(f.original)))) f,
  ];
  final dataBytes = Uint8List.fromList(utf8.encode(dataText));
  final out = Archive();
  var total = 0;
  for (final f in keep) {
    final b = archive.findFile(f.zipPath)!.content;
    out.addFile(ArchiveFile(f.zipPath, b.length, b));
    total += b.length;
  }
  final filesJson = utf8.encode(jsonEncode([for (final e in keep) e.toJson()]));
  final manifest = BackupManifest(
    app: m.app,
    format: m.format < 2 ? 2 : m.format,
    schemaVersion: m.schemaVersion,
    appVersion: m.appVersion,
    createdAt: m.createdAt,
    sha256: sha256.convert(dataBytes).toString(),
    counts: {for (final e in data.entries) e.key: e.value.length},
    label: m.label,
    fileCount: keep.length,
    fileBytes: total,
    filesSha256: sha256.convert(filesJson).toString(),
    missingFiles: m.missingFiles,
  );
  final mBytes = utf8.encode(jsonEncode(manifest.toJson()));
  out
    ..addFile(ArchiveFile('manifest.json', mBytes.length, mBytes))
    ..addFile(ArchiveFile('data.json', dataBytes.length, dataBytes))
    ..addFile(ArchiveFile('files.json', filesJson.length, filesJson));
  final tmp = File('$path.purge.tmp');
  final old = File('$path.purge.old');
  try {
    tmp.writeAsBytesSync(ZipEncoder().encode(out), flush: true);
    final (_, check, _) = _checkBackup(tmp.path); // full integrity check of the new file
    if (spec.presentIn(check)) throw const BusinessException('The rewritten backup still contains the record.');
    File(path).renameSync(old.path);
    tmp.renameSync(path);
    old.deleteSync();
  } catch (e) {
    if (tmp.existsSync()) tmp.deleteSync();
    if (old.existsSync() && !File(path).existsSync()) old.renameSync(path); // put the original back
    rethrow;
  }
}
