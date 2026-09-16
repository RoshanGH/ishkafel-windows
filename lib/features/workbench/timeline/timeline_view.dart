import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ishkafel/core/editing/segmentation_editor_controller.dart';
import 'package:ishkafel/core/audio/bgm_plan.dart';
import 'package:collection/collection.dart';
import 'package:ishkafel/core/subtitle/subtitle_edit.dart';
import 'package:ishkafel/core/time/timecode.dart';
import 'package:ishkafel/core/subtitle/subtitle_overlay.dart';
import 'package:ishkafel/core/subtitle/subtitle_track.dart';
import 'bgm_edge_hit.dart';
import 'subtitle_segments.dart';
import 'package:ishkafel/core/audio/voice_plan.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';
import 'package:ishkafel/core/log/app_log.dart';
import 'package:ishkafel/features/workbench/timeline/bgm_track.dart';
import 'package:ishkafel/features/workbench/timeline/text_layout_cache.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_geometry.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_hit_tester.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_painter.dart';
import 'package:ishkafel/features/workbench/timeline_media_builder.dart';
import 'track_px.dart';

/// 时间线视图：手势交互 + 缩略图预解码 + 监听编辑器状态重绘
///
/// 缩放本身由外部工具条（slider）驱动，本组件只接收 [geometry] 展示；水平拖拽
/// 命中边界手柄（±6px 容差，见 [TimelineHitTester]）时驱动编辑器移动边界，否则
/// 视为滚动，通过 [onGeometryChanged] 把新的 geometry 上抛给持有状态的父级。
///
/// 单击块体默认选中所在语义单元（粗粒度）；双击镜头轨块体才进入镜头层选中
/// （细粒度编辑入口），点击刻度轨触发 [onSeek]。
///
/// 双击通过在 [onTapUp] 里手动记录上一次点击的时间与位置来判定，不使用
/// [GestureDetector.onDoubleTapDown]：同一个手势识别器上同时挂载双击与单击/拖拽
/// 会让 `DoubleTapGestureRecognizer` 在竞技场里持有指针，测试结束时它仍握着一个
/// 未消解的 [kDoubleTapTimeout]（300ms）倒计时定时器，触发测试框架的
/// "timer still pending" 检查失败；因此改为在单击回调里自行判断"双击"。
///
/// 拖拽起点的坐标读取使用 [DragStartBehavior.down]（见 [GestureDetector] 构造），
/// 让 [onHorizontalDragStart] 报告的是指针刚按下时的原始坐标，而非默认
/// [DragStartBehavior.start] 下"越过系统触摸容差（约 18~20px）后手势识别器胜出
/// 时"的坐标——边界手柄的命中容差只有 ±6px，用默认行为会把合法的边界拖拽误判
/// 成滚动。这与双击定时器泄漏是两个独立问题。
///
/// 命中边界手柄时会开启一个"拖拽会话"（[SegmentationEditorController.
/// beginDragSession]/[endDragSession]）：一次连续拖拽会触发几十次
/// [onHorizontalDragUpdate]，若每次都单独调用 moveUnitBoundary/moveShotBoundary
/// 都各自入 undo 栈，用户要撤销几十次才能回退一次拖动；会话期间的移动不逐次
/// 入栈，拖拽结束时才合并为一条记录。
class TimelineView extends StatefulWidget {
  final SegmentationEditorController controller;
  final TimelineGeometry geometry;
  final TimelineMedia? media;
  /// 播放位置。用 [ValueListenable] 而不是普通 int：播放时它每秒变化 30 次，
  /// 只让包住 [CustomPaint] 的那一层重建，外层三栏面板完全不动。
  final ValueListenable<int> playhead;

  /// 抽帧/波形就绪状态，未就绪时时间线画占位而不是留白
  final TimelineMediaStatus mediaStatus;

  /// 画面轨 / 音频轨各自的状态（两条轨会各坏各的）
  final TimelineMediaStatus? thumbStatus;
  final TimelineMediaStatus? waveStatus;

  /// 底片固定过的单元各自的画面与波形（单元 uid → 那条素材的）。
  /// 那几段的画面来自素材，原片那份缩略图里根本没有它们
  final Map<String, TimelineMedia> baseMedia;
  final ValueChanged<int> onSeek;
  final ValueChanged<TimelineGeometry> onGeometryChanged;

  /// 开始/结束拖动播放头。调用方据此暂停播放并在松手后恢复——
  /// 拖动时画面若还在自己往前走，用户根本对不准位置。
  final VoidCallback? onScrubStart;
  final VoidCallback? onScrubEnd;

  /// 双击某一块：从它的起点播到它的终点（含头不含尾，单位毫秒）。
  /// 逐段试看是审片的主要动作，比「从这里一直播下去」有用得多。
  /// 双击某一格：播它。**给的是列表下标，不是毫秒**——毫秒要经过
  /// 「原片 → 成片」换算，而 endMs 是开区间，会落到相邻那一段身上。
  /// 手加的单元拖到最前之后，原片里最后那个单元的终点被算成 0，
  /// 播放区间翻转成「从 104 秒播到 0 秒」（2026-09-08 真机：「U6 不能正常
  /// 播放」）。下标交给上层去问成片轴，精确且与顺序无关。
  /// [shotIndex] 为 null 表示播整个单元
  final void Function(int unitIndex, int? shotIndex)? onPlaySegment;

  /// 这一镜有几行字幕（多于一行时在块上标个数——轨上只画得下头一句）
  final int Function(int unitIndex, int shotIndex)? subtitleLineCount;

  /// 双击字幕轨上的某一块：就地改这一镜的字幕。
  ///
  /// 给的是**块体在屏幕坐标系里的位置**，上层照着它把浮层贴上去。
  /// 字幕轨只有 22px 高、窄镜头的块可能只有几十像素宽——把块体本身变成
  /// 输入框做不出能用的东西，所以弹一个定宽的浮层（用户 2026-09-08：
  /// 「我双击那个字幕轨上的那个字幕的时候，能不能在那个地方改？」）
  final void Function(int unitIndex, int shotIndex, Rect blockOnScreen)?
      onEditSubtitleBlock;

  /// 这一镜的字幕。轨上按段画、拖动时算位置都要它
  final List<SubtitleLine> Function(int unitIndex, int shotIndex)?
      subtitleLinesOf;

  /// 拖完一段交出去：整份行交回去（与属性卡同一条通路）
  final void Function(int unitIndex, int shotIndex, List<SubtitleLine> lines)?
      onSubtitleChanged;

  /// 手改过的字幕。**只为重画判定**：改字幕不动 units，不给画布一个会变的
  /// 值，轨上那一句就一直是旧的（见 [TimelinePainter.subtitleTrack]）
  final SubtitleTrack subtitleTrack;

  /// 配乐方案（画在配乐轨上）
  final BgmPlan bgm;

  /// 换音色方案（换过的单元在块体底边画一道绿杠）
  final VoicePlan voices;

  /// 当前替换方案：时间线上标出「哪几段挑好了素材、各几条」
  final List<UnitReplacement> replacements;

  /// 被整体替换的单元在成片里有多长（单元下标 → 毫秒）
  final Map<int, int> composedDurations;

  /// 这一镜的字幕手改过没有（字幕轨上标一下）
  final bool Function(int unitIndex, int shotIndex)? subtitleEdited;

  /// 字幕轨上画的预览文字
  final String Function(int unitIndex, int shotIndex)? subtitleTextOf;

  /// 点了那个数字徽标：跳到右栏对应的那一段（shotIndex 为 null 表示整体替换）
  final void Function(int unitIndex, int? shotIndex)? onReplacementBadgeTap;

  /// 在配乐轨上框选完一段连续镜头（全片打平下标，含两端）
  final void Function(int fromShot, int toShot)? onBgmRangeSelected;

  /// 点了配乐轨上已有的一段（用于换曲/移除）
  final void Function(BgmSegment segment)? onBgmSegmentTap;

  /// 拖段落边界改长度：把起点是 [startUnit] 的那一段改成 [newStart]..[newEnd]
  final void Function(int startUnit, int newStart, int newEnd)? onBgmResize;

  /// 删掉起点是 [startUnit] 的那一段。此前删一段要先点开素材库浮层再点移除，
  /// 太重了
  final void Function(int startUnit)? onBgmDelete;

  /// 判定双击窗口用的时钟。测试注入——`tester.pump(Duration)` 推进的是框架的
  /// 假时钟，`DateTime.now()` 纹丝不动，不注入就没法验证「隔太久不算双击」。
  final DateTime Function() clock;

  /// 只读回看模式（评审 Important 1）：true 时忽略会改数据的手势（边界
  /// 拖拽），但保留选中、滚动、缩放、点刻度 seek——回看仍要能浏览。
  /// 默认 false（编辑态，行为与此前一致）。
  final bool readOnly;

  const TimelineView({
    super.key,
    required this.controller,
    required this.geometry,
    this.subtitleEdited,
    this.subtitleTextOf,
    this.subtitleLineCount,
    this.media,
    required this.playhead,
    this.mediaStatus = TimelineMediaStatus.ready,
    this.thumbStatus,
    this.waveStatus,
    this.baseMedia = const {},
    required this.onSeek,
    required this.onGeometryChanged,
    this.onScrubStart,
    this.onScrubEnd,
    this.onPlaySegment,
    this.onEditSubtitleBlock,
    this.subtitleLinesOf,
    this.onSubtitleChanged,
    this.subtitleTrack = const SubtitleTrack.empty(),
    this.bgm = BgmPlan.empty,
    this.voices = VoicePlan.empty,
    this.replacements = const [],
    this.composedDurations = const {},
    this.onReplacementBadgeTap,
    this.onBgmRangeSelected,
    this.onBgmSegmentTap,
    this.onBgmResize,
    this.onBgmDelete,
    DateTime Function()? clock,
    this.readOnly = false,
  }) : clock = clock ?? DateTime.now;

  @override
  State<TimelineView> createState() => _TimelineViewState();
}

class _TimelineViewState extends State<TimelineView> {
  List<ui.Image?>? _thumbImages;

  /// 正在配乐轨上框选的镜头区间（起点下标 / 当前下标）。
  /// 非空即表示这次拖拽是在选配乐区间，不是拖边界也不是滚动。
  ({int from, int to})? _bgmSelecting;

  /// 正在拖某一段的边界：(这一段的起点, 拖的是哪一头, 当前的另一头)
  ({int startUnit, BgmEdge edge, int from, int to})? _bgmResizing;

  /// 正在拖的那一段字幕：拖的是谁、抓的哪一头、拖动中的那份行。
  ///
  /// **拖动中只改这份临时的**，松手才交出去：每移动一像素就提交等于每像素
  /// 重烧一次字幕（属性卡那边「离开才提交」是同一个理由）
  ({
    int unitIndex,
    int shotIndex,
    int lineIndex,
    SubtitleGrab grab,
    double startDx,
    List<SubtitleLine> original,
    List<SubtitleLine> lines,
  })? _subsDragging;

  /// 本次拖拽是「拖播放头」而不是「拖时间线」
  bool _scrubbing = false;
  double _viewportWidth = 0;
  /// 上一次按下的**硬件时间戳**（引擎在事件产生时打的，不受 UI 卡顿影响）
  Duration? _lastDownTs;

  /// 这一下算不算双击的第二下——按下那一刻就定好，tap-up 只是取用
  bool _pendingDoubleTap = false;
  Offset? _lastTapPosition;

  /// 缩略图解码请求的递增序号：连续两次 media 变更时，慢的那次解码结果到达
  /// 时已不是最新请求，需丢弃并 dispose，避免覆盖新结果（竞态）。
  int _decodeRequestId = 0;

  /// 跨帧复用的文字排版缓存（时间线每帧几十段文字，内容几乎不变）
  final _textCache = TextLayoutCache();

  @override
  void initState() {
    super.initState();
    _decodeThumbs(widget.media);
    _decodeBaseThumbs(widget.baseMedia);
    widget.playhead.addListener(_followPlayhead);
  }

  @override
  void didUpdateWidget(covariant TimelineView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.media, widget.media)) {
      _decodeThumbs(widget.media);
    }
    // 底片那几份是按 uid 存的 map；上游每次换新实例，这里比引用就够
    if (!identical(oldWidget.baseMedia, widget.baseMedia)) {
      _decodeBaseThumbs(widget.baseMedia);
    }
    if (!identical(oldWidget.playhead, widget.playhead)) {
      oldWidget.playhead.removeListener(_followPlayhead);
      widget.playhead.addListener(_followPlayhead);
    }
  }

  /// 播放头跑出可视区时把它带回来（对标剪映/FCP 的时间线跟随）。
  ///
  /// 放大之后视口只覆盖全片的一小段，一播放播放头几秒就跑到视口外，用户
  /// 要么手动追着滚、要么只能缩回 fit——放大功能等于废掉一半。
  ///
  /// 只在**跑出去**时才滚（还在视野里就不动），避免每帧微调让画面无谓抖动。
  /// 滚动后把播放头放在视口靠左三分之一处，留出更多"接下来要播的内容"，
  /// 这是视频工具的通行做法。
  ///
  /// 用户手动平移/缩放后临时停跟随（[_followSuspended]）：否则播放中想看看
  /// 别处，下一个 tick（≤33ms）就把视口拽回去，等于不让人看。播放头重新
  /// 进入视野时视为"用户已经追上"，自动恢复跟随——暂停不能是永久的，
  /// 否则浏览过一次之后播放头就再也不会被带回来。
  void _followPlayhead() {
    if (_viewportWidth <= 0) return;
    final geometry = widget.geometry;
    // fit 状态下整片都在视口里，没有滚动余地
    if (geometry.totalWidthPx <= _viewportWidth) return;

    // 播放头本来就是**成片**毫秒（播放器直接给的），不能再走一次
    // 「原片 → 成片」换算——那会把它当原片时刻，跟随滚动就跑偏了
    final x = geometry.composedMsToPx(widget.playhead.value);
    if (x >= 0 && x <= _viewportWidth) {
      _followSuspended = false;
      return;
    }
    if (_followSuspended) return;

    final targetScroll = geometry.composedMsToPx(widget.playhead.value) +
        geometry.scrollPx -
        _viewportWidth / 3;
    final next = geometry.scrolledBy(targetScroll - geometry.scrollPx,
        viewportWidthPx: _viewportWidth);
    widget.onGeometryChanged(next);
  }

  @override
  void dispose() {
    _textCache.clear();
    widget.playhead.removeListener(_followPlayhead);
    // 兜底：若卸载发生在拖拽会话进行中（Flutter 手势系统在卸载路径下不保证
    // onHorizontalDragEnd/onHorizontalDragCancel 一定会触发），必须显式结束
    // 会话，否则 controller._dragSessionSnapshot 永久非空，此后所有编辑都会
    // 静默跳过 undo 入栈，用户撤销功能彻底失效且无任何提示。该方法本身是
    // 幂等的：不在会话中调用无副作用。
    widget.controller.endDragSession();
    _disposeThumbImages(_thumbImages);
    super.dispose();
  }

  void _disposeThumbImages(List<ui.Image?>? images) {
    if (images == null) return;
    for (final image in images) {
      image?.dispose();
    }
  }

  /// 把 [media] 的缩略图文件路径解码为 [ui.Image]；文件不存在或解码失败均跳过
  /// 并记录警告日志（时间线缩略图是辅助视觉，不应阻断审片台）。
  ///
  /// 用递增的 [_decodeRequestId] 作为"取消令牌"：解码是异步 IO，若 media 连续
  /// 变更两次，先发出的慢请求可能比后发出的快请求更晚完成；写回前比对请求号，
  /// 不是最新请求就丢弃解码结果（并 dispose），不覆盖新结果。
  /// 胶片条一格的解码高度：轨道高 52，按 2 倍屏留一档
  static const int _thumbDecodeHeight = 104;

  /// 解码结果**按下标对齐**：某一张缺失或解码失败时保留 null 占位，绝不
  /// 压缩列表——压缩会让剩余各张被按新长度重新等分铺开，整条胶片条与
  /// 时间轴错位（见 [TimelineMedia.thumbPaths] 的说明）。
  /// 底片单元解码好的图（单元 uid → 每一格）
  Map<String, List<ui.Image?>> _baseThumbImages = const {};

  /// 底片那几份自己的取消令牌。**不能和原片那份共用**：两个解码前后脚
  /// 启动时，后启动的会把先启动的结果判成过期丢掉
  int _baseDecodeRequestId = 0;

  /// 给每个底片单元解一份图。
  ///
  /// 和原片那份分开存：它们各按各的素材抽帧，格数和内容都不一样，
  /// 混在一起就是把别人的画面画到这一格上
  Future<void> _decodeBaseThumbs(Map<String, TimelineMedia> baseMedia) async {
    final requestId = ++_baseDecodeRequestId;
    final out = <String, List<ui.Image?>>{};
    for (final entry in baseMedia.entries) {
      final paths = entry.value.thumbPaths;
      final decoded = List<ui.Image?>.filled(paths.length, null);
      for (var i = 0; i < paths.length; i++) {
        final path = paths[i];
        if (path == null) continue;
        final file = File(path);
        if (!await file.exists()) continue;
        try {
          final codec = await ui.instantiateImageCodec(
              await file.readAsBytes(),
              targetHeight: _thumbDecodeHeight);
          decoded[i] = (await codec.getNextFrame()).image;
        } catch (e) {
          AppLog.warn('底片缩略图解码失败：$path，$e');
        }
      }
      out[entry.key] = decoded;
    }
    if (!mounted || requestId != _baseDecodeRequestId) {
      for (final imgs in out.values) {
        _disposeThumbImages(imgs);
      }
      return;
    }
    final previous = _baseThumbImages;
    setState(() => _baseThumbImages = out);
    for (final imgs in previous.values) {
      _disposeThumbImages(imgs);
    }
  }

  Future<void> _decodeThumbs(TimelineMedia? media) async {
    final requestId = ++_decodeRequestId;
    final paths = media?.thumbPaths ?? const <String?>[];
    final decoded = List<ui.Image?>.filled(paths.length, null);
    for (var i = 0; i < paths.length; i++) {
      final path = paths[i];
      if (path == null) continue;
      final file = File(path);
      if (!await file.exists()) continue;
      try {
        final bytes = await file.readAsBytes();
        // **按格子的高度解码，不要整张图**：抽帧图是 270×480，全尺寸解出来
        // 每张 518KB，而它们会一直握在手里直到离开页面——二十几张就是十几 MB
        // 白占着，画到屏幕上却只有 52 逻辑像素高（2026-09-09 性能走查）
        final codec = await ui.instantiateImageCodec(bytes,
            targetHeight: _thumbDecodeHeight);
        final frame = await codec.getNextFrame();
        decoded[i] = frame.image;
      } catch (e) {
        AppLog.warn('时间线缩略图解码失败：$path，$e');
      }
    }
    if (!mounted || requestId != _decodeRequestId) {
      _disposeThumbImages(decoded);
      return;
    }
    final previous = _thumbImages;
    setState(() => _thumbImages = decoded);
    _disposeThumbImages(previous);
  }

  void _handleTapUp(TapUpDetails details) {
    final position = details.localPosition;
    final isDoubleTap = _isDoubleTap(position);

    final units = widget.controller.units;
    // 替换数量徽标优先命中：它压在块体上，先判它才点得到
    if (_hitReplacementBadge(position)) return;
    if (_isOnBgmTrack(position)) {
      // 删除按钮优先：它压在块体上，先判它才点得到
      for (final span
          in bgmSpans(widget.bgm, widget.controller.units, widget.geometry.axis)) {
        if (!hitsBgmDelete(
            dx: position.dx,
            dy: position.dy,
            left: widget.geometry.composedMsToPx(span.startMs),
            right: widget.geometry.composedMsToPx(span.endMs),
            top: TimelineTracks.bgmTop,
            bottom: TimelineTracks.bgmBottom)) {
          continue;
        }
        if (!widget.readOnly) {
          widget.onBgmDelete?.call(span.segment.startUnit);
        }
        return;
      }
      final at = _unitIndexAtX(position.dx);
      final segment = at == null ? null : widget.bgm.segmentAt(at);
      if (segment != null) widget.onBgmSegmentTap?.call(segment);
      return;
    }

    // 字幕轨：点哪一段就选中那一镜，人直接去右边改。
    //
    // 那几段字是**按镜头坑位**画的，横向范围和视觉镜头轨上那一格完全一样，
    // 所以直接借镜头轨的命中判定——把 y 挪到镜头轨上再问一次，不另写一套
    // 几何（两套迟早对不上）。用户原话：「能不能直接选中字幕直接改啊？」
    if (TimelineTracks.isOnSubsTrack(position.dy)) {
      final onShots = Offset(position.dx,
          (TimelineTracks.shotsTop + TimelineTracks.shotsBottom) / 2);
      final shotHit = TimelineHitTester.hitTest(
          onShots, widget.controller.units, widget.geometry,
          locks: widget.controller.locks);
      if (shotHit case ShotBlockHit(:final unitIndex, :final shotIndex)) {
        // 单击照旧只是选中——双击才就地改，不打断已有习惯
        widget.controller.select(EditorSelection.shot(unitIndex, shotIndex));
        if (isDoubleTap) {
          _editSubtitleAt(unitIndex, shotIndex);
        }
      }
      return;
    }

    final hit = TimelineHitTester.hitTest(
        position, widget.controller.units, widget.geometry,
        locks: widget.controller.locks);
    switch (hit) {
      case RulerHit(:final ms):
        widget.onSeek(ms);
      case UnitBlockHit(:final unitIndex):
        // 单击点什么选什么，立即生效。原来单击镜头选的是「所在单元」，
        // 而且要等 300ms 双击窗口超时才生效——点下去没反应，用户只会以为
        // 没点上；想选单元点上面这一行就是了，那层粗粒度兜底是多余的。
        widget.controller.select(EditorSelection.unit(unitIndex));
        if (isDoubleTap && unitIndex < units.length) {
          widget.onPlaySegment?.call(unitIndex, null);
        }
      case ShotBlockHit(:final unitIndex, :final shotIndex):
        widget.controller.select(EditorSelection.shot(unitIndex, shotIndex));
        if (isDoubleTap &&
            unitIndex < units.length &&
            shotIndex < units[unitIndex].shots.length) {
          widget.onPlaySegment?.call(unitIndex, shotIndex);
        }
      case UnitBoundaryHit():
      case ShotBoundaryHit():
      case null:
        break;
    }
  }

  /// 光标落在字幕轨的哪一段上。没展开成多段（太窄）时一律返回 null——
  /// 那时轨上是整镜一块，只能双击进弹窗改
  ({
    int unitIndex,
    int shotIndex,
    int lineIndex,
    SubtitleGrab grab,
    double startDx,
    List<SubtitleLine> original,
    List<SubtitleLine> lines,
  })? _grabSubtitle(double dx) {
    final linesOf = widget.subtitleLinesOf;
    if (linesOf == null || widget.onSubtitleChanged == null) return null;
    final units = widget.controller.units;
    for (var u = 0; u < units.length; u++) {
      for (var i = 0; i < units[u].shots.length; i++) {
        final (left, right) = shotPx(u, i, units, widget.geometry);
        if (dx < left - subtitleEdgeHitPx || dx > right + subtitleEdgeHitPx) {
          continue;
        }
        final lines = linesOf(u, i);
        final boxes = subtitleSegmentBoxes(
          lines: lines,
          slotDurationMs: units[u].shots[i].durationMs,
          blockLeft: left + 1,
          blockRight: right - 1,
        );
        if (!subtitleSegmentsFit(boxes)) return null;
        final hit = subtitleGrabAt(dx: dx, boxes: boxes);
        if (hit == null) return null;
        return (
          unitIndex: u,
          shotIndex: i,
          lineIndex: hit.index,
          grab: hit.grab,
          startDx: dx,
          original: lines,
          lines: lines,
        );
      }
    }
    return null;
  }

  /// 拖动中：按位移算出新的一份行。**夹的规则走 core 那一套**——
  /// 属性卡里输数字和这里拖，能做到的事必须一样
  void _updateSubtitleDrag(
    ({
      int unitIndex,
      int shotIndex,
      int lineIndex,
      SubtitleGrab grab,
      double startDx,
      List<SubtitleLine> original,
      List<SubtitleLine> lines,
    }) drag,
    double dx,
  ) {
    final units = widget.controller.units;
    if (drag.unitIndex >= units.length) return;
    final shots = units[drag.unitIndex].shots;
    if (drag.shotIndex >= shots.length) return;
    final slotMs = shots[drag.shotIndex].durationMs;
    final (left, right) =
        shotPx(drag.unitIndex, drag.shotIndex, units, widget.geometry);
    // **吸到帧上**：属性卡里这两个数是按帧显示的（`00:17.10`），
    // 拖出来的值落在帧缝里的话，人看到的和实际存的对不上一帧
    final fps = widget.controller.fps;
    final rawDelta = subtitleDeltaMs(
      deltaPx: dx - drag.startDx,
      slotDurationMs: slotMs,
      blockLeft: left + 1,
      blockRight: right - 1,
    );
    final deltaMs = alignToFrame(rawDelta, fps);
    final source = drag.original;
    final line = source[drag.lineIndex];
    final next = switch (drag.grab) {
      SubtitleGrab.start => setSubtitleStart(
          source, drag.lineIndex, alignToFrame(line.startMs + deltaMs, fps),
          slotDurationMs: slotMs),
      SubtitleGrab.end => setSubtitleEnd(
          source, drag.lineIndex, alignToFrame(line.endMs + deltaMs, fps),
          slotDurationMs: slotMs),
      SubtitleGrab.move =>
        moveSubtitle(source, drag.lineIndex, deltaMs, slotDurationMs: slotMs),
    };
    if (const ListEquality<SubtitleLine>().equals(next, drag.lines)) return;
    setState(() => _subsDragging = (
          unitIndex: drag.unitIndex,
          shotIndex: drag.shotIndex,
          lineIndex: drag.lineIndex,
          grab: drag.grab,
          startDx: drag.startDx,
          original: drag.original,
          lines: next,
        ));
  }

  /// 画布要看到的那份行：正在拖的那一镜给临时的，别的镜头给真的
  List<SubtitleLine> _subtitleLinesForPaint(int unitIndex, int shotIndex) {
    if (_subsDragging case final drag?
        when drag.unitIndex == unitIndex && drag.shotIndex == shotIndex) {
      return drag.lines;
    }
    return widget.subtitleLinesOf?.call(unitIndex, shotIndex) ?? const [];
  }

  /// 把这一镜的字幕块换算成屏幕坐标，交给上层去贴浮层
  void _editSubtitleAt(int unitIndex, int shotIndex) {
    final onEdit = widget.onEditSubtitleBlock;
    if (onEdit == null) return;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final (left, right) =
        shotPx(unitIndex, shotIndex, widget.controller.units, widget.geometry);
    final topLeft = box.localToGlobal(Offset(left, TimelineTracks.subsTop));
    onEdit(
      unitIndex,
      shotIndex,
      Rect.fromLTWH(topLeft.dx, topLeft.dy, (right - left).abs(),
          TimelineTracks.subsBottom - TimelineTracks.subsTop),
    );
  }

  /// 与上一次单击的时间间隔在 [kDoubleTapTimeout] 内、位置偏移在
  /// [kDoubleTapSlop] 内即视为双击
  bool _isDoubleTap(Offset position) => _pendingDoubleTap;

  /// 按下那一刻就把「这算不算第二下」定下来——用事件自带的时间戳，
  /// 量的是人手上那两下的真实间隔，不受中间那些活影响（见 build 里的说明）。
  void _rememberDown(PointerDownEvent event) {
    final last = _lastDownTs;
    final lastPosition = _lastTapPosition;
    _pendingDoubleTap = last != null &&
        lastPosition != null &&
        event.timeStamp - last <= kDoubleTapTimeout &&
        (event.localPosition - lastPosition).distance <= kDoubleTapSlop;
    _lastDownTs = event.timeStamp;
    _lastTapPosition = event.localPosition;
  }

  /// 命中边界手柄时开启拖拽会话（多次 update 合并为一条撤销记录）；
  /// [DragStartBehavior.down]（见 [build]）确保这里拿到的是指针刚按下时的
  /// 原始坐标，落在边界手柄 ±6px 的判定窗口内。
  void _handleDragStart(DragStartDetails details) {
    // 拖播放头优先于一切：它只是定位、不改数据，因此只读回看下同样可用。
    // 判定放在边界命中之前——刻度尺本来就不承载任何边界手柄，不会打架。
    if (_isScrubStart(details.localPosition)) {
      _scrubbing = true;
      widget.onScrubStart?.call();
      _seekTo(details.localPosition.dx);
      return;
    }
    // 配乐轨上横向拖拽 = 框选一段连续镜头。判定放在边界命中之前：配乐轨
    // 上本来就没有边界手柄，不会打架。
    if (!widget.readOnly && _isOnBgmTrack(details.localPosition)) {
      // 先判「拖已有段落的边界」——那是改长度；判不中才是「框选一段新的」
      final grabbed = _grabBgmEdge(details.localPosition.dx);
      if (grabbed != null) {
        setState(() => _bgmResizing = grabbed);
        return;
      }
      final at = _unitIndexAtX(details.localPosition.dx);
      if (at != null) {
        setState(() => _bgmSelecting = (from: at, to: at));
        return;
      }
    }
    // 字幕轨：放大到每段都够宽时，一句一段各自能拖（左右边缘改起止、
    // 中间整段平移）。窄的时候不展开，那时这里抓不到任何东西，
    // 横向拖照旧当滚动
    if (!widget.readOnly && TimelineTracks.isOnSubsTrack(
        details.localPosition.dy)) {
      final grabbed = _grabSubtitle(details.localPosition.dx);
      if (grabbed != null) {
        setState(() => _subsDragging = grabbed);
        return;
      }
    }
    // 边界不能拖了（产品决定 2026-08-18）：切分边界来自分析管线 + 帧信号，
    // 人要做的是「切、合并、逐帧微调」，不是在轴上把两段拉来拉去——拖拽的
    // 自由度只带来误操作。此处不再识别边界手柄，横向拖一律当滚动
  }

  /// 播放头的抓取半径。比边界手柄（±6px）宽一些：红线是贯穿全高的醒目目标，
  /// 用户会直接往上按，抓不住比抓错更让人恼火。
  static const double _playheadGrabPx = 8;

  /// 两处可以起拖播放头：刻度尺整条（专业剪辑软件的通行做法），
  /// 以及红线本身左右各 [_playheadGrabPx]（用户看见什么就去拖什么）。
  bool _isScrubStart(Offset position) {
    if (position.dy >= TimelineTracks.rulerTop &&
        position.dy < TimelineTracks.rulerBottom) {
      return true;
    }
    // 播放头是**成片**位置（播放器直接给的），不走原片映射
    final playheadX = widget.geometry.composedMsToPx(widget.playhead.value);
    return (position.dx - playheadX).abs() <= _playheadGrabPx;
  }

  /// 像素 → **成片**毫秒。定位是给播放器的，而播放器跑在成片上；
  /// 已夹在 [0, durationMs]，拖出两端不会出现负数或超长
  void _seekTo(double dx) => widget.onSeek(widget.geometry.pxToComposedMs(dx));

  /// 点在某个替换数量徽标上了吗？是的话跳到右栏对应的那一段。
  bool _hitReplacementBadge(Offset position) {
    final onBadge = widget.onReplacementBadgeTap;
    if (onBadge == null) return false;

    final units = widget.controller.units;
    for (var u = 0; u < units.length; u++) {
      final unit = units[u];
      final (uLeft, uRight) = unitPx(u, units, widget.geometry);
      final rect = Rect.fromLTRB(
        uLeft,
        TimelineTracks.unitsTop,
        uRight,
        TimelineTracks.unitsBottom,
      );
      // 没挑素材的地方压根没画徽标，点下去不该误跳
      final hasWhole =
          ReplacementBadges.wholeCount(widget.replacements, unit.index) > 0;
      if (hasWhole &&
          (ReplacementBadges.unitBadgeRect(rect)?.contains(position) ?? false)) {
        onBadge(unit.index, null);
        return true;
      }
      for (var s = 0; s < unit.shots.length; s++) {
        final (sLeft, sRight) = shotPx(u, s, units, widget.geometry);
        final shotRect = Rect.fromLTRB(
          sLeft,
          TimelineTracks.shotsTop,
          sRight,
          TimelineTracks.shotsBottom,
        );
        final hasShot =
            ReplacementBadges.shotCount(widget.replacements, unit.index, s) > 0;
        if (hasShot &&
            (ReplacementBadges.shotBadgeRect(shotRect)?.contains(position) ??
                false)) {
          onBadge(unit.index, s);
          return true;
        }
      }
    }
    return false;
  }

  bool _isOnBgmTrack(Offset position) =>
      position.dy >= TimelineTracks.bgmTop &&
      position.dy < TimelineTracks.bgmBottom;

  /// 配乐轨按台词语义单元对齐——框选时吸附到单元边界，而不是 51 个镜头
  /// 一格一格对
  ///
  /// **按成片位置查**：老写法是「像素 → 成片 ms → 原片 ms → 拿原片时间去
  /// 列表里顺序扫」，那一步假设单元按原片时间升序排列。单元可以被拖乱顺序
  /// 之后这个假设就不成立了——点在 U1 上会选中别人。
  int? _unitIndexAtX(double dx) {
    final axis = widget.geometry.axis;
    if (axis == null) {
      return unitIndexAtMs(
          widget.controller.units, widget.geometry.pxToMs(dx));
    }
    return widget.controller.units.isEmpty
        ? null
        : axis.unitIndexAtComposedMs(widget.geometry.pxToComposedMs(dx));
  }

  /// 光标是不是抓在某一段的边界手柄上
  ({int startUnit, BgmEdge edge, int from, int to})? _grabBgmEdge(double dx) {
    for (final span in bgmSpans(widget.bgm, widget.controller.units)) {
      final left = widget.geometry.composedMsToPx(span.startMs);
      final right = widget.geometry.composedMsToPx(span.endMs);
      final edge = bgmEdgeAt(dx: dx, left: left, right: right);
      if (edge == null) continue;
      return (
        startUnit: span.segment.startUnit,
        edge: edge,
        from: span.segment.startUnit,
        to: span.segment.endUnit,
      );
    }
    return null;
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    if (_subsDragging case final drag?) {
      _updateSubtitleDrag(drag, details.localPosition.dx);
      return;
    }
    if (_bgmResizing case final rs?) {
      final at = _unitIndexAtX(details.localPosition.dx);
      if (at != null) {
        setState(() => _bgmResizing = rs.edge == BgmEdge.start
            ? (startUnit: rs.startUnit, edge: rs.edge, from: at, to: rs.to)
            : (startUnit: rs.startUnit, edge: rs.edge, from: rs.from, to: at));
      }
      return;
    }
    if (_bgmSelecting case final sel?) {
      final at = _unitIndexAtX(details.localPosition.dx);
      if (at != null && at != sel.to) {
        setState(() => _bgmSelecting = (from: sel.from, to: at));
      }
      return;
    }
    if (_scrubbing) {
      // 每次 update 都定位：只在松手时跳一次，等于让用户闭着眼睛拖
      _seekTo(details.localPosition.dx);
      return;
    }
    // 整段水平拖拽视为滚动（边界拖拽已移除——边界只能在属性面板逐帧调）
    final scrolled = widget.geometry
        .scrolledBy(-details.delta.dx, viewportWidthPx: _viewportWidth);
    widget.onGeometryChanged(scrolled);
  }

  void _endDrag() {
    if (_subsDragging case final drag?) {
      setState(() => _subsDragging = null);
      // 没动就不提交——白提交一次等于白烧一次字幕
      if (!const ListEquality<SubtitleLine>()
          .equals(drag.lines, drag.original)) {
        widget.onSubtitleChanged
            ?.call(drag.unitIndex, drag.shotIndex, drag.lines);
      }
      return;
    }
    if (_bgmResizing case final rs?) {
      setState(() => _bgmResizing = null);
      widget.onBgmResize?.call(rs.startUnit, rs.from, rs.to);
      return;
    }
    if (_bgmSelecting case final sel?) {
      setState(() => _bgmSelecting = null);
      widget.onBgmRangeSelected?.call(
          sel.from < sel.to ? sel.from : sel.to,
          sel.from < sel.to ? sel.to : sel.from);
      return;
    }
    if (_scrubbing) {
      _scrubbing = false;
      // 少发一次 end，调用方那边的播放就永远恢复不回来
      widget.onScrubEnd?.call();
    }
    // 不在会话中时调用无副作用（历史上边界拖拽会开会话，现已移除）
    widget.controller.endDragSession();
  }

  void _handleDragEnd(DragEndDetails details) => _endDrag();

  void _handleDragCancel() => _endDrag();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewportWidth = constraints.maxWidth;
        return Listener(
          // **双击判定用事件自带的时间戳，不用墙钟。**
          //
          // 墙钟量的是「我处理到这两下之间隔了多久」，中间夹着选中、重建这些
          // 活；`PointerEvent.timeStamp` 是引擎在事件产生时打的，量的才是人
          // 手上那两下的真实间隔。两者平时接近，UI 忙的时候前者会偏大——
          // 偏大就意味着人明明双击了却被判成两次单击。用后者不花任何代价。
          //
          // （2026-09-08 自测时我一度以为双击失灵是这个原因，后来用时间戳量
          // 出来是自动化工具两次点击本身就隔了 381ms——**功能一直是好的**。
          // 这个改动留着，因为它本来就是更该用的那个来源。）
          onPointerDown: _rememberDown,
          onPointerSignal: _handlePointerSignal,
          onPointerPanZoomStart: (_) {
            _panZoomScale = 1.0;
            _panZoomPan = Offset.zero;
          },
          onPointerPanZoomUpdate: _handlePanZoomUpdate,
          child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // 触控板的双指手势交给 Listener 的 PanZoom 回调统一处理。
          // 若同时让手势识别器把它当成拖拽，两条路径会各自基于**同一份未更新
          // 的 geometry** 调用 onGeometryChanged，后到的那次把先到的结果整个
          // 覆盖掉——表现为捏合缩放看起来完全没生效。
          // 注意：在触控板上按下拖动产生的是 mouse 类指针，不受这里影响。
          supportedDevices: const {
            PointerDeviceKind.mouse,
            PointerDeviceKind.touch,
            PointerDeviceKind.stylus,
            PointerDeviceKind.invertedStylus,
            PointerDeviceKind.unknown,
          },
          // 让 onHorizontalDragStart 报告指针刚按下时的原始坐标（而非默认的
          // "越过触摸容差后手势识别器胜出时"的坐标），边界手柄 ±6px 的命中
          // 判定才不会被拖拽启动阈值带偏
          dragStartBehavior: DragStartBehavior.down,
          onTapUp: _handleTapUp,
          onHorizontalDragStart: _handleDragStart,
          onHorizontalDragUpdate: _handleDragUpdate,
          onHorizontalDragEnd: _handleDragEnd,
          onHorizontalDragCancel: _handleDragCancel,
          // RepaintBoundary 是必需的：没有它时 RenderCustomPaint.markNeedsPaint
          // 会一路上溯到 RenderView，播放头每次移动都要把整页的绘制指令重录一遍。
          // 轨道总高固定（六条轨 + 各自标题条，见 TimelineTracks.totalHeight）。
          // 窗口太矮时纵向滚动兜底，而不是让最后一条轨（音频波形）整条落在
          // 可视区外——用户既看不到波形，也看不到为它准备的「生成中/生成
          // 失败」占位。**兜底成立的前提是画布高确实取到了总高**：总高比
          // 视口还矮的话子高度就等于视口高度，滚都滚不动（2026-09-08）。
          // 手势坐标取自 CustomPaint 内部，滚动不影响命中判定的 y 基准。
          child: SingleChildScrollView(
            // 停在哪条轨上，就只亮那条轨的标题、只露那条轨的说明。
            // **只在跨轨时才 setState**：同一条轨里移动不重建，
            // 否则鼠标一动就是一次全时间线重绘。
            //
            // 摆在 RepaintBoundary **外面**：套在里面的话
            // RenderCustomPaint 的直接父节点就成了 RenderMouseRegion，
            // 播放头每次移动的 markNeedsPaint 又会一路上溯到 RenderView
            child: MouseRegion(
            // 光标要说得出「这儿能干什么」：压在边界手柄上是双向箭头
            // （可以拖着改切分），压在刻度尺上是「可以拖播放头」，
            // 别的地方保持普通箭头。少了这一层，人得靠试才知道哪儿能拖
            // （2026-09-09 设计走查）
            cursor: _cursor,
            onHover: (e) {
              _setHoverTrack(
                  TimelineTracks.trackLabelTopAt(e.localPosition.dy));
              _setCursorFor(e.localPosition);
            },
            onExit: (_) {
              _setHoverTrack(null);
              _setCursor(MouseCursor.defer);
            },
            child: RepaintBoundary(
            child: AnimatedBuilder(
              animation: widget.controller,
              builder: (context, _) => ValueListenableBuilder<int>(
                valueListenable: widget.playhead,
                builder: (context, playheadMs, _) => CustomPaint(
                  size: Size(
                    constraints.maxWidth,
                    math.max(constraints.maxHeight, TimelineTracks.totalHeight),
                  ),
                  painter: TimelinePainter(
                    units: widget.controller.units,
                    selection: widget.controller.selection,
                    geometry: widget.geometry,
                    thumbImages: _thumbImages,
                    waveEnvelope: widget.media?.waveEnvelope,
                    baseThumbImages: _baseThumbImages,
                    baseWaveEnvelopes: {
                      for (final e in widget.baseMedia.entries)
                        e.key: e.value.waveEnvelope,
                    },
                    playheadMs: playheadMs,
                    mediaStatus: widget.mediaStatus,
                    thumbStatus: widget.thumbStatus,
                    waveStatus: widget.waveStatus,
                    bgm: widget.bgm,
                    bgmSelecting: _bgmSelecting,
                    voices: widget.voices,
                    replacements: widget.replacements,
                    composedDurations: widget.composedDurations,
                    subtitleEdited: widget.subtitleEdited,
                    subtitleTextOf: widget.subtitleTextOf,
                    subtitleLineCount: widget.subtitleLineCount,
                    // 正在拖的那一镜给临时的那份，别的镜头给真的
                    subtitleLinesOf: _subtitleLinesForPaint,
                    subtitleDragging: _subsDragging == null
                        ? null
                        : (
                            unitIndex: _subsDragging!.unitIndex,
                            shotIndex: _subsDragging!.shotIndex,
                            lineIndex: _subsDragging!.lineIndex,
                            // 拖到哪儿了也要交给画布：不然 shouldRepaint
                            // 看不出变化，整个拖动一帧都不重画
                            lines: _subsDragging!.lines,
                          ),
                    subtitleTrack: widget.subtitleTrack,
                    hoveredLabelTop: _hoverLabelTop,
                    textCache: _textCache,
                  ),
                ),
              ),
            ),
            ),
          ),
          ),
        ),
        );
      },
    );
  }

  /// 鼠标停着的那条轨（它标题条的 top）
  double? _hoverLabelTop;

  void _setHoverTrack(double? top) {
    if (_hoverLabelTop == top) return;
    setState(() => _hoverLabelTop = top);
  }

  /// 当前该用什么光标
  MouseCursor _cursor = MouseCursor.defer;

  void _setCursor(MouseCursor next) {
    if (_cursor == next) return;
    setState(() => _cursor = next);
  }

  /// **只在光标真的该换时才 setState**：鼠标在同一块区域里移动不重建，
  /// 否则一动就是一次全时间线重绘
  void _setCursorFor(Offset local) {
    // 字幕轨上先问「这儿能不能抓」：抓边缘是双向箭头、抓中间是手型。
    // 少了这一层，人得靠试才知道哪儿能拖（和边界手柄同一条理由）
    if (!widget.readOnly && TimelineTracks.isOnSubsTrack(local.dy)) {
      final grab = _grabSubtitle(local.dx);
      if (grab != null) {
        _setCursor(grab.grab == SubtitleGrab.move
            ? SystemMouseCursors.grab
            : SystemMouseCursors.resizeLeftRight);
        return;
      }
    }
    final hit = TimelineHitTester.hitTest(
      local,
      widget.controller.units,
      widget.geometry,
      locks: widget.controller.locks,
    );
    _setCursor(switch (hit) {
      UnitBoundaryHit() || ShotBoundaryHit() =>
        SystemMouseCursors.resizeLeftRight,
      RulerHit() => SystemMouseCursors.resizeColumn,
      _ => MouseCursor.defer,
    });
  }

  /// 滚轮 / 触控板双指手势：
  /// - ⌘ + 滚动 → 以指针位置为锚点缩放（macOS 上缩放的通行手势）
  /// - 其余滚动（含纵向）→ 平移时间线
  ///
  /// 纵向滚动也映射为平移：时间线本身没有纵向可滚内容，不映射就是一个
  /// 落空的手势；而触控板上纯粹的水平滑动很难做到，用户实际会带纵向分量。
  /// 用户手动平移/缩放后临时停止跟随播放头；播放头重新进入视野时解除
  bool _followSuspended = false;

  /// 触控板双指手势上一次的累计缩放比例与累计平移（事件给的是自手势开始
  /// 以来的累计值，需要自己算增量）
  double _panZoomScale = 1.0;
  Offset _panZoomPan = Offset.zero;

  /// 触控板双指手势：平移 + 捏合缩放，一处统一处理。
  ///
  /// 两件事必须在同一处做：它们来自同一个事件流，若分散在两条路径里，各自
  /// 基于同一份未更新的 geometry 计算并回调，后者会把前者的结果覆盖掉。
  void _handlePanZoomUpdate(PointerPanZoomUpdateEvent event) {
    if (_viewportWidth <= 0) return;

    final scale = event.scale <= 0 ? _panZoomScale : event.scale;
    final factor = scale / _panZoomScale;
    final panDelta = event.pan - _panZoomPan;
    _panZoomScale = scale;
    _panZoomPan = event.pan;

    var next = widget.geometry;
    // 极小的抖动不触发重算，避免手指静止时的噪声让画面持续微动
    if ((factor - 1).abs() >= 0.005) {
      next = next.zoomAt(event.localPosition.dx, factor,
          viewportWidthPx: _viewportWidth);
    }
    if (panDelta.dx.abs() >= 0.5) {
      // 内容跟着手指走：手指左滑（dx 为负）时时间线向右滚
      next = next.scrolledBy(-panDelta.dx, viewportWidthPx: _viewportWidth);
    }
    if (identical(next, widget.geometry)) return;
    _followSuspended = true;
    widget.onGeometryChanged(next);
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (_viewportWidth <= 0) return;

    final zooming = HardwareKeyboard.instance.isMetaPressed ||
        HardwareKeyboard.instance.isControlPressed;
    if (zooming) {
      // 向上滚（dy<0）放大。每 100 单位对应 1.2 倍，手感与系统一致
      final steps = -event.scrollDelta.dy / 100;
      if (steps == 0) return;
      final factor = math.pow(1.2, steps).toDouble();
      _followSuspended = true;
      widget.onGeometryChanged(widget.geometry.zoomAt(
          event.localPosition.dx, factor,
          viewportWidthPx: _viewportWidth));
      return;
    }

    final delta = event.scrollDelta.dx.abs() >= event.scrollDelta.dy.abs()
        ? event.scrollDelta.dx
        : event.scrollDelta.dy;
    if (delta == 0) return;
    _followSuspended = true;
    widget.onGeometryChanged(widget.geometry
        .scrolledBy(delta, viewportWidthPx: _viewportWidth));
  }
}
