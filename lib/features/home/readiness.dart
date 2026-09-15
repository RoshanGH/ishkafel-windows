import 'dart:io';

import '../../core/ffmpeg/media_tools_locator.dart';
import '../../core/build_mode.dart';
import '../../core/miaoa/miaoa_account_service.dart';

/// 一项前置条件的检查结果（不可变）
class ReadinessItem {
  final String title;

  /// 一眼可见的状态短语（「已就绪」「未登录」「检测中…」）
  final String statusText;

  final bool ready;

  /// 还在探测，结论未知。既不算就绪也不算失败——还没测出结果就把用户拦住，
  /// 等于把一次正常启动做成故障。
  final bool checking;

  /// 没就绪时该怎么办：说清**后果**与**下一步**，不是只标一个叉
  final String? hint;

  const ReadinessItem({
    required this.title,
    required this.statusText,
    required this.ready,
    this.checking = false,
    this.hint,
  });
}

/// 首页「准备工作」清单。
///
/// 存在的理由：本应用的分发方式是把 .app 交给同事双击打开，没有安装向导、
/// 没有培训。缺 ffmpeg、没登录 miaoa 这些事，原来只在出错时弹一条红色横幅
/// ——那时用户已经在半路上了。把它们摆在首页，让人**开始之前**就知道。
class Readiness {
  final List<ReadinessItem> items;

  /// 真正让「新建任务」做不下去的原因；null 表示可以开始
  final String? blockingReason;

  Readiness({required List<ReadinessItem> items, this.blockingReason})
      : items = List.unmodifiable(items);

  bool get allReady => items.every((i) => i.ready);

  bool get canStartTask => blockingReason == null;

  factory Readiness.from({
    required MediaToolsStatus? mediaTools,
    required MiaoaAccountStatus? account,
    required bool credentialsReady,

    /// 测试注入用：flutter test 的 VM 永远是 debug 模式，不注入的话
    /// 正式版文案那条分支在测试里永远走不到
    bool debugBuild = isDebugBuild,
    String? operatingSystem,
  }) {
    final resolvedOperatingSystem = operatingSystem ?? Platform.operatingSystem;
    final tools = _toolsItem(mediaTools, resolvedOperatingSystem);
    return Readiness(
      items: [
        tools,
        _accountItem(account),
        _credentialsItem(credentialsReady, debugBuild),
      ],
      // 只拦真正做不下去的：没有 ffmpeg 连读取视频信息、抽封面都做不到。
      // miaoa / 凭据的问题都还有补救路径（向导内重试、先导入后重新分析），
      // 把入口锁死反而让用户连重试的机会都没有。
      blockingReason: tools.ready || tools.checking
          ? null
          : resolvedOperatingSystem == 'windows'
              ? '未检测到内置 ffmpeg，无法读取视频信息与抽取封面。请重新安装完整版本。'
              : '未检测到 ffmpeg，无法读取视频信息与抽取封面。请先按下方提示安装。',
    );
  }

  static ReadinessItem _toolsItem(
      MediaToolsStatus? status, String operatingSystem) {
    if (status == null) {
      return const ReadinessItem(
          title: '视频处理组件',
          statusText: '检测中…',
          ready: false,
          checking: true);
    }
    if (status.isReady) {
      return const ReadinessItem(
          title: '视频处理组件', statusText: '已就绪', ready: true);
    }
    return ReadinessItem(
      title: '视频处理组件',
      statusText: '缺少 ${status.missingTools.join('、')}',
      ready: false,
      hint: operatingSystem == 'windows'
          ? '没有它就无法导入与分析素材。Windows 正式包本应内置这些组件，'
              '请重新安装从官方渠道取得的完整版本。'
          : '没有它就无法导入与分析素材。请在终端执行 brew install ffmpeg 安装，'
              '然后重启本应用。',
    );
  }

  static ReadinessItem _accountItem(MiaoaAccountStatus? status) {
    if (status == null) {
      return const ReadinessItem(
          title: 'miaoa 账号',
          statusText: '检测中…',
          ready: false,
          checking: true);
    }
    final failure = status.failure;
    if (failure != null) {
      // 读取失败与「没登录」是两回事，透出服务层已经分类好的中文提示
      return ReadinessItem(
          title: 'miaoa 账号',
          statusText: '读取失败',
          ready: false,
          hint: failure.message);
    }
    if (status.loggedIn) {
      final who = status.maskedAccount ?? '已登录账号';
      final tenant = status.tenantName;
      return ReadinessItem(
        title: 'miaoa 账号',
        statusText: tenant == null ? '已登录 $who' : '已登录 $who · $tenant',
        ready: true,
      );
    }
    return const ReadinessItem(
      title: 'miaoa 账号',
      statusText: '未登录',
      ready: false,
      hint: '未登录就读不到标签组，也检索不到候选素材。请在终端运行 '
          'miaoa auth login 完成登录（手机号 + 短信验证码）。',
    );
  }

  static ReadinessItem _credentialsItem(bool ready, bool debugBuild) => ready
      ? const ReadinessItem(
          title: '云端 AI 服务', statusText: '已配置', ready: true)
      : ReadinessItem(
          title: '云端 AI 服务',
          statusText: debugBuild ? '调试版不含' : '未配置',
          ready: false,
          // 凭据由打包注入，使用者自己配不了；让他去改配置只会白折腾。
          // 调试版本就不含凭据——如实说，别把人引去找同事重新打包
          hint: debugBuild
              ? '当前是开发调试版，本就不含云端 AI 凭据。日常使用请打开正式打包的版本。'
              : '缺少语音识别与画面打标所需的凭据，导入的素材无法自动分析。'
                  '请联系分发这个版本的同事重新打包。',
        );
}
