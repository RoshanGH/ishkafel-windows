import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/diagnostics/environment_report.dart';
import '../../../core/diagnostics/tool_installer.dart';
import '../agent_skill_card.dart';
import '../cli_install_card.dart';
import '../tool_install_panel.dart';
import '../settings_providers.dart';
import '../settings_widgets.dart';

String environmentPathExplanation({String? operatingSystem}) {
  final os = operatingSystem ?? Platform.operatingSystem;
  if (os == 'windows') {
    return '这几个命令行工具负责转码、抽帧与素材检索。路径由应用自己探测——'
        '从开始菜单启动的 Windows 程序可能拿不到 PowerShell 中刚更新的 PATH，'
        '所以“PowerShell 里能用”不等于这里能用。';
  }
  return '这几个命令行工具负责转码、抽帧与素材检索。路径由应用自己探测——'
      'macOS 从访达启动的程序拿不到终端里的 PATH，'
      '所以“终端里能用”不等于这里能用。';
}

/// 运行环境分区：外部工具的**真实解析路径** + 云端凭据是否齐全。
///
/// 存在的理由：macOS 上 GUI 启动的进程 PATH 里没有 Homebrew 目录，
/// ffmpeg「明明装了」却调不起来——本项目反复踩过。把路径摆在界面上，
/// 用户和排查问题的人一眼就能确认到底找没找到。
class EnvironmentSection extends ConsumerWidget {
  const EnvironmentSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final report = ref.watch(environmentReportProvider);
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.xl),
      children: [
        report.when(
          loading: () => const SettingsCard(
              children: [SettingsRow(label: '体检', value: '检测中…')]),
          error: (_, _) => SettingsCard(children: [
            SettingsErrorBlock(
                message: '运行环境体检失败，请点「重试」。',
                onRetry: () => refreshToolProbes(ref)),
          ]),
          data: (data) => data == null
              ? const SettingsCard(children: [
                  SettingsNote('本次运行未开启环境体检（通常只发生在测试环境）。')
                ])
              : _Report(report: data, onRefresh: () => refreshToolProbes(ref)),
        ),
        // 摆在体检结果**外面**：命令行工具跟体检没有依赖关系，体检失败或
        // 没开启时，这张卡片不该跟着一起消失
        const CliInstallCard(),
        const AgentSkillCard(),
      ],
    );
  }
}

class _Report extends StatelessWidget {
  final EnvironmentReport report;
  final VoidCallback onRefresh;

  const _Report({required this.report, required this.onRefresh});

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SettingsCard(
            title: '本地工具',
            children: [
              for (final tool in report.tools) _ToolRow(tool: tool),
              SettingsNote(environmentPathExplanation()),
              const SizedBox(height: AppSpacing.sm),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton(
                    onPressed: onRefresh, child: const Text('重新检测')),
              ),
            ],
          ),
          SettingsCard(
            title: '云端 AI 服务',
            children: [
              SettingsRow(
                label: '凭据',
                content: StatusDot(
                    ok: report.credentialsReady,
                    text: report.credentialsReady ? '已配置' : '未配置'),
              ),
              SettingsNote(report.credentialsHint ??
                  '语音识别与画面打标所需的凭据已随版本打包，使用者无需配置。'),
            ],
          ),
        ],
      );
}

class _ToolRow extends ConsumerWidget {
  /// 这个工具的安装面板；没有配方（或没接安装器）时不显示
  final ToolHealth tool;

  const _ToolRow({required this.tool});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              // 108 而不是 84：`audio-separator` 在 84 里会折成两行
              // 「audio-」「separator」，和上面几行的基线全错开
              // （2026-09-09 设计走查）
              width: 108,
              child: Text(tool.name,
                  style: const TextStyle(
                      fontSize: AppFontSize.body,
                      color: AppColors.textSecondary)),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  StatusDot(
                      ok: tool.installed, text: tool.installed ? '已就绪' : '未安装'),
                  const SizedBox(height: AppSpacing.xs),
                  if (tool.path != null)
                    SelectableText(tool.path!,
                        style: TextStyle(
                            fontSize: AppFontSize.caption,
                            fontFamily: platformMonospaceFontFamily,
                            color: AppColors.textTertiary)),
                  if (tool.version != null)
                    Text(tool.version!,
                        style: const TextStyle(
                            fontSize: AppFontSize.caption,
                            color: AppColors.textTertiary)),
                  if (tool.hint != null)
                    Text(tool.hint!,
                        style: const TextStyle(
                            fontSize: AppFontSize.caption,
                            height: 1.6,
                            color: AppColors.orange)),
                  // 没装就地给一个能点的按钮。只把「请在终端执行……」摆出来
                  // 是让用户离开这个 app 去敲命令，再回来重启——到 C 软件不该这样
                  if (!tool.installed) ...[
                    const SizedBox(height: AppSpacing.sm),
                    ?_installPanel(ref),
                  ],
                ],
              ),
            ),
          ],
        ),
      );

  Widget? _installPanel(WidgetRef ref) {
    final recipe = InstallRecipes.forTool(tool.name);
    final installer = ref.watch(toolInstallerProvider);
    if (recipe == null || installer == null) return null;
    return ToolInstallPanel(
      recipe: recipe,
      installer: installer,
      // 装好了立刻重新体检——不让用户自己去猜「现在算装上了吗」
      onInstalled: () => refreshToolProbes(ref),
    );
  }
}
