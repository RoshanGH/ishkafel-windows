import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/diagnostics/cli_installer.dart';
import 'package:path/path.dart' as p;

/// 把命令行工具装进 PATH。
///
/// 判据只有一条：**用户装完 app 点一下，`ishkafel` 就能用**，不需要知道
/// 自己这台是 Intel 还是 M 系列，不需要开终端敲任何东西。所以这里所有的
/// 状态都要能在界面上说清楚，尤其是「装过但现在坏了」——app 被挪过位置
/// 之后 shim 指向空气，那时候报错必须说人话。
void main() {
  late Directory temp;
  late Directory bin;
  late File bundled;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('cli_installer');
    bin = Directory(p.join(temp.path, 'usr_local_bin'))..createSync();
    bundled = File(
      p.join(temp.path, 'app', 'Resources', 'cli', 'bin', 'ishkafel'),
    );
    bundled.parent.createSync(recursive: true);
    bundled.writeAsStringSync('#!/bin/sh\necho hi\n');
  });

  tearDown(() => temp.deleteSync(recursive: true));

  CliInstaller installerWith({File? cli}) =>
      CliInstaller(binDir: bin, bundledCli: cli ?? bundled);

  File shimIn(Directory directory) => File(
    p.join(directory.path, Platform.isWindows ? 'ishkafel.cmd' : 'ishkafel'),
  );

  group('看状态', () {
    test('包里没带 CLI 就说没带，而不是说没装', () {
      // 调试运行（flutter run）出来的产物里没有 CLI。这时候给「未安装 + 安装
      // 按钮」是骗人的：点了也装不上
      final missing = File(p.join(temp.path, '不存在'));
      expect(installerWith(cli: missing).inspect(), CliStatus.unavailable);
    });

    test('还没装', () {
      expect(installerWith().inspect(), CliStatus.notInstalled);
    });

    test('装好了', () async {
      await installerWith().install();
      expect(installerWith().inspect(), CliStatus.installed);
    });

    test('装过但指向的东西没了——app 被挪走了', () async {
      // 用户把 app 从下载目录拖进「应用程序」：包里的 CLI 还在（在新位置），
      // 但 shim 里写的还是老路径，敲 ishkafel 会「no such file」
      final oldSpot = File(p.join(temp.path, '旧位置', 'bin', 'ishkafel'));
      oldSpot.parent.createSync(recursive: true);
      oldSpot.writeAsStringSync('#!/bin/sh\n');
      await CliInstaller(binDir: bin, bundledCli: oldSpot).install();
      oldSpot.parent.parent.deleteSync(recursive: true);

      expect(installerWith().inspect(), CliStatus.stale);
    });

    test('别处装的同名命令不认成自己装的', () {
      shimIn(bin)
        ..writeAsStringSync('#!/bin/sh\n# 别人家的\n')
        ..parent.createSync(recursive: true);
      expect(installerWith().inspect(), CliStatus.foreign);
    });
  });

  group('装', () {
    test('装出来是能执行的，且真的能跑到包里那份', () async {
      final result = await installerWith().install();
      expect(result.ok, isTrue);

      final shim = shimIn(bin);
      expect(shim.existsSync(), isTrue);
      if (!Platform.isWindows) {
        final mode = shim.statSync().mode;
        expect(mode & 0x40, isNot(0), reason: 'owner 要有可执行位');
      } else {
        expect(shim.readAsStringSync(), contains('chcp 65001'));
      }

      // 用绝对路径而不是软链：bundle 里的可执行文件靠相对路径找 dylib，
      // 软链过去会让它找不到
      expect(shim.readAsStringSync(), contains(bundled.path));
    });

    test('重复装是幂等的，不会追加成两行', () async {
      await installerWith().install();
      await installerWith().install();
      final body = shimIn(bin).readAsStringSync();
      expect(
        body.split(Platform.isWindows ? bundled.path : 'exec').length - 1,
        1,
      );
    });

    test('目录不存在时自己建出来', () async {
      final fresh = Directory(p.join(temp.path, '还没有这个目录'));
      final result = await CliInstaller(
        binDir: fresh,
        bundledCli: bundled,
      ).install();
      expect(result.ok, isTrue);
      expect(shimIn(fresh).existsSync(), isTrue);
    });

    test('包里没带 CLI 时不假装装上了', () async {
      final result = await installerWith(
        cli: File(p.join(temp.path, '不存在')),
      ).install();
      expect(result.ok, isFalse);
      expect(result.message, contains('这个版本没有带命令行工具'));
    });

    test('写不进去时说清楚要管理员，而不是把系统报错甩出来', () async {
      final locked = Directory(p.join(temp.path, 'locked'))..createSync();
      // 去掉写权限，模拟 /usr/local/bin 不可写
      await Process.run('chmod', ['555', locked.path]);
      addTearDown(() => Process.run('chmod', ['755', locked.path]));

      final result = await CliInstaller(
        binDir: locked,
        bundledCli: bundled,
      ).install();
      expect(result.ok, isFalse);
      expect(result.needsAdmin, isTrue);
      expect(result.message, contains('管理员'));
    }, skip: Platform.isWindows ? 'Windows 默认写用户目录，不走 chmod 权限位' : false);
  });

  group('卸', () {
    test('只删自己装的那个', () async {
      await installerWith().install();
      expect(await installerWith().uninstall(), isTrue);
      expect(shimIn(bin).existsSync(), isFalse);
    });

    test('别人家的同名命令不碰', () async {
      final foreign = shimIn(bin)..writeAsStringSync('别人家的');
      expect(await installerWith().uninstall(), isFalse);
      expect(foreign.existsSync(), isTrue, reason: '不是我们装的就不许删');
    });
  });
}
