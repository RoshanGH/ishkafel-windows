import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';

/// 想做哪条线的活儿。**起点（有没有参考片）是线里面的事，不是第三条线**
enum WizardLine {
  /// 替换裂变：以片找片、换画面。工作页是工作台
  replace,

  /// 脚本成片：从台词造新片。工作页是编导台
  script,
}

/// 第 1 步：选一条线，再选起点。
///
/// **为什么是两层而不是四张卡并排**：本地文件和「不用原片从素材拼」不是
/// 两个模块，它们是替换裂变的两种起点——有参考片和没参考片，进去之后干的
/// 是同一件事。四张卡并列摆着等于告诉人这里有四种玩法，用户看着这个界面
/// 说的原话是「现在有三个可用模块，但其实两个就够了」。
///
/// miaoa 成片库是替换裂变的另一种「有参考」来源，本期未开放但保留并写清
/// 原因——项目清理过一个「点不动、没有任何解释」的死按钮，那种控件只会让
/// 用户反复点击并怀疑软件坏了。
class WizardSourceStep extends StatelessWidget {
  /// 选中的线。null = 还没选
  final WizardLine? line;

  final String? filePath;
  final bool pickingFile;
  final VoidCallback onPickFile;

  /// 选了「不用原片」这一路。此时 [filePath] 一定为 null
  final bool blank;
  final VoidCallback onPickBlank;


  /// 选线。null 时只展示（单测用）
  final void Function(WizardLine line)? onPickLine;

  const WizardSourceStep({
    super.key,
    this.line,
    this.onPickLine,
    required this.filePath,
    this.pickingFile = false,
    required this.onPickFile,
    this.blank = false,
    required this.onPickBlank,
  });

  static const miaoaChannelNote = '本期未开放：需要 miaoa 成片下载通道。'
      '请先把成片下载到本地，再用「本地文件」导入。';

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _lineCard(WizardLine.replace)),
              const SizedBox(width: AppSpacing.sm),
              Expanded(child: _lineCard(WizardLine.script)),
            ],
          ),
        ),
        if (line == WizardLine.replace) ...[
          const SizedBox(height: AppSpacing.md),
          const Text('从哪儿开始',
              style: TextStyle(
                  color: AppColors.textSecondary, fontSize: AppFontSize.caption)),
          const SizedBox(height: AppSpacing.xs),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _localCard()),
                const SizedBox(width: AppSpacing.sm),
                Expanded(child: _miaoaCard()),
                const SizedBox(width: AppSpacing.sm),
                Expanded(child: _blankCard()),
              ],
            ),
          ),
        ],
        if (line == WizardLine.script) ...[
          const SizedBox(height: AppSpacing.md),
          const Text('台词自己写，也可以进编导台后上传一条参考片、让它把台词扒出来',
              style: TextStyle(
                  color: AppColors.textSecondary, fontSize: AppFontSize.caption)),
        ],
      ],
    );
  }

  Widget _lineCard(WizardLine which) {
    final isReplace = which == WizardLine.replace;
    return _SourceCard(
      cardKey: Key(isReplace ? 'wizard-line-replace' : 'wizard-line-script'),
      icon: isReplace ? Icons.grid_view : Icons.edit_note,
      title: isReplace ? '替换裂变' : '脚本成片',
      description: isReplace
          ? '拿一条片子换画面，出多条；台词与节奏照原片'
          : '从台词造新片，配音配镜长出成片',
      selected: line == which,
      onTap: onPickLine == null ? null : () => onPickLine!(which),
    );
  }

  Widget _localCard() {
    final picked = filePath;
    return _SourceCard(
      cardKey: const Key('wizard-pick-local-file'),
      icon: Icons.folder_open,
      title: '本地文件',
      description: pickingFile
          ? '正在选择文件，请在系统窗口中选择或取消'
          : picked == null
              ? '点击选择 mp4 / mov 成片'
              : '${p.basename(picked)}\n点击可重新选择',
      selected: picked != null,
      onTap: pickingFile ? null : onPickFile,
    );
  }

  /// 没有参考成片、只知道要什么画面时走这条。分子手动加、标签手动填，
  /// 用标签搜出素材拼成新片
  Widget _blankCard() => _SourceCard(
        cardKey: const Key('wizard-blank-source'),
        icon: Icons.dashboard_customize_outlined,
        title: '不用原片，从素材拼',
        description: '手动加分子、打标签，用标签搜素材拼片',
        selected: blank,
        onTap: onPickBlank,
      );

  // 卡面只写短句（四卡一行，长文案会把整行撑高、把下方「重试」等按钮
  // 挤出折叠线）；完整原因悬停可见
  Widget _miaoaCard() => Tooltip(
        message: miaoaChannelNote,
        child: const _SourceCard(
          cardKey: Key('wizard-miaoa-source'),
          icon: Icons.link,
          title: 'miaoa 成片库',
          description: '本期未开放，请下载到本地再导入',
          selected: false,
          onTap: null,
        ),
      );
}

class _SourceCard extends StatelessWidget {
  final Key cardKey;
  final IconData icon;
  final String title;
  final String description;
  final bool selected;
  final VoidCallback? onTap;

  const _SourceCard({
    required this.cardKey,
    required this.icon,
    required this.title,
    required this.description,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return InkWell(
      key: cardKey,
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.accentBlue.withValues(alpha: 0.10)
              : AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
              color: selected ? AppColors.accentBlue : AppColors.border),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon,
                size: 20,
                color: disabled
                    ? AppColors.textTertiary
                    : AppColors.accentBlueLight),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          color: disabled
                              ? AppColors.textTertiary
                              : AppColors.textPrimary,
                          fontSize: AppFontSize.body,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: AppSpacing.xs),
                  Text(description,
                      style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: AppFontSize.caption,
                          height: 1.4)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
