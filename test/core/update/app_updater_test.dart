import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/update/app_updater.dart';

/// 装新版本这一步动的是**人正在用的软件**，出错的代价是「软件没了」。
/// 所以每一步都可回滚、每一步都先验证。
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('upd'));
  tearDown(() => dir.deleteSync(recursive: true));

  AppUpdater updaterWith(
    Future<ProcessResult> Function(String, List<String>) run,
  ) => AppUpdater(run: run, operatingSystem: 'macos');

  test('指纹对不上就停——装一个坏包比不升级糟得多', () async {
    final f = File('${dir.path}/pkg.zip')..writeAsStringSync('半截包');
    await expectLater(
      AppUpdater().verifySha256(f, 'b' * 64),
      throwsA(isA<UpdateException>()),
    );
  });

  test('指纹对得上就放行', () async {
    final f = File('${dir.path}/pkg.zip')..writeAsStringSync('完整的包');
    final real = sha256.convert(f.readAsBytesSync()).toString();
    await AppUpdater().verifySha256(f, real); // 不抛就是过
  });

  test('解压用 ditto，不用 unzip——unzip 丢扩展属性，签名会失效', () async {
    final calls = <String>[];
    final u = updaterWith((exe, args) async {
      calls.add(exe);
      Directory('${dir.path}/out/ishkafel.app').createSync(recursive: true);
      return ProcessResult(0, 0, '', '');
    });
    final zip = File('${dir.path}/a.zip')..writeAsStringSync('z');
    final app = await u.unpack(zip, Directory('${dir.path}/out'));
    expect(calls, contains('ditto'));
    expect(calls, isNot(contains('unzip')));
    expect(app.path, endsWith('.app'));
  });

  test('包里没有 app 就直说，别装一半', () async {
    final u = updaterWith((exe, args) async {
      Directory('${dir.path}/out').createSync(recursive: true);
      return ProcessResult(0, 0, '', '');
    });
    await expectLater(
      u.unpack(
        File('${dir.path}/a.zip')..writeAsStringSync('z'),
        Directory('${dir.path}/out'),
      ),
      throwsA(isA<UpdateException>()),
    );
  });

  test('签名不过就不替换——换完再发现，人手上只剩一个打不开的 app', () async {
    final u = updaterWith(
      (exe, args) async => exe == 'codesign'
          ? ProcessResult(0, 1, '', 'bad')
          : ProcessResult(0, 0, '', ''),
    );
    await expectLater(
      u.verifySignature(Directory('${dir.path}/x.app')..createSync()),
      throwsA(isA<UpdateException>()),
    );
  });

  group('替换脚本', () {
    final script = AppUpdater(operatingSystem: 'macos').replaceScript(
      newApp: '/tmp/new/ishkafel.app',
      targetApp: '/Applications/ishkafel.app',
      pid: 4321,
    );

    test('先等旧进程退出，不能边跑边换', () {
      expect(
        script,
        contains('kill -0 4321'),
        reason: '正在运行的可执行文件被删掉，之后每次加载动态库都会崩',
      );
    });

    test('旧的先改名留着，新的就位才删', () {
      expect(script, contains('.old'));
      expect(
        script.indexOf('mv "/Applications/ishkafel.app"'),
        lessThan(script.indexOf('mv "/tmp/new/ishkafel.app"')),
        reason: '顺序反了就没有回滚的余地',
      );
    });

    test('中途失败要把旧的搬回来，并且照样打开', () {
      expect(
        script,
        contains('mv "\$BACKUP" "/Applications/ishkafel.app"'),
        reason: '失败了还把人的软件弄没了，这是最不能接受的结局',
      );
      expect(
        'open "/Applications/ishkafel.app"'.allMatches(script).length,
        greaterThanOrEqualTo(2),
        reason: '成功要打开，回滚也要打开——不能让人对着一个没反应的图标',
      );
    });
  });

  test('装在没权限的地方：先问清楚，别替换到一半才发现', () {
    final readOnly = Directory('/System/Library/CoreServices/ishkafel.app');
    expect(AppUpdater().canReplace(readOnly), isFalse);
    expect(
      AppUpdater().canReplace(Directory('${dir.path}/ishkafel.app')),
      isTrue,
    );
  });
}
