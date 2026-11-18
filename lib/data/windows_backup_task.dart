import 'dart:convert';
import 'dart:io';

/// Windows Task Scheduler entry that starts the app in background mode
/// (`--backup-now`, no window) every day at the backup time. Windows runs it
/// even if the app is closed, and — because "start when available" is set —
/// as soon as possible after the computer was off or asleep at that time.
/// The app itself also checks at start-up and every minute while open, so a
/// backup is never skipped when the task cannot be registered.
class WindowsBackupTask {
  static const taskName = r'AL-AQSA CCTV & SOLAR SYSTEM\Daily Backup';
  static const argument = '--backup-now';

  /// Task definition (Task Scheduler 1.2 XML).
  static String xml({required String exePath, required int hour, required int minute, DateTime? from}) {
    final d = from ?? DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final start = '${d.year}-${two(d.month)}-${two(d.day)}T${two(hour)}:${two(minute)}:00';
    const esc = HtmlEscape(HtmlEscapeMode.element);
    return '''<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Daily automatic backup of AL-AQSA CCTV &amp; SOLAR SYSTEM data.</Description>
  </RegistrationInfo>
  <Triggers>
    <CalendarTrigger>
      <StartBoundary>$start</StartBoundary>
      <Enabled>true</Enabled>
      <ScheduleByDay>
        <DaysInterval>1</DaysInterval>
      </ScheduleByDay>
    </CalendarTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <ExecutionTimeLimit>PT2H</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>${esc.convert(exePath)}</Command>
      <Arguments>$argument</Arguments>
    </Exec>
  </Actions>
</Task>
''';
  }

  /// Creates / updates (enabled) or removes (disabled) the task. Returns
  /// null on success, otherwise the reason it could not be done.
  static Future<String?> sync({required bool enabled, required int hour, required int minute, String? exePath}) async {
    if (!Platform.isWindows) return 'Only available on Windows.';
    try {
      if (!enabled) {
        final r = await Process.run('schtasks', ['/Delete', '/TN', taskName, '/F']);
        // "not found" is fine: nothing to remove.
        return r.exitCode == 0 || '${r.stderr}'.toLowerCase().contains('cannot find') ? null : '${r.stderr}'.trim();
      }
      final exe = exePath ?? Platform.resolvedExecutable;
      final file = File('${Directory.systemTemp.path}\\aqsa_backup_task_${DateTime.now().microsecondsSinceEpoch}.xml');
      // UTF-16 LE with BOM, as Task Scheduler expects for this header.
      final body = xml(exePath: exe, hour: hour, minute: minute);
      final bytes = <int>[0xFF, 0xFE];
      for (final u in body.codeUnits) {
        bytes
          ..add(u & 0xFF)
          ..add(u >> 8);
      }
      await file.writeAsBytes(bytes, flush: true);
      try {
        final r = await Process.run('schtasks', ['/Create', '/TN', taskName, '/XML', file.path, '/F']);
        return r.exitCode == 0 ? null : '${r.stderr}${r.stdout}'.trim();
      } finally {
        if (await file.exists()) await file.delete();
      }
    } catch (e) {
      return '$e';
    }
  }

  /// True when the task exists (Windows only).
  static Future<bool> exists() async {
    if (!Platform.isWindows) return false;
    try {
      final r = await Process.run('schtasks', ['/Query', '/TN', taskName]);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }
}
