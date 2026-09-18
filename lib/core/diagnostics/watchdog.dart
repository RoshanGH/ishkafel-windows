import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../log/app_log.dart';

/// 通过 Windows Shell 启动，主程序退出时不会一起被父进程 job 回收。
Future<void> startDiagnosticWatchdog(Directory logs) async {
  if (!Platform.isWindows) return;
  final script = File(
    p.join(p.dirname(Platform.resolvedExecutable), 'diagnostic_watchdog.ps1'),
  );
  if (!await script.exists()) return;
  String quote(String value) => "'${value.replaceAll("'", "''")}'";
  final command =
      '& ${quote(script.path)} -AppPid $pid -LogDirectory ${quote(logs.path)}';
  final bytes = <int>[];
  for (final unit in command.codeUnits) {
    bytes.addAll([unit & 255, unit >> 8]);
  }
  final encoded = base64Encode(bytes);
  try {
    await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      "(New-Object -ComObject Shell.Application).ShellExecute('powershell.exe', '-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded', '', 'open', 0)",
    ]).timeout(const Duration(seconds: 5));
  } catch (_) {
    AppLog.warn('独立诊断监测未启动；仍可手动提交日志。');
  }
}
