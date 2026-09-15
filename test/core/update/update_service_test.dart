import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/update/release_manifest.dart';
import 'package:ishkafel/core/update/update_service.dart';

/// 查更新这一步的规矩：**查不到就当没有新版本**。
///
/// 网络不通、清单读不懂、拿到一份坏 JSON——这些都不该弹错误框吓人。
/// 而「有新版本」必须确实比手上这一版新，不能反复提示人升级同一版。
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('svc'));
  tearDown(() => dir.deleteSync(recursive: true));

  UpdateService svc() => UpdateService(
    workDir: Directory('${dir.path}/work'),
    currentApp: Directory('${dir.path}/ishkafel.app')..createSync(),
  );

  String manifest(String version) =>
      '''
{"version":"$version","objectKey":"releases/x.zip",
 "sha256":"${'a' * 64}","sizeBytes":100,"notes":"改了点东西"}''';

  test('没配更新地址时整个功能关掉——不能留一个点了永远报错的按钮', () async {
    // 测试环境没有 --dart-define，UpdateConfig.enabled 必然是 false
    expect(await svc().check(fetch: (_) async => manifest('9.9.9')), isNull);
  });

  test('版本比较是核心：同版本不提示，旧版本不提示', () {
    expect(isNewerVersion('0.1.172', '0.1.171'), isTrue);
    expect(isNewerVersion('0.1.171', '0.1.171'), isFalse);
    expect(isNewerVersion('0.1.170', '0.1.171'), isFalse);
  });

  test('清单读不懂时返回 null，而不是抛给界面', () {
    expect(ReleaseManifest.tryParse('{"version":"坏的"}'), isNull);
  });

  test('Windows 更新目标是 exe 所在的完整 bundle，不向上误删父目录', () {
    expect(
      UpdateService.runningAppFrom(
        r'C:\Program Files\Ishkafel\ishkafel.exe',
        operatingSystem: 'windows',
      ).path,
      r'C:\Program Files\Ishkafel',
    );
    expect(
      UpdateService.runningAppFrom(
        '/Applications/ishkafel.app/Contents/MacOS/ishkafel',
        operatingSystem: 'macos',
      ).path,
      '/Applications/ishkafel.app',
    );
  });

  group('升级之后的收尾', () {
    test('说明书没装过的人不给他装——那是多管闲事', () {
      // 只验意图写在代码里：inspect().outdated 非空才装
      final src = File(
        'lib/core/update/update_service.dart',
      ).readAsStringSync();
      expect(
        src,
        contains('status.outdated.isNotEmpty'),
        reason: '不能给没用 Agent 的人往家目录里塞文件',
      );
    });

    test('命令行工具 stale 时也要重写——那正是 app 换了位置的样子', () {
      final src = File(
        'lib/core/update/update_service.dart',
      ).readAsStringSync();
      expect(
        src,
        contains('CliStatus.stale'),
        reason: 'shim 指着旧路径 = 命令直接失效，而升级正是最容易造成这个的时候',
      );
    });
  });
}
