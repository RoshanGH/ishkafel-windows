import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/build_mode.dart';
import '../../core/ffmpeg/media_tools_locator.dart';
import 'task_list_controller.dart';

/// 运行环境探测结果：null 表示尚未探测（测试或未接线场景），不展示横幅；
/// main.dart 启动时用真实 preflight 结果 override。
final mediaToolsStatusProvider = Provider<MediaToolsStatus?>((ref) => null);

/// 常驻提示横幅：环境类问题不能只写日志或弹一次性 SnackBar，
/// 必须在列表页持续可见，用户才知道该去做什么。
class NoticeBanner extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String message;

  /// 可选的行动按钮（如「重试」）；两者必须同时给出才会渲染
  final String? actionLabel;
  final VoidCallback? onAction;

  const NoticeBanner({
    super.key,
    required this.icon,
    required this.color,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final label = actionLabel;
    final action = onAction;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 0),
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                  fontSize: AppFontSize.body,
                  height: 1.4,
                  color: AppColors.textPrimary),
            ),
          ),
          if (label != null && action != null) ...[
            const SizedBox(width: AppSpacing.sm),
            TextButton(
              onPressed: action,
              style: TextButton.styleFrom(
                foregroundColor: color,
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md, vertical: AppSpacing.xs),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(label,
                  style: const TextStyle(
                      fontSize: AppFontSize.body, fontWeight: FontWeight.w600)),
            ),
          ],
        ],
      ),
    );
  }
}

/// 列表页顶部的环境提示区：把「装不了/跑不了」的前置条件常驻展示
class EnvironmentBanners extends ConsumerWidget {
  const EnvironmentBanners({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mediaTools = ref.watch(mediaToolsStatusProvider);
    // 依赖列表状态刷新（装载完成后才知道跳过了几个文件）
    final loaded = ref.watch(taskListProvider).hasValue;
    final skipped = loaded
        ? ref.read(taskListProvider.notifier).skippedTaskFileCount
        : 0;
    final banners = <Widget>[
      if (mediaTools != null && !mediaTools.isReady)
        NoticeBanner(
          icon: Icons.error_outline,
          color: AppColors.red,
          message: missingMediaToolsBannerText(mediaTools.missingTools),
        ),
      if (ref.watch(analysisPipelineProvider) == null)
        NoticeBanner(
          icon: Icons.info_outline,
          color: AppColors.orange,
          message: analysisMissingBannerText(),
        ),
      if (skipped > 0)
        NoticeBanner(
          icon: Icons.warning_amber_rounded,
          color: AppColors.orange,
          message: '有 $skipped 个任务文件无法读取，已跳过（它们不会显示在下方列表里）。'
              '如果发现任务缺失，请联系维护者检查数据目录。',
        ),
    ];
    if (banners.isEmpty) return const SizedBox.shrink();
    return Column(mainAxisSize: MainAxisSize.min, children: banners);
  }
}

String missingMediaToolsBannerText(
  List<String> missingTools, {
  String? operatingSystem,
}) {
  final prefix = '未检测到视频处理组件（${missingTools.join('、')}），导入与分析都无法进行。';
  return (operatingSystem ?? Platform.operatingSystem) == 'windows'
      ? '$prefix Windows 正式包本应内置这些组件，请重新安装完整版本。'
      : '$prefix 请在终端执行 brew install ffmpeg 安装后重启本应用。';
}

/// AI 分析不可用时的横幅文案。
/// 调试构建天生不带凭据——如实说，别把用户引去「补齐凭据」；
/// 正式包缺凭据才是真的打包问题（测试注入 [debugBuild]：
/// flutter test 的 VM 永远是 debug 模式）
String analysisMissingBannerText({bool debugBuild = isDebugBuild}) =>
    debugBuild
        ? '当前是开发调试版（不含云端 AI 凭据与内置命令行工具），'
            '仅供开发验证。日常使用请打开正式打包的版本。'
        : '尚未配置 AI 服务（语音识别与语义切分），导入的素材无法自动分析。'
            '请补齐凭据后重启应用，再对任务点「重新分析」。';
