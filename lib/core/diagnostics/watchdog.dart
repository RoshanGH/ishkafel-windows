import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../log/app_log.dart';
import 'report_redactor.dart';

/// 独立进程持续落盘采样；不依赖可能无响应的 Explorer COM。
/// 外部若终止整个 Windows job，末次退出码仍可能来不及写入。
Future<void> startDiagnosticWatchdog(Directory logs, {File? script}) async {
  if (!Platform.isWindows) return;
  script ??= File(
    p.join(p.dirname(Platform.resolvedExecutable), 'diagnostic_watchdog.ps1'),
  );
  if (!await script.exists()) {
    AppLog.warn('独立诊断监测未启动：缺少监测脚本。');
    return;
  }
  final started = DateTime.now().toUtc();
  Process? child;
  final errorBytes = <int>[];
  int? exitCode;
  String failureDetails() {
    final error = ReportRedactor(const [])
        .clean(utf8.decode(errorBytes, allowMalformed: true))
        .replaceAll(RegExp(r'[\r\n]+'), ' ')
        .trim();
    return 'exit=${exitCode ?? 'running'}'
        '${error.isEmpty ? '' : '；stderr=$error'}';
  }

  try {
    final powershell = p.join(
      Platform.environment['SystemRoot'] ?? r'C:\Windows',
      'System32',
      'WindowsPowerShell',
      'v1.0',
      'powershell.exe',
    );
    child = await Process.start(powershell, [
      '-NoProfile',
      '-NonInteractive',
      '-WindowStyle',
      'Hidden',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      script.absolute.path,
      '-AppPid',
      '$pid',
      '-LogDirectory',
      logs.absolute.path,
    ]);
    // 异步排空输出，避免管道写满阻塞采样；这里不等待监测进程退出。
    child.stdout.drain<void>();
    final errorsDrained = child.stderr.forEach((bytes) {
      // 只保留首段诊断，但始终排空管道，避免异常输出撑满内存或阻塞子进程。
      if (errorBytes.length < 4096) {
        errorBytes.addAll(bytes.take(4096 - errorBytes.length));
      }
    });
    child.exitCode.then((code) => exitCode = code);
    await child.stdin.close();
    final report = File(p.join(logs.path, 'watchdog.json'));
    final wait = Stopwatch()..start();
    while (wait.elapsed < const Duration(seconds: 8)) {
      if (exitCode != null) {
        await errorsDrained;
        AppLog.warn('独立诊断监测未启动：进程提前退出；${failureDetails()}；仍可手动提交日志。');
        return;
      }
      try {
        final samples = jsonDecode(await report.readAsString());
        final last = samples is List && samples.isNotEmpty
            ? samples.last
            : null;
        final timestamp = last is Map && last['utc'] is String
            ? DateTime.tryParse(last['utc'] as String)
            : null;
        if (last is Map &&
            last['pid'] == pid &&
            timestamp != null &&
            !timestamp.isBefore(started)) {
          AppLog.info('独立诊断监测已启动并确认采样。');
          return;
        }
      } on FileSystemException {
        // 首次写入前文件尚不存在。
      } on FormatException {
        // 写入期间可能读到不完整 JSON，等待下一次读取。
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    child.kill();
    AppLog.warn('独立诊断监测未启动：未收到采样确认；${failureDetails()}；仍可手动提交日志。');
  } catch (error) {
    child?.kill();
    AppLog.warn('独立诊断监测未启动：${error.runtimeType}；仍可手动提交日志。');
  }
}
