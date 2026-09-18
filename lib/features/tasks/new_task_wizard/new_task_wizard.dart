import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../shared/scroll_fade.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/log/app_log.dart';
import '../../../core/miaoa/miaoa_failure.dart';
import '../../../core/miaoa/miaoa_tag_service.dart';
import '../../../core/models/project_ref.dart';
import '../../../core/models/tag_group_ref.dart';
import '../../../core/platform/windows_video_picker.dart';
import 'tag_group_field.dart';
import 'wizard_body.dart';
import 'wizard_source_step.dart';
import 'wizard_providers.dart';

/// 弹出新建任务向导；用户取消返回 null。
///
/// [prefillUnitGroups]/[prefillShotGroups] 与两层的打标约束都用上一条任务的
/// 配置预填：同一个项目里连着建好几条任务是常态，每次重选四个组、重贴两段
/// 约束纯属折磨。预填只是起点，用户照样能改。
Future<NewTaskWizardResult?> showNewTaskWizard(
  BuildContext context, {
  List<TagGroupRef> prefillUnitGroups = const [],
  List<TagGroupRef> prefillShotGroups = const [],
  String prefillUnitPrompt = '',
  String prefillShotPrompt = '',
  ProjectRef? prefillProject,
  ({String mode, String? filePath})? autoSubmit,
}) =>
    showDialog<NewTaskWizardResult>(
      context: context,
      builder: (_) => NewTaskWizard(
        prefillUnitGroups: prefillUnitGroups,
        prefillShotGroups: prefillShotGroups,
        prefillUnitPrompt: prefillUnitPrompt,
        prefillShotPrompt: prefillShotPrompt,
        prefillProject: prefillProject,
        autoSubmit: autoSubmit,
      ),
    );

/// 新建任务向导（模态）：① 选成片来源 ② 选两个标签组 → 开始分析
class NewTaskWizard extends ConsumerStatefulWidget {
  final List<TagGroupRef> prefillUnitGroups;
  final List<TagGroupRef> prefillShotGroups;
  final String prefillUnitPrompt;
  final String prefillShotPrompt;
  final ProjectRef? prefillProject;

  /// Agent 在驱动它：把来源选好、字段填好，然后**当着人的面点创建**。
  ///
  /// 为什么是真的走一遍向导而不是后台直接建：可视模式的意义就是让人
  /// 看见每一步。严格交付的活儿，前面走错一两步后面差很远——人得看着
  /// 它稳稳跑过很多次，才会放心切到静默模式
  final ({String mode, String? filePath})? autoSubmit;

  const NewTaskWizard({
    super.key,
    this.prefillUnitGroups = const [],
    this.prefillShotGroups = const [],
    this.prefillUnitPrompt = '',
    this.prefillShotPrompt = '',
    this.prefillProject,
    this.autoSubmit,
  });

  @override
  ConsumerState<NewTaskWizard> createState() => _NewTaskWizardState();
}

class _NewTaskWizardState extends ConsumerState<NewTaskWizard> {
  String? _filePath;
  bool _pickingFile = false;
  bool _filePickCancelled = false;
  VoidCallback? _cancelFileSelection;

  /// 走「不用原片，从素材拼」这一路
  bool _blank = false;
  bool _script = false;

  /// 选了哪条线。起点（有没有参考片）是线里面的事，不是第三条线
  WizardLine? _line;
  List<TagGroup>? _groups;
  String? _groupsError;
  late final List<TagGroupRef> _unitGroups = [...widget.prefillUnitGroups];
  late final List<TagGroupRef> _shotGroups = [...widget.prefillShotGroups];
  late ProjectRef? _project = widget.prefillProject;
  late String _unitPrompt = widget.prefillUnitPrompt;
  late String _shotPrompt = widget.prefillShotPrompt;
  TagPreview? _unitPreview;
  TagPreview? _shotPreview;

  @override
  void initState() {
    super.initState();
    _loadGroups();
    final auto = widget.autoSubmit;
    if (auto != null) {
      // 先把来源选上（人看得见选中了哪一个），停一拍再点创建——
      // 「唰」地一下闪过去等于没演
      _script = auto.mode == 'script';
      _blank = auto.mode == 'blank';
      _line = _script ? WizardLine.script : WizardLine.replace;
      _filePath = auto.filePath;
      _autoSubmitAfterGroups = true;
    }
  }

  /// 标签组一到位就自动提交（Agent 驱动时）。
  /// 要等它们加载完——没有标签组时创建按钮本来就是灰的
  bool _autoSubmitAfterGroups = false;

  void _maybeAutoSubmit() {
    if (!_autoSubmitAfterGroups || !mounted) return;
    if (_missing.isNotEmpty) return;
    _autoSubmitAfterGroups = false;
    // 停一拍：让人看清向导里填了什么，再看着它被提交
    Future<void>.delayed(const Duration(milliseconds: 700), () {
      if (mounted) _start();
    });
  }

  /// 拉标签组列表。失败只翻译成中文引导展示，**不自动重试**——401 自动重试
  /// 只会连续撞墙，403/404 重试也不会变好，都得用户自己去处理。
  ///
  /// 前提：只在「还没有任何标签组可选」时才可能被重新调用（重试按钮只出现在
  /// 失败/空列表两种状态，此时两个下拉根本没渲染，也就不可能已有选中项）。
  /// 若将来把重试入口挪到列表已加载之后，必须同时清掉新列表里不存在的选中项，
  /// 否则 DropdownButton 会因 value 不在 items 中而断言失败。
  Future<void> _loadGroups() async {
    setState(() {
      _groups = null;
      _groupsError = null;
    });
    try {
      final groups = await ref.read(miaoaTagServiceProvider).listGroups();
      if (!mounted) return;
      setState(() => _groups = groups);
      // Agent 驱动时：标签组到位了才谈得上创建
      _maybeAutoSubmit();
    } catch (e) {
      AppLog.warn('读取 miaoa 标签组失败：$e');
      if (!mounted) return;
      // 网关的异常自带可照做的中文（错误出口只此一份）；
      // 陌生异常才落到关键词兜底
      setState(() => _groupsError =
          e is MiaoaException ? e.message : miaoaFriendlyMessage(e));
    }
  }

  Future<void> _pickFile() async {
    if (_pickingFile) return;
    _cancelFileSelection = ref.read(videoFilePickerCancelProvider);
    _filePickCancelled = false;
    setState(() => _pickingFile = true);
    final elapsed = Stopwatch()..start();
    AppLog.info('video_picker phase=start');
    try {
      // 先呈现等待状态，再启动 Windows 独立选择进程或其他平台的系统窗口。
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || _filePickCancelled) return;
      AppLog.info('video_picker phase=invoke elapsedMs=${elapsed.elapsedMilliseconds}');
      final path = await ref.read(videoFilePickerProvider)();
      AppLog.info('video_picker phase=${path == null ? 'cancel' : 'success'} '
          'elapsedMs=${elapsed.elapsedMilliseconds}');
      if (path == null || !mounted || _filePickCancelled) return;
      setState(() {
        _filePath = path;
        _blank = false; // 选了本地文件就不再是空白任务
        _script = false;
      });
    } catch (e) {
      AppLog.warn('video_picker phase=error elapsedMs=${elapsed.elapsedMilliseconds} '
          'type=${e.runtimeType}');
      if (mounted && !_filePickCancelled) {
        _showSnackBar(e is VideoPickerException ? e.message : '打开文件选择框失败，请重试。');
      }
    } finally {
      if (mounted) setState(() => _pickingFile = false);
    }
  }

  void _cancelPickFile() {
    _filePickCancelled = true;
    _cancelFileSelection?.call();
  }

  @override
  void dispose() {
    if (_pickingFile) _cancelPickFile();
    super.dispose();
  }

  void _showSnackBar(String message) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

  void _selectUnitGroups(List<TagGroupRef> groups) {
    setState(() {
      _unitGroups
        ..clear()
        ..addAll(groups);
      _unitPreview = _mergedPreview(groups);
    });
  }

  void _selectShotGroups(List<TagGroupRef> groups) {
    setState(() {
      _shotGroups
        ..clear()
        ..addAll(groups);
      _shotPreview = _mergedPreview(groups);
    });
  }

  /// 只改约束、不改选中的组。
  ///
  /// 与 [_selectUnitGroups] 分开：那条路每次都要重算标签预览，而约束是逐字
  /// 敲进去的——每敲一个字重算一遍预览纯属白费，预览内容也压根没变。
  /// 选中若干组后的标签预览：把它们的标签合并去重——打标用的就是这份合并
  /// 后的受控词表，预览就该长成它实际的样子。
  ///
  /// 标签随组一起拉回来（`--include-tags`），所以纯本地算，不再往返。
  TagPreview _mergedPreview(List<TagGroupRef> groups) {
    if (groups.isEmpty) return const TagPreviewReady([]);
    final merged = <String>[];
    var anyMissing = false;
    for (final g in groups) {
      final found = _groups?.where((x) => x.id == g.id).firstOrNull;
      if (found == null || found.tags.isEmpty) {
        anyMissing = true;
        continue;
      }
      for (final t in found.tags) {
        if (!merged.contains(t)) merged.add(t);
      }
    }
    // 列表没带上标签（降级路径）时不谎报「这个组没有标签」
    if (merged.isEmpty && anyMissing) return const TagPreviewLoading();
    return TagPreviewReady(merged);
  }

  /// 还差哪些必填项；为空表示可以开始。
  ///
  /// 空白任务不需要原片，也**不需要镜头标签组**——它不分镜头。分子标签组
  /// 仍然必填：那是打标的受控词表，没有它后面挑素材时没有标签可用
  /// 脚本成片与空白任务一样不需要原片；镜头标签组也不必填
  /// （镜头层打标发生在参考分镜出现之后，届时用建任务时选的组）——
  /// 但为了检索质量，脚本成片允许选镜头组，仅分子组必填
  List<String> get _missing => [
        if (_pickingFile) '请先完成文件选择',
        // 顺序就是人该动手的顺序：先定线，再定起点，最后标签组
        if (_line == null) '先选一条线：替换裂变还是脚本成片',
        if (_line == WizardLine.replace && !_blank && _filePath == null)
          '选择本地成片文件，或选「不用原片」',
        if (_unitGroups.isEmpty) '选择台词语义单元标签组',
        if (!_blank && !_script && _shotGroups.isEmpty) '选择视觉镜头标签组',
      ];

  void _pickBlank() => setState(() {
        _blank = true;
        _script = false;
        _line = WizardLine.replace;
        _filePath = null;
      });

  void _pickScript() => setState(() {
        _script = true;
        _blank = false;
        _line = WizardLine.script;
        _filePath = null;
      });

  /// 选线。换线时把上一条线的起点清掉——留着会让「缺什么」算错，
  /// 也会让人以为上次选的文件还算数
  void _pickLine(WizardLine line) => setState(() {
        _line = line;
        _script = line == WizardLine.script;
        _blank = false;
        _filePath = null;
      });

  void _start() {
    if (_missing.isNotEmpty) return;
    Navigator.of(context).pop(NewTaskWizardResult(
        filePath: _filePath,
        script: _script,
        unitTagGroups: List.of(_unitGroups),
        shotTagGroups: List.of(_shotGroups),
        unitTagPrompt: _unitPrompt,
        shotTagPrompt: _shotPrompt,
        project: _project));
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.surfaceRaised,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg)),
      child: ConstrainedBox(
        // 高度**跟着屏幕走**，别写死 640：1440×900 的窗口里这个表单一屏
        // 放不下，最后一个输入框被底部说明压掉一半（2026-09-09 设计走查）。
        // 留一成给对话框外的余白，再封个顶——屏幕再高也不该拉成一长条
        constraints: BoxConstraints(
          maxWidth: 680,
          maxHeight: math.min(
              820, MediaQuery.sizeOf(context).height * 0.86),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _WizardHeader(_line),
              const SizedBox(height: AppSpacing.lg),
              Flexible(
                // 内容比对话框高时下沿压一层淡出：这里的表单一屏放不下
                // （真机上「视觉镜头的打标约束」那个输入框被底部说明压住了
                // 一半），而 macOS 的滚动条不动鼠标根本不出现
                // ——人不知道下面还有东西（2026-09-09 设计走查）
                child: ScrollFade(
                  background: AppColors.surfaceRaised,
                  child: SingleChildScrollView(
                  child: WizardBody(
                    filePath: _filePath,
                    pickingFile: _pickingFile,
                    onCancelFile: _cancelFileSelection == null ? null : _cancelPickFile,
                    line: _line,
                    onPickLine: _pickLine,
                    onPickFile: _pickFile,
                    blank: _blank,
                    onPickBlank: _pickBlank,
                    script: _script,
                    onPickScript: _pickScript,
                    groups: _groups,
                    groupsError: _groupsError,
                    onRetryGroups: _loadGroups,
                    unitGroups: _unitGroups,
                    shotGroups: _shotGroups,
                    unitPreview: _unitPreview,
                    shotPreview: _shotPreview,
                    onUnitGroupsChanged: _selectUnitGroups,
                    onShotGroupsChanged: _selectShotGroups,
                    unitPrompt: _unitPrompt,
                    shotPrompt: _shotPrompt,
                    // 不 setState：输入框自己管着文本，重建只会打断输入
                    onUnitPromptChanged: (v) => _unitPrompt = v,
                    onShotPromptChanged: (v) => _shotPrompt = v,
                    project: _project,
                    onProjectChanged: (p) => setState(() => _project = p),
                  ),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              WizardFooter(
                missing: _missing,
                // 空白任务建出来就能编，没有任何东西要分析
                startLabel: _script
                    ? '创建脚本成片'
                    : _blank
                        ? '创建拼片任务'
                        : '开始分析',
                // **只有替换裂变要跑分析**。脚本成片和拼片建出来直接进工作台，
                // 一次云端调用都没有——底下却写着「预计耗时数分钟，消耗云端
                // API 额度」，等于凭空吓人一跳（2026-09-09 设计走查）
                analyses: !_script && !_blank,
                onCancel: () => Navigator.of(context).pop(),
                onStart: _start,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WizardHeader extends StatelessWidget {
  const _WizardHeader(this.line);

  /// 还没选线时不预设标题——写死「新建替换裂变任务」的话，
  /// 人一进来就被告知要做哪条线，而这一步恰恰是让他选
  final WizardLine? line;

  String get title => switch (line) {
        WizardLine.replace => '新建替换裂变任务',
        WizardLine.script => '新建脚本成片任务',
        null => '新建任务',
      };

  String get subtitle => switch (line) {
        WizardLine.replace =>
          '选择成片来源与两个标签组，提交后自动完成：语音转写 → 台词语义单元切分与打标 → 视觉镜头切分与打标',
        WizardLine.script => '建出来直接进编导台开写；台词可以自己敲，也可以上传一条参考片让它扒出来',
        null => '先选一条线。替换裂变是拿现成的片子换画面，脚本成片是从台词造一条新的',
      };

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: AppFontSize.title,
                fontWeight: FontWeight.w700)),
        SizedBox(height: AppSpacing.xs),
        Text(subtitle,
            style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: AppFontSize.caption,
                height: 1.5)),
      ],
    );
  }
}
