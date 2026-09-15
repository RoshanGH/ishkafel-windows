import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../log/app_log.dart';

typedef UpdateProcessLauncher =
    Future<void> Function(
      String executable,
      List<String> arguments,
      ProcessStartMode mode,
    );

/// 下载失败/校验失败：message 面向用户（中文、说清下一步）
class UpdateException implements Exception {
  final String message;
  final Object? cause;
  const UpdateException(this.message, {this.cause});
  @override
  String toString() => message;
}

/// **把新版本装上去，然后重启。**
///
/// 这一步动的是人正在用的软件，出错的代价是「软件没了」——所以每一步都
/// 可回滚、每一步都先验证：
///
/// 1. 下载到临时目录（不碰现有 app）
/// 2. 核对 sha256——半截包解压出来是个坏 app，而人只会觉得「升级把软件搞坏了」
/// 3. 用 `ditto` 解压。**不用 unzip**：它会丢掉扩展属性，代码签名跟着失效，
///    换上去的 app 一打开就被 Gatekeeper 拦下
/// 4. 验一遍新包的签名，再动现有的 app
/// 5. 旧的先改名留着，新的就位后才删——中途失败还能把旧的搬回来
class AppUpdater {
  final Future<ProcessResult> Function(String, List<String>) run;
  final UpdateProcessLauncher launch;
  final HttpClient Function() httpClient;
  final String operatingSystem;

  AppUpdater({
    Future<ProcessResult> Function(String, List<String>)? run,
    UpdateProcessLauncher? launch,
    HttpClient Function()? httpClient,
    String? operatingSystem,
  }) : run = run ?? Process.run,
       launch = launch ?? _launchDetached,
       httpClient = httpClient ?? HttpClient.new,
       operatingSystem = operatingSystem ?? Platform.operatingSystem;

  static Future<void> _launchDetached(
    String executable,
    List<String> arguments,
    ProcessStartMode mode,
  ) async {
    await Process.start(executable, arguments, mode: mode);
  }

  /// 下载到 [into]，边下边报进度（0~1）。返回落地的文件
  Future<File> download(
    String url,
    File into, {
    void Function(int received, int total)? onProgress,
  }) async {
    final client = httpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw UpdateException(
          '下载失败（HTTP ${response.statusCode}）。链接可能已经过期，'
          '关掉重开再试一次。',
        );
      }
      final total = response.contentLength;
      into.parent.createSync(recursive: true);
      final sink = into.openWrite();
      var received = 0;
      await for (final chunk in response) {
        received += chunk.length;
        sink.add(chunk);
        onProgress?.call(received, total);
      }
      await sink.close();
      return into;
    } on UpdateException {
      rethrow;
    } catch (e) {
      throw UpdateException('下载失败：网络不通或链接失效。', cause: e);
    } finally {
      client.close(force: true);
    }
  }

  /// 核对整包指纹。**不对就必须停**——装一个损坏的包比不升级糟得多
  Future<void> verifySha256(File file, String expected) async {
    final digest = await sha256.bind(file.openRead()).first;
    final got = digest.toString();
    if (got != expected.toLowerCase()) {
      throw UpdateException(
        '下载的包校验没通过（可能没下完，或者被改过）。'
        '删掉重下一次；一直不过就联系发包的人。',
      );
    }
  }

  /// 解压出 `.app`。用 `ditto` 而不是 `unzip`：后者丢扩展属性 → 签名失效
  Future<Directory> unpack(File zip, Directory into) async {
    into.createSync(recursive: true);
    final r = operatingSystem == 'windows'
        ? await run('powershell.exe', [
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            'Expand-Archive -LiteralPath ${_psQuote(zip.path)} '
                '-DestinationPath ${_psQuote(into.path)} -Force',
          ])
        : await run('ditto', ['-x', '-k', zip.path, into.path]);
    if (r.exitCode != 0) {
      throw UpdateException('解压失败：${r.stderr}');
    }
    final candidates = into.listSync().whereType<Directory>();
    final app = operatingSystem == 'windows'
        ? candidates
              .where((d) => File(p.join(d.path, 'ishkafel.exe')).existsSync())
              .firstOrNull
        : candidates.where((d) => d.path.endsWith('.app')).firstOrNull;
    if (app == null) {
      throw UpdateException('这个包里没有找到 app，可能不是完整的安装包。');
    }
    return app;
  }

  /// 验签。**换上去之前验**——换完再发现签名坏了，人手上就只剩一个
  /// 打不开的 app 了
  Future<void> verifySignature(Directory app) async {
    // 参数**手跑过**才敢写：codesign 没有 `-q`，给了它会 usage 报错退出 2,
    // 于是任何包都被判成「签名不过」，人永远升不上去（这一条是真机验证抓到的）
    final r = operatingSystem == 'windows'
        ? await run('powershell.exe', [
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            r"if ((Get-AuthenticodeSignature -LiteralPath "
                '${_psQuote(p.join(app.path, 'ishkafel.exe'))}).Status '
                "-ne 'Valid') { exit 1 }",
          ])
        : await run('codesign', ['--verify', '--deep', app.path]);
    if (r.exitCode != 0) {
      throw UpdateException(
        '新版本的签名验证没通过，没有替换。'
        '这可能是下载被中间人改过——请找发包的人确认。',
      );
    }
  }

  /// 能不能就地替换。装在 /Applications 而当前用户不是所有者时会失败——
  /// **先问清楚再动手**，不要替换到一半才发现没权限
  bool canReplace(Directory currentApp) {
    try {
      final probe = File(
        p.join(
          currentApp.parent.path,
          '.ishkafel-write-probe-${DateTime.now().microsecondsSinceEpoch}',
        ),
      );
      probe.writeAsStringSync('x');
      probe.deleteSync();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 替换脚本：**等旧进程退出**再动手，旧的先留着，新的就位才删。
  ///
  /// 不能在 app 自己的进程里替换自己——正在运行的可执行文件被删掉之后，
  /// 后面每一次动态库加载都会失败，崩得莫名其妙。所以交给一个独立的 shell。
  String replaceScript({
    required String newApp,
    required String targetApp,
    required int pid,
  }) => operatingSystem == 'windows'
      ? r'''$ErrorActionPreference = 'Stop'
$processId = '''
            '$pid\n'
            r'''$i = 0
while ((Get-Process -Id $processId -ErrorAction SilentlyContinue) -and $i -lt 600) {
  Start-Sleep -Milliseconds 100
  $i++
}
$stillRunning = Get-Process -Id $processId -ErrorAction SilentlyContinue
if ($stillRunning) {
  exit 2
}
$target = '''
            '${_psQuote(targetApp)}\n'
            r'''$fresh = '''
            '${_psQuote(newApp)}\n'
            r'''$backup = "$target.old"
try {
  if (Test-Path -LiteralPath $backup) {
    Remove-Item -LiteralPath $backup -Recurse -Force
  }
  Move-Item -LiteralPath $target -Destination $backup
  try {
    Move-Item -LiteralPath $fresh -Destination $target
  } catch {
    Move-Item -LiteralPath $backup -Destination $target
    exit 1
  }
  Remove-Item -LiteralPath $backup -Recurse -Force
  $exe = Join-Path $target 'ishkafel.exe'
  if (Test-Path -LiteralPath $exe) { Start-Process -FilePath $exe }
  exit 0
} catch {
  if ((Test-Path -LiteralPath $backup) -and -not (Test-Path -LiteralPath $target)) {
    Move-Item -LiteralPath $backup -Destination $target
  }
  exit 1
}
'''
      : '''#!/bin/sh
# ishkafel 自动更新：等旧进程退出 → 换上新版 → 重新打开
# 旧的先改名留着，新的就位才删——中途失败还能把旧的搬回来
i=0
while kill -0 $pid 2>/dev/null && [ \$i -lt 600 ]; do
  sleep 0.1
  i=\$((i+1))
done
BACKUP="$targetApp.old"
rm -rf "\$BACKUP"
if ! mv "$targetApp" "\$BACKUP"; then
  open "$targetApp"
  exit 1
fi
if ! mv "$newApp" "$targetApp"; then
  mv "\$BACKUP" "$targetApp"
  open "$targetApp"
  exit 1
fi
rm -rf "\$BACKUP"
# 换好了就算成功。**打开失败不算失败**——人自己点一下图标就行，
# 而把退出码搅浑会让「没换上去」和「换好了没打开」分不开
open "$targetApp" || true
exit 0
''';

  /// 交棒给替换脚本，然后**这个进程就该退出了**（调用方负责退出）
  Future<void> handOff({
    required Directory newApp,
    required Directory currentApp,
    required Directory workDir,
  }) async {
    final windows = operatingSystem == 'windows';
    final script = File(
      p.join(workDir.path, windows ? 'replace.ps1' : 'replace.sh'),
    );
    script.writeAsStringSync(
      replaceScript(newApp: newApp.path, targetApp: currentApp.path, pid: pid),
    );
    if (!windows) await run('chmod', ['+x', script.path]);
    AppLog.info('自动更新：交棒给替换脚本 ${script.path}');
    // detached：这个进程马上就要退出了，脚本必须活下去
    await launch(
      windows ? 'powershell.exe' : '/bin/sh',
      windows
          ? [
              '-NoProfile',
              '-NonInteractive',
              '-ExecutionPolicy',
              'Bypass',
              '-File',
              script.path,
            ]
          : [script.path],
      ProcessStartMode.detached,
    );
  }

  static String _psQuote(String value) => "'${value.replaceAll("'", "''")}'";
}
