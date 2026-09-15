import 'dart:io';

import 'package:path/path.dart' as p;

/// 命令行工具当前的状态。
///
/// 分这么细是因为**每一种的下一步动作都不一样**：没带要说清这个版本没有、
/// 没装给安装按钮、装坏了要重装、别人家的同名命令绝对不能覆盖。
/// 全都揉成一个「未安装」，用户点了按钮没反应还不知道为什么。
enum CliStatus {
  /// 这个版本的包里根本没带 CLI（调试运行的产物就没有）
  unavailable,

  /// 带了，还没装进 PATH
  notInstalled,

  /// 装好了，指向的也在
  installed,

  /// 装过，但指向的文件没了——app 被挪了位置或删了
  stale,

  /// PATH 里已经有个同名命令，但不是我们装的。不许碰
  foreign,
}

class CliInstallResult {
  final bool ok;
  final String message;

  /// 目标目录写不进去，得用管理员权限再来一次
  final bool needsAdmin;

  const CliInstallResult({
    required this.ok,
    required this.message,
    this.needsAdmin = false,
  });
}

/// 把 app 里带的命令行工具装进 PATH。
///
/// **为什么写包装脚本而不是软链**：bundle 里的可执行文件靠相对路径找
/// `lib/objective_c.dylib`，软链过去它就找不着了。
///
/// **为什么带指纹注释**：装之前要能分辨「这是我们装的」还是「用户自己放了个
/// 同名命令」。分不出来就只有两个选择——不敢动（那就永远装不上）或者直接覆盖
/// （那就把别人的东西吃了）。两个都不行。
class CliInstaller {
  /// 装到哪儿。macOS 默认 PATH 里就有 /usr/local/bin
  final Directory binDir;

  /// app 里带的那份
  final File bundledCli;

  /// Windows 正式包使用用户目录，不需要提权；安装时把该目录登记到用户 PATH。
  final bool manageUserPath;

  static const _marker = '# ishkafel-cli-shim';
  static const commandName = 'ishkafel';

  const CliInstaller({
    required this.binDir,
    required this.bundledCli,
    this.manageUserPath = false,
  });

  /// 跑在 app 里时的默认装法：CLI 在 `<app>/Contents/Resources/cli/ishkafel`。
  ///
  /// 那是个**按机器架构分发**的入口脚本，两个架构的 bundle 都在它旁边——
  /// Dart 不支持交叉编译，两份产物也没法 lipo 成一个（AOT 快照是附加在
  /// Mach-O 后面的，lipo 只认前面那段，合完快照就丢了）
  factory CliInstaller.forRunningApp({Directory? binDir}) {
    if (Platform.isWindows) {
      final executableDir = File(Platform.resolvedExecutable).parent;
      final localAppData = Platform.environment['LOCALAPPDATA'];
      final defaultBin = localAppData == null || localAppData.isEmpty
          ? Directory(p.join(executableDir.path, 'user-cli'))
          : Directory(p.join(localAppData, 'Ishkafel', 'bin'));
      return CliInstaller(
        binDir: binDir ?? defaultBin,
        bundledCli: File(
          p.join(executableDir.path, 'cli', 'bin', 'ishkafel.exe'),
        ),
        manageUserPath: binDir == null,
      );
    }
    final macos = File(Platform.resolvedExecutable).parent; // Contents/MacOS
    final contents = macos.parent;
    return CliInstaller(
      binDir: binDir ?? Directory('/usr/local/bin'),
      bundledCli: File(p.join(contents.path, 'Resources', 'cli', commandName)),
    );
  }

  File get _shim => File(
    p.join(binDir.path, Platform.isWindows ? '$commandName.cmd' : commandName),
  );

  CliStatus inspect() {
    if (!bundledCli.existsSync()) return CliStatus.unavailable;
    if (!_shim.existsSync()) return CliStatus.notInstalled;

    final String body;
    try {
      body = _shim.readAsStringSync();
    } catch (_) {
      // 读不出来就当是别人的，不去动它
      return CliStatus.foreign;
    }
    if (!body.contains(_marker)) return CliStatus.foreign;

    // 指纹对得上，再看它指的那个东西还在不在
    final target = _targetOf(body);
    if (target == null || !File(target).existsSync()) return CliStatus.stale;
    return CliStatus.installed;
  }

  Future<CliInstallResult> install() async {
    if (!bundledCli.existsSync()) {
      return const CliInstallResult(
        ok: false,
        message: '这个版本没有带命令行工具（调试运行的产物就没有），请用正式打包的版本',
      );
    }
    if (inspect() == CliStatus.foreign) {
      return CliInstallResult(
        ok: false,
        message:
            '${_shim.path} 已经有一个同名命令，但不是本应用装的。'
            '为免覆盖别人的东西，这里不动它——确认可以覆盖就手动删掉再来',
      );
    }

    try {
      if (!binDir.existsSync()) binDir.createSync(recursive: true);
      _shim.writeAsStringSync(_shimBody());
      // 只有可读没有可执行位，敲进去是「permission denied」，用户完全看不懂
      if (!Platform.isWindows) {
        final chmod = await Process.run('chmod', ['755', _shim.path]);
        if (chmod.exitCode != 0) {
          return CliInstallResult(
            ok: false,
            message: '装上了但没能给可执行权限：${chmod.stderr}',
          );
        }
      } else if (manageUserPath) {
        final pathResult = await _ensureWindowsUserPath();
        if (pathResult != null) return pathResult;
      }
    } on FileSystemException catch (e) {
      if (_isPermission(e)) {
        return CliInstallResult(
          ok: false,
          needsAdmin: true,
          message: '${binDir.path} 需要管理员权限才能写入',
        );
      }
      return CliInstallResult(ok: false, message: '装不进去：${e.message}');
    }

    return CliInstallResult(
      ok: true,
      message: '装好了。终端里执行 $commandName --help 看用法',
    );
  }

  /// 用管理员权限再装一次。会弹系统的授权框
  Future<CliInstallResult> installWithAdmin() async {
    // Windows 默认写入 %LOCALAPPDATA% 并登记 HKCU PATH，不需要管理员权限。
    if (Platform.isWindows) return install();
    if (!bundledCli.existsSync()) {
      return const CliInstallResult(
        ok: false,
        message: '这个版本没有带命令行工具，请用正式打包的版本',
      );
    }
    // 脚本内容里有换行和引号，走临时文件再 mv，比拼一条长命令稳
    final staged = File(
      p.join(
        Directory.systemTemp.path,
        'ishkafel-shim-${pid.toRadixString(36)}',
      ),
    );
    staged.writeAsStringSync(_shimBody());

    final script =
        'mkdir -p ${_q(binDir.path)} && '
        'cp ${_q(staged.path)} ${_q(_shim.path)} && '
        'chmod 755 ${_q(_shim.path)}';
    // 这条 shell 命令还要再穿一层 AppleScript 的双引号字符串，路径里的
    // 反斜杠和双引号必须在这一层再转一次，否则授权框里跑的是条断掉的命令
    final inAppleScript = script.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
    final result = await Process.run('osascript', [
      '-e',
      'do shell script "$inAppleScript" with administrator privileges',
    ]);
    try {
      staged.deleteSync();
    } catch (_) {}

    if (result.exitCode != 0) {
      final err = '${result.stderr}';
      // 用户点了取消不是错误，是他的选择——别当失败报给他
      if (err.contains('-128')) {
        return const CliInstallResult(ok: false, message: '已取消');
      }
      return CliInstallResult(ok: false, message: '装不进去：${err.trim()}');
    }
    return CliInstallResult(
      ok: true,
      message: '装好了。终端里执行 $commandName --help 看用法',
    );
  }

  /// 只删自己装的。返回 false 表示没删（不存在，或者不是我们装的）
  Future<bool> uninstall() async {
    if (!_shim.existsSync()) return false;
    try {
      if (!_shim.readAsStringSync().contains(_marker)) return false;
      _shim.deleteSync();
      return true;
    } catch (_) {
      return false;
    }
  }

  String _shimBody() {
    if (Platform.isWindows) {
      return '@echo off\r\n'
          'rem $_marker\r\n'
          'chcp 65001 >nul\r\n'
          '"${bundledCli.path}" %*\r\n';
    }
    return '#!/bin/sh\n'
        '$_marker\n'
        '# 由 ishkafel.app 写入。删掉这个文件就等于卸载。\n'
        'exec ${_q(bundledCli.path)} "\$@"\n';
  }

  String? _targetOf(String body) {
    if (Platform.isWindows) {
      return RegExp(
        r'^"([^"]+)" %\*$',
        multiLine: true,
      ).firstMatch(body)?.group(1);
    }
    final match = RegExp(r"^exec '(.+)' ", multiLine: true).firstMatch(body);
    return match?.group(1)?.replaceAll(r"'\''", "'");
  }

  /// 把默认 shim 目录写入当前用户的 PATH。使用 HKCU 避免管理员权限，也不走
  /// `setx`（旧版本会截断过长 PATH）。返回 null 表示成功。
  Future<CliInstallResult?> _ensureWindowsUserPath() async {
    final query = await Process.run(
      'reg.exe',
      [r'query', r'HKCU\Environment', '/v', 'Path'],
      stdoutEncoding: systemEncoding,
      stderrEncoding: systemEncoding,
    );
    var current = '';
    if (query.exitCode == 0) {
      final matchingLines = '${query.stdout}'
          .split(RegExp(r'\r?\n'))
          .where((value) => value.contains('REG_'))
          .toList();
      final line = matchingLines.isEmpty ? null : matchingLines.first;
      if (line != null) {
        current = line
            .replaceFirst(RegExp(r'^\s*Path\s+REG_\w+\s+'), '')
            .trim();
      }
    }
    final entries = current
        .split(';')
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList();
    final alreadyPresent = entries.any(
      (value) => p.equals(p.normalize(value), p.normalize(binDir.path)),
    );
    if (alreadyPresent) return null;
    final updated = [...entries, binDir.path].join(';');
    final add = await Process.run(
      'reg.exe',
      [
        'add',
        r'HKCU\Environment',
        '/v',
        'Path',
        '/t',
        'REG_EXPAND_SZ',
        '/d',
        updated,
        '/f',
      ],
      stdoutEncoding: systemEncoding,
      stderrEncoding: systemEncoding,
    );
    if (add.exitCode == 0) return null;
    return CliInstallResult(
      ok: false,
      message: '命令文件已写入，但没能登记用户 PATH：${add.stderr}'.trim(),
    );
  }

  static bool _isPermission(FileSystemException e) =>
      e.osError?.errorCode == 13 || e.osError?.errorCode == 1;

  /// 单引号包起来，里面的单引号按 shell 的规矩转义
  static String _q(String path) => "'${path.replaceAll("'", r"'\''")}'";
}
