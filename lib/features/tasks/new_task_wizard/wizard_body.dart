import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/miaoa/miaoa_tag_service.dart';
import '../../../core/models/project_ref.dart';
import '../../../core/models/tag_group_ref.dart';
import 'project_field.dart';
import 'tag_group_field.dart';
import 'tag_prompt_field.dart';
import 'wizard_source_step.dart';

/// 向导正文（两步），纯展示：状态与回调由 [NewTaskWizard] 持有
class WizardBody extends StatelessWidget {
  final String? filePath;
  final bool pickingFile;
  final VoidCallback? onCancelFile;

  /// 选了哪条线（替换裂变 / 脚本成片）
  final WizardLine? line;
  final void Function(WizardLine line)? onPickLine;
  final VoidCallback onPickFile;

  /// 走「不用原片，从素材拼」这一路
  final bool blank;
  final VoidCallback onPickBlank;
  final bool script;
  final VoidCallback onPickScript;

  /// null 表示标签组仍在读取中
  final List<TagGroup>? groups;

  /// 非 null 表示读取失败，内容已是面向用户的中文引导
  final String? groupsError;
  final VoidCallback onRetryGroups;

  final List<TagGroupRef> unitGroups;
  final List<TagGroupRef> shotGroups;
  final TagPreview? unitPreview;
  final TagPreview? shotPreview;
  final ValueChanged<List<TagGroupRef>> onUnitGroupsChanged;
  final ValueChanged<List<TagGroupRef>> onShotGroupsChanged;

  /// 两层各自的打标约束（一层一条）。与选组分开上抛，避免每敲一个字都重算
  /// 标签预览。
  final String unitPrompt;
  final String shotPrompt;
  final ValueChanged<String> onUnitPromptChanged;
  final ValueChanged<String> onShotPromptChanged;

  /// 在哪个项目里找素材（可不填）
  final ProjectRef? project;
  final ValueChanged<ProjectRef?> onProjectChanged;

  const WizardBody({
    super.key,
    required this.filePath,
    this.pickingFile = false,
    this.onCancelFile,
    this.line,
    this.onPickLine,
    this.blank = false,
    required this.onPickBlank,
    this.script = false,
    required this.onPickScript,
    required this.onPickFile,
    required this.groups,
    required this.groupsError,
    required this.onRetryGroups,
    required this.unitGroups,
    required this.shotGroups,
    required this.unitPreview,
    required this.shotPreview,
    required this.onUnitGroupsChanged,
    required this.onShotGroupsChanged,
    required this.unitPrompt,
    required this.shotPrompt,
    required this.onUnitPromptChanged,
    required this.onShotPromptChanged,
    required this.project,
    required this.onProjectChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _StepLabel('第 1 步 · 做哪条线'),
        IgnorePointer(
          ignoring: pickingFile,
          child: WizardSourceStep(
              filePath: filePath,
              pickingFile: pickingFile,
              line: line,
              onPickLine: onPickLine,
              onPickFile: onPickFile,
              blank: blank,
              onPickBlank: onPickBlank),
        ),
        if (pickingFile && onCancelFile != null)
          TextButton.icon(
            key: const Key('wizard-cancel-file'),
            onPressed: onCancelFile,
            icon: const Icon(Icons.close, size: 16),
            label: const Text('取消文件选择'),
          ),
        const SizedBox(height: AppSpacing.lg),
        const _StepLabel('第 2 步 · 项目与标签组（素材从哪儿来、按什么打标）'),
        // 项目在最上面：先定「上哪儿找素材」，再定「按什么打标」
        ProjectField(value: project, onChanged: onProjectChanged),
        const SizedBox(height: AppSpacing.md),
        _tagGroupSection(),
      ],
    );
  }

  Widget _tagGroupSection() {
    final error = groupsError;
    if (error != null) {
      return _NoticeBox(message: error, onRetry: onRetryGroups);
    }
    final list = groups;
    if (list == null) return const _LoadingBox();
    if (list.isEmpty) {
      return _NoticeBox(
        message: 'miaoa 里没有可用的标签组。没有标签组就无法打标，'
            '后续也检索不到候选素材。请先在 miaoa 后台建好标签组并添加标签，再回来新建任务。',
        onRetry: onRetryGroups,
      );
    }
    return Column(
      children: [
        TagGroupField(
          dropdownKey: const Key('wizard-unit-tag-group'),
          label: '台词语义单元标签组',
          hint: '选择用于台词打标的标签组（可多选）',
          groups: list,
          selected: unitGroups,
          onChanged: onUnitGroupsChanged,
          preview: unitPreview,
        ),
        // 选完组当场就能写约束，第一次打标就用得上；不然只能等打完一遍、
        // 进任务再改一遍重打
        if (unitGroups.isNotEmpty)
          TagPromptField(
            layer: 'unit',
            layerLabel: '台词语义单元',
            value: unitPrompt,
            onChanged: onUnitPromptChanged,
          ),
        const SizedBox(height: AppSpacing.md),
        TagGroupField(
          dropdownKey: const Key('wizard-shot-tag-group'),
          label: '视觉镜头标签组',
          hint: '选择用于画面打标的标签组（可多选）',
          groups: list,
          selected: shotGroups,
          onChanged: onShotGroupsChanged,
          preview: shotPreview,
        ),
        if (shotGroups.isNotEmpty)
          TagPromptField(
            layer: 'shot',
            layerLabel: '视觉镜头',
            value: shotPrompt,
            onChanged: onShotPromptChanged,
          ),
      ],
    );
  }
}

class _StepLabel extends StatelessWidget {
  final String text;
  const _StepLabel(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        child: Text(text,
            style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: AppFontSize.caption,
                fontWeight: FontWeight.w600)),
      );
}

class _LoadingBox extends StatelessWidget {
  const _LoadingBox();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
        child: Row(
          children: [
            SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: AppSpacing.sm),
            Text('正在从 miaoa 读取标签组…',
                style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: AppFontSize.caption)),
          ],
        ),
      );
}

/// 失败/空列表提示：一句人话 + 一个可执行动作
class _NoticeBox extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _NoticeBox({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.orange.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message,
              style: const TextStyle(
                  color: AppColors.orange,
                  fontSize: AppFontSize.caption,
                  height: 1.5)),
          const SizedBox(height: AppSpacing.sm),
          OutlinedButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}

/// 底部：耗时预期 + 禁用理由 + 取消/开始
class WizardFooter extends StatelessWidget {
  /// 还差哪些必填项；为空表示可以开始
  final List<String> missing;

  /// 主按钮文案。空白任务不分析——写「开始分析」是骗人的
  final String startLabel;
  final VoidCallback onCancel;
  final VoidCallback onStart;

  const WizardFooter({
    super.key,
    required this.missing,
    this.startLabel = '开始分析',
    this.analyses = true,
    required this.onCancel,
    required this.onStart,
  });

  /// 点下去要不要跑分析。脚本成片和拼片都是「建出来直接进工作台」，
  /// 一次云端调用都没有——那时候不该摆耗时和额度的说明
  final bool analyses;

  /// 耗时说明。
  ///
  /// 不给单一数字：耗时几乎全部取决于**镜头数**（画面打标是最慢的一步，
  /// 单个镜头约 18 秒、4 路并发），而镜头数在分析完成前无从知晓。原来写
  /// 的「1~2 分钟（96 秒素材实测）」是并发改造前的旧口径，同样长度的素材
  /// 实测要几分钟——界面上写一个做不到的数字，比不给预期更伤信任。
  static const durationNote = '预计耗时数分钟，消耗云端 API 额度';

  /// 展开说的那几句。放 tooltip：它们是「读一次就够」的话，
  /// 常驻两行小字会把上面的表单挤掉半个输入框（2026-09-09 设计走查）
  static const durationDetail = '耗时几乎全看镜头数——为每个视觉镜头打标签是最慢的'
      '一步，而镜头数要分析完才知道。\n'
      '分析过程中任务卡上会显示当前进行到哪一步；完成后进入「切分确认」。';

  @override
  Widget build(BuildContext context) {
    final ready = missing.isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!ready) _blockedReason(),
        Row(
          children: [
            Expanded(
              child: analyses
                  ? const Tooltip(
                      message: durationDetail,
                      child: Row(children: [
                        Icon(Icons.schedule,
                            size: 11, color: AppColors.textTertiary),
                        SizedBox(width: 4),
                        Flexible(
                          child: Text(durationNote,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: AppColors.textTertiary,
                                  fontSize: AppFontSize.micro)),
                        ),
                      ]),
                    )
                  : const Text('建出来直接进工作台，不跑分析',
                      style: TextStyle(
                          color: AppColors.textTertiary,
                          fontSize: AppFontSize.micro)),
            ),
            TextButton(onPressed: onCancel, child: const Text('取消')),
            const SizedBox(width: AppSpacing.sm),
            FilledButton(
              key: const Key('wizard-start-btn'),
              onPressed: ready ? onStart : null,
              child: Text(startLabel),
            ),
          ],
        ),
      ],
    );
  }

  /// 禁用按钮必须说清「还差什么」与「不选的后果」，否则用户只会反复点它
  Widget _blockedReason() => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        child: Text(
          '还需要：${missing.join('、')}。'
          '标签是后续「按相同标签检索候选素材」的唯一依据，不选就没有候选素材可用。',
          style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: AppFontSize.caption,
              height: 1.5),
        ),
      );
}
