import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ffmpeg/media_tools_locator.dart';
import 'package:ishkafel/core/miaoa/miaoa_account_service.dart';
import 'package:ishkafel/core/miaoa/miaoa_failure.dart';
import 'package:ishkafel/features/home/readiness.dart';

const _toolsOk = MediaToolsStatus(
    ffmpegPath: '/opt/homebrew/bin/ffmpeg',
    ffprobePath: '/opt/homebrew/bin/ffprobe');

const _loggedIn = MiaoaAccountStatus(
    loggedIn: true, maskedAccount: '134****0087', tenantName: '极创美奥');

Readiness _readiness({
  MediaToolsStatus? tools = _toolsOk,
  MiaoaAccountStatus? account = _loggedIn,
  bool credentials = true,
  bool debugBuild = false, // 默认按正式版测；调试版文案单独一条用例
  String operatingSystem = 'macos',
}) =>
    Readiness.from(
        mediaTools: tools,
        account: account,
        credentialsReady: credentials,
        debugBuild: debugBuild,
        operatingSystem: operatingSystem);

void main() {
  group('准备工作清单（同事双击打开就用，没人给他做培训）', () {
    test('三项前置条件都在：视频组件、miaoa 账号、云端 AI', () {
      final items = _readiness().items;

      expect(items, hasLength(3));
      expect(items.map((i) => i.title),
          containsAll(<String>['视频处理组件', 'miaoa 账号', '云端 AI 服务']));
    });

    test('全部就绪时不摆一堆黄色感叹号吓人', () {
      final r = _readiness();

      expect(r.allReady, isTrue);
      expect(r.items.every((i) => i.ready), isTrue);
      expect(r.blockingReason, isNull);
    });

    test('已登录时显示脱敏账号，让人确认登的是哪个号', () {
      final miaoa =
          _readiness().items.firstWhere((i) => i.title == 'miaoa 账号');

      expect(miaoa.statusText, contains('134****0087'));
    });
  });

  group('缺失时要说清后果，而不只是标一个叉', () {
    test('缺 ffmpeg：说明导入与分析都做不了，并给安装办法', () {
      final item = _readiness(tools: const MediaToolsStatus())
          .items
          .firstWhere((i) => i.title == '视频处理组件');

      expect(item.ready, isFalse);
      expect(item.hint, contains('brew install ffmpeg'));
      expect(item.hint, anyOf(contains('导入'), contains('分析')));
    });

    test('Windows 缺内置 ffmpeg：要求重装完整包，不让用户去装 Homebrew', () {
      final item = _readiness(
        tools: const MediaToolsStatus(),
        operatingSystem: 'windows',
      ).items.firstWhere((i) => i.title == '视频处理组件');

      expect(item.hint, contains('重新安装'));
      expect(item.hint, contains('内置'));
      expect(item.hint, isNot(contains('brew')));
    });

    test('未登录 miaoa：说明没有标签组就检索不到候选素材', () {
      final item = _readiness(account: const MiaoaAccountStatus(loggedIn: false))
          .items
          .firstWhere((i) => i.title == 'miaoa 账号');

      expect(item.ready, isFalse);
      expect(item.hint, contains('候选素材'));
      expect(item.hint, contains('miaoa auth login'));
    });

    test('缺云端凭据：说明是打包问题，去找发版的人而不是自己配', () {
      final item = _readiness(credentials: false)
          .items
          .firstWhere((i) => i.title == '云端 AI 服务');

      expect(item.ready, isFalse);
      expect(item.hint, contains('同事'),
          reason: '凭据由打包注入，使用者自己配不了；让他去改配置只会白折腾');
    });

    test('调试构建缺凭据：如实说「调试版本就不含」，别把人引去找同事重新打包', () {
      final item = _readiness(credentials: false, debugBuild: true)
          .items
          .firstWhere((i) => i.title == '云端 AI 服务');

      expect(item.statusText, '调试版不含');
      expect(item.hint, contains('开发调试版'));
      expect(item.hint, isNot(contains('同事')),
          reason: '调试版天生没有凭据，找同事重新打包解决不了任何问题');
    });
  });

  group('探测结果还没回来时不下结论', () {
    test('工具状态未知按「检测中」处理，不谎报未安装', () {
      final item =
          _readiness(tools: null).items.firstWhere((i) => i.title == '视频处理组件');

      expect(item.ready, isFalse);
      expect(item.checking, isTrue);
      expect(item.statusText, contains('检测中'));
    });

    test('账号状态未知时也是检测中，不谎报未登录', () {
      final item =
          _readiness(account: null).items.firstWhere((i) => i.title == 'miaoa 账号');

      expect(item.checking, isTrue);
    });

    test('检测中不算「全部就绪」，也不算失败', () {
      final r = _readiness(tools: null);

      expect(r.allReady, isFalse);
      expect(r.blockingReason, isNull,
          reason: '还没测出结果就拦住用户，等于把一次正常启动做成故障');
    });
  });

  group('只有真正做不了的事才拦住入口', () {
    test('缺 ffmpeg 时禁止新建任务并说明原因', () {
      final r = _readiness(tools: const MediaToolsStatus());

      expect(r.canStartTask, isFalse);
      expect(r.blockingReason, contains('ffmpeg'));
    });

    test('miaoa 没登录不拦——网络可能只是暂时不通，向导里还能重试', () {
      final r = _readiness(account: const MiaoaAccountStatus(loggedIn: false));

      expect(r.canStartTask, isTrue,
          reason: '把入口锁死，用户连「重试」的机会都没有；'
              '向导内部已经有针对 miaoa 失败的重试与引导');
      expect(r.allReady, isFalse);
    });

    test('缺云端凭据不拦导入，但要在清单里标出来', () {
      final r = _readiness(credentials: false);

      expect(r.canStartTask, isTrue,
          reason: '素材可以先导进来，凭据补上后对任务点「重新分析」即可');
      expect(r.allReady, isFalse);
    });
  });

  group('miaoa 读取失败与「没登录」是两回事', () {
    test('读取失败时透出服务层给的中文提示，不改写成「未登录」', () {
      final item = _readiness(
              account: const MiaoaAccountStatus.failed(MiaoaAccountFailure(
                  kind: MiaoaFailureKind.network,
                  message: '连接 miaoa 失败，请检查网络后点「重试」。')))
          .items
          .firstWhere((i) => i.title == 'miaoa 账号');

      expect(item.ready, isFalse);
      expect(item.hint, contains('连接 miaoa 失败'));
    });
  });
}
