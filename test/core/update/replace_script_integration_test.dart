import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/update/app_updater.dart';

/// **真的把脚本跑起来**，不是只检查它长什么样。
///
/// 替换这一步动的是人正在用的软件，「升级把软件搞没了」是最不能接受的结局。
/// 而这类逻辑光看代码是看不出问题的——真机验证时就抓到过一个：
/// `codesign` 根本没有 `-q` 选项，给了它 usage 报错退出 2，
/// 于是**任何包都被判成「签名不过」**，人永远升不上去。
void main() {
  late Directory work;
  setUp(() => work = Directory.systemTemp.createTempSync('replace'));
  tearDown(() => work.deleteSync(recursive: true));

  Future<ProcessResult> runScript({
    required String newApp,
    required String target,
  }) async {
    final windows = Platform.isWindows;
    final f = File('${work.path}/replace.${windows ? 'ps1' : 'sh'}');
    f.writeAsStringSync(
      AppUpdater().replaceScript(
        newApp: newApp,
        targetApp: target,
        // 一个必然不存在的 pid：脚本应当立刻往下走，不是干等
        pid: 999999,
      ),
    );
    if (windows) {
      return Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        f.path,
      ]);
    }
    await Process.run('chmod', ['+x', f.path]);
    return Process.run('/bin/sh', [f.path]);
  }

  test('换上去了：新的就位，旧的清干净', () async {
    final target = Directory('${work.path}/ishkafel.app')..createSync();
    File('${target.path}/marker').writeAsStringSync('旧');
    final fresh = Directory('${work.path}/new.app')..createSync();
    File('${fresh.path}/marker').writeAsStringSync('新');

    final r = await runScript(newApp: fresh.path, target: target.path);

    expect(
      File('${target.path}/marker').readAsStringSync(),
      '新',
      reason: '换上去了没有，看的是内容，不是退出码',
    );
    expect(r.exitCode, 0, reason: '换好了就算成功——打开失败不该让退出码看起来像「升级失败」');
    expect(
      Directory('${target.path}.old').existsSync(),
      isFalse,
      reason: '备份留着不清，几次更新就攒出几个几十兆的残骸',
    );
  });

  test('搬不过去：旧的必须回到原位，一个字节都不能少', () async {
    final target = Directory('${work.path}/ishkafel.app')..createSync();
    File('${target.path}/marker').writeAsStringSync('旧版还在');

    // 新包指向一个不存在的路径：模拟解压产物被清理、磁盘满
    final r = await runScript(
      newApp: '${work.path}/根本不存在.app',
      target: target.path,
    );

    expect(r.exitCode, isNot(0), reason: '失败要如实报出来');
    expect(target.existsSync(), isTrue, reason: '人的软件不能没了');
    expect(File('${target.path}/marker').readAsStringSync(), '旧版还在');
    expect(Directory('${target.path}.old').existsSync(), isFalse);
  });

  test('等旧进程退出：pid 还活着就不动手', () async {
    // 拿一个真在跑的进程（当前测试进程自己）当靶子：脚本应当一直等，
    // 而不是立刻把 app 换掉
    final target = Directory('${work.path}/ishkafel.app')..createSync();
    final fresh = Directory('${work.path}/new.app')..createSync();
    final windows = Platform.isWindows;
    final f = File('${work.path}/replace.${windows ? 'ps1' : 'sh'}');
    f.writeAsStringSync(
      AppUpdater().replaceScript(
        newApp: fresh.path,
        targetApp: target.path,
        pid: pid,
      ),
    );
    if (!windows) await Process.run('chmod', ['+x', f.path]);
    final proc = await Process.start(
      windows ? 'powershell.exe' : '/bin/sh',
      windows
          ? [
              '-NoProfile',
              '-NonInteractive',
              '-ExecutionPolicy',
              'Bypass',
              '-File',
              f.path,
            ]
          : [f.path],
    );
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(target.existsSync(), isTrue, reason: '正在运行的可执行文件被删掉，之后每次加载动态库都会崩');
    expect(Directory('${target.path}.old').existsSync(), isFalse);
    proc.kill();
  });
}
