import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'data/app_paths.dart';
import 'data/windows_backup_task.dart';
import 'data/migrations.dart';
import 'data/store/hive_store.dart';
import 'domain/services/app_services.dart';
import 'domain/services/backup_service.dart';
import 'ui/providers.dart';
import 'ui/shell/app_shell.dart';
import 'ui/splash/splash_screen.dart';
import 'ui/theme.dart';

/// Held for the whole process lifetime; the OS releases it on exit.
SingleInstanceLock? _instanceLock;

/// Backup folder used until the owner chooses another one.
String? _defaultBackupDir() {
  if (Platform.isWindows) return defaultWindowsBackupDir;
  final home = Platform.environment['HOME'];
  return home == null ? null : '$home/AL-AQSA_Backups';
}

Future<void> main(List<String> args) async {
  if (args.contains(WindowsBackupTask.argument)) {
    // Started by the Windows scheduled task: no window, back up if due, exit.
    await _backgroundBackup();
    return;
  }
  AppServices? services;

  await runZonedGuarded(() async {
    bootClock.start();
    WidgetsFlutterBinding.ensureInitialized();
    final AppPaths paths;
    final HiveStore store;
    try {
      final support = await getApplicationSupportDirectory();
      paths = AppPaths.resolve(env: Platform.environment, isWindows: Platform.isWindows, fallback: support.path);
      await paths.ensure();
      _instanceLock = await SingleInstanceLock.acquire(paths.lockFile);
      if (_instanceLock == null) {
        runApp(const StartupErrorApp(
            title: '$appDisplayName is already open',
            message: 'Another window of the application is already running on this computer.\nClose this window and use the one that is already open.'));
        return;
      }
      // The window shows the splash immediately; the database (seconds for a
      // large shop) opens behind it.
      store = await HiveStore.open(paths.data, onSettings: (st) => runApp(BootSplashApp(dark: st?['theme'] != 'light')));
      await Migrator.run(store);
    } catch (e) {
      runApp(StartupErrorApp(title: 'Could not open the database', message: 'The application could not start.\n\n$e\n\nRestore the latest backup or contact support.'));
      return;
    }

    final app = AppServices(store, localBackupDir: paths.backups, mediaDir: paths.media, defaultBackupDir: _defaultBackupDir());
    services = app;
    await app.settings.applyOfficialName();
    if (store.recoveredTransactions > 0) {
      await app.ctx.logError('Recovered ${store.recoveredTransactions} interrupted transaction(s) on startup', null);
    }

    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      app.ctx.logError(details.exception, details.stack);
    };

    // Daily automatic backup: checked at start-up (catches up a missed
    // backup), every minute while the app is open, and by the Windows
    // scheduled task when the app is closed.
    Future<void> autoBackup() async {
      try {
        await app.backup.runAutoBackupIfDue();
      } catch (e) {
        await app.ctx.logError(e, null);
      }
    }
    var running = false;
    Future<void> tick() async {
      if (running) return;
      running = true;
      try {
        await autoBackup();
      } finally {
        running = false;
      }
    }

    unawaited(Future<void>.delayed(const Duration(seconds: 20), tick));
    Timer.periodic(const Duration(minutes: 1), (_) => tick());
    final st0 = app.ctx.settings;
    unawaited(WindowsBackupTask.sync(enabled: st0.autoBackup, hour: st0.backupHour, minute: st0.backupMinute).then((err) async {
      if (err != null && Platform.isWindows) await app.ctx.logError('Backup task: $err', null);
    }));

    runApp(ProviderScope(
      overrides: [
        servicesProvider.overrideWithValue(app),
        themeModeProvider.overrideWith((ref) => app.ctx.settings.theme != 'light'),
      ],
      child: const AlAqsaApp(),
    ));
  }, (error, stack) {
    services?.ctx.logError(error, stack);
  });
}

class AlAqsaApp extends ConsumerWidget {
  const AlAqsaApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = ref.watch(themeModeProvider);
    return MaterialApp(
      title: appDisplayName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build(AppColors.lightPalette),
      darkTheme: AppTheme.build(AppColors.darkPalette),
      themeMode: dark ? ThemeMode.dark : ThemeMode.light,
      home: const Root(),
    );
  }
}

/// `--backup-now`: open the data, run the automatic backup if it is due and
/// exit. If the app is already open it does the backup itself, so this run
/// just ends.
Future<void> _backgroundBackup() async {
  var code = 0;
  try {
    WidgetsFlutterBinding.ensureInitialized();
    final support = await getApplicationSupportDirectory();
    final paths = AppPaths.resolve(env: Platform.environment, isWindows: Platform.isWindows, fallback: support.path);
    await paths.ensure();
    final lock = await SingleInstanceLock.acquire(paths.lockFile);
    if (lock != null) {
      final store = await HiveStore.open(paths.data);
      try {
        await Migrator.run(store);
        final app = AppServices(store, localBackupDir: paths.backups, mediaDir: paths.media, defaultBackupDir: _defaultBackupDir());
        await app.auth.openLocalSession();
        final r = await app.backup.runAutoBackupIfDue();
        if (r != null && !r.ok) code = 2;
      } finally {
        await store.close();
        await lock.release();
      }
    }
  } catch (_) {
    code = 1;
  }
  exit(code);
}

/// Shown instead of a blank window when the app cannot start.
class StartupErrorApp extends StatelessWidget {
  final String title;
  final String message;
  const StartupErrorApp({super.key, required this.title, required this.message});

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.build(AppColors.darkPalette),
        home: Scaffold(
          body: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Container(
              width: 560,
              padding: const EdgeInsets.all(32),
              decoration: BoxDecoration(color: AppColors.darkPalette.surface, borderRadius: BorderRadius.circular(18), border: Border.all(color: AppColors.darkPalette.border)),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.error_outline, size: 56, color: AppColors.darkPalette.warning),
                const SizedBox(height: 14),
                Text(title, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.darkPalette.text)),
                const SizedBox(height: 10),
                SelectableText(message, textAlign: TextAlign.center, style: TextStyle(color: AppColors.darkPalette.textMuted)),
              ]),
            ),
            ),
          ),
        ),
      );
}
