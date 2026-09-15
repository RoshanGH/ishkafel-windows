import 'dart:io';

typedef SyncProcessRunner =
    ProcessResult Function(String executable, List<String> arguments);
typedef AsyncProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

/// 与系统 shell 交互的唯一入口；业务代码不再硬编码 which、tasklist 或 PATH 分隔符。
class PlatformShell {
  final String operatingSystem;
  final SyncProcessRunner runSync;
  final AsyncProcessRunner run;

  PlatformShell({
    String? operatingSystem,
    SyncProcessRunner? runSync,
    AsyncProcessRunner? run,
  })
    : operatingSystem = operatingSystem ?? Platform.operatingSystem,
      runSync = runSync ?? _systemRunSync,
      run = run ?? Process.run;

  String get pathSeparator => operatingSystem == 'windows' ? ';' : ':';

  String get revealLabel => operatingSystem == 'windows'
      ? '在文件资源管理器中显示'
      : '在访达中显示';

  /// 用系统文件管理器打开一个目录。参数直接交给进程 API，不经过 shell，
  /// 所以中文、空格和 `&` 都不会被二次解释。
  Future<void> openPath(String path) => operatingSystem == 'windows'
      ? _runChecked('explorer.exe', [path])
      : _runChecked('open', [path]);

  /// 在系统文件管理器里选中一个文件或目录。
  Future<void> revealPath(String path) => operatingSystem == 'windows'
      ? _runChecked('explorer.exe', ['/select,', path])
      : _runChecked('open', ['-R', path]);

  Future<void> _runChecked(String executable, List<String> arguments) async {
    final result = await run(executable, arguments);
    if (result.exitCode == 0) return;
    final detail = '${result.stderr}'.trim();
    throw StateError(
      detail.isEmpty
          ? '$executable failed with exit code ${result.exitCode}'
          : detail,
    );
  }

  List<String> executableNames(String name) {
    if (operatingSystem != 'windows' || _hasWindowsExecutableExtension(name)) {
      return [name];
    }
    return ['$name.exe', '$name.cmd', '$name.bat', name];
  }

  String? lookupOnPath(String executableName) {
    try {
      final command = operatingSystem == 'windows'
          ? 'where.exe'
          : '/usr/bin/which';
      final result = runSync(command, [executableName]);
      if (result.exitCode != 0) return null;
      final lines = '${result.stdout}'
          .split(RegExp(r'[\r\n]+'))
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty);
      return lines.firstOrNull;
    } catch (_) {
      return null;
    }
  }

  bool isProcessAlive(int pid) {
    if (pid <= 0) return true;
    try {
      if (operatingSystem != 'windows') {
        return runSync('ps', ['-p', '$pid']).exitCode == 0;
      }
      final result = runSync('tasklist.exe', [
        '/FI',
        'PID eq $pid',
        '/FO',
        'CSV',
        '/NH',
      ]);
      if (result.exitCode != 0) return true;
      final pidPattern = RegExp('^[^,]+,"?$pid"?(?:,|\u0024)', multiLine: true);
      return pidPattern.hasMatch('${result.stdout}'.trim());
    } catch (_) {
      // 系统查询失败时走保守方向：不抢占一把可能仍有效的锁。
      return true;
    }
  }

  static bool _hasWindowsExecutableExtension(String name) =>
      RegExp(r'\.(exe|cmd|bat)$', caseSensitive: false).hasMatch(name);

  static ProcessResult _systemRunSync(
    String executable,
    List<String> arguments,
  ) => Process.runSync(executable, arguments);
}
