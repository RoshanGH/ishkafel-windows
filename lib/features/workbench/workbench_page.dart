import 'dart:convert';
import '../../core/subtitle/subtitle_style.dart';
import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../app/theme/app_colors.dart';
import '../../core/analysis/audio_extractor.dart';
import '../../core/analysis/tag_merge.dart';
import '../../core/audio/material_audio.dart';
import '../../core/audio/source_audio.dart';
import '../director/tag_picker.dart';
import '../tasks/new_task_wizard/wizard_providers.dart';
import '../../core/analysis/handpicked_tags.dart';
import '../../core/subtitle/subtitle_track.dart';
import '../../core/subtitle/preview_subtitle_at.dart';
import '../../core/export/composed_timeline.dart';
import '../../core/export/export_file_name.dart';
import '../../core/subtitle/slot_subtitles.dart';
import '../../core/subtitle/subtitle_overlay.dart';
import '../../core/editing/edit_locks.dart';
import '../../core/editing/blank_unit_ops.dart';
import '../../core/review/review_receipt.dart';
import '../review/review_page.dart';
import '../../core/editing/blank_unit_removal.dart';
import '../../core/editing/base_pin_ops.dart';
import '../../core/replacement/unit_base.dart';
import 'base_segment_card.dart';
import 'base_pin_dialogs.dart';
import '../blank_task/blank_unit_tag_editor.dart';
import '../../core/editing/segmentation_edit_ops.dart';
import '../../core/editing/segmentation_editor_controller.dart';
import '../../core/editing/unit_reorder.dart';
import '../../core/ffmpeg/thumbnail_service.dart';
import '../../core/ai/ai_usage_scope.dart';
import '../../core/audio/voice_swap_service.dart';
import '../../core/log/app_log.dart';
import '../../core/models/export_record.dart';
import '../../core/models/renew_task.dart';
import '../../core/platform/platform_paths.dart';
import '../../core/presentation/user_facing_error.dart';
import '../../core/net/http_bytes.dart';
import '../../core/miaoa/candidate_probe.dart';
import '../../core/miaoa/miaoa_content_service.dart';
import '../../core/miaoa/miaoa_tag_service.dart';
import '../../core/models/semantic_unit.dart';
import '../../core/models/tag_group_ref.dart';
import '../../core/playback/gap_clip.dart';
import '../../core/playback/silent_clip.dart';
import '../../core/playback/media_kit_playback.dart';
import '../../core/playback/noop_playback_controller.dart';
import '../../core/playback/playback_controller.dart';
import '../../core/ffmpeg/ffprobe_service.dart';
import '../../core/ffmpeg/process_runner.dart';
import '../../core/ffmpeg/proxy_builder.dart';
import '../../core/ffmpeg/proxy_spec.dart';
import '../../core/ffmpeg/rendered_cache.dart';
import '../../core/playback/media_kit_follower.dart';
import '../../core/playback/multitrack_playback.dart';
import 'preview_tracks.dart';
import 'speed_fitter.dart';

import '../../core/replacement/picked_material.dart';
import '../../core/replacement/replacement_plan.dart';
import '../../core/editing/edit_consequence.dart';
import '../picking/picking_messages.dart';
import '../settings/settings_providers.dart';
import '../tasks/task_list_controller.dart';
import '../../core/audio/audio_preview.dart';
import '../../core/audio/bgm_plan.dart';
import '../../core/audio/vocal_separator.dart';
import 'bgm_picker_sheet.dart';
import 'candidate_badge.dart';
import 'voice_picker_sheet.dart';
import 'voice_swap_runner.dart';
import 'timeline/bgm_track.dart';
import 'candidate_tab.dart';
import '../picking/picked_material_store.dart';
import '../picking/picked_media_cache.dart';
import '../picking/picking_providers.dart';
import 'edit_consequence_dialog.dart';
import 'task_tag_groups_dialog.dart';
import 'timeline/timeline_painter.dart';
import 'timeline_media_builder.dart';
import 'workbench_body.dart';
import 'workbench_chrome.dart';
import 'workbench_summary.dart';
import '../export/export_dialog.dart';
import '../export/default_export_directory.dart';
import '../../core/storage/agent_presence.dart';
import '../../core/jianying/jianying_plan.dart' show JianyingPlanException;
import '../../core/jianying/jianying_writer.dart';
import '../../core/platform/platform_shell.dart';
import '../../core/jianying/renew_jianying_plan.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import 'agent_focus_request.dart';
import '../../core/replacement/brand_consistency.dart';
import '../picking/burned_text_warning.dart';
import 'serve_broadcast.dart';
import '../../cli/plan_submission.dart';
import '../agent/visual_pace.dart';
import '../shared/long_task_dialog.dart';
import '../shared/subtitle_style_sheet.dart';
import '../../core/storage/agent_request.dart';
import '../../core/storage/ui_action.dart';
import '../../core/storage/task_lock.dart';
import '../../core/storage/task_artifacts.dart';
import '../../core/storage/task_media.dart';
import 'task_lock_banner.dart';
import 'subtitle_popover.dart';

/// 审片台阶段一页面：三栏（单元列表/播放器/检查器）+ 时间线 + 顶栏/底部栏组装
///
/// 装配决策：
/// - [playbackFactory] 缺省时构造真实 `MediaKitPlaybackController`；测试注入
///   [FakePlaybackController]，避免单测触碰 libmpv。构造过程若抛出
///   **`Exception`**（生产环境理论上不会——`main.dart` 已在 `runApp` 前
///   调用 `MediaKit.ensureInitialized()`；但万一某台机器缺/坏 libmpv 动态
///   库，或测试刻意注入一个会抛错的工厂），会被捕获并降级为
///   [NoopPlaybackController]，同时置顶一条**用户可见**的橙色提示条
///   （见 [_playbackDegraded]），而不是静默显示占位图标却毫无说明；`Error`
///   子类（编程错误，如 `ArgumentError`/`StateError`）不在捕获范围内，会
///   继续抛出，不被这里误吞。
/// - [mediaBuilder] 缺省时构造真实 [TimelineMediaBuilder]（真实 ffmpeg 抽帧/波形），
///   工作目录复用与 `AnalysisPipeline` 一致的 `ishkafel_data/analysis_work`；
///   测试注入假 builder 时改用一次性临时目录（不复用生产缓存位置），避免测试
///   之间因缓存文件互相污染。
/// - `task.units == null`（或非空白任务而 `videoInfo == null`）时不组装
///   编辑器/播放器，
///   仅渲染错误占位（路由层已按状态拦截，这里是纵深防御，防止极端脏数据崩溃）。
/// - 三栏 + 时间线的实际布局、页面级全局播放快捷键（空格/←/→）都下沉到
///   [WorkbenchBody]（独立 StatefulWidget，见该文件文档）；本类只负责装配
///   编辑器/播放器/媒体这几项跨区域共享的状态，以及顶栏/底部栏/确认流转/
///   离开确认这些与"三栏内部展示细节"无关的页面级职责。
class WorkbenchPage extends ConsumerStatefulWidget {
  final RenewTask task;
  final PlaybackController Function()? playbackFactory;
  final TimelineMediaBuilder? mediaBuilder;

  /// 时间线判定双击用的时钟。默认真实时间；测试注入可控时钟，否则机器一忙
  /// 两次点击的间隔就超过双击窗口，用例随机变红。
  final DateTime Function()? clock;

  /// 右栏「替换素材」的依赖，缺省走真实 miaoa CLI；测试注入假实现
  /// 把挑中的素材落到盘上（下首帧图）。为空表示不落地——托盘仍然能画，
  /// 只是重开 app 之后要现拉
  final PickedMaterialStore? pickedStore;

  final MiaoaContentService? contentService;
  final CandidateProbe? candidateProbe;
  final MiaoaTagService? tagService;

  /// 「生成配音」的装配点。缺省读 [voiceSwapFactoryProvider]（凭据齐才有）；
  /// 测试注入假实现，避免单测真去跑云端合成。
  final VoiceSwapFactory? voiceSwapFactory;

  /// 试听配音用的播放器。缺省懒创建真实的；测试注入假实现，
  /// 免得单测去碰 libmpv。
  final AudioPreview? audioPreview;

  const WorkbenchPage({
    super.key,
    required this.task,
    this.playbackFactory,
    this.mediaBuilder,
    this.clock,
    this.pickedStore,
    this.contentService,
    this.candidateProbe,
    this.tagService,
    this.voiceSwapFactory,
    this.audioPreview,
  });

  @override
  ConsumerState<WorkbenchPage> createState() => _WorkbenchPageState();
}

class _WorkbenchPageState extends ConsumerState<WorkbenchPage> {
  SegmentationEditorController? _editor;
  PlaybackController? _playback;
  Widget? _videoWidget;
  TimelineMedia? _media;

  /// 抽帧/波形是否构建失败。与 `_media == null` 一起决定时间线两条辅助轨
  /// 显示「生成中…」还是「生成失败」——此前失败只写日志，界面上是一片
  /// 空白，用户无从判断是在算还是坏了。
  bool _mediaFailed = false;
  StreamSubscription<int>? _positionSub;

  /// 播放位置。用 [ValueNotifier] 而不是 State 字段：播放时这个值每秒变化
  /// 30 次，而它唯一的消费者是时间线上那条 2px 的播放头线。若走 `setState`，
  /// 每次 tick 都会连带重建左栏单元列表、播放器、右栏检查器与底部栏——
  /// 实测每 tick 净开销 10~12ms，占满 60fps 预算的七成，播放与拖拽因此发顿。
  final ValueNotifier<int> _playhead = ValueNotifier<int>(0);

  /// 留着引用只为离开时 [SpeedFitter.prune] 一次
  SpeedFitter? _speedFitter;

  /// 别人（多半是 Agent）持有的锁；为 null 表示没人占着
  TaskLock? _lock;
  Timer? _lockTimer;

  /// Agent 此刻在不在、在动哪个单元。**这套跟随是全软件共用的**：
  /// 同一份在场状态，编导台按行滚、这里按单元把播放头挪过去——
  /// 各模块只负责「我怎么把那个位置摆到眼前」，不各造一套协议
  AgentPresence? _agent;
  Timer? _agentPoll;

  /// 锁文件。**在 initState 里就存下来**：dispose 时要放锁，而那时候
  /// 已经不能再碰 ref（Riverpod 会抛 "Cannot use ref after disposed"）
  TaskLockFile? _lockFile;

  /// 本进程的身份。横幅上要能说出是谁占着，所以带上 pid
  String get _lockHolder => 'gui:$pid';

  /// 占住锁并盯着它。
  ///
  /// **进工作台就占锁**：人正在编辑而 Agent 同时在写，后写的会把先写的覆盖
  /// 掉。两个方向都要防，不能只防 Agent 那一边。
  ///
  /// 每 5 秒一轮：既给自己的锁续命，也看看是不是被别人抢了。这个间隔比 60 秒
  /// 的失效阈值密得多——对方一结束或一崩掉，很快就能恢复可编辑，而不是让人
  /// 干等一分钟；自己这把锁也不会因为一次卡顿就过期。
  void _watchLock() {
    final dataDir = ref.read(dataDirProvider);
    if (dataDir == null) return;
    final file = TaskLockFile(dataDir: dataDir, taskId: widget.task.id);
    _lockFile = file;

    void poll() {
      // 先试着占住/续命。占不到说明别人正持着，那就进只读
      final mine = file.heartbeat(_lockHolder) || file.acquire(_lockHolder);
      final current = mine ? null : file.read();
      final held = current != null &&
          current.holder != _lockHolder &&
          // 带上进程存在性：写锁的 app 已经退了的话，不用干等心跳超时
          !current.isStale(DateTime.now().toUtc(),
              processAlive: isProcessAlive);
      final next = held ? current : null;
      if (next?.holder == _lock?.holder) return;
      if (mounted) setState(() => _lock = next);
    }

    poll();
    _lockTimer = Timer.periodic(const Duration(seconds: 5), (_) => poll());
  }

  /// 订阅 Agent 的在场状态，跟着它走：它看哪个单元，就把播放头挪过去。
  /// 展示完这一帧再回执——Agent 靠它决定什么时候走下一步（不猜时间）
  void _watchAgent() {
    _agentPoll?.cancel();
    _agentPoll = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      final dataDir = ref.read(dataDirProvider);
      if (dataDir == null) return;
      // Agent 请这一页代办的事（提交方案）。**界面占着锁不是冲突，
      // 是委派的时机**：可视模式要求界面停在这个任务上，而写入要求界面
      // 不能停在这个任务上——请界面去做，人就能眼看着方案落到时间线上
      unawaited(_serveAgentRequest(dataDir));
      final now =
          readAgentPresence(dataDir: dataDir, taskId: widget.task.id);
      final was = _agent;
      // 连镜头和面板一起比：以前只比单元，Agent 从 U3S2 挪到 U3S5
      // 界面一动不动——人看到的是「它卡住了」
      if (was?.action == now?.action &&
          was?.focus?.unitIndex == now?.focus?.unitIndex &&
          was?.focus?.shotIndex == now?.focus?.shotIndex &&
          was?.focus?.panel == now?.focus?.panel &&
          (was == null) == (now == null)) {
        return;
      }
      setState(() => _agent = now);
      final unit = now?.focus?.unitIndex;
      if (unit != null) _seekToUnit(unit);
      if (now != null && now.step > 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          // 停够再回执：这个值与播报条共用一份（见 visualPace），
      // 各定各的话谁先回执 Agent 就走，另一头整步扑空
      Future<void>.delayed(visualStepDwell, () {
            if (!mounted) return;
            writeAgentAck(
                dataDir: dataDir, taskId: widget.task.id, step: now.step);
          });
        });
      }
    });
  }

  /// Agent 这一步要界面跟到哪儿。null = 没人在跟。
  ///
  /// **「该不该切到候选面板」在这儿判一次**：`findShots` 是人点「添加分镜」
  /// 弹出来的那个面板，Agent 挑素材时报的就是它——切过去人才看得见它在挑
  /// 什么，而不是只看到播放头跳一下
  AgentFocusRequest? get _agentFocusRequest {
    final focus = _agent?.focus;
    if (_agent == null || focus == null) return null;
    return AgentFocusRequest(
      step: _agent!.step,
      unitIndex: focus.unitIndex,
      shotIndex: focus.shotIndex,
      wantsCandidates: focus.panel == AgentPanel.findShots,
    );
  }

  /// 正在处理代办，防重入
  bool _servingRequest = false;

  /// 代为提交方案：**校验和投影复用 CLI 那一份**（`plan_submission`），
  /// 不另写一套——两份实现迟早对不上，而这一步定的是成片长什么样。
  ///
  /// 做完把方案投影到界面上：人眼看着三条方案落到时间线，这正是
  /// 「界面占着锁」时最该发生的事。
  Future<void> _applyPlansFromAgent(
    String raw,
    void Function(bool ok, String message, {Map<String, dynamic> payload})
        reply, {
    List<PickedMaterial> picked = const [],
  }) async {
    final editor = _editor;
    if (editor == null) {
      reply(false, '这一页还没准备好');
      return;
    }
    // **过程要说出来**：活儿是界面干的、CLI 在那头等着，没人报在场状态的话
    // 播报条一片空白——而 CLI 打印的是「人能看着方案落进去」。
    // 验收 Agent 密拍 40 帧确认过：一帧播报都没有，那句话没兑现
    final dataDir = ref.read(dataDirProvider);
    final voice = dataDir == null
        ? null
        : ServeBroadcast(dataDir: dataDir, taskId: widget.task.id);
    try {
      await voice?.sayAndHold('正在核对 Agent 提交的方案');
      final Object? decoded;
      try {
        decoded = jsonDecode(raw);
      } catch (e) {
        reply(false, userFacingError(e, fallback: '方案不是合法的 JSON'));
        return;
      }
      final validation = parsePlans(decoded, _task);
      if (!validation.ok) {
        // 校验不过要原样转达：Agent 得知道是哪一条不合格，而不是「失败了」
        voice?.say('方案没通过校验，没有改动任何东西');
        reply(false, validation.errors.join('；'));
        return;
      }
      final replacements =
          projectPlansToReplacements(validation.plans, _task.units ?? const []);
      // 素材连同时长（取段靠它）和画面自查结果一起收下——不存的话，
      // 委派这条路上取段全失效、烧字和品牌问题一个都报不出来
      if (picked.isNotEmpty) {
        _task = _task.copyWith(pickedMaterials: picked);
      }
      await voice?.sayAndHold(
          '${validation.plans.length} 条方案通过校验，正在投影到时间线',
          focus: const AgentFocus(module: 'workbench'));
      setState(() => _replacements = replacements);
      _task = _task.copyWith(replacementsByUid: _byUid(replacements));
      await _tasks!.savePickingPlan(_task, replacements);
      await voice?.sayAndHold(
          '投影完了：${replacements.length} 个单元的替换已经落在时间线上',
          focus: const AgentFocus(module: 'workbench'));
      // **会毁掉整片的两件事要当场说出来**：素材画面上烧着别家的字
      // （成片两层字幕）、画面里露的是竞品（台词说的和画面里摆的对不上）。
      // 不说的话，人看到的是「一切正常，方案落好了」——而那两件事只有
      // 看图才发现得了，等他自己去托盘上一条条翻是不现实的
      await _warnAboutPickedMaterials(voice);
      reply(true, '方案已经投影到界面上了', payload: {
        'plans': validation.plans.length,
        'units': replacements.length,
      });
    } finally {
      // 撤场：不撤的话界面永远停在只读态，人得等心跳超时才能自己动手
      voice?.done();
    }
  }

  /// Agent 请我们把导出对话框打开、参数填好。
  ///
  /// 和提交方案的区别：那件事做完就是做完了，这件事**故意停在人手上**——
  /// 导出跑几分钟、直接产出要交付的片子、而且花钱。界面占着锁说明人正在
  /// 旁边看着，最后那一下让他自己点才对。
  Future<void> _openExportForAgent(
    AgentRequest req,
    void Function(bool ok, String message, {Map<String, dynamic> payload})
        reply,
  ) async {
    if (_editor == null) {
      reply(false, '这一页还没准备好');
      return;
    }
    final dataDir = ref.read(dataDirProvider);
    final voice = dataDir == null
        ? null
        : ServeBroadcast(dataDir: dataDir, taskId: widget.task.id);
    try {
      await voice?.sayAndHold('正在打开导出，参数按 Agent 给的填',
          focus: const AgentFocus(module: 'workbench'));
      // 回执要在对话框打开之前发：对话框会一直开着等人点，
      // 等它关掉才回执的话，Agent 那头会先超时
      reply(true, '导出对话框已经打开、参数填好了，等用户点「开始导出」');
      await voice?.sayAndHold('导出对话框开着了——最后那一下请你点',
          focus: const AgentFocus(module: 'workbench'));
      voice?.done();
      if (mounted) await _openExport();
    } catch (e) {
      AppLog.warn('代为打开导出失败（${widget.task.id}）：$e');
      voice?.done();
    }
  }

  /// 把「会毁掉整片」的发现当场播报出来。
  ///
  /// 播报条一行就那么宽，这里只说一句「出了什么事、多严重」；细节在托盘
  /// 胶囊和导出确认页上，人要细看就去那儿。
  Future<void> _warnAboutPickedMaterials(ServeBroadcast? voice) async {
    if (voice == null) return;
    final picked = _task.pickedMaterials;
    if (burnedTextBroadcastLine(picked) case final line?) {
      await voice.warnAndHold(line);
    }
    if (brandBroadcastLine(
            picked: picked, sourceBrand: sourceBrandOf(_task.units ?? const []))
        case final line?) {
      await voice.warnAndHold(line);
    }
  }

  /// 接住 Agent 的代办并**真的去做**。做的和人自己点是同一件事，
  /// 不另造一套只读展示——那样人看到的动作和自己操作时不一样，反而更不放心。
  Future<void> _serveAgentRequest(Directory dataDir) async {
    if (_servingRequest) return;
    final req = consumeAgentRequest(dataDir: dataDir, taskId: widget.task.id);
    if (req == null) return;
    _servingRequest = true;
    void reply(bool ok, String message,
            {Map<String, dynamic> payload = const {}}) =>
        writeAgentRequestResult(
            dataDir: dataDir,
            taskId: widget.task.id,
            id: req.id,
            ok: ok,
            message: message,
            payload: payload);
    try {
      switch (UiAction.parse(req.kind)) {
        case UiAction.plansApply:
          break;
        case UiAction.exportOpen:
          // **只打开、填好，不替人点导出**：导出跑几分钟、直接出交付物、
          // 还花钱。人正在旁边看着（不然界面不会占着锁），
          // 最后那一下让他自己点才对
          await _openExportForAgent(req, reply);
          return;
        default:
          reply(false, '这一页接不了这个动作：${req.kind}');
          return;
      }
      await _applyPlansFromAgent(
        '${req.payload['raw'] ?? ''}',
        reply,
        // 素材是命令行那头收好递过来的（探时长要 ffprobe、看画面要 AI
        // 凭据，都在那一边）。界面只负责存下来并把结果摆给人看
        picked: PickedMaterial.parseList(req.payload['pickedMaterials']),
      );
    } catch (e) {
      AppLog.warn('代为提交方案失败（${widget.task.id}）：$e');
      reply(false, userFacingError(e, fallback: '提交失败，请稍后重试'));
    } finally {
      _servingRequest = false;
    }
  }

  /// 把播放头挪到第 [index] 个单元的起点——工作台是时间线式的，
  /// 「看某个单元」就是把指针放到那儿
  void _seekToUnit(int index) {
    final units = _editor?.units ?? const [];
    if (index < 0 || index >= units.length) return;
    _playhead.value = units[index].startMs;
  }

  /// 离开工作台就放锁——不放的话，别人要等 60 秒超时才能接手
  void _releaseLock() => _lockFile?.release(_lockHolder);

  void _takeoverLock() {
    final dataDir = ref.read(dataDirProvider);
    if (dataDir == null) return;
    TaskLockFile(dataDir: dataDir, taskId: widget.task.id)
        .forceTakeover(_lockHolder);
    setState(() => _lock = null);
  }

  /// 上一次向 UI 反映的 dirty 值。编辑器每次 notify 都会走 [_onEditorChanged]，
  /// 但页面本身只有 [PopScope.canPop] 依赖 dirty，只在它真正翻转时才需要重建。
  bool _lastDirty = false;

  /// 自动落库的防抖计时器。拖一次边界会触发几十次编辑，逐次写盘既浪费
  /// 又会在连续拖动时排成一长串写入。
  Timer? _autosaveTimer;

  /// 最近一次已落库的 units。真的变了才写——undo 回到原样、或只是切换选中，
  /// 都不该产生一次写盘。
  List<SemanticUnit>? _savedUnits;

  /// 当前替换方案。右栏改一次就落库一次，与切分改动同一条自动保存通路。
  List<UnitReplacement>? _replacements;

  /// 「改完之后要不要连坐」的询问计时器与结算基线。基线是上一次结算时的
  /// units：只问这之后的新改动，否则用户每改一次都会被翻旧账。
  Timer? _consequenceTimer;
  List<SemanticUnit>? _consequenceBaseline;
  bool _askingConsequence = false;

  /// 正在重新打标。要走两趟云端推理，几秒到几十秒，界面上必须有个说法，
  /// 否则用户会以为点了「是」什么都没发生。
  int _retaggingCount = 0;

  /// 配音生成进度。每句要走一次音频理解 + 一到两次合成，十句就是一分多钟，
  /// 没有进度用户只会以为卡死了。
  (int done, int total)? _voiceProgress;

  /// 已经生成好的配音文件，按台词语义单元下标。有文件才给试听按钮——
  /// 给一个点了没声音的按钮比不给还糟。
  Map<String, String> _voiceAudio = const {};

  /// 试听用的独立播放器：时间线那个正播着原片，不能把它的位置弄丢
  AudioPreview? _preview;

  /// 预览音轨：让工作台里听到的就是导出后的声音（配音替换 + 配乐叠加）
  PreviewTracks? _tracks;

  /// 任务列表控制器。在 initState 里就抓住：dispose 时 `ref` 已经失效，
  /// 而离开页面时那次补写恰恰发生在 dispose 里。
  TaskListController? _tasks;

  /// 这条任务的最新状态。
  ///
  /// **不能拿 `widget.task` 去存**：切分和替换方案走两条落库通路，两边都
  /// 从同一个进页面时的旧快照 copyWith，后写的那次就会把前一次的改动整个
  /// 盖回去——清掉素材再标记重打，素材又活过来了。
  late RenewTask _task = widget.task;

  /// 播放后端是否已降级为 [NoopPlaybackController]（构造真实播放器失败）；
  /// true 时页面顶部常驻一条用户可见的提示条，而不是静默显示占位图标
  bool _playbackDegraded = false;

  /// 项目**永远可编辑**。
  ///
  /// 一条原片放在那儿反复出不同组合：今天挑两个导出去，明天换两个再导。
  /// 没有「导完就锁住」这回事——那个 `exported` 状态从来没有一处代码把它
  /// 设上过，只读回看整套逻辑一直是死的。
  bool get _isEditable => true;

  @override
  void initState() {
    super.initState();
    _tasks = ref.read(taskListProvider.notifier);
    _mediaCache = _buildMediaCache();
    _bgmMediaCache = _buildBgmMediaCache()?..addListener(_onMediaCacheChanged);
    _mediaCache?.addListener(_onMediaCacheChanged);
    final task = widget.task;
    final units = task.units;
    final videoInfo = task.videoInfo;
    // 空白任务没有原片，也就没有 videoInfo。它进的是同一个工作台——
    // 时间线、配乐、矩阵导出这些能力跟有没有原片无关，另起一页会把它们全丢掉
    if (units == null || (videoInfo == null && !task.isBlank)) {
      return; // 兜底：路由层已拦截，此处只防御极端脏数据
    }

    final editor = SegmentationEditorController(
      initialUnits: units,
      // 空白任务的总长由分子加出来（没挑素材的按占位长度算）
      durationMs: videoInfo?.duration.inMilliseconds ??
          (units.isEmpty ? BlankUnitOps.placeholderMs : units.last.endMs),
      // 没有原片就没有原片帧率。30 只是内部坐标的刻度——成片规格跟素材走
      fps: videoInfo?.fps ?? 30,
      sentences: task.asrSentences ?? const [],
    );
    editor.addListener(_onEditorChanged);
    _editor = editor;
    _replacements = task.replacementsFor(units);
    _syncEditLocks();
    _pinMaterials();
    _consequenceBaseline = units;
    // 进工作台就把方案里的配乐固定住——只在「选完」时才下的话，
    // 打开一条早就配好乐的任务什么都不会发生
    _pinBgm();
    // 素材已经在本地、但落地记录里缺时长的，补一次（整体替换靠它算长度）
    unawaited(_backfillDurations());

    final playback = _resolvePlayback();
    _playback = playback;
    _videoWidget = switch (playback) {
      MultitrackPlayback() => playback.buildVideoWidget(),
      MediaKitPlaybackController() => playback.buildVideoWidget(),
      _ => null,
    };
    // 只更新 notifier，不触发页面重建；重复值直接丢弃（mpv 会重复上报同一毫秒）
    _positionSub = playback.positionMsStream.listen((ms) {
      if (!mounted) return;
      // 预览播的可能是**合成出来的成片**（整体替换会改变时长），而时间线画的
      // 是原片切分——播放头要换算回原片时刻，否则整体替换之后指针就飘了
      // 时间线现在画的就是成片，播放头直接用播放器位置——不必再换算回
      // 原片时刻（那一步在整体替换段上是按比例估的，本来就不精确）
      // **先判「这一段能不能放」，再做去重**：播放头本来就停在 0，而 0 可能
      // 正落在放不了的那一段里（手加的单元拖到最前就是这样）。放在去重后面
      // 的话，mpv 上报的还是 0、被当成重复丢掉，人点了播放只看到停住、
      // 没有任何解释（2026-09-08 自测时踩到）
      _stopAtUnplayable(ms, playback);
      if (_playhead.value == ms) return;
      _playhead.value = ms;
    });
    // 空白任务没有原片可开。画面全部来自素材，等轨道推上去自然就有内容了
    if (task.sourcePath case final source?) {
      unawaited(_openSource(playback, source));
    }
    unawaited(_loadMedia());
    _restoreVoiceAudio();

    if (playback is MultitrackPlayback) {
      _tracks = PreviewTracks(
        playback: playback,
        separateMaterial: switch (ref.read(materialSeparatorProvider)) {
          final f? => (path) => f(_task.id, path),
          _ => null,
        },
        materials: _mediaCache,
        bgmMedia: _bgmMediaCache,
        speedFitter: _speedFitter = _buildSpeedFitter(),
        gapClip: _buildGapClip(),
        silentClip: _buildSilentClip(),
      )
        ..addListener(_onTracksChanged)
        ..onNeedsRebuild = _syncPreviewAudio;
      // 后台转原片代理，转好了自动换上；这期间先播原片
      unawaited(_buildSourceProxy());
    }
    _syncPreviewAudio();
    _watchLock();
    _watchAgent();
  }

  /// 给「还没挑素材」的那几段垫黑场的渲染器。没有数据目录（测试环境）
  /// 就不垫——那时照旧留洞，Edl 会打警告
  GapClip? _buildGapClip() {
    final dataDir = ref.read(dataDirProvider);
    if (dataDir == null) return null;
    return GapClip(RenderedCache(
      dir: Directory(p.join(dataDir.path, 'gap_clip', widget.task.id)),
      run: const ResolvingProcessRunner().call,
    ));
  }

  /// 给「原片这一镜的声音 = 不播放」的那几镜垫静音的渲染器。
  /// 没有数据目录（测试环境）就不垫，那时预览退回原声
  SilentClip? _buildSilentClip() {
    final dataDir = ref.read(dataDirProvider);
    if (dataDir == null) return null;
    return SilentClip(RenderedCache(
      dir: Directory(p.join(dataDir.path, 'silent_clip', widget.task.id)),
      run: const ResolvingProcessRunner().call,
    ));
  }

  /// 变速切片的渲染器。没有数据目录（测试环境）就不做变速——
  /// 那一段先播原片，其余照旧
  SpeedFitter? _buildSpeedFitter() {
    final dataDir = ref.read(dataDirProvider);
    if (dataDir == null) return null;
    return SpeedFitter(
      cache: RenderedCache(
        dir: Directory(p.join(dataDir.path, 'speed_fit', widget.task.id)),
        run: const ResolvingProcessRunner().call,
      ),
      probeDurationMs: (path) async =>
          (await FfprobeService(run: const ResolvingProcessRunner().call)
                  .probe(path))
              .duration
              .inMilliseconds,
      // 切片也编成代理规格：预览链路上每一段规格一致，接缝处才不用重建解码器
      targetSpec: () async => ProxySpec.at(_frameRateArg),
      // 字幕不烧进切片：调样式要即刻看到，烧的话每动一下就得重渲、重换源
      // （见 [SpeedFitter] 类注释与 [_previewSubtitleAt]）
    );
  }

  /// 三条轨：画面（主时钟，静音）+ 口播 + 配乐（循环）
  static PlaybackController _multitrack() => MultitrackPlayback(
        video: MediaKitPlaybackController(),
        voice: MediaKitFollower(),
        bgm: MediaKitFollower(loop: true),
      );

  void _onTracksChanged() {
    if (mounted) setState(() {});
  }

  /// 方案变了就重推轨道。与画面/声音无关的改动会被轨道指纹挡掉。
  /// 上一次为「这一段放不了」停在哪个单元上——同一段只提醒一次，
  /// 否则每上报一次位置就弹一条
  int? _stoppedAtUnit;

  /// 播到还没挑素材的那一段就**停下来点名**。
  ///
  /// 用户原话：「你不是应该提醒吗？你不要觉得这个东西就一定要解决，你提醒他
  /// 就好了呀。你必须得选个视频，他这个部分才能播放。」
  ///
  /// 不许悄悄滑过去：那一段在成片里是空的，画面停着不动，人只会以为播放器卡了。
  void _stopAtUnplayable(int ms, PlaybackController playback) {
    final spans = _tracks?.plan.unplayable ?? const [];
    if (spans.isEmpty) {
      _stoppedAtUnit = null;
      return;
    }
    final hit = spans.where((s) => s.covers(ms)).firstOrNull;
    if (hit == null) {
      _stoppedAtUnit = null;
      return;
    }
    // **只在真的在播时才拦**：进页面那一刻播放头就停在 0，而 0 可能正落在
    // 这一段里——不加这条的话，人刚打开任务、还没按播放就先挨一句提示。
    // 常驻横幅已经把话说在前面了，这里只管「他按了播放之后」
    if (!playback.isPlaying) return;
    if (_stoppedAtUnit == hit.unitIndex) {
      // 已经为这一段停过一次，人又按了播放：**跳过它继续往下看**。
      // 再停一次的表现就是「点了没反应」，而停在原地不动地播完这 10 秒空白
      // 更糟——画面冻住，人只会以为软件卡死了
      playback.seekMs(hit.endMs);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('跳过 U${hit.unitIndex + 1}（还没选素材），继续往下播'),
        duration: const Duration(seconds: 3),
      ));
      return;
    }
    _stoppedAtUnit = hit.unitIndex;
    playback.pause();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('U${hit.unitIndex + 1} 还没选素材，这一段放不了。'
          '去「替换素材」给它挑一条，或者把它删掉'),
      duration: const Duration(seconds: 5),
    ));
  }

  void _syncPreviewAudio() {
    final editor = _editor;
    if (editor == null) return;
    unawaited(_tracks?.update(
      task: _task,
      units: editor.units,
      voiceAudio: _voiceAudio,
      // 各槽位取标了 ★ 的那个候选
      replacements: _replacements ?? const [],
    ));
  }

  /// 打开原片。失败要让用户看见——文件被移走/改名时，静默失败的表现是
  /// 「点了播放没反应」，用户无从判断是坏了还是没加载完。
  Future<void> _openSource(PlaybackController playback, String path) async {
    try {
      await playback.open(path);
    } catch (e) {
      AppLog.warn('打开原片失败（$path）：$e');
      if (mounted) setState(() => _playbackDegraded = true);
    }
  }

  /// 重开页面时恢复「哪几句已经配好音了」。
  ///
  /// 不恢复的话，用户昨天生成过的配音今天点不到试听，只会以为白跑了一轮。
  void _restoreVoiceAudio() {
    final factory = widget.voiceSwapFactory ?? ref.read(voiceSwapFactoryProvider);
    if (factory == null) return;
    try {
      _voiceAudio = factory(widget.task)
              ?.existingAudio(widget.task.voices.assignedUnits) ??
          const {};
    } catch (e) {
      // 目录读不出来只影响试听按钮，不该拦住整个页面
      AppLog.warn('恢复已生成配音失败（taskId=${widget.task.id}）：$e');
    }
  }

  /// 解析播放后端：优先用测试/调用方注入的 [WorkbenchPage.playbackFactory]，
  /// 缺省时构造真实 `MediaKitPlaybackController`。
  ///
  /// media_kit 要求先在 `main()` 里调用过 `MediaKit.ensureInitialized()`
  /// 才能构造 `Player()`；正常启动流程必然满足，这条 catch 分支在真实 app
  /// 里理论上不会触达。只捕获 `Exception`（`on Exception catch (e)`），不
  /// 捕获 `Error`：media_kit 的 `NativeLibrary.path` 在未 ensureInitialized
  /// 时抛的正是裸 `Exception(...)`（libmpv 缺失/损坏等真机原生故障同理会
  /// 抛 `Exception`，仍会走到这里正常降级+提示），而 `ArgumentError`/
  /// `StateError`/`TypeError`/`AssertionError` 等 `Error` 子类通常意味着
  /// 编程错误——不应被这里静默吞掉、包装成一句"播放器不可用"，而应该继续
  /// 抛出、暴露真正的 bug。只要落入这条 catch，都必须置位
  /// [_playbackDegraded]，在页面上给用户一条可见提示（而不是静默显示占位
  /// 图标却不说明原因），并保留原始异常到日志（按消息文本对已知的"未
  /// 初始化"情形单独给出更精确的措辞）。
  PlaybackController _resolvePlayback() {
    // 缺省是**三条独立轨**：画面主时钟 + 口播 + 配乐（见 [MultitrackPlayback]）。
    // 测试注入 FakePlaybackController，不碰 libmpv
    final factory = widget.playbackFactory ?? _multitrack;
    try {
      return factory();
    } on Exception catch (e) {
      final looksLikeInitOrderIssue = e.toString().contains('ensureInitialized');
      AppLog.warn(looksLikeInitOrderIssue
          ? '播放器未完成 MediaKit.ensureInitialized 初始化，审片台将以无播放模式运行：$e'
          : '播放器初始化出现未预期异常，审片台将以无播放模式运行：$e');
      _playbackDegraded = true;
      return NoopPlaybackController();
    }
  }

  @override
  void dispose() {
    _lockTimer?.cancel();
    _agentPoll?.cancel();
    _releaseLock();
    _consequenceTimer?.cancel();
    // 浮层挂在 Overlay 上，页面 pop 不会带走它
    _subtitleStylePanel?.close();
    _flushAutosaveOnDispose();
    _positionSub?.cancel();
    _editor?.removeListener(_onEditorChanged);
    _editor?.dispose();
    _playhead.dispose();
    unawaited(_playback?.dispose());
    unawaited(_preview?.dispose());
    _tracks?.removeListener(_onTracksChanged);
    _tracks?.dispose();
    // 变速切片也要回收：只留这一次方案还在用的那几段。
    // 此前 prune 压根没人调，真机上 speed_fit 里堆了 6 个切片、4 个早就废了
    _speedFitter?.prune();
    // 离开工作台时做一次配额回收：固定住的一律不动，只淘汰没人用的
    for (final cache in [_mediaCache, _bgmMediaCache]) {
      if (cache == null) continue;
      cache.removeListener(_onMediaCacheChanged);
      cache.sweep();
      cache.dispose();
    }
    super.dispose();
  }

  /// 页面销毁时把还压在防抖窗口里的那次改动补写掉。
  ///
  /// 两件事都要做：定时器必须取消（否则它会在页面没了之后开火，拿着一个已经
  /// 失效的 ref 去写盘），而它本来要写的那次改动也不能就这么丢——用户刚拖完
  /// 边界就关窗口，改动理应已经留住。写盘走 [_tasks]（initState 里就抓住的
  /// notifier）——dispose 里 `ref` 已经失效，用它取会直接抛 StateError。
  void _flushAutosaveOnDispose() {
    final pending = _autosaveTimer?.isActive ?? false;
    _autosaveTimer?.cancel();
    _autosaveTimer = null;
    final editor = _editor;
    if (!pending || editor == null || !_isEditable) return;
    final units = editor.units;
    if (_savedUnits != null &&
        const ListEquality<SemanticUnit>().equals(_savedUnits!, units)) {
      return;
    }
    final notifier = _tasks;
    if (notifier == null) return;
    unawaited(() async {
      try {
        await notifier.saveSegmentationDraft(_task, units);
      } catch (e) {
        // 页面已经没了，弹不出提示，只能进日志
        AppLog.warn('离开时的自动保存失败（taskId=${widget.task.id}）：$e');
      }
    }());
  }

  /// 时间线辅助素材的就绪状态
  TimelineMediaStatus get _mediaStatus {
    // 空白任务没有原片，缩略图和波形永远不会有——显示「生成中…」等于挂一个
    // 永远转下去的圈
    if (_task.isBlank) return TimelineMediaStatus.noSource;
    if (_media != null) return TimelineMediaStatus.ready;
    return _mediaFailed
        ? TimelineMediaStatus.failed
        : TimelineMediaStatus.loading;
  }

  /// 画面轨自己的状态：抽出来一张都没有就是失败，不能报 ready 让它画成
  /// 一片没有任何说明的空白（2026-09-15 真机撞到）
  TimelineMediaStatus get _thumbStatus {
    final media = _media;
    if (media == null) return _mediaStatus;
    return media.thumbsAllMissing
        ? TimelineMediaStatus.failed
        : TimelineMediaStatus.ready;
  }

  /// 音频轨同理。失败时兜底返回的是**全 0**，画出来是贴底的一条直线，
  /// 看着像「这段本来就没声音」
  TimelineMediaStatus get _waveStatus {
    final media = _media;
    if (media == null) return _mediaStatus;
    return media.waveAllSilent
        ? TimelineMediaStatus.failed
        : TimelineMediaStatus.ready;
  }

  /// 编辑器变化时**只在 dirty 真正翻转时**重建页面。
  ///
  /// 页面本身唯一依赖编辑器状态的地方是 [PopScope.canPop]（决定返回时是否
  /// 弹「保存草稿」确认框）；三栏面板与底部栏各自监听同一个 controller，
  /// 不需要页面代劳。改造前这里无条件 `setState`，于是拖拽边界时每个
  /// DragUpdate（macOS 触控板约 90~125Hz）都重建整页。
  /// 空白任务：在末尾加一个空分子。
  ///
  /// 走 [SegmentationEditorController.replaceUnitsForBlankTask] 而不是切分
  /// 那套操作——那套要保证「无缝覆盖固定的原片时长」，而这里总长本来就是
  /// 加出来的。
  /// 把界面上那份**按位置排**的方案翻译成「单元身份 → 方案」。
  ///
  /// 界面天然按位置走（人说的是 U1/U2），而存的是身份——挪动、删除都不会
  /// 让它错位。翻译只在写进 [_task] 的这一步做
  Map<String, UnitReplacement> _byUid(List<UnitReplacement>? list) {
    final units = _editor?.units ?? const <SemanticUnit>[];
    final plans = list ?? const <UnitReplacement>[];
    return RenewTask.byUid(units, plans);
  }

  /// 把某个单元拖到另一个位置——**列表顺序就是成片顺序**。
  ///
  /// 挪列表本身很简单，风险全在旁边那三份按下标记的数据上：替换方案、配音、
  /// 配乐。不跟着搬不会报错，只会让成片悄悄变成另一个样子（挑给 U2 的素材
  /// 跑到 U1 身上）。三个 remap 见 `unit_reorder.dart`。
  ///
  /// 配乐记的是**区间**，把区间里的单元挪出去，这一段盖的范围就变了——
  /// 那是用户照着内容选的曲子，不能悄悄改，所以要弹出来点名。
  Future<void> _reorderUnit(int from, int to) async {
    final editor = _editor;
    if (editor == null || !_isEditable || _lock != null) return;
    final next = moveUnit(editor.units, from: from, to: to);
    if (identical(next, editor.units)) return;

    final bgm = remapBgmAfterMove(_task.bgm, from: from, to: to);
    if (bgm.brokenSegments.isNotEmpty && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('有配乐是按连续几段铺的，挪动之后盖的范围变了——'
              '请回配乐轨确认一下')));
    }

    // **一份都不用搬**：方案、配音、手改字幕都按单元的身份记，挪的只是
    // 列表顺序。内存里那份是按位置排的视图，照新顺序重新铺一遍就是了
    final movedReplacements = _task.replacementsFor(next);
    setState(() {
      _replacements = movedReplacements;
      _task = _task.copyWith(
          bgm: bgm.plan,
          // **也要写进 _task 并落盘**：只改内存的话，重开任务时素材会退回
          // 挪动之前那一格（2026-09-08 真机）。身份没变，这里写的是同一份，
          // 但 replacementsByUid 仍要显式带上——否则 units 换了、方案没跟着
          // 存，下次读档按位置兜底会错位
          replacementsByUid: RenewTask.byUid(next, movedReplacements));
    });
    await _savePickingPlanQuietly(movedReplacements);
    // **有原片的任务：原片时长一帧没多。** 加一段进来变长的是成片，
    // 而 durationMs 的语义是原片时长——传链上去的假末尾会让底部摘要写出
    // 「时长 75.3s（原片 85.3s）」这种把两个数对调的话（2026-09-08 真机）。
    // 空白任务没有原片，总长就是排出来的那些分子，照旧
    editor.replaceUnitsForBlankTask(
        next, _task.isBlank ? next.last.endMs : editor.durationMs);
    editor.select(EditorSelection.unit(to));
    await _saveBgm(_task.bgm);
    _scheduleAutosave();
  }

  /// 全片打底：**两条轨各放哪一路声音**。单个镜头可以覆盖它（见镜头属性栏）。
  ///
  /// 一个对话框管两条：成片的声音本来就是两层，分成两个按钮的话人得开两次、
  /// 还看不出它们是一组的（用户 2026-09-10 要的正是「排列组合由我自己选」）
  Future<void> _editMaterialAudio() async {
    final current = _task.materialAudio;
    var mode = current.mode;
    var volume = current.volume;
    final currentSource = _task.sourceAudio;
    var sourceMode = currentSource.mode;
    var sourceVolume = currentSource.volume;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('这一镜的声音（全片）'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text(
                  '被替换掉的那一镜，声音有两层：原片这一段自己的，'
                  '和顶上来那条素材自己的。两层各选各的，最后混在一起。',
                  style: TextStyle(fontSize: AppFontSize.caption, height: 1.6),
                ),
                const SizedBox(height: AppSpacing.md),
                _audioSection(
                  title: '原片这一镜的声音',
                  keyPrefix: 'task-source-audio',
                  hintOf: (m) => m.sourceHint,
                  // 没选过 = 自动：原混音照播，被配乐盖住时换成纯人声。
                  // 直接写死「原声」的话，人什么都没动、铺了配乐的段落反而变差
                  selected: sourceMode,
                  onSelected: (m) => setLocal(() => sourceMode = m),
                  volume: sourceVolume,
                  onVolume: (v) => setLocal(() => sourceVolume = v),
                  autoNote: '自动：原片这一段原样播；这一格铺了配乐就换成纯人声',
                  onAuto: () => setLocal(() => sourceMode = null),
                ),
                const Divider(height: AppSpacing.xl),
                _audioSection(
                  title: '替换分镜的声音',
                  keyPrefix: 'task-material-audio',
                  hintOf: (m) => m.hint,
                  selected: mode,
                  onSelected: (m) => setLocal(() => mode = m),
                  volume: volume,
                  onVolume: (v) => setLocal(() => volume = v),
                ),
                if (mode.needsSeparation)
                  const Text('人声和背景声要先把素材分成两路，'
                      '每条素材十几秒，选中后会当场开始',
                      style: TextStyle(
                          fontSize: AppFontSize.caption,
                          height: 1.5,
                          color: AppColors.textTertiary)),
              ]),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('好')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _task = _task.copyWith(
          materialAudio: MaterialAudioSetting(mode: mode, volume: volume),
          sourceAudio:
              SourceAudioSetting(mode: sourceMode, volume: sourceVolume),
        ));
    // 改了全片打底，预览要跟着换源
    _syncPreviewAudio();
    await _tasks?.saveMaterialAudio(_task);
  }

  /// 对话框里的一栏：四个档位 + 音量。[onAuto] 非空表示这一栏还有
  /// 「自动」这个态（原片那一栏有，素材那一栏没有——它的默认就是一个档位）
  Widget _audioSection({
    required String title,
    required String keyPrefix,
    required String Function(MaterialAudioMode) hintOf,
    required MaterialAudioMode? selected,
    required ValueChanged<MaterialAudioMode> onSelected,
    required double volume,
    required ValueChanged<double> onVolume,
    String? autoNote,
    VoidCallback? onAuto,
  }) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title,
            style: const TextStyle(
                fontSize: AppFontSize.body, fontWeight: FontWeight.w600)),
        const SizedBox(height: AppSpacing.xs),
        RadioGroup<MaterialAudioMode>(
          groupValue: selected,
          onChanged: (v) => onSelected(v ?? MaterialAudioMode.original),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final m in MaterialAudioMode.values)
              RadioListTile<MaterialAudioMode>(
                key: Key('$keyPrefix-${m.name}'),
                value: m,
                title: Text(m.label),
                subtitle: Text(hintOf(m),
                    style: const TextStyle(fontSize: AppFontSize.caption)),
                contentPadding: EdgeInsets.zero,
                dense: true,
              ),
          ]),
        ),
        if (onAuto != null)
          Row(children: [
            Expanded(
              child: Text(
                  selected == null ? autoNote ?? '' : '现在按你选的那一档放',
                  key: Key('$keyPrefix-auto-note'),
                  style: const TextStyle(
                      fontSize: AppFontSize.caption,
                      height: 1.5,
                      color: AppColors.textTertiary)),
            ),
            if (selected != null)
              TextButton(
                  key: Key('$keyPrefix-auto'),
                  onPressed: onAuto,
                  child: const Text('改回自动')),
          ]),
        if (selected?.audible ?? false)
          Row(children: [
            Text('音量 ${(volume * 100).round()}%',
                style: const TextStyle(fontSize: AppFontSize.caption)),
            Expanded(
              child: Slider(value: volume, onChanged: onVolume),
            ),
          ]),
      ]);

  /// 手改台词语义单元的标签。
  ///
  /// **只从这条任务的标签组里选**：标签是搜素材的检索键，给出标签组以外的词
  /// 等于让人挑一个这个项目根本没素材的标签，搜完才发现是空的。
  ///
  /// 改完标成「人改过」——重新打标时会跳过它，不然模型照台词重打一遍，
  /// 人刚做的判断就被一个后台步骤抹掉了，而且不问一声。
  Future<void> _editUnitTags(int unitIndex) async {
    final editor = _editor;
    if (editor == null || !_isEditable || _lock != null) return;
    final units = editor.units;
    if (unitIndex >= units.length) return;
    final picked = await showTagPicker(
      context,
      tags: ref.read(miaoaTagServiceProvider),
      selected: units[unitIndex].tags,
      preferredGroupIds: {for (final g in _task.unitTagGroups) g.id},
      onlyPreferred: true,
    );
    if (picked == null || !mounted) return;
    editor.replaceUnits([
      for (var i = 0; i < units.length; i++)
        if (i != unitIndex)
          units[i]
        else
          withHandpickedTags(units[i], [for (final t in picked) t.name]),
    ]);
    _scheduleAutosave();
    _remindResearch();
  }

  /// 手改视觉镜头的标签（规矩同上，只是词表换成镜头层那几个标签组）
  Future<void> _editShotTags(int unitIndex, int shotIndex) async {
    final editor = _editor;
    if (editor == null || !_isEditable || _lock != null) return;
    final units = editor.units;
    if (unitIndex >= units.length) return;
    final shots = units[unitIndex].shots;
    if (shotIndex >= shots.length) return;
    final picked = await showTagPicker(
      context,
      tags: ref.read(miaoaTagServiceProvider),
      selected: shots[shotIndex].tags,
      preferredGroupIds: {for (final g in _task.shotTagGroups) g.id},
      onlyPreferred: true,
    );
    if (picked == null || !mounted) return;
    editor.replaceUnits([
      for (var i = 0; i < units.length; i++)
        if (i != unitIndex)
          units[i]
        else
          units[i].copyWith(shots: [
            for (var j = 0; j < shots.length; j++)
              if (j != shotIndex)
                shots[j]
              else
                withHandpickedShotTags(
                    shots[j], [for (final t in picked) t.name]),
          ]),
    ]);
    _scheduleAutosave();
    _remindResearch();
  }

  /// 标签就是搜素材的检索键——改了，之前搜出来的候选就是按旧标签搜的。
  /// **只提醒一句，不替他重搜**：重搜要花时间、还会冲掉他已经挑好的
  void _remindResearch() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('标签改了。之前的候选是按旧标签搜出来的，'
            '可能要去「替换素材」重新搜一次')));
  }

  /// 这一镜当前的字幕。
  ///
  /// **手改过就给手改的，没改过就把自动算的那份算出来给人看** ——
  /// 直接给空列表的话，人一打开看到的是「没有字幕」，而导出时其实会烧上一份，
  /// 他改的第一步会变成「凭空敲一遍」。
  /// 这一镜要烧哪几行字。**时间线、属性面板、字幕编辑卡都读它**——
  /// 和预览、导出走的是同一份规则（见 [subtitleLinesForSlot]）。
  ///
  /// 底片固定过的单元从**它自己的转写**里取，坑位换成素材内偏移：原片那份
  /// ASR 量的是原片，拿它算出来的行时间和这段画面对不上，画在时间线上就是
  /// 一块位置和宽度都不对的灰条（2026-09-16 真机：字幕块和镜头块错开）
  List<SubtitleLine> _subtitleLinesOf(int unitIndex, int shotIndex) {
    final units = _editor?.units ?? const [];
    if (unitIndex >= units.length) return const [];
    final unit = units[unitIndex];
    final shots = unit.shots;
    if (shotIndex >= shots.length) return const [];
    final onBase = hasOwnBaseShots(unit);
    return subtitleLinesForSlot(
      track: _task.subtitleTrack,
      sentences: _task.asrSentences ?? const [],
      unitUid: unit.uid,
      shotIndex: shotIndex,
      slotStartMs: shots[shotIndex].startMs,
      slotEndMs: shots[shotIndex].endMs,
      onMaterialBase: onBase,
      baseSentences: onBase ? unit.baseSentences : null,
      baseSlotStartMs:
          onBase ? shots[shotIndex].startMs - unit.startMs : null,
      baseSlotEndMs: onBase ? shots[shotIndex].endMs - unit.startMs : null,
    );
  }

  /// 这一格字幕坑位。单元的**身份**是键——单元怎么挪，手改的字幕都还认得回来
  SubtitleSlot? _subtitleSlot(int unitIndex, int shotIndex) {
    final units = _editor?.units ?? const [];
    if (unitIndex < 0 || unitIndex >= units.length) return null;
    return SubtitleSlot(unitUid: units[unitIndex].uid, shotIndex: shotIndex);
  }

  bool _subtitleEdited(int unitIndex, int shotIndex) {
    final slot = _subtitleSlot(unitIndex, shotIndex);
    return slot != null && _task.subtitleTrack.linesOf(slot) != null;
  }

  /// 这一镜有几行字幕。时间线上多于一行就标个数——轨上只画得下头一句，
  /// 不标的话人不知道双击进去还有别的行
  int _subtitleLineCount(int unitIndex, int shotIndex) =>
      _subtitleLinesOf(unitIndex, shotIndex).length;

  /// 双击时间线上的字幕块：贴着它弹一个浮层就地改。
  ///
  /// 内容复用右侧那张字幕卡——两个入口共用一份实现，否则迟早行为不一样
  /// （一边离开才提交、另一边每敲一下就提交，人只会觉得「时好时坏」）
  Future<void> _editSubtitleAtBlock(
      int unitIndex, int shotIndex, Rect blockOnScreen) async {
    if (!_isEditable || _lock != null) return;
    await showSubtitlePopover(
      context,
      anchor: blockOnScreen,
      lines: _subtitleLinesOf(unitIndex, shotIndex),
      edited: _subtitleEdited(unitIndex, shotIndex),
      slotDurationMs: _shotDurationMs(unitIndex, shotIndex),
      slotStartMs: _shotComposedStartMs(unitIndex, shotIndex),
      fps: _editor?.fps ?? 30,
      onChanged: (lines) => _setSubtitleLines(unitIndex, shotIndex, lines),
      onResetToAuto: () => _resetSubtitle(unitIndex, shotIndex),
    );
  }

  /// 这一镜有多长。字幕的时间以这一镜的开头为 0，改时间时靠它夹住上界
  int _shotDurationMs(int unitIndex, int shotIndex) {
    final units = _editor?.units ?? const [];
    if (unitIndex >= units.length) return 0;
    final shots = units[unitIndex].shots;
    return shotIndex >= shots.length ? 0 : shots[shotIndex].durationMs;
  }

  /// 这一镜在**成片时间轴**上从哪儿开始。字幕存的是相对这一镜的时间，
  /// 摆给人看的是成片时间码，靠它换算
  int _shotComposedStartMs(int unitIndex, int shotIndex) {
    final editor = _editor;
    if (editor == null) return 0;
    final axis = ComposedTimeline.of(
        units: editor.units, wholeDurations: _composedDurations);
    return axis.composedShotStart(unitIndex, shotIndex) ?? 0;
  }

  /// 这一镜字幕的头一句，画在时间线的字幕轨上当预览
  String _subtitleTextOf(int unitIndex, int shotIndex) {
    final lines = _subtitleLinesOf(unitIndex, shotIndex);
    return lines.isEmpty ? '' : lines.first.text;
  }

  void _setSubtitleLines(
      int unitIndex, int shotIndex, List<SubtitleLine> lines) {
    if (!_isEditable || _lock != null) return;
    final slot = _subtitleSlot(unitIndex, shotIndex);
    if (slot == null) return;
    setState(() => _task = _task.copyWith(
        subtitleTrack: _task.subtitleTrack.withLines(slot, lines)));
    // 预览里那一段是烧好字的切片，不重推就永远停在旧那一版
    _syncPreviewAudio();
    unawaited(_tasks?.saveSubtitleTrack(_task) ?? Future.value());
  }

  void _resetSubtitle(int unitIndex, int shotIndex) {
    if (!_isEditable || _lock != null) return;
    final slot = _subtitleSlot(unitIndex, shotIndex);
    if (slot == null) return;
    setState(() =>
        _task = _task.copyWith(subtitleTrack: _task.subtitleTrack.cleared(slot)));
    _syncPreviewAudio();
    unawaited(_tasks?.saveSubtitleTrack(_task) ?? Future.value());
  }

  /// 这一镜换过素材没有。没换就没有「素材的声音」可言，那张卡片不出现
  bool _shotReplaced(int unitIndex, int shotIndex) {
    final plans = _replacements ?? const [];
    if (unitIndex >= plans.length) return false;
    return plans[unitIndex].shotCandidateIds[shotIndex]?.isNotEmpty ?? false;
  }

  /// 换上来那条素材自己的语音转写。非空 = 它自己带口播，保留原声会和台词
  /// 打架——界面上就地提示一句，但**不拦**：有时候要的就是那句话
  String? _shotMaterialVoiceover(int unitIndex, int shotIndex) {
    final plans = _replacements ?? const [];
    if (unitIndex >= plans.length) return null;
    final ids = plans[unitIndex].shotCandidateIds[shotIndex];
    if (ids == null || ids.isEmpty) return null;
    final picked = _task.pickedMaterials
        .where((m) => m.id == ids.first)
        .firstOrNull;
    return picked?.voiceover;
  }

  /// 改这一镜的「保留素材原声」。keep 传 null = 清掉覆盖、改回跟随全片
  /// 选了「人声」「背景声」就**当场把这条素材分成两路**。
  ///
  /// 为什么不等到导出：那时才分，人要等整批导完才知道分不出来；而这一步
  /// 十几秒，就地跑掉、就地报错，他还能当场改成别的档位。分完按素材缓存，
  /// 同一条素材在别的镜头再选一次不会重跑。
  Future<void> _ensureMaterialSeparated(int unitIndex, int shotIndex) async {
    final path = _shotMaterialPath(unitIndex, shotIndex);
    if (path == null) return;
    final separate = ref.read(materialSeparatorProvider);
    if (separate == null) {
      setState(() => _materialSeparationError =
          '没装人声分离工具，分不出人声/背景声。去「设置 → 运行环境」装好，'
          '或把这一镜改成「原声」/「不播放」');
      return;
    }
    setState(() {
      _separatingMaterial = path;
      _materialSeparationError = null;
    });
    try {
      final vocals = await separate(_task.id, path);
      if (!mounted) return;
      setState(() => _materialSeparationError = vocals == null
          // 不许悄悄退回原声：他选的是另一路声音
          ? '这条素材分离失败。重试一次，或把这一镜改成「原声」/「不播放」'
          : null);
    } catch (e) {
      if (mounted) {
        setState(() => _materialSeparationError = userFacingError(e,
            fallback: '素材分离失败，请检查人声分离工具后重试'));
      }
    } finally {
      if (mounted) setState(() => _separatingMaterial = null);
    }
  }

  /// 分离轨在不在盘上。存量任务可能只分过人声、或者产物被清理掉了
  static bool _hasStem(String? path) =>
      path != null && File(path).existsSync();

  /// 这一镜换上来那条素材的本地路径（还没落地就返回 null）
  String? _shotMaterialPath(int unitIndex, int shotIndex) {
    final plans = _replacements ?? const [];
    if (unitIndex >= plans.length) return null;
    final ids = plans[unitIndex].shotCandidateIds[shotIndex];
    if (ids == null || ids.isEmpty) return null;
    return _mediaCache?.localPathOf(ids.first);
  }

  /// 改这一镜「原片这一镜的声音」。mode 传 null = 清掉覆盖、回到跟随全片
  void _setShotSourceAudio(int unitIndex, int shotIndex,
      MaterialAudioMode? mode, double? volume) {
    final editor = _editor;
    if (editor == null || !_isEditable || _lock != null) return;
    final units = editor.units;
    if (unitIndex >= units.length) return;
    final shots = units[unitIndex].shots;
    if (shotIndex >= shots.length) return;
    editor.replaceUnits([
      for (var i = 0; i < units.length; i++)
        if (i != unitIndex)
          units[i]
        else
          units[i].copyWith(shots: [
            for (var j = 0; j < shots.length; j++)
              if (j != shotIndex)
                shots[j]
              else
                // 走 withSourceAudioOverride：copyWith 传 null 等于「不改」，
                // 而「跟随全片」正是 null
                shots[j].withSourceAudioOverride(mode: mode, volume: volume),
          ]),
    ]);
    _scheduleAutosave();
    // 预览要跟着换源——不然人改了档位却听不出变化
    _syncPreviewAudio();
  }

  void _setShotMaterialAudio(int unitIndex, int shotIndex,
      MaterialAudioMode? mode, double? volume) {
    final editor = _editor;
    if (editor == null || !_isEditable || _lock != null) return;
    final units = editor.units;
    if (unitIndex >= units.length) return;
    final shots = units[unitIndex].shots;
    if (shotIndex >= shots.length) return;
    editor.replaceUnits([
      for (var i = 0; i < units.length; i++)
        if (i != unitIndex)
          units[i]
        else
          units[i].copyWith(shots: [
            for (var j = 0; j < shots.length; j++)
              if (j != shotIndex)
                shots[j]
              else
                // 走 withMaterialAudioOverride：copyWith 传 null 等于「不改」，
                // 而「跟随全片」正是 null，用 copyWith 会清不掉覆盖
                shots[j]
                    .withMaterialAudioOverride(mode: mode, volume: volume),
          ]),
    ]);
    _scheduleAutosave();
    // 选了要分离的档位就当场开分——「选了就当场跑」是产品定的
    final effective = resolveMaterialAudio(
        taskDefault: _task.materialAudio, shotMode: mode);
    if (effective.mode.needsSeparation) {
      unawaited(_ensureMaterialSeparated(unitIndex, shotIndex));
    }
  }

  /// 加一个台词语义单元。
  ///
  /// 空白任务走 [BlankUnitOps]（本来就没有原片，分子随便加）；有原片的任务
  /// 走 [SegmentationEditOps.appendUnit]——加出来的那个标着「原片上没有它」，
  /// 只能接在末尾（想排到前面加完再拖）。两条路产出的都是「待填」的单元：
  /// 不给它挑素材，导出会点名拦住，不会拿黑帧顶上。
  void _addUnit() {
    final editor = _editor;
    if (editor == null || !_isEditable || _lock != null) return;
    final next = _task.isBlank
        ? BlankUnitOps.append(editor.units)
        : SegmentationEditOps.appendUnit(editor.units, fps: editor.fps);
    editor.replaceUnitsForBlankTask(next, next.last.endMs);
    editor.select(EditorSelection.unit(next.length - 1));
    _scheduleAutosave();
  }

  /// 空白任务的分子标签编辑器。只能从任务标签组的词表里选——手打的标签
  /// 检索时一个都命中不了，而用户打完字看不出任何异常
  Widget _blankTagEditor(int unitIndex, List<String> tags) =>
      BlankUnitTagEditor(
        key: ValueKey('blank-tags-$unitIndex'),
        unitIndex: unitIndex,
        tags: tags,
        tagGroups: _task.unitTagGroups,
        project: _task.project,
        onChanged: (next) {
          final editor = _editor;
          if (editor == null || !_isEditable || _lock != null) return;
          final units = BlankUnitOps.setTags(editor.units, unitIndex, next);
          editor.replaceUnitsForBlankTask(
              units, units.isEmpty ? BlankUnitOps.placeholderMs : units.last.endMs);
          _scheduleAutosave();
        },
      );

  /// 空白任务：删掉一个分子。
  ///
  /// 分子本身好删，风险在旁边两份**也是按下标记**的数据：替换方案和配乐
  /// 区间。它们不跟着挪不会报错，只会让成片悄悄变成另一个样子
  /// （见 [shiftReplacementsAfterRemoval] / [shiftBgmAfterRemoval]）。
  Future<void> _deleteBlankUnit(int unitIndex) async {
    final editor = _editor;
    if (editor == null || !_isEditable || _lock != null) return;
    // 「至少留几个」是空白任务的规矩：那条片子整个由分子排出来。有原片的
    // 任务这里删的只是手动加的那个，删光了还有分析切出来的一整条
    if (_task.isBlank && editor.units.length <= blankMinUnits) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('至少要留 $blankMinUnits 个分子')));
      return;
    }

    final picked = (_replacements ?? const []).length > unitIndex &&
        _replacements![unitIndex].wholeCandidateIds.isNotEmpty;
    if (picked) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('删掉 U${unitIndex + 1}？'),
          content: const Text('它已经挑好素材了。删掉之后这个选择也一并没了，撤不回来。'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('删掉')),
          ],
        ),
      );
      if (ok != true) return;
    }

    // 这个单元名下的画面/波形（固定过底片才有）跟它一起走——它没了，
    // 那几份就再也没人读（「不留孤儿数据」）
    final goneUid = editor.units[unitIndex].uid;
    _discardUnitArtifacts(goneUid);
    _baseMedia = {..._baseMedia}..remove(goneUid);

    // **有原片的任务只重排下标，不重铺时间轴**：单元的起止是原片坐标，
    // 单元里的视觉镜头也是。把单元重新铺成连续的一条、镜头留在原地，
    // 两层就此对不上（见 [removeUnitAt]）
    final units = _task.isBlank
        ? BlankUnitOps.removeAt(editor.units, unitIndex)
        : removeUnitAt(editor.units, unitIndex);
    // 删掉之后按新的单元列表重新铺一遍——方案按身份记，没被删的那些
    // 一个都不会跑位
    final shifted = _task.replacementsFor(units);
    setState(() {
      _replacements = shifted;
      _task = _task.copyWith(
          bgm: shiftBgmAfterRemoval(_task.bgm, removed: unitIndex),
          // 和重排同理：内存、_task、盘上三处都要改。方案按身份记，
          // 删掉的那个单元连同它的方案一起没了，剩下的一份都不动
          replacementsByUid: RenewTask.byUid(units, shifted),
          // 配音和字幕只需要把没人认领的那几条丢掉——剩下的一份都不用动
          voices: _task.voices.keepingOnly({for (final u in units) u.uid}),
          subtitleTrack: _task.subtitleTrack
              .keepingOnly({for (final u in units) u.uid}));
    });
    await _savePickingPlanQuietly(shifted);
    editor.replaceUnitsForBlankTask(
        units,
        units.isEmpty
            ? BlankUnitOps.placeholderMs
            // 取最大值而不是最后一个：列表顺序是成片顺序，调过序之后
            // 最后那个未必覆盖到最远
            : (_task.isBlank ? units.last.endMs : coveredEndMs(units)));
    unawaited(_saveBgm(_task.bgm));
    _scheduleAutosave();
  }

  /// 上一次通知时是否正处在拖拽会话里——用来识别「刚松手」那一刻
  bool _wasDragging = false;

  void _onEditorChanged() {
    // 边界动过，每一段的时长就变了，预览音轨要重合（它自己带防抖）
    _syncPreviewAudio();
    _scheduleAutosave();
    // 松手就是「这一刀拖完了」的明确信号，0.8 秒就问；步进按钮、改台词
    // 这类没有明确收尾动作的编辑才等 3 秒的「手停下来了」
    final dragging = _editor?.inDragSession ?? false;
    final justReleased = _wasDragging && !dragging;
    _wasDragging = dragging;
    if (!dragging) {
      _scheduleConsequenceCheck(justReleased
          ? const Duration(milliseconds: 800)
          : const Duration(seconds: 3));
    }
    final dirty = _editor?.dirty ?? false;
    if (dirty == _lastDirty) return;
    setState(() => _lastDirty = dirty);
  }

  /// 编辑停下来之后再问「要不要清素材/重打标」。
  ///
  /// 比自动保存等得久得多：用户往往连着拖好几刀才算改完一处，改一下弹一次
  /// 会把人逼疯。3 秒是「手停下来了」的信号。
  void _scheduleConsequenceCheck(
      [Duration delay = const Duration(seconds: 3)]) {
    // 空白任务不问这个。它问的是「切分结构变了，原来的素材和标签多半对不上」
    // ——那是有原片的任务拆分/合并之后的真实后果。空白任务加一个分子什么都没影响，
    // 删一个的连带处理（替换方案、配乐区间）已经在删除那一步做掉了。
    //
    // 更要命的是它提出的「重新打标」：空白任务的标签是**手填**的，
    // 照做等于把用户刚选的标签清掉，送去一个没有台词可读的模型重打
    if (_task.isBlank) return;
    _consequenceTimer?.cancel();
    _consequenceTimer = Timer(delay, _askConsequence);
  }

  Future<void> _askConsequence() async {
    _consequenceTimer = null;
    final editor = _editor;
    if (editor == null || !_isEditable || _askingConsequence) return;

    final baseline = _consequenceBaseline ?? widget.task.units ?? const [];
    final consequence = EditConsequence.evaluate(
      before: baseline,
      after: editor.units,
      replacements: _replacements ?? const [],
    );
    // 无论问不问，这一轮都已经结算过了：下次只比这次之后的新改动
    _consequenceBaseline = editor.units;
    if (consequence == null || !mounted) return;

    _askingConsequence = true;
    try {
      final choice = await showEditConsequenceDialog(context, consequence,
          replacements: _replacements ?? const []);
      if (choice == null || choice.nothingToDo || !mounted) return;
      if (choice.clearCandidates) {
        await _onReplacementsChanged(
            consequence.clearCandidates(_replacements ?? const []));
      }
      if (choice.retag) await _retag(consequence);
    } finally {
      _askingConsequence = false;
    }
  }

  /// 给若干台词语义单元换音色。
  ///
  /// 只落方案，不立刻合成——合成要走云端、几秒一句，用户往往先把几句都配好
  /// 再统一生成。真正的合成由「生成配音」触发。
  Future<void> _changeVoice(int unitIndex) async {
    final editor = _editor;
    if (editor == null) return;
    final choice = await showVoicePicker(
      context,
      units: editor.units,
      plan: _task.voices,
      focusedUnit: unitIndex,
    );
    if (choice == null || !mounted) return;
    // 界面上人选的是 U1/U2（位置），存的是单元自己的身份
    final uids = [
      for (final i in choice.unitIndexes)
        if (i >= 0 && i < editor.units.length) editor.units[i].uid,
    ];
    final next = choice.voice == null
        ? _task.voices.clear(uids)
        : _task.voices.assign(uids, choice.voice!);
    setState(() => _task = _task.copyWith(voices: next));
    _syncPreviewAudio();
    try {
      await _tasks!.saveVoices(_task, next);
    } catch (e) {
      AppLog.warn('换音色方案落库失败（taskId=${widget.task.id}）：$e');
      if (mounted) _showSaveFailure('配音方案');
    }
  }

  /// 「生成配音」：把已经定好的换音色方案真正跑成音频。
  ///
  /// 与「选音色」分开是刻意的：选音色是即时的，生成要走云端、每句几秒，
  /// 用户往往先把几句都配好再统一生成。
  Future<void> _generateVoices() async {
    // 重入闸：一轮生成是真金白银的云端计费任务，按钮虽随进度禁用，
    // 但任何别的入口（快捷键/将来新增的调用点）都不该能并发触发第二轮
    if (_voiceProgress != null) return;
    final editor = _editor;
    final factory = widget.voiceSwapFactory ?? ref.read(voiceSwapFactoryProvider);
    if (editor == null || _task.voices.isEmpty) return;
    if (factory == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('尚未配置 AI 服务，无法生成配音；补齐凭据后重启应用再试')));
      return;
    }

    final job = factory(_task);
    if (job == null) {
      // 空白任务没有台词可念。这个按钮本来就不该出现在这类任务上，
      // 真出现了也要说人话
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('这条任务没有台词，换不了音色')));
      return;
    }
    setState(() => _voiceProgress = (0, _task.voices.assignedUnits.length));
    try {
      // 合成按字符计费，且用户会反复改台词重生成——记进这个任务的账
      late Map<String, VoiceSwapResult> results;
      final usage = await AiUsageScope.collect(
        () async {
          results = await job.service.run(
            units: editor.units,
            sentences: widget.task.asrSentences ?? const [],
            plan: _task.voices,
            onProgress: (done, total) {
              if (mounted) setState(() => _voiceProgress = (done, total));
            },
          );
        },
        // 中途失败时前面已经合成的照样计费
        onPartial: (partial) =>
            _task = _task.copyWith(aiUsage: _task.aiUsage.merge(partial)),
      );
      _task = _task.copyWith(aiUsage: _task.aiUsage.merge(usage));
      // 落盘：跑一轮要几十秒到几分钟，只留在内存里的话关掉页面就得重跑
      final written = <String, String>{};
      job.outputDir.createSync(recursive: true);
      for (final entry in results.entries) {
        final file = job.audioFor(entry.key)
          ..writeAsBytesSync(entry.value.audio);
        written[entry.key] = file.path;
      }
      if (!mounted) return;
      final failed = job.service.failures;
      setState(() => _voiceAudio = {..._voiceAudio, ...written});
      _syncPreviewAudio();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(failed.isEmpty
            ? '已生成 ${written.length} 句配音，可在检查器里试听'
            // 失败的那几句要点名，用户才知道去重跑哪几句
            : '已生成 ${written.length} 句；'
                // 失败的按身份记，说给人听要翻译回 U1/U2
                '${[for (var i = 0; i < editor.units.length; i++) if (failed.containsKey(editor.units[i].uid)) 'U${i + 1}'].join('、')} 失败，可再点一次只补这几句'),
        backgroundColor: failed.isEmpty ? null : AppColors.red,
      ));
    } catch (e) {
      AppLog.warn('生成配音失败（taskId=${widget.task.id}）：$e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(userFacingError(e, fallback: '生成配音失败，请稍后重试')),
          backgroundColor: AppColors.red,
        ));
      }
    } finally {
      if (mounted) setState(() => _voiceProgress = null);
    }
  }

  /// 试听某个单元已生成的配音。**按身份取**：按位置取的话，人挪过顺序之后
  /// 试听到的是别人那一段
  Future<void> _previewVoice(int unitIndex) async {
    final units = _editor?.units ?? const [];
    if (unitIndex < 0 || unitIndex >= units.length) return;
    final path = _voiceAudio[units[unitIndex].uid];
    if (path == null) return;
    try {
      await (_preview ??= widget.audioPreview ?? AudioPreview()).play(path);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('试听失败，音频文件可能已被清理')));
      }
    }
  }

  /// 在配乐轨上框选完一段单元：挑一首铺上去。
  Future<void> _pickBgmForRange(int fromUnit, int toUnit) async {
    final editor = _editor;
    if (editor == null) return;
    final rangeMs = unitRangeMs(editor.units, from: fromUnit, to: toUnit);
    final choice = await showBgmPicker(
      context,
      rangeMs: rangeMs,
      rangeLabel: _unitRangeLabel(fromUnit, toUnit),
      projectIds: _projectIds,
    );
    if (choice is! BgmPicked || !mounted) return;
    await _saveBgm(_task.bgm.assign(
      startUnit: fromUnit,
      endUnit: toUnit,
      materials: choice.materials,
      previewIndex: choice.previewIndex,
      rangeMs: rangeMs,
      volume: choice.volume,
    ));
  }

  static bool _sameGroups(List<TagGroupRef> a, List<TagGroupRef> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// 重新推一次轨道。配乐/素材取不到最常见的两个原因是网络抖动和登录过期，
  /// 重试一次多半就好了——而此前用户只能去重新选一遍
  void _retryPreviewAudio() {
    for (final cache in [_mediaCache, _bgmMediaCache]) {
      for (final id in cache?.notReady ?? const <int>[]) {
        cache!.retry(id);
      }
    }
    _syncPreviewAudio();
  }

  /// 正在单独补这条任务的人声轨。分离要十几秒，界面得说清在做什么
  bool _separatingVocals = false;

  /// 正在给哪条素材分离（人声/背景声这两档要先分）。null = 没在分
  String? _separatingMaterial;

  /// 素材分离失败了，说明这一条。人是特意选了那一档的，
  /// 静默退回原声等于给他一个不是他选的声音
  String? _materialSeparationError;

  /// 只补这条任务自己的人声轨，不重跑整轮分析。
  ///
  /// 人声轨**归任务所有**（落在 `stems/<taskId>/`）：别人删任务时会被一起
  /// 清掉，当初那次分离也可能失败过。缺的既然只是这一份，就没有理由为它
  /// 重跑几分钟的 ASR 与切分——何况那条路命中分析缓存后直接返回，
  /// 压根走不到分离那一步（真机事故 2026-09-04 就卡在这儿）。
  ///
  /// **失败要说原因**：这是用户主动点的，他在等一个结果。工具没装、模型下
  /// 不下来，[VocalSeparationException] 都已经翻成人话，原样告诉他
  Future<void> _separateVocals() async {
    // 重入闸：分离是十几秒的重活，连点两下不该跑两遍
    if (_separatingVocals) return;
    final pipeline = ref.read(analysisPipelineProvider);
    if (pipeline == null) {
      _showVocalsFailure(pipelineUnavailableMessage);
      return;
    }
    setState(() => _separatingVocals = true);
    try {
      final stems = await pipeline.separateVocals(_task);
      if (!mounted) return;
      if (stems == null) {
        // 走到这儿说明这条任务压根没有可分离的原片。提示条本不该给出口，
        // 真给到了也不能一声不吭
        _showVocalsFailure('这条任务没有原片，分不出人声轨');
        return;
      }
      setState(() => _task = _task.copyWith(
          vocalsPath: stems.vocalsPath, backgroundPath: stems.backgroundPath));
      // 有了纯人声，预览要重新混一遍——否则听到的还是原声叠着新配乐
      _syncPreviewAudio();
      await _tasks!.saveVocals(_task, stems);
    } on VocalSeparationException catch (e) {
      AppLog.warn('单独分离人声轨失败（taskId=${widget.task.id}）：${e.message}');
      if (mounted) _showVocalsFailure(e.message);
    } catch (e) {
      AppLog.warn('单独分离人声轨失败（taskId=${widget.task.id}）：$e');
      if (mounted) _showVocalsFailure('人声分离失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _separatingVocals = false);
    }
  }

  /// 分离失败的说法。失败原因已经是人话了，原样给出去，并留一个再试一次的入口
  void _showVocalsFailure(String reason) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(reason),
      backgroundColor: AppColors.red,
      action: SnackBarAction(
          label: '再试一次',
          textColor: Colors.white,
          onPressed: () => unawaited(_separateVocals())),
    ));
  }

  /// 拖段落边界改长度。只改长度——曲子、备选、音量、预览版都不动
  Future<void> _resizeBgm(int startUnit, int newStart, int newEnd) =>
      _saveBgm(_task.bgm
          .resize(startUnit: startUnit, newStart: newStart, newEnd: newEnd));

  /// 点段落上的 × 删掉它。此前删一段要点开素材库浮层再点移除，太重
  /// 删一段配乐要确认：一点即删且不进撤销栈，误触的代价是重新找曲子、
  /// 重新铺区间——破坏性操作必须有确认（对照删除任务/清缓存的既有规则）
  Future<void> _deleteBgm(int startUnit) async {
    final segment = _task.bgm.segments
        .where((s) => s.startUnit == startUnit)
        .firstOrNull;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这段配乐？'),
        content: Text(segment == null
            ? '删除后需要重新选曲铺设。'
            : '「${segment.materials.first.name}」将从 U${segment.startUnit + 1}'
                '–U${segment.endUnit + 1} 移除，需要时要重新选曲铺设。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: FilledButton.styleFrom(backgroundColor: AppColors.red),
              child: const Text('删除')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _saveBgm(_task.bgm.removeSegment(startUnit));
  }

  /// 被整体替换的单元在成片里的时长（时间线上要标出「15.3s → 11.3s」）。
  /// 直接从画面轨读——每个整体替换单元就是轨上的一段
  Map<int, int> get _composedDurations {
    final tracks = _tracks;
    if (tracks == null) return const {};
    final units = _editor?.units ?? const [];
    final out = <int, int>{};
    for (var i = 0; i < units.length && i < (_replacements?.length ?? 0); i++) {
      final replacement = _replacements![i];
      if (replacement.mode != ReplacementMode.whole) continue;
      final id = replacement.wholePreviewId;
      final path = id == null ? null : _mediaCache?.localPathOf(id);
      if (path == null) continue;
      for (final segment in tracks.plan.video) {
        if (segment.source == path) {
          out[i] = segment.durationMs;
          break;
        }
      }
    }
    return out;
  }

  /// 传给 miaoa CLI 的 `--projects`；不限项目时为空
  List<int> get _projectIds =>
      _task.project == null ? const [] : [_task.project!.id];

  /// 点了配乐轨上已有的一段：换一首，或者移除
  Future<void> _editBgmSegment(BgmSegment segment) async {
    final editor = _editor;
    if (editor == null) return;
    final rangeMs = unitRangeMs(editor.units,
        from: segment.startUnit, to: segment.endUnit);
    final choice = await showBgmPicker(
      context,
      rangeMs: rangeMs,
      rangeLabel: _unitRangeLabel(segment.startUnit, segment.endUnit),
      canClear: true,
      projectIds: _projectIds,
      initialVolume: segment.volume,
      initialMaterials: segment.materials,
      initialPreviewIndex: segment.previewIndex,
    );
    if (choice == null || !mounted) return;
    await _saveBgm(switch (choice) {
      BgmVolumeChanged(:final volume) => _task.bgm
          .withVolume(startUnit: segment.startUnit, volume: volume),
      BgmPicked(:final materials, :final previewIndex, :final volume) =>
        _task.bgm.assign(
          startUnit: segment.startUnit,
          endUnit: segment.endUnit,
          materials: materials,
          previewIndex: previewIndex,
          rangeMs: rangeMs,
          volume: volume,
        ),
      BgmCleared() => _task.bgm.removeAt(segment.startUnit),
    });
  }

  /// 「U2–U4」这样的区间名。配乐按台词语义单元对齐（见 [BgmSegment.startUnit]）
  String _unitRangeLabel(int from, int to) =>
      from == to ? 'U${from + 1}' : 'U${from + 1}–U${to + 1}';

  Future<void> _saveBgm(BgmPlan next) async {
    setState(() => _task = _task.copyWith(bgm: next));
    // 选中就把曲子下到本地：素材库那边被删也不影响这条任务
    _pinBgm();
    // 配乐变了，预览音轨要跟着重合——否则加完配乐播放还是原声
    _syncPreviewAudio();
    try {
      await _tasks!.saveBgm(_task, next);
    } catch (e) {
      AppLog.warn('配乐方案落库失败（taskId=${widget.task.id}）：$e');
      if (mounted) _showSaveFailure('配乐方案');
    }
  }

  /// 改这条任务用哪些标签组，并按需立刻用新词表重打全片。
  ///
  /// 换了词表却不重打，标签还是按旧词表打的——那份标签既不在新词表里，
  /// 拿去检索素材也一个都对不上。所以这个对话框默认勾着「立即重打」。
  Future<void> _editTagGroups() async {
    final editor = _editor;
    if (editor == null) return;
    final picked = await showTaskTagGroupsDialog(
      context,
      unit: _task.unitTagGroups,
      shot: _task.shotTagGroups,
      unitPrompt: _task.unitTagPrompt,
      shotPrompt: _task.shotTagPrompt,
      project: _task.project,
    );
    if (picked == null || !mounted) return;

    // 打标的输入变没变：词表（标签组）与约束。项目不在其中
    final taggingChanged = !_sameGroups(_task.unitTagGroups, picked.unit) ||
        !_sameGroups(_task.shotTagGroups, picked.shot) ||
        _task.unitTagPrompt != picked.unitPrompt ||
        _task.shotTagPrompt != picked.shotPrompt;

    _task = _task.copyWith(
      unitTagGroups: picked.unit,
      shotTagGroups: picked.shot,
      unitTagPrompt: picked.unitPrompt,
      shotTagPrompt: picked.shotPrompt,
      project: picked.project,
      // 选了「不限项目」要真的清掉
      clearProject: picked.project == null,
    );
    try {
      await _tasks!.saveTagGroups(
        _task,
        unit: picked.unit,
        shot: picked.shot,
        unitPrompt: picked.unitPrompt,
        shotPrompt: picked.shotPrompt,
        project: picked.project,
      );
    } catch (e) {
      AppLog.warn('标签组落库失败（taskId=${widget.task.id}）：$e');
      if (mounted) _showSaveFailure('标签组');
      return;
    }
    if (!mounted) return;
    setState(() {});
    // 只改了项目就别重打：项目决定的是「上哪儿找替换素材」，
    // 跟怎么打标毫无关系，白跑一遍几分钟的云端推理
    if (!picked.retagNow || !taggingChanged) return;

    // 全片重打：换词表就是把整份标签作废了，只重打其中几个没有意义
    await _retag(EditConsequence(
      unitIndexes: [for (var i = 0; i < editor.units.length; i++) i],
      structural: true,
      maxChangedRatio: 1,
    ));
  }

  /// 「立刻去打标」。
  ///
  /// 先把受影响单元标记为待重打并落库，再送去打标：打标要走两趟云端推理，
  /// 中途失败或用户关掉窗口都是常事，标记留在盘上，界面上才看得出这些标签
  /// 已经过期，而不是让人拿着一份对不上画面的标签往下走。
  /// 正在切哪个单元的底片（下标）。切分要跑 ffmpeg 加云端复核，得让人看见
  int? _segmentingUnit;

  /// 底片被固定过的单元 → 那张底片在本地的路径。
  ///
  /// **抽帧、打标、合声音都要它**：那些镜头是按素材切的，跑去原片同一个
  /// 时间点取，拿到的是一段毫不相干的画面/声音，而哪儿都不报错
  Map<int, String> _baseVideoPaths() {
    final dataDir = ref.read(dataDirProvider);
    if (dataDir == null) return const {};
    final media = TaskMedia(dataDir: dataDir, taskId: _task.id);
    final out = <int, String>{};
    for (final u in (_editor?.units ?? const <SemanticUnit>[])) {
      if (u.baseCandidateId case final id?) {
        if (media.localMaterial(id) case final path?) out[u.index] = path;
      }
    }
    return out;
  }

  /// 把这个单元名下的画面/波形产物清掉。
  ///
  /// 它们是按**那一张底片**抽的，换一张、或者这个单元没了，就再也没人读
  /// ——不清的话反复试几次底片就是几十兆躺在盘上（「不留孤儿数据」）
  void _discardUnitArtifacts(String uid) {
    final dataDir = ref.read(dataDirProvider);
    if (dataDir == null || uid.isEmpty) return;
    final artifacts = TaskArtifacts(dataDir);
    artifacts.delete(artifacts.ofUnit(_task.id, uid));
  }

  /// 属性面板里的「这一段的底片」卡片
  Widget? _baseCard(int unitIndex, SemanticUnit unit) {
    final plans = _replacements ?? const <UnitReplacement>[];
    final plan = unitIndex < plans.length
        ? plans[unitIndex]
        : UnitReplacement.keepOriginal();
    final id = baseChoiceOf(unit: unit, replacement: plan) is MaterialBase
        ? (unit.baseCandidateId ?? plan.wholePreviewId)
        : null;
    return BaseSegmentCard(
      unit: unit,
      replacement: plan,
      materialName: id == null
          ? null
          : _task.pickedMaterials
              .firstWhereOrNull((m) => m.id == id)
              ?.name,
      segmenting: _segmentingUnit == unitIndex,
      retagging: _retaggingBaseUnit == unitIndex,
      onSegment: _isEditable && _lock == null
          ? () => _segmentUnitBase(unitIndex)
          : null,
      onUnpin: _isEditable && _lock == null && hasOwnBaseShots(unit)
          ? () => _unpinUnitBase(unitIndex)
          : null,
      onRetag: _isEditable && _lock == null
          ? () => _retagBaseUnit(unitIndex)
          : null,
    );
  }

  /// 正在给哪个单元的底片镜头打标
  int? _retaggingBaseUnit;

  /// 给切出来的这几镜打标。**按画面/标签搜素材全靠它**。
  ///
  /// 单独一条路而不是复用编辑后的重打标：那条要 [EditConsequence]，
  /// 而这里的触发点是人在底片卡片上点的按钮，只针对这一个单元
  Future<void> _retagBaseUnit(int unitIndex) async {
    final editor = _editor;
    if (editor == null) return;
    final tagging = ref.read(taggingServiceProvider);
    if (tagging == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('尚未配置 AI 服务，打不了标；补齐凭据后重启再试')));
      return;
    }
    // 顶栏那条横幅也要亮起来：底片卡片上那行小字得滚到才看得见，
    // 人在时间线/预览区域看不到任何东西在动，只会以为卡住了
    // （2026-09-15 真机：「得等到什么时候才可以预览啊，我一度以为是出 bug」）
    setState(() {
      _retaggingBaseUnit = unitIndex;
      _retaggingCount = 1;
    });
    try {
      late List<SemanticUnit> tagged;
      final usage = await AiUsageScope.collect(
        () async {
          tagged = await tagging.tag(_task, editor.units,
              only: {unitIndex}, baseVideoPaths: _baseVideoPaths());
        },
        onPartial: (partial) => _task =
            _task.copyWith(aiUsage: _task.aiUsage.merge(partial)),
      );
      _task = _task.copyWith(aiUsage: _task.aiUsage.merge(usage));
      if (!mounted) return;
      editor.replaceUnits(tagged);
      await _flushAutosave();
      if (!mounted) return;
      final shots = tagged[unitIndex].shots.length;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('U${unitIndex + 1} 的 $shots 个镜头打好标了，'
              '现在按画面搜素材就有结果了')));
    } catch (e) {
      AppLog.warn('底片镜头打标失败（taskId=${_task.id}, U$unitIndex）：$e');
      unawaited(_flushAutosave());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(userFacingError(e, fallback: '打标失败，请稍后重试')),
        backgroundColor: AppColors.red,
      ));
    } finally {
      if (mounted) {
        setState(() {
          _retaggingBaseUnit = null;
          _retaggingCount = 0;
        });
      }
    }
  }

  /// 切这一段的底片：把它切成视觉镜头，从此每一镜都能单独换素材。
  ///
  /// **显式触发**：这一步要跑 ffmpeg 采信号、还要云端复核灰区切点，
  /// 花钱也花时间。不在用户挑完素材时偷偷跑
  Future<void> _segmentUnitBase(int unitIndex) async {
    final editor = _editor;
    if (editor == null) return;
    final units = editor.units;
    if (unitIndex < 0 || unitIndex >= units.length) return;
    final unit = units[unitIndex];
    final plans = _replacements ?? const <UnitReplacement>[];
    final plan = unitIndex < plans.length
        ? plans[unitIndex]
        : UnitReplacement.keepOriginal();

    final blocked =
        BasePinOps.segmentBlockedReason(unit: unit, replacement: plan);
    if (blocked != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(blocked)));
      return;
    }
    final choice = baseChoiceOf(unit: unit, replacement: plan);
    if (choice is! MaterialBase) return;
    final candidateId = choice.candidateId;

    final segmenter = ref.read(unitSegmenterProvider);
    if (segmenter == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('尚未配置 AI 服务，切分用不了；补齐凭据后重启再试')));
      return;
    }
    final dataDir = ref.read(dataDirProvider);
    if (dataDir == null) return;
    final media = TaskMedia(dataDir: dataDir, taskId: _task.id);
    final basePath = media.localMaterial(candidateId);
    if (basePath == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('这条素材还没下到本地，等它下完再切')));
      return;
    }

    // **每次都问**：这一下不只是切，切完还接着送云端逐镜打标——
    // 花钱的动作不许点一下就跑起来。作废什么也一并说清
    final cost = BasePinOps.costOf(
        unit: unit, replacement: plan, candidateId: candidateId);
    final ok = await confirmPinBase(context,
        unitLabel: 'U${unit.index + 1}',
        cost: cost,
        repin: hasOwnBaseShots(unit));
    if (!ok || !mounted) return;

    setState(() => _segmentingUnit = unitIndex);
    try {
      final durationMs = _task.pickedMaterials
              .firstWhereOrNull((m) => m.id == candidateId)
              ?.durationMs ??
          unit.durationMs;
      final shots = await segmenter.segment(
        unit: unit,
        base: UnitBase(
            path: basePath,
            startMs: 0,
            endMs: durationMs,
            candidateId: candidateId),
        taskId: _task.id,
        fps: editor.fps,
      );
      if (!mounted) return;
      if (shots.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('这条素材读不出时长，切不了。换一条试试')));
        return;
      }
      // **顺手把这条素材转写一遍**：字幕要的是词级时间戳，原片那份量的是
      // 原片、跟这段画面毫无关系。转不出来不挡切分——那一段就是没字幕，
      // 字幕卡上会如实说，人也可以自己排
      final sentences = await ref.read(baseTranscriberProvider)?.transcribe(
            videoPath: basePath,
            key: '${_task.id}_u${unit.uid}',
          );
      final (nextUnits, nextPlans) = BasePinOps.pin(
          editor.units, _replacements ?? const [], unitIndex,
          candidateId: candidateId, shots: shots, sentences: sentences);
      editor.replaceUnits(nextUnits);
      await _onReplacementsChanged(nextPlans);
      await _flushAutosave();
      if (!mounted) return;
      // 新底片的画面和波形要现建一份，不然时间线上那一格是空的。
      // 上一张底片那几份先清掉——它们按那张片子抽的，换一张就不作数了
      _discardUnitArtifacts(unit.uid);
      _baseMedia = {..._baseMedia}..remove(unit.uid);
      unawaited(_loadBaseMedia());
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('U${unit.index + 1} 切成了 ${shots.length} 个镜头。'
              '画面现在就能预览，标签在后台接着打')));
    } catch (e) {
      AppLog.warn('切分这一段的底片失败（taskId=${_task.id}, U$unitIndex）：$e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(userFacingError(e, fallback: '切分失败，请检查原片后重试')),
        backgroundColor: AppColors.red,
      ));
    } finally {
      if (mounted) setState(() => _segmentingUnit = null);
    }

    // **切完就接着打标**：原片切出来的镜头是分析时顺带打好标的，底片切出来
    // 的也得一样——不打标，按画面/标签搜素材一条都搜不出来，这一段等于只切
    // 不能用。放在 finally 之后是为了让「正在切」的转圈先收掉，
    // 接着亮的是「正在打标」
    if (mounted && hasOwnBaseShots(_editor?.units[unitIndex] ?? unit)) {
      await _retagBaseUnit(unitIndex);
    }
  }

  /// 换一张底片：先把旧底片切出来的镜头和挂在上面的选择清掉
  Future<void> _unpinUnitBase(int unitIndex) async {
    final editor = _editor;
    if (editor == null) return;
    final units = editor.units;
    if (unitIndex < 0 || unitIndex >= units.length) return;
    final unit = units[unitIndex];
    final ok = await confirmUnpinBase(context,
        unitLabel: 'U${unit.index + 1}', shotCount: unit.shots.length);
    if (!ok || !mounted) return;
    _baseMedia = {..._baseMedia}..remove(unit.uid);
    _discardUnitArtifacts(unit.uid);
    final (nextUnits, nextPlans) =
        BasePinOps.unpin(editor.units, _replacements ?? const [], unitIndex);
    editor.replaceUnits(nextUnits);
    await _onReplacementsChanged(nextPlans);
    await _flushAutosave();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('U${unit.index + 1} 的底片已清掉，重新挑一条素材吧')));
  }

  Future<void> _retag(EditConsequence consequence) async {
    final editor = _editor;
    if (editor == null) return;
    editor.replaceUnits(consequence.markForRetag(editor.units));
    await _flushAutosave();
    if (!mounted) return;

    final tagging = ref.read(taggingServiceProvider);
    if (tagging == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('尚未配置 AI 服务，已标记为待重打；补齐凭据后可再次重打')));
      return;
    }

    setState(() => _retaggingCount = consequence.unitIndexes.length);
    try {
      // 重打标是「花费不停累积」的主要来源：用户改一次切分就走一趟云端推理，
      // 记账要跟着（见 [AiUsageScope]）
      late List<SemanticUnit> tagged;
      final usage = await AiUsageScope.collect(
        () async {
          tagged = await tagging.tag(_task, editor.units,
              only: consequence.unitIndexes.toSet(),
              baseVideoPaths: _baseVideoPaths());
        },
        onPartial: (partial) => _task =
            _task.copyWith(aiUsage: _task.aiUsage.merge(partial)),
      );
      _task = _task.copyWith(aiUsage: _task.aiUsage.merge(usage));
      if (!mounted) return;
      editor.replaceUnits(tagged);
      await _flushAutosave();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('已重新打标 ${consequence.unitIndexes.length} 个台词语义单元')));
    } catch (e) {
      AppLog.warn('重新打标失败（taskId=${widget.task.id}）：$e');
      // 失败也要把已经花掉的记上，并落库
      unawaited(_flushAutosave());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('重新打标失败，标签已标记为待重打，可稍后重试'),
        backgroundColor: AppColors.red,
      ));
    } finally {
      if (mounted) setState(() => _retaggingCount = 0);
    }
  }

  /// 每次改动都自动落库：只要不按 ⌘Z，下次进来就是上次的状态。
  ///
  /// 因此没有「保存草稿」也没有「确认切分」——那两个动作存在的前提是
  /// 「有未保存状态」，而现在没有。
  void _scheduleAutosave() {
    _autosaveTimer?.cancel();
    _autosaveTimer = Timer(
        const Duration(milliseconds: 800), () => unawaited(_flushAutosave()));
  }

  Future<void> _flushAutosave() async {
    _autosaveTimer?.cancel();
    _autosaveTimer = null;
    final editor = _editor;
    if (editor == null || !_isEditable) return;
    final units = editor.units;
    if (_savedUnits != null &&
        const ListEquality<SemanticUnit>().equals(_savedUnits!, units)) {
      return;
    }
    try {
      await _tasks!.saveSegmentationDraft(_task, units);
      _task = _task.copyWith(units: units);
      _savedUnits = units;
    } catch (e) {
      // 存不上必须让用户知道，否则他以为改动已经留住了
      AppLog.warn('自动保存失败（taskId=${widget.task.id}）：$e');
      if (mounted) _showSaveFailure('自动保存');
    }
  }

  /// 解析媒体构建器与其工作目录：注入假 builder（测试）时用一次性临时目录，
  /// 缺省（生产）时用真实 builder + 与分析管线一致的持久化目录（便于复用缓存）
  Future<({TimelineMediaBuilder builder, Directory workDir})> _resolveMedia() async {
    final injected = widget.mediaBuilder;
    if (injected != null) {
      return (
        builder: injected,
        workDir: Directory.systemTemp.createTempSync('ishkafel_wb_'),
      );
    }
    final dataDir = ref.read(dataDirProvider);
    if (dataDir == null) {
      throw StateError('工作台缺少数据目录配置');
    }
    final workDir = Directory(p.join(dataDir.path, 'analysis_work'));
    return (
      builder: TimelineMediaBuilder(
          thumbnails: ThumbnailService(), audio: AudioExtractor()),
      workDir: workDir,
    );
  }

  /// 正在加载画面/音频轨，别重复起一份
  bool _loadingMedia = false;

  /// **底片固定过的单元各自的画面与波形**（单元 uid → 它那条素材的）。
  ///
  /// 这几段的画面来自素材而不是原片，原片那份缩略图里根本没有它们。
  /// 不单独建一份，时间线上那一格就永远是空的——而它明明有画面有声音
  /// （2026-09-15 真机：「画面和音频还是空的」）
  ///
  /// **每次换成新 Map**：原地改同一个实例的话，下游拿到的 old/new 是同一个
  /// 对象，`didUpdateWidget` 比不出变化，解码永远不会重跑——图抽好了躺在
  /// 盘上，时间线上那一格照旧是空的（2026-09-15 真机就卡在这一步）
  Map<String, TimelineMedia> _baseMedia = const {};

  /// 加载时间线的画面缩略图与音频波形。
  ///
  /// **读 [_task] 而不是 [widget.task]**：进页面那一刻任务可能还在分析，
  /// `videoInfo` 要等分析完才有。拿进门时的快照判一次就再也不看，那两条轨
  /// 会一直空着，要退出去重进才出来（2026-09-15 真机：「这个音频和画面轨
  /// 是空的？分析完之后是不是应该补上」）。
  Future<void> _loadMedia() async {
    // **底片那几段先建**：它们跟有没有原片毫无关系（拼片任务一条原片都
    // 没有，照样每一段都有画面）。放在下面那个 return 后头的话，
    // 没有原片的任务永远走不到，那几格就一直空着
    unawaited(_loadBaseMedia());
    if (_loadingMedia || _media != null) return;
    final videoInfo = _task.videoInfo;
    final sourcePath = _task.sourcePath;
    // 空白任务没有原片，也就没有原片缩略图这一条轨；
    // 有原片但还没分析出元信息的，等 [_adoptAnalysis] 收到之后再来
    if (videoInfo == null || sourcePath == null) return;
    _loadingMedia = true;
    try {
      final resolved = await _resolveMedia();
      final media = await resolved.builder.build(
        videoPath: sourcePath,
        taskId: _task.id,
        durationMs: videoInfo.duration.inMilliseconds,
        workDir: resolved.workDir,
      );
      if (!mounted) return;
      setState(() => _media = media);
    } catch (e) {
      AppLog.warn('时间线媒体加载失败（taskId=${_task.id}）：$e');
      if (!mounted) return;
      setState(() => _mediaFailed = true);
    } finally {
      _loadingMedia = false;
    }
  }

  /// 给每个固定过底片的单元建一份它自己的画面与波形。
  ///
  /// 缓存文件名带上单元身份（`<taskId>_u<uid>`），既和原片那份分开，
  /// 又仍然算在这条任务名下（[artifactBelongsTo] 认 `taskId_` 前缀），
  /// 删任务时跟着一起清
  Future<void> _loadBaseMedia() async {
    final editor = _editor;
    final dataDir = ref.read(dataDirProvider);
    if (editor == null || dataDir == null) return;
    final media = TaskMedia(dataDir: dataDir, taskId: _task.id);
    for (final unit in editor.units) {
      final id = unit.baseCandidateId;
      if (id == null || unit.uid.isEmpty) continue;
      if (_baseMedia.containsKey(unit.uid)) continue;
      final path = media.localMaterial(id);
      if (path == null) continue;
      // 这一段在成片里多长，就按多长去抽帧和算波形
      final durationMs = unit.shots.isEmpty
          ? unit.durationMs
          : unit.shots.last.endMs - unit.startMs;
      if (durationMs <= 0) continue;
      try {
        final resolved = await _resolveMedia();
        final built = await resolved.builder.build(
          videoPath: path,
          taskId: '${_task.id}_u${unit.uid}',
          durationMs: durationMs,
          workDir: resolved.workDir,
        );
        if (!mounted) return;
        setState(() => _baseMedia = {..._baseMedia, unit.uid: built});
      } catch (e) {
        // 这一格画不出来不该拖垮整条时间线；轨道上那一段会照旧标出来
        AppLog.warn('底片画面/波形加载失败（U${unit.index + 1}）：$e');
      }
    }
  }

  /// 审核候选：人挑完（或 Agent 挑完）在这里过一遍再导。
  ///
  /// 内嵌模式：审核页把决定交回来，在**本会话**里应用并走既有的落库通路
  /// ——同一个人的同一次编辑，没有第二把锁
  Future<void> _openReview() async {
    final outcome = await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReviewPage(
          task: _task.copyWith(
              replacementsByUid: _byUid(_replacements),
              units: _editor?.units),
          onApply: (decisions) {
            final pruned = applyReviewDecisions(
                _replacements ?? const [], decisions);
            unawaited(_onReplacementsChanged(pruned));
          },
          // 审核页改的标签由这边落库：内嵌时它和工作台是同一次会话，
          // 两边各写各的整份任务对象，谁后写谁赢（人在审核页改的会被
          // 工作台的下一次保存抹掉）。走 replaceUnits 是为了让 ⌘Z 也管得着
          onTagsChanged: (units) => _editor?.replaceUnits(units),
        ),
      ),
    );
    if (outcome is ReviewOutcome && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('审核完成：保留 ${outcome.kept} 条 · '
              '剔除 ${outcome.dropped} 条')));
    }
  }

  /// 进入矩阵导出。
  ///
  /// 这里曾经是「确认切分，进入替换选材」——切分和选材已经合并在本工作台里
  /// 交替进行，那道闸门连同它的落库副作用一并删掉了（改动现在随手就存）。
  bool _jianyingBusy = false;

  /// 预览画面上这一刻该显示的那行字。**只有被我们换掉画面的镜头才有**——
  /// 没换的镜头，台词字幕烧在原素材的像素里，再叠一层就是两行字打架。
  ///
  /// 这一层是**现画**的（见 [PreviewSubtitleLayer]）：调样式不重渲切片、
  /// 不换播放源，所以既不转圈也不跳回片头
  String? _previewSubtitleAt(int composedMs) {
    final editor = _editor;
    if (editor == null) return null;
    return previewSubtitleAt(
      composedMs: composedMs,
      timeline: ComposedTimeline.of(
          units: editor.units, wholeDurations: _composedDurations),
      replacements: _replacements ?? const [],
      track: _task.subtitleTrack,
      sentences: _task.asrSentences ?? const [],
    );
  }

  /// 直接把画面上的字幕拖到想要的高度——比在面板里拧「距底 21%」直观得多
  Future<void> _dragSubtitleTo(double bottomRatio) async {
    final next = _task.copyWith(
        subtitle: _task.subtitle.copyWith(bottomRatio: bottomRatio),
        updatedAt: DateTime.now());
    setState(() => _task = next);
    await ref.read(taskRepositoryProvider).save(next);
  }

  /// 改字幕样式。**主要用途是遮挡**：素材自带烧录字幕时（库里不少见，
  /// 而且画面描述里一个字都看不出来），默认的白字黑描边盖不住，
  /// 原字幕会从描边缝里透出来；切成底条或毛玻璃才能盖住。
  Future<void> _editSubtitleStyle() async {
    final before = _task.subtitle;
    // 浮层不是模态弹窗，页面被销毁它不会自己走——留住句柄，dispose 里兜底
    final panel = _subtitleStylePanel = showSubtitleStylePanel(context,
        initial: before, onPreview: _previewSubtitleStyle);
    final picked = await panel.done;
    if (identical(_subtitleStylePanel, panel)) _subtitleStylePanel = null;
    if (!mounted) return;
    if (picked == null) {
      // 取消 = 不要这套。调的过程中已经把预览改成半路那一套了，退回去
      if (_task.subtitle.fingerprint != before.fingerprint) {
        setState(() => _task = _task.copyWith(subtitle: before));
      }
      return;
    }
    final next = _task.copyWith(subtitle: picked.$1, updatedAt: DateTime.now());
    // 预览的字幕是现画的一层，setState 就已经重画了——不推轨道、不换源
    setState(() => _task = next);
    await ref.read(taskRepositoryProvider).save(next);
  }

  /// 开着的字幕样式浮层（见 [showSubtitleStylePanel]）
  SubtitleStylePanel? _subtitleStylePanel;

  /// 边调边看：样式改一下画面上的字就跟着变。
  ///
  /// **一次 ffmpeg 都不跑**——字幕是画上去的一层，不是烧进切片的像素。
  /// 以前烧在切片里，所以这里还得节流、还得重推轨道，人看到的是每动一下
  /// 转一次圈再弹回片头（用户原话：「这个跳转太煞笔了」）。
  ///
  /// **只改内存、不落盘**——人还没点「就这样」，这套样式随时可能被取消。
  void _previewSubtitleStyle(SubtitleStyle style) {
    // 比指纹，不比对象：SubtitleStyle 没有值相等，`==` 只会永远为假
    if (!mounted || _task.subtitle.fingerprint == style.fingerprint) return;
    setState(() => _task = _task.copyWith(subtitle: style));
  }

  /// 还有几条素材没落到本地、其中几条是彻底下不下来的。
  ///
  /// 画面素材与配乐用同一把闸：任何一样没齐都不给导出、也不给写剪映工程
  /// ——工程里少一段素材，人要到剪映里才发现。抽出来是因为导出和剪映
  /// 两个出口都要问同一个问题，各算各的迟早会漂
  (int pending, int failed) get _mediaReadiness {
    var pending = 0;
    var failed = 0;
    for (final cache in [_mediaCache, _bgmMediaCache]) {
      if (cache == null) continue;
      for (final id in cache.notReady) {
        pending++;
        if (cache.statusOf(id) == PickedMediaStatus.failed) failed++;
      }
    }
    return (pending, failed);
  }

  /// 写成一份剪映工程：所有候选摞成多条轨，人在剪映里边看边切。
  ///
  /// **和导出成片是两个出口**：导出出的是定死的成片，这里交出去的是
  /// 还没定死的选择。不拉起剪映——它没有给外部程序「打开指定草稿」的通道。
  Future<void> _openJianying() async {
    final task = _task;
    final units = task.units;
    if (units == null || units.isEmpty) return;
    final dataDir = ref.read(dataDirProvider);
    if (dataDir == null) return;
    // 素材没落到本地就别开工：工程里少一段，人要到剪映里才发现
    final (pending, failed) = _mediaReadiness;
    if (exportBlockedReason(_plan, pendingMedia: pending, failedMedia: failed)
        case final blocked?) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(blocked)));
      return;
    }
    setState(() => _jianyingBusy = true);
    // 一百多个素材要归集到工程目录，不能让人对着一个卡住的窗口猜
    final progress = ValueNotifier<LongTaskProgress?>(
        const LongTaskProgress('正在核对方案'));
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => LongTaskDialog(progress: progress, title: '正在生成剪映工程'),
    ));
    try {
      final media = TaskMedia(dataDir: dataDir, taskId: task.id);
      final durations = {
        for (final m in task.pickedMaterials) m.id: m.durationMs,
      };
      final plan = buildRenewJianyingPlan(
        units: units,
        replacements: _replacements ?? const [],
        sourcePath: task.sourcePath ?? '',
        sourceTotalMs: task.videoInfo?.duration.inMilliseconds ?? 0,
        materialOf: media.localMaterial,
        materialDurationOf: (id) => durations[id] ?? 0,
        sentences: task.asrSentences ?? const [],
        bgm: task.bgm,
        bgmPathOf: media.localBgm,
      );
      final result = await JianyingWriter(sourceOf: (_) => null).writePlan(
        plan,
        taskName: '#${task.seq ?? ''} ${task.name}'.trim(),
        subtitle: task.subtitle,
        onProgress: (done, total, what) =>
            progress.value = LongTaskProgress(
                '$what（$done/$total）', total <= 0 ? null : done / total),
      );
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      await _showJianyingDone(result, plan.videoTracks.length);
    } on JianyingPlanException catch (e) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      AppLog.warn('剪映草稿生成失败：$e');
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('生成剪映草稿失败，请稍后重试。')));
    } finally {
      progress.dispose();
      if (mounted) setState(() => _jianyingBusy = false);
    }
  }

  /// 生成完的交代：草稿叫什么、去哪儿开、那些轨是怎么回事。
  /// **不许只弹一句「成功」**——人下一步要做什么必须说清楚
  Future<void> _showJianyingDone(JianyingDraftResult result, int tracks) =>
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('剪映工程已生成'),
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
                  '$tracks 条画面轨 · ${result.materialCount} 个素材',
                  style: const TextStyle(
                      fontSize: AppFontSize.caption,
                      color: AppColors.textSecondary)),
              const SizedBox(height: AppSpacing.md),
              const Text('打开剪映，在「本地草稿」里找到它继续编辑。',
                  style: TextStyle(
                      fontSize: AppFontSize.body,
                      color: AppColors.textPrimary)),
              const SizedBox(height: AppSpacing.xs),
              const Text('同一个位置挑的候选摞成了好几条轨，上面那条盖着下面的——'
                  '想用别的候选，把上面那条关掉就行。',
                  style: TextStyle(
                      fontSize: AppFontSize.caption,
                      color: AppColors.textSecondary)),
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
                // 只是把剪映拉起来——它没有「打开指定草稿」的通道，
                // 草稿名在上面写着，人自己去列表里点
                try {
                  await launchJianying();
                } catch (error) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(this.context).showSnackBar(
                    SnackBar(
                        content: Text(userFacingError(error,
                            fallback: '操作失败，请稍后重试'))),
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

  Future<void> _openExport() async {
    final editor = _editor;
    if (editor == null) return;
    // 成片放到「影片」目录下按任务分文件夹：跟原片、跟缓存都分开，
    // 用户拿完就走，不必在应用数据目录里翻
    final fallbackOutputDir = Directory(p.join(PlatformPaths().videosDirectory, 'ishkafel',
        safePathSegment('${_task.name}_${_task.id}')));
    final outputDir = initialExportDirectory(
      lastUsable: _lastUsableExportDir(),
      configuredDefault: ref.read(defaultExportDirectoryProvider),
      fallback: fallbackOutputDir,
    );
    await showExportDialog(
      context,
      taskId: _task.id,
      taskName: _task.name,
      sourcePath: _task.sourcePath,
      units: editor.units,
      replacements: _replacements ?? const [],
      bgm: _task.bgm,
      voiceAudio: _voiceAudio,
      // 导出前要核对「选了音色的单元是不是都生成了配音」——少了会静默出原声
      voices: _task.voices,
      vocalsPath: _task.vocalsPath,
      // 镜头替换的切片上重渲台词字幕（原片字幕烧在被换掉的画面里）
      subtitleSentences: _task.asrSentences ?? const [],
      subtitleStyle: _task.subtitle,
      // 导出帧率默认跟着原片走（时间线就是按它数帧的）
      sourceFps: _task.videoInfo?.fps ?? 0,
      materialAudio: _task.materialAudio,
      // 「原片这一镜的声音」也要带上——只传素材那一层的话，人在属性面板里
      // 设的档位只在预览里生效，导出来的片子还是老样子
      sourceAudio: _task.sourceAudio,
      backgroundPath: _task.backgroundPath,
      // 人手改过的那几镜的字幕，以他改的为准
      subtitleTrack: _task.subtitleTrack,
      // 上次导到哪儿就默认还导到哪儿——同一个项目往往一直往同一个位置出片。
      // 但临时目录不算数：CLI 测试之类导进 /tmp 的一次性位置被记成默认，
      // 下次成片就会落进重启即清的地方（真机踩过）
      outputDir: outputDir,
      onExported: _recordExport,
      exports: _task.exports,
      // 整体替换的成片时长跟候选走——不给这个，确认页会按原片长度报，
      // 和底部摘要写的成片时长对不上
      pickedMaterials: _task.pickedMaterials,
      materialDurations: {
        for (final m in _task.pickedMaterials)
          if (m.durationMs != null) m.id: m.durationMs!,
      },
    );
  }

  /// 把这一次导出记进项目。
  ///
  /// 项目没有终态（原片放在那儿，明天换一批素材还能再导），有始有终的是每
  /// 一次导出——「哪天、导了几条、成了几条、在哪个目录」。
  Future<void> _recordExport(ExportRecord record) async {
    try {
      await _tasks!.addExportRecord(_task, record);
      if (mounted) {
        setState(() =>
            _task = _task.copyWith(exports: [..._task.exports, record]));
      }
    } catch (e) {
      // 记不上不该影响已经导好的片子，但要留痕
      AppLog.warn('导出记录落库失败（taskId=${widget.task.id}）：$e');
    }
  }

  /// 任务名会进文件路径，斜杠与冒号在 macOS 上都是雷
  /// 上一次导出的目录，仅当它还值得再用：临时目录（/tmp、/private/tmp）
  /// 重启就清，不能当默认；已经不存在的也不指过去
  Directory? _lastUsableExportDir() {
    if (_task.exports.isEmpty) return null;
    final last = _task.exports.last.outputDir;
    if (PlatformPaths().isTemporaryPath(last)) return null;
    final dir = Directory(last);
    return dir.existsSync() ? dir : null;
  }

  /// 保存类操作失败的统一用户提示：说清做什么失败了与可能的原因，
  /// 不把原始异常文本摊给用户（详情已进日志）。
  /// [retry] 非空时给「重试」按钮——文案叫人重试就必须给重试的入口，
  /// 否则用户只能把刚才的操作从头做一遍
  void _showSaveFailure(String what, {VoidCallback? retry}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$what保存失败，请检查磁盘空间后重试'),
        backgroundColor: AppColors.red,
        action: retry == null
            ? null
            : SnackBarAction(label: '重试', textColor: Colors.white, onPressed: retry),
      ),
    );
  }

  /// 返回。改动是随手落库的，没有「未保存」这回事，因此不再拦截——
  /// 只把还在防抖窗口里的那次改动补写掉，否则改完立刻返回会丢。
  Future<void> _handleBackRequest() async {
    await _flushAutosave();
    if (!mounted) return;
    Navigator.of(context).maybePop();
  }

  /// 把「哪些单元/镜头挑过替换素材」推给编辑器——挑过的就钉死切分。
  ///
  /// 为什么必须钉：替换方案按下标记。切一刀、并一次，下标全变，原本钉在
  /// S6 上的素材就跑到别的镜头上去了；改边界则会让已经按旧时长变速好的
  /// 切片全部作废，而用户毫不知情。见 [EditLocks]
  void _syncEditLocks() =>
      _editor?.locks = EditLocks.of(_replacements ?? const [],
          semanticUnits: _editor?.units ?? const []);

  /// 把替换方案落盘。**重排/删单元这类「顺带改到方案」的操作用它**——
  /// 失败要说出来，不然人只会在下次打开时发现素材跑到了别人身上
  Future<void> _savePickingPlanQuietly(List<UnitReplacement> next) async {
    try {
      await _tasks!.savePickingPlan(_task, next);
    } catch (e) {
      AppLog.warn('替换方案落库失败（taskId=${widget.task.id}）：$e');
      if (mounted) _showSaveFailure('替换方案');
    }
  }

  /// 右栏改了替换方案：立刻落库，并让底部栏的组合数与 tab 角标跟着更新
  Future<void> _onReplacementsChanged(List<UnitReplacement> next) async {
    if (!_isEditable) return;
    setState(() => _replacements = next);
    _syncEditLocks();
    _pinMaterials();
    try {
      await _tasks!.savePickingPlan(_task, next);
      _task = _task.copyWith(replacementsByUid: _byUid(next));
    } catch (e) {
      AppLog.warn('替换方案落库失败（taskId=${widget.task.id}）：$e');
      if (mounted) _showSaveFailure('替换方案');
    }
  }

  /// 右栏落地了新的已选素材：跟着存盘。存失败不打断选材——盘上少一条记录
  /// 只影响「下次进来还看不看得见」，不影响这次的方案。
  /// 但**要说出来**：静默吞掉的话，用户明天进来发现挑好的素材"丢了"，
  /// 只会以为软件坏了
  Future<void> _onPickedMaterialsChanged(List<PickedMaterial> next) async {
    if (!_isEditable) return;
    if (const DeepCollectionEquality().equals(_task.pickedMaterials, next)) {
      return;
    }
    try {
      await _tasks!.savePickedMaterials(_task, next);
      _task = _task.copyWith(pickedMaterials: next);
    } catch (e) {
      AppLog.warn('已选素材落库失败（taskId=${widget.task.id}）：$e');
      if (mounted) {
        _showSaveFailure('已选素材', retry: () => _onPickedMaterialsChanged(next));
      }
    }
  }

  /// 已选素材本体的本地固定。全应用共用一份缓存目录（和导出读的是同一个），
  /// 但固定集合是按任务来的——所以每个工作台各持一个实例
  PickedMediaCache? _mediaCache;

  /// 配乐同理：选中就下到本地，别人在素材库那边删了也不影响这条任务。
  /// 此前配乐是「用到才下」，从选完到导出中间同样有被删的窗口
  PickedMediaCache? _bgmMediaCache;

  /// 下载动作来自 [materialFetcherProvider]（和导出读同一个缓存目录）；
  /// 没接（测试环境）就不固定
  PickedMediaCache? _buildMediaCache() {
    final fetch = ref.read(materialFetcherProvider);
    final dataDir = ref.read(dataDirProvider);
    if (fetch == null || dataDir == null) return null;
    // 下完顺手转成预览代理——预览链路上每一段都是同一个规格，播放器在接缝处
    // 才不必重建解码器（见 [ProxySpec]）。**导出不走这里**，它读的是
    // materials/<taskId>/ 下的原始下载
    return PickedMediaCache(
      fetch: (id) async => _proxyBuilder(dataDir)
          .build(path: await fetch(_task.id, id), frameRate: _frameRateArg),
      cacheDir: TaskMedia(dataDir: dataDir, taskId: _task.id).materialsDir,
    );
  }

  /// 预览代理的生成器。原片与候选素材共用一条路、共用一份缓存目录：
  /// 同一个内容指纹只转一次
  ProxyBuilder _proxyBuilder(Directory dataDir) => ProxyBuilder(
        cache: RenderedCache(
          dir: Directory(p.join(dataDir.path, 'preview_proxy')),
          run: const ResolvingProcessRunner().call,
        ),
        run: const ResolvingProcessRunner().call,
      );

  /// 代理跟着原片的帧率走——帧率一变，时间线上每一帧的位置都要重算，
  /// 而本产品所有切分边界都是按帧对齐的
  String get _frameRateArg =>
      frameRateArg(widget.task.videoInfo?.fps ?? 30);

  /// 原片的预览代理。转好之后重推轨道换上去；转不动就一直播原片
  Future<void> _buildSourceProxy() async {
    final dataDir = ref.read(dataDirProvider);
    final tracks = _tracks;
    final sourcePath = widget.task.sourcePath;
    // 空白任务没有原片，也就没有原片代理要转
    if (dataDir == null || tracks == null || sourcePath == null) return;
    final path = await _proxyBuilder(dataDir)
        .build(path: sourcePath, frameRate: _frameRateArg);
    if (!mounted || path == sourcePath) return;
    tracks.proxyPath = path;
    _syncPreviewAudio();
  }



  /// 配乐的固定。曲子按 id 从当前方案里找——方案里存的就是完整的
  /// [BgmMaterial]，不必再去库里查一次
  PickedMediaCache? _buildBgmMediaCache() {
    final fetch = ref.read(bgmFetcherProvider);
    final dataDir = ref.read(dataDirProvider);
    if (fetch == null || dataDir == null) return null;
    return PickedMediaCache(
      extension: 'mp3',
      fetch: (id) {
        final material = _task.bgm.materialById(id);
        if (material == null) {
          throw StateError('这首配乐已经不在方案里了');
        }
        return fetch(_task.id, material);
      },
      cacheDir: TaskMedia(dataDir: dataDir, taskId: _task.id).bgmDir,
    );
  }

  /// 把方案里用到的配乐固定住。选完、改完、刚进工作台都要调一次
  void _pinBgm() {
    _bgmMediaCache?.pinAll({for (final m in _task.bgm.materials) m.id});
  }

  /// 把方案里用到的替换素材固定住——**打开工作台就做，不等用户点开选材面板**。
  ///
  /// 此前这一步只在「替换素材」那个 tab 里做。于是打开一条早就选好素材的任务、
  /// 直接按播放，素材从没被固定过，预览读的是 material_cache 里**没有代理化**
  /// 的原始下载：规格和别的段落对不上，接缝处照旧要重建解码器。配乐那边早就是
  /// 进工作台就固定的，素材没有理由两样。
  void _pinMaterials() {
    final cache = _mediaCache;
    final replacements = _replacements;
    if (cache == null || replacements == null) return;
    // 底片也要固定住（规则见 [referencedCandidateIds]）——漏了它，
    // 那条素材会被当成没人要的缓存清掉，预览整段变黑
    cache.pinAll(referencedCandidateIds(
        _editor?.units ?? const <SemanticUnit>[], replacements));
  }

  /// 首帧图落在任务数据目录下。没有数据目录（测试环境）就不落地——
  /// 托盘照样能画，只是重开就没了
  PickedMaterialStore? get _defaultPickedStore {
    final dataDir = ref.read(dataDirProvider);
    if (dataDir == null) return null;
    return PickedMaterialStore(
      dir: Directory(p.join(dataDir.path, 'picked_thumbs', widget.task.id)),
      fetch: httpBytes,
      frameChecker: ref.read(frameCheckerProvider),
    );
  }


  /// 素材/配乐的落地状态变了就重画底部栏——导出按钮的可用性挂在它上面
  void _onMediaCacheChanged() {
    if (mounted) setState(() {});
    unawaited(_backfillDurations());
    // 素材刚落地/刚规格化完，轨道要换上真正该播的那一份。少了这一句，
    // 预览会一直播启动那一刻的约定路径——也就是**没规格化过的原始下载**，
    // 于是替换点照旧要重建解码器，规格化等于白做
    _syncPreviewAudio();
  }

  /// 补齐已选素材的时长。
  ///
  /// 勾选那一刻规格可能还在探测中，落地记录里就存了个空——而整体替换要靠它
  /// 算「这一段在成片里有多长」。缺了的话会按原坑位长度铺，EDL 里写的
  /// length 比候选本身还长，播到候选结尾那一段就没东西了（真机上就这么错的）。
  ///
  /// 素材本来就固定在本地，ffprobe 一次几十毫秒，补完写回任务，之后不再探。
  Future<void> _backfillDurations() async {
    final cache = _mediaCache;
    if (cache == null || _backfillingDurations) return;
    final missing = [
      for (final m in _task.pickedMaterials)
        if (m.durationMs == null && cache.localPathOf(m.id) != null) m,
    ];
    if (missing.isEmpty) return;

    _backfillingDurations = true;
    try {
      final probe = FfprobeService(run: const ResolvingProcessRunner().call);
      final updated = <int, int>{};
      for (final m in missing) {
        try {
          final ms = (await probe.probe(cache.localPathOf(m.id)!))
              .duration
              .inMilliseconds;
          if (ms > 0) updated[m.id] = ms;
        } catch (e) {
          // 探不出来就先空着，下次进来再试；不要用 0 顶——那会把后面所有
          // 段落挤成一团
          AppLog.warn('补取已选素材 ${m.id} 的时长失败：$e');
        }
      }
      if (updated.isEmpty || !mounted) return;
      await _onPickedMaterialsChanged([
        for (final m in _task.pickedMaterials)
          updated.containsKey(m.id)
              ? PickedMaterial(
                  id: m.id,
                  name: m.name,
                  voiceover: m.voiceover,
                  sceneDescription: m.sceneDescription,
                  thumbPath: m.thumbPath,
                  durationMs: updated[m.id],
                )
              : m,
      ]);
      _syncPreviewAudio();
    } finally {
      _backfillingDurations = false;
    }
  }

  bool _backfillingDurations = false;

  ReplacementPlan get _plan => ReplacementPlan(_replacements ?? const []);

  String _summaryText(SegmentationEditorController editor) =>
      workbenchSummaryText(
        units: editor.units,
        durationMs: editor.durationMs,
        dirty: editor.dirty,
        hasTagGroups: widget.task.unitTagGroup != null ||
            widget.task.shotTagGroup != null,
        composedMs: _tracks?.plan.totalMs,
        blankFill: _task.isBlank
            ? BlankUnitOps.filledStat(editor.units,
                durationOf: _pickedDurationOf)
            : null,
      );

  /// 这个分子挑中的素材有多长；null 表示还没挑。空白任务的时长统计靠它
  int? _pickedDurationOf(int unitIndex) {
    final units = _editor?.units ?? const <SemanticUnit>[];
    // **固定过底片的分子当然算「已填」**：它的画面就是那条素材，而且已经
    // 按它切成了镜头。只看整体替换的候选会把它算成没填——切完分镜之后
    // 底部立刻变成「一条素材都没挑」，人会以为刚才那一下把东西弄丢了
    if (unitIndex < units.length && hasOwnBaseShots(units[unitIndex])) {
      return units[unitIndex].shots.last.endMs - units[unitIndex].startMs;
    }
    final replacements = _replacements ?? const [];
    if (unitIndex >= replacements.length) return null;
    final replacement = replacements[unitIndex];
    if (replacement.mode != ReplacementMode.whole) return null;
    final id = replacement.wholePreviewId ??
        (replacement.wholeCandidateIds.isEmpty
            ? null
            : replacement.wholeCandidateIds.first);
    if (id == null) return null;
    for (final material in _task.pickedMaterials) {
      if (material.id == id) return material.durationMs;
    }
    return null;
  }

  /// 把盘上新打好的标签接回来。
  ///
  /// 只补标签，**不碰切分**：这几分钟里人可能一直在拖边界，那些改动以他的
  /// 为准（[mergeTagsInto] 只认边界没变的单元）。没有可补的就什么都不做——
  /// 每次列表刷新都无脑回填会把 undo 栈灌满，⌘Z 就废了。
  void _adoptTags(List<RenewTask>? tasks) {
    final editor = _editor;
    if (editor == null || tasks == null) return;
    final fresh = tasks.where((t) => t.id == widget.task.id).firstOrNull;
    if (fresh == null) return;
    _adoptAnalysis(fresh);
    final stored = fresh.units;
    if (stored == null) return;
    final merged = mergeTagsInto(editor.units, stored);
    if (identical(merged, editor.units)) return;
    editor.replaceUnits(merged);
  }

  /// 分析跑完补上来的**原片元信息**（时长、帧率）要接住。
  ///
  /// 人是切分一好就被放进这一页的，那时分析还没跑完、`videoInfo` 还是空的
  /// ——画面轨和音频轨于是一直空着，而它们要等的东西早就在盘上了。
  /// 只补一次：拿到之后就去把那两条轨建起来
  void _adoptAnalysis(RenewTask fresh) {
    if (_task.videoInfo != null || fresh.videoInfo == null) return;
    _task = _task.copyWith(
      videoInfo: fresh.videoInfo,
      // 人声/背景轨也是分析产出的，同一趟接过来——「这一镜的声音」选
      // 人声/背景声那两档要靠它
      vocalsPath: fresh.vocalsPath ?? _task.vocalsPath,
      backgroundPath: fresh.backgroundPath ?? _task.backgroundPath,
      asrSentences: fresh.asrSentences ?? _task.asrSentences,
    );
    unawaited(_loadMedia());
  }

  @override
  Widget build(BuildContext context) {
    // 打标是在人**已经被放进这一页之后**才跑的：切分一好就放人进来干活，
    // 打标占总时长七成，在后台补（见 [AnalysisPipeline]）。它跑完只写了盘，
    // 开着的这一页自己不会知道——真机上就是这样：属性栏一直写着「未打标」，
    // 而盘上标签一个不少；连带「替换素材」也搜不出东西，因为检索键正是取自
    // 单元与镜头的标签（见 [PickingScope]）。
    ref.listen(taskListProvider, (_, next) => _adoptTags(next.valueOrNull));

    final editor = _editor;
    final playback = _playback;
    if (editor == null || playback == null) {
      return Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.surface,
          title: Text(widget.task.name),
        ),
        body: const Center(
          child: Text('该任务尚未完成分析切分，暂时无法进入审片台',
              style: TextStyle(color: AppColors.textSecondary)),
        ),
      );
    }

    // 声音不对时那条提示。**分离能力按谁来分离判定**：空白任务的声音全部来自
    // 替换素材，是逐条分离的；有原片的任务分的是原片自己那条音轨，用的是分析
    // 管线里那个分离器。拿素材那条去判断原片这条，判出来的话是不作数的
    final vocalsNotice = missingVocalsNotice(
      _task.bgm,
      _task.voices,
      _task.vocalsPath,
      isBlank: _task.isBlank,
      canSeparate: _task.isBlank
          ? ref.read(materialSeparatorProvider) != null
          : ref.read(analysisPipelineProvider)?.separator != null,
    );

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        // 已经 pop 了也要把防抖窗口里的改动补写掉
        unawaited(_flushAutosave());
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: WorkbenchTopBar(
          task: _task,
          onBack: _handleBackRequest,
          onEditTagGroups: _isEditable ? _editTagGroups : null,
          onEditMaterialAudio:
              _isEditable && _lock == null ? _editMaterialAudio : null,
          materialAudioOn: _task.materialAudio.mode.audible,
          onEditSubtitle: _isEditable ? _editSubtitleStyle : null,
        ),
        body: Column(
          children: [
            if (_playbackDegraded) const PlaybackDegradedBanner(),
            if (_retaggingCount > 0) RetaggingBanner(unitCount: _retaggingCount),
            // 多轨播放不需要「正在合成」——只有变速切片和取不到的配乐
            // 才有话要说
            if (_tracks?.notice case final notice?)
              PreviewAudioBanner(
                text: notice,
                building: (_tracks?.speedFitter?.pending ?? 0) > 0,
                // 「还没选素材」重试一百次也不会变——那种提示不给重试按钮
                onRetry: _tracks?.noticeRetryable ?? false
                    ? _retryPreviewAudio
                    : null,
              ),
            // 素材分离同样十几秒，照原片那条的规矩：正在跑就说在跑，
            // 失败给原因和重试，不许转圈不说话、也不许只写日志
            if (_separatingMaterial != null)
              const PreviewAudioBanner(
                  key: Key('material-separating-banner'),
                  text: '正在把这条素材分成人声与背景，约十几秒…',
                  building: true)
            else if (_materialSeparationError case final err?)
              PreviewAudioBanner(
                key: const Key('material-separating-banner'),
                text: err,
                building: false,
                retryLabel: '重新分离',
                onRetry: _isEditable && _lock == null
                    ? () {
                        final sel = _editor?.selection;
                        final u = sel?.unitIndex;
                        final sh = sel?.shotIndex;
                        if (u != null && sh != null) {
                          unawaited(_ensureMaterialSeparated(u, sh));
                        }
                      }
                    : null,
              ),
            // 分离要十几秒，正在跑就先说在跑——转圈不说话是不合格的
            if (_separatingVocals)
              const PreviewAudioBanner(
                  key: Key('vocals-notice-banner'),
                  text: '正在分离这条片子的纯人声轨，约十几秒…',
                  building: true)
            else if (vocalsNotice case final notice?)
              PreviewAudioBanner(
                key: const Key('vocals-notice-banner'),
                text: notice.text,
                building: false,
                retryLabel: '重新分离',
                // 只读时不给出口：这条任务正被别人占着，补出来也写不进去
                onRetry: notice.retryable && _isEditable && _lock == null
                    ? _separateVocals
                    : null,
              ),
            if (_voiceProgress case final p?)
              VoiceGeneratingBanner(done: p.$1, total: p.$2),
            // 被别人占着时整页只读。只禁不说的话，用户只会以为软件坏了
            if (_lock case final lock?)
              TaskLockBanner(
                holder: lock.holder,
                action: _agent?.action,
                onTakeover: _takeoverLock,
              ),
            Expanded(
              child: WorkbenchBody(
                // Agent 在看哪儿，界面就跟到哪儿——像人自己点过去那样
                agentFocus: _agentFocusRequest,
                // 整体替换后这一段在成片里多长——时间线上标出来
                composedDurations: _composedDurations,
                onBgmResize: _isEditable ? _resizeBgm : null,
                onBgmDelete: _isEditable ? _deleteBgm : null,
                editor: editor,
                // 两种任务都能加单元。有原片的任务加出来的那个**原片上没有它**
                // （hasSource=false）：画面只能来自挑到的素材，成片因此比原片长
                onAddUnit: _isEditable && _lock == null ? _addUnit : null,
                onReorderUnit:
                    _isEditable && _lock == null ? _reorderUnit : null,
                materialAudioDefault: _task.materialAudio,
                shotReplaced: _shotReplaced,
                shotMaterialVoiceover: _shotMaterialVoiceover,
                onEditUnitTags:
                    _isEditable && _lock == null ? _editUnitTags : null,
                onEditShotTags:
                    _isEditable && _lock == null ? _editShotTags : null,
                subtitleLinesOf: _subtitleLinesOf,
                subtitleEdited: _subtitleEdited,
                subtitleTextOf: _subtitleTextOf,
                subtitleLineCount: _subtitleLineCount,
                onEditSubtitleBlock: _editSubtitleAtBlock,
                onSubtitleChanged:
                    _isEditable && _lock == null ? _setSubtitleLines : null,
                onSubtitleReset:
                    _isEditable && _lock == null ? _resetSubtitle : null,
                onShotMaterialAudioChanged:
                    _isEditable && _lock == null ? _setShotMaterialAudio : null,
                sourceAudioDefault: _task.sourceAudio,
                // 时间线靠它判断「字幕改过没有、要不要重画」
                subtitleTrack: _task.subtitleTrack,
                onShotSourceAudioChanged:
                    _isEditable && _lock == null ? _setShotSourceAudio : null,
                unitVoiceSwapped: (i) {
                  final units = editor.units;
                  return i < units.length &&
                      _task.voices.assignedUnits.contains(units[i].uid);
                },
                hasVocals: _hasStem(_task.vocalsPath),
                hasBackground: _hasStem(_task.backgroundPath),
                // 标签手填：空白任务的分子全都手加，有原片的任务里只有手加的
                // 那些。手加的单元没有台词，模型没东西可以据以打标，而标签是
                // 搜素材的检索键——不给它手填就等于让它永远搜不出东西
                unitTagEditor: (i, u) => _task.isBlank || !u.hasSource
                    ? _blankTagEditor(i, u.tags)
                    : null,
                baseCard: _baseCard,
                blankTask: _task.isBlank,
                onDeleteUnit: _isEditable && _lock == null
                    ? _deleteBlankUnit
                    : null,
                // 有原片的任务只有**手动加的**单元能删。分析切出来的单元
                // 删掉等于把原片少放一段，那是另一件事，不在这个入口做
                canDeleteUnit: _task.isBlank ? null : (u) => !u.hasSource,
                playback: playback,
                videoWidget: _videoWidget,
                // 预览的字幕是**现画的一层**，不是烧进切片的像素：
                // 调位置/字号/颜色即刻生效，不跑 ffmpeg、不换源、不跳帧
                subtitleAt: _previewSubtitleAt,
                subtitleStyle: _task.subtitle,
                onSubtitleTap: _isEditable ? _editSubtitleStyle : null,
                onSubtitleDragEnd: _isEditable ? _dragSubtitleTo : null,
                media: _media,
                mediaStatus: _mediaStatus,
                thumbStatus: _thumbStatus,
                waveStatus: _waveStatus,
                baseMedia: _baseMedia,
                playhead: _playhead,
                readOnly: !_isEditable || _lock != null,
                clock: widget.clock,
                voices: _task.voices,
                replacements: _replacements ?? const [],
                onChangeVoice: _isEditable ? _changeVoice : null,
                previewVoice: (i) {
                  final units = _editor?.units ?? const [];
                  if (i < 0 || i >= units.length) return null;
                  return _voiceAudio.containsKey(units[i].uid)
                      ? () => _previewVoice(i)
                      : null;
                },
                candidateBadge: candidateBadgeText(_replacements ?? const []),
                bgm: _task.bgm,
                onBgmRangeSelected: _isEditable ? _pickBgmForRange : null,
                onBgmSegmentTap: _isEditable ? _editBgmSegment : null,
                candidatePanel: CandidateTab(
                  // Agent 要给某一镜挑素材时，右栏得先切到镜头替换——
                  // 否则播报和右栏说的是两回事
                  agentFocus: _agentFocusRequest,
                  editor: editor,
                  shotTagGroups: _task.shotTagGroups,
                  unitTagGroups: _task.unitTagGroups,
                  initialReplacements: _replacements,
                  onReplacementsChanged: _onReplacementsChanged,
                  readOnly: !_isEditable || _lock != null,
                  project: _task.project,
                  pickedMaterials: _task.pickedMaterials,
                  onPickedMaterialsChanged: _onPickedMaterialsChanged,
                  pickedStore: widget.pickedStore ?? _defaultPickedStore,
                  mediaCache: _mediaCache,
                  contentService: widget.contentService,
                  candidateProbe: widget.candidateProbe,
                  tagService: widget.tagService,
                ),
              ),
            ),
          ],
        ),
        // 摘要含单元数/镜头数/dirty 标记，只随编辑器变化重建，不随播放位置重建
        bottomNavigationBar: AnimatedBuilder(
          animation: editor,
          builder: (context, _) {
            final (pending, failed) = _mediaReadiness;
            final blocked = exportBlockedReason(_plan,
                pendingMedia: pending, failedMedia: failed);
            return WorkbenchBottomBar(
              summaryText: _summaryText(editor),
              voiceCount: _task.voices.assignedUnits.length,
              onGenerateVoices:
                  _isEditable && _voiceProgress == null ? _generateVoices : null,
              combinationText: _plan.isEmpty ? null : combinationSummaryText(_plan),
              blockedReason: blocked,
              onExport: blocked == null ? _openExport : null,
              onJianying: _jianyingBusy || !_isEditable ? null : _openJianying,
              onReview: _isEditable &&
                      _lock == null &&
                      collectReviewItems(_replacements ?? const []).isNotEmpty
                  ? _openReview
                  : null,
            );
          },
        ),
      ),
    );
  }
}
