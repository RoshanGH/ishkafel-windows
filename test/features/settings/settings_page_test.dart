import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/diagnostics/environment_report.dart';
import 'package:ishkafel/core/miaoa/miaoa_account_service.dart';
import 'package:ishkafel/core/miaoa/miaoa_failure.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/storage/cache_usage.dart';
import 'package:ishkafel/core/storage/task_repository.dart';
import 'package:ishkafel/features/settings/settings_page.dart';
import 'package:ishkafel/features/settings/sections/environment_section.dart';
import 'package:ishkafel/features/settings/settings_providers.dart';
import 'package:ishkafel/features/settings/settings_widgets.dart';
import 'package:ishkafel/features/tasks/task_list_controller.dart';

class _Repo implements TaskRepository {
  @override
  Future<List<RenewTask>> findAll() async => const [];
  @override
  Future<RenewTask?> findById(String id) async => null;
  @override
  Future<void> save(RenewTask task) async {}
  @override
  Future<void> delete(String id) async {}
}

const _loggedIn = MiaoaAccountStatus(
  loggedIn: true,
  maskedAccount: '134****0087',
  tenantName: '极创美奥',
  projectName: '卫仕洗衣液三组v2',
  projectCount: 42,
  endpoint: 'https://miaoa.example.com/api',
);

EnvironmentReport _report({bool ffmpegOk = true, bool credentialsOk = true}) =>
    EnvironmentReport(
      tools: [
        ffmpegOk
            ? const ToolHealth(
                name: 'ffmpeg',
                path: '/opt/homebrew/bin/ffmpeg',
                version: 'ffmpeg version 7.1.1')
            : const ToolHealth(
                name: 'ffmpeg', hint: '未找到 ffmpeg，请执行 brew install ffmpeg'),
        const ToolHealth(name: 'ffprobe', path: '/opt/homebrew/bin/ffprobe'),
        const ToolHealth(name: 'miaoa', path: '/Users/x/.local/bin/miaoa'),
      ],
      credentialsReady: credentialsOk,
      credentialsHint: credentialsOk ? null : '云端 AI 凭据不完整，无法进行语音识别与画面打标。',
    );

Future<void> _pump(
  WidgetTester tester, {
  MiaoaAccountStatus account = _loggedIn,
  CacheUsage usage = CacheUsage.empty,
  EnvironmentReport? report,
  Future<int> Function()? purge,
  TaskRepository? repo,
}) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      taskRepositoryProvider.overrideWithValue(repo ?? _Repo()),
      miaoaAccountProvider.overrideWith((_) async => account),
      cacheUsageProvider.overrideWith((_) async => usage),
      environmentReportProvider.overrideWith((_) async => report ?? _report()),
      cachePurgeProvider.overrideWithValue(purge ?? () async => 0),
      dataDirProvider.overrideWithValue(Directory('/tmp/ishkafel_data')),
    ],
    child: const MaterialApp(home: SettingsPage()),
  ));
  await tester.pumpAndSettle();
}

Future<void> _openSection(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  test('Windows 运行环境说明不出现 macOS 与访达', () {
    final text = environmentPathExplanation(operatingSystem: 'windows');
    expect(text, contains('Windows'));
    expect(text, contains('PowerShell'));
    expect(text, isNot(contains('macOS')));
    expect(text, isNot(contains('访达')));
  });

  group('分区导航', () {
    testWidgets('五个分区都在，默认停在 miaoa 账号', (tester) async {
      await _pump(tester);

      for (final name in ['miaoa 账号', '运行环境', '存储位置', '缓存管理', '关于']) {
        expect(find.text(name), findsWidgets, reason: '$name 分区入口缺失');
      }
      expect(find.text('极创美奥'), findsOneWidget);
    });

    testWidgets('存储位置不是死入口', (tester) async {
      await _pump(tester);
      await _openSection(tester, '存储位置');
      expect(find.byKey(const Key('settings-change-storage-root')), findsOneWidget);
      expect(find.byKey(const Key('settings-change-export-root')), findsOneWidget);
    });
  });

  group('版面', () {
    testWidgets('宽窗口下卡片不会拉满整屏', (tester) async {
      tester.view.physicalSize = const Size(2400, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await _pump(tester);

      // 量的是真正画出背景的那层，不是 SettingsCard 这个外壳——外壳被
      // ListView 拉满是正常的，卡片本体有没有收住才是问题
      final body = tester.getSize(find
          .descendant(
              of: find.byType(SettingsCard).first, matching: find.byType(Container))
          .first);
      expect(body.width, lessThanOrEqualTo(640),
          reason: '设置项是「键 —— 值」的短行，铺满 2000px 会让键和值隔着大半个'
              '屏幕，眼睛要横扫过去才能配对；设计稿给的上限是 640');
    });
  });

  group('miaoa 账号', () {
    testWidgets('已登录：显示脱敏账号、租户、当前项目与可选项目数', (tester) async {
      await _pump(tester);

      expect(find.textContaining('134****0087'), findsOneWidget);
      expect(find.text('极创美奥'), findsOneWidget);
      expect(find.textContaining('卫仕洗衣液三组v2'), findsOneWidget);
      expect(find.textContaining('42'), findsWidgets);
    });

    testWidgets('未登录不是错误：给登录办法，不弹红字', (tester) async {
      await _pump(tester, account: const MiaoaAccountStatus(loggedIn: false));

      expect(find.textContaining('miaoa auth login'), findsWidgets,
          reason: '得告诉用户具体该敲什么，而不是「请先登录」');
      expect(find.byIcon(Icons.error_outline), findsNothing);
    });

    testWidgets('登录命令可一键复制——不该让用户照着屏幕手打', (tester) async {
      // 剪贴板是平台通道，测试环境默认未注册；不接管的话调用会抛
      // MissingPluginException，测到的就变成「失败路径」而不是复制本身
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add(call.arguments['text'] as String);
        }
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));

      await _pump(tester, account: const MiaoaAccountStatus(loggedIn: false));

      final copy = find.byKey(const Key('settings-copy-login-command'));
      expect(copy, findsOneWidget);
      await tester.tap(copy);
      await tester.pumpAndSettle();
      expect(copied, ['miaoa auth login'],
          reason: '进到剪贴板的必须是可直接粘贴执行的完整命令');
      expect(find.textContaining('已复制'), findsOneWidget);
    });

    testWidgets('剪贴板不可用时给提示，而不是点了没反应', (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform, (call) async {
        // 只让写剪贴板这一个调用失败：整条通道都抛的话，SelectableText 的
        // Live Text 探测等无关调用也会跟着炸，测到的就不是这里要测的东西
        if (call.method == 'Clipboard.setData') {
          throw PlatformException(code: 'unavailable');
        }
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));

      await _pump(tester, account: const MiaoaAccountStatus(loggedIn: false));

      await tester.tap(find.byKey(const Key('settings-copy-login-command')));
      await tester.pumpAndSettle();

      expect(find.textContaining('复制失败'), findsOneWidget,
          reason: '按钮点下去什么都不发生，用户只会反复点同一个地方');
    });

    testWidgets('账号服务未接线时如实说明，不冒充「未登录」', (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [taskRepositoryProvider.overrideWithValue(_Repo())],
        child: const MaterialApp(home: SettingsPage()),
      ));
      await tester.pumpAndSettle();

      expect(find.textContaining('未接入'), findsOneWidget,
          reason: '拿「未登录」冒充漏接线，会让已登录的用户永远看到登录引导，'
              '而没有任何线索指向真正的原因');
      expect(find.textContaining(miaoaLoginCommand), findsNothing);
    });

    testWidgets('读取失败时透出分类提示并可重试', (tester) async {
      await _pump(tester,
          account: const MiaoaAccountStatus.failed(MiaoaAccountFailure(
              kind: MiaoaFailureKind.network, message: '连接 miaoa 失败，请检查网络后点「重试」。')));

      expect(find.textContaining('连接 miaoa 失败'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    });
  });

  group('运行环境', () {
    testWidgets('列出三个外部工具的实际解析路径', (tester) async {
      await _pump(tester);
      await _openSection(tester, '运行环境');

      expect(find.text('/opt/homebrew/bin/ffmpeg'), findsOneWidget,
          reason: 'GUI 启动时 PATH 里没有 Homebrew 目录是本项目反复踩的坑，'
              '把真实路径摆出来才能一眼确认到底找没找到');
      expect(find.textContaining('miaoa'), findsWidgets);
    });

    testWidgets('缺失工具给出该工具自己的安装办法', (tester) async {
      await _pump(tester, report: _report(ffmpegOk: false));
      await _openSection(tester, '运行环境');

      expect(find.textContaining('brew install ffmpeg'), findsOneWidget);
    });

    testWidgets('云端凭据只报状态，界面上没有任何输入框可以看到或改动它',
        (tester) async {
      await _pump(tester);
      await _openSection(tester, '运行环境');

      expect(find.text('已配置'), findsOneWidget);
      expect(find.byType(TextField), findsNothing,
          reason: '凭据由打包注入，使用者不接触；放个输入框既泄露又会被误改');
    });

    testWidgets('凭据不全时说明后果与找谁解决', (tester) async {
      await _pump(tester, report: _report(credentialsOk: false));
      await _openSection(tester, '运行环境');

      expect(find.textContaining('无法进行语音识别'), findsOneWidget);
    });

    testWidgets('命令行工具那张卡片一直在，体检挂了也不受影响', (tester) async {
      // 它跟体检没有依赖关系。挂在体检结果里面的话，体检一失败整张卡片
      // 连同安装按钮一起消失，用户只会以为「这版没有这个功能」
      await _pump(tester);
      await _openSection(tester, '运行环境');
      expect(find.text('命令行工具'), findsOneWidget);
    });
  });

  group('缓存管理', () {
    const usage = CacheUsage(
        coversBytes: 72 * 1024,
        workBytes: 14 * 1024 * 1024,
        fileCount: 130,
        orphanBytes: 3 * 1024 * 1024,
        orphanCount: 20);

    testWidgets('显示总占用与可回收空间', (tester) async {
      await _pump(tester, usage: usage);
      await _openSection(tester, '缓存管理');

      expect(find.textContaining('14.1 MB'), findsWidgets);
      expect(find.textContaining('3.0 MB'), findsWidgets);
    });

    testWidgets('没有可回收空间时按钮禁用，并说明为什么', (tester) async {
      await _pump(tester,
          usage: const CacheUsage(
              coversBytes: 100,
              workBytes: 100,
              fileCount: 2,
              orphanBytes: 0,
              orphanCount: 0));
      await _openSection(tester, '缓存管理');

      final button = tester.widget<FilledButton>(
          find.byKey(const Key('settings-purge-cache')));
      expect(button.onPressed, isNull);
      expect(find.textContaining('都属于现有任务'), findsOneWidget,
          reason: '一个点不动的按钮不解释原因，用户只会以为软件卡住了');
    });

    testWidgets('清理前必须确认，且说清会删掉什么', (tester) async {
      var purged = 0;
      await _pump(tester, usage: usage, purge: () async {
        purged++;
        return 3 * 1024 * 1024;
      });
      await _openSection(tester, '缓存管理');
      await tester.tap(find.byKey(const Key('settings-purge-cache')));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining('20'), findsWidgets, reason: '要说清是多少个文件');
      expect(purged, 0, reason: '删除是不可逆操作，弹窗还没确认就不能动手');

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(purged, 0);
    });

    testWidgets('确认后执行清理并回报实际释放的空间', (tester) async {
      await _pump(tester, usage: usage, purge: () async => 3 * 1024 * 1024);
      await _openSection(tester, '缓存管理');
      await tester.tap(find.byKey(const Key('settings-purge-cache')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清理'));
      await tester.pumpAndSettle();

      expect(find.textContaining('3.0 MB'), findsWidgets);
    });

    testWidgets('清理失败给中文提示，不把异常摊给用户', (tester) async {
      await _pump(tester,
          usage: usage, purge: () async => throw const FileSystemException('boom'));
      await _openSection(tester, '缓存管理');
      await tester.tap(find.byKey(const Key('settings-purge-cache')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清理'));
      await tester.pumpAndSettle();

      expect(find.textContaining('FileSystemException'), findsNothing);
      expect(find.textContaining('清理未完成'), findsWidgets);
    });
  });

  group('关于', () {
    testWidgets('显示版本号与数据目录，并能在访达中打开', (tester) async {
      await _pump(tester);
      await _openSection(tester, '关于');

      expect(find.textContaining(appVersion), findsWidgets);
      expect(find.textContaining('/tmp/ishkafel_data'), findsOneWidget);
      expect(find.byKey(const Key('settings-reveal-data-dir')), findsOneWidget);
      expect(
        find.text(Platform.isWindows ? '在文件资源管理器中显示' : '在访达中显示'),
        findsOneWidget,
      );
    });
  });

  group('版本号防漂移', () {
    test('代码里的版本号与 pubspec.yaml 一致', () {
      final line = File('pubspec.yaml')
          .readAsLinesSync()
          .firstWhere((l) => l.startsWith('version:'));
      final declared = line.split(':')[1].trim().split('+').first;

      expect(appVersion, declared,
          reason: '「关于」页显示的版本号是排查线上问题时唯一的对齐锚点，'
              '和 pubspec 对不上就等于没有');
    });
  });
}
