import 'dart:async';
import '../../core/ui/text_editing_keys.dart';

import 'package:flutter/material.dart';
import '../../core/audio/material_audio.dart';
import '../../core/audio/source_audio.dart';
import '../../core/subtitle/subtitle_track.dart';
import '../../core/subtitle/subtitle_overlay.dart';
import '../../core/subtitle/subtitle_style.dart';
import '../../core/models/semantic_unit.dart';
import 'package:flutter/foundation.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/editing/segmentation_editor_controller.dart';
import '../../core/export/composed_timeline.dart';
import '../../core/playback/playback_controller.dart';
import '../shared/shortcuts_cheatsheet.dart';
import 'inspector_panel.dart';
import 'player_panel.dart';
import 'preview_subtitle_layer.dart';
import '../../core/audio/bgm_plan.dart';
import '../../core/audio/voice_plan.dart';
import '../../core/replacement/replacement_plan.dart';
import 'agent_focus_request.dart';
import 'candidate_badge.dart';
import 'side_panel_tabs.dart';
import 'workbench_panel_widths.dart';
import 'segment_playback.dart';
import 'timeline/timeline_hit_tester.dart';
import 'timeline/timeline_geometry.dart';
import 'timeline/timeline_painter.dart';
import 'timeline/timeline_view.dart';
import 'timeline_media_builder.dart';
import 'unit_list_panel.dart';
import 'workbench_shortcuts.dart';

/// 审片台主体：三栏（单元列表/播放器/检查器）+ 时间线，从 `workbench_page.dart`
/// 拆出的独立 StatefulWidget。
///
/// 拆分理由：[TimelineGeometry]/缩放倍数/时间线视口宽度这几项状态是"时间线
/// 展示区"的局部展示细节（缩放交互、resize 重新 clamp），页面级 State
/// （`WorkbenchPage`）自身的职责（装配编辑器/播放器、确认流转、离开确认）
/// 完全不需要读取它们——把它们留在页面级 State 里只是历史遗留的"放在一起"，
/// 搬到这里后各自的状态归属更清楚：本 Widget 自己的 State 持有时间线专属
/// 的展示状态；`WorkbenchPage` 只需要转发 [editor]/[playback]/[videoWidget]/
/// [media]/[playhead] 这几个"跨区域共享"的值。同理，页面级播放快捷键
/// （空格/←/→）转发到 [PlayerPanel] 的 [GlobalKey] 只在本组件内部使用，
/// 也一并搬入，`WorkbenchPage` 不再需要关心它。
class WorkbenchBody extends StatefulWidget {
  final SegmentationEditorController editor;

  /// Agent 这一步在看哪儿。**可视模式的跟随就靠它**：Agent 说它在挑
  /// U3S2 的素材，界面要像人自己点过去那样——选中那一镜、右栏切到
  /// 「替换素材」。只挪播放头的话，人看到的还是「后台改数据、前台显示结果」。
  ///
  /// null = 没人在跟（人自己在操作时界面不许自作主张乱跳）
  final AgentFocusRequest? agentFocus;

  /// 空白任务：分子手动加。有原片的任务为 null（分子是分析切出来的）
  final VoidCallback? onAddUnit;

  /// 把第 from 个单元拖到第 to 个位置（列表顺序就是成片顺序）
  final void Function(int from, int to)? onReorderUnit;

  /// 空白任务：分子标签手填，检查器里给一个能选的编辑器
  final Widget? Function(int unitIndex, SemanticUnit unit)? unitTagEditor;

  /// 「这一段的底片」卡片（见 [BaseSegmentCard]）。挑了素材的插入段才有
  final Widget? Function(int unitIndex, SemanticUnit unit)? baseCard;

  /// 手改单元 / 镜头的标签
  final void Function(int unitIndex)? onEditUnitTags;
  final void Function(int unitIndex, int shotIndex)? onEditShotTags;

  /// 这一镜当前的字幕（手改过就是手改的，否则是按 ASR 算的那份）
  final List<SubtitleLine> Function(int unitIndex, int shotIndex)?
      subtitleLinesOf;

  /// 这一镜的字幕手改过没有
  final bool Function(int unitIndex, int shotIndex)? subtitleEdited;

  /// 字幕轨上画的预览文字
  final String Function(int unitIndex, int shotIndex)? subtitleTextOf;

  /// 这一镜有几行字幕（时间线上标个数）
  final int Function(int unitIndex, int shotIndex)? subtitleLineCount;

  /// 双击时间线上的字幕块：就地改。给的是块体在屏幕上的位置
  final void Function(int unitIndex, int shotIndex, Rect blockOnScreen)?
      onEditSubtitleBlock;

  final void Function(int unitIndex, int shotIndex, List<SubtitleLine> lines)?
      onSubtitleChanged;
  final void Function(int unitIndex, int shotIndex)? onSubtitleReset;

  /// 「保留素材原声」的全片打底设置（单个镜头可覆盖）
  final MaterialAudioSetting materialAudioDefault;

  /// 这一镜换过素材没有
  final bool Function(int unitIndex, int shotIndex)? shotReplaced;

  /// 换上来那条素材自己的语音转写（非空 = 自带口播，要提示）
  final String? Function(int unitIndex, int shotIndex)? shotMaterialVoiceover;

  /// 改这一镜「替换分镜的声音」。mode 传 null = 改回跟随全片
  final void Function(int unitIndex, int shotIndex, MaterialAudioMode? mode,
      double? volume)? onShotMaterialAudioChanged;

  /// 「原片这一镜的声音」的全片打底 + 镜头级改动
  final SourceAudioSetting sourceAudioDefault;
  final void Function(int unitIndex, int shotIndex, MaterialAudioMode? mode,
      double? volume)? onShotSourceAudioChanged;

  /// 手改过的字幕。传给时间线只为一件事：改完要重画（见 TimelinePainter）
  final SubtitleTrack subtitleTrack;

  /// 这个单元换过音色没有；以及这条任务有没有分离好的人声/背景轨
  final bool Function(int unitIndex)? unitVoiceSwapped;
  final bool hasVocals;
  final bool hasBackground;

  /// 整条任务都没有原片（空白任务）。**别拿它判断某一个单元有没有台词**——
  /// 有原片的任务里也会有手加的、没有原片来源的单元，那要看 unit.hasSource
  final bool blankTask;

  /// 空白任务：删掉一个分子
  final ValueChanged<int>? onDeleteUnit;

  /// 哪些单元能删（有原片的任务只有手动加的能删）
  final bool Function(SemanticUnit unit)? canDeleteUnit;
  final PlaybackController playback;
  final Widget? videoWidget;

  /// 预览画面上这一刻该显示的那行字（**成片**毫秒 → 文本，null = 不出字）。
  /// 只有被我们换掉画面的镜头才有——没换的镜头字幕烧在原素材像素里，
  /// 再叠一层就是两行字打架。见 `core/subtitle/preview_subtitle_at.dart`
  final String? Function(int composedMs)? subtitleAt;

  /// 画字幕用的样式。改一下就即刻重画，不重渲任何切片
  final SubtitleStyle subtitleStyle;

  /// 点画面上的字幕：打开样式面板
  final VoidCallback? onSubtitleTap;

  /// 上下拖画面上的字幕：松手时把新的 bottomRatio 落盘
  final ValueChanged<double>? onSubtitleDragEnd;
  final TimelineMedia? media;
  /// 播放位置（只驱动时间线播放头，不参与页面重建，见 workbench_page.dart）
  final ValueListenable<int> playhead;

  /// 抽帧/波形就绪状态，透传给时间线画占位
  final TimelineMediaStatus mediaStatus;

  /// 画面轨 / 音频轨各自的状态（两条轨会各坏各的）
  final TimelineMediaStatus? thumbStatus;
  final TimelineMediaStatus? waveStatus;

  /// 底片固定过的单元各自的画面与波形（单元 uid → 那条素材的）。
  /// 那几段的画面来自素材，原片那份缩略图里根本没有它们
  final Map<String, TimelineMedia> baseMedia;

  /// 只读回看模式（评审 Important 1）：picking/exported 状态下已确认的
  /// 切分结构不允许再被静默改写，下发到 [TimelineView]/[InspectorPanel]。
  final bool readOnly;

  /// 右栏「替换素材」视图的内容。由页面装配后传入——工作台本身不关心
  /// 素材是怎么检索来的。
  final Widget? candidatePanel;

  /// 「替换素材」tab 上的角标（已选素材数之类）

  /// 时间线判定双击用的时钟（测试注入）
  final DateTime Function()? clock;

  /// 换音色方案与入口
  final VoicePlan voices;

  /// 当前替换方案：时间线上标出「哪几段挑好了素材、各几条」
  final List<UnitReplacement> replacements;

  /// 被整体替换的单元在成片里有多长（单元下标 → 毫秒）。时间线上标出来，
  /// 用户才知道成片总长已经变了
  final Map<int, int> composedDurations;

  /// 拖段落边界改长度 / 点 × 删掉一段
  final void Function(int startUnit, int newStart, int newEnd)? onBgmResize;
  final void Function(int startUnit)? onBgmDelete;
  final void Function(int unitIndex)? onChangeVoice;

  /// 试听某个单元已生成的配音；返回 null 表示这一句还没生成
  final VoidCallback? Function(int unitIndex)? previewVoice;

  /// 配乐方案与两个入口（框选一段 / 点已有的一段）
  final BgmPlan bgm;
  final void Function(int fromShot, int toShot)? onBgmRangeSelected;
  final void Function(BgmSegment segment)? onBgmSegmentTap;

  const WorkbenchBody({
    super.key,
    required this.editor,
    this.agentFocus,
    this.onAddUnit,
    this.onReorderUnit,
    this.unitTagEditor,
    this.baseCard,
    this.blankTask = false,
    this.materialAudioDefault = MaterialAudioSetting.off,
    this.shotReplaced,
    this.shotMaterialVoiceover,
    this.onEditUnitTags,
    this.onEditShotTags,
    this.subtitleLinesOf,
    this.subtitleEdited,
    this.subtitleTextOf,
    this.subtitleLineCount,
    this.onEditSubtitleBlock,
    this.onSubtitleChanged,
    this.onSubtitleReset,
    this.onShotMaterialAudioChanged,
    this.sourceAudioDefault = SourceAudioSetting.auto,
    this.onShotSourceAudioChanged,
    this.subtitleTrack = const SubtitleTrack.empty(),
    this.unitVoiceSwapped,
    this.hasVocals = false,
    this.hasBackground = false,
    this.onDeleteUnit,
    this.canDeleteUnit,
    required this.playback,
    this.videoWidget,
    this.subtitleAt,
    this.subtitleStyle = SubtitleStyle.standard,
    this.onSubtitleTap,
    this.onSubtitleDragEnd,
    this.media,
    required this.playhead,
    this.mediaStatus = TimelineMediaStatus.ready,
    this.thumbStatus,
    this.waveStatus,
    this.baseMedia = const {},
    this.readOnly = false,
    this.candidatePanel,
    this.clock,
    this.voices = VoicePlan.empty,
    this.replacements = const [],
    this.composedDurations = const {},
    this.onBgmResize,
    this.onBgmDelete,
    this.onChangeVoice,
    this.previewVoice,
    this.bgm = BgmPlan.empty,
    this.onBgmRangeSelected,
    this.onBgmSegmentTap,
  });

  @override
  State<WorkbenchBody> createState() => _WorkbenchBodyState();
}

class _WorkbenchBodyState extends State<WorkbenchBody> {
  /// 右栏当前视图。切分与选材在同一个工作台里交替进行，不再是两个页面。
  SidePanelTab _sideTab = SidePanelTab.inspector;

  /// 上一次跟过的那一步。同一步重复上报（心跳）不重跟——
  /// 否则选中框会闪、滚动位置会跳，人反而看不清
  int? _followedStep;

  /// 跟着 Agent 走：**走人自己点过去时走的同一条路**（[_jumpToReplacement]），
  /// 不另造一套只读的展示——那样人看到的动作和自己操作时不一样，
  /// 反而更不放心。
  void _followAgent() {
    final focus = widget.agentFocus;
    if (focus == null || focus.step == _followedStep) return;
    _followedStep = focus.step;
    final unit = focus.unitIndex;
    if (unit == null || unit < 0 || unit >= widget.editor.units.length) return;

    // 挑素材就切到候选面板；别的事（分析、改切分）留在属性页
    if (focus.wantsCandidates) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _jumpToReplacement(unit, focus.shotIndex);
      });
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.editor.select(focus.shotIndex == null
          ? EditorSelection.unit(unit)
          : EditorSelection.shot(unit, focus.shotIndex!));
    });
  }

  /// 点了时间线上那个数字：选中那一段并把右栏切到「替换素材」。
  ///
  /// 徽标只告诉用户「这儿挑了 3 条」，看不到是哪三条；点它直接落到那一段的
  /// 候选面板，才是一个能闭环的标记。
  void _jumpToReplacement(int unitIndex, int? shotIndex) {
    widget.editor.select(shotIndex == null
        ? EditorSelection.unit(unitIndex)
        : EditorSelection.shot(unitIndex, shotIndex));
    setState(() => _sideTab = SidePanelTab.candidates);
  }

  /// 「只播这一段」（双击时间线上的单元/镜头）
  late final SegmentPlayback _segment = SegmentPlayback(widget.playback);

  /// 拖播放头之前是否正在播——松手后据此恢复，而不是一律停住
  bool _resumeAfterScrub = false;

  @override
  void initState() {
    super.initState();
    widget.editor.addListener(_reportBlockedEdit);
    _followAgent();
  }

  @override
  void didUpdateWidget(WorkbenchBody old) {
    super.didUpdateWidget(old);
    if (old.editor != widget.editor) {
      old.editor.removeListener(_reportBlockedEdit);
      widget.editor.addListener(_reportBlockedEdit);
    }
    _followAgent();
  }

  @override
  void dispose() {
    widget.editor.removeListener(_reportBlockedEdit);
    _segment.dispose();
    super.dispose();
  }

  /// 刚才那一下被「已选替换素材」的锁挡下来了：说清是哪个、为什么，
  /// 并直接给一条去移除素材的路。
  ///
  /// 集中在编辑器变化这一处报，而不是逐个操作入口报——拆分、合并、拖边界、
  /// ±帧步进有十来个调用点，散着写迟早漏掉一个，而漏掉的那个对用户就是
  /// 「点了没反应」。
  void _reportBlockedEdit() {
    final reason = widget.editor.takeBlockedReason();
    if (reason == null || !mounted) return;
    // 拖拽会连着撞很多次，同一句话不重复刷屏
    if (reason == _blockedReason) return;
    _blockedReason = reason;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        // 必须显式给前景色：深色底上用 Material 的默认前景色，出来是一片
        // 灰压灰，真机上根本读不出写的是什么
        content: Text(reason,
            style: const TextStyle(
                fontSize: AppFontSize.body,
                height: 1.5,
                color: AppColors.textPrimary)),
        backgroundColor: AppColors.surfaceCard,
        duration: _blockedNoticeFor,
        // 「去看素材」只在被素材锁挡下时给：播放头出界这类拦截附这个
        // 入口只会把人带去一个不相干的地方
        action: widget.editor.blockedByMaterialLock
            ? SnackBarAction(
                label: '去看素材',
                textColor: AppColors.accentBlueLight,
                onPressed: () =>
                    setState(() => _sideTab = SidePanelTab.candidates),
              )
            : null,
      ));
    // 说完就忘：下次再撞同一处仍然要说
    Future<void>.delayed(_blockedNoticeFor, () {
      if (mounted && _blockedReason == reason) _blockedReason = null;
    });
  }

  String? _blockedReason;
  static const _blockedNoticeFor = Duration(seconds: 4);

  /// 拖动播放头期间必须暂停：画面还在自己往前走的话，用户根本对不准位置。
  /// 同时作废「只播这一段」的约束——他已经自己接管定位了。
  void _onScrubStart() {
    unawaited(_segment.cancel());
    _resumeAfterScrub = widget.playback.isPlaying;
    if (_resumeAfterScrub) unawaited(widget.playback.pause());
  }

  /// 松手后从新位置接着播（拖之前本来就停着的话就保持停着）
  void _onScrubEnd() {
    if (_resumeAfterScrub) unawaited(widget.playback.play());
    _resumeAfterScrub = false;
  }

  /// 转发页面级快捷键到 PlayerPanel 内部同一份播放状态（避免另起一份
  /// `_isPlaying` 导致图标显示不同步）
  final _playerPanelKey = GlobalKey<PlayerPanelState>();

  TimelineGeometry? _geometry;
  double _timelineViewportWidth = 0;

  /// 当前的成片时间轴。**所有交给播放器的位置都要过它**——时间线与切分
  /// 数据用原片刻度，而播放器跑在成片上，整体替换之后两者不再相等
  ComposedTimeline? _axis;

  /// 原片时刻 → 播放器该定位到的成片时刻
  /// 选中项（单元或镜头）在**成片**上的起点。按下标问轴——拿原片毫秒去
  /// 换算是病态方向，调过序就会算到别的段上（见
  /// `docs/2026-09-08-成片时间轴重构-TRD.md` 二、2.2）
  int? _composedStartOfSelection(SegmentationEditorController editor) {
    final sel = editor.selection;
    if (sel == null) return null;
    final axis = _axis;
    if (axis == null) return editor.selectedStartMs;
    final u = sel.unitIndex;
    if (u < 0 || u >= axis.units.length) return null;
    final s = sel.shotIndex;
    return s == null
        ? axis.startOf(u)
        : (axis.composedShotStart(u, s) ?? axis.startOf(u));
  }

  /// 双击某一格要播的**成片**区间。整体替换的单元里点某一镜时给整段——
  /// 那些镜头在成片里已经不存在了，单独播它没有意义
  /// 预览舞台：画面本体 + **实时**字幕层。
  ///
  /// 字幕不烧进切片、由这一层现画，所以调样式（位置/字号/颜色/衬底）既不
  /// 跑 ffmpeg 也不换播放源——不转圈、不跳回片头
  Widget? _stage() {
    final video = widget.videoWidget;
    final at = widget.subtitleAt;
    if (video == null || at == null) return video;
    return Stack(fit: StackFit.expand, children: [
      video,
      PreviewSubtitleLayer(
        positionMs: widget.playhead,
        textAt: at,
        style: widget.subtitleStyle,
        onTap: widget.onSubtitleTap,
        onDragEnd: widget.onSubtitleDragEnd,
      ),
    ]);
  }

  (int, int)? _playRange(ComposedTimeline axis, int unitIndex, int? shotIndex) {
    if (unitIndex < 0 || unitIndex >= axis.units.length) return null;
    if (shotIndex != null) {
      final a = axis.composedShotStart(unitIndex, shotIndex);
      final b = axis.composedShotEnd(unitIndex, shotIndex);
      if (a != null && b != null && b > a) return (a, b);
    }
    final start = axis.startOf(unitIndex);
    final end = start + axis.durationOf(unitIndex);
    return end > start ? (start, end) : null;
  }

  /// 缩放倍数一律从 geometry 反推，不维护独立字段——滚轮/触控板/跟随播放头
  /// 都只更新 geometry，滑块若自己记历史值就会与实际缩放脱节，下一次拖动
  /// 以错误基准算 factor，出现「往左拖想缩小、画面反而放大」。
  double get _zoomLevel => _geometry?.zoomLevel(
      viewportWidthPx: _timelineViewportWidth) ??
      1.0;

  /// 页面级快捷键转发：与 PlayerPanel 内部按钮走同一份播放状态
  void _togglePlaybackFromShortcut() =>
      _playerPanelKey.currentState?.togglePlay();

  void _stepPlaybackFromShortcut(int frames) =>
      _playerPanelKey.currentState?.stepFrame(frames);

  void _onZoomChanged(double value) {
    final geometry = _geometry;
    if (geometry == null || _timelineViewportWidth <= 0) return;
    final current = _zoomLevel;
    if (current <= 0) return;
    final factor = value / current;
    setState(() {
      _geometry = geometry.zoomAt(_timelineViewportWidth / 2, factor,
          viewportWidthPx: _timelineViewportWidth);
    });
  }

  /// 页面级全局快捷键作用域：包裹三栏 + 时间线（不含顶栏/底部栏，那两处的
  /// 按钮本就该响应系统默认的空格/回车激活）。焦点无论落在单元列表、检查器
  /// 的步进按钮还是时间线上，空格/←/→都会被这里截获转发给播放器；焦点若
  /// 落在台词输入框，`workbench_shortcuts.dart` 里 Action 的 `isEnabled`
  /// 会返回 false，按键继续正常走文本编辑逻辑（详见该文件文档）。
  @override
  Widget build(BuildContext context) {
    final editor = widget.editor;
    final playback = widget.playback;
    return Shortcuts(
      shortcuts: workbenchPlaybackShortcuts,
      child: Actions(
        actions: workbenchPlaybackActions(
          onTogglePlay: _togglePlaybackFromShortcut,
          onStepFrame: _stepPlaybackFromShortcut,
          onUndo: editor.undo,
          onRedo: editor.redo,
          onShuttle: _shuttle,
          onSeekEdge: (toStart) => playback
              .seekMs(toStart ? 0 : (_axis?.totalMs ?? editor.durationMs)),
          onSelectAdjacent: (delta) => _selectAdjacent(editor, playback, delta),
          onShortcutsHelp: () => showShortcutsCheatSheet(context),
        ),
        // 输入框交出焦点之后由它接住，否则焦点落空、整套键位一起哑掉。
        // **必须摆在 Actions 里面**：按键是从拿着焦点的那个节点往上找动作的，
        // 摆到 Actions 外面就找不到 —— 空格能匹配上，却没人执行
        child: KeyboardHome(
            child: LayoutBuilder(builder: (context, page) {
          // **时间线要多高，是按它自己有多少内容算出来的，不是一个死比例。**
          //
          // 原来写死 5:4（时间线 44%）。1440×900 下 body 是 787px，时间线区
          // 拿到 350px，而六条轨加工具条要 370px——第六条轨（音频波形）整条
          // 落在可视区外，人不滚动就永远看不到波形，而波形正是定位切点的
          // 主要依据（2026-09-09 设计走查真机截图：最底下只到「画面」轨）。
          //
          // 现在按内容要多少给多少，两头都夹住：
          // - 上限 55%：再多就把预览挤没了，这里毕竟是「看画面」的地方
          // - 下限 35%：CLAUDE.md 要「时间线占比要充足（参考剪映约 40%）」，
          //   屏幕再高也不能让它退化成一条缝
          final wanted =
              TimelineTracks.totalHeight + _timelineToolbarHeight;
          // 高度无界时（放进可滚容器里）没有「占几成」可言，就按内容给
          final timelineHeight = page.maxHeight.isFinite
              ? wanted.clamp(page.maxHeight * 0.35, page.maxHeight * 0.55)
              : wanted;
          return Column(
          children: [
            Expanded(
              child: LayoutBuilder(builder: (context, box) {
                // 挑素材时把播放器两侧的死黑还给候选面板：素材是 9:16 竖屏，
                // 播放器横向再宽也用不上，而候选网格的宽度直接换成
                // 「一屏能看到几条」
                final picking = _sideTab == SidePanelTab.candidates;
                final widths = workbenchPanelWidths(
                  box.maxWidth,
                  stageHeight: box.maxHeight,
                  candidatesActive: picking,
                );
                // **一条成片轴，两个面板共用**：左栏和属性栏上的时间数字全是
                // 「这一段在成片里落到哪儿」，每次现算。存的永远是原片毫秒
                // （那是切分点，是数据本身）——把成片时间存进库的话，加一个
                // 单元就要重写每一个单元再落盘，写一半崩了就烂在盘上。
                // 实测全量重算 0.4µs（60 单元 2700 镜也只要 3.5µs），
                // 而时间线光画省略号每帧就要 2.1ms
                // **每次要用时现算，不缓存成一个变量传下去。**
                // 缓存的那个是外层 build 时算的，而编辑（逐帧微调、拆分）
                // 只 notifyListeners()，各面板自己重建时它已经旧了——
                // 数字停在改动之前，正是「改了没反应」那一类
                // （2026-09-08 真机：连点三次「+1 帧」属性栏只动 1 帧）
                ComposedTimeline currentAxis() => ComposedTimeline.of(
                    units: editor.units,
                    wholeDurations: widget.composedDurations);
                return Row(
                children: [
                  SizedBox(
                    width: widths.left,
                    child: UnitListPanel(
                      composedDurationOf: (i) => widget.composedDurations[i],
                      controller: editor,
                      onAddUnit: widget.onAddUnit,
                      onReorderUnit: widget.onReorderUnit,
                      onDeleteUnit: widget.onDeleteUnit,
                      canDeleteUnit: widget.canDeleteUnit,
                      onUnitTap: (unit) =>
                          playback.seekMs(currentAxis().startOf(unit.index)),
                    ),
                  ),
                  const VerticalDivider(width: 1, color: AppColors.border),
                  Expanded(
                    // 跟着编辑重建：片长会被拆分、微调、加单元改掉，
                    // 停在旧值上就会末尾对不齐
                    child: AnimatedBuilder(
                      animation: editor,
                      builder: (context, _) => PlayerPanel(
                        key: _playerPanelKey,
                        playback: playback,
                        videoWidget: _stage(),
                        // **成片总长，不是原片总长**：手加的单元、整体替换都会
                        // 改变片长。用原片总长的话末尾对不上时间线——真机上
                        // 时间线画到 01:46 而播放器只到 01:36（2026-09-08）
                        durationMs: currentAxis().totalMs,
                        fps: editor.fps,
                      ),
                    ),
                  ),
                  const VerticalDivider(width: 1, color: AppColors.border),
                  SizedBox(
                    // 随窗口伸缩：窄窗口收到 300（再宽就会把播放控制条挤到
                    // 点不中），宽窗口把播放器两侧的死黑还给检查器
                    width: widths.right,
                    child: Column(
                      children: [
                        // **角标跟着选中的单元走**，所以要听 editor：
                        // 选中变化不会让外面那层重建（_onEditorChanged 是
                        // 拖拽期间每帧都调的地方，不能在那儿 setState），
                        // 不听的话点到哪个单元角标都不动
                        ListenableBuilder(
                          listenable: editor,
                          builder: (context, _) => SidePanelTabBar(
                            current: _sideTab,
                            badges: {
                              SidePanelTab.candidates: candidateBadgeText(
                                  widget.replacements,
                                  unitIndex: editor.selection?.unitIndex),
                            },
                            onChanged: (t) => setState(() => _sideTab = t),
                          ),
                        ),
                        Expanded(
                          // 切 tab 时淡进淡出，不是硬闪一下。
                          // 120ms 短到不拖慢操作，但足够让眼睛跟上
                          // 「换了一块内容」这件事（2026-09-10 走查）
                          child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 120),
                          child: KeyedSubtree(
                          key: ValueKey(_sideTab),
                          child: switch (_sideTab) {
                            SidePanelTab.inspector => InspectorPanel(
                                controller: editor,
                                fps: editor.fps,
                                onSplitAtPlayhead: () =>
                                    _splitAtPlayhead(context, editor, playback),
                                // 逐帧调边界时预览跟到那一帧（先停播——
                                // 画面自己往前走的话根本对不准）
                                onSeekTo: (ms) {
                                  playback.pause();
                                  playback.seekMs(ms);
                                },
                                readOnly: widget.readOnly,
                                // 界面按位置说话，方案按身份存——在这里翻译
                                voiceOf: (i) => i >= 0 &&
                                        i < editor.units.length
                                    ? widget.voices
                                        .voiceOf(editor.units[i].uid)
                                    : null,
                                onChangeVoice: widget.onChangeVoice,
                                previewVoice: widget.previewVoice,
                                unitTagEditor: widget.unitTagEditor,
                                baseCard: widget.baseCard,
                                blankTask: widget.blankTask,
                                composedDurationOf: (i) =>
                                    widget.composedDurations[i],
                                materialAudioDefault: widget.materialAudioDefault,
                                shotReplaced: widget.shotReplaced,
                                shotMaterialVoiceover:
                                    widget.shotMaterialVoiceover,
                                onEditUnitTags: widget.onEditUnitTags,
                                onEditShotTags: widget.onEditShotTags,
                                subtitleLinesOf: widget.subtitleLinesOf,
                                subtitleEdited: widget.subtitleEdited,
                                onSubtitleChanged: widget.onSubtitleChanged,
                                onSubtitleReset: widget.onSubtitleReset,
                                onShotMaterialAudioChanged:
                                    widget.onShotMaterialAudioChanged,
                                sourceAudioDefault: widget.sourceAudioDefault,
                                onShotSourceAudioChanged:
                                    widget.onShotSourceAudioChanged,
                                unitVoiceSwapped: widget.unitVoiceSwapped,
                                hasVocals: widget.hasVocals,
                                hasBackground: widget.hasBackground,
                              ),
                            SidePanelTab.candidates =>
                              widget.candidatePanel ?? const _NoCandidatePanel(),
                          },
                          ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                );
              }),
            ),
            const Divider(height: 1, color: AppColors.border),
            SizedBox(
              height: timelineHeight,
              child: _buildTimelineArea(editor, playback),
            ),
          ],
          );
        })),
      ),
    );
  }

  /// ↑↓ 在相邻对象间移动选中，并把播放头同步到该对象起点——只改选中不动
  /// 播放头的话，用户按了半天方向键，播放器画面纹丝不动，会以为没生效。
  void _selectAdjacent(
      SegmentationEditorController editor, PlaybackController playback, int delta) {
    editor.selectAdjacent(delta);
    final startMs = _composedStartOfSelection(editor);
    if (startMs != null) playback.seekMs(startMs);
  }

  /// JKL 走带：L 正向播放、K 停、J 反向。
  ///
  /// 真正的 JKL 是变速走带（连按 J/L 加速到 2×/4×），需要播放器暴露倍速
  /// 控制；[PlaybackController] 目前没有这个能力，所以 J 退化为「暂停并
  /// 逐帧倒退」——保证按下去有确定的、符合方向直觉的反馈，而不是无反应。
  /// 变速走带已记入待办。
  void _shuttle(int direction) {
    final playback = widget.playback;
    if (direction > 0) {
      playback.play();
      return;
    }
    playback.pause();
    if (direction < 0) {
      playback.stepFrames(-1, widget.editor.fps);
    }
  }

  /// 「在游标处拆分」。失败原因（没选中/播放头出界/贴边/素材锁定）由
  /// 编辑器给出完整人话，走 [_reportBlockedEdit] 统一显示——这里不再
  /// 自己拼一句笼统的（「播放头不在所选范围内」这种不带主语的拒绝，
  /// 真机上把同事困住过）
  void _splitAtPlayhead(BuildContext context, SegmentationEditorController editor,
      PlaybackController playback) {
    editor.splitSelectedAt(playback.positionMs);
  }

  Widget _buildTimelineArea(
      SegmentationEditorController editor, PlaybackController playback) {
    return Container(
      color: AppColors.surface,
      child: Column(
        children: [
          // 工具条按钮的禁用态取自编辑器（canUndo/canRedo/selection），必须
          // 自己监听：页面级 setState 已被移除（播放时每秒 30 次重建整页的
          // 性能问题），不能再指望父级顺手帮它重建
          // 工具条内的按钮与缩放滑块要保留自己的键盘操作，不能被页面级
          // 快捷键截走（见 workbenchControlKeyPassthrough 的说明）
          Shortcuts(
            shortcuts: workbenchControlKeyPassthrough,
            child: AnimatedBuilder(
              animation: editor,
              builder: (context, _) => _buildTimelineToolbar(editor),
            ),
          ),
          Expanded(
            // **必须跟着编辑器重建**：换轴那一步就写在下面的 builder 里，
            // 而 LayoutBuilder 只在**尺寸变了**才重跑。切分改了（合并两镜、
            // 拆一镜、拖边界）尺寸一个像素都不变，于是那一步永远不跑——
            // 时间线继续用着改动之前那条轴，镜头位置全是旧的，单元尾部空出
            // 一截；退回任务列表再进来（整棵树重建）就又好了。
            // 用户原话：「连续合并两次就又是这个样子，返回首页再进去就显示
            // 正常了」（2026-09-09 真机）。
            //
            // 属性栏那边早就栽过同一件事，结论一样：**轴要在自己的重建里
            // 现算**（见 test/features/workbench/axis_refreshes_on_edit_test.dart）
            child: AnimatedBuilder(
              animation: editor,
              builder: (context, _) => LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                // 时间线画的是**成片**：整体替换之后那一格按新长度画，
                // 后面的跟着挪。轴变了就换掉，但保持缩放与滚动
                final axis = ComposedTimeline.of(
                    units: editor.units,
                    wholeDurations: widget.composedDurations);
                _axis = axis;
                // **比的是整条布局，不能只比总时长**：调整单元顺序不改变总长，
                // 只比总时长的话时间线会一直用着拖动之前那份轴——左栏顺序变了、
                // 时间线纹丝不动（2026-09-07 真机 bug）
                final currentAxis = _geometry?.axis;
                if (_geometry != null &&
                    !(currentAxis?.sameLayoutAs(axis) ?? false)) {
                  _geometry = _geometry!.withAxis(axis);
                }
                if (width != _timelineViewportWidth) {
                  final geometry = _geometry;
                  // 窗口 resize：适应窗口状态下跟着重新铺满，放大状态下保持
                  // 缩放并把滚动夹回合法范围（判定要用**变化前**的宽度）
                  _geometry = geometry == null
                      ? TimelineGeometry.fit(
                          durationMs: editor.durationMs,
                          viewportWidthPx: width,
                          axis: axis)
                      : geometry.resizedTo(
                          oldViewportWidthPx: _timelineViewportWidth,
                          newViewportWidthPx: width);
                  _timelineViewportWidth = width;
                }
                return TimelineView(
                  controller: editor,
                  geometry: _geometry!,
                  subtitleEdited: widget.subtitleEdited,
                  subtitleTextOf: widget.subtitleTextOf,
                  subtitleLineCount: widget.subtitleLineCount,
                  onEditSubtitleBlock: widget.onEditSubtitleBlock,
                  // 字幕轨按段画、拖完整份交回去
                  subtitleLinesOf: widget.subtitleLinesOf,
                  onSubtitleChanged: widget.onSubtitleChanged,
                  // 只为重画判定：改字幕不动 units
                  subtitleTrack: widget.subtitleTrack,
                  media: widget.media,
                  playhead: widget.playhead,
                  mediaStatus: widget.mediaStatus,
                  thumbStatus: widget.thumbStatus,
                  waveStatus: widget.waveStatus,
                  baseMedia: widget.baseMedia,
                  onSeek: (ms) {
                    // 用户自己定位了，上一段的「播到这儿停」约束随即作废
                    unawaited(_segment.cancel());
                    playback.seekMs(ms);
                  },
                  onGeometryChanged: (g) => setState(() => _geometry = g),
                  onScrubStart: _onScrubStart,
                  onScrubEnd: _onScrubEnd,
                  // **按下标问成片轴，不拿原片毫秒换算**：endMs 是开区间，
                  // 换算会落到相邻那一段身上——手加的单元拖到最前之后，
                  // 原片里最后那个单元的终点被算成 0，播放区间翻转成
                  // 「从 104 秒播到 0 秒」（2026-09-08 真机：U6 不能正常播放）
                  onPlaySegment: (unitIndex, shotIndex) {
                    final range = _playRange(axis, unitIndex, shotIndex);
                    if (range == null) return;
                    unawaited(_segment.play(range.$1, range.$2, editor.fps));
                  },
                  clock: widget.clock ?? DateTime.now,
                  bgm: widget.bgm,
                  voices: widget.voices,
                  replacements: widget.replacements,
                  composedDurations: widget.composedDurations,
                  onReplacementBadgeTap: _jumpToReplacement,
                  onBgmRangeSelected: widget.onBgmRangeSelected,
                  onBgmResize: widget.onBgmResize,
                  onBgmDelete: widget.onBgmDelete,
                  onBgmSegmentTap: widget.onBgmSegmentTap,
                  readOnly: widget.readOnly,
                );
              },
            ),
            ),
          ),
        ],
      ),
    );
  }

  /// 时间线工具条实际占的高度（撤销/重做/拆分/合并 + 缩放）。
  /// 时间线区要多高是「轨道总高 + 它」算出来的
  static const double _timelineToolbarHeight = 40;

  /// 缩放滑杆的宽度：够拖出 20 档，又不至于横跨整条工具条。
  ///
  /// 两侧原来各摆一个放大镜图标，不可点、纯装饰——去掉之后这一行省下
  /// 32px，正好放得下「铺满窗口」这个真能按的按钮
  static const double _zoomSliderWidth = 160;

  Widget _buildTimelineToolbar(SegmentationEditorController editor) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Row(
        children: [
          _undoRedoButton(
            key: const Key('timeline-undo-btn'),
            icon: Icons.undo,
            enabled: editor.canUndo,
            onTap: editor.undo,
          ),
          _undoRedoButton(
            key: const Key('timeline-redo-btn'),
            icon: Icons.redo,
            enabled: editor.canRedo,
            onTap: editor.redo,
          ),
          const SizedBox(width: AppSpacing.sm),
          const _ToolbarDivider(),
          const SizedBox(width: AppSpacing.sm),
          // 拆分/合并在时间线上也给入口：此前只能从右侧检查器触发，而用户
          // 调整切分时视线与鼠标都在时间线上，来回横跨整个窗口很别扭
          _undoRedoButton(
            key: const Key('timeline-split-btn'),
            icon: Icons.content_cut,
            tooltip: '在游标处拆分所选（台词语义单元或视觉镜头）',
            enabled: !widget.readOnly && editor.selection != null,
            onTap: () => _splitAtPlayhead(context, editor, widget.playback),
          ),
          _undoRedoButton(
            key: const Key('timeline-merge-btn'),
            icon: Icons.merge_type,
            tooltip: '把所选并入前一个',
            enabled: !widget.readOnly && editor.selection != null,
            onTap: editor.mergeSelectedWithPrevious,
          ),
          // 编辑工具靠左、缩放靠右（剪映 / Final Cut 都是这个位置）。
          // **滑杆不能用 Expanded 撑满**：它会横跨整条工具条一千多像素，
          // 屏幕上看到的是「最左边一个小蓝点、最右边一个孤零零的放大镜」，
          // 中间一千像素什么都没有（2026-09-09 设计走查）
          // Flexible 吃掉剩余宽度、Align 把滑杆顶到右边、ConstrainedBox 给它
          // 封顶。**三样缺一不可**：换成 Spacer + 固定宽度，窄窗口
          // （测试用的 800px）下这一行会溢出 31px
          Flexible(
            child: Align(
              alignment: Alignment.centerRight,
              child: ConstrainedBox(
                constraints:
                    const BoxConstraints(maxWidth: _zoomSliderWidth),
                child: Slider(
                  key: const Key('timeline-zoom-slider'),
                  value: _zoomLevel.clamp(1.0, TimelineGeometry.maxZoom),
                  min: 1,
                  max: TimelineGeometry.maxZoom,
                  // 未走过的那一段轨道要看得见：默认色在这个底上几乎是隐形的，
                  // 屏幕上只剩一个孤零零的蓝点，看不出它是个可以拖的滑杆
                  // （2026-09-09 设计走查）
                  inactiveColor: AppColors.border,
                  onChanged: _onZoomChanged,
                ),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          // 缩放到看得见整条片子：拖到一半找不着北时的回家键
          _undoRedoButton(
            key: const Key('timeline-zoom-fit-btn'),
            icon: Icons.fit_screen_outlined,
            tooltip: '整条片子铺满窗口',
            enabled: _zoomLevel > 1.0001,
            onTap: () => _onZoomChanged(1),
          ),
        ],
      ),
    );
  }

  /// 时间线工具条的撤销/重做按钮：对标剪映的可发现性，与 ⌘Z/⇧⌘Z 快捷键
  /// 是同一份撤销栈；[enabled] 为 false 时降透明度且不响应点击。
  Widget _undoRedoButton({
    required Key key,
    required IconData icon,
    required bool enabled,
    required VoidCallback onTap,
    String? tooltip,
  }) {
    return IconButton(
      key: key,
      onPressed: enabled ? onTap : null,
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      icon: Icon(
        icon,
        size: 16,
        color: enabled
            ? AppColors.textPrimary
            : AppColors.textTertiary.withValues(alpha: 0.35),
      ),
    );
  }
}

/// 工具条分组分隔线：把撤销/编辑/缩放三组操作在视觉上分开
class _ToolbarDivider extends StatelessWidget {
  const _ToolbarDivider();

  @override
  Widget build(BuildContext context) => Container(
        width: AppStroke.hairline,
        height: 16,
        color: AppColors.border,
      );
}

/// 「替换素材」视图尚未接入时的占位。
///
/// 如实说明为什么空着，而不是留一片空白让用户以为坏了。
class _NoCandidatePanel extends StatelessWidget {
  const _NoCandidatePanel();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.all(AppSpacing.lg),
        child: Text('这条任务还没有可挑选的替换素材。',
            style: TextStyle(
                fontSize: AppFontSize.body, color: AppColors.textSecondary)),
      );
}
