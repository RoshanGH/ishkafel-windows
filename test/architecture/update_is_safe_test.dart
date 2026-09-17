import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 自动更新动的是**人正在用的软件**，而且包里带着明文 AI 凭据。
/// 这几条错一条，后果分别是「软件没了」和「别人花你的钱」。
void main() {
  mainExternalArgs();
  test('安装包不能公开读——产物里的 AI 凭据是明文的', () {
    final src = File('lib/core/update/update_config.dart').readAsStringSync();
    expect(src, contains('UPDATE_TOS_AK'),
        reason: '包私有存放，靠只读凭据现换预签名链接');
    expect(src.contains('UPDATE_MANIFEST_URL'), isFalse,
        reason: '清单也走预签名读：app 本来就带着钥匙，'
            '再维护一个公开地址等于多一处要操心 ACL 的地方');
    final signer = File('lib/core/update/tos_signer.dart').readAsStringSync();
    expect(signer, contains('presignGet'),
        reason: '没有预签名就只能公开读，等于把方舟 key 发出去');
  });

  test('下载完必须核对指纹再动现有的 app', () {
    final src = File('lib/core/update/update_service.dart').readAsStringSync();
    final install = src.substring(src.indexOf('Future<void> install('));
    expect(install.indexOf('verifySha256'), lessThan(install.indexOf('handOff')),
        reason: '先换后验等于没验——人手上会剩一个坏 app');
    expect(install.indexOf('verifySignature'),
        lessThan(install.indexOf('handOff')),
        reason: '签名也要在替换之前验');
  });

  test('没配更新地址时不显示任何更新入口', () {
    final card = File('lib/features/settings/update_card.dart').readAsStringSync();
    expect(card, contains('UpdateConfig.enabled'),
        reason: '摆一个点下去永远报错的按钮，比没有这个按钮更糟');
  });

  test('更新前要人确认——重启会打断正在跑的活儿', () {
    final dialog =
        File('lib/features/update/update_dialog.dart').readAsStringSync();
    expect(dialog, contains('会被打断'),
        reason: '破坏性操作要说清代价，这是写进 CLAUDE.md 的');
    expect(dialog, contains('以后再说'), reason: '要留得下拒绝的余地');
  });

  test('提示摆在人看得见的地方，不是只藏在设置里', () {
    final page =
        File('lib/features/tasks/task_list_page.dart').readAsStringSync();
    expect(page, contains('有新版本'),
        reason: '只放设置页等于没有提示——人不会天天进去看');
    expect(page, contains('_checkUpdate'),
        reason: '启动就要查一次，不然提示永远不出现');
  });

  test('更新流程只有一套 UI——两处各写一套迟早改漏一处', () {
    final card =
        File('lib/features/settings/update_card.dart').readAsStringSync();
    expect(card, contains('showUpdateDialog'));
    expect(card.contains('LinearProgressIndicator'), isFalse,
        reason: '进度画在对话框里就够了，卡片里再画一份就是第二套');
  });

  test('收尾失败要说出来，不能只写日志', () {
    final svc = File('lib/core/update/update_service.dart').readAsStringSync();
    expect(svc, contains('problems.add'),
        reason: '说明书没装上却不吭声，人以为是新的，'
            'Agent 照着旧手册调新命令，报错查不到根因');
  });

  test('发布不依赖外部命令行工具——本机装没装都能发', () {
    expect(File('tool/publish_release.dart').existsSync(), isTrue);
    final src = File('tool/publish_release.dart').readAsStringSync();
    expect(src, contains('presignPut'));
    expect(src.contains('Process.run'), isFalse,
        reason: '要求先装一个命令行工具才能发版，早晚有一次发不出去');
    expect(src.contains('Process.start'), isFalse);
    expect(
      src.indexOf("contentType: 'application/zip'"),
      lessThan(src.indexOf('for (final manifestKey in manifestKeys)')),
      reason: '先传包后传清单——反了的话清单已经指向新版本而包还没上去，'
          '这中间点更新的人会下到 404',
    );
  });

  test('发布用的可写凭据不进产物', () {
    final build = File('scripts/build_macos.sh').readAsStringSync();
    expect(build.contains('update_tos_ak_write'), isFalse,
        reason: 'app 里只该有读权限——写凭据进了产物，'
            '拿到包的人就能往发布目录里塞东西');
  });

  test('升级后 CLI 与说明书要跟上同一版', () {
    final svc = File('lib/core/update/update_service.dart').readAsStringSync();
    expect(svc, contains('CliInstaller'));
    expect(svc, contains('SkillInstaller'));
    final page =
        File('lib/features/tasks/task_list_page.dart').readAsStringSync();
    expect(page, contains('finishAfterRestart'),
        reason: '写了不调用等于没做——版本对不上是最难查的一类问题');
  });
}

/// 外部命令的参数**必须手跑过**才敢写进代码。
///
/// 真机验证抓到过：`codesign --verify --deep -q` —— 它没有 `-q`，
/// usage 报错退出 2，于是任何包都被判成「签名不过」，人永远升不上去。
/// 测试里用假的 runner 是发现不了这种问题的。
void mainExternalArgs() {
  test('codesign 的参数是真实存在的', () {
    final src = File('lib/core/update/app_updater.dart').readAsStringSync();
    final line = src
        .split('\n')
        .firstWhere((l) => l.contains("run('codesign'"), orElse: () => '');
    expect(line, isNotEmpty);
    expect(line.contains("'-q'"), isFalse,
        reason: 'codesign 没有 -q：给了它 usage 报错退出 2，任何包都验不过');
  });
}
