import 'dart:io';

import 'package:al_aqsa_cctv/data/app_paths.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('Windows data folder is fixed under %APPDATA%', () {
    final a = AppPaths.resolve(env: {'APPDATA': r'C:\Users\Shop\AppData\Roaming'}, isWindows: true, fallback: '/ignored');
    expect(a.root, p.join(r'C:\Users\Shop\AppData\Roaming', 'AL AQSA CCTV'));
    expect(a.data, p.join(a.root, 'data'));
    expect(a.backups, p.join(a.root, 'backups'));
  });

  test('Other platforms use the support folder; AQSA_DATA_DIR overrides', () {
    expect(AppPaths.resolve(env: {}, isWindows: false, fallback: '/support').root, '/support');
    expect(AppPaths.resolve(env: {'AQSA_DATA_DIR': ' /portable '}, isWindows: true, fallback: '/x').root, '/portable');
    expect(AppPaths.resolve(env: {}, isWindows: true, fallback: '/fb').root, '/fb');
  });

  test('Single-instance lock can be acquired and released', () async {
    final dir = await Directory.systemTemp.createTemp('aqsa_lock');
    final paths = AppPaths(dir.path);
    await paths.ensure();
    final lock = await SingleInstanceLock.acquire(paths.lockFile);
    expect(lock, isNotNull);
    await lock!.release();
    final again = await SingleInstanceLock.acquire(paths.lockFile);
    expect(again, isNotNull);
    await again!.release();
    await dir.delete(recursive: true);
  });
}
