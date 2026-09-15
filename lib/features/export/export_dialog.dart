import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/export/diverse_pick.dart';
import '../../core/replacement/picked_material.dart';
import '../../core/export/subtitle_coverage.dart';
import '../../core/replacement/brand_consistency.dart';
import '../picking/burned_text_warning.dart';
import '../../core/export/export_spec.dart';
import 'export_options_panel.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;

import '../../core/models/export_record.dart';
import '../../core/platform/platform_paths.dart';
import '../../core/platform/platform_shell.dart';


import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/audio/voice_plan.dart';
import '../../core/analysis/providers.dart' show AsrSentence;
import '../../core/audio/bgm_plan.dart';
import '../../core/audio/material_audio.dart';
import '../../core/audio/source_audio.dart';
import '../../core/export/export_plan.dart';
import '../../core/export/export_runner.dart';
import '../../core/subtitle/subtitle_style.dart';
import '../../core/subtitle/subtitle_track.dart';
import '../../core/models/semantic_unit.dart';
import '../../core/replacement/replacement_plan.dart';

/// 造一个能干活的导出器（真实 ffmpeg + 真实下载）。
/// 缺省为 null，由 main.dart 按数据目录装配；测试注入假实现。
typedef ExportRunnerFactory = ExportRunner Function(
    String taskId, SubtitleStyle subtitle);

final exportRunnerFactoryProvider =
    Provider<ExportRunnerFactory?>((ref) => null);

/// 矩阵导出面板：先看清要导出什么，再开始；跑起来之后有进度、有失败清单。
Future<void> showExportDialog(
  BuildContext context, {
  required String taskId,
  required String taskName,
  required String? sourcePath,
  required List<SemanticUnit> units,
  required List<UnitReplacement> replacements,
  BgmPlan bgm = BgmPlan.empty,
  Map<String, String> voiceAudio = const {},
  VoicePlan voices = VoicePlan.empty,

  /// 分离出来的纯人声轨：被配乐覆盖的段落要用它
  String? vocalsPath,

  /// 句级转写：镜头替换的切片上重渲台词字幕用（空 = 不渲）
  List<AsrSentence> subtitleSentences = const [],

  /// 字幕烧成什么样。**素材自带烧录字幕时人会切成底条/毛玻璃来遮挡**，
  /// 不传下去的话那个设置等于白设
  SubtitleStyle subtitleStyle = SubtitleStyle.standard,
  required Directory outputDir,

  /// 让用户挑一个目录；返回 null 表示他取消了。注入而不是内建：单测不弹系统框
  Future<String?> Function()? pickDirectory,

  /// 在系统文件管理器里显示这个目录
  Future<void> Function(String path)? revealDirectory,

  /// 导完之后把这一次记进项目（哪天、导了几条、成了几条、在哪儿）
  Future<void> Function(ExportRecord record)? onExported,

  /// 记录导出时刻。测试注入可控时钟
  DateTime Function()? now,

  /// 这个项目以前导过哪几次。摆在确认页上——正要导之前，先看看上次导到
  /// 哪儿、导了几条
  List<ExportRecord> exports = const [],

  /// 候选素材各有多长（候选 id → 毫秒）。整体替换的成片时长靠它算
  Map<int, int> materialDurations = const {},
  List<PickedMaterial> pickedMaterials = const [],

  /// 「保留素材原声」的全片打底设置（单个镜头可覆盖）
  MaterialAudioSetting materialAudio = MaterialAudioSetting.off,

  /// 原片帧率：导出规格的默认值跟着它走，选到别的档位时会提示
  double sourceFps = 0,

  /// 「原片这一镜的声音」的全片打底 + 分离出来的背景音轨。
  /// 少传任何一个，人在属性面板里设的那一档就只在预览里生效、导出时消失
  SourceAudioSetting sourceAudio = SourceAudioSetting.auto,
  String? backgroundPath,

  /// **手改过的**字幕。不传下去的话，人在属性面板改完，导出烧的还是按 ASR
  /// 现算的那一份——而这件事只有把片子导出来看一眼才发现（2026-09-08 真机）
  SubtitleTrack subtitleTrack = const SubtitleTrack.empty(),
}) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ExportDialog(
        taskId: taskId,
        taskName: taskName,
        sourcePath: sourcePath,
        subtitleSentences: subtitleSentences,
        subtitleStyle: subtitleStyle,
        sourceFps: sourceFps,
        materialAudio: materialAudio,
        sourceAudio: sourceAudio,
        backgroundPath: backgroundPath,
        subtitleTrack: subtitleTrack,
        units: units,
        replacements: replacements,
        bgm: bgm,
        voiceAudio: voiceAudio,
        voices: voices,
        vocalsPath: vocalsPath,
        outputDir: outputDir,
        pickDirectory: pickDirectory ?? pickExportDirectory,
        revealDirectory: revealDirectory ?? revealInFileManager,
        onExported: onExported,
        now: now ?? DateTime.now,
        exports: exports,
        materialDurations: materialDurations,
        pickedMaterials: pickedMaterials,
      ),
    );

/// 系统目录选择框
Future<String?> pickExportDirectory() => getDirectoryPath(
    confirmButtonText: '导出到这里', initialDirectory: _defaultInitialDir());

String? _defaultInitialDir() {
  try {
    return PlatformPaths().videosDirectory;
  } on StateError {
    return null;
  }
}

/// 把家目录缩成 `~`。导出路径通常很长，全写出来会把这一行挤没
String shortenPath(String path) {
  try {
    final home = PlatformPaths().userHome;
    if (!path.startsWith(home)) return path;
    return '~${path.substring(home.length)}';
  } on StateError {
    return path;
  }
}

/// 在系统文件管理器里显示，路径直接传给进程 API，不经过命令行解释。
Future<void> revealInFileManager(String path) async {
  await PlatformShell().openPath(path);
}

class _ExportDialog extends ConsumerStatefulWidget {
  final String taskId;
  final String taskName;
  /// 为 null 表示空白任务：所有段落都来自素材，没有原片可切
  final String? sourcePath;
  final List<SemanticUnit> units;
  final List<UnitReplacement> replacements;
  final BgmPlan bgm;
  final Map<String, String> voiceAudio;
  final VoicePlan voices;
  final String? vocalsPath;
  final List<AsrSentence> subtitleSentences;

  /// 「保留素材原声」的全片打底设置——不带进来的话，界面上改了导出还是老样子
  final double sourceFps;
  final MaterialAudioSetting materialAudio;
  final SourceAudioSetting sourceAudio;
  final String? backgroundPath;

  /// **手改过的**字幕（见 [SubtitleTrack]）
  final SubtitleTrack subtitleTrack;
  final SubtitleStyle subtitleStyle;
  final Directory outputDir;
  final Future<String?> Function() pickDirectory;
  final Future<void> Function(String path) revealDirectory;
  final Future<void> Function(ExportRecord record)? onExported;

  /// 记录导出时刻。测试注入可控时钟
  final DateTime Function() now;
  final List<ExportRecord> exports;

  /// 候选素材各有多长（候选 id → 毫秒）。整体替换的成片时长靠它算
  final Map<int, int> materialDurations;

  /// 已挑素材的落地信息。**挑「差异最大的几条」靠它**——判断两条素材像不像，
  /// 看的是名字（同一批拍摄的同前缀）和画面描述
  final List<PickedMaterial> pickedMaterials;

  const _ExportDialog({
    required this.taskId,
    required this.taskName,
    required this.sourcePath,
    required this.units,
    required this.replacements,
    required this.bgm,
    required this.voiceAudio,
    required this.voices,
    required this.vocalsPath,
    this.subtitleSentences = const [],
    this.sourceFps = 0,
    this.materialAudio = MaterialAudioSetting.off,
    this.sourceAudio = SourceAudioSetting.auto,
    this.backgroundPath,
    this.subtitleTrack = const SubtitleTrack.empty(),
    this.subtitleStyle = SubtitleStyle.standard,
    required this.outputDir,
    required this.pickDirectory,
    required this.revealDirectory,
    this.onExported,
    this.now = DateTime.now,
    this.exports = const [],
    this.materialDurations = const {},
    this.pickedMaterials = const [],
  });

  @override
  ConsumerState<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends ConsumerState<_ExportDialog> {
  bool _running = false;

  /// 导到哪儿。可以在开始之前改
  late Directory _outputDir = widget.outputDir;

  /// 这个项目导过哪几次。跑完会把这一次追加进来，用户当场就能看到
  late List<ExportRecord> _exports = List.of(widget.exports);
  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  (int done, int total, String what)? _progress;

  /// 当前这一条是什么时候开始的、上一条花了多久。
  ///
  /// 2026-09-10 真机走查：合成一条 75 秒的片子要二十几秒，而进度只在
  /// 「条」这个粒度跳——屏幕上「0/2 · 第 1 条」二十几秒纹丝不动，
  /// 人分不清是在跑还是卡死了。ffmpeg 的逐帧进度要改子进程执行器才拿得到，
  /// 而「这条已经跑了多久 / 上一条跑了多久」零成本就能说，
  /// 足够让人看出它在动、也大致知道还要等多久。
  DateTime? _stepStartedAt;
  Duration? _lastStepTook;
  int? _lastStepIndex;
  Timer? _tick;

  /// 把 done 的变化翻译成「上一条用了多久、这一条从什么时候开始」
  void _markStep(int done) {
    if (_lastStepIndex == done) return;
    final now = DateTime.now();
    if (_lastStepIndex != null && _stepStartedAt != null) {
      _lastStepTook = now.difference(_stepStartedAt!);
    }
    _lastStepIndex = done;
    _stepStartedAt = now;
  }

  /// 这一条已经跑了多久（跑完了就不再计时）
  String? get _elapsedText {
    final at = _stepStartedAt;
    if (at == null || !_running) return null;
    final secs = DateTime.now().difference(at).inSeconds;
    final tail = _lastStepTook == null
        ? ''
        : '（上一条用了 ${_lastStepTook!.inSeconds} 秒）';
    return '已用 $secs 秒$tail';
  }
  List<ExportOutcome>? _results;
  String? _failure;

  /// 出多大多清楚。记住上次的选择——同一个项目连着导好几次是常态
  /// 默认跟着原片帧率走——时间线是按原片帧率数帧的，导出默认写死 30
  /// 等于让「你数的帧」和「导出来的帧」默认就不是一回事
  late ExportSpec _spec = ExportSpec.followingSource(widget.sourceFps);

  /// null = 全部导出；否则只挑这么多条差异最大的
  int? _pickCount;

  /// 真正要导的那几条：全部，或者挑出来的
  List<ExportCombination> get _selected => _pickCount == null
      ? _combos
      : pickDiverse(_combos,
          count: _pickCount!, materials: widget.pickedMaterials);

  late final List<ExportCombination> _combos = ExportPlanner.enumerate(
      units: widget.units,
      replacements: widget.replacements,
      materialDurations: widget.materialDurations);

  Future<void> _start() async {
    // 手动加的单元原片上没有它，没挑素材就是**真的缺一段**。让它跑下去，
    // 导出那边会当成「用原片这一段」——出来的是空白或者直接崩在 ffmpeg 里，
    // 而人要等整批片子导完才发现。停下来点名，不许拿黑帧顶上
    final empty = unitsWithNothingToShow(widget.units, widget.replacements);
    if (empty.isNotEmpty) {
      setState(() => _failure =
          '${empty.map((i) => 'U${i + 1}').join('、')} 还没挑素材。'
          '这些单元是手动加的，原片里没有对应画面，不挑就没东西可放。');
      return;
    }
    final factory = ref.read(exportRunnerFactoryProvider);
    if (factory == null) {
      setState(() => _failure = '未检测到 ffmpeg，无法合成成片。装好后重启应用再试');
      return;
    }
    setState(() {
      _running = true;
      _markStep(0);
      // 秒级重绘，让「已用 N 秒」真的走起来
      _tick?.cancel();
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted && _running) setState(() {});
      });
      _failure = null;
      _progress = (0, _selected.length, '准备中');
    });
    try {
      final chosen = _selected;
      final runner = factory(widget.taskId, widget.subtitleStyle);
      // 挑了几条就只导那几条，不再重新做笛卡尔积
      final results = _pickCount == null
          ? await runner.exportAll(
        spec: _spec,
        sourcePath: widget.sourcePath,
        units: widget.units,
        replacements: widget.replacements,
        outputDir: _outputDir,
        bgm: widget.bgm,
        voiceAudio: widget.voiceAudio,
        voices: widget.voices,
        vocalsPath: widget.vocalsPath,
        subtitleSentences: widget.subtitleSentences,
        materialAudio: widget.materialAudio,
        sourceAudio: widget.sourceAudio,
        backgroundPath: widget.backgroundPath,
        subtitleTrack: widget.subtitleTrack,
        onProgress: (d, t, w) {
          if (mounted) {
            setState(() {
              _markStep(d);
              _progress = (d, t, w);
            });
          }
        },
      )
          : await runner.exportCombinations(
              combos: chosen,
              spec: _spec,
              sourcePath: widget.sourcePath,
              units: widget.units,
              replacements: widget.replacements,
              outputDir: _outputDir,
              bgm: widget.bgm,
              voiceAudio: widget.voiceAudio,
              voices: widget.voices,
              vocalsPath: widget.vocalsPath,
              subtitleSentences: widget.subtitleSentences,
              materialAudio: widget.materialAudio,
              sourceAudio: widget.sourceAudio,
              backgroundPath: widget.backgroundPath,
              subtitleTrack: widget.subtitleTrack,
              onProgress: (d, t, w) {
                if (mounted) {
            setState(() {
              _markStep(d);
              _progress = (d, t, w);
            });
          }
              },
            );
      if (!mounted) return;
      setState(() => _results = results);
      // 记进项目：项目没有终态，**导出才是那件有始有终的事**
      final record = ExportRecord(
        at: widget.now(),
        total: results.length,
        succeeded: results.where((r) => r.ok).length,
        outputDir: _outputDir.path,
      );
      setState(() => _exports = [..._exports, record]);
      await widget.onExported?.call(record);
    } catch (e) {
      if (mounted) setState(() => _failure = '导出失败：$e');
    } finally {
      _tick?.cancel();
      _tick = null;
      if (mounted) setState(() => _running = false);
    }
  }

  /// 换导出目录。取消（返回 null）就保持原样——不要把选择框一关就把
  /// 已经填好的位置清掉
  Future<void> _pickDir() async {
    final picked = await widget.pickDirectory();
    if (picked == null || !mounted) return;
    setState(() => _outputDir = Directory(picked));
  }

  /// 在访达里显示这个目录。导完不知道片子在哪，等于没导
  Future<void> _reveal() => _revealPath(_outputDir.path);

  Future<void> _revealPath(String path) async {
    try {
      await widget.revealDirectory(path);
    } catch (e) {
      if (!mounted) return;
      setState(() => _failure = '打不开这个目录：$e');
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        backgroundColor: AppColors.surfaceRaised,
        title: const Text('矩阵导出'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _summary(),
                const SizedBox(height: AppSpacing.md),
                ExportOptionsPanel(
                  spec: _spec,
                  onSpecChanged: (next) => setState(() => _spec = next),
                  totalCombos: _combos.length,
                  pickCount: _pickCount,
                  onPickCountChanged: (n) => setState(() => _pickCount = n),
                  durationMs: _combos.isEmpty ? 0 : _combos.first.durationMs,
                  sourceFps: widget.sourceFps,
                  enabled: !_running,
                ),
                if (_pickCount != null) ...[
                  const SizedBox(height: AppSpacing.md),
                  _pickBreakdown(),
                ],
                if (_failure case final f?) ...[
                  const SizedBox(height: AppSpacing.md),
                  // **可以选中复制**：导出失败时这段话里带着 ffmpeg 的原文，
                  // 人要把它贴给我们才说得清出了什么事。不能选的错误信息
                  // 等于让人对着屏幕手抄（2026-09-09 设计走查）
                  SelectableText(f,
                      style: const TextStyle(
                          color: AppColors.red, fontSize: AppFontSize.body)),
                ],
                if (_progress case final p? when _running) ...[
                  const SizedBox(height: AppSpacing.md),
                  LinearProgressIndicator(
                      value: p.$2 == 0 ? null : p.$1 / p.$2,
                      color: AppColors.accentBlue,
                      backgroundColor: AppColors.surface),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                      [
                        '${p.$1}/${p.$2} · ${p.$3}',
                        ?_elapsedText,
                      ].join(' · '),
                      key: const Key('export-progress'),
                      style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: AppFontSize.caption)),
                ],
                if (_results case final r?) ...[
                  const SizedBox(height: AppSpacing.md),
                  _resultList(r),
                ],
                _history(),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            key: const Key('export-close'),
            onPressed: _running ? null : () => Navigator.of(context).pop(),
            child: Text(_results == null ? '取消' : '关闭'),
          ),
          // 导完了先给「打开目录」，再给「关闭」——用户此刻要的是去看片子，
          // 而不是把这个框关掉之后再自己找
          if (_results != null)
            FilledButton(
              key: const Key('export-reveal'),
              onPressed: _reveal,
              child: Text(PlatformShell().revealLabel),
            ),
          if (_results == null)
            FilledButton(
              key: const Key('export-start'),
              onPressed: _running || _combos.isEmpty ? null : _start,
              child: Text(_running ? '导出中…' : '开始导出'),
            ),
        ],
      );

  /// 24 条是怎么来的：每个挑了多条候选的位置各自的候选数相乘。
  /// 算式直接写出来，不让用户对着一个总数自己猜
  String? get _comboBreakdown {
    final parts = <(int factor, String where)>[];
    for (var i = 0; i < widget.replacements.length; i++) {
      final r = widget.replacements[i];
      switch (r.mode) {
        case ReplacementMode.whole:
          if (r.wholeCandidateIds.length > 1) {
            parts.add((r.wholeCandidateIds.length, 'U${i + 1}'));
          }
        case ReplacementMode.perShot:
          for (final e in r.shotCandidateIds.entries) {
            if (e.value.length > 1) {
              parts.add((e.value.length, 'U${i + 1} 的 S${e.key + 1}'));
            }
          }
        case ReplacementMode.keepOriginal:
          break;
      }
    }
    if (parts.length < 2) return null; // 单因子或没得乘，总数自明
    final raw = parts.fold<int>(1, (acc, p) => acc * p.$1);
    final formula = parts.map((p) => '${p.$1}').join(' × ');
    final who = parts.map((p) => '${p.$2} 挑了 ${p.$1} 条').join('、');
    // 去重会让实际条数少于乘积：同一条素材在一条成片里出现两次的组合
    // 被丢掉了。**等号两边必须对得上**——写 2×4×2×3 = 24 是在羞辱读者
    if (raw == _combos.length) {
      return '$formula = ${_combos.length}（$who，每条成片各取一条组合）';
    }
    return '$formula = $raw，去掉同一条素材出现两次的 ${raw - _combos.length} 条，'
        '剩 ${_combos.length} 条（$who；有几个位置挑了相同的素材）';
  }

  /// 一条都排不出来时说清为什么。
  ///
  /// 「共 0 条成片」+ 一个灰掉的导出按钮，是这个对话框最糟的一种状态：
  /// 人不知道自己做错了什么，也不知道回去改哪儿（2026-09-09 设计走查真机）。
  String? get _nothingToExportReason {
    if (_combos.isNotEmpty) return null;
    final clashes =
        ExportPlanner.materialsUsedTwice(widget.replacements);
    if (clashes.isEmpty) return null;
    final lines = [
      for (final entry in clashes.entries)
        '素材 ${entry.key} 同时用在 ${entry.value.join('、')}',
    ];
    return '排不出成片：一条成片里不能出现同一条素材两次，'
        '而现在每一种排法都会撞上。\n${lines.join('\n')}\n'
        '在其中一处换一条素材就好了。';
  }

  Widget _summary() {
    final replaced = _combos.where((c) => c.replacedCount > 0).length;
    final seconds =
        (_combos.isEmpty ? 0 : _combos.first.durationMs) / 1000;
    if (_nothingToExportReason case final reason?) {
      return Container(
        key: const Key('export-nothing-reason'),
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: AppColors.orange.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: AppColors.orange.withValues(alpha: 0.4)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.error_outline, color: AppColors.orange, size: 16),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(reason,
                style: const TextStyle(
                    color: AppColors.orange,
                    fontSize: AppFontSize.body,
                    height: 1.5)),
          ),
        ]),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
            _pickCount == null
                ? '共 ${_combos.length} 条成片 · 每条约 ${seconds.toStringAsFixed(1)}s'
                : '${_combos.length} 条组合里挑 ${_selected.length} 条 · '
                    '每条约 ${seconds.toStringAsFixed(1)}s',
            key: const Key('export-summary'),
            style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: AppFontSize.emphasis,
                fontWeight: FontWeight.w600)),
        if (_comboBreakdown case final breakdown?) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(breakdown,
              key: const Key('export-combo-breakdown'),
              style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: AppFontSize.caption,
                  height: 1.5)),
        ],
        const SizedBox(height: AppSpacing.xs),
        // 「有几条其实跟原片一样」要说在前面：用户按条数付出的是等待时间
        Text(
          replaced == _combos.length
              ? '每条都至少换掉了一段画面'
              : '其中 ${_combos.length - replaced} 条与原片画面相同（没有为任何一段选替换素材）',
          style: const TextStyle(
              color: AppColors.textTertiary, fontSize: AppFontSize.caption),
        ),
        ?_burnedTextNotice(),
        ?_brandNotice(),
        ?_subtitleGapNotice(),
        const SizedBox(height: AppSpacing.xs),
        // 导到哪儿要能改，也要能一眼看见——此前是写死在「影片」下的一个
        // 子目录，用户点完关闭就不知道片子在哪了
        Row(
          children: [
            Expanded(
              child: Tooltip(
                message: _outputDir.path,
                child: Text('导出到：${shortenPath(_outputDir.path)}',
                  key: const Key('export-output-dir'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: AppColors.textTertiary,
                      fontSize: AppFontSize.caption)),
              ),
            ),
            TextButton(
              key: const Key('export-pick-dir'),
              onPressed: _running ? null : _pickDir,
              child: const Text('换个位置'),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        const Text('画面来自替换素材，声音沿用原片（换过音色的用生成的配音）',
            style: TextStyle(
                color: AppColors.textTertiary, fontSize: AppFontSize.micro)),
      ],
    );
  }

  /// 有几条素材画面上**本来就烧着字**。
  ///
  /// 换上它之后我们还要再烧一行台词字幕，两层字叠在一起、内容还毫不相干，
  /// 片子直接废。托盘上挑选时已经标过一次，这里再点一次名是因为：导出是
  /// 花钱花时间的那一步，而人挑完一圈之后未必还记得哪条有问题。
  Widget? _burnedTextNotice() {
    final byId = {for (final m in widget.pickedMaterials) m.id: m};
    final picks = <({String label, PickedMaterial material})>[];
    for (var i = 0; i < widget.replacements.length; i++) {
      final r = widget.replacements[i];
      for (final id in r.wholeCandidateIds) {
        if (byId[id] case final m?) picks.add((label: 'U${i + 1}', material: m));
      }
      for (final e in r.shotCandidateIds.entries) {
        for (final id in e.value) {
          if (byId[id] case final m?) {
            picks.add((label: 'U${i + 1} 的 S${e.key + 1}', material: m));
          }
        }
      }
    }
    final text = burnedTextSummary(picks);
    if (text == null) return null;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xs),
      child: Text(
        text,
        key: const Key('export-burned-text'),
        style: const TextStyle(
            color: AppColors.orange,
            fontSize: AppFontSize.caption,
            height: 1.5),
      ),
    );
  }

  /// 挑的素材里出现了不止一个品牌。
  ///
  /// 台词说「滴露新款消毒液」，画面却是若也洗发水直播间——片子自己打自己
  /// 的脸。真机上交付过这样一条成片（U3S2 的直播带货镜头用了别家直播间）。
  /// 托盘上挑选时已经标过一次，导出前再点一次名：这是花钱花时间的那一步，
  /// 而人挑完一圈之后未必还记得哪条有问题。
  Widget? _brandNotice() {
    // 两条互补的判据：一条抓「候选之间打架」，一条抓「候选一致、
    // 但整条都跑到别家去了」——后者只有拿原片当参照才看得出来
    final text = brandConflictNotice(widget.pickedMaterials) ??
        brandMismatchNotice(
          picked: widget.pickedMaterials,
          sourceBrand: sourceBrandOf(widget.units),
        );
    if (text == null) return null;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xs),
      child: Text(
        text,
        key: const Key('export-brand-conflict'),
        style: const TextStyle(
            color: AppColors.red, fontSize: AppFontSize.caption, height: 1.5),
      ),
    );
  }

  /// 哪几段成片里没有台词字幕。
  ///
  /// **整体替换原样接上、时长随候选**，和原坑位对不齐——按原片时间戳算的
  /// 字幕没法直接烧上去，那一段就没字。镜头替换会变速对齐回原坑位并重渲。
  /// 一条片子两种模式混着用，字幕就是断断续续的，而人点导出时看不见这件事。
  Widget? _subtitleGapNotice() {
    final text = subtitleGapNotice(widget.replacements);
    if (text == null) return null;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xs),
      child: Text(
        text,
        key: const Key('export-subtitle-gap'),
        style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: AppFontSize.caption,
            height: 1.5),
      ),
    );
  }

  /// 这个项目的导出历史。**放在确认页上**：正要导之前先看一眼上次导到哪儿、
  /// 导了几条，比另开一个界面顺手得多（用户原话：「每一个项目点导出的时候，
  /// 它不是最后还要确认一下吗？你可以在那个页面里展示出这个项目之前导出的
  /// 这个历史。」）
  ///
  /// 倒序、只列最近五次——更早的写个条数就够了，把确认页撑长反而看不清
  /// 这一次要导什么。
  Widget _history() {
    if (_exports.isEmpty) return const SizedBox.shrink();
    final recent = _exports.reversed.toList();
    final shown = recent.take(_historyLimit).toList();
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('这个项目导出过 ${_exports.length} 次',
              key: const Key('export-history-title'),
              style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: AppFontSize.caption,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: AppSpacing.xs),
          for (final record in shown) _historyRow(record),
          if (recent.length > shown.length)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('另有 ${recent.length - shown.length} 次更早的导出',
                  style: const TextStyle(
                      color: AppColors.textTertiary,
                      fontSize: AppFontSize.micro)),
            ),
        ],
      ),
    );
  }

  static const int _historyLimit = 5;

  Widget _historyRow(ExportRecord record) {
    final failed = record.total - record.succeeded;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          Text(
            '${record.at.month}月${record.at.day}日 '
            '${record.at.hour.toString().padLeft(2, '0')}:'
            '${record.at.minute.toString().padLeft(2, '0')}',
            style: const TextStyle(
                color: AppColors.textTertiary, fontSize: AppFontSize.micro),
          ),
          const SizedBox(width: AppSpacing.sm),
          Text(
            failed > 0 ? '${record.succeeded} 条（$failed 条失败）'
                : '${record.succeeded} 条',
            style: TextStyle(
                color: failed > 0 ? AppColors.orange : AppColors.textSecondary,
                fontSize: AppFontSize.micro),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Tooltip(
              message: record.outputDir,
              child: Text(
                shortenPath(record.outputDir),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: AppColors.textTertiary, fontSize: AppFontSize.micro),
              ),
            ),
          ),
          // 每一条都能直接打开——历史的用处就是「回去找那批片子」
          InkWell(
            key: Key('export-history-open-${record.at.toIso8601String()}'),
            onTap: () => _revealPath(record.outputDir),
            borderRadius: BorderRadius.circular(AppRadius.xs),
            child: const Padding(
              padding: EdgeInsets.all(3),
              child: Icon(Icons.folder_open,
                  size: 13, color: AppColors.accentBlue),
            ),
          ),
        ],
      ),
    );
  }

  Widget _resultList(List<ExportOutcome> results) {
    final failed = results.where((r) => !r.ok).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          failed.isEmpty
              ? '${results.length} 条全部导出完成'
              : '成功 ${results.length - failed.length} 条，失败 ${failed.length} 条',
          key: const Key('export-result'),
          style: TextStyle(
              color: failed.isEmpty ? AppColors.green : AppColors.orange,
              fontSize: AppFontSize.body,
              fontWeight: FontWeight.w600),
        ),
        // 成的那几条叫什么，直接摆出来：同名不覆盖会把文件排成
        // 「变体1(2).mp4」，人到目录里找的是刚导的这几个，不说清就得自己猜
        if (results.any((r) => r.ok)) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            _fileNames(results),
            key: const Key('export-result-files'),
            style: const TextStyle(
                color: AppColors.textTertiary,
                fontSize: AppFontSize.micro,
                height: 1.5),
          ),
        ],
        // 导成了但有话要说的（目前只有「这一段过载了」）。**不能不说**：
        // 各层声音是相加的，叠出来可能发破——软件不替他压音量，但要告诉他
        // 是哪一段、去调哪一层
        for (final note in {for (final r in results) ...r.notes})
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xs),
            child: Text(note,
                key: const Key('export-result-note'),
                style: const TextStyle(
                    color: AppColors.orange,
                    fontSize: AppFontSize.micro,
                    height: 1.4)),
          ),
        // 失败的要逐条点名并带原因，否则用户只能一条条自己找
        for (final f in failed)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xs),
            child: Text('第 ${f.index} 条：${f.failure}',
                style: const TextStyle(
                    color: AppColors.textTertiary,
                    fontSize: AppFontSize.micro,
                    height: 1.4)),
          ),
      ],
    );
  }

  /// 挑出来的这几条各用了什么。
  ///
  /// **摆在导出之前**：挑得对不对只有人能判断，等导完再列等于让人对着
  /// 十个文件自己比对。「挑差异最大的」到底有没有把每个位置的候选都摊开，
  /// 在这一栏一眼就能数出来（2026-09-10 用户真机：一个镜头挑了 5 条素材，
  /// 导出来的十条全用其中同一条）
  Widget _pickBreakdown() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('这几条各用什么',
              key: Key('export-pick-breakdown'),
              style: TextStyle(
                  fontSize: AppFontSize.caption,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textSecondary)),
          for (final combo in _selected)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text('第 ${combo.index} 条 · ${_composition(combo)}',
                  style: const TextStyle(
                      color: AppColors.textTertiary,
                      fontSize: AppFontSize.micro,
                      height: 1.5)),
            ),
        ],
      );

  /// 导出来的文件名。多了就只列前几个——把确认页撑长反而看不清
  static String _fileNames(List<ExportOutcome> results) {
    final names = [
      for (final r in results)
        if (r.path case final path?) p.basename(path),
    ];
    const shown = 6;
    if (names.length <= shown) return names.join('、');
    return '${names.take(shown).join('、')}，另有 ${names.length - shown} 条';
  }

  /// 一条成片用了哪些素材，按 U 顺序写出来。
  ///
  /// 用素材**名字**而不是 id：id 是给机器看的，用户看到 80791142539264
  /// 只能再去别处查一遍
  String _composition(ExportCombination combo) {
    final names = <String>[];
    for (final segment in combo.segments) {
      final id = segment.candidateId;
      if (id == null) continue;
      final material = widget.pickedMaterials
          .where((m) => m.id == id)
          .firstOrNull;
      final label = material?.name ?? '素材 $id';
      // 名字往往很长（滴露_植源喷雾_姚瑶_20260702_80791142539264），
      // 尾号才是区分同一批里那几条的关键，所以留尾不留头
      // 位置标到镜头：一个单元里好几镜各换各的，只说 U2 分不清是哪一镜
      final where = segment.shotIndex == null
          ? 'U${segment.unitIndex + 1}'
          : 'U${segment.unitIndex + 1}·S${segment.shotIndex! + 1}';
      names.add('$where ${_tail(label)}');
    }
    return names.isEmpty ? '全部用原片' : names.join(' · ');
  }

  static String _tail(String name) =>
      name.length <= 14 ? name : '…${name.substring(name.length - 13)}';
}
