import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/analysis/tag_vocabulary.dart';
import '../../core/models/project_ref.dart';
import '../../core/models/tag_group_ref.dart';
import '../../core/presentation/user_facing_error.dart';
import '../tasks/new_task_wizard/wizard_providers.dart';

/// 给一个分子打标签。
///
/// **标签只能从任务的标签组词表里选，不许手打**。手打的标签检索时一个都命中
/// 不了——「厨房场景」和「厨房情景」差一个字就是搜不搜得到的区别，而用户
/// 打完字看不出任何异常，要等搜不出素材才发现，那时也不知道是标签错了。
class BlankUnitTagEditor extends ConsumerStatefulWidget {
  final int unitIndex;
  final List<String> tags;
  final List<TagGroupRef> tagGroups;
  final ProjectRef? project;
  final ValueChanged<List<String>> onChanged;

  /// 测试注入；缺省走真实的 miaoa 命令行
  final TagVocabularySource? vocabulary;

  const BlankUnitTagEditor({
    super.key,
    required this.unitIndex,
    required this.tags,
    required this.tagGroups,
    required this.onChanged,
    this.project,
    this.vocabulary,
  });

  @override
  ConsumerState<BlankUnitTagEditor> createState() =>
      _BlankUnitTagEditorState();
}

class _BlankUnitTagEditorState extends ConsumerState<BlankUnitTagEditor> {
  List<String>? _words;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (widget.tagGroups.isEmpty) {
      setState(() => _words = const []);
      return;
    }
    // 走 provider 而不是 new 一个：绕过依赖注入的话，测试没法替换它，
    // 而它会真的去起一个 10 分钟超时的子进程
    final source = widget.vocabulary ??
        MiaoaTagVocabularySource(ref.read(miaoaTagServiceProvider));
    try {
      final all = <String>{};
      for (final group in widget.tagGroups) {
        all.addAll(await source.vocabularyOf(group.id));
      }
      if (!mounted) return;
      setState(() => _words = all.toList()..sort());
    } catch (e) {
      if (!mounted) return;
      // 拉不到词表不能变成一个空白面板——用户会以为这个标签组是空的
      setState(() => _error = userFacingError(e,
          fallback: '标签读取失败，请检查素材库登录状态后重试'));
    }
  }

  void _toggle(String tag) {
    final next = [...widget.tags];
    next.contains(tag) ? next.remove(tag) : next.add(tag);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        constraints: const BoxConstraints(maxHeight: 220),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('U${widget.unitIndex + 1} 的标签',
                    style: const TextStyle(
                        fontSize: AppFontSize.body,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary)),
                const SizedBox(width: AppSpacing.sm),
                const Expanded(
                  child: Text('标签就是下面搜素材的检索键',
                      style: TextStyle(
                          fontSize: AppFontSize.caption,
                          color: AppColors.textTertiary)),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Expanded(child: _body()),
          ],
        ),
      );

  Widget _body() {
    final error = _error;
    if (error != null) {
      return Row(
        children: [
          Expanded(
            child: Text(error,
                style: const TextStyle(
                    fontSize: AppFontSize.caption, color: AppColors.orange)),
          ),
          TextButton(
              onPressed: () => setState(() {
                    _error = null;
                    _load();
                  }),
              child: const Text('重试')),
        ],
      );
    }
    final words = _words;
    if (words == null) {
      return const Text('读取标签中…',
          style: TextStyle(
              fontSize: AppFontSize.caption, color: AppColors.textTertiary));
    }
    if (words.isEmpty) {
      return const Text(
        '这条任务没有可用的标签组，或者标签组里一个标签都没有。'
        '标签组在新建任务时定，多半是选错了企业或项目。',
        style: TextStyle(
            fontSize: AppFontSize.caption,
            height: 1.6,
            color: AppColors.orange),
      );
    }
    return SingleChildScrollView(
      child: Wrap(
        spacing: AppSpacing.xs,
        runSpacing: AppSpacing.xs,
        children: [
          for (final word in words)
            FilterChip(
              label: Text(word, style: const TextStyle(fontSize: 12)),
              selected: widget.tags.contains(word),
              onSelected: (_) => _toggle(word),
              showCheckmark: false,
              backgroundColor: AppColors.surfaceRaised,
              selectedColor: AppColors.accentBlue,
              side: const BorderSide(color: AppColors.border),
            ),
        ],
      ),
    );
  }
}
