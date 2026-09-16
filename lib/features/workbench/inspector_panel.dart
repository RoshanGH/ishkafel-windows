import 'package:flutter/material.dart';
import '../../core/ui/text_editing_keys.dart';

import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_colors.dart';
import '../shared/scroll_fade.dart';
import '../../app/theme/app_typography.dart';
import '../../core/editing/segmentation_editor_controller.dart';
import '../../core/audio/material_audio.dart';
import '../../core/audio/source_audio.dart';
import '../../core/models/semantic_unit.dart';
import '../../core/replacement/unit_base.dart';
import '../../core/subtitle/subtitle_overlay.dart';
import '../../core/export/composed_timeline.dart';
import '../../core/time/timecode.dart';
import 'inspector_widgets.dart';
import 'inserted_unit_label.dart';
import 'material_audio_card.dart';
import 'source_audio_card.dart';
import 'subtitle_editor_card.dart';
import '../../core/audio/voice_plan.dart';
import 'tag_trace_section.dart';
import 'voice_card.dart';
import '../../core/editing/edit_locks.dart';

/// 时间码格式化搬到了 `core/time/timecode.dart`——命令行、导出、报告都要用，
/// 不该去 import 一个界面文件。这里转出去，老调用点不用改。
export '../../core/time/timecode.dart' show formatTimecode;

/// 属性检查器：右栏，跟随 [SegmentationEditorController.selection] 三态渲染
/// ——选中单元 / 选中镜头 / 无选中占位。
///
/// 纯展示型辅助组件（卡片/步进按钮/标签 chips 等）拆在 [inspector_widgets.dart]
/// 里，本文件只负责三态判断、与 controller 的数据/事件绑定。
class InspectorPanel extends StatefulWidget {
  final SegmentationEditorController controller;
  final double fps;

  /// 「在游标处拆分」的实际拆分时机（当前播放头位置）由外部（审片台页面）
  /// 决定，本面板只负责转发点击事件。
  final VoidCallback? onSplitAtPlayhead;

  /// 逐帧调整边界后把预览定位到那一帧——眼睛盯着的是画面，不是时间码。
  /// 按住步进按钮连发时预览逐帧跟着走
  final void Function(int ms)? onSeekTo;

  /// 只读回看模式（评审 Important 1）：true 时步进按钮、台词输入框、拆分/
  /// 并入按钮全部禁用——已确认（picking/exported）的切分结构不允许被
  /// 静默改写。默认 false（编辑态，行为与此前一致）。
  final bool readOnly;

  /// 这个单元换成了哪个音色（null 表示保持原声）
  final VoiceRef? Function(int unitIndex)? voiceOf;

  /// 点「换音色」。由页面弹面板——检查器不该知道音色是从哪来的。
  final void Function(int unitIndex)? onChangeVoice;

  /// 试听这个单元已生成的配音；返回 null 表示还没生成过
  final VoidCallback? Function(int unitIndex)? previewVoice;

  /// 这一段在成片里占多长（被整体替换时跟着候选走）。时间线画的就是它
  final int? Function(int unitIndex)? composedDurationOf;

  /// 手改这个单元的标签
  final void Function(int unitIndex)? onEditUnitTags;

  /// 手改这一镜的标签
  final void Function(int unitIndex, int shotIndex)? onEditShotTags;

  /// 这一镜当前的字幕（手改过就是手改的，否则是按 ASR 算的那份）
  final List<SubtitleLine> Function(int unitIndex, int shotIndex)?
      subtitleLinesOf;

  /// 这一镜的字幕手改过没有
  final bool Function(int unitIndex, int shotIndex)? subtitleEdited;

  /// 改这一镜的字幕
  final void Function(int unitIndex, int shotIndex, List<SubtitleLine> lines)?
      onSubtitleChanged;

  /// 清掉手改，回到按 ASR 自动算
  final void Function(int unitIndex, int shotIndex)? onSubtitleReset;

  /// 「保留素材原声」的全片打底设置（单个镜头可覆盖）
  final MaterialAudioSetting materialAudioDefault;

  /// 这一镜换过素材没有。没换就没有「素材的声音」，那张卡片不出现
  final bool Function(int unitIndex, int shotIndex)? shotReplaced;

  /// 换上来那条素材自己的语音转写（非空 = 它自己带口播，要提示）
  final String? Function(int unitIndex, int shotIndex)? shotMaterialVoiceover;

  /// 改这一镜「替换分镜的声音」。mode 传 null = 改回跟随全片
  final void Function(int unitIndex, int shotIndex, MaterialAudioMode? mode,
      double? volume)? onShotMaterialAudioChanged;

  /// 「原片这一镜的声音」的全片打底设置（单个镜头可覆盖）
  final SourceAudioSetting sourceAudioDefault;

  /// 改这一镜「原片这一镜的声音」。mode 传 null = 改回跟随全片
  final void Function(int unitIndex, int shotIndex, MaterialAudioMode? mode,
      double? volume)? onShotSourceAudioChanged;

  /// 这个单元换过音色没有。换过的话原片那一路已经被生成的配音顶掉了
  final bool Function(int unitIndex)? unitVoiceSwapped;

  /// 这条任务有没有分离好的人声轨 / 背景音轨
  final bool hasVocals;
  final bool hasBackground;

  /// 空白任务：整条片子都没有原片。**注意这只是「全都没有」的那种情况**——
  /// 有原片的任务里也可能有个别单元没有原片来源（用户手加的），
  /// 判断某一个单元有没有台词要看 [SemanticUnit.hasSource]，不是看这个 flag
  final bool blankTask;

  /// 这一段的底片卡片（挑了素材的插入段才有）。返回 null 表示不摆。
  ///
  /// 交给外面造而不是在这儿拼：它要知道素材叫什么、要能发起切分、
  /// 要显示切分进度——那些都在工作台那一层
  final Widget? Function(int unitIndex, SemanticUnit unit)? baseCard;

  /// 单元标签的**手填**编辑器。返回 null 表示这个单元不该手填
  /// （分析切出来的单元：标签是模型按台词打的，在这儿手改会和「重新打标」
  /// 互相覆盖，而用户看不出是谁赢了）。
  ///
  /// 手加的单元必须给：它没有台词，模型没有任何东西可以据以打标，
  /// 而标签正是去搜素材的检索键——不给的话这个单元永远搜不出东西
  final Widget? Function(int unitIndex, SemanticUnit unit)? unitTagEditor;

  const InspectorPanel({
    super.key,
    required this.controller,
    required this.fps,
    this.onSplitAtPlayhead,
    this.onSeekTo,
    this.voiceOf,
    this.onChangeVoice,
    this.previewVoice,
    this.unitTagEditor,
    this.blankTask = false,
    this.composedDurationOf,
    this.baseCard,
    this.onEditUnitTags,
    this.onEditShotTags,
    this.subtitleLinesOf,
    this.subtitleEdited,
    this.onSubtitleChanged,
    this.onSubtitleReset,
    this.materialAudioDefault = MaterialAudioSetting.off,
    this.shotReplaced,
    this.shotMaterialVoiceover,
    this.onShotMaterialAudioChanged,
    this.sourceAudioDefault = SourceAudioSetting.auto,
    this.onShotSourceAudioChanged,
    this.unitVoiceSwapped,
    this.hasVocals = false,
    this.hasBackground = false,
    this.readOnly = false,
  });

  @override
  State<InspectorPanel> createState() => _InspectorPanelState();
}

class _InspectorPanelState extends State<InspectorPanel> {
  /// 成片时间轴。**在这里现算，绝不从外面接一个算好的进来。**
  ///
  /// 接进来的那个是外层 build 时算的，而逐帧微调只 `notifyListeners()`——
  /// 面板自己的 AnimatedBuilder 重建了，轴却还是旧的：连点三次「+1 帧」，
  /// 盘上走了 3 帧，属性栏只动 1 帧（2026-09-08 真机回归时点出来的）。
  /// 这正是「改了没反应」那一类。实测全量重算 0.4µs，不值得为它冒这个险。
  ComposedTimeline get _axis => ComposedTimeline.of(
        units: widget.controller.units,
        wholeDurations: {
          for (var i = 0; i < widget.controller.units.length; i++)
            i: ?widget.composedDurationOf?.call(i),
        },
      );

  /// 这个单元在**成片**里的起点
  int _unitStart(int unitIndex, SemanticUnit unit) => _axis.startOf(unitIndex);

  int _unitEnd(int unitIndex, SemanticUnit unit) {
    final t = _axis;
    return t.startOf(unitIndex) + t.durationOf(unitIndex);
  }

  /// 这一镜在**成片**里的起止。整体替换的单元返回 null——那一段整个换成了
  /// 另一条素材，原片的镜头切分在成片里已经不存在，编一个数出来是假精度
  (int, int)? _shotRange(int unitIndex, int shotIndex) {
    final t = _axis;
    final a = t.composedShotStart(unitIndex, shotIndex);
    final b = t.composedShotEnd(unitIndex, shotIndex);
    return (a == null || b == null) ? null : (a, b);
  }

  final _transcriptController = TextEditingController();

  /// 台词 TextField 专用 FocusNode：聚焦时开启编辑会话、失焦时结束（评审
  /// Important 3），使聚焦期间连续多次 updateTranscript（逐击键入）合并
  /// 为一条 undo 记录，而不是每个字符都单独入栈。
  final _transcriptFocusNode = FocusNode(debugLabel: 'InspectorTranscript');

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    _transcriptFocusNode.addListener(_onTranscriptFocusChanged);
    _syncTranscript();
  }

  void _onTranscriptFocusChanged() {
    if (_transcriptFocusNode.hasFocus) {
      widget.controller.beginTextSession();
    } else {
      widget.controller.endTextSession();
    }
  }

  @override
  void didUpdateWidget(covariant InspectorPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
    }
    _syncTranscript();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _transcriptFocusNode.removeListener(_onTranscriptFocusChanged);
    // 兜底：若卸载发生在台词编辑会话进行中（如切换选中对象导致本面板随之
    // 重建/卸载而非正常失焦），必须显式结束会话，否则 controller 的会话
    // 快照永久非空、此后所有编辑都会静默跳过 undo 入栈。该方法本身幂等。
    widget.controller.endTextSession();
    _transcriptController.dispose();
    _transcriptFocusNode.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    _syncTranscript();
    setState(() {});
  }

  /// 仅在受控单元的台词与当前文本框内容不一致时才写回，避免用户正在输入时
  /// 因 notifyListeners 触发的 setState 把光标强制拉回文本末尾。
  void _syncTranscript() {
    final text = _selectedUnit()?.transcript ?? '';
    if (_transcriptController.text != text) {
      _transcriptController.text = text;
    }
  }

  SemanticUnit? _selectedUnit() {
    final sel = widget.controller.selection;
    final units = widget.controller.units;
    if (sel == null || sel.unitIndex < 0 || sel.unitIndex >= units.length) {
      return null;
    }
    return units[sel.unitIndex];
  }

  /// 逐帧调边界并让预览跟到那一帧：眼睛盯着的是画面——不跟随的话，
  /// 用户只能看时间码数字变，根本不知道这一帧切在画面的哪里
  void _nudgeAndFollow({required bool startEdge, required int frames}) {
    final ok = widget.controller
        .nudgeSelectedEdge(startEdge: startEdge, frames: frames);
    if (!ok) return;
    final sel = widget.controller.selection;
    if (sel == null) return;
    final units = widget.controller.units;
    if (sel.unitIndex >= units.length) return;
    final unit = units[sel.unitIndex];
    final shotIndex = sel.shotIndex;
    final ms = shotIndex == null
        ? (startEdge ? unit.startMs : unit.endMs)
        : (shotIndex < unit.shots.length
            ? (startEdge
                ? unit.shots[shotIndex].startMs
                : unit.shots[shotIndex].endMs)
            : null);
    if (ms != null) widget.onSeekTo?.call(ms);
  }

  @override
  Widget build(BuildContext context) {
    final selection = widget.controller.selection;
    final Widget body;
    Widget? actions;
    if (selection == null) {
      body = _buildPlaceholder();
    } else if (selection.shotIndex == null) {
      body = _buildUnitInspector(selection.unitIndex);
      actions = _unitActions(selection.unitIndex);
    } else {
      body = _buildShotInspector(selection.unitIndex, selection.shotIndex!);
      actions = _shotActions(selection.unitIndex, selection.shotIndex!);
    }
    return Container(
      color: AppColors.surfaceRaised,
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 内容没到底时下沿压一层淡出：macOS 的滚动条不动鼠标就不出现，
          // 没有它人根本不知道下面还有东西（见 [ScrollFade]）
          Expanded(
            child:
                ScrollFade(background: AppColors.surfaceRaised, child: body),
          ),
          if (actions != null) ...[
            const SizedBox(height: 10),
            actions,
          ],
        ],
      ),
    );
  }

  /// 「这一段为什么改不动了」。
  ///
  /// 控件置灰而不说原因，用户只会以为软件坏了。这里点名是谁被钉住、
  /// 为什么钉、以及怎么解开——解开是用户自己的决定，软件不替他做。
  ///
  /// [shotIndex] 为 null 时说的是整个单元。返回 null 表示这一处没被钉。
  Widget? _lockNoteFor(EditLocks locks, int unitIndex, int? shotIndex) {
    final String detail;
    if (shotIndex != null) {
      if (!locks.isShotLocked(unitIndex, shotIndex)) return null;
      detail = locks.isShotBoundaryLocked(unitIndex)
          ? '这个单元已整体替换，里面的镜头在成片里已经不存在了。'
          : '这个镜头已选替换素材。';
    } else if (locks.basePinned.contains(unitIndex)) {
      // 固定过底片的：单元层锁着、镜头层是活的。只写「锁定」的话，
      // 人会以为这一段彻底不能改了
      detail = '这一段按底片切成了镜头：单元边界不能动，每一镜还能调。';
    } else if (locks.isUnitLocked(unitIndex)) {
      detail = '这个单元已选整体替换素材。';
    } else {
      final shots = locks.lockedShotsIn(unitIndex);
      if (shots.isEmpty) return null;
      detail = '这个单元里的 ${shots.map((s) => 'S${s + 1}').join('、')} 已选替换素材。';
    }
    // **一行说完，原因放 tooltip**。原来是一段四行的解释常驻在这儿，
    // 把它下面的「单元台词（可编辑）」和「拆分 / 并入」整个挤出了可视区——
    // 人看不到那两样东西，等于这个面板少了一半功能
    // （2026-09-09 设计走查真机截图）
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.md),
      child: Tooltip(
        message: '改边界会让已经按原时长做好的素材对不上；'
            '拆分或合并会让替换方案错位到别的镜头上。\n'
            '要调整切分，请先移除它的替换素材。',
        child: inspectorCard([
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Icon(Icons.lock_outline_rounded,
                  size: 14, color: AppColors.purple),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '$detail切分已锁定',
                  style: const TextStyle(
                    fontSize: AppFontSize.caption,
                    height: 1.4,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ]),
      ),
    );
  }

  /// 什么都没选中时，这一栏说「整片现在是什么样」。
  ///
  /// 2026-09-09 设计走查：原来这里只有一句「未选中任何单元或镜头」，
  /// 480px 宽的一整栏空着，而人真正想知道的那几个数（换了几个镜头、
  /// 改了几处字幕、片子多长）挤在窗口最下面一行 10px 的灰字里。
  /// 空状态不是「没东西可说」，是「还没聚焦到某一处」——那就说整体。
  Widget _buildPlaceholder() {
    final units = widget.controller.units;
    if (units.isEmpty) {
      return const Center(
        child: Text(
          '还没有台词语义单元',
          textAlign: TextAlign.center,
          style: TextStyle(
              color: AppColors.textTertiary, fontSize: AppFontSize.body),
        ),
      );
    }

    var shots = 0;
    var replaced = 0;
    var subtitleEdited = 0;
    var revoiced = 0;
    // 拼片的一个「分子」整段挑一条素材，没有镜头层——它的进度是
    // 「几个分子填上了」
    var filledUnits = 0;
    for (var u = 0; u < units.length; u++) {
      final list = units[u].shots;
      shots += list.length;
      var unitReplaced = false;
      for (var i = 0; i < list.length; i++) {
        if (widget.shotReplaced?.call(u, i) ?? false) {
          replaced++;
          unitReplaced = true;
        }
        if (widget.subtitleEdited?.call(u, i) ?? false) subtitleEdited++;
      }
      if (unitReplaced || (widget.composedDurationOf?.call(u) ?? 0) > 0) {
        filledUnits++;
      }
      if (widget.voiceOf?.call(u) != null) revoiced++;
    }

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        inspectorTitle(widget.blankTask ? '整片（拼片）' : '整片'),
        const SizedBox(height: AppSpacing.md),
        inspectorCard([
          inspectorInfoRow('时长', formatTimecode(_axis.totalMs, widget.fps)),
          inspectorInfoRow(
              widget.blankTask ? '分子' : '台词语义单元', '${units.length}'),
          if (!widget.blankTask) inspectorInfoRow('视觉镜头', '$shots'),
        ]),
        const SizedBox(height: AppSpacing.md),
        // 「改了多少」比「有多少」更值得一眼看到——它回答的是
        // 「这条片子翻新到哪一步了」。
        // 拼片没有镜头层（分子整段挑一条素材），「换过画面的镜头 0 / 0」
        // 是一行没有意义的数（2026-09-09 设计走查）
        inspectorCard([
          if (!widget.blankTask)
            inspectorInfoRow('换过画面的镜头', '$replaced / $shots'),
          if (widget.blankTask)
            inspectorInfoRow('已挑到素材的分子', '$filledUnits / ${units.length}'),
          inspectorInfoRow('手改过的字幕', '$subtitleEdited'),
          inspectorInfoRow('换过音色的单元', '$revoiced'),
        ]),
        const SizedBox(height: AppSpacing.md),
        const Text(
          '点左侧列表、或时间线上任意一块，这里就变成它的属性。',
          style: TextStyle(
              color: AppColors.textTertiary, fontSize: AppFontSize.caption),
        ),
      ],
    );
  }

  Widget _buildUnitInspector(int unitIndex) {
    final units = widget.controller.units;
    if (unitIndex < 0 || unitIndex >= units.length) return _buildPlaceholder();
    final unit = units[unitIndex];
    // 首单元没有前一个单元可合并边界，末单元没有后一个单元可合并边界；
    // 只读模式下一律禁用（回看不允许改写已确认的结构）。
    // 挑过替换素材就钉死切分（见 EditLocks）：边界一动，已经按旧时长变速好
    // 的素材全对不上；拆分/合并更会让替换方案的下标整体错位
    final locks = widget.controller.locks;
    final lockedNote = _lockNoteFor(locks, unitIndex, null);
    final canNudgeStart = unitIndex > 0 &&
        !widget.readOnly &&
        !locks.isUnitLocked(unitIndex) &&
        !locks.isUnitLocked(unitIndex - 1);
    final canNudgeEnd = unitIndex < units.length - 1 &&
        !widget.readOnly &&
        !locks.isUnitLocked(unitIndex) &&
        !locks.isUnitLocked(unitIndex + 1);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 手加的单元原片里没有它——标出来，不然混在真台词单元里看不出
          // 区别。但固定过底片的已经不是「纯画面」了：那条素材转写过，
          // 它有台词、有字幕、镜头也打过标
          inspectorTitle(unit.hasSource
              ? '台词语义单元 — U${unit.index + 1}'
              : hasOwnBaseShots(unit)
                  ? '插入段 — U${unit.index + 1}（画面与台词都来自底片素材）'
                  : '插入段 — U${unit.index + 1}（原片里没有，纯画面）'),
          const SizedBox(height: 10),
          inspectorCard([
            inspectorTimeRow(
              // **标出是哪条轴**：这两个数是它在成片里的位置，不是原片位置。
              // 只写「开始」时人没法知道是哪条轴上的开始，而下面那行
              // 「取自原片」标了——一标一不标最容易让人以为是同一件事
              label: '成片开始',
              valueText: formatTimecode(_unitStart(unitIndex, unit), widget.fps),
              minusKey: const Key('inspector-start-minus'),
              plusKey: const Key('inspector-start-plus'),
              minusEnabled: canNudgeStart,
              plusEnabled: canNudgeStart,
              onMinus: () => _nudgeAndFollow(startEdge: true, frames: -1),
              onPlus: () => _nudgeAndFollow(startEdge: true, frames: 1),
            ),
            inspectorTimeRow(
              label: '成片结束',
              valueText: formatTimecode(_unitEnd(unitIndex, unit), widget.fps),
              minusKey: const Key('inspector-end-minus'),
              plusKey: const Key('inspector-end-plus'),
              minusEnabled: canNudgeEnd,
              plusEnabled: canNudgeEnd,
              onMinus: () => _nudgeAndFollow(startEdge: false, frames: -1),
              onPlus: () => _nudgeAndFollow(startEdge: false, frames: 1),
            ),
            inspectorInfoRow(
                '时长',
                unitDurationLabel(
                  placeholderMs: unit.durationMs,
                  // **固定过底片的走同一条轴**：这一段的真实长度是底片切出来
                  // 那几镜的跨度，而 unit.startMs/endMs 还是原来那个原片
                  // 坑位。真机上一条 16.09s 的底片挂在 10s 的坑位上，
                  // 这里写「10.00s」，上面两行却写着「成片 0~16.09」
                  // ——同一张卡片自相矛盾
                  composedMs: hasOwnBaseShots(unit)
                      ? _axis.durationOf(unitIndex)
                      : widget.composedDurationOf?.call(unitIndex),
                  hasSource: unit.hasSource,
                )),
            inspectorInfoRow('镜头数', '${unit.shots.length}'),
            // 这一行回答的是**这一段的画面从哪儿来**，所以顺序和
            // `baseChoiceOf` 一致：固定过底片的先认底片。
            //
            // 真机上的反例：拼片任务的分子 hasSource 为真（它是从别的任务
            // 搬过来的一段），可这条任务根本没有原片文件，画面早就换成了
            // 底片那条素材——先判 hasSource 的话，这里写的是「取自原片
            // 00:00.00–00:10.00」，一条并不存在的原片上的坐标
            if (hasOwnBaseShots(unit))
              inspectorSubRow(
                  '取自底片',
                  '${formatTimecode(0, widget.fps)} – '
                      '${formatTimecode(unit.shots.last.endMs - unit.startMs, widget.fps)}')
            // 手加的单元原片里根本没有它——它的 startMs/endMs 只是塞在原片
            // 末尾的占位。给出来就是个纯假数字（真机上它写着
            // 01:36.07–01:46.07，而原片只有 96.2s），所以这一行只对
            // 真的取自原片的单元出现
            else if (unit.hasSource)
              inspectorSubRow(
                  '取自原片',
                  '${formatTimecode(unit.startMs, widget.fps)}'
                      ' – ${formatTimecode(unit.endMs, widget.fps)}'),
            inspectorTimecodeLegend(widget.fps),
          ]),
          ?lockedNote,
          ?widget.baseCard?.call(unitIndex, unit),
          const SizedBox(height: 10),
          // 空白任务给一个能选的编辑器；有原片的任务照旧只展示模型打的结果
          widget.unitTagEditor?.call(unitIndex, unit) ??
              TagTraceSection(
                title: '台词语义单元标签',
                tags: unit.tags,
                tagsStale: unit.tagsStale,
                trace: unit.trace,
                handpicked: unit.tagsHandpicked,
                onEdit: widget.onEditUnitTags == null
                    ? null
                    : () => widget.onEditUnitTags!(unitIndex),
              ),
          // 没有原片来源的单元没有台词：换音色没得念、台词框永远是空的。
          // **按单元判而不是按任务判**——有原片的任务里也会有手加的单元。
          //
          // 固定过底片的除外：它的台词是从那条素材转写出来的，跟原片单元
          // 一样有话可念、有词可改（2026-09-15 真机：「该有的都要有」）
          if (unit.hasSource || hasOwnBaseShots(unit)) ...[
            const SizedBox(height: 10),
            VoiceCard(
              voice: widget.voiceOf?.call(unitIndex),
              onTap: widget.readOnly
                  ? null
                  : () => widget.onChangeVoice?.call(unitIndex),
              onPreview: widget.previewVoice?.call(unitIndex),
            ),
            const SizedBox(height: 10),
            inspectorCard([
              // 回看模式下台词框是禁用的，标题必须如实反映，不能继续声称可编辑
              inspectorLabel(
                  widget.readOnly ? '单元台词（只读）' : '单元台词（可编辑）'),
              const SizedBox(height: 6),
              _transcriptField(unitIndex),
            ]),
          ],
        ],
      ),
    );
  }

  /// 镜头的动作行。同样钉在底部，理由见 [_unitActions]
  Widget? _shotActions(int unitIndex, int shotIndex) {
    final units = widget.controller.units;
    if (unitIndex < 0 || unitIndex >= units.length) return null;
    if (shotIndex < 0 || shotIndex >= units[unitIndex].shots.length) {
      return null;
    }
    final locks = widget.controller.locks;
    final selfLocked = locks.isShotLocked(unitIndex, shotIndex);
    return inspectorActionsRow(
      splitLabel: '✂ 在游标处拆分镜头',
      mergeLabel: '⇧ 并入前一镜头',
      onSplit: widget.readOnly || selfLocked
          ? null
          : () => widget.onSplitAtPlayhead?.call(),
      // 并入前一镜头会让前一个消失：自己或前一个被钉都不行
      onMerge: widget.readOnly ||
              selfLocked ||
              locks.isShotLocked(unitIndex, shotIndex - 1)
          ? null
          : widget.controller.mergeSelectedWithPrevious,
    );
  }

  /// 单元的动作行。**钉在面板底部，不跟着滚**——它上面的内容
  /// （时间、锁定说明、标签、音色、台词框）加起来早就超过一屏，
  /// 这两个按钮跟着滚就永远落在可视区外，人根本不知道有它们
  /// （2026-09-09 设计走查真机：属性栏底下什么都看不到）。
  Widget? _unitActions(int unitIndex) {
    final units = widget.controller.units;
    if (unitIndex < 0 || unitIndex >= units.length) return null;
    final unit = units[unitIndex];
    // 拆分/并入是「在一条固定的原片时间轴上换个切法」。手加的单元是加出来
    // 的，没有原片区间可并；**固定过底片的也不行**——拆开之后两半各自的
    // 镜头还挂着同一张底片的偏移，对不上任何一边（SegmentationEditOps
    // 那边同样拒绝，两处口径一致）。要改这一段的切法，用「重新切分」
    if (!unit.hasSource) return null;
    final locks = widget.controller.locks;
    final structureLocked = locks.unitHasAnyLock(unitIndex);
    return inspectorActionsRow(
      splitLabel: '✂ 在游标处拆分单元',
      mergeLabel: '⇧ 并入上一单元',
      onSplit: widget.readOnly || structureLocked
          ? null
          : () => widget.onSplitAtPlayhead?.call(),
      onMerge: widget.readOnly || structureLocked
          ? null
          : widget.controller.mergeSelectedWithPrevious,
    );
  }

  Widget _buildShotInspector(int unitIndex, int shotIndex) {
    final units = widget.controller.units;
    if (unitIndex < 0 || unitIndex >= units.length) return _buildPlaceholder();
    final unit = units[unitIndex];
    final shots = unit.shots;
    if (shotIndex < 0 || shotIndex >= shots.length) return _buildPlaceholder();
    final shot = shots[shotIndex];
    // 这一镜是按**这个单元自己的底片**切出来的吗——决定「取自」那一行
    // 写原片还是写底片，以及数字要不要减掉单元起点
    final onBase = hasOwnBaseShots(unit);
    // 单元内首/末镜头同理没有对应方向的相邻边界可调；只读模式下同样禁用。
    final locks = widget.controller.locks;
    final lockedNote = _lockNoteFor(locks, unitIndex, shotIndex);
    final selfLocked = locks.isShotLocked(unitIndex, shotIndex);
    final canNudgeStart = shotIndex > 0 &&
        !widget.readOnly &&
        !selfLocked &&
        !locks.isShotLocked(unitIndex, shotIndex - 1);
    final canNudgeEnd = shotIndex < shots.length - 1 &&
        !widget.readOnly &&
        !selfLocked &&
        !locks.isShotLocked(unitIndex, shotIndex + 1);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          inspectorTitle('视觉镜头 — U${unit.index + 1} · S${shotIndex + 1}'),
          const SizedBox(height: 10),
          inspectorCard([
            inspectorInfoRow('所属单元',
                'U${unit.index + 1} · ${(unit.durationMs / 1000).toStringAsFixed(2)}s'),
            inspectorTimeRow(
              label: '成片开始',
              valueText: formatTimecode(
                  _shotRange(unitIndex, shotIndex)?.$1 ?? shot.startMs,
                  widget.fps),
              minusKey: const Key('inspector-start-minus'),
              plusKey: const Key('inspector-start-plus'),
              minusEnabled: canNudgeStart,
              plusEnabled: canNudgeStart,
              onMinus: () => _nudgeAndFollow(startEdge: true, frames: -1),
              onPlus: () => _nudgeAndFollow(startEdge: true, frames: 1),
            ),
            inspectorTimeRow(
              label: '成片结束',
              valueText: formatTimecode(
                  _shotRange(unitIndex, shotIndex)?.$2 ?? shot.endMs,
                  widget.fps),
              minusKey: const Key('inspector-end-minus'),
              plusKey: const Key('inspector-end-plus'),
              minusEnabled: canNudgeEnd,
              plusEnabled: canNudgeEnd,
              onMinus: () => _nudgeAndFollow(startEdge: false, frames: -1),
              onPlus: () => _nudgeAndFollow(startEdge: false, frames: 1),
            ),
            inspectorInfoRow(
                '时长', '${(shot.durationMs / 1000).toStringAsFixed(2)}s'),
            // **原片出处单独一行、写清楚**：上面那两个数是成片位置，
            // 而人有时要知道这一镜取自原片哪一段（回原片去看、去对素材）。
            // 两者混在同一个字段里就是 2026-09-08 那个「属性栏写 00:45.03、
            // 时间线画在 01:03」的来源
            // 底片被固定成一条素材时，这一镜取的是**那条素材**的第几秒——
            // 还写「取自原片」会让人跑回原片去对时，怎么对都对不上
            inspectorSubRow(
                onBase ? '取自底片' : '取自原片',
                '${formatTimecode(shot.startMs - (onBase ? unit.startMs : 0), widget.fps)}'
                    ' – ${formatTimecode(shot.endMs - (onBase ? unit.startMs : 0), widget.fps)}'),
            inspectorTimecodeLegend(widget.fps),
          ]),
          ?lockedNote,
          const SizedBox(height: 10),
          TagTraceSection(
            title: '视觉镜头标签',
            tags: shot.tags,
            tagsStale: shot.tagsStale,
            description: shot.description,
            trace: shot.trace,
            handpicked: shot.tagsHandpicked,
            onEdit: widget.onEditShotTags == null
                ? null
                : () => widget.onEditShotTags!(unitIndex, shotIndex),
          ),
          const SizedBox(height: 10),
          // 换过素材的镜头，原片的字跟着旧画面没了，这里的字会重新烧上去
          SubtitleEditorCard(
            replaced: widget.shotReplaced?.call(unitIndex, shotIndex) ?? false,
            // 底片是素材的段落：字幕取自它自己的转写，不是原片那份 ASR
            onMaterialBase: onBase,
            lines: widget.subtitleLinesOf?.call(unitIndex, shotIndex) ??
                const [],
            edited: widget.subtitleEdited?.call(unitIndex, shotIndex) ?? false,
            // 存的是相对这一镜的时间，摆给人看的是成片时间码——
            // 所以两样都要：这一镜多长（夹上界）、它在成片上从哪儿开始
            slotDurationMs: shot.durationMs,
            slotStartMs: _shotRange(unitIndex, shotIndex)?.$1 ?? shot.startMs,
            fps: widget.fps,
            onChanged: (v) =>
                widget.onSubtitleChanged?.call(unitIndex, shotIndex, v),
            onResetToAuto: () =>
                widget.onSubtitleReset?.call(unitIndex, shotIndex),
          ),
          const SizedBox(height: 10),
          // 成片的声音是两层。**原片那一层摆在前面**：它是主体，
          // 替换素材那一层是叠在它上面的
          SourceAudioCard(
            taskDefault: widget.sourceAudioDefault,
            shotMode: shot.sourceAudioMode,
            shotVolume: shot.sourceAudioVolume,
            replaced: widget.shotReplaced?.call(unitIndex, shotIndex) ?? false,
            voiceSwapped: widget.unitVoiceSwapped?.call(unitIndex) ?? false,
            unreplacedSiblings: _unreplacedSiblings(unitIndex, shotIndex),
            hasVocals: widget.hasVocals,
            hasBackground: widget.hasBackground,
            // 底片被固定成素材的那些单元，这张卡调的是**素材**自己的声音
            onMaterialBase: hasOwnBaseShots(units[unitIndex]),
            onChanged: (mode, volume) => widget.onShotSourceAudioChanged
                ?.call(unitIndex, shotIndex, mode, volume),
          ),
          const SizedBox(height: 10),
          // 这一镜换过素材才有「素材的声音」可言
          MaterialAudioCard(
            taskDefault: widget.materialAudioDefault,
            shotMode: shot.materialAudioMode,
            shotVolume: shot.materialAudioVolume,
            replaced: widget.shotReplaced?.call(unitIndex, shotIndex) ?? false,
            materialVoiceover:
                widget.shotMaterialVoiceover?.call(unitIndex, shotIndex),
            onChanged: (mode, volume) => widget.onShotMaterialAudioChanged
                ?.call(unitIndex, shotIndex, mode, volume),
          ),
        ],
      ),
    );
  }

  /// 这一句里还有哪几镜没换素材。
  ///
  /// 一句台词常常跨好几镜：这一镜剥掉了原片现场音、旁边那一镜还是原混音，
  /// 同一句话说到一半背景音突然出现。人听得出别扭却找不到原因，得点名说
  List<String> _unreplacedSiblings(int unitIndex, int shotIndex) {
    final replaced = widget.shotReplaced;
    if (replaced == null) return const [];
    final units = widget.controller.units;
    if (unitIndex < 0 || unitIndex >= units.length) return const [];
    return [
      for (var s = 0; s < units[unitIndex].shots.length; s++)
        if (s != shotIndex && !replaced(unitIndex, s)) 'S${s + 1}',
    ];
  }

  Widget _transcriptField(int unitIndex) {
    return TextField(
      key: const Key('inspector-transcript-field'),
      controller: _transcriptController,
      focusNode: _transcriptFocusNode,
      enabled: !widget.readOnly,
      maxLines: null,
      minLines: 2,
      style: const TextStyle(color: AppColors.textPrimary, fontSize: AppFontSize.body),
      decoration: const InputDecoration(
        isDense: true,
        border: InputBorder.none,
      ),
      onChanged: (text) => widget.controller.updateTranscript(unitIndex, text),
      // 点到别处就交出焦点，否则空格一直被当成「在框里打空格」，
      // 播放/暂停就此失灵（见 [releaseFocusOnTapOutside]）
      onTapOutside: (_) => KeyboardHome.take(context),
    );
  }
}
