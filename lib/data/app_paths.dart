import 'dart:io';

import 'package:path/path.dart' as p;

/// Folder name used under %APPDATA% on Windows. Never change this in a
/// future version, or upgrades will not find the existing shop data.
const appFolderName = 'AL AQSA CCTV';

class AppPaths {
  final String root;
  const AppPaths(this.root);
  String get data => p.join(root, 'data');
  String get backups => p.join(root, 'backups');
  String get media => p.join(root, 'media');
  String get lockFile => p.join(root, 'app.lock');

  /// Windows: %APPDATA%\AL AQSA CCTV (fixed, independent of the exe's
  /// version info). Other platforms: the platform's application-support
  /// folder supplied by [fallback]. `AQSA_DATA_DIR` overrides both (useful
  /// for a portable install or for testing).
  static AppPaths resolve({required Map<String, String> env, required bool isWindows, required String fallback}) {
    final override = env['AQSA_DATA_DIR'];
    if (override != null && override.trim().isNotEmpty) return AppPaths(override.trim());
    if (isWindows) {
      final appData = env['APPDATA'];
      if (appData != null && appData.isNotEmpty) return AppPaths(p.join(appData, appFolderName));
    }
    return AppPaths(fallback);
  }

  Future<void> ensure() async {
    await Directory(data).create(recursive: true);
    await Directory(backups).create(recursive: true);
    await Directory(media).create(recursive: true);
  }
}

/// Prevents a second copy of the app from opening the same database
/// (two writers would corrupt Hive files).
class SingleInstanceLock {
  final RandomAccessFile _file;
  SingleInstanceLock._(this._file);

  /// Returns null if another running copy holds the lock.
  static Future<SingleInstanceLock?> acquire(String path) async {
    final f = await File(path).open(mode: FileMode.append);
    try {
      await f.lock(FileLock.exclusive);
      return SingleInstanceLock._(f);
    } on FileSystemException {
      await f.close();
      return null;
    }
  }

  Future<void> release() async {
    try {
      await _file.unlock();
    } finally {
      await _file.close();
    }
  }
}
