import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show HardwareKeyboard, LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/ai/tag_dimension.dart';
import '../../core/analysis/scene_detector.dart';
import '../../core/audio/audio_preview.dart';
import '../../core/audio/bgm_plan.dart';
import '../../core/export/export_spec.dart';
import '../../core/audio/voice_catalog.dart';
import '../../core/script/shot_frame_check.dart';
import '../../core/log/app_log.dart';
import '../../core/models/renew_task.dart';
import '../../core/script/bgm_rail.dart';
import '../../core/script/line_delivery_service.dart';
import '../../core/script/preview_voice_normalizer.dart';
import '../../core/script/script_cover.dart';
import '../../core/script/playhead.dart';
import '../../core/script/script_doc.dart';
import '../../core/script/uploaded_voice.dart';
import '../../core/script/script_service_wiring.dart';
import '../../core/script/voice_sweep.dart';
import '../../core/script/sound_mix.dart';
import '../../core/script/script_transcriber.dart';
import '../../core/storage/agent_presence.dart';
import '../../core/storage/doc_watch.dart';
import '../../core/ui/text_editing_keys.dart';
import 'scroll_into_view.dart';
import '../../core/storage/task_media.dart';
import '../../core/storage/task_lock.dart';
import '../../core/storage/agent_request.dart';
import '../../core/storage/ui_action.dart';
import '../../core/storage/task_repository.dart';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/ffmpeg/ffprobe_service.dart';
import '../../core/ffmpeg/process_runner.dart';
import '../../core/ffmpeg/rendered_cache.dart';
import '../../core/playback/media_kit_follower.dart';
import '../../core/playback/media_kit_playback.dart';
import '../../core/playback/multitrack_playback.dart';
import '../../core/playback/playback_controller.dart';
import '../../core/playback/track_plan.dart';
import '../../core/script/script_export.dart';
import '../../core/script/script_track_plan.dart';
import '../../core/script/shot_allocation.dart';
import '../../core/script/word_shot_insert.dart';
import '../../core/script/speed_clip_renderer.dart';
import '../picking/picked_media_cache.dart';
import '../picking/picking_providers.dart';
import '../settings/settings_providers.dart';
import '../tasks/new_task_wizard/wizard_providers.dart';
import '../tasks/task_id_badge.dart';
import '../tasks/task_list_controller.dart';
import '../agent/visual_pace.dart';
import '../shared/long_task_dialog.dart';
import '../workbench/bgm_picker_sheet.dart';
import 'director_providers.dart';
import 'find_shots_sheet.dart';
import '../../core/script/skipped_lines_summary.dart';
import '../shared/preview_subtitle.dart';
import 'tag_picker.dart';
import 'line_board.dart';
import 'script_panel.dart';
import 'start_guide.dart';
import '../../core/subtitle/subtitle_style.dart';
import 'export_readiness.dart';
import '../../core/jianying/jianying_plan.dart';
import '../../core/jianying/jianying_writer.dart';
import '../../core/platform/platform_shell.dart';
import '../../core/platform/platform_paths.dart';
import 'script_export_dialog.dart';
import '../shared/subtitle_style_sheet.dart';
import 'voice_select_dialog.dart';

/// 编导台——「脚本成片」的工作页（对仗审片台）。
///
/// 三栏：左 = 脚本（唯一的真相 + 总览导航）；中 = 预览（成片的影子）；
/// 右 = 当前行的工作台（聚焦深工）。见 docs/2026-08-19 设计稿。
class DirectorPage extends ConsumerStatefulWidget {
  final RenewTask task;

  /// 预览播放后端。缺省三轨真实播放器（画面主时钟 + 配音跟随）；
  /// 测试注入假实现或 null 工厂，不碰 libmpv
  final PlaybackController? Function()? playbackFactory;

  const DirectorPage({super.key, required this.task, this.playbackFactory});

  @override
  ConsumerState<DirectorPage> createState() => _DirectorPageState();
}

/// 「从视频提取脚本」此刻的状态：没在跑 / 跑到哪一步 / 挂在哪
sealed class _ExtractState {
  const _ExtractState();
}

class _ExtractRunning extends _ExtractState {
  final ScriptTranscribeStage stage;
  const _ExtractRunning(this.stage);
}

class _ExtractFailed extends _ExtractState {
  final String message;
  const _ExtractFailed(this.message);
}

class _DirectorPageState extends ConsumerState<DirectorPage> {
  late RenewTask _task = widget.task;
  late ScriptDoc _doc = widget.task.script ?? ScriptDoc.empty();
  int _selected = 0;

  /// 刚插入的行：让它的输入框自动聚焦（回车后手不离键盘）
  String? _autofocusLineId;

  Timer? _autosave;
  bool _saving = false;
  TaskLockFile? _lock;
  Timer? _lockHeartbeat;
  String? _blockedBy;

  _ExtractState? _extract;

  /// 用户在空脚本上点了「直接开始写」：起步引导让位给预览
  bool _guideDismissed = false;

  /// 正在生成配音的行 id（生成是异步的，期间行可能被移动，下标不可靠）
  final Set<String> _generatingLineIds = {};

  /// 正在试听配音的行 id；试听播放器整页共用一个
  String? _playingLineId;

  /// 预览播放位置当前落在的行（右栏跟随高亮）；null = 位置不在任何行里
  int? _previewLineIndex;

  /// 传输条拖动中的位置（ms）；null = 没在拖。拖动中进度以它为准，
  /// 松手才 seek——不然位置流每帧把滑块拽回去
  int? _dragMs;
  final AudioPreview _voicePreview = AudioPreview();

  /// initState 里取好：dispose 阶段还要落一次盘，那时不能再碰 ref
  late final TaskRepository _repo;

  /// 展开详情的镜头：(行下标, 镜头下标)。展开发生在块内，一次一个
  (int, int)? _expandedShot;

  /// Agent 此刻在不在、在干什么。非空 = 界面跟着它的焦点走，且人改不动
  AgentPresence? _agent;
  Timer? _agentPoll;

  /// 参考段缩略图：行 id → 本地 jpg（抽一帧缓存一帧）
  final Map<String, String> _refThumbs = {};
  final Set<String> _refThumbsRendering = {};

  /// 抽帧失败过的 key：记账后不再重试。没有这本账，build 每帧都会
  /// 重新起一个 ffmpeg（真实发生过：源文件不在时无限重试，测试挂死）
  final Set<String> _refThumbFailed = {};

  /// 取段胶片条的素材帧（materialId → 8 帧路径）。拖窗口时看得见
  /// 取的是哪段画面——纯色条只能靠猜。按素材缓存，算过一次不再抽
  final Map<int, List<String>> _shotFrames = {};
  final Set<int> _shotFramesBusy = {};
  final Set<int> _shotFramesFailed = {};

  /// 抽 24 帧、160px 高：显示端按条宽自适应取 N 帧（格子比例锁素材
  /// 原比例、永不拉伸），24 帧足够覆盖全屏宽度。一条 ffmpeg 命令抽完，
  /// 比逐帧 seek 快数倍
  static const _filmstripFrameCount = 24;

  /// 素材帧的宽高比（宽/高），随帧缓存落盘（meta.txt）；
  /// 取段条按它定格宽，竖屏素材就是竖格
  final Map<int, double> _shotFrameAspect = {};

  /// 确保素材的胶片帧就绪（本地文件在才抽；异步落盘后刷新）
  void _ensureShotFrames(LineShot shot) {
    final id = shot.materialId;
    if (_shotFrames.containsKey(id) ||
        _shotFramesBusy.contains(id) ||
        _shotFramesFailed.contains(id)) {
      return;
    }
    final src = shot.localSource ?? _mediaCache?.localPathOf(id);
    final dataDir = ref.read(dataDirProvider);
    final durMs = shot.durationMs;
    if (src == null || dataDir == null || durMs == null || durMs <= 0) return;
    // v3：24 帧一条命令抽完 + meta 记素材宽高比——目录带版本号，
    // 旧版帧整目录作废（TaskArtifacts 收编按任务清理）
    final dir = Directory(
        p.join(dataDir.path, 'shot_frames', _task.id, '${id}_${durMs}_v3'));
    final expect = [
      for (var i = 1; i <= _filmstripFrameCount; i++)
        p.join(dir.path, 'f${i.toString().padLeft(2, '0')}.jpg'),
    ];
    final metaFile = File(p.join(dir.path, 'meta.txt'));
    if (expect.every((f) => File(f).existsSync()) && metaFile.existsSync()) {
      final aspect = double.tryParse(metaFile.readAsStringSync().trim());
      if (aspect != null && aspect > 0) _shotFrameAspect[id] = aspect;
      _shotFrames[id] = expect;
      return;
    }
    _shotFramesBusy.add(id);
    unawaited(() async {
      try {
        await dir.create(recursive: true);
        // 一条命令均匀抽 N 帧（fps 滤镜），比逐帧 seek 快数倍；
        // 本地源（参考段）先 -ss 切到区间
        final baseMs = shot.localSource != null ? shot.trimStartMs : 0;
        final r = await const ResolvingProcessRunner().call('ffmpeg', [
          '-y', '-v', 'error',
          if (baseMs > 0) ...['-ss', (baseMs / 1000).toStringAsFixed(3)],
          '-t', (durMs / 1000).toStringAsFixed(3),
          '-i', src,
          '-vf',
          'fps=$_filmstripFrameCount/${(durMs / 1000).toStringAsFixed(3)},'
              'scale=-2:160',
          '-frames:v', '$_filmstripFrameCount',
          p.join(dir.path, 'f%02d.jpg'),
        ]);
        if (r.exitCode != 0) throw StateError('ffmpeg exit=${r.exitCode}');
        // fps 滤镜可能少产最后一两帧：缺的用最后一帧补位，别让格子开天窗
        String? last;
        for (final fpath in expect) {
          if (File(fpath).existsSync()) {
            last = fpath;
          } else if (last != null) {
            File(fpath).writeAsBytesSync(File(last).readAsBytesSync());
          }
        }
        if (last == null) throw StateError('一帧都没抽出来');
        // 素材宽高比从 ffprobe 拿，随缓存落盘
        final probe = await const ResolvingProcessRunner().call('ffprobe', [
          '-v', 'error', '-select_streams', 'v:0',
          '-show_entries', 'stream=width,height', '-of', 'csv=p=0:s=x',
          src,
        ]);
        final parts = '${probe.stdout}'.trim().split('x');
        final aspect = parts.length == 2
            ? (double.tryParse(parts[0]) ?? 9) /
                ((double.tryParse(parts[1]) ?? 16) == 0
                    ? 16
                    : double.tryParse(parts[1])!)
            : 9 / 16;
        metaFile.writeAsStringSync(aspect.toStringAsFixed(4));
        if (mounted) {
          setState(() {
            _shotFrameAspect[id] = aspect;
            _shotFrames[id] = expect;
          });
        }
      } catch (e) {
        _shotFramesFailed.add(id);
        AppLog.warn('取段胶片帧抽取失败（素材 $id）：$e');
      } finally {
        _shotFramesBusy.remove(id);
      }
    }());
  }

  /// 右板滚动控制（左栏点行 → 滚到对应块）
  final ScrollController _boardScroll = ScrollController();

  /// 素材固定：挑中的镜头视频下到本地（与工作台/导出同一份缓存目录）。
  /// 下载器未接（测试环境/凭据不全）时为 null，卡片不显示下载状态
  PickedMediaCache? _mediaCache;

  // ---- 整片预览 ----

  PlaybackController? _playback;
  Widget? _videoWidget;
  ScriptPlanResult _planResult =
      const ScriptPlanResult(plan: TrackPlan.empty, skippedLines: {});
  final ValueNotifier<int> _positionMs = ValueNotifier(0);
  bool _previewPlaying = false;
  StreamSubscription<int>? _positionSub;
  StreamSubscription<bool>? _playingSub;
  Timer? _previewRebuild;

  /// 变速切片：渲染好的路径按指纹存着；正在渲的记 key 防重复
  SpeedClipRenderer? _clipRenderer;

  /// 口播轨的段规范化器：进这条轨的每一段都要转成同规格（见
  /// PreviewVoiceNormalizer）。渲好的路径按内容指纹记在这里
  PreviewVoiceNormalizer? _voiceNormalizer;
  final Map<String, String> _voiceSegs = {};
  final Set<String> _renderingVoiceSegs = {};
  final Map<String, String> _speedClips = {};
  final Set<String> _renderingClips = {};

  /// 配乐固定：选中即下到本地（与工作台同一份 bgm_cache）
  PickedMediaCache? _bgmCache;

  /// 草片刚做完的庆祝一拍（对勾动效那 1.1 秒），结束即开播
  bool _draftCelebrating = false;

  /// 字幕拖动中的临时位置（bottomRatio）；null = 没在拖。
  /// 拖动实时预览、松手才落盘
  double? _subtitleDragRatio;

  /// 字幕工具条的草稿样式：拖滑杆时实时预览用，松手才 _mutate 落盘
  /// （否则每帧一次撤销记录，⌘Z 要按上百次）
  SubtitleStyle? _styleDraft;
  String? _styleDraftLineId;

  /// 这一行当下生效的字幕样式：草稿 > 行级覆盖 > 全局
  SubtitleStyle _styleOf(ScriptLine line) {
    if (_styleDraftLineId == line.id && _styleDraft != null) {
      return _styleDraft!;
    }
    return line.subtitleOverride ?? _doc.subtitle;
  }

  /// 工具条针对的那一句：正在播的那句优先，否则是选中的那句
  int get _subtitleTargetIndex {
    final i = _previewLineIndex ?? _selected;
    return (i >= 0 && i < _doc.lines.length) ? i : 0;
  }

  /// 草片流水线进度：(阶段名, 当前句摘要, 已完成, 总数)；null = 没在跑。
  /// 这是产品的魔法时刻——提取完一条参考片，几分钟后中央屏幕自动
  /// 播出一版会说话的草片，人从此只做否决和替换
  (String, String, int, int)? _draftProgress;

  @override
  void initState() {
    super.initState();
    _repo = ref.read(taskRepositoryProvider);
    _acquireLock();
    _mediaCache = _buildMediaCache();
    _mediaCache?.addListener(_onMediaCache);
    _bgmCache = _buildBgmCache();
    _bgmCache?.addListener(_onMediaCache);
    _pinBgm();
    _pinAllShots();
    _watchAgent();
    // **等第一帧画完再建播放器**，不要在 initState 里同步建。
    //
    // 真机崩了四次，栈一字不差：mpv_render_context_create 里的断言失败、
    // 整个 app abort。规律是验收 Agent 用四轮数据定死的：
    //
    // | 场景 | 结果 |
    // |---|---|
    // | `ui new-task` 建本进程**首个**编导台 | 崩 |
    // | `ui new-task` 时已经开过编导台 | 不崩 |
    // | `open` 建本进程首个编导台（含冷启动） | 不崩 |
    //
    // 差别在路径本身：`ui new-task` 中间隔着一个**模态对话框**，它关闭
    // 时界面正在重建，这一刻去建 mpv 的 GL 纹理就撞上了；`open` 那条
    // 直接 push，界面是稳的。之前两次都猜错了方向（先猜冷启动竞态、
    // 再猜两个上下文并存），都被数据反证。
    //
    // 挪到 postFrame 之后，两条路进来时界面都已经画完一帧、稳定了
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _setupPreview();
    });
  }

  PickedMediaCache? _buildBgmCache() {
    final fetch = ref.read(bgmFetcherProvider);
    final dataDir = ref.read(dataDirProvider);
    if (fetch == null || dataDir == null) return null;
    return PickedMediaCache(
      extension: 'mp3',
      fetch: (id) {
        for (final seg in _doc.bgmSegments) {
          if (seg.material.id == id) return fetch(_task.id, seg.material);
        }
        throw StateError('这首配乐已经不在方案里了');
      },
      cacheDir: TaskMedia(dataDir: dataDir, taskId: _task.id).bgmDir,
    );
  }

  void _pinBgm() {
    final ids = {for (final seg in _doc.bgmSegments) seg.material.id};
    if (ids.isNotEmpty) _bgmCache?.pinAll(ids);
  }

  // ---- 配乐（分段在右栏色带上切；这里只有换曲/音量的动作）----

  void _setupPreview() {
    final playback = widget.playbackFactory != null
        ? widget.playbackFactory!()
        : MultitrackPlayback(
            video: MediaKitPlaybackController(),
            voice: MediaKitFollower(),
            bgm: MediaKitFollower(loop: true),
            // 素材原声独立成轨：挂在画面轨上会让主时钟在
            // 「无音轨→有音轨」的接缝处卡死（真机踩过）
            source: MediaKitFollower(),
          );
    if (playback == null) return;
    _playback = playback;
    _videoWidget = switch (playback) {
      MultitrackPlayback() => playback.buildVideoWidget(),
      MediaKitPlaybackController() => playback.buildVideoWidget(),
      _ => null,
    };
    _positionSub = playback.positionMsStream.listen((ms) {
      if (!mounted) return;
      _positionMs.value = ms;
      _syncPreviewLine(ms);
    });
    _playingSub = playback.playingStream.listen((playing) {
      if (mounted && _previewPlaying != playing) {
        // 一按暂停就把「人动过手」的标记清掉：他停下来多半就是要改东西，
        // 改完再播，自动展开该重新跟上
        setState(() {
          _previewPlaying = playing;
          if (!playing) _autoExpandPaused = false;
        });
      }
    });
    final dataDir = ref.read(dataDirProvider);
    if (dataDir != null) {
      _voiceNormalizer = PreviewVoiceNormalizer(
          cache: RenderedCache(
              dir: Directory(
                  p.join(dataDir.path, 'preview_voice', _task.id)),
              run: const ResolvingProcessRunner().call));
      _clipRenderer = SpeedClipRenderer(
        cache: RenderedCache(
          dir: Directory(
              p.join(dataDir.path, 'speed_fit_script', _task.id)),
          run: const ResolvingProcessRunner().call,
        ),
      );
    }
    _dataDir = dataDir;
    _docPrint = dataDir == null ? null : taskFingerprint(dataDir, _task.id);
    _schedulePreviewRebuild();
    // 进门顺手收一次无主配音：换过音色的旧 mp3 没人引用了，但任务还活着，
    // 孤儿清扫碰不到它们。**只能在这一刻收**——撤销栈这时必然是空的，
    // 编辑当中删会让 ⌘Z 撤成死链（真机上出现过整行无声）
    if (dataDir != null) {
      final removed =
          sweepUnusedVoices(dataDir: dataDir, taskId: _task.id, doc: _doc);
      if (removed > 0) AppLog.info('回收无主配音 $removed 个（${_task.id}）');
    }
  }

  /// 内容一变就排一次轨道重建（600ms 防抖）。画面轨没变时
  /// MultitrackPlayback 自己会挡住重复 open，不闪黑
  /// 预览正在重建（换素材、改时长之后要重铺轨道）。
  /// **超过一两秒的等待都要有交代**——没有它，人只会以为自己没点中，
  /// 于是反复点（真机反馈：「点了以后没反应，要点很多下」）
  bool _previewBusy = false;

  void _schedulePreviewRebuild() {
    if (_playback == null) return;
    _previewRebuild?.cancel();
    if (!_previewBusy && mounted) setState(() => _previewBusy = true);
    _previewRebuild =
        Timer(const Duration(milliseconds: 600), _rebuildPreview);
  }

  String _clipKey(LineShot s) =>
      '${s.materialId}|${s.trimStartMs}|${s.allocMs}|${s.speed}';

  /// 切片够不够长。短了只记日志不拦——拦下来这一行就没画面了，
  /// 而短几十毫秒的片子仍然能看；但必须让它在日志里留下名字
  Future<void> _warnIfClipTooShort(String path, int allocMs) async {
    try {
      final info = await FfprobeService().probe(path);
      final realMs = info.duration.inMilliseconds;
      if (realMs + 2 < allocMs) {
        AppLog.warn('变速切片比坑位短：$path 实际 ${realMs}ms、'
            '轨上要 ${allocMs}ms（差 ${allocMs - realMs}ms）——'
            '画面轨会提前收，口播会被往前拽');
      }
    } catch (e) {
      AppLog.warn('变速切片时长自检失败（$path）：$e');
    }
  }

  /// 原声音量改了就**立刻**让正在播的预览跟着变。
  ///
  /// 走 `_mutate` 的话要等 600ms 防抖再重铺整条轨，人拖着滑杆听不到反馈，
  /// 只会以为没生效（真机反馈）。音量不改变任何编排，直接把新音量推给
  /// 播放器即可
  /// 拖动过程中的临时音量：不落盘，只让正在播的预览跟着变
  /// 拖动混音台时**当场**让正在播的预览跟着变（松手才落盘）。
  /// 不这样的话，人拖着滑杆听不到任何变化，只会以为没生效
  void _mixPreview(SoundMix next) {
    final playback = _playback;
    if (playback is! MultitrackPlayback) return;
    final preview = _doc.withMix(next);
    final result = buildScriptTrackPlan(preview, sourceOf: (shot) {
      if (shot.speed != 1.0) {
        final clip = _speedClips[_clipKey(shot)];
        return clip == null ? null : ShotSource(clip);
      }
      final local =
          shot.localSource ?? _mediaCache?.localPathOf(shot.materialId);
      return local == null ? null : ShotSource(local, inMs: shot.trimStartMs);
    },
        bgmPathOf: (id) => _bgmCache?.localPathOf(id),
        voiceSegmentOf: _voiceSegmentOf,
        voiceOk: (path) => File(path).existsSync());
    unawaited(playback.setPlan(result.plan));
  }

  void _applySourceVolumeNow() {
    final playback = _playback;
    if (playback is! MultitrackPlayback) return;
    final result = buildScriptTrackPlan(_doc, sourceOf: (shot) {
      if (shot.speed != 1.0) {
        final clip = _speedClips[_clipKey(shot)];
        return clip == null ? null : ShotSource(clip);
      }
      final local =
          shot.localSource ?? _mediaCache?.localPathOf(shot.materialId);
      return local == null ? null : ShotSource(local, inMs: shot.trimStartMs);
    },
        bgmPathOf: (id) => _bgmCache?.localPathOf(id),
        voiceSegmentOf: _voiceSegmentOf,
        voiceOk: (path) => File(path).existsSync());
    setState(() => _planResult = result);
    unawaited(playback.setPlan(result.plan));
  }

  /// 口播轨上这一段该用哪个已规范化的文件；还没渲好就先返回 null
  /// （这一行这一轮不进预览），渲好之后自动重排一次
  String? _voiceSegmentOf({
    required String kind,
    required String source,
    required int inMs,
    required int durationMs,
    required double speed,
  }) {
    final key = '$kind|$source|$inMs|$durationMs|$speed';
    final ready = _voiceSegs[key];
    if (ready != null) return ready;
    final normalizer = _voiceNormalizer;
    if (normalizer == null || _renderingVoiceSegs.contains(key)) return null;
    if (kind != 'mute' && !File(source).existsSync()) return null;
    _renderingVoiceSegs.add(key);
    final job = kind == 'mute'
        ? normalizer.silence(durationMs: durationMs)
        : normalizer.normalize(
            source: source,
            inMs: inMs,
            durationMs: durationMs,
            speed: speed,
            tag: kind,
          );
    unawaited(job.then((path) {
      _voiceSegs[key] = path;
      if (mounted) _schedulePreviewRebuild();
    }).catchError((Object e) {
      AppLog.warn('预览口播段规范化失败（$kind $source）：$e');
    }).whenComplete(() => _renderingVoiceSegs.remove(key)));
    return null;
  }

  Future<void> _rebuildPreview() async {
    final playback = _playback;
    if (playback == null || !mounted) {
      if (mounted && _previewBusy) setState(() => _previewBusy = false);
      return;
    }
    // 变速镜头先渲对齐切片（按内容指纹缓存，改了才重渲）
    for (final line in _doc.lines) {
      for (final shot in line.shots) {
        if (shot.speed == 1.0 || shot.allocMs == null) continue;
        final key = _clipKey(shot);
        if (_speedClips.containsKey(key) ||
            _renderingClips.contains(key) ||
            _clipRenderer == null) {
          continue;
        }
        final src =
            shot.localSource ?? _mediaCache?.localPathOf(shot.materialId);
        if (src == null) continue;
        _renderingClips.add(key);
        unawaited(_clipRenderer!
            .render(
          materialId: shot.materialId,
          sourcePath: src,
          trimStartMs: shot.trimStartMs,
          allocMs: shot.allocMs!,
          speed: shot.speed,
        )
            .then((path) async {
          // 渲完当场量一次：切片比它在轨上声明的长度短，画面轨就会一路
          // 偏快、口播被反复往前拽（真机踩过）。这类错位在界面上毫无征兆，
          // 只能靠日志指认
          await _warnIfClipTooShort(path, shot.allocMs!);
          _speedClips[key] = path;
          if (mounted) _schedulePreviewRebuild();
        }).catchError((Object e) {
          AppLog.warn('变速切片渲染失败（素材 ${shot.materialId}）：$e');
        }).whenComplete(() => _renderingClips.remove(key)));
      }
    }
    final result = buildScriptTrackPlan(_doc, sourceOf: (shot) {
      if (shot.speed != 1.0) {
        final clip = _speedClips[_clipKey(shot)];
        return clip == null ? null : ShotSource(clip);
      }
      final local = shot.localSource ?? _mediaCache?.localPathOf(shot.materialId);
      return local == null
          ? null
          : ShotSource(local, inMs: shot.trimStartMs);
    },
        bgmPathOf: (id) => _bgmCache?.localPathOf(id),
        voiceSegmentOf: _voiceSegmentOf,
        voiceOk: (path) => File(path).existsSync());
    if (!mounted) return;
    setState(() => _planResult = result);
    if (playback is MultitrackPlayback) {
      await playback.setPlan(result.plan);
    }
    // 还有切片在渲就先不落——那时候画面还会再变一次
    if (mounted &&
        _renderingClips.isEmpty &&
        _renderingVoiceSegs.isEmpty &&
        _previewBusy) {
      setState(() => _previewBusy = false);
    }
  }

  Future<void> _togglePreviewPlay() async {
    final playback = _playback;
    if (playback == null) return;
    if (_previewPlaying) {
      await playback.pause();
    } else {
      // 开播前停掉分镜卡/配音试听——同时只有一个东西在响
      _stopInline();
      await _voicePreview.stop();
      if (_playingLineId != null) setState(() => _playingLineId = null);
      await playback.play();
    }
  }

  /// 播放位置落在哪一行，右栏就点亮哪一行（预览是主角，行块跟着它走）。
  /// 只在换行时 setState——位置流每帧都来，不能每帧重建行带板
  void _syncPreviewLine(int ms) {
    // 播到哪一镜就把哪一镜的操作栏摊开：人看着片子播过去，手边就是那一镜
    // 的取段、速度、原声，不用先暂停、再找到那一行、再点开
    final at = shotAt(_doc, _planResult.lineStarts, ms);
    final current = at?.$1;
    if (at != null && !_autoExpandPaused && _previewPlaying) {
      final want = at.$2 == null ? null : (at.$1, at.$2!);
      if (want != _expandedShot) setState(() => _expandedShot = want);
    }
    if (current == _previewLineIndex) return;
    final previous = _previewLineIndex;
    setState(() => _previewLineIndex = current);
    // 渐进换行由行块自己 ensureVisible；大跳（拖进度条）时目标行块
    // 可能还没被列表构建出来，先按比例粗滚过去让它构建
    if (current != null && (previous == null || (current - previous).abs() > 2)) {
      _scrollBoardNear(current);
    }
  }

  void _scrollBoardNear(int index) {
    if (!_boardScroll.hasClients || _doc.lines.isEmpty) return;
    final pos = _boardScroll.position;
    final target = ((index / _doc.lines.length) * pos.maxScrollExtent)
        .clamp(pos.minScrollExtent, pos.maxScrollExtent);
    unawaited(_boardScroll.animateTo(target,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic));
  }

  /// 传输条拖动定位：拖到哪就从哪继续（拖动中不被位置流打架，
  /// 见 _transportBar 的本地拖动态）
  Future<void> _seekPreview(int ms) async {
    await _playback?.seekMs(ms);
    _positionMs.value = ms;
    _syncPreviewLine(ms);
  }

  // ---- 导出 ----

  bool _exporting = false;

  /// 上次用的导出规格（同一个任务里连着导几版时不用重选）
  ExportSpec _exportSpec = ExportSpec.standard;
  final ValueNotifier<ScriptExportProgress?> _exportProgress =
      ValueNotifier(null);

  /// 导出前把素材补齐：**人已经点了导出，意图很明确**——还在下的就等它
  /// 下完（等待写进进度条），只有真下不下来才中断。把人赶回去自己猜
  /// 「下完了没有」不是商业软件该有的样子。
  ///
  /// 返回下不下来的那些（名字 + 原因）；空列表 = 可以开导了。
  Future<List<MediaBlocked>> _prepareMedia() async {
    // 先确保都在队列里（老方案打开后可能还没排过队）
    _pinAllShots();
    _pinBgm();
    final shotIds = <int, String>{};
    for (final line in _doc.lines) {
      for (final shot in line.shots) {
        if (shot.localSource != null) continue; // 参考段用的是原片，不走缓存
        shotIds[shot.materialId] = shot.name;
      }
    }
    final bgmIds = <int, String>{
      for (final seg in _doc.bgmSegments) seg.material.id: seg.material.name,
    };
    final needs = <MediaNeed>[
      for (final e in shotIds.entries) (id: e.key, name: e.value, isBgm: false),
      for (final e in bgmIds.entries) (id: e.key, name: e.value, isBgm: true),
    ];
    if (needs.isEmpty) return const [];
    final deadline = DateTime.now().add(const Duration(minutes: 20));
    while (true) {
      if (!mounted) return const [];
      final r = checkMedia(
        needs,
        statusOf: (n) =>
            (n.isBgm ? _bgmCache : _mediaCache)?.statusOf(n.id),
        failureOf: (n) =>
            (n.isBgm ? _bgmCache : _mediaCache)?.failureOf(n.id),
      );
      if (r.failed.isNotEmpty) return r.failed;
      if (r.canExport) return const [];
      if (DateTime.now().isAfter(deadline)) {
        return [
          (
            id: -1,
            name: '还有 ${r.pending} 项',
            reason: '下载迟迟没有完成（已等 20 分钟），请检查网络后重试',
            isBgm: false
          )
        ];
      }
      // 等待也要有交代：进度条上写清准备到第几项
      _exportProgress.value = ScriptExportProgress(
          '正在准备素材 ${r.ready}/${r.total}', r.ready / r.total * 0.06);
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  /// 素材没齐时的出路：**「知道了」不是操作**。给重试；如果卡住的
  /// 全是配乐，还可以把这几段配乐撤掉直接出片（画面和口播不受影响）
  Future<String?> _askMediaBlocked(List<MediaBlocked> failed) async {
    final allBgm = failed.every((f) => f.isBgm) && failed.first.id > 0;
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('素材还没齐'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final f in failed.take(5))
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('· ${f.isBgm ? '配乐' : '素材'}「${f.name}」：${f.reason}',
                    style: const TextStyle(fontSize: AppFontSize.caption)),
              ),
            if (failed.length > 5)
              Text('…还有 ${failed.length - 5} 项',
                  style: const TextStyle(
                      fontSize: AppFontSize.caption,
                      color: AppColors.textSecondary)),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('先不导')),
          if (allBgm)
            TextButton(
                key: const ValueKey('export-drop-bgm'),
                onPressed: () => Navigator.of(context).pop('drop-bgm'),
                child: const Text('去掉这几段配乐继续导出')),
          FilledButton(
              key: const ValueKey('export-retry-download'),
              onPressed: () => Navigator.of(context).pop('retry'),
              child: const Text('重试下载')),
        ],
      ),
    );
  }

  Future<void> _exportScript() async {
    final cache = _mediaCache;
    final dataDir = ref.read(dataDirProvider);
    if (cache == null || dataDir == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('当前环境没有素材下载器，无法导出。')));
      return;
    }
    _flushNow();
    // **该拦的在进门口拦**：有句子没配音/没挑镜头时导出必然失败，
    // 那就别让人先选一遍分辨率码率、点了「开始导出」才蹦出「没能导出」
    // （2026-09-10 真机走查）
    if (ScriptExportRunner.blockingReason(_doc) case final blocked?) {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: AppColors.surfaceRaised,
          title: const Text('还导不了'),
          content: SizedBox(
            width: 380,
            child: SelectableText(blocked,
                style: const TextStyle(
                    fontSize: AppFontSize.body,
                    color: AppColors.textSecondary,
                    height: 1.6)),
          ),
          actions: [
            FilledButton(
                key: const Key('script-export-blocked-ok'),
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('知道了')),
          ],
        ),
      );
      return;
    }
    // 规格该选还得选（与其他模块同一套面板）；记住上次的选择
    final spec = await showScriptExportDialog(
      context,
      initial: _exportSpec,
      durationMs: _planResult.plan.totalMs,
      lineCount: _doc.lines.where((l) => l.shots.isNotEmpty).length,
      // 少了哪几句、为什么少，在做「就导这个」这个决定的地方说
      skipped: _planResult.skippedLines,
    );
    if (spec == null || !mounted) return;
    setState(() {
      _exportSpec = spec;
      _exporting = true;
    });
    _exportProgress.value = const ScriptExportProgress('准备中', 0);
    // 模态进度：导出中不许再改内容，改了也不会进这一版成片
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ExportProgressDialog(progress: _exportProgress),
    ));
    // 先把素材补齐（还在下就等，进度写在条上）；下不下来才中断并给出路
    while (true) {
      final blocked = await _prepareMedia();
      if (!mounted) return;
      if (blocked.isEmpty) break;
      Navigator.of(context, rootNavigator: true).pop();
      final choice = await _askMediaBlocked(blocked);
      if (!mounted) return;
      if (choice == null) {
        setState(() => _exporting = false);
        return;
      }
      if (choice == 'drop-bgm') {
        final drop = {for (final f in blocked) f.id};
        _mutate((d) => d.withBgmSegments([
              for (final seg in d.bgmSegments)
                if (!drop.contains(seg.material.id)) seg,
            ]));
        _flushNow();
        _pinBgm();
      } else {
        for (final f in blocked) {
          (f.isBgm ? _bgmCache : _mediaCache)?.retry(f.id);
        }
      }
      _exportProgress.value = const ScriptExportProgress('准备中', 0);
      unawaited(showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _ExportProgressDialog(progress: _exportProgress),
      ));
    }
    final runner = ScriptExportRunner(
      workDir: Directory(p.join(dataDir.path, 'script_export', _task.id)),
      localPathOf: cache.localPathOf,
      localSourceOk: (path) => File(path).existsSync(),
      run: const ResolvingProcessRunner().call,
    );
    final stamp = DateTime.now();
    final outDir = p.join(
      PlatformPaths().desktopDirectory,
      'ishkafel-脚本成片',
    );
    final name = '#${_task.seq ?? ''}_'
        '${stamp.month.toString().padLeft(2, '0')}'
        '${stamp.day.toString().padLeft(2, '0')}_'
        '${stamp.hour.toString().padLeft(2, '0')}'
        '${stamp.minute.toString().padLeft(2, '0')}.${spec.format.name}';
    try {
      final out = await runner.export(
        doc: _doc,
        outPath: p.join(outDir, name),
        spec: spec,
        bgmPathOf: (id) => _bgmCache?.localPathOf(id),
        onProgress: (progress) => _exportProgress.value = progress,
      );
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('成片已导出：$out'),
        duration: const Duration(seconds: 6),
        action: SnackBarAction(
          label: PlatformShell().revealLabel,
          onPressed: () => PlatformShell().revealPath(out),
        ),
      ));
    } on ScriptExportException catch (e) {
      AppLog.warn('脚本导出被拦/失败：${e.message} ${e.cause ?? ''}');
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('没能导出'),
            content: Text(e.message),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('知道了')),
            ],
          ),
        );
      }
    } catch (e) {
      AppLog.warn('脚本导出失败：$e');
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('导出失败，请稍后重试。')));
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  PickedMediaCache? _buildMediaCache() {
    final fetch = ref.read(materialFetcherProvider);
    final dataDir = ref.read(dataDirProvider);
    if (fetch == null || dataDir == null) return null;
    return PickedMediaCache(
      fetch: (id) => fetch(_task.id, id),
      cacheDir: TaskMedia(dataDir: dataDir, taskId: _task.id).materialsDir,
    );
  }

  void _onMediaCache() {
    if (mounted) setState(() {});
    unawaited(_backfillMeasuredDurations());
    // 素材落地了就顺手看一眼画面：烧没烧字、露的是谁家产品。
    // **两样都只有看图才发现得了、而且会毁掉整片**——脚本成片自己要给
    // 台词烧一行字幕，素材再自带一层就是两层字叠在一起
    unawaited(_backfillFrameChecks());
  }

  /// 正在看的，避免同一条素材反复看
  final Set<int> _checkingFrames = {};

  /// 素材落地就做一次画面自查。
  ///
  /// 和实测时长走同一个时机（「文件都在本地了，量一下几十毫秒的事」）：
  /// 挑素材那一刻素材还没下载、看不了，落地之后就能抽帧。
  /// **能看清的时候就该看**，而不是让人拿到成片才发现素材上烧着别家的字。
  ///
  /// 先查跨任务缓存：一条素材看一次就够，不是每个任务看一次。
  Future<void> _backfillFrameChecks() async {
    final cache = _mediaCache;
    final dataDir = ref.read(dataDirProvider);
    if (cache == null || dataDir == null) return;
    final todo = shotsNeedingFrameCheck(
      doc: _doc,
      localPathOf: (id) =>
          _checkingFrames.contains(id) ? null : cache.localPathOf(id),
    );
    if (todo.isEmpty) return;
    final checker =
        ref.read(shotFrameCheckFactoryProvider)?.call(dataDir, _task.id);
    if (checker == null) return; // 没配 AI 凭据：记成「没查过」，不冒充没问题
    _checkingFrames.addAll(todo.map((s) => s.materialId));
    for (final shot in todo) {
      try {
        final result = await checker(shot.materialId, shot.durationMs);
        if (mounted) {
          _mutate((d) => d.withFrameCheck(shot.materialId, result));
        }
      } catch (err) {
        AppLog.warn('素材 ${shot.materialId} 的画面没看成：$err');
      } finally {
        _checkingFrames.remove(shot.materialId);
      }
    }
  }

  /// 正在量的，避免同一条素材反复量
  final Set<int> _measuring = {};

  /// 素材落地就量一次**真实时长**回填。
  ///
  /// 时长原本靠对着签名地址跑 ffprobe 探测，网络一抖就探不到；探不到就是
  /// null，而 null 在分配里被当成「无限长」——于是 1.2 秒的素材能被分到
  /// 6 秒的坑位，预览与成片两头出错（真机踩过）。文件都在本地了，量一下
  /// 几十毫秒的事，没有必要继续猜
  Future<void> _backfillMeasuredDurations() async {
    final cache = _mediaCache;
    if (cache == null) return;
    final todo = <int, String>{};
    for (final line in _doc.lines) {
      for (final shot in line.shots) {
        if (shot.localSource != null || shot.durationMs != null) continue;
        if (_measuring.contains(shot.materialId)) continue;
        final path = cache.localPathOf(shot.materialId);
        if (path != null) todo[shot.materialId] = path;
      }
    }
    if (todo.isEmpty) return;
    _measuring.addAll(todo.keys);
    for (final e in todo.entries) {
      try {
        final info = await FfprobeService().probe(e.value);
        final ms = info.duration.inMilliseconds;
        if (ms > 0 && mounted) {
          _mutate((d) => d.withMeasuredDuration(e.key, ms));
        }
      } catch (err) {
        AppLog.warn('素材 ${e.key} 实测时长失败：$err');
      } finally {
        _measuring.remove(e.key);
      }
    }
  }

  /// 把全部行的全部镜头固定到本地——挑中即下载，检索结果随时会变，
  /// 凡是进入方案的都要钉死（最高准则）
  void _pinAllShots() {
    final cache = _mediaCache;
    if (cache == null) return;
    cache.pinAll({
      for (final line in _doc.lines)
        for (final shot in line.shots) shot.materialId,
    });
  }

  static String get _holder => '人（编导台）';

  /// 与工作台/审核页同一套会话级互斥：谁先进谁处理
  /// 盘上这个任务的指纹。Agent 写盘之后它会变，界面据此重读
  String? _docPrint;

  /// 数据目录的缓存。**dispose 里读不到 ref**，而落盘检查在那时也要跑
  Directory? _dataDir;

  /// Agent 改了盘上的数据 → 这一页立刻显示新内容。
  ///
  /// 只在 Agent 在场时做：人自己编辑的时候，内存里的才是最新的，
  /// 反过来读盘会把人正在打的字冲掉
  void _followDocOnDisk(Directory dataDir, {bool force = false}) {
    final now = taskFingerprint(dataDir, _task.id);
    if (_docPrint == null && !force) {
      _docPrint = now;
      return;
    }
    if (now == _docPrint && !force) return;
    _docPrint = now;
    unawaited(_repo.findById(_task.id).then((fresh) {
      final doc = fresh?.script;
      if (!mounted || doc == null) return;
      setState(() {
        _task = fresh!;
        _doc = doc;
      });
      _schedulePreviewRebuild();
    }).catchError((Object e) {
      AppLog.warn('跟随 Agent 重读任务失败（${_task.id}）：$e');
    }));
  }

  /// 上一次为哪一行滚过。**同一行上的后续播报不再滚**——它在这一行做十件
  /// 事，界面就稳稳停在这一行，跟人自己操作时一样
  int? _scrolledTo;

  /// 哪些行此刻真的在树上：粗滚只为没构建的行出手
  final BuiltRows _builtRows = BuiltRows();

  /// 订阅 Agent 的在场状态。
  ///
  /// 用轮询而不是文件监听：这份文件是**另一个进程**写的，macOS 上的文件
  /// 事件对跨进程写入不总触发。500ms 一次与心跳同量级，跟得上手也不吃 CPU。
  void _watchAgent() {
    _agentPoll?.cancel();
    _agentPoll = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      final dataDir = ref.read(dataDirProvider);
      if (dataDir == null) return;
      // 编导台此前**接不了任何 Agent 请求**——脚本成片这条线在可视模式下
      // 一个委派都做不了。最要紧的一条是「让出写锁但留在页面」：
      // 不让位，Agent 就写不进来；让界面退出去，人就什么都看不见了
      _serveAgentRequest(dataDir);
      final now = readAgentPresence(dataDir: dataDir, taskId: _task.id);
      final was = _agent;
      final leaving = was != null && now == null;
      // **数据也要跟着走**：Agent 改了什么，这一页当场显示出来。
      // 以前只做了「滚到那一行」，人看到的是一块不动的板子
      if (now != null) _followDocOnDisk(dataDir);
      final focusChanged = now?.focus?.lineIndex != was?.focus?.lineIndex ||
          now?.focus?.shotIndex != was?.focus?.shotIndex ||
          now?.focus?.panel != was?.focus?.panel;
      if (was?.action == now?.action && !focusChanged && !leaving) return;

      setState(() {
        _agent = now;
        // 跟着它走：它看哪一行，界面就把哪一行摆到眼前；它开哪个面板，
        // 界面就展开哪个——**跟人自己点开时是同一套状态**，不另造展示
        final focus = now?.focus;
        if (focus != null && focus.lineIndex < _doc.lines.length) {
          _selected = focus.lineIndex;
          _expandedShot =
              (focus.panel == AgentPanel.shot ||
                          focus.panel == AgentPanel.findShots) &&
                      focus.shotIndex != null
                  ? (focus.lineIndex, focus.shotIndex!)
                  : null;
          // **只在换行时滚，而且只为「还没构建出来的行」出手。**
          //
          // 先粗滚才建得出那一行：右栏一屏放得下三四行，ListView 是懒构建
          // 的，焦点落在第 11 行时它压根不在树上，行内那个「滚到眼前」等不
          // 到任何回调——Agent 一过第 4 行界面就再也不动了。
          //
          // 但粗滚按**平均行高**估落点，而行高差得远（一行可能挂着 9 个镜头
          // 卡片）。Agent 在同一行上会连着播好几条（找镜头 → 看参考片画面 →
          // 搜到候选 → 提交），每条都滚一次的话，精调刚把这一行对准，下一条
          // 就把画面拽回估算点——人看到的是「不停地从这一行跳回第一行」，
          // 盯不住它在哪儿干活，可视化最要紧的那件事就没了。
          if (_scrolledTo != focus.lineIndex) {
            _scrolledTo = focus.lineIndex;
            ensureIndexVisible(
                controller: _boardScroll,
                index: focus.lineIndex,
                count: _doc.lines.length,
                alreadyBuilt: _builtRows.has(focus.lineIndex));
          }
        }
      });
      // **等这一帧真的画出来再回执**：Agent 靠它决定什么时候走下一步。
      // 收到就回的话，人还没看清界面已经翻篇了——那还不如不做可视
      if (now != null && now.step > 0) _ackAfterPainted(now.step);
      // 它干完走了：把它改的东西载进来——不载的话人随手一改就把它的活覆盖了
      if (leaving) {
        // 它走了：下次再来时重新对齐一次（人这期间可能自己滚到别处了）
        _scrolledTo = null;
        // 让出去的锁要收回来，不然人接着改，改到保存那一下才发现写不进去
        if (_yieldedToAgent) {
          _yieldedToAgent = false;
          _acquireLock();
        }
        unawaited(_reloadAfterAgent());
      }
    });
  }

  /// 等这一帧画完（滚动动画、面板展开都落定）再告诉 Agent「展示好了」。
  ///
  /// 节奏由界面决定而不是让 Agent 猜时间：机器快的时候它不白等，
  /// 慢的时候也不会一闪而过没看清
  void _ackAfterPainted(int step) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 滚动是有动画的（_ScrollIntoView 用 animateTo），再等一拍让它停下来
      // 停够再回执：这个值与播报条共用一份（见 visualPace），
      // 各定各的话谁先回执 Agent 就走，另一头整步扑空
      Future<void>.delayed(visualStepDwell, () {
        if (!mounted) return;
        final dataDir = ref.read(dataDirProvider);
        if (dataDir == null) return;
        writeAgentAck(dataDir: dataDir, taskId: _task.id, step: step);
      });
    });
  }

  /// Agent 收工后重新读盘。**先把本地未落盘的改动冲掉**，免得人自己的活丢了
  Future<void> _reloadAfterAgent() async {
    _flushNow();
    final fresh = await _repo.findById(_task.id);
    final script = fresh?.script;
    if (!mounted || script == null) return;
    setState(() {
      _doc = script;
      _undoStack.clear();
      _redoStack.clear();
    });
    _pinAllShots();
    _pinBgm();
    _schedulePreviewRebuild();
    _toast('Agent 的改动已载入。');
  }

  /// 人要抢回来：撤掉在场状态，Agent 之后的写入会被锁拒掉
  Future<void> _takeoverFromAgent() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('接手这个任务？'),
        content: const Text('Agent 正在做的这一步会被打断，它之后的写入会被'
            '拒绝。已经改好的部分会保留。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('让它继续')),
          FilledButton(
              key: const ValueKey('agent-takeover-confirm'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('我来接手')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final dataDir = ref.read(dataDirProvider);
    if (dataDir != null) {
      clearAgentPresence(dataDir: dataDir, taskId: _task.id);
    }
    // **人接手了，这一页就不再自动让位。**
    //
    // 让位机制是为「人在旁边看着它干活」做的；人一旦按了这个按钮，
    // 意思正相反：他要自己动手了。不记这一笔的话，Agent 下一条命令
    // 一来，这一页又乖乖把锁让出去——**接手按钮等于白按**
    //（真机上人按完还没来得及操作，Agent 就又接着写了）。
    _humanTookOver = true;
    _yieldedToAgent = false;
    // 界面自己在跑的自动铺片也要停：人按这个按钮的意思是「我来」，
    // 不是「你们俩一起来」
    _cancelDraft();
    if (_lock == null) _acquireLock();
    setState(() => _agent = null);
    await _reloadAfterAgent();
  }

  /// 人按过「我来接手」。在他离开这一页之前，不再把写锁让给 Agent
  bool _humanTookOver = false;

  bool _servingRequest = false;

  /// 这一页把写锁让给 Agent 了。它收工之后要**自己把锁拿回来**，
  /// 否则人接着改会一路改到保存被拒才发现
  bool _yieldedToAgent = false;

  /// Agent 请这一页做一件事。目前只有一件：**让出写锁**。
  ///
  /// 让位之后这一页转成只读跟随（和「Agent 占着锁时人打开这一页」同一套
  /// 状态），人能眼看着它一行行往下做；要抢回来点横幅上的「我来接手」。
  void _serveAgentRequest(Directory dataDir) {
    if (_servingRequest) return;
    final req = consumeAgentRequest(dataDir: dataDir, taskId: _task.id);
    if (req == null) return;
    _servingRequest = true;
    void reply(bool ok, String message) {
      writeAgentRequestResult(
          dataDir: dataDir,
          taskId: _task.id,
          id: req.id,
          ok: ok,
          message: message,
          payload: const {});
      _servingRequest = false;
    }

    switch (UiAction.parse(req.kind)) {
      case UiAction.lockYield:
        if (_humanTookOver) {
          reply(false, '人已经按了「我来接手」，这个任务现在由他自己动手——'
              '**停下来问他**，别再往这条任务里写');
          return;
        }
        if (_lock == null) {
          reply(true, '这一页本来就没占着写锁');
          return;
        }
        // **先把没落盘的改动冲下去再让**：人可能刚拖过一镜、改过一句台词，
        // 让位之后这一页就写不进去了，不冲就丢了
        _flushNow();
        _lockHeartbeat?.cancel();
        _lockHeartbeat = null;
        _lock?.release(_holder);
        _lock = null;
        // **别设 _blockedBy**：那个字段的意思是「被另一个界面挡住了」，
        // 它渲染的是一张「等它结束再进」的空白拦截页——而人打开这一页
        // 正是为了看 Agent 干活，拦掉等于把要看的东西挡在门外。
        // 只读跟随靠的是在场状态（_agent），那一套已经有了
        _yieldedToAgent = true;
        reply(true, '写锁让给你了，人还在这一页看着——'
            '记得把每一步都播报出来');
      default:
        reply(false, '这一页接不了这个动作：${req.kind}');
    }
  }

  void _acquireLock() {
    final dataDir = ref.read(dataDirProvider);
    if (dataDir == null) return;
    final lock = TaskLockFile(dataDir: dataDir, taskId: _task.id);
    if (!lock.acquire(_holder)) {
      final holder = lock.read()?.holder;
      // Agent 占着**不拦成一张空白页**：可视模式下人正是为了看它干活才
      // 打开这一页的，拦掉等于把要看的东西挡在门外。转成只读跟随
      // （见 [_watchAgent]），它一收工这一页自动可操作。
      //
      // 审片台早就这么做了，这里漏了——验收 Agent 报回来的现象是：
      // 「人在旁边看着，看到的是一块黑板」
      if (isGuiHolder(holder)) _blockedBy = holder ?? '别人';
      return;
    }
    _lock = lock;
    // 心跳让锁活着：写脚本可能一坐半小时，超时失效等于没锁
    _lockHeartbeat = Timer.periodic(
        const Duration(seconds: 20), (_) => lock.heartbeat(_holder));
  }

  /// 抢锁是破坏性的（对方之后的保存会被拒绝），与审核页同一套确认规矩
  Future<void> _forceTakeover() async {
    final dataDir = ref.read(dataDirProvider);
    if (dataDir == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('当前环境没有数据目录，无法接管')));
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('强制接管这个任务？'),
        content: Text('「${_blockedBy ?? '对方'}」之后的保存会被拒绝，'
            '它未落盘的改动可能丢失。确定要接管吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('接管')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final lock = TaskLockFile(dataDir: dataDir, taskId: _task.id);
    lock.forceTakeover(_holder);
    setState(() => _blockedBy = null);
    _lock = lock;
    _lockHeartbeat = Timer.periodic(
        const Duration(seconds: 20), (_) => lock.heartbeat(_holder));
  }

  @override
  void dispose() {
    _autosave?.cancel();
    _flushNow();
    _lockHeartbeat?.cancel();
    _lock?.release(_holder);
    _mediaCache?.removeListener(_onMediaCache);
    _mediaCache?.dispose();
    _bgmCache?.removeListener(_onMediaCache);
    _bgmCache?.dispose();
    _previewRebuild?.cancel();
    unawaited(_positionSub?.cancel());
    unawaited(_playingSub?.cancel());
    _replayDebounce?.cancel();
    _agentPoll?.cancel();
    unawaited(_inlineLoop?.cancel());
    unawaited(_inlinePosSub?.cancel());
    _inlinePositionMs.dispose();
    unawaited(_inlinePlayer?.dispose());
    unawaited(_inlineAudio?.dispose());
    _playback?.dispose();
    _positionMs.dispose();
    unawaited(_voicePreview.dispose());
    super.dispose();
  }

  // ---- 配音 ----

  /// 给某行挑音色。选完只是记下——生成才花钱
  Future<void> _pickVoice(int index) async {
    final line = _doc.lines[index];
    final voicedCount =
        _doc.lines.where((l) => l.type == ScriptLineType.voiced).length;
    final picked = await showVoiceSelectDialog(context,
        // 预填有效值：行上没设就是本片基调
        selected: _doc.voiceIdOf(line), allowApplyAll: voicedCount > 1);
    if (picked == null || !mounted) return;
    final (voiceId, applyAll) = picked;
    if (!applyAll) {
      _mutate((d) => d.setVoiceId(index, voiceId));
      return;
    }
    await _unifyVoice(voiceId);
  }

  /// 把某个音色定成**本片基调**：新生成的都用它，各行单独设过的一并清掉。
  ///
  /// 这是「在某一行试出满意的音色，推广到全片」那条路径的落点——
  /// 用户实际就是这么用的：随便找一行反复生成试听，满意了推给其他行
  Future<void> _unifyVoice(String voiceId) async {
    _mutate((d) => d.unifyVoice(voiceId));
    final name = VoiceCatalog.byId(voiceId)?.ref.name ?? voiceId;
    // 已经生成的那些现在是旧音色了。**不问就是错**：前几句旧音色、
    // 后几句新音色，混出一条前后不一样的片子，最容易一路漏到成片
    final stale = _doc.staleVoiceLines;
    if (stale.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('本片音色定为「$name」，之后生成的都用它。')));
      return;
    }
    if (!mounted) return;
    final redo = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surfaceRaised,
        title: Text('本片音色改为「$name」'),
        content: Text('已经生成的 ${stale.length} 句还是旧音色。'
            '不重新生成的话，这条片子前后会是两个人的声音。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('先留着'),
          ),
          FilledButton(
            key: const Key('voice-unify-redo'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text('重新生成这 ${stale.length} 句'),
          ),
        ],
      ),
    );
    if (redo != true || !mounted) return;
    await _regenerateVoices([for (final l in stale) l.id]);
  }

  /// 批量重配这几行。**要有进度、要能取消**——十几句就是分钟级的活，
  /// 点下去以后软件假死两分钟是不能接受的
  Future<void> _regenerateVoices(List<String> lineIds) async {
    _cancelBatchVoice = false;
    var failed = 0;
    for (var i = 0; i < lineIds.length; i++) {
      if (!mounted || _cancelBatchVoice) break;
      final line = _doc.lines.where((l) => l.id == lineIds[i]).firstOrNull;
      if (line == null) continue; // 期间被删了
      setState(() => _batchVoiceProgress = (i + 1, lineIds.length, line.text));
      final voiceId = _doc.voiceIdOf(line);
      if (voiceId == null) continue;
      if (!await _generateVoiceCore(line.id, voiceId)) failed++;
    }
    if (!mounted) return;
    final stopped = _cancelBatchVoice;
    setState(() => _batchVoiceProgress = null);
    final flat = lineIds.where(_deliveryDegraded.containsKey).length;
    final flatNote =
        flat > 0 ? '（其中 $flat 句没听成参考片的念法，用的是默认语气）' : '';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(stopped
            ? '已停下。生成好的那几句保留着，其余仍是旧音色。'
            : failed == 0
                ? '${lineIds.length} 句都换好了。$flatNote'
                : '$failed 句没生成成功，可以单独点那几句重试。$flatNote')));
  }

  /// 显式生成配音：设计稿定死——改字只标黄，点这里才调 API
  /// **用我自己录的配音**：选一个音频装到这一行上。
  ///
  /// 这一行的时长、逐字时间、甚至台词都以这段录音为准——人已经念出来了，
  /// 那就是事实。合成语音的情绪天花板摆在那儿，这是最后那条路。
  Future<void> _uploadVoice(int index) async {
    final picked = await ref.read(voiceFilePickerProvider)();
    if (picked == null || !mounted) return;
    final dataDir = ref.read(dataDirProvider);
    if (dataDir == null) return;
    final line = _doc.lines[index];
    setState(() => _generatingLineIds.add(line.id));
    try {
      final kept = await keepUploadedVoice(
          source: File(picked), dataDir: dataDir, taskId: _task.id, lineId: line.id);
      final durationMs = await measureAudioMs(kept);
      if (durationMs <= 0) {
        _toast('这个音频读不出时长，可能不是能用的音频文件。');
        return;
      }
      // 逐字时间是断句和字幕打轴的依据。听不出来只影响这两样，
      // **不该挡住「用我自己的配音」这件事**——但要说出来
      var words = const <VoiceWord>[];
      var heard = '';
      final asr = ref.read(voiceWordsProvider);
      if (asr == null) {
        _toast('没配语音服务，听不出这段说了什么——时长照用，但断不了句。');
      } else {
        try {
          words = await asr(kept);
          heard = words.map((w) => w.text).join();
        } catch (e) {
          AppLog.warn('上传配音转写失败（line=${line.id}）：$e');
          _toast('这段录音没听清——时长照用，但断不了句。');
        }
      }
      if (!mounted) return;
      final before = line.text.trim();
      _mutate((d) => applyUploadedVoice(
            doc: d,
            lineIndex: index,
            audioPath: kept.path,
            durationMs: durationMs,
            words: words,
            heardText: heard,
          ));
      final after = _doc.lines[index].text.trim();
      if (after != before) {
        // 悄悄把台词换掉，人回头看脚本会以为自己记错了
        _toast('台词按你录的改了：「$after」');
      }
    } catch (e) {
      if (mounted) _toast('这段配音没装上：$e');
    } finally {
      if (mounted) setState(() => _generatingLineIds.remove(line.id));
    }
  }

  Future<void> _generateVoice(int index) async {
    final factory = ref.read(lineVoiceFactoryProvider);
    if (factory == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('尚未配置 AI 服务（语音合成），无法生成配音。')));
      return;
    }
    var line = _doc.lines[index];
    if (line.voiceId == null) {
      // 还没选音色：先弹选择器，选完直接接着生成——别让用户点两遍
      await _pickVoice(index);
      line = _doc.lines[index];
      if (line.voiceId == null) return;
    }
    final ok = await _generateVoiceCore(line.id, line.voiceId!);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('配音生成失败，请稍后重试。')));
      return;
    }
    // 配出来了，但没听成参考片的念法——这一句是默认语气，说清楚，
    // 别让人以为「就该是这个味儿」
    final degraded = _deliveryDegraded[line.id];
    if (degraded != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('配好了，但没听成参考片这一句是怎么念的，'
              '用的是默认语气（$degraded）。重新生成一次多半就好了。')));
    }
  }

  /// 这几句没听成参考片的念法（lineId → 原因），用的是默认语气。
  /// **必须说出去**：情绪扁平的配音和正常配音在界面上长得一模一样，
  /// 不说的话人只会觉得「这软件配出来就是这个味儿」
  final Map<String, String> _deliveryDegraded = {};

  /// 配音生成内核（静默版）：草片流水线与单行按钮共用。
  /// 成功返回 true；失败只留日志，由调用方决定怎么告知
  Future<bool> _generateVoiceCore(String lineId, String voiceId) async {
    final factory = ref.read(lineVoiceFactoryProvider);
    if (factory == null) return false;
    final line = _doc.lines.firstWhere((l) => l.id == lineId);
    setState(() => _generatingLineIds.add(lineId));
    try {
      final service = factory(_task);
      // 先听一遍参考片这一句是怎么念的，把念法交给合成。不带这句指令，
      // 预置音色只会用默认语气平铺直叙——用户反馈里那条「原片在激动地
      // 争吵，复刻出来情绪非常扁平」就是这么来的。
      // 听过的按内容指纹走缓存，重配同一句不再花钱
      final delivery = ref.read(lineDeliveryFactoryProvider)?.call(_task);
      final how = delivery == null
          ? LineDelivery.none
          : await delivery.resolve(deliveryRequestOf(_doc, line));
      if (how.degradedReason == null) {
        _deliveryDegraded.remove(lineId);
      } else {
        _deliveryDegraded[lineId] = how.degradedReason!;
      }
      if (!mounted) return false;
      final vo = await service.generate(
        lineId: lineId,
        text: line.text,
        voiceId: voiceId,
        speechRate: _doc.speechRateOf(line),
        instruction: how.instruction,
      );
      if (!mounted) return false;
      _mutate((d) => d.setVoiceoverById(lineId, vo));
      // 配音时长是这一行时间轴的根：根变了，镜头的时长分配跟着重算
      final updated = _doc.lines.firstWhere((l) => l.id == lineId);
      if (updated.shots.isNotEmpty) {
        _mutate((d) => d.setShotsById(
            lineId,
            ShotAllocation.fillBySlowdown(
                reallocShots(updated, updated.shots), vo.durationMs)));
      }
      _flushNow();
      // 旧配音**不再立即删**：⌘Z 撤销可能把数据回滚到旧文件上，
      // 立即删就撤成死链（真机发生过：行 2 台词整段无声）。
      // 不被任何行引用的旧 mp3 由任务清理兜底回收
      return true;
    } catch (e) {
      AppLog.warn('配音生成失败（line=$lineId）：$e');
      return false;
    } finally {
      if (mounted) setState(() => _generatingLineIds.remove(lineId));
    }
  }

  // ---- 找镜头 ----

  /// 打开找镜头面板；确认后整组落回行上（按行 id，面板期间行可能被移动）
  Future<void> _findShots(int index) async {
    final line = _doc.lines[index];
    // 防撞车：同任务其他行已用的素材要在面板里标出来
    final usedBy = <int, int>{};
    for (var i = 0; i < _doc.lines.length; i++) {
      for (final shot in _doc.lines[i].shots) {
        if (shot.localSource != null) continue; // 参考段不参与防撞车
        usedBy.putIfAbsent(shot.materialId, () => i);
      }
    }
    final picked = await showFindShotsSheet(
      context,
      services: ref.read(shotSearchServicesProvider),
      tagger: ref.read(lineTaggerProvider),
      task: _task,
      lineIndex: index,
      line: line,
      usedBy: usedBy,
      // 参考原子条的数据：原子首帧缩略图 + 原片路径（直接用原片这段）
      refThumbOf: (segIndex) {
        _ensureRefThumb(line, segIndex);
        return _refThumbs['${line.id}_$segIndex'];
      },
      refVideoPath: _refVideoOf(line),
      // 「画面相似」：拿参考镜的首帧去妙啊搜像的画面
      queryFrames: ref.read(queryFrameUploaderProvider),
      tagRefShot: (segIndex) => _tagRefShot(line.id, segIndex),
      // 参考没切过视觉镜头：在面板里切（面板开着 loading），切完把
      // 新的行回给面板——不让人看旧数据、也不必关掉重开
      prepareRef: () async {
        await _ensureRefCuts(line.id);
        return _doc.lines.where((l) => l.id == line.id).firstOrNull;
      },
    );
    if (picked == null) return;
    // 挑完就把时长按行的根均分好（默认全自动预填，人只做否决）；
    // 行还没有根（没配音/没填时长）就先不分，界面会说清下一步
    // 走统一入口：这一行可能已经有划词镜，老的均分会把它们的时长平摊掉
    final shots = reallocShots(line, picked.shots);
    _mutate((d) =>
        d.setShotsById(line.id, shots).setTagsById(line.id, picked.tags));
    _flushNow();
    _pinAllShots();
  }

  /// 改台词。**划词建的镜头会失效**：字变了，词序号整个错位，
  /// 之前「这几个字配这个画面」的对应关系全部说不通了。
  ///
  /// 所以要清掉——但清之前说清损失，别让人改个错别字就丢了挑好的素材
  Future<void> _changeText(int index, String text) async {
    final line = _doc.lines[index];
    if (line.text.trim() == text.trim()) return;
    final bound = line.shots.where((s) => s.boundToWords).length;
    if (bound > 0) {
      final withMaterial =
          line.shots.where((s) => s.boundToWords && s.materialId > 0).length;
      final ok = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: AppColors.surfaceRaised,
          title: const Text('改了台词，划词的分镜要清掉'),
          content: Text('这一行有 $bound 个分镜是按字划出来的'
              '${withMaterial > 0 ? '（其中 $withMaterial 个已经挑好素材）' : ''}。'
              '台词一改，字的位置全变了，这些对应关系就不成立了——'
              '只能清掉重划。'),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('先不改')),
            FilledButton(
                key: const Key('text-change-drop-bound'),
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('改，并清掉这些分镜')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    _mutate((d) {
      var next = d.updateText(index, text);
      if (bound > 0) {
        final kept = [
          for (final s in next.lines[index].shots)
            if (!s.boundToWords) s,
        ];
        next = next.setShotsById(next.lines[index].id, kept);
      }
      return next;
    });
  }

  /// 划词建镜：选中的字读多久，这一镜就多长。
  ///
  /// 与「找镜头」的区别是**插入而不是替换**：那个是给整行铺一遍，
  /// 这个是给这几个字单配一个画面，其余镜头原样不动
  Future<void> _addShotByWords(int index, int startWord, int endWord) async {
    final line = _doc.lines[index];
    final usedBy = <int, int>{};
    for (var i = 0; i < _doc.lines.length; i++) {
      for (final shot in _doc.lines[i].shots) {
        if (shot.localSource != null) continue;
        usedBy.putIfAbsent(shot.materialId, () => i);
      }
    }
    final picked = await showFindShotsSheet(
      context,
      services: ref.read(shotSearchServicesProvider),
      tagger: ref.read(lineTaggerProvider),
      task: _task,
      lineIndex: index,
      line: line,
      usedBy: usedBy,
      refThumbOf: (segIndex) {
        _ensureRefThumb(line, segIndex);
        return _refThumbs['${line.id}_$segIndex'];
      },
      queryFrames: ref.read(queryFrameUploaderProvider),
      tagRefShot: (segIndex) => _tagRefShot(line.id, segIndex),
      prepareRef: () async {
        await _ensureRefCuts(line.id);
        return _doc.lines.where((l) => l.id == line.id).firstOrNull;
      },
    );
    if (picked == null || picked.shots.isEmpty || !mounted) return;
    // 一次划词配一个画面。挑了多个只用第一个——要给这几个字配好几个画面，
    // 就分几次划，那样每一段的时长才说得清
    final shot =
        picked.shots.first.copyWith(startWord: startWord, endWord: endWord);
    final next = [...line.shots];
    next.insert(insertIndexForWords(next, startWord), shot);
    _mutate((d) => d.setShotsById(line.id, reallocShots(line, next)));
    _flushNow();
    _pinAllShots();
    if (picked.shots.length > 1 && mounted) {
      _toast('这次只用了挑中的第一个画面——要给这几个字配多个画面，分几次划。');
    }
  }

  /// 这一句的参考还没切过视觉镜头时，**就地切一次**（只切这句的区间，
  /// 几秒；老任务提取时没切出切点，不必为此重新提取整片）。
  /// 切点存回行上，之后即开即用；切失败不挡路——退回整段一镜
  Future<void> _ensureRefCuts(String lineId) async {
    final line = _doc.lines.where((l) => l.id == lineId).firstOrNull;
    final ref = line?.reference;
    final video = line == null ? null : _refVideoOf(line);
    if (line == null || ref == null || video == null) return;
    // 新档提取时已经按全片切点分好完整镜头了——再就地切一遍，只会把
    // 一个完整镜头按台词边界重新切碎，正是这次修的那个 bug
    if (ref.hasWholeShots || ref.cuts.isNotEmpty ||
        _refCutting.contains(lineId)) {
      return;
    }
    if (!File(video).existsSync()) return;
    _refCutting.add(lineId);
    try {
      // 只切这一句的区间：先裁一段临时片再检测，比整片检测快得多
      final dataDir = this.ref.read(dataDirProvider);
      final tmp = File(p.join(
          dataDir?.path ?? Directory.systemTemp.path,
          'script_refs',
          _task.id,
          'cut_${line.id}.mp4'));
      await tmp.parent.create(recursive: true);
      final cut = await const ResolvingProcessRunner().call('ffmpeg', [
        '-y', '-v', 'error',
        '-ss', (ref.startMs / 1000).toStringAsFixed(3),
        '-t', (ref.durationMs / 1000).toStringAsFixed(3),
        '-i', video,
        '-an', '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '28',
        tmp.path,
      ]);
      if (cut.exitCode != 0) throw StateError('裁参考段失败');
      final rel = await SceneDetector(run: const ResolvingProcessRunner().call)
          .detect(tmp.path);
      try {
        tmp.deleteSync();
      } catch (_) {}
      // 相对坐标 → 原片坐标；丢掉太靠边的切点（<400ms 的碎段没价值）
      final abs = [
        for (final ms in rel)
          if (ms > 400 && ms < ref.durationMs - 400) ref.startMs + ms,
      ];
      if (abs.isEmpty || !mounted) return;
      _mutate((d) => d.setReferenceById(line.id, ref.withCuts(abs)));
      AppLog.info('参考就地切分（line=$lineId）：${abs.length} 个切点');
    } catch (e) {
      AppLog.warn('参考就地切分失败（line=$lineId，退回整段一镜）：$e');
    } finally {
      _refCutting.remove(lineId);
    }
  }

  final Set<String> _refCutting = {};

  /// 给参考视觉镜头按需打标：抽三帧（头/中/尾）→ ShotTagger 一次出
  /// 标签 + 画面描述 → 缓存回行上（切点变了自动失效）。
  /// 打标是花钱的一步，所以**只在点选那一镜时打这一镜**，不整片预打
  Future<RefShotMeta?> _tagRefShot(String lineId, int segIndex) async {
    final line = _doc.lines.where((l) => l.id == lineId).firstOrNull;
    final ref = line?.reference;
    final video = line == null ? null : _refVideoOf(line);
    final tagger = ref == null ? null : this.ref.read(refShotTaggerProvider);
    final dataDir = this.ref.read(dataDirProvider);
    if (line == null || ref == null || video == null || tagger == null ||
        dataDir == null) {
      return null;
    }
    final segs = ref.segments;
    if (segIndex < 0 || segIndex >= segs.length) return null;
    final (segStart, segEnd) = segs[segIndex];
    try {
      // 三帧：头/中/尾——单帧看不出镜头里在发生什么（U 层实测）
      final dir = Directory(
          p.join(dataDir.path, 'script_refs', _task.id, 'tag_${line.id}_$segIndex'));
      await dir.create(recursive: true);
      final frames = <List<int>>[];
      String? firstFrame;
      for (final (i, at) in [
        (0, segStart + 120),
        (1, (segStart + segEnd) ~/ 2),
        (2, segEnd - 120),
      ]) {
        final out = p.join(dir.path, 'f$i.jpg');
        final r = await const ResolvingProcessRunner().call('ffmpeg', [
          '-y', '-v', 'error',
          '-ss', (at / 1000).toStringAsFixed(3),
          '-i', video,
          '-frames:v', '1',
          '-vf', 'scale=-2:480',
          out,
        ]);
        if (r.exitCode == 0 && File(out).existsSync()) {
          frames.add(File(out).readAsBytesSync());
          firstFrame ??= out;
        }
      }
      if (frames.isEmpty) return null;
      // 视觉镜头层用**视觉镜头标签组**的词表（与单元层的话术标签不同）
      final groups = _task.shotTagGroups.isNotEmpty
          ? _task.shotTagGroups
          : _task.unitTagGroups;
      final vocab = <TagDimension>[];
      try {
        final all = await this.ref.read(shotSearchServicesProvider).tags.listGroups();
        for (final g in groups) {
          final hit = all.where((x) => x.id == g.id).firstOrNull;
          if (hit != null && hit.tags.isNotEmpty) {
            vocab.add(TagDimension(name: hit.name, vocabulary: hit.tags));
          }
        }
      } catch (e) {
        AppLog.warn('参考镜头打标拉词表失败（只出画面描述）：$e');
      }
      final understanding = await tagger.understand(
        frames: frames,
        dimensions: vocab,
        constraint: _task.shotTagPrompt.isEmpty ? null : _task.shotTagPrompt,
      );
      final meta = RefShotMeta(
        startMs: segStart,
        description: understanding.description ?? '',
        tags: understanding.tags,
        framePath: firstFrame,
      );
      if (!mounted) return meta;
      _mutate((d) => d.setReferenceById(line.id, ref.withShotMeta(meta)));
      return meta;
    } catch (e) {
      AppLog.warn('参考镜头打标失败（line=$lineId seg=$segIndex）：$e');
      return null;
    }
  }

  /// 从这一句开始换一首（在轨上切一刀）：切开后先继承上一段的曲子，
  /// 紧接着弹选曲——多数时候你就是要给后半段换个曲子
  Future<void> _bgmSplitAt(int lineIndex) async {
    final rail = bgmRail(_doc.bgmSegments, _doc.lines.length);
    final next = splitRailAt(rail, lineIndex);
    if (identical(next, rail)) return;
    _mutate((d) => d.withBgmSegments(railToSegments(next)));
    final segIndex = next.indexWhere((s) => s.startLine == lineIndex);
    if (segIndex >= 0) await _bgmEditSegment(segIndex);
  }

  /// 点段首色带：给这一段换曲 / 调音量 / 设为不要配乐 / 与上一段合并
  Future<void> _bgmEditSegment(int segIndex) async {
    final rail = bgmRail(_doc.bgmSegments, _doc.lines.length);
    if (segIndex < 0 || segIndex >= rail.length) return;
    final seg = rail[segIndex];
    // 这一段有多长：按已就绪行的时长累加（说清「这段要放多久的曲子」）
    var rangeMs = 0;
    for (var i = seg.startLine; i <= seg.endLine && i < _doc.lines.length; i++) {
      final root = ShotAllocation.rootMsOf(_doc.lines[i]);
      rangeMs += root ?? 0;
    }
    final choice = await showBgmPicker(
      context,
      rangeMs: rangeMs,
      rangeLabel: '第 ${seg.startLine + 1}~${seg.endLine + 1} 句',
      canClear: true,
      projectIds: [if (_task.project != null) _task.project!.id],
      initialVolume: seg.volume,
      initialMaterials: [if (seg.material != null) seg.material!],
      // 编导台是一条片子，一段配乐就一首曲子——多选出来的其余几首
      // 根本不会被用到（代码里一直只取第一首），摆出来只会误导
      singleSelect: true,
      // 想把中间几句换首曲子，直接在面板里改范围——不用先切两刀再选曲
      range: (seg.startLine, seg.endLine),
      lineCount: _doc.lines.length,
    );
    if (choice == null || !mounted) return;
    // 改了范围就整条轨重排（相邻段让位）；没改就只换这一段的曲子与音量
    final List<BgmRailSegment> next;
    if (choice is BgmPicked &&
        choice.range != null &&
        choice.range != (seg.startLine, seg.endLine)) {
      final (from, to) = choice.range!;
      next = setRailRange(
        rail,
        from,
        to,
        choice.materials.isEmpty ? null : choice.materials.first,
        choice.volume,
      );
    } else {
      final updated = switch (choice) {
        BgmPicked(materials: final ms, volume: final v) => seg.copyWith(
            material: ms.isEmpty ? null : ms.first, volume: v),
        _ => seg.copyWith(material: null),
      };
      next = [
        for (var i = 0; i < rail.length; i++)
          if (i == segIndex) updated else rail[i],
      ];
    }
    _mutate((d) => d.withBgmSegments(railToSegments(next)));
    _pinBgm();
  }

  /// 一句短提示（打轴这类高频操作要立刻有交代，不许点了没反应）
  void _toast(String message) {
    if (!mounted) return;
    final m = ScaffoldMessenger.of(context)..clearSnackBars();
    m.showSnackBar(SnackBar(
        content: Text(message), duration: const Duration(seconds: 2)));
  }

  /// 打轴：正在原位播这一镜时，在**当前播放位置**换一屏。
  /// 十秒六句话，听一遍点五下就切完了——比数字数快。
  /// 切点只记「从哪个字另起一屏」，镜头时长怎么改都不跑偏
  void _cutSubtitleHere(int index, int j) {
    final line = _doc.lines[index];
    if (j < 0 || j >= line.shots.length) return;
    final player = _inlinePlayer;
    if (player == null || _inlineKey != 'shot_${line.id}_$j') {
      _toast('先播这一镜，听到该换屏的地方再点。');
      return;
    }
    // 播放位置（素材坐标）→ 这一镜内已经走了多久 → 行时间轴（成片时间）
    final shot = line.shots[j];
    final playedMs =
        ((player.positionMs - shot.trimStartMs) / shot.speed).round();
    final atMs = _lineShotStart(line, j) +
        playedMs.clamp(0, shot.allocMs ?? 0);
    final chars = _styleOf(line).maxCharsPerScreen;
    final before = line.subtitleScreensAt(maxChars: chars).length;
    final next = line.cutSubtitleAt(atMs, maxChars: chars);
    if (next.subtitleScreensAt(maxChars: chars).length == before) {
      // 切不动要说清为什么（这一刻正说着这一屏的第一个字 / 没有词级时间戳）
      _toast(line.voiceover?.words.isEmpty ?? true
          ? '这句配音没有逐字时间，重新生成配音后才能打轴。'
          : '这里已经是一屏的开头了。');
      return;
    }
    _mutate((d) => d.cutScreenById(line.id, atMs, maxChars: chars),
        affectsTracks: false);
    _toast('已在 ${(atMs / 1000).toStringAsFixed(1)}s 换屏。');
  }

  /// 这一镜在行时间轴上的起点（成片时间）
  int _lineShotStart(ScriptLine line, int j) {
    var start = 0;
    for (var i = 0; i < j && i < line.shots.length; i++) {
      start += line.shots[i].allocMs ?? 0;
    }
    return start;
  }

  /// 改行标签：从妙啊标签体系里搜索、点选、替换（不只是删）
  Future<void> _editTags(int index) async {
    final line = _doc.lines[index];
    final picked = await showTagPicker(
      context,
      tags: ref.read(shotSearchServicesProvider).tags,
      selected: line.tags,
      preferredGroupIds: {for (final g in _task.unitTagGroups) g.id},
    );
    if (picked == null || !mounted) return;
    _mutate(
        (d) => d.setTagsById(line.id, [for (final t in picked) t.name]),
        affectsTracks: false);
  }

  // ---- 时长分配 ----

  void _updateShots(int index, List<LineShot> shots) {
    final line = _doc.lines[index];
    _mutate((d) => d.setShotsById(line.id, shots));
  }

  void _distribute(int index) {
    final line = _doc.lines[index];
    _updateShots(index, reallocShots(line, line.shots));
  }

  /// 素材偏短分不满行时长：放慢镜头把整行充满（分镜可加速可放慢，
  /// 短了就慢放，别把「素材不够长」留给人发愁）
  void _slowFill(int index) {
    final line = _doc.lines[index];
    final root = ShotAllocation.rootMsOf(line);
    if (root == null) return;
    final filled = ShotAllocation.fillBySlowdown(line.shots, root);
    if (identical(filled, line.shots)) return;
    _updateShots(index, filled);
    final left = ShotAllocation.shortfallMs(filled, root);
    if (left > 0) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('放慢到 0.5x 还差 ${(left / 1000).toStringAsFixed(1)} 秒'
              '——这条素材实在太短，换一条或再加一镜吧。')));
    }
  }

  /// 上次弹「到底线」提示的时刻：拖拽每帧都会触发失败，提示要节流
  /// ——不然一次拖拽攒下一队列 SnackBar，松手后还在连环弹（真机反馈）
  DateTime _lastResizeHint = DateTime.fromMillisecondsSinceEpoch(0);

  void _resizeShot(int index, int j, int newAllocMs) {
    final line = _doc.lines[index];
    final next = ShotAllocation.resize(line.shots, j, newAllocMs);
    if (next == null) {
      final now = DateTime.now();
      if (now.difference(_lastResizeHint) > const Duration(seconds: 3)) {
        _lastResizeHint = now;
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(const SnackBar(
              duration: Duration(seconds: 2),
              content: Text('调不动了：相邻镜头已经到底线（每镜最少 0.5 秒）。')));
      }
      return;
    }
    _updateShots(index, next);
  }

  void _trimShot(int index, int j, int trimStartMs) {
    final line = _doc.lines[index];
    final next = [...line.shots];
    next[j] = ShotAllocation.setTrimStart(next[j], trimStartMs);
    _updateShots(index, next);
  }

  void _speedShot(int index, int j, double speed) {
    final line = _doc.lines[index];
    final next = [...line.shots];
    next[j] = ShotAllocation.setSpeed(next[j], speed);
    _updateShots(index, next);
  }

  // ---- 参考段（这一句在参考片里的原始画面）----

  /// 这一行的参考视频路径。取法在 [ScriptDoc.refVideoOf] 里只有一份——
  /// 界面和 CLI 各写各的时候，CLI 那三处全漏了回落
  String? _refVideoOf(ScriptLine line) => _doc.refVideoOf(line);

  /// 参考分镜缩略图：取该镜中点帧（两端常踩转场），按 (行,镜) 缓存
  void _ensureRefThumb(ScriptLine line, int segIndex) {
    final ref = line.reference;
    final video = _refVideoOf(line);
    final dataDir = this.ref.read(dataDirProvider);
    if (ref == null || video == null || dataDir == null) return;
    final segments = ref.segments;
    if (segIndex < 0 || segIndex >= segments.length) return;
    final key = '${line.id}_$segIndex';
    if (_refThumbs.containsKey(key) ||
        _refThumbsRendering.contains(key) ||
        _refThumbFailed.contains(key)) {
      return;
    }
    final out = p.join(dataDir.path, 'script_refs', _task.id, '$key.jpg');
    if (File(out).existsSync()) {
      _refThumbs[key] = out;
      return;
    }
    _refThumbsRendering.add(key);
    final seg = segments[segIndex];
    unawaited(() async {
      try {
        await Directory(p.dirname(out)).create(recursive: true);
        final mid = (seg.$1 + seg.$2) / 2000;
        final r = await const ResolvingProcessRunner().call('ffmpeg', [
          '-y', '-v', 'error',
          '-ss', mid.toStringAsFixed(3),
          '-i', video,
          '-frames:v', '1',
          '-vf', 'scale=-2:240',
          out,
        ]);
        if (r.exitCode == 0 && mounted) {
          setState(() => _refThumbs[key] = out);
        } else {
          _refThumbFailed.add(key);
        }
      } catch (e) {
        _refThumbFailed.add(key);
        AppLog.warn('参考缩略图抽帧失败（$key）：$e');
      } finally {
        _refThumbsRendering.remove(key);
      }
    }());
  }

  // ---- 原位播放（卡片就地播，不弹窗）----

  /// 共享的原位播放器：同时只有一张卡在播，谁在播就挂到谁的卡上
  MediaKitPlaybackController? _inlinePlayer;

  /// 原位播放的配音伴奏（独立实例同步播配音段——外挂音轨那条 API
  /// 在 macOS 上不工作，主预览的口播轨也是独立实例，照抄已验证模式）
  MediaKitPlaybackController? _inlineAudio;
  Widget? _inlineVideo;

  /// 正在原位播放的卡：'ref_行id' 或 'shot_行id_镜下标'；null = 没在播
  String? _inlineKey;
  StreamSubscription<bool>? _inlineLoop;

  /// 原位播放的位置（素材坐标）——卡上叠的字幕跟着它换屏。
  /// 用 ValueNotifier：只重建那一块字，不带着整块板子每秒刷几次
  final ValueNotifier<int> _inlinePositionMs = ValueNotifier<int>(0);
  StreamSubscription<int>? _inlinePosSub;

  /// 原位播放一段：再点同一张卡 = 停。开播前停掉其他一切声源
  /// （主预览、配音试听）——同时只有一个东西在响。
  /// [audioPath] 非空时用独立实例同步播配音的 [audioStartMs, audioEndMs)
  /// 段（分镜素材多为无声，成片里这一镜配的就是这段配音）
  Future<void> _playInline(
      String key, String path, int startMs, int endMs,
      {double rate = 1.0,
      String? audioPath,
      int audioStartMs = 0,
      int audioEndMs = 0,

      /// 素材原声在这一镜该出多大（0 = 不出）。**卡上播的必须和成片一致**
      /// ——调了原声音量却只有主预览变、卡上还是满音量，人会以为没生效
      double sourceVolume = 1.0}) async {
    if (_inlineKey == key) {
      _stopInline();
      return;
    }
    if (!File(path).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('这段视频已不在本地，回来后才能播放。')));
      return;
    }
    await _stopAllPlayback(exceptInline: true);
    await _inlineLoop?.cancel();
    _inlineLoop = null;
    final player = _inlinePlayer ??= MediaKitPlaybackController();
    _inlineVideo ??= player.buildVideoWidget();
    setState(() => _inlineKey = key);
    await _inlinePosSub?.cancel();
    _inlinePosSub =
        player.positionMsStream.listen((ms) => _inlinePositionMs.value = ms);
    await player.open(path);
    await player.waitUntilLoaded();
    if (!mounted || _inlineKey != key) return;
    await player.setVolume(sourceVolume);
    await player.player.setRate(rate);
    final withVoice =
        audioPath != null && File(audioPath).existsSync() && audioEndMs > 0;
    if (withVoice) {
      final audio = _inlineAudio ??= MediaKitPlaybackController();
      await audio.open(audioPath);
      await audio.waitUntilLoaded();
      if (!mounted || _inlineKey != key) return;
      await audio.setMuted(false);
    }
    Future<void> playSeg() async {
      // 画面与配音各自 playRange，同时起跑（几十毫秒内的相差
      // 预览无感；主预览的多轨同样是双实例同步）
      if (withVoice) {
        unawaited(_inlineAudio!.playRange(audioStartMs, audioEndMs, 30));
      }
      final ok = await player.playRange(startMs, endMs, 30);
      if (!ok) {
        await player.seekMs(startMs);
        await player.play();
      }
    }

    await playSeg();
    // 播一次就停（用户定的：不要循环）——段尾自然停住后清态，
    // 按钮从 ⏹ 复位回 ▶。**只认段尾**：中途因落盘/重建产生的瞬时
    // 暂停不该把播放判成结束
    _inlineLoop = player.playingStream.listen((playing) {
      if (playing || !mounted || _inlineKey != key) return;
      if (player.positionMs >= endMs - 250) _stopInline();
    });
  }

  /// 重播某一镜（取段/时长刚调完，听调整后的效果）——
  /// 与点 ▶ 的 toggle 不同，这里无论在不在播都重新来一遍
  Future<void> _replayShotInline(int index, int j) async {
    _stopInline();
    await _playShotInline(index, j);
  }

  /// 取段调整后的重播防抖。
  ///
  /// **松手先别播**：立刻播放的是改动落定前的旧区间，紧接着落盘与
  /// 预览重建又把它打断——「播一下就停」的顿挫（真机反馈）。
  /// 这里等改动落定（预览重建防抖 600ms + 余量）再播一次新区间；
  /// 期间继续拖就重新计时，只在最后一次调整后播一遍
  Timer? _replayDebounce;

  void _scheduleReplayShot(int index, int j) {
    _replayDebounce?.cancel();
    _stopInline();
    _replayDebounce = Timer(const Duration(milliseconds: 780), () {
      if (!mounted) return;
      unawaited(_replayShotInline(index, j));
    });
  }

  void _stopInline() {
    unawaited(_inlineLoop?.cancel());
    _inlineLoop = null;
    unawaited(_inlinePosSub?.cancel());
    _inlinePosSub = null;
    unawaited(_inlinePlayer?.pause());
    unawaited(_inlineAudio?.pause());
    if (mounted && _inlineKey != null) setState(() => _inlineKey = null);
  }

  /// 停掉一切声源（互斥的地基）：任何播放动作开始前先调它——
  /// 分镜在播时点主预览、点配音试听，前面的必须停
  Future<void> _stopAllPlayback({bool exceptInline = false}) async {
    await _playback?.pause();
    await _voicePreview.stop();
    if (_playingLineId != null && mounted) {
      setState(() => _playingLineId = null);
    }
    if (!exceptInline) _stopInline();
  }

  /// 播放参考：**原位**循环播（在参考卡自己的位置上，不弹窗）。
  /// [segIndex] >=0 播该参考分镜（原子）区间，传负数播整段（分子）
  Future<void> _playReference(int index, int segIndex) async {
    final line = _doc.lines[index];
    final ref = line.reference;
    final video = _refVideoOf(line);
    if (ref == null || video == null) return;
    final segments = ref.segments;
    final (startMs, endMs) = segIndex >= 0 && segIndex < segments.length
        ? segments[segIndex]
        : (ref.startMs, ref.endMs);
    await _playInline('ref_${line.id}', video, startMs, endMs);
  }

  /// 原位播放一个镜头——**成片里这一镜的样子**：画面（变速镜头优先用
  /// 渲好的对齐切片）+ 这一句配音的对应段（外挂对齐；分镜素材本身
  /// 多是无声的）。没配音的行退回素材原声按倍率播
  Future<void> _playShotInline(int index, int j) async {
    final line = _doc.lines[index];
    if (j < 0 || j >= line.shots.length) return;
    final shot = line.shots[j];
    final src =
        shot.localSource ?? _mediaCache?.localPathOf(shot.materialId);
    if (src == null) {
      // **说清还差几条**：只说「还没下载好」，人不知道是差一条还是差四十条，
      // 也不知道该等三秒还是三分钟
      final left = _mediaCache?.notReady.length ?? 0;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(left > 1
              ? '这一镜的素材还在下（一共还差 $left 条），下好就能播。'
              : '这一镜的素材还在下，马上就好。')));
      return;
    }
    // 该镜在行时间轴上的起点 = 前面镜头的 alloc 累计（配音同轴）
    var segStartMs = 0;
    for (var i = 0; i < j; i++) {
      segStartMs += line.shots[i].allocMs ?? 0;
    }
    final vo = line.voiceover;
    final alloc = shot.allocMs ?? shot.durationMs ?? 3000;
    // 变速镜头优先播渲好的对齐切片（时长 = alloc、配音同速）；
    // 切片还没渲好就退素材原速近似
    final clip = shot.speed != 1.0 ? _speedClips[_clipKey(shot)] : null;
    final String path;
    final int start;
    final int end;
    double rate = 1.0;
    if (clip != null) {
      path = clip;
      start = 0;
      end = alloc;
    } else {
      path = src;
      start = shot.trimStartMs;
      end = start +
          (shot.consumedSourceMs > 0
              ? shot.consumedSourceMs
              : (shot.durationMs ?? 3000));
      // **画面永远按这一镜自己的倍速播**：0.5x 就慢放，1.25 秒素材
      // 正好铺满 2.5 秒——与配音天然对齐，不需要任何补偿
      rate = shot.speed;
    }
    await _playInline('shot_${line.id}_$j', path, start, end,
        rate: rate,
        // 与排轨同一套规则：配音行跟随全片（默认静音），
        // 画面行本来就靠素材出声（除非这一镜单独压过）
        sourceVolume: _doc.sourceVolumeFor(line, shot),
        audioPath: vo?.audioPath,
        // 配音段 = 该镜在行时间轴上的区间（配音与行同轴）
        audioStartMs: segStartMs,
        audioEndMs: segStartMs + alloc);
  }

  /// 参考分镜一键作镜头：原片本地文件直接当镜头用
  void _useReference(int index, int segIndex) {
    final line = _doc.lines[index];
    final ref = line.reference;
    final video = _refVideoOf(line);
    if (ref == null || video == null) return;
    final segments = ref.segments;
    if (segIndex < 0 || segIndex >= segments.length) return;
    final seg = segments[segIndex];
    if (line.shots
        .any((s) => s.localSource == video && s.trimStartMs == seg.$1)) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('这段参考画面已经在这一行的镜头里了。')));
      return;
    }
    final shot = LineShot(
      // 负数占位：本地源不参与下载与防撞车，行内按区间起点保证唯一
      materialId: -(seg.$1 + 1),
      name: '参考画面',
      sceneDescription: '参考片 ${(seg.$1 / 1000).toStringAsFixed(1)}s'
          '~${(seg.$2 / 1000).toStringAsFixed(1)}s',
      durationMs: seg.$2 - seg.$1,
      localSource: video,
      trimStartMs: seg.$1,
    );
    final next = [...line.shots, shot];
    _updateShots(index, reallocShots(line, next));
    _flushNow();
  }

  /// 给某一行上传参考视频（手写的行也能对照参考配镜）。
  /// 整段视频作为该行的参考区间；时长用 ffprobe 实探，不猜
  /// 给这一句传参考：**视频或图片都行，只能有一个**（再传就是替换）。
  ///
  /// 视频：≤15 秒（一个台词语义单元本来就不该更长），传完把它当这一句的
  /// 参考做该做的事——跑 ASR（**只用于展示**这段说了什么，不回填脚本、
  /// 不参与检索）+ 视觉切分（切成 N 个视觉镜头，供添加分镜时按画面找）。
  /// 图片：它天然就是「首帧」，只给视觉镜头层当查询帧
  Future<void> _uploadReference(int index) async {
    final line = _doc.lines[index];
    final path = await ref.read(refFilePickerProvider)();
    if (path == null || !mounted) return;
    if (line.reference != null) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('换掉这一句的参考？'),
          content: const Text('旧参考的切分与画面标注会一起作废；'
              '已经用参考画面做成的镜头保留不动。'),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('算了')),
            FilledButton(
                key: const ValueKey('ref-replace-ok'),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('换')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    final isImage = const ['.jpg', '.jpeg', '.png', '.webp']
        .any((e) => path.toLowerCase().endsWith(e));
    if (isImage) {
      // 参考图：没有时长与台词，用一个象征性的区间占位
      _mutate((d) => d.setReferenceById(
          line.id, LineRef(startMs: 0, endMs: 1, imagePath: path)));
      _flushNow();
      return;
    }
    int durationMs;
    try {
      final r = await const ResolvingProcessRunner().call('ffprobe', [
        '-v', 'quiet', '-show_entries', 'format=duration', '-of', 'csv=p=0',
        path,
      ]);
      final seconds = double.tryParse('${r.stdout}'.trim());
      if (seconds == null || seconds <= 0) {
        throw StateError('时长读不出来');
      }
      durationMs = (seconds * 1000).round();
    } catch (e) {
      AppLog.warn('参考视频探测失败（$path）：$e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('读不出这条视频的时长，确认它是完整的视频文件。')));
      }
      return;
    }
    if (durationMs > _maxRefMs) {
      // 不静默截断——截了用户会以为软件吃了他的东西
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('这段有 ${(durationMs / 1000).toStringAsFixed(1)} 秒，'
                '一个台词语义单元的参考不该超过 ${_maxRefMs ~/ 1000} 秒——'
                '裁一下再传。')));
      }
      return;
    }
    _mutate((d) => d.setReferenceById(
        line.id, LineRef(startMs: 0, endMs: durationMs, videoPath: path)));
    _flushNow();
    // 后台把该做的事做掉：ASR（只展示）+ 视觉切分（供按画面找镜头）
    unawaited(_prepareUploadedRef(line.id));
  }

  /// 手动传的参考视频上限：一个台词语义单元本来就不该超过 15 秒
  static const int _maxRefMs = 15000;

  /// 手动传的参考视频跑一遍它该做的事：ASR（展示用）+ 视觉切分
  Future<void> _prepareUploadedRef(String lineId) async {
    await _ensureRefCuts(lineId);
    if (!mounted) return;
    final line = _doc.lines.where((l) => l.id == lineId).firstOrNull;
    final ref0 = line?.reference;
    final video = line == null ? null : _refVideoOf(line);
    final transcriber = ref.read(scriptTranscriberProvider);
    if (line == null || ref0 == null || video == null || transcriber == null) {
      return;
    }
    if (ref0.words.isNotEmpty) return;
    try {
      final sentences = await transcriber.transcribeOnly(video);
      if (!mounted) return;
      final words = [
        for (final s in sentences)
          for (final w in s.words)
            VoiceWord(text: w.text, startMs: w.startMs, endMs: w.endMs),
      ];
      if (words.isEmpty) return;
      final cur = _doc.lines.where((l) => l.id == lineId).firstOrNull?.reference;
      if (cur == null) return;
      _mutate((d) => d.setReferenceById(lineId, cur.withWords(words)));
    } catch (e) {
      AppLog.warn('参考视频 ASR 失败（只影响展示，$lineId）：$e');
    }
  }

  Future<void> _togglePlayVoice(int index) async {
    final line = _doc.lines[index];
    final vo = line.voiceover;
    if (vo == null) return;
    if (_playingLineId == line.id) {
      setState(() => _playingLineId = null);
      await _voicePreview.stop();
      return;
    }
    // 试听开始前停掉分镜卡/主预览——同时只有一个东西在响
    _stopInline();
    await _playback?.pause();
    setState(() => _playingLineId = line.id);
    await _voicePreview.play(vo.audioPath);
    // 简单起见按时长收尾：播完把按钮复位（期间切行/重播由上面的分支处理）
    Future.delayed(Duration(milliseconds: vo.durationMs + 200), () {
      if (mounted && _playingLineId == line.id) {
        setState(() => _playingLineId = null);
      }
    });
  }

  /// 撤销/重做栈：ScriptDoc 不可变，存引用零拷贝。上限防内存无限涨
  final List<ScriptDoc> _undoStack = [];
  final List<ScriptDoc> _redoStack = [];
  static const _undoLimit = 100;

  /// 改动随手落库（800ms 防抖）——写作软件没有「保存」这回事。
  /// 每次改动前把旧文档压进撤销栈（新改动作废重做栈）
  /// 改一次文档。
  ///
  /// [affectsTracks] 说的是这次改动**影不影响预览的轨道结构**。
  /// 默认 true（保守），但语速、标签、字幕文字与样式这些**跟轨道无关**的
  /// 改动必须显式传 false——正在播放时重建轨道会扰动播放位置与跟随轨，
  /// 听感就是声音忽大忽小、严重时卡住反复念同几个字（真机反馈）。
  /// 字幕是画在预览层上的 widget，`setState` 就够，不必动轨道。
  void _mutate(ScriptDoc Function(ScriptDoc) f, {bool affectsTracks = true}) {
    // Agent 干活时人改不动：两边同时写会把彼此的活覆盖掉，而且只有软件
    // 看得见两个写入方（spec 第六节）。**所有数据改动都从这里过**，
    // 拦这一处胜过给几十个控件各包一层只读
    final agent = _agent;
    if (agent != null) {
      _toast('${agent.holder} 正在操作这个任务——要自己改，先点上面的「我来接手」。');
      return;
    }
    // 人正在改东西：自动展开这一轮让开。不让的话，他改着第 3 行，
    // 播放头走到第 5 行就把他手上那一栏收起来了
    if (_previewPlaying) _autoExpandPaused = true;
    _undoStack.add(_doc);
    if (_undoStack.length > _undoLimit) _undoStack.removeAt(0);
    _redoStack.clear();
    setState(() {
      _doc = f(_doc);
      _saving = true;
    });
    _autosave?.cancel();
    _autosave = Timer(const Duration(milliseconds: 800), _flushNow);
    if (affectsTracks) _schedulePreviewRebuild();
  }

  void _undo() {
    if (_undoStack.isEmpty) return;
    _redoStack.add(_doc);
    setState(() => _doc = _undoStack.removeLast());
    _flushNow();
    _schedulePreviewRebuild();
  }

  void _redo() {
    if (_redoStack.isEmpty) return;
    _undoStack.add(_doc);
    setState(() => _doc = _redoStack.removeLast());
    _flushNow();
    _schedulePreviewRebuild();
  }

  void _flushNow() {
    _autosave?.cancel();
    // **Agent 在场时一个字都不许写**。
    //
    // 这一页写盘写的是内存里的整份 doc。Agent 可视模式下界面刚被唤醒
    // 打开，内存里是**打开那一刻**的旧数据；Agent 随后写了盘，界面这边
    // 任何一次自动保存都会把旧的整份盖回去——CLI 报 ok:true、盘上没变，
    // 人以为写好了继续往下走（验收 Agent 实测到的第二个问题，
    // 而且它比「报失败」更危险：那个会重试，这个会带着错往前走）。
    //
    // 这时人本来也改不动（_mutate 拦着），所以没有要保存的东西
    // **写之前先看一眼盘上被别人动过没有**。
    //
    // 这一页写盘写的是内存里的整份 doc。Agent 在外面也在写同一个文件，
    // 谁后写谁赢——真机连着两轮栽在这儿：先是 Agent 刚写的被界面盖掉
    // （CLI 报 ok、盘上没变），后来更狠，**已经落盘很久的一句台词被
    // 回滚没了**，而 CLI 全程 ok:true。
    //
    // 上一版靠「Agent 在场时不写」挡，但「在场」是 500ms 轮询出来的，
    // 那个窗口里界面照写不误。改成按内容判定，不依赖任何时序
    // 用缓存的 dataDir 而不是 ref.read——**dispose 里也会调这个方法**，
    // 那时候 ref 已经不能用了，一读就抛，而异常会打断 dispose 后面的
    // timer 取消，留下一堆跑着的定时器（测试当场抓到）
    final dataDir = _dataDir;
    if (dataDir != null && !canOverwrite(dataDir, _task.id, _docPrint)) {
      AppLog.info('盘上这份任务被外面改过，这次不覆盖（${_task.id}）');
      // **这里不能去重读**：dispose 里也会调 flush，那时再拉起重建预览
      // 就会在树都拆了之后新起一个 Timer。重读交给 _watchAgent 的轮询，
      // 它自己会发现指纹变了
      return;
    }
    _task = _task.copyWith(script: _doc, updatedAt: DateTime.now());
    unawaited(_repo.save(_task).then((_) {
      // 写完把基线对齐到刚写出去的那一版，否则下一次会误判成「被人动过」
      final d = _dataDir;
      if (d != null) _docPrint = taskFingerprint(d, _task.id);
      if (mounted) setState(() => _saving = false);
      // 顺手把封面对上：脚本任务的封面是成片第一帧（第一行第一镜）。
      // 没有它，列表页上一条排好的片子和一个空任务长得一模一样
      unawaited(_refreshCover());
    }).catchError((Object e) {
      AppLog.warn('脚本落库失败（taskId=${_task.id}）：$e');
    }));
  }

  /// 更新封面。按内容指纹缓存，第一镜没换就不重抽。
  ///
  /// **销毁后不许再碰 ref**：dispose 里会落一次盘，那时页面已经没了，
  /// 再去读 provider 会抛 StateError
  Future<void> _refreshCover() async {
    if (!mounted) return;
    final dataDir = ref.read(dataDirProvider);
    if (dataDir == null) return;
    final cover = await ensureScriptCover(
      doc: _doc,
      dataDir: dataDir,
      taskId: _task.id,
      localPathOf: (id) => _mediaCache?.localPathOf(id),
    );
    if (cover == null || cover == _task.coverPath || !mounted) return;
    _task = _task.copyWith(coverPath: cover);
    unawaited(_repo.save(_task));
  }

  bool get _scriptIsPristine =>
      _doc.lines.length == 1 && _doc.lines.single.text.trim().isEmpty;

  /// 「从视频提取脚本」全流程：选文件 → （非空时确认覆盖）→ 三步提取 →
  /// 覆盖填充。失败给原因和重试，不静默。
  Future<void> _extractFromVideo() async {
    final transcriber = ref.read(scriptTranscriberProvider);
    if (transcriber == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('尚未配置 AI 服务（语音识别与语义分行），无法从视频提取脚本。')));
      return;
    }
    if (!_scriptIsPristine) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('用提取结果替换当前脚本？'),
          content: Text(
              '当前脚本已有 ${_doc.lines.length} 行，提取出的台词会整体替换它们，'
              '此操作无法撤销。'),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('替换')),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    if (!mounted) return;
    final path = await ref.read(videoFilePickerProvider)();
    if (path == null || !mounted) return;

    setState(() =>
        _extract = const _ExtractRunning(ScriptTranscribeStage.extractingAudio));
    try {
      final lines = await transcriber.extract(path, onStage: (stage) {
        if (mounted) setState(() => _extract = _ExtractRunning(stage));
      });
      if (!mounted) return;
      setState(() {
        // 来源视频跟文档走：行上的 reference 区间都指向它（参考视频列）
        _doc = ScriptDoc(lines,
            subtitle: _doc.subtitle,
            bgmSegments: _doc.bgmSegments,
            refVideoPath: path);
        _selected = 0;
        _extract = null;
        _guideDismissed = true;
      });
      _flushNow();
      unawaited(_offerDraftAfterExtract());
    } on ScriptTranscribeException catch (e) {
      AppLog.warn('脚本提取失败（$path）：${e.cause ?? e.message}');
      if (mounted) setState(() => _extract = _ExtractFailed(e.message));
    } catch (e) {
      AppLog.warn('脚本提取失败（$path）：$e');
      if (mounted) {
        setState(() =>
            _extract = const _ExtractFailed('提取失败，请稍后重试。'));
      }
    }
  }

  /// 提取完成后追问一次「自动铺一版」：打标 → 配音 → 照着参考片配镜 →
  /// 直接开播。一次确认把费用说清，之后人只做否决和替换——这是产品的北极星
  Future<void> _offerDraftAfterExtract() async {
    if (!mounted) return;
    // **Agent 正在干这条任务时不插嘴。**
    //
    // 「自动铺一版」是给人自己用的：一次确认，软件把空位全填满，人只做
    // 否决和替换。而 Agent 那条路的形状正相反——软件把候选连同画面一起
    // 给它，**由它看图判断该用哪一镜**，再提交回来。
    //
    // 两条路混在一起，人看到的就是：Codex 明明停了，界面还在一句句地铺；
    // 按「我来接手」也停不下来。用户的原话：「这说明找镜头这个动作根本
    // 不是 Agent 在做——是它敲了一条命令，然后软件自己在跑。」
    if (_agent != null) return;
    final tagger = ref.read(lineTaggerProvider);
    final voiceFactory = ref.read(lineVoiceFactoryProvider);
    final voiced = [
      for (final l in _doc.lines)
        if (l.type == ScriptLineType.voiced) l.id,
    ];
    if (voiced.isEmpty) return;
    // 花钱的事按**分镜**算：一句里 9 个分镜就是 9 次识图，按句报会少报一截
    var extractSegCount = 0;
    for (final id in voiced) {
      final l = _doc.lines.where((x) => x.id == id).firstOrNull;
      extractSegCount += l?.reference?.segments.length ?? 1;
    }
    final canTag = tagger != null && _task.unitTagGroups.isNotEmpty;
    final canVoice = voiceFactory != null;
    final defaultVoice = VoiceCatalog.all.first.ref.name;
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('自动铺一版？'),
        content: Text([
          '脚本已经就位（${voiced.length} 句）。接下来照着参考片自动铺：',
          if (canTag) '· 给每句打上标签（${voiced.length} 次 AI 调用）',
          if (canVoice)
            '· 用「$defaultVoice」配上声音（${voiced.length} 次语音合成，之后每句可换）',
          '· 看懂参考片的每一镜，去妙啊找像的画面——'
              '参考里这一句有几个分镜就铺几个，时长按参考的比例切'
              '（一共 $extractSegCount 个分镜，同样次数的 AI 识图）',
          '铺完直接播出来，不满意的随手换。',
        ].join('\n')),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('我自己一句句来')),
          FilledButton(
              key: const ValueKey('draft-after-extract'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('铺一版')),
        ],
      ),
    );
    if (go != true || !mounted) return;
    // 阶段〇：给每句打话术标签（有词表才打；失败不挡路——镜头那步靠的是
    // 参考镜的画面描述，与这里的话术标签是两回事）
    if (canTag) {
      for (var i = 0; i < voiced.length; i++) {
        if (!mounted) return;
        final line = _doc.lines.where((l) => l.id == voiced[i]).firstOrNull;
        if (line == null) continue;
        setState(() =>
            _draftProgress = ('打标', line.text.trim(), i, voiced.length));
        try {
          final tags = await tagger.tag(
            text: line.text,
            groups: _task.unitTagGroups,
            constraint: _task.unitTagPrompt,
          );
          if (!mounted) return;
          if (tags.isNotEmpty) {
            _mutate((d) => d.setTagsById(line.id, tags),
                affectsTracks: false);
          }
        } catch (e) {
          AppLog.warn('话术打标失败（第 ${i + 1} 句）：$e');
        }
      }
    }
    final needVoice = canVoice
        ? [
            for (final l in _doc.lines)
              if (l.type == ScriptLineType.voiced &&
                  l.voiceState != LineVoiceState.fresh)
                l.id,
          ]
        : <String>[];
    // 只给**有参考镜可依据**的行配镜：手写脚本没有参考片，就不去瞎捞
    // （用户定的：手写的自己上传参考，或者直接去找镜头面板搜）
    final needShots = [
      for (final l in _doc.lines)
        if (l.shots.isEmpty &&
            l.type == ScriptLineType.voiced &&
            (l.reference?.segments.isNotEmpty ?? false))
          l.id,
    ];
    await _runDraftPipeline(
        needVoice: needVoice,
        needShots: needShots,
        defaultVoice: VoiceCatalog.all.first.ref.id);
  }

  // ---- 草片流水线（北极星：人是来看片子诞生的，不是来操作块的）----

  /// 「自动铺一版」：把还没做的补齐——没配音的配上音，没镜头的**照着
  /// 参考片这一镜的画面**去找像的，铺完直接开播。
  ///
  /// 「铺」对应的心智是把整片的空位填满、然后逐句替换；「一版」是说它
  /// 可以改，不是终稿。花钱的事先说清再动手
  Future<void> _generateDraft() async {
    if (_draftProgress != null) return;
    final voiceFactory = ref.read(lineVoiceFactoryProvider);
    final needVoice = [
      for (final l in _doc.lines)
        if (l.type == ScriptLineType.voiced &&
            l.voiceState != LineVoiceState.fresh)
          l.id,
    ];
    // 只铺**有参考镜可依据**的行（手写脚本没有参考片，不去瞎捞）
    final needShots = [
      for (final l in _doc.lines)
        if (l.shots.isEmpty &&
            l.type == ScriptLineType.voiced &&
            (l.reference?.segments.isNotEmpty ?? false))
          l.id,
    ];
    // 还空着、但没有参考可依据的行：说清楚它们为什么没被铺上
    final noRef = [
      for (final l in _doc.lines)
        if (l.shots.isEmpty &&
            l.type == ScriptLineType.voiced &&
            (l.reference?.segments.isEmpty ?? true))
          l.id,
    ];
    if (needVoice.isEmpty && needShots.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(noRef.isEmpty
              ? '每一句都铺好了，直接按播放看。'
              : '配音都好了。还有 ${noRef.length} 句没有镜头——'
                  '它们没有参考片可依据，去右栏「找镜头」挑，'
                  '或者先上传一段参考视频。')));
      return;
    }
    if (needVoice.isNotEmpty && voiceFactory == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('尚未配置 AI 服务（语音合成），铺不了。')));
      return;
    }
    // 本片音色还没定过就**先卡住让人选**：拿目录里第一个撞运气去配 27 句，
    // 不对就白烧一轮 TTS（真机上就是这么浪费掉的）
    if (_doc.defaultVoiceId == null && needVoice.isNotEmpty) {
      final picked = await showVoiceSelectDialog(context,
          selected: VoiceCatalog.all.first.ref.id, allowApplyAll: false);
      if (picked == null || !mounted) return;
      _mutate((d) => d.withDefaultVoiceId(picked.$1));
    }
    // **费用要按分镜算，不是按句算**：一句里有 9 个分镜就是 9 次检索、
    // 最多 9 次识图。按句报的话人以为花 5 块，实际花 30——花钱的事先说清
    var draftSegCount = 0;
    var draftUntagged = 0;
    for (final id in needShots) {
      final l = _doc.lines.where((x) => x.id == id).firstOrNull;
      final segs = l?.reference?.segments ?? const <(int, int)>[];
      draftSegCount += segs.length;
      for (final (from, _) in segs) {
        final m = l!.reference!.metaAt(from);
        if (m == null || m.description.trim().isEmpty) draftUntagged++;
      }
    }
    // 批量时绝不弹 27 次选择器：全片一个基调，逐句要改在行内改
    final defaultVoice = _doc.defaultVoiceId ?? VoiceCatalog.all.first.ref.id;
    final defaultVoiceName =
        VoiceCatalog.byId(defaultVoice)?.ref.name ?? defaultVoice;
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('自动铺一版？'),
        content: Text([
          if (needVoice.isNotEmpty)
            '· 给 ${needVoice.length} 句配上「$defaultVoiceName」的声音'
                '（${needVoice.length} 次语音合成，每句之后可单独换）',
          if (needShots.isNotEmpty)
            '· 照着参考片的画面，给 ${needShots.length} 句铺上镜头——'
                '参考里这一句有几个分镜就铺几个，时长按参考的比例切'
                '（一共 $draftSegCount 个分镜；没打过标的要先看懂，'
                '$draftUntagged 次 AI 识图）',
          if (noRef.isNotEmpty)
            '· 另有 ${noRef.length} 句没有参考片可依据，这次不铺镜头——'
                '去右栏「找镜头」挑，或先上传一段参考视频',
          '铺完直接播出来，不满意的随手换。',
        ].join('\n')),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('先不用')),
          FilledButton(
              key: const ValueKey('draft-confirm'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('铺一版')),
        ],
      ),
    );
    if (go != true || !mounted) return;
    await _runDraftPipeline(
        needVoice: needVoice, needShots: needShots, defaultVoice: defaultVoice);
  }

  /// 补上逐字时间：早期生成的配音只有整段音频、没有每个字的时间戳，
  /// 字幕就只能按字数把时间摊开，也没法手工分屏与打轴。这里把全片
  /// 缺时间的行**重配一次音**（同音色同台词，声音听不出差别）。
  ///
  /// 会花钱、会让行时长有毫秒级变化（镜头分配跟着重算），所以先说清
  /// 再动手；跑的时候顶栏有进度，失败的行会点名
  Future<void> _fixMissingWordTimings() async {
    if (_draftProgress != null) return;
    final need = [
      for (final l in _doc.lines)
        if (l.type == ScriptLineType.voiced &&
            l.voiceover != null &&
            l.voiceover!.words.isEmpty)
          l.id,
    ];
    if (need.isEmpty) {
      _toast('每一句都已经有逐字时间了。');
      return;
    }
    if (ref.read(lineVoiceFactoryProvider) == null) {
      _toast('尚未配置 AI 服务（语音合成），补不了逐字时间。');
      return;
    }
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('补上逐字时间？'),
        content: Text([
          '有 ${need.length} 句配音是早期生成的，没带每个字的时间戳，',
          '所以字幕只能按字数摊时间，也改不了切点。',
          '',
          '· 这 ${need.length} 句会用原来的音色和台词重配一次'
              '（${need.length} 次语音合成），声音听不出差别',
          '· 行的时长可能有毫秒级变化，镜头分配会跟着重算',
          '· 补完就能手工分屏、按播放位置打轴',
        ].join('\n')),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('先不用')),
          FilledButton(
              key: const ValueKey('fix-timing-confirm'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('补上')),
        ],
      ),
    );
    if (go != true || !mounted) return;
    final failed = <String>[];
    for (var i = 0; i < need.length; i++) {
      if (!mounted) return;
      final line = _doc.lines.where((l) => l.id == need[i]).firstOrNull;
      if (line == null) continue; // 期间被删了
      setState(() =>
          _draftProgress = ('补逐字时间', line.text.trim(), i, need.length));
      final voiceId = line.voiceId ??
          _doc.lines
              .lastWhere((l) => l.voiceId != null, orElse: () => line)
              .voiceId;
      if (voiceId == null) {
        failed.add(line.text.trim());
        continue;
      }
      final ok = await _generateVoiceCore(line.id, voiceId);
      // 重配了还是没有逐字时间（老服务端/长句）——也算没补上，别装成功
      final after = _doc.lines.where((l) => l.id == line.id).firstOrNull;
      if (!ok || (after?.voiceover?.words.isEmpty ?? true)) {
        failed.add(line.text.trim());
      }
    }
    if (!mounted) return;
    setState(() => _draftProgress = null);
    _flushNow();
    _schedulePreviewRebuild();
    if (failed.isEmpty) {
      _toast('${need.length} 句都补上了逐字时间，现在可以手工分屏与打轴。');
    } else {
      // 不静默：补不上的点名，剩下的照常可用
      _toast('${need.length - failed.length} 句补好了；'
          '${failed.length} 句没补上（${failed.first}…），可以单独重新生成配音。');
    }
  }

  void setStateProgress(String step, String what, int i, int total) =>
      _draftProgress = (step, what, i, total);

  /// 自动铺片被叫停了。
  ///
  /// 它一次要跑几十句配音加几十次识图，十几分钟起步——**跑起来却没有任何
  /// 停下来的办法**（真机上人按「我来接手」也停不掉，只能看着它把钱烧完）。
  bool _draftCancelled = false;

  /// 叫停自动铺片。已经铺好的那几句留着，没轮到的不动
  void _cancelDraft() {
    if (_draftProgress == null) return;
    _draftCancelled = true;
    _toast('正在停下来——这一句做完就收手，已经铺好的都留着。');
  }

  Future<void> _runDraftPipeline({
    required List<String> needVoice,
    required List<String> needShots,
    required String defaultVoice,
  }) async {
    _draftCancelled = false;
    var voiceFailed = 0;
    var shotFailed = 0;
    // 一、配音
    for (var i = 0; i < needVoice.length; i++) {
      if (!mounted || _draftCancelled) break;
      final line = _doc.lines.where((l) => l.id == needVoice[i]).firstOrNull;
      if (line == null) continue; // 生成期间被删了
      setState(() =>
          setStateProgress('配音', line.text.trim(), i, needVoice.length));
      if (line.voiceId == null) {
        _mutate((d) => d.setVoiceId(
            _doc.lines.indexWhere((l) => l.id == line.id), defaultVoice));
      }
      final ok = await _generateVoiceCore(
          line.id, _doc.lines.firstWhere((l) => l.id == line.id).voiceId!);
      if (!ok) voiceFailed++;
    }
    // 二、配镜：照着参考片这一镜的画面去找像的
    final tagIds =
        needShots.isEmpty ? const <String, int>{} : await _loadTagIds();
    for (var i = 0; i < needShots.length; i++) {
      if (!mounted || _draftCancelled) break;
      final line = _doc.lines.where((l) => l.id == needShots[i]).firstOrNull;
      if (line == null) continue;
      // 进度带分母**到镜**：一行可能有 9 个分镜，只报「第 3 句 / 27 句」
      // 的话，人看着它在一句上停半分钟，不知道是卡了还是在干活
      final segTotal = line.reference?.segments.length ?? 1;
      setState(() => setStateProgress(
          '照着参考片找镜头',
          segTotal > 1
              ? '${line.text.trim()}（这一句 $segTotal 个分镜）'
              : line.text.trim(),
          i,
          needShots.length));
      final missed = await _autoPickShotByReference(
        line.id,
        tagIds,
        onProgress: (done, total) {
          if (!mounted || total <= 1) return;
          setState(() => setStateProgress('照着参考片找镜头',
              '${line.text.trim()}（第 ${done + 1}/$total 个分镜）',
              i, needShots.length));
        },
      );
      shotFailed += missed.length;
    }
    if (!mounted) return;
    // 三、完成一拍 + 开播——魔法时刻要有个 crescendo：进度收束成
    // 「铺好了」的对勾一拍（1.1s），然后播放器入场直接开播
    setState(() {
      _draftProgress = null;
      _draftCelebrating = true;
    });
    _flushNow();
    _pinAllShots();
    _schedulePreviewRebuild();
    unawaited(
        Future<void>.delayed(const Duration(milliseconds: 1100), () async {
      if (!mounted) return;
      setState(() => _draftCelebrating = false);
      // **有东西可播才播**。所有行都没挑到镜头时预览轨是空的，
      // 这一下 play() 只会让播放器进「正在播」的状态却停在 0：
      // 屏幕上是一个暂停按钮配着 00:00 / 00:00，人一看就懵
      // ——状态跟事实对不上（2026-09-10 真机走查）
      if (_planResult.isEmpty) return;
      await _playback?.seekMs(0);
      await _playback?.play();
    }));
    final flat = needVoice.where(_deliveryDegraded.containsKey).length;
    final problems = [
      if (voiceFailed > 0) '$voiceFailed 句配音没成',
      // 配出来了但没听成参考片的念法：那几句是默认语气，听起来会平
      if (flat > 0) '$flat 句用的是默认语气（没听成参考片怎么念）',
      // 数的是**镜**不是句：一句里 9 个分镜可能只缺 1 个，说成「1 句没找到」
      // 会让人以为整句是空的
      if (shotFailed > 0) '$shotFailed 个分镜没找到像的画面',
    ];
    // 一句都没进预览时不许说「正在播」——那是假的
    final nothingToPlay = _planResult.isEmpty;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(switch ((problems.isEmpty, nothingToPlay)) {
      (true, false) => '铺好了，正在播——不满意的镜头随手换。',
      (true, true) => '配音铺好了。镜头还没挑，去右栏「找镜头」，'
          '或者先传一段参考片让它照着配镜。',
      (false, true) => '铺好了（${problems.join('、')}）。'
          '现在还没有可播的内容——镜头挑上就能试片。',
      (false, false) => '铺好了（${problems.join('、')}，对应句子可以手动补）。',
    })));
  }

  /// 标签名 → id 映射（自动配镜的标签约束用）。
  /// **视觉镜头标签组也要**：自动配镜依据的是参考镜的画面标签，
  /// 它来自视觉镜头组，与话术标签不是一套。拉不到不挡路
  Future<Map<String, int>> _loadTagIds() async {
    try {
      final services = ref.read(shotSearchServicesProvider);
      final groups = await services.tags.listGroups();
      final wanted = {
        for (final g in [..._task.shotTagGroups, ..._task.unitTagGroups]) g.id,
      };
      final ids = <String, int>{};
      for (final g in groups) {
        if (!wanted.contains(g.id)) continue;
        for (final t in await services.tags.listTags(g.id)) {
          ids.putIfAbsent(t.name, () => t.id);
        }
      }
      return ids;
    } catch (e) {
      AppLog.warn('自动配镜拉标签词表失败（退回按台词搜）：$e');
      return const {};
    }
  }

  /// 给一句自动配一个镜头：按行标签检索（其次按台词的画面描述搜），
  /// 取第一个没被别的句子占用的候选，探好时长落地并按行时长分配
  /// 照着**参考片这一镜的画面**给一行配镜头。
  ///
  /// 以前这里是「有行标签就按标签搜，否则拿台词去搜画面描述」——后者是个
  /// 错配：台词说的是「如果你觉得有点贵」，而画面描述库里存的是「手持喷雾
  /// 瓶在厨房台面」，一句话和一幅画的描述根本不在一个维度上，搜出来的东西
  /// 和这句话没关系（而且只取第一条，不做挑选）。
  ///
  /// 现在走的是这个产品真正的主线：**复刻参考片**。先看懂参考片这一镜
  /// 长什么样（多帧识图，一次调用同时拿画面描述和标签），再拿这个描述去
  /// 妙啊找像的画面——和你在找镜头面板里手动做的是同一条路。
  ///
  /// 没有参考镜可依据时**直接放弃**，不退回去瞎捞：宁可这一行空着
  /// （空着一眼就看得出「这里还没做」），也不铺一堆不相干的画面让人逐个删。
  /// 「自动铺一版」的配镜：**这一行的参考里有几个分镜，就铺几个**。
  ///
  /// 产品负责人定的规矩：「第三行里面有 9 个分镜，你就要找 9 个，然后自动
  /// 去切对应的时间——这是机械化的程序。」此前这里只看第一个参考镜、
  /// 只找一条素材塞给整行：9 个镜头的行铺出来是一整条，参考片的节奏全丢了。
  ///
  /// 每一镜各自按**它自己的画面描述**去搜（不拿第一镜代表整行），时长按
  /// 参考的比例分（见 [ShotAllocation.distributeByReference]），素材偏短的
  /// 用放慢补满。
  ///
  /// 某一镜没搜到不静默跳过：其余的照铺，把没铺上的镜号报出去让人补。
  /// 返回没铺上的镜号（从 1 起），空表示这一行全铺上了。
  Future<List<int>> _autoPickShotByReference(
    String lineId,
    Map<String, int> tagIds, {
    void Function(int done, int total)? onProgress,
  }) async {
    final missed = <int>[];
    try {
      final services = ref.read(shotSearchServicesProvider);
      final line = _doc.lines.where((l) => l.id == lineId).firstOrNull;
      if (line == null) return [1];
      final refSegs = line.reference?.segments ?? const <(int, int)>[];
      if (refSegs.isEmpty) return [1];

      final picked = <LineShot>[];
      final usedSegs = <(int, int)>[];
      final dir = ref.read(dataDirProvider);
      for (var k = 0; k < refSegs.length; k++) {
        if (!mounted || _draftCancelled) break;
        onProgress?.call(k, refSegs.length);
        final seg = refSegs[k];
        // 参考片这一镜长什么样：打过标就直接用，没打过现打一次
        var meta = _doc.lines
            .firstWhere((l) => l.id == lineId)
            .reference
            ?.metaAt(seg.$1);
        if (meta == null || meta.description.trim().isEmpty) {
          meta = await _tagRefShot(lineId, k);
        }
        final description = meta?.description.trim() ?? '';
        if (description.isEmpty) {
          missed.add(k + 1);
          continue;
        }
        // 参考镜自己的画面标签当约束（比行的话术标签更贴画面）
        final ids = [
          for (final t in meta!.tags) ?tagIds[t],
        ];
        final page = await services.content.searchByDescription(
          keyword: description,
          tagIds: ids,
          projectIds: [if (_task.project != null) _task.project!.id],
          pageSize: 10,
        );
        // 已经用过的不再用：同一条素材在整片里反复出现，一眼就看出是机器
        // 铺的。这一行里刚挑中的也算用过
        final used = <int>{
          for (final l in _doc.lines)
            for (final sh in l.shots)
              if (sh.localSource == null) sh.materialId,
          for (final sh in picked) sh.materialId,
        };
        final pick = page.items
            .where((m) => !used.contains(m.id) && m.previewUrl != null)
            .firstOrNull;
        if (pick == null) {
          missed.add(k + 1);
          continue;
        }
        // 本地已经有就读本地：联网量一条要一秒，而且会失败
        final spec = await services.probe.probe(
          materialId: pick.id,
          previewUrl: pick.previewUrl,
          localPath: dir == null
              ? null
              : TaskMedia(dataDir: dir, taskId: _task.id)
                  .localMaterial(pick.id),
        );
        picked.add(LineShot(
          materialId: pick.id,
          name: pick.name,
          voiceover: pick.voiceover,
          sceneDescription: pick.sceneDescription,
          thumbnailUrl: pick.thumbnailUrl,
          fileKey: pick.fileKey,
          durationMs: spec?.durationMs,
        ));
        usedSegs.add(seg);
      }
      onProgress?.call(refSegs.length, refSegs.length);
      if (picked.isEmpty) return missed.isEmpty ? [1] : missed;

      final current = _doc.lines.firstWhere((l) => l.id == lineId);
      final withShots = current.withShots([...current.shots, ...picked]);
      final root = ShotAllocation.rootMsOf(withShots);
      _mutate((d) => d.setShotsById(
          lineId,
          root == null
              ? withShots.shots
              // 先按参考比例分时长，再把素材偏短的缺口用放慢补满——
              // 自动配的镜头不许留「没充满」的尾巴
              : ShotAllocation.fillBySlowdown(
                  ShotAllocation.distributeByReference(
                      withShots.shots, root, usedSegs),
                  root)));
      return missed;
    } catch (e) {
      AppLog.warn('自动配镜失败（line=$lineId）：$e');
      return missed.isEmpty ? [1] : missed;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_blockedBy != null) return _blockedView();
    final extracting = _extract is _ExtractRunning;
    // 起步引导激活时右栏收敛：一边问「从哪里开始」、一边摆开行工作台，
    // 两套话语打架（真机截图核对时发现）
    final showGuide =
        _scriptIsPristine && !_guideDismissed && _extract == null;
    // 全页快捷键：空格播放/暂停、←→ 秒跳、⌘Z 撤销、⇧⌘Z 重做。
    //
    // **人在输入框里打字时一律让路**（[isEditableTextFocused]）。
    // `CallbackShortcuts` 没有 `isEnabled` 那道闸，匹配上就无条件执行——
    // 于是写脚本时空格被当成「播放/暂停」，而中文输入法在拼音阶段按空格
    // 是选词上屏，拼音永远上不了屏：**中文根本打不出来，粘贴却可以**。
    // 输入框那头也包了 [TextEditingKeys] 把这些键留在本层，两道一起。
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.space): () {
          if (isEditableTextFocused()) return;
          if (!_planResult.isEmpty && _videoWidget != null) {
            unawaited(_togglePreviewPlay());
          }
        },
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () {
          if (isEditableTextFocused()) return;
          unawaited(_seekPreview(
              (_positionMs.value - 1000).clamp(0, _planResult.plan.totalMs)));
        },
        const SingleActivator(LogicalKeyboardKey.arrowRight): () {
          if (isEditableTextFocused()) return;
          unawaited(_seekPreview(
              (_positionMs.value + 1000).clamp(0, _planResult.plan.totalMs)));
        },
        const SingleActivator(LogicalKeyboardKey.keyA, meta: true): () {
          // 输入框里 ⌘A 是全选这段文字，不是全选整篇脚本的行
          if (isEditableTextFocused()) return;
          setState(() => _multiSelected
            ..clear()
            ..addAll([for (var i = 0; i < _doc.lines.length; i++) i]));
        },
        const SingleActivator(LogicalKeyboardKey.keyA, control: true): () {
          if (isEditableTextFocused()) return;
          setState(() => _multiSelected
            ..clear()
            ..addAll([for (var i = 0; i < _doc.lines.length; i++) i]));
        },
        const SingleActivator(LogicalKeyboardKey.escape): () {
          // 输入法组合时 Esc 是取消组合
          if (isEditableTextFocused()) return;
          setState(_multiSelected.clear);
        },
        const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): () {
          if (isEditableTextFocused()) return;
          _undo();
        },
        const SingleActivator(LogicalKeyboardKey.keyZ,
            meta: true, shift: true): () {
          if (isEditableTextFocused()) return;
          _redo();
        },
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): () {
          if (isEditableTextFocused()) return;
          _undo();
        },
        const SingleActivator(LogicalKeyboardKey.keyZ,
            control: true, shift: true): () {
          if (isEditableTextFocused()) return;
          _redo();
        },
      },
      // 输入框交出焦点之后由它接住，否则焦点落空、整套键位一起哑掉
      // （见 [KeyboardHome]）
      child: KeyboardHome(
          child: FocusScope(
        autofocus: true,
        child: Scaffold(
      backgroundColor: AppColors.background,
      body: Column(children: [
        _topBar(),
        const Divider(height: 1, thickness: 1, color: AppColors.border),
        // Agent 在场：**不做全页阻断**——人要能看着它干活，那正是这块屏的
        // 意义。改不动是在 _mutate 那一处拦的
        if (_agent != null) _agentBanner(_agent!),
        Expanded(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // 左：脚本——唯一的真相
            Container(
              width: 360,
              color: AppColors.surface,
              child: Column(children: [
                if (_extract != null) _extractBanner(),
                Expanded(
                  child: IgnorePointer(
                    ignoring: extracting,
                    child: ScriptPanel(
                      doc: _doc,
                      selected: _selected,
                      autofocusLineId: _autofocusLineId,
                      onSelect: (i) => setState(() {
                        _selected = i;
                        _expandedShot = null;
                      }),
                      onInsertAfter: (i) {
                        _mutate((d) => d.insertAfter(i));
                        setState(() {
                          _selected = i + 1;
                          _autofocusLineId = _doc.lines[i + 1].id;
                          _guideDismissed = true;
                        });
                      },
                      onRemove: (i) {
                        _mutate((d) => d.removeAt(i));
                        if (_selected >= _doc.lines.length) {
                          setState(
                              () => _selected = _doc.lines.length - 1);
                        }
                      },
                      onMove: (from, to) {
                        _mutate((d) => d.move(from, to));
                        setState(() => _selected = to);
                      },
                      onTextChanged: _changeText,
                    ),
                  ),
                ),
              ]),
            ),
            const VerticalDivider(
                width: 1, thickness: 1, color: AppColors.border),
            // 中：预览（定宽，播放器窄而居中）；空脚本时让位给起步引导
            if (showGuide)
              Expanded(child: _startGuide())
            else ...[
              SizedBox(width: 400, child: _previewStage()),
              const VerticalDivider(
                  width: 1, thickness: 1, color: AppColors.border),
              // 右：分镜编辑板——所有行的工作块从上到下铺开（行带式，
              // 见 2026-08-20 设计推演；检查器范式已废）
              Expanded(
                child: Container(
                  color: AppColors.surface,
                  child: Column(children: [
                    Expanded(child: LineBoard(
                    doc: _doc,
                    selected: _selected,
                    multiSelected: _multiSelected,
                    expandedShot: _expandedShot,
                    onExpandShot: (v) => setState(() {
                      _expandedShot = v;
                      // 人自己点开/收起了某一镜：这一轮播放别再抢他的面板
                      _autoExpandPaused = true;
                    }),
                    generatingLineIds: _generatingLineIds,
                    playingLineId: _playingLineId,
                    previewLineIndex: _previewLineIndex,
                    focusLineIndex: _agent?.focus?.lineIndex,
                    builtRows: _builtRows,
                    // 「正在给这一行找镜头」：那一步是纯检索，要过一会儿
                    // 才有东西填进来。不给个动静的话，人看到的是播报在
                    // 热火朝天地报「找到 946 条」，而界面一动不动
                    searchingLineIndex:
                        _agent?.focus?.panel == AgentPanel.findShots
                            ? _agent?.focus?.lineIndex
                            : null,
                    inlineKey: _inlineKey,
                    inlineVideo: _inlineVideo,
                    inlinePosition: _inlinePositionMs,
                    controller: _boardScroll,
                    handlers: LineBoardHandlers(
                      onFocusLine: _focusLine,
                      onFindShots: _findShots,
                      onRemoveShot: (index, j) {
                        final line = _doc.lines[index];
                        final next = [...line.shots]..removeAt(j);
                        // 删镜后剩下的按根重新均分——空出的时长不能凭空消失
                        _mutate((d) => d.setShotsById(
                            line.id,
                            next.isEmpty ? next : reallocShots(line, next)));
                        setState(() => _expandedShot = null);
                      },
                      onResizeShot: _resizeShot,
                      onTrimShot: _trimShot,
                      onSpeedShot: _speedShot,
                      onDistribute: _distribute,
                      onSlowFill: _slowFill,
                      onEditTags: _editTags,
                      shotFramesOf: (shot) {
                        _ensureShotFrames(shot);
                        final frames = _shotFrames[shot.materialId];
                        if (frames == null) return null;
                        return (
                          frames: frames,
                          aspect:
                              _shotFrameAspect[shot.materialId] ?? 9 / 16,
                        );
                      },
                      onPlayShot: _playShotInline,
                      onTrimDone: _scheduleReplayShot,
                      subtitleStyleOf: _styleOf,
                      // 滑杆的「默认值」必须和播放用的是同一个：
                      // 画面行满音量、配音行跟全片
                      defaultSourceVolumeOf: _doc.defaultSourceVolumeFor,
                      voiceIdOf: _doc.voiceIdOf,
                      speechRateOf: _doc.speechRateOf,
                      voiceStateOf: _doc.voiceStateOf,
                      onPickWords: _addShotByWords,
                      onShotSourceVolume: (index, j, volume) {
                        final line = _doc.lines[index];
                        // 音量不改变编排，所以不重铺轨道；改完直接把新音量
                        // 推给播放器，正在播就当场听得到
                        _mutate(
                            (d) => d.setShotSourceVolumeById(
                                line.id, j, volume),
                            affectsTracks: false);
                        _applySourceVolumeNow();
                        // 正在卡上播这一镜的话，当场跟着变——不然人拖着
                        // 滑杆听不到任何变化，只会以为没生效
                        if (_inlineKey == 'shot_${line.id}_$j') {
                          unawaited(_inlinePlayer?.setVolume(
                              volume ?? _doc.defaultSourceVolumeFor(line)));
                        }
                      },
                      onScreenText: (index, screenIndex, text) {
                        final line = _doc.lines[index];
                        _mutate(
                            (d) => d.setScreenTextById(
                                line.id, screenIndex, text,
                                maxChars: _styleOf(line).maxCharsPerScreen),
                            affectsTracks: false);
                      },
                      onScreenMerge: (index, screenIndex) {
                        final line = _doc.lines[index];
                        _mutate(
                            (d) => d.mergeScreenById(line.id, screenIndex,
                                maxChars: _styleOf(line).maxCharsPerScreen),
                            affectsTracks: false);
                      },
                      onScreenCut: (index, atMs) {
                        final line = _doc.lines[index];
                        _mutate(
                            (d) => d.cutScreenById(line.id, atMs,
                                maxChars: _styleOf(line).maxCharsPerScreen),
                            affectsTracks: false);
                      },
                      onFixTimings: _fixMissingWordTimings,
                      onScreenReset: (index) {
                        final line = _doc.lines[index];
                        _mutate((d) => d.resetScreensById(line.id),
                            affectsTracks: false);
                      },
                      onSubtitleCutHere: _cutSubtitleHere,
                      onManualMs: (index, ms) =>
                          _mutate((d) => d.setManualMs(index, ms)),
                      onPickVoice: _pickVoice,
                      onSpeechRate: (index, rate) {
                        _mutate((d) => d.setSpeechRate(index, rate),
                            affectsTracks: false);
                        // 语速只在**下一次生成配音**时生效，界面上不会有
                        // 任何立刻可见的变化——不说一声，人只会以为没点中
                        // 而反复点（真机反馈）
                        final label = switch (rate) {
                          -25 => '0.75x',
                          25 => '1.25x',
                          50 => '1.5x',
                          _ => '1x',
                        };
                        _toast('第 ${index + 1} 句语速设为 $label——'
                            '点这一行的「重新生成」才会按新语速配音。');
                      },
                      onGenerateVoice: _generateVoice,
                      onUploadVoice: _uploadVoice,
                      onTogglePlayVoice: _togglePlayVoice,
                      onPlayReference: _playReference,
                      onUseReference: _useReference,
                      onUploadReference: _uploadReference,
                      shotStatus: (id) => _mediaCache?.statusOf(id),
                      onRetryDownload: (id) => _mediaCache?.retry(id),
                      bgmOf: (lineIndex) {
                        final rail = bgmRail(_doc.bgmSegments, _doc.lines.length);
                        for (var i = 0; i < rail.length; i++) {
                          if (lineIndex >= rail[i].startLine &&
                              lineIndex <= rail[i].endLine) {
                            return (
                              index: i,
                              seg: rail[i],
                              isHead: lineIndex == rail[i].startLine
                            );
                          }
                        }
                        return (
                          index: 0,
                          seg: BgmRailSegment(
                              startLine: 0,
                              endLine: 0,
                              material: null,
                              volume: BgmSegment.defaultVolume),
                          isHead: true
                        );
                      },
                      bgmStatus: (id) => _bgmCache?.statusOf(id),
                      onRetryBgm: (id) {
                        _bgmCache?.retry(id);
                        _toast('正在重新下载这首配乐…');
                      },
                      onBgmSplit: _bgmSplitAt,
                      onBgmEdit: _bgmEditSegment,
                      onBgmMoveBoundary: (segIndex, delta) {
                        final rail =
                            bgmRail(_doc.bgmSegments, _doc.lines.length);
                        if (segIndex <= 0 || segIndex >= rail.length) return;
                        final next = moveRailBoundary(rail, segIndex,
                            rail[segIndex].startLine + delta);
                        _mutate((d) => d.withBgmSegments(railToSegments(next)));
                      },
                      refThumbOf: (line, segIndex) {
                        _ensureRefThumb(line, segIndex);
                        return _refThumbs['${line.id}_$segIndex'];
                      },
                    ),
                    )),
                    // 只在多选时出现，选回一行就收走
                    if (_multiSelected.length > 1) _multiSelectBar(),
                  ]),
                ),
              ),
            ],
          ]),
        ),
      ]),
        ),
      )),
    );
  }

  /// 点块 = 「你正看着这一行」：左栏行选中 + 预览跳播到该行起点
  void _focusLine(int index) {
    final keys = HardwareKeyboard.instance;
    // Shift = 选到这一行为止的一段；⌘ = 加选/取消这一行。
    // 都是 macOS 通用手势，不用教
    if (keys.isShiftPressed && _doc.lines.isNotEmpty) {
      final from = _selected < index ? _selected : index;
      final to = _selected < index ? index : _selected;
      setState(() {
        _multiSelected
          ..clear()
          ..addAll([for (var i = from; i <= to; i++) i]);
        _expandedShot = null;
      });
      return;
    }
    final additiveSelection =
        Platform.isWindows ? keys.isControlPressed : keys.isMetaPressed;
    if (additiveSelection) {
      setState(() {
        if (_multiSelected.isEmpty) _multiSelected.add(_selected);
        if (!_multiSelected.remove(index)) _multiSelected.add(index);
        _expandedShot = null;
      });
      return;
    }
    setState(() {
      _multiSelected.clear();
      _selected = index;
      _expandedShot = null;
    });
    final start = _planResult.lineStarts[index];
    if (start != null) {
      unawaited(_playback?.seekMs(start));
    }
  }

  /// 选中的那几行（没多选时就是当前这一行）
  List<int> get _targetLines {
    if (_multiSelected.isEmpty) return [_selected];
    return _multiSelected.toList()..sort();
  }

  /// 选中多行时浮出来的操作条。
  ///
  /// **不是「批量模式」**：就像 Finder，选一个和选十个用的是同一套操作，
  /// 只是作用对象多了几个。所以它只在多选时出现，选回一行就收走。
  ///
  /// 只放三件事——音色、语速、删除。它们的共同点是**一行行点特别痛**：
  /// 字幕样式已经有「整片」了；配乐是段的概念、不是行；时长每行都不同，
  /// 批量设没有意义
  Widget _multiSelectBar() {
    final lines = _targetLines;
    final voiced = [
      for (final i in lines)
        if (_doc.lines[i].type == ScriptLineType.voiced) i,
    ];
    final totalMs = lines.fold<int>(
        0, (a, i) => a + (ShotAllocation.rootMsOf(_doc.lines[i]) ?? 0));
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
      decoration: const BoxDecoration(
        color: AppColors.surfaceRaised,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: Row(children: [
        Text(
            '已选 ${lines.length} 行'
            '${totalMs > 0 ? ' · ${(totalMs / 1000).toStringAsFixed(1)} 秒' : ''}',
            style: const TextStyle(
                fontSize: AppFontSize.caption,
                color: AppColors.textSecondary)),
        const SizedBox(width: AppSpacing.sm),
        TextButton(
          key: const Key('multi-clear'),
          onPressed: () => setState(_multiSelected.clear),
          child: const Text('取消选择'),
        ),
        const Spacer(),
        // 画面行没有配音，音色/语速对它们无意义——一个都没有就禁掉，
        // 而不是点了以后悄悄什么都不做
        TextButton.icon(
          key: const Key('multi-voice'),
          onPressed: voiced.isEmpty ? null : () => _multiPickVoice(voiced),
          icon: const Icon(Icons.record_voice_over_outlined, size: 15),
          label: const Text('音色'),
        ),
        _multiSpeedButton(voiced),
        const SizedBox(width: AppSpacing.xs),
        TextButton.icon(
          key: const Key('multi-delete'),
          onPressed: () => _multiDelete(lines),
          icon: const Icon(Icons.delete_outline, size: 15),
          style: TextButton.styleFrom(foregroundColor: AppColors.red),
          label: const Text('删除'),
        ),
      ]),
    );
  }

  Widget _multiSpeedButton(List<int> voiced) => PopupMenuButton<int>(
        key: const Key('multi-speed'),
        enabled: voiced.isNotEmpty,
        tooltip: '语速',
        onSelected: (rate) => _multiSetSpeechRate(voiced, rate),
        itemBuilder: (_) => [
          for (final (rate, label) in const [
            (-25, '语速 0.75x'),
            (0, '语速 1x'),
            (25, '语速 1.25x'),
            (50, '语速 1.5x'),
          ])
            PopupMenuItem(value: rate, height: 32, child: Text(label)),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm, vertical: 6),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.speed,
                size: 15,
                color: voiced.isEmpty
                    ? AppColors.textTertiary
                    : AppColors.accentBlueLight),
            const SizedBox(width: 4),
            Text('语速',
                style: TextStyle(
                    fontSize: AppFontSize.caption,
                    color: voiced.isEmpty
                        ? AppColors.textTertiary
                        : AppColors.accentBlueLight)),
          ]),
        ),
      );

  /// 给选中的这几行换音色。
  ///
  /// 这里写的是**逐行覆盖**而不是本片基调：人特意挑了这几行，说明其他行
  /// 不该跟着变。要改全片，用顶栏那个「本片」
  Future<void> _multiPickVoice(List<int> lines) async {
    final picked = await showVoiceSelectDialog(context,
        selected: _doc.voiceIdOf(_doc.lines[lines.first]),
        allowApplyAll: false);
    if (picked == null || !mounted) return;
    final voiceId = picked.$1;
    _mutate((d) {
      var next = d;
      for (final i in lines) {
        next = next.setVoiceId(i, voiceId);
      }
      return next;
    });
    await _offerRegenerate(lines);
  }

  Future<void> _multiSetSpeechRate(List<int> lines, int rate) async {
    _mutate((d) {
      var next = d;
      for (final i in lines) {
        next = next.setSpeechRate(i, rate);
      }
      return next;
    });
    await _offerRegenerate(lines);
  }

  /// 改完音色/语速，已经配过音的那几句就过期了——问一句要不要现在重配。
  /// 不问的话，人以为改完了，实际听到的还是旧的
  Future<void> _offerRegenerate(List<int> lines) async {
    final stale = [
      for (final i in lines)
        if (i < _doc.lines.length &&
            _doc.voiceStateOf(_doc.lines[i]) == LineVoiceState.stale)
          _doc.lines[i].id,
    ];
    if (stale.isEmpty || !mounted) return;
    final redo = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surfaceRaised,
        title: Text('这 ${stale.length} 句要重新配音吗？'),
        content: const Text('改过的这几句现在还是旧的声音，'
            '不重新生成的话，预览和成片听到的都是改之前的。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('先留着')),
          FilledButton(
              key: const Key('multi-regen-confirm'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text('重新生成这 ${stale.length} 句')),
        ],
      ),
    );
    if (redo != true || !mounted) return;
    await _regenerateVoices(stale);
  }

  /// 批量删行。**要说清删掉的是什么**：其中几句已经配好音，删掉就真没了
  Future<void> _multiDelete(List<int> lines) async {
    final withVoice =
        lines.where((i) => _doc.lines[i].voiceover != null).length;
    final undoShortcut = Platform.isWindows ? 'Ctrl+Z' : '⌘Z';
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surfaceRaised,
        title: Text('删掉这 ${lines.length} 行？'),
        content: Text(withVoice == 0
            ? '删掉之后可以按 $undoShortcut 撤销。'
            : '其中 $withVoice 句已经配好音，删掉这些配音也一并没了。'
                '删错了可以按 $undoShortcut 撤销。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消')),
          FilledButton(
              key: const Key('multi-delete-confirm'),
              style: FilledButton.styleFrom(backgroundColor: AppColors.red),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    // 从后往前删：从前往后删会让后面的下标全部错位
    final descending = [...lines]..sort((a, b) => b.compareTo(a));
    _mutate((d) {
      var next = d;
      for (final i in descending) {
        next = next.removeAt(i);
      }
      return next;
    });
    setState(() {
      _multiSelected.clear();
      _selected = _selected.clamp(0, (_doc.lines.length - 1).clamp(0, 9999));
    });
  }

  /// 顶栏：返回 + 身份（#编号 · 名字 · 模块徽标）+ 保存状态。
  /// 自动保存要**说出来**——用户不问「存了没」是因为界面一直在回答
  /// Agent 在场的横幅：谁在、正在做什么、以及「我来接手」
  Widget _agentBanner(AgentPresence agent) => Container(
        width: double.infinity,
        color: AppColors.accentBlue.withValues(alpha: 0.16),
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg, vertical: AppSpacing.xs),
        child: Row(children: [
          const SizedBox(
              width: 11,
              height: 11,
              child: CircularProgressIndicator(strokeWidth: 1.4)),
          const SizedBox(width: AppSpacing.sm),
          Text('${agent.holder} 正在操作这个任务',
              style: const TextStyle(
                  fontSize: AppFontSize.caption,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary)),
          if (agent.action.isNotEmpty) ...[
            const SizedBox(width: AppSpacing.sm),
            Flexible(
              child: Text(agent.action,
                  key: const ValueKey('agent-action'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: AppFontSize.caption,
                      color: AppColors.textSecondary)),
            ),
          ],
          const Spacer(),
          TextButton(
            key: const ValueKey('agent-takeover'),
            onPressed: _takeoverFromAgent,
            child: const Text('我来接手',
                style: TextStyle(fontSize: AppFontSize.caption)),
          ),
        ]),
      );

  Widget _topBar() => Container(
        height: 48,
        color: AppColors.surface,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
        child: Row(children: [
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back_ios_new,
                size: 15, color: AppColors.textSecondary),
            tooltip: '返回任务列表',
          ),
          const SizedBox(width: AppSpacing.xs),
          // 编号要看得见、点得动：人跟 Agent 说事情全靠它。
          // 原来用最淡的 tertiary 写在这儿，等于没有
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.sm),
            child: TaskIdBadge(task: _task),
          ),
          Flexible(
            child: Text(_task.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: AppFontSize.emphasis,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary)),
          ),
          const SizedBox(width: AppSpacing.sm),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: AppColors.accentBlue.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppRadius.pill),
            ),
            child: const Text('编导台',
                style: TextStyle(
                    fontSize: AppFontSize.micro,
                    fontWeight: FontWeight.w600,
                    color: AppColors.accentBlueLight)),
          ),
          const Spacer(),
          _voiceBaselineChip(),
          const SizedBox(width: AppSpacing.sm),
          Text(_saving ? '保存中…' : '更改已自动保存',
              style: const TextStyle(
                  fontSize: AppFontSize.caption,
                  color: AppColors.textTertiary)),
          const SizedBox(width: AppSpacing.sm),
          IconButton(
            key: const ValueKey('director-bgm'),
            visualDensity: VisualDensity.compact,
            // 还没配乐时：一键给整片配一首（整片就是一段）。
            // 分段在右栏色带上做——「从这一句开始换一首」
            onPressed: () => _bgmEditSegment(0),
            iconSize: 16,
            icon: Icon(Icons.music_note,
                color: _doc.bgmSegments.isEmpty
                    ? AppColors.textSecondary
                    : AppColors.accentBlueLight),
            tooltip: _doc.bgmSegments.isEmpty
                ? '给整片配一首（分段在右栏色带上切）'
                : '配乐：${_doc.bgmSegments.length} 段',
          ),
          // 顶栏只留可重复、非破坏的动作：配乐 · 生成草片 · 导出成片。
          // 「字幕样式」由预览下方的工具条 +「应用到整片」接管；
          // 「从视频提取脚本」是空脚本时的一次性起步动作（会覆盖整份
          // 脚本、把配音镜头字幕全作废），只留在起步引导里
          const SizedBox(width: AppSpacing.xs),
          _draftButton(),
          const SizedBox(width: AppSpacing.sm),
          _exportButton(),
          const SizedBox(width: AppSpacing.sm),
          _jianyingButton(),
          const SizedBox(width: AppSpacing.xs),
        ]),
      );

  /// 还有句子没配好吗——顶栏主次按它定
  bool get _draftHasWork => _doc.lines.any((l) =>
      l.type == ScriptLineType.voiced &&
      (l.voiceState != LineVoiceState.fresh || l.shots.isEmpty));

  /// 「生成草片」的主次是动态的：还有句子没配好时它才是这一屏的主动作
  /// （实心蓝），全就绪后让位给「导出成片」——一屏只有一个主角，
  /// 所以两个按钮的实心/描边永远互补（见 [_exportButton]）
  Widget _draftButton() {
    final label = Text(_draftProgress != null ? '铺片中…' : '自动铺一版');
    const icon = Icon(Icons.auto_awesome, size: 14);
    final onPressed = _draftProgress != null ? null : _generateDraft;
    if (_draftHasWork) {
      return FilledButton.icon(
        key: const ValueKey('director-draft'),
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.accentBlue,
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md, vertical: 6),
          textStyle: const TextStyle(
              fontSize: AppFontSize.body, fontWeight: FontWeight.w600),
        ),
        icon: icon,
        label: label,
      );
    }
    return OutlinedButton.icon(
      key: const ValueKey('director-draft'),
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.textPrimary,
        side: const BorderSide(color: AppColors.border),
        padding:
            const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 6),
        textStyle: const TextStyle(fontSize: AppFontSize.body),
      ),
      icon: icon,
      label: label,
    );
  }

  // ---- 剪映 ----

  bool _jianyingBusy = false;

  /// 「剪映」：把这一版方案写成剪映工程，用户自己在剪映里接着精修。
  ///
  /// 与「导出成片」互补——那边出的是**片子**（烧死，改个转场都要重来），
  /// 这边出的是**工程**（原始素材 + 剪辑参数，都还能调）。永远是描边：
  /// 一屏只有一个实心主角，那是「导出成片」/「自动铺一版」
  Widget _jianyingButton() => OutlinedButton.icon(
        key: const ValueKey('director-jianying'),
        onPressed: _jianyingBusy || _exporting ? null : _generateJianyingDraft,
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.textPrimary,
          side: const BorderSide(color: AppColors.border),
          padding:
              const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 6),
          textStyle: const TextStyle(fontSize: AppFontSize.body),
        ),
        icon: const Icon(Icons.movie_outlined, size: 14),
        label: Text(_jianyingBusy ? '生成中…' : '剪映'),
      );

  /// 生成剪映草稿：素材补齐 → 落地 → 写草稿。**不拉起剪映**——
  /// 剪映没有给外部程序「打开指定草稿」的通道（实测详见 jianying_writer 注释），
  /// 与其假装能替用户点开，不如把草稿名交代清楚
  Future<void> _generateJianyingDraft() async {
    _flushNow();
    final cache = _mediaCache;
    if (cache == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('当前环境没有素材下载器，生成不了剪映草稿。')));
      return;
    }
    // **拦在进门口**：缺镜头这类问题一眼看得全，不该让人先等素材归集
    // 几十秒、再被一句「第 2 行还没挑镜头」打回来（2026-09-10 真机走查）
    if (jianyingBlockingReason(_doc) case final blocked?) {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: AppColors.surfaceRaised,
          title: const Text('还生成不了剪映草稿'),
          content: SizedBox(
            width: 380,
            child: SelectableText(blocked,
                style: const TextStyle(
                    fontSize: AppFontSize.body,
                    color: AppColors.textSecondary,
                    height: 1.6)),
          ),
          actions: [
            FilledButton(
                key: const Key('jianying-blocked-ok'),
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('知道了')),
          ],
        ),
      );
      return;
    }
    setState(() => _jianyingBusy = true);
    _exportProgress.value = const ScriptExportProgress('准备中', 0);
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ExportProgressDialog(
          progress: _exportProgress, title: '正在生成剪映草稿'),
    ));
    // 素材先补齐——工程里少一段素材，用户要到剪映里才发现
    while (true) {
      final blocked = await _prepareMedia();
      if (!mounted) return;
      if (blocked.isEmpty) break;
      Navigator.of(context, rootNavigator: true).pop();
      final choice = await _askMediaBlocked(blocked);
      if (!mounted) return;
      if (choice == null) {
        setState(() => _jianyingBusy = false);
        return;
      }
      if (choice == 'drop-bgm') {
        final drop = {for (final f in blocked) f.id};
        _mutate((d) => d.withBgmSegments([
              for (final seg in d.bgmSegments)
                if (!drop.contains(seg.material.id)) seg,
            ]));
        _flushNow();
        _pinBgm();
      } else {
        for (final f in blocked) {
          (f.isBgm ? _bgmCache : _mediaCache)?.retry(f.id);
        }
      }
      _exportProgress.value = const ScriptExportProgress('准备中', 0);
      unawaited(showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _ExportProgressDialog(
            progress: _exportProgress, title: '正在生成剪映草稿'),
      ));
    }
    try {
      final writer = JianyingWriter(
        sourceOf: (shot) =>
            shot.localSource ?? cache.localPathOf(shot.materialId),
        voiceOf: (line) {
          final vo = line.voiceover;
          return vo != null && File(vo.audioPath).existsSync()
              ? vo.audioPath
              : null;
        },
        bgmOf: (id) => _bgmCache?.localPathOf(id),
      );
      final result = await writer.write(
        _doc,
        taskName: _task.name,
        onProgress: (done, total, what) => _exportProgress.value =
            ScriptExportProgress(
                '$what $done/$total', total <= 0 ? 0 : done / total),
      );
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      setState(() => _jianyingBusy = false);
      await _showJianyingDone(result);
    } on JianyingPlanException catch (e) {
      AppLog.warn('剪映草稿被拦：${e.message}');
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      setState(() => _jianyingBusy = false);
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('生成不了剪映草稿'),
          content: Text(e.message),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('知道了')),
          ],
        ),
      );
    } catch (e) {
      AppLog.warn('剪映草稿生成失败：$e');
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      setState(() => _jianyingBusy = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('生成剪映草稿失败，请稍后重试。')));
    }
  }

  /// 生成完的交代：草稿叫什么、去哪儿开、剪映开着时为什么还看不到。
  /// **不许只弹一句「成功」**——用户下一步要做什么必须说清楚
  Future<void> _showJianyingDone(JianyingDraftResult result) => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('剪映草稿已生成'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(result.name,
                  style: const TextStyle(
                      fontSize: AppFontSize.body,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary)),
              const SizedBox(height: AppSpacing.xs),
              Text(
                  '${(result.totalMs / 1000).toStringAsFixed(1)} 秒 · '
                  '${result.materialCount} 个素材',
                  style: const TextStyle(
                      fontSize: AppFontSize.caption,
                      color: AppColors.textSecondary)),
              const SizedBox(height: AppSpacing.md),
              const Text('打开剪映，在「本地草稿」里找到它继续编辑。',
                  style: TextStyle(
                      fontSize: AppFontSize.body,
                      color: AppColors.textPrimary)),
              const SizedBox(height: AppSpacing.xs),
              const Text('剪映如果已经开着，需要重启它才会出现在草稿列表里。',
                  style: TextStyle(
                      fontSize: AppFontSize.caption,
                      color: AppColors.textSecondary)),
              for (final note in result.notes) ...[
                const SizedBox(height: AppSpacing.sm),
                Text('· $note',
                    style: const TextStyle(
                        fontSize: AppFontSize.caption,
                        color: AppColors.orange)),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => PlatformShell().revealPath(result.folder),
              child: Text(PlatformShell().revealLabel),
            ),
            TextButton(
              onPressed: () async {
                Navigator.of(context).pop();
                try {
                  await launchJianying();
                } catch (error) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(this.context).showSnackBar(
                    SnackBar(content: Text('$error')),
                  );
                }
              },
              child: const Text('打开剪映'),
            ),
            TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('知道了')),
          ],
        ),
      );

  /// 「导出成片」与「生成草片」互补：草片还有活时退居描边，
  /// 全就绪后成为唯一的实心主角
  Widget _exportButton() {
    final label = Text(_exporting ? '导出中…' : '导出成片');
    const icon = Icon(Icons.ios_share, size: 14);
    final onPressed = _exporting ? null : _exportScript;
    if (_draftHasWork) {
      return OutlinedButton.icon(
        key: const ValueKey('director-export'),
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.textPrimary,
          side: const BorderSide(color: AppColors.border),
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md, vertical: 6),
          textStyle: const TextStyle(fontSize: AppFontSize.body),
        ),
        icon: icon,
        label: label,
      );
    }
    return FilledButton.icon(
      key: const ValueKey('director-export'),
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.accentBlue,
        padding:
            const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 6),
        textStyle: const TextStyle(
            fontSize: AppFontSize.body, fontWeight: FontWeight.w600),
      ),
      icon: icon,
      label: label,
    );
  }

  Widget _extractBanner() {
    final state = _extract;
    if (state is _ExtractRunning) {
      return Container(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                    strokeWidth: 1.5, color: AppColors.accentBlue)),
            const SizedBox(width: AppSpacing.sm),
            Text(state.stage.label,
                style: const TextStyle(
                    fontSize: AppFontSize.body,
                    color: AppColors.textSecondary)),
          ]),
          const SizedBox(height: AppSpacing.sm),
          const LinearProgressIndicator(
              minHeight: 2,
              color: AppColors.accentBlue,
              backgroundColor: AppColors.surfaceCard),
        ]),
      );
    }
    if (state is _ExtractFailed) {
      return Container(
        margin: const EdgeInsets.fromLTRB(
            AppSpacing.sm, AppSpacing.sm, AppSpacing.sm, 0),
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: AppColors.red.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(state.message,
              style: const TextStyle(
                  fontSize: AppFontSize.body,
                  color: AppColors.red,
                  height: 1.4)),
          const SizedBox(height: AppSpacing.xs),
          Row(children: [
            TextButton(
                onPressed: _extractFromVideo, child: const Text('重试')),
            TextButton(
                onPressed: () => setState(() => _extract = null),
                child: const Text('关闭')),
          ]),
        ]),
      );
    }
    return const SizedBox.shrink();
  }

  /// 空脚本的起步引导（见 start_guide.dart）
  Widget _startGuide() => StartGuide(
        canExtract: ref.watch(scriptTranscriberProvider) != null,
        onExtract: _extractFromVideo,
        onWrite: () => setState(() => _guideDismissed = true),
      );

  /// 预览舞台：竖屏幕布居中、限高——播放器窄而居中，不做顶天立地的黑洞。
  /// 有可播内容时是真播放器 + 传输条；没有时占位说明「还差什么」
  Widget _previewStage() {
    // 草片刚做完：对勾一拍（elasticOut 弹入），紧接着开播
    if (_draftCelebrating) {
      return Container(
        color: AppColors.stageWell,
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 600),
              curve: Curves.elasticOut,
              builder: (_, v, child) => Transform.scale(scale: v, child: child),
              child: Container(
                width: 56,
                height: 56,
                decoration: const BoxDecoration(
                    shape: BoxShape.circle, color: AppColors.green),
                child: const Icon(Icons.check_rounded,
                    size: 34, color: Colors.white),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            const Text('铺好了',
                style: TextStyle(
                    fontSize: AppFontSize.title,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary)),
            const SizedBox(height: AppSpacing.xs),
            const Text('这就播给你看',
                style: TextStyle(
                    fontSize: AppFontSize.caption,
                    color: AppColors.textSecondary)),
          ]),
        ),
      );
    }
    // 批量重配进行中：**必须能停**。十几句是分钟级的活，点下去以后
    // 软件假死两分钟是不能接受的；停下来时已经生成好的要保留
    if (_batchVoiceProgress case (final done, final total, final text)) {
      return Container(
        color: AppColors.stageWell,
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(
                width: 44,
                height: 44,
                child: CircularProgressIndicator(
                  value: total == 0 ? null : done / total,
                  strokeWidth: 3,
                  color: AppColors.accentBlue,
                  backgroundColor: AppColors.surfaceCard,
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text('正在重新配音 $done / $total',
                  style: const TextStyle(
                      fontSize: AppFontSize.emphasis,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary)),
              const SizedBox(height: AppSpacing.sm),
              Text('「${text.length > 24 ? '${text.substring(0, 24)}…' : text}」',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: AppFontSize.caption,
                      color: AppColors.textSecondary,
                      height: 1.5)),
              const SizedBox(height: AppSpacing.md),
              TextButton(
                key: const Key('batch-voice-cancel'),
                onPressed: _cancelBatchVoice
                    ? null
                    : () => setState(() => _cancelBatchVoice = true),
                child: Text(_cancelBatchVoice ? '正在停下…' : '停下'),
              ),
            ]),
          ),
        ),
      );
    }
    // 草片流水线进行中：舞台交给进度——用户看着自己的片子一句句长出来，
    // 而不是对着死黑块等
    if (_draftProgress case (final stage, final text, final done, final total)) {
      return Container(
        color: AppColors.stageWell,
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(
                width: 44,
                height: 44,
                child: CircularProgressIndicator(
                  value: total == 0 ? null : (done + 1) / total,
                  strokeWidth: 3,
                  color: AppColors.accentBlue,
                  backgroundColor: AppColors.surfaceCard,
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text('正在给第 ${done + 1} / $total 句$stage',
                  style: const TextStyle(
                      fontSize: AppFontSize.emphasis,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary)),
              const SizedBox(height: AppSpacing.sm),
              Text('「${text.length > 24 ? '${text.substring(0, 24)}…' : text}」',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: AppFontSize.caption,
                      color: AppColors.textSecondary,
                      height: 1.5)),
              const SizedBox(height: AppSpacing.md),
              const Text('完成后草片会直接播出来',
                  style: TextStyle(
                      fontSize: AppFontSize.micro,
                      color: AppColors.textTertiary)),
            ]),
          ),
        ),
      );
    }
    final playable = !_planResult.isEmpty && _videoWidget != null;
    return Container(
      color: AppColors.stageWell,
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xl, vertical: AppSpacing.lg),
      child: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 560),
              child: AspectRatio(
                aspectRatio: 9 / 16,
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.stageBackground,
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                    border: Border.all(color: AppColors.stageEdge),
                    // 和审片台的舞台同一套：一圈边 + 一层落影把画面从
                    // 舞台底色里托起来。深色画面（夜景、黑场）少了这两样
                    // 会和背景连成一片，看不出画幅到哪儿为止
                    boxShadow: const [
                      BoxShadow(
                          color: Color(0x99000000),
                          blurRadius: 24,
                          offset: Offset(0, 6)),
                    ],
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: playable
                      ? Stack(fit: StackFit.expand, children: [
                          _videoWidget!,
                          // 实时字幕层：播放到哪句显示哪句，样式即改即见
                          // （所见即所得——不用导出才知道字幕长什么样）
                          ValueListenableBuilder<int>(
                            valueListenable: _positionMs,
                            builder: (_, _, _) => _previewSubtitle(),
                          ),
                        ])
                      : Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.play_circle_outline,
                                size: 28,
                                color: AppColors.textTertiary
                                    .withValues(alpha: 0.55)),
                            const SizedBox(height: AppSpacing.sm),
                            const Text('配音与镜头就绪后，在这里试片',
                                style: TextStyle(
                                    fontSize: AppFontSize.caption,
                                    color: AppColors.textTertiary)),
                          ]),
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          // 传输条：可播时活的（进度条可拖动定位），不可播时禁用态骨架
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 340),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
              key: const ValueKey('director-preview-play'),
              visualDensity: VisualDensity.compact,
              tooltip: _previewPlaying ? '暂停　空格' : '播放　空格',
              onPressed: playable ? _togglePreviewPlay : null,
              iconSize: 20,
              icon: Icon(_previewPlaying ? Icons.pause : Icons.play_arrow,
                  color: playable
                      ? AppColors.textPrimary
                      : AppColors.textTertiary.withValues(alpha: 0.4)),
            ),
            const SizedBox(width: AppSpacing.xs),
            Flexible(
              child: ValueListenableBuilder<int>(
                valueListenable: _positionMs,
                builder: (_, ms, _) {
                  final total = _planResult.plan.totalMs;
                  final shown = (_dragMs ?? (playable ? ms : 0))
                      .clamp(0, total > 0 ? total : 1);
                  return SliderTheme(
                    data: SliderThemeData(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 5),
                      overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 11),
                      activeTrackColor: AppColors.accentBlue,
                      inactiveTrackColor: AppColors.surfaceCard,
                      thumbColor: AppColors.accentBlueLight,
                    ),
                    child: Slider(
                      key: const ValueKey('director-preview-seek'),
                      value: shown.toDouble(),
                      max: (total > 0 ? total : 1).toDouble(),
                      onChanged: playable
                          ? (v) => setState(() => _dragMs = v.round())
                          : null,
                      onChangeEnd: playable
                          ? (v) {
                              setState(() => _dragMs = null);
                              unawaited(_seekPreview(v.round()));
                            }
                          : null,
                    ),
                  );
                },
              ),
            ),
            const SizedBox(width: AppSpacing.xs),
            ValueListenableBuilder<int>(
              valueListenable: _positionMs,
              builder: (_, ms, _) => Text(
                  '${_mmss(_dragMs ?? (playable ? ms : 0))} / ${_mmss(_planResult.plan.totalMs)}',
                  style: TextStyle(
                      fontSize: AppFontSize.caption,
                      color: playable
                          ? AppColors.textSecondary
                          : AppColors.textTertiary.withValues(alpha: 0.5),
                      fontFeatures: const [FontFeature.tabularFigures()])),
            ),
          ])),
          if (_previewBusy)
            const Padding(
              padding: EdgeInsets.only(top: AppSpacing.xs),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(strokeWidth: 1.4)),
                SizedBox(width: 6),
                Text('正在重铺预览…',
                    style: TextStyle(
                        fontSize: AppFontSize.micro,
                        color: AppColors.textSecondary)),
              ]),
            ),
          if (playable) _soundToolbar(),
          if (playable) _subtitleToolbar(),
          // 预览可以少几行——人还在编排——但少了哪几行必须点名。
          // 行多时按原因分组汇总，不拿一面墙的橙字糊满中栏
          if (_planResult.skippedLines.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.sm),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 340),
                child: Text(
                  _skippedSummary(),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: AppFontSize.micro,
                      color: AppColors.orange,
                      height: 1.5),
                ),
              ),
            ),
        ]),
      ),
    );
  }

  /// 字幕工具条（常驻在预览正下方，用户定的 A 方案）：调什么、看什么
  /// 在同一视线里——不再用弹窗盖住唯一能看出效果的地方。
  /// 跟着**当前这一句**走（播到哪句就是哪句，否则是选中的那句）；
  /// 样式粒度 = 句，右端「整片」把这套提升为全局基调
  /// 顶栏的**本片基调**：这个片子的音色与语速。
  ///
  /// 常驻在顶栏，因为它是「这片子听起来是谁在说话」这件事的唯一出处——
  /// 藏进某一行的菜单里，人就只会一行行去点。点开可改；改了之后新生成的
  /// 都用它，已经生成的会被问一句要不要一起换
  Widget _voiceBaselineChip() {
    final id = _doc.defaultVoiceId;
    final name = id == null
        ? '未定音色'
        : (VoiceCatalog.byId(id)?.ref.name ?? id);
    final rate = _doc.defaultSpeechRate;
    return Tooltip(
      message: '本片基调：新生成的配音用这个音色与语速。\n单句要不一样，在那一行改',
      child: InkWell(
        key: const Key('director-voice-baseline'),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        onTap: _editVoiceBaseline,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: id == null
                ? AppColors.orange.withValues(alpha: 0.14)
                : AppColors.surfaceCard,
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.record_voice_over_outlined,
                size: 13,
                color: id == null
                    ? AppColors.orange
                    : AppColors.textSecondary),
            const SizedBox(width: 4),
            Text(
                '本片 · $name${rate != 0 ? ' · ${1 + rate / 100}x' : ''}',
                style: TextStyle(
                    fontSize: AppFontSize.micro,
                    color: id == null
                        ? AppColors.orange
                        : AppColors.textSecondary)),
          ]),
        ),
      ),
    );
  }

  Future<void> _editVoiceBaseline() async {
    final picked = await showVoiceSelectDialog(context,
        selected: _doc.defaultVoiceId, allowApplyAll: false);
    if (picked == null || !mounted) return;
    // 从顶栏改就是改全片——这里没有「只改这一行」的语义
    await _unifyVoice(picked.$1);
  }

  /// 拖动中的混音台（松手才落盘：每动一下就重建轨道会卡）
  SoundMix? _mixDraft;

  /// 批量重配进度：(第几句, 共几句, 这句台词)；null = 没在跑
  (int, int, String)? _batchVoiceProgress;

  /// 人按了取消——正在跑的这一句做完就停，已生成的保留
  bool _cancelBatchVoice = false;

  /// 多选中的行（下标）。空 = 只有 [_selected] 那一行。
  ///
  /// 改 5 句不该点 5 次——这是编导台最痛的一处。选择用的是所有人都会的
  /// 手势（Shift 选范围、⌘ 加选、⌘A 全选），**不新增「批量模式」这种概念**：
  /// 就像 Finder 里选一个文件和选十个文件，操作是同一套
  final Set<int> _multiSelected = {};

  /// 人动手了，自动展开先让路。
  ///
  /// 不停的话，人正改着第 3 行，播放头走到第 5 行就把他手上那一栏收起来了
  /// ——这个功能会从「顺手」变成「骚扰」。暂停播放时解除
  bool _autoExpandPaused = false;

  /// 声音区：**三条轨的混音台**——原声 / 配音 / 配乐。
  ///
  /// 用户的心智就是一张混音台：三条轨可能同时响，也可能只调其中一条、
  /// 或者直接关掉。此前这里只有一根滑杆，还名不副实——它叫「原声」、
  /// 位置像总音量，实际调的是「配音行没单独设时原声压到多少」，
  /// 所以拉它对画面行永远没反应，用户只会以为软件坏了。
  Widget _soundToolbar() {
    final mix = _mixDraft ?? _doc.mix;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Column(children: [
        _mixRow(
          label: '原声',
          slot: 'source',
          value: mix.source,
          muted: mix.sourceMuted,
          onChanged: (v) => _mixDraftTo(mix.copyWith(source: v)),
          onCommit: (v) => _mixCommit(mix.copyWith(source: v)),
          onMute: () => _mixCommit(mix.withSourceMuted(!mix.sourceMuted)),
        ),
        _mixRow(
          // 叫「口播」不叫「配音」：和「原声」并排时，「配音」太泛，
          // 人分不清哪个是素材自带的声音、哪个是念台词的
          label: '口播',
          slot: 'voice',
          value: mix.voice,
          muted: mix.voiceMuted,
          onChanged: (v) => _mixDraftTo(mix.copyWith(voice: v)),
          onCommit: (v) => _mixCommit(mix.copyWith(voice: v)),
          onMute: () => _mixCommit(mix.withVoiceMuted(!mix.voiceMuted)),
        ),
        _mixRow(
          label: '配乐',
          slot: 'bgm',
          value: mix.bgm,
          muted: mix.bgmMuted,
          onChanged: (v) => _mixDraftTo(mix.copyWith(bgm: v)),
          onCommit: (v) => _mixCommit(mix.copyWith(bgm: v)),
          onMute: () => _mixCommit(mix.withBgmMuted(!mix.bgmMuted)),
        ),
        _duckRow(mix),
      ]),
    );
  }

  void _mixDraftTo(SoundMix next) {
    setState(() => _mixDraft = next);
    _mixPreview(next);
  }

  void _mixCommit(SoundMix next) {
    setState(() => _mixDraft = null);
    // 音量不改变编排，所以不重铺轨道
    _mutate((d) => d.withMix(next), affectsTracks: false);
    _applySourceVolumeNow();
  }

  Widget _mixRow({
    required String label,
    required String slot,
    required double value,
    required bool muted,
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onCommit,
    required VoidCallback onMute,
  }) =>
      Row(children: [
        SizedBox(
            width: 28,
            child: Text(label,
                style: TextStyle(
                    fontSize: AppFontSize.micro,
                    color: muted
                        ? AppColors.textTertiary
                        : AppColors.textSecondary))),
        Expanded(
          child: SliderTheme(
            data: const SliderThemeData(
              trackHeight: 2,
              thumbShape: RoundSliderThumbShape(enabledThumbRadius: 5),
              overlayShape: RoundSliderOverlayShape(overlayRadius: 10),
            ),
            child: Slider(
              key: ValueKey('sound-bar-$slot-volume'),
              value: value.clamp(0.0, 1.0),
              // 静音时滑杆变灰但**位置不动**：再点一下要回到原来的地方
              activeColor:
                  muted ? AppColors.textTertiary : AppColors.accentBlue,
              onChanged: onChanged,
              onChangeEnd: onCommit,
            ),
          ),
        ),
        SizedBox(
            width: 38,
            child: Text('${(value * 100).round()}%',
                textAlign: TextAlign.right,
                style: TextStyle(
                    fontSize: AppFontSize.micro,
                    color: muted
                        ? AppColors.textTertiary
                        : AppColors.textSecondary,
                    fontFeatures: const [FontFeature.tabularFigures()]))),
        IconButton(
          key: ValueKey('sound-bar-$slot-mute'),
          onPressed: onMute,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          padding: EdgeInsets.zero,
          tooltip: muted ? '取消静音' : '静音这条轨',
          icon: Icon(muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
              size: 15,
              color: muted ? AppColors.orange : AppColors.textTertiary),
        ),
      ]);

  /// 「有口播时自动压低原声」。
  ///
  /// 这是原声轨真正需要的那条规则：口播段落上原声会和人声叠成两份，
  /// 默认压到 0。它以前被当成「原声总音量」摆在上面，所以画面行拉不动
  Widget _duckRow(SoundMix mix) => Padding(
        padding: const EdgeInsets.only(top: 2, right: 28),
        child: Row(children: [
          SizedBox(
            width: 22,
            height: 22,
            child: Checkbox(
              key: const ValueKey('sound-bar-duck'),
              value: mix.duckSourceUnderVoice,
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              onChanged: (v) =>
                  _mixCommit(mix.copyWith(duckSourceUnderVoice: v ?? true)),
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Text(
                mix.duckSourceUnderVoice
                    ? '有口播时把原声压到 ${(mix.duckedSourceVolume * 100).round()}%'
                    : '有口播时不压低原声',
                style: const TextStyle(
                    fontSize: AppFontSize.micro,
                    color: AppColors.textTertiary)),
          ),
          if (mix.duckSourceUnderVoice)
            SizedBox(
              width: 90,
              child: SliderTheme(
                data: const SliderThemeData(
                  trackHeight: 2,
                  thumbShape: RoundSliderThumbShape(enabledThumbRadius: 4),
                  overlayShape: RoundSliderOverlayShape(overlayRadius: 8),
                ),
                child: Slider(
                  key: const ValueKey('sound-bar-duck-level'),
                  value: mix.duckedSourceVolume.clamp(0.0, 1.0),
                  activeColor: AppColors.accentBlue,
                  onChanged: (v) =>
                      _mixDraftTo(mix.copyWith(duckedSourceVolume: v)),
                  onChangeEnd: (v) =>
                      _mixCommit(mix.copyWith(duckedSourceVolume: v)),
                ),
              ),
            ),
        ]),
      );

  Widget _subtitleToolbar() {
    final index = _subtitleTargetIndex;
    if (_doc.lines.isEmpty) return const SizedBox.shrink();
    final line = _doc.lines[index];
    if (line.type != ScriptLineType.voiced) return const SizedBox.shrink();
    final style = _styleOf(line);

    void draft(SubtitleStyle next) {
      setState(() {
        _styleDraft = next;
        _styleDraftLineId = line.id;
      });
    }

    void commit(SubtitleStyle next) {
      setState(() {
        _styleDraft = null;
        _styleDraftLineId = null;
      });
      _mutate((d) => d.setSubtitleOverrideById(line.id, next),
          affectsTracks: false);
    }

    Widget slider({
      required String label,
      required Key key,
      required double value,
      required double min,
      required double max,
      required String trailing,
      required SubtitleStyle Function(double v) build,
    }) =>
        Row(children: [
          SizedBox(
              width: 28,
              child: Text(label,
                  style: const TextStyle(
                      fontSize: AppFontSize.micro,
                      color: AppColors.textSecondary))),
          Expanded(
            child: SliderTheme(
              data: const SliderThemeData(
                trackHeight: 2,
                thumbShape: RoundSliderThumbShape(enabledThumbRadius: 5),
                overlayShape: RoundSliderOverlayShape(overlayRadius: 10),
              ),
              child: Slider(
                key: key,
                value: value.clamp(min, max),
                min: min,
                max: max,
                activeColor: AppColors.accentBlue,
                onChanged: (v) => draft(build(v)),
                onChangeEnd: (v) => commit(build(v)),
              ),
            ),
          ),
          SizedBox(
              width: 42,
              child: Text(trailing,
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                      fontSize: AppFontSize.micro,
                      color: AppColors.textTertiary,
                      fontFeatures: [FontFeature.tabularFigures()]))),
        ]);

    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Text('第 ${index + 1} 句的字幕',
              style: const TextStyle(
                  fontSize: AppFontSize.micro,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textSecondary)),
          const Spacer(),
          if (line.subtitleOverride != null) ...[
            InkWell(
              key: const ValueKey('subtitle-bar-reset'),
              onTap: () =>
                  _mutate((d) => d.setSubtitleOverrideById(line.id, null),
                      affectsTracks: false),
              child: const Text('跟随整片',
                  style: TextStyle(
                      fontSize: AppFontSize.micro,
                      color: AppColors.textTertiary)),
            ),
            const SizedBox(width: AppSpacing.sm),
          ],
          InkWell(
            key: const ValueKey('subtitle-bar-apply-all'),
            onTap: () => _mutate((d) =>
                d.withSubtitle(style).setSubtitleOverrideById(line.id, null)),
            child: const Text('应用到整片',
                style: TextStyle(
                    fontSize: AppFontSize.micro,
                    color: AppColors.accentBlueLight)),
          ),
        ]),
        slider(
          label: '位置',
          key: const ValueKey('subtitle-bar-bottom'),
          value: style.bottomRatio,
          min: 0.03,
          max: 0.6,
          trailing: '${(style.bottomRatio * 100).round()}%',
          build: (v) => style.copyWith(bottomRatio: v),
        ),
        slider(
          label: '字号',
          key: const ValueKey('subtitle-bar-font'),
          value: style.fontRatio,
          min: 0.018,
          max: 0.065,
          trailing: '${(style.fontRatio * 1000).round()}‰',
          build: (v) => style.copyWith(fontRatio: v),
        ),
        Row(children: [
          for (final (hex, name) in subtitleColors)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Tooltip(
                message: name,
                child: InkWell(
                  key: ValueKey('subtitle-bar-color-$hex'),
                  onTap: () => commit(style.copyWith(
                      colorHex: hex == 'FFFFFF' ? null : hex)),
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  child: Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color(int.parse('FF$hex', radix: 16)),
                      border: Border.all(
                          color: (style.colorHex ?? 'FFFFFF') == hex
                              ? AppColors.accentBlue
                              : AppColors.border,
                          width: (style.colorHex ?? 'FFFFFF') == hex ? 2 : 1),
                    ),
                  ),
                ),
              ),
            ),
          const SizedBox(width: AppSpacing.xs),
          for (final (preset, label) in const [
            (SubtitlePreset.whiteOutline, '无底'),
            (SubtitlePreset.blurBox, '毛玻璃'),
            (SubtitlePreset.whiteBox, '黑条'),
          ])
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: InkWell(
                key: ValueKey('subtitle-bar-mask-${preset.name}'),
                onTap: () => commit(style.copyWith(preset: preset)),
                borderRadius: BorderRadius.circular(AppRadius.pill),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: style.preset == preset
                        ? AppColors.accentBlue.withValues(alpha: 0.16)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    border: Border.all(
                        color: style.preset == preset
                            ? AppColors.accentBlue
                            : AppColors.border),
                  ),
                  child: Text(label,
                      style: TextStyle(
                          fontSize: AppFontSize.micro,
                          color: style.preset == preset
                              ? AppColors.accentBlueLight
                              : AppColors.textSecondary)),
                ),
              ),
            ),
        ]),
      ]),
    );
  }

  /// 当前播放行的字幕：按镜头边界与词级时间戳切段（与导出同一套规则）
  /// ——「家人们」只在第一镜出现，后半句归后面的镜头。画面行没台词不出。
  /// 字幕本身可操作：点一下改样式，上下拖直接调位置
  Widget _previewSubtitle() {
    final index = _previewLineIndex;
    if (index == null || index < 0 || index >= _doc.lines.length) {
      return const SizedBox.shrink();
    }
    final line = _doc.lines[index];
    if (line.type != ScriptLineType.voiced) return const SizedBox.shrink();
    final lineStart = _planResult.lineStarts[index] ?? 0;
    final relMs = _positionMs.value - lineStart;
    // 字幕屏：切点跟语言走，与镜头无关；每屏字数按**生效样式**的字号推，
    // 与镜头卡、卡上播放、成片导出取的是同一份派生
    final seg = line
        .subtitleScreensAt(maxChars: _styleOf(line).maxCharsPerScreen)
        .where((s) => relMs >= s.startMs && relMs < s.endMs)
        .firstOrNull;
    final text = seg?.text ?? '';
    if (text.isEmpty) return const SizedBox.shrink();
    final style = _styleOf(line);
    return PreviewSubtitle(
      text: text,
      style: style,
      // 点字幕 = 选中这一句（样式调整在预览正下方的工具条里，
      // 不再用弹窗盖住预览）
      onTap: () => _focusLine(index),
      onDragRatio: (ratio) =>
          setState(() => _subtitleDragRatio = ratio),
      onDragEnd: (ratio) {
        _subtitleDragRatio = null;
        // 样式粒度 = 句：拖字幕改的就是这一句
        _mutate(affectsTracks: false, (d) => d.setSubtitleOverrideById(
            line.id, style.copyWith(bottomRatio: ratio)));
      },
      dragRatio: _subtitleDragRatio,
    );
  }

  /// 未进预览的交代：**先按原因归堆**，同一个原因下的行号并成区间。
  ///
  /// 原来是「不超过 4 行就逐条点名」——于是四行台词都没配音时，屏幕上是
  /// 四条一模一样的橙字，只有行号不同（2026-09-09 设计走查真机截图）。
  /// 该省的从来不是行号，是**重复的那句原因**。
  String _skippedSummary() => summarizeSkippedLines(_planResult.skippedLines);

  static String _mmss(int ms) {
    final s = ms ~/ 1000;
    return '${(s ~/ 60).toString().padLeft(2, '0')}:'
        '${(s % 60).toString().padLeft(2, '0')}';
  }

  Widget _blockedView() => Scaffold(
        backgroundColor: AppColors.background,
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('「$_blockedBy」正在处理这个任务',
                style: const TextStyle(
                    fontSize: AppFontSize.title,
                    color: AppColors.textPrimary)),
            const SizedBox(height: AppSpacing.sm),
            const Text('等它结束再进（谁先进谁处理）',
                style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: AppFontSize.caption)),
            const SizedBox(height: AppSpacing.lg),
            Row(mainAxisSize: MainAxisSize.min, children: [
              OutlinedButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: const Text('返回')),
              const SizedBox(width: AppSpacing.sm),
              FilledButton(
                  onPressed: _forceTakeover, child: const Text('强制接管')),
            ]),
          ]),
        ),
      );
}

/// 导出进度对话框：一段一报，不许点掉——导出中改内容不会进这一版成片
/// 编导台的进度框。**壳而已**——实现在 [LongTaskDialog]，两个工作页共用一份。
/// 保留这层壳是为了不动这里十几处调用点。
class _ExportProgressDialog extends StatelessWidget {
  final ValueListenable<ScriptExportProgress?> progress;
  final String title;

  const _ExportProgressDialog(
      {required this.progress, this.title = '正在导出成片'});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
        valueListenable: progress,
        builder: (_, value, _) => LongTaskDialog(
          title: title,
          progress: ValueNotifier(
              value == null ? null : LongTaskProgress(value.step, value.fraction)),
        ),
      );
}


/// 参考段小窗：循环播这一句在参考片里的区间。
/// 用独立的 mpv 实例——试听不该动主预览的位置
class _SublineCutDialog extends StatefulWidget {
  final String text;
  final int suggest;

  const _SublineCutDialog({required this.text, required this.suggest});

  @override
  State<_SublineCutDialog> createState() => _SublineCutDialogState();
}

class _SublineCutDialogState extends State<_SublineCutDialog> {
  late int _cut = widget.suggest.clamp(1, widget.text.length - 1);

  @override
  Widget build(BuildContext context) => AlertDialog(
        backgroundColor: AppColors.surfaceRaised,
        title: const Text('这段台词从哪里分开？',
            style: TextStyle(fontSize: AppFontSize.title)),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('点一个字，从它前面切开——前半段归上面的镜头组，'
                '后半段归下面的',
                style: TextStyle(
                    fontSize: AppFontSize.caption,
                    color: AppColors.textSecondary)),
            const SizedBox(height: AppSpacing.md),
            Wrap(spacing: 0, runSpacing: 4, children: [
              for (var i = 0; i < widget.text.length; i++)
                InkWell(
                  key: ValueKey('subline-char-$i'),
                  onTap: i == 0 ? null : () => setState(() => _cut = i),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 1, vertical: 2),
                    decoration: BoxDecoration(
                      border: Border(
                          left: BorderSide(
                              color: i == _cut
                                  ? AppColors.accentBlue
                                  : Colors.transparent,
                              width: 2)),
                      color: i >= _cut
                          ? AppColors.accentBlue.withValues(alpha: 0.10)
                          : Colors.transparent,
                    ),
                    child: Text(widget.text[i],
                        style: const TextStyle(
                            fontSize: AppFontSize.emphasis,
                            height: 1.5,
                            color: AppColors.textPrimary)),
                  ),
                ),
            ]),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消')),
          FilledButton(
            key: const ValueKey('subline-cut-ok'),
            onPressed: () => Navigator.of(context).pop(_cut),
            child: const Text('就这样分'),
          ),
        ],
      );
}
