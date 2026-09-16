import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:flutter/material.dart';

import '../shared/thumb_image.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/export/speed_fit.dart';
import '../../core/ffmpeg/process_runner.dart';
import '../../core/ffmpeg/thumbnail_service.dart';
import '../../core/models/renew_task.dart';
import '../../core/models/semantic_unit.dart';
import '../../core/presentation/user_facing_error.dart';
import '../../core/replacement/picked_material.dart';
import '../../core/review/review_receipt.dart';
import '../../core/storage/agent_presence.dart';
import '../../core/storage/agent_request.dart';
import '../../core/replacement/unit_base.dart';
import '../../core/storage/task_media.dart';
import '../../core/storage/task_lock.dart';
import '../director/tag_picker.dart';
import '../picking/picking_providers.dart';
import '../settings/settings_providers.dart';
import '../tasks/new_task_wizard/wizard_providers.dart';
import '../tasks/task_id_badge.dart';
import '../tasks/task_list_controller.dart';
import 'review_hover_player.dart';

/// 审核页：人过一遍 Agent 挑的候选，点掉不要的，一次确认。
///
/// 「Agent 干活 → 人把关 → 导出」闭环里人把关那一环。交互按「快速扫片」
/// 设计：**悬停即播**（有声、循环）、**点卡片即剔除/恢复**——审核是把
/// 不要的挑出来，不是重新挑一遍，所以不摆一排勾选框。
///
/// 版式：左侧位置栏（结构 + 进度，点击跳到对应段），右侧按位置分组的卡片
/// 网格。确认那一刻剔除落进任务、写回执（见 [ReviewReceipt]），Agent 用
/// `review-result` 取结果。
class ReviewPage extends ConsumerStatefulWidget {
  final RenewTask task;

  /// 工作台内嵌模式：确认时把决定交回工作台，由它在自己的会话里应用
  /// ——同一个人的同一次编辑会话，没有第二把锁。为 null 时是**独立模式**
  /// （CLI 唤醒 / 任务列表进入）：进门持锁、确认自己写盘
  final void Function(List<ReviewDecision> decisions)? onApply;

  /// 标签在这一页被改过时回调（**内嵌模式必须接**）。
  ///
  /// 为什么不让审核页自己写盘：内嵌时工作台开着同一条任务，两边都是整份
  /// 任务对象落库，谁后写谁赢——不交回去的话，人在这里改的标签会被工作台
  /// 的下一次保存抹掉。为 null 时是独立模式，自己持锁自己写。
  final void Function(List<SemanticUnit> units)? onTagsChanged;

  /// 测试注入：假播放器（真实现碰 libmpv）、假素材解析、假抽帧
  final ReviewHoverPlayer? hoverPlayer;
  final Future<String> Function(int materialId)? resolveMedia;
  /// 抽「本来的样子」那一张。第三个参数是**取自哪条素材**（底片固定过的
  /// 单元），null 表示取自任务原片——签名里带着它，是因为 `??` 两边类型
  /// 对不上时 Dart 会推断成裸 `Function`，参数个数错要到运行时才炸
  final Future<String?> Function(int startMs, int endMs, int? candidateId)?
      extractOriginalThumb;

  const ReviewPage({
    super.key,
    required this.task,
    this.onApply,
    this.onTagsChanged,
    this.hoverPlayer,
    this.resolveMedia,
    this.extractOriginalThumb,
  });

  @override
  ConsumerState<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends ConsumerState<ReviewPage> {
  /// 单元列表的**可变副本**：审核页能就地改标签，改完这里先变，
  /// 再按模式落库（内嵌模式交回工作台，独立模式自己写盘）
  late List<SemanticUnit> _units = [...(widget.task.units ?? const [])];

  late final List<ReviewItem> _items =
      collectReviewItems(widget.task.replacementsFor(_units));

  /// 被剔除的候选。默认空 = 全保留：审核是把不要的挑出来
  final Set<String> _dropped = {};

  late final ReviewHoverPlayer _hover =
      widget.hoverPlayer ?? MediaKitHoverPlayer();

  /// 当前悬停在哪张卡上（null = 没有）。整页共用一个播放器，
  /// 只有这张卡把缩略图换成视频
  String? _hoveringKey;
  Timer? _hoverDebounce;

  final ScrollController _scroll = ScrollController();
  final Map<String, GlobalKey> _sectionKeys = {};

  String? _error;

  /// 原片段落的首帧图（分组 id → 本地 jpg）。抽出来一张补一张
  final Map<String, String> _originThumbs = {};

  /// 独立模式的会话锁。**进门就持**：审核期间任务就是「人在处理」，
  /// Agent 这时的写入要被拒（互斥是双向的——反过来 Agent 在处理时，
  /// 这里进不来，见 [_blockedBy]）。工作台内嵌模式不碰锁：那是同一次会话
  TaskLockFile? _lock;
  Timer? _lockHeartbeat;
  static String get _holder => '人（审核中）';

  /// 进门时锁在**另一个界面**手里：显示是谁、给强制接管。
  /// Agent 持锁不走这条路——见 [_agent]
  String? _blockedBy;

  /// Agent 此刻在这个任务上做什么。非 null = 它在干活：
  /// 页面转成**只读跟随**（照常显示候选、滚到它动的那张卡），
  /// 而不是拦成一张空白页——可视模式下人正是为了看它干活才打开这一页的
  AgentPresence? _agent;
  Timer? _agentPoll;

  /// 每张卡的位置锚点，用来把 Agent 动到的那张滚进视野
  final Map<String, GlobalKey> _cardKeys = {};

  /// Agent 刚代办完什么（顶部轻提示）。人正开着这一页指挥它时走这条路
  String? _delegateNote;

  static String keyOf(ReviewItem item) =>
      '${item.unit}/${item.shot}/${item.material}';

  @override
  void initState() {
    super.initState();
    if (widget.onApply == null) _acquireSessionLock();
    _loadOriginThumbs();
    _watchAgent();
  }

  /// 盯着 Agent：**两个方向都要接**。
  ///
  /// - 它在干活（在场状态）→ 页面转只读，把它动的那张卡滚到眼前，展示完回执
  /// - 它请我代办（代办请求）→ 我来点这几张卡。剔除是界面里的临时状态，
  ///   人按「确认」才落盘，所以只能由这一页执行，不能让它绕过去写盘
  void _watchAgent() {
    _agentPoll?.cancel();
    _agentPoll = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      final dataDir = ref.read(dataDirProvider);
      if (dataDir == null) return;
      _handleDelegated(dataDir);
      _followAgent(dataDir);
    });
  }

  void _handleDelegated(Directory dataDir) {
    final request =
        consumeAgentRequest(dataDir: dataDir, taskId: widget.task.id);
    if (request == null) return;
    final keep = request.kind == 'review.keep';
    if (request.kind != 'review.drop' && !keep) {
      writeAgentRequestResult(
          dataDir: dataDir,
          taskId: widget.task.id,
          id: request.id,
          ok: false,
          message: '审核页不认识「${request.kind}」这件事');
      return;
    }
    final decisions = [
      for (final raw in (request.payload['decisions'] as List? ?? const []))
        ?ReviewDecision.tryFromJson(raw),
    ];
    // 整批拒绝：一条编号对不上就全不做。不然人以为剔了两条、实际剔了一条
    final missing = [
      for (final d in decisions)
        if (!_items.any((i) =>
            i.unit == d.unit && i.shot == d.shot && i.material == d.material))
          '第 ${d.unit + 1} 段'
              '${d.shot == null ? '' : '第 ${d.shot! + 1} 镜'}的素材 ${d.material}',
    ];
    if (decisions.isEmpty || missing.isNotEmpty) {
      writeAgentRequestResult(
        dataDir: dataDir,
        taskId: widget.task.id,
        id: request.id,
        ok: false,
        message: decisions.isEmpty
            ? '一条决定都没有'
            : '这一页上没有这些候选：${missing.join('、')}',
      );
      return;
    }
    setState(() {
      for (final d in decisions) {
        final key = '${d.unit}/${d.shot}/${d.material}';
        d.keep ? _dropped.remove(key) : _dropped.add(key);
      }
      final what = keep ? '恢复' : '剔除';
      _delegateNote = 'Agent $what了 ${decisions.length} 条，'
          '按下面的「确认」才会落进方案';
    });
    // 滚到它动的最后一张，人的视线跟着走
    final last = decisions.last;
    _scrollToCard('${last.unit}/${last.shot}/${last.material}');
    writeAgentRequestResult(
      dataDir: dataDir,
      taskId: widget.task.id,
      id: request.id,
      ok: true,
      message: '已在界面上标记 ${decisions.length} 条，等人按确认',
    );
  }

  void _followAgent(Directory dataDir) {
    final now = readAgentPresence(dataDir: dataDir, taskId: widget.task.id);
    final was = _agent;
    final changed = (was == null) != (now == null) ||
        was?.action != now?.action ||
        was?.focus?.materialId != now?.focus?.materialId;
    if (!changed) return;
    setState(() => _agent = now);
    final focus = now?.focus;
    if (focus?.materialId != null) {
      _scrollToCard(
          '${focus!.unitIndex ?? focus.lineIndex}/${focus.shotIndex}/'
          '${focus.materialId}');
    }
    if (now != null && now.step > 0) {
      // 真的展示完（滚动落定）才回执——Agent 靠它决定什么时候走下一步
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Future<void>.delayed(const Duration(milliseconds: 320), () {
          if (!mounted) return;
          writeAgentAck(
              dataDir: dataDir, taskId: widget.task.id, step: now.step);
        });
      });
    }
  }

  void _scrollToCard(String key) {
    final ctx = _cardKeys[key]?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(ctx,
        duration: const Duration(milliseconds: 250),
        alignment: 0.4,
        curve: Curves.easeOut);
  }

  void _acquireSessionLock() {
    final dataDir = ref.read(dataDirProvider);
    if (dataDir == null) return;
    final lock = TaskLockFile(dataDir: dataDir, taskId: widget.task.id);
    if (!lock.acquire(_holder)) {
      final holder = lock.read()?.holder;
      // Agent 占着**不拦成空白页**：可视模式下人正是为了看它干活才打开
      // 这一页的，拦掉等于把要看的东西挡在门外。转成只读跟随即可
      // （见 [_followAgent]），它一收工这一页自动可操作
      if (isGuiHolder(holder)) _blockedBy = holder ?? '别人';
      return;
    }
    _lock = lock;
    // 心跳让锁活着：审核可能一看十分钟，超时失效等于没锁
    _lockHeartbeat = Timer.periodic(
        const Duration(seconds: 20), (_) => lock.heartbeat(_holder));
  }

  Future<void> _forceTakeover() async {
    final dataDir = ref.read(dataDirProvider);
    if (dataDir == null) {
      // 测试环境才会走到：按钮点了必须有反应，不能静默吞掉
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('当前环境没有数据目录，无法接管')));
      return;
    }
    // 抢锁是破坏性的：对方之后的写入会被拒绝。工作台的同名按钮有确认框，
    // 这里必须同一套规矩
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
    final lock = TaskLockFile(dataDir: dataDir, taskId: widget.task.id);
    lock.forceTakeover(_holder);
    setState(() => _blockedBy = null);
    _lock = lock;
    _lockHeartbeat = Timer.periodic(
        const Duration(seconds: 20), (_) => lock.heartbeat(_holder));
  }

  /// 给每个位置组的原片段落抽一张首帧图（取中点：两端常踩在转场上，
  /// 抽出来是糊的）。按任务缓存，抽过的直接用
  Future<void> _loadOriginThumbs() async {
    for (final section in _sections) {
      final start = section.originStartMs;
      final end = section.originEndMs;
      if (start == null || end == null) continue;
      // 取自原片的那些要有原片；取自素材的（底片固定过）不需要
      if (section.originCandidateId == null &&
          widget.task.sourcePath == null) {
        continue;
      }
      try {
        final path = await (widget.extractOriginalThumb ?? _extractThumb)(
            start, end, section.originCandidateId);
        if (!mounted) return;
        if (path != null && File(path).existsSync()) {
          setState(() => _originThumbs[section.id] = path);
        }
      } catch (_) {
        // 抽不出来就保持占位图，悬停仍能播真画面——不值得为一张缩略图报错
      }
    }
  }

  Future<String?> _extractThumb(
      int startMs, int endMs, int? candidateId) async {
    final dataDir = ref.read(dataDirProvider);
    final source = _originPathOf(candidateId);
    if (dataDir == null || source == null) return null;
    final dir = Directory(
        p.join(dataDir.path, 'review_thumbs', widget.task.id))
      ..createSync(recursive: true);
    // 素材那张要单独存：不带 id 的话，原片同一个时间点的缓存会被当成
    // 它的，抽出来是别的画面
    final tag = candidateId == null ? 'orig' : 'base$candidateId';
    final out = p.join(dir.path, '${tag}_${startMs}_$endMs.jpg');
    if (File(out).existsSync()) return out;
    await ThumbnailService(run: const ResolvingProcessRunner().call)
        .extractCover(
      videoPath: source,
      outPath: out,
      atSeconds: ((startMs + endMs) / 2) / 1000.0,
      height: 480,
    );
    return out;
  }

  @override
  void dispose() {
    _agentPoll?.cancel();
    _lockHeartbeat?.cancel();
    _lock?.release(_holder);
    _hoverDebounce?.cancel();
    _hover.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ---- 数据视图 ----

  PickedMaterial? _materialOf(int id) {
    for (final m in widget.task.pickedMaterials) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// 标了 ★ 的那些（预览版）：审核的人该知道哪条是 Agent 的首选
  late final Set<String> _previewKeys = () {
    final keys = <String>{};
    final replacements = widget.task.replacementsFor(_units);
    for (var u = 0; u < replacements.length; u++) {
      final r = replacements[u];
      if (r.wholeCandidateIds.isNotEmpty) {
        keys.add('$u/null/${r.wholePreviewId ?? r.wholeCandidateIds.first}');
      }
      for (final e in r.shotCandidateIds.entries) {
        if (e.value.isEmpty) continue;
        keys.add('$u/${e.key}/${r.shotPreviewIds[e.key] ?? e.value.first}');
      }
    }
    return keys;
  }();

  /// 「本来的样子」该读哪个文件：底片固定过的单元读那条素材，其余读原片
  String? _originPathOf(int? candidateId) {
    if (candidateId == null) return widget.task.sourcePath;
    final dataDir = ref.read(dataDirProvider);
    if (dataDir == null) return null;
    return TaskMedia(dataDir: dataDir, taskId: widget.task.id)
        .localMaterial(candidateId);
  }

  /// 位置分组（保持出现顺序）
  late final List<_Section> _sections = () {
    final map = <String, _Section>{};
    final units = widget.task.units ?? const [];
    for (final item in _items) {
      final id = '${item.unit}/${item.shot}';
      map.putIfAbsent(id, () {
        final unit = item.unit < units.length ? units[item.unit] : null;
        final shot = unit != null &&
                item.shot != null &&
                item.shot! < unit.shots.length
            ? unit.shots[item.shot!]
            : null;
        // 「这一段本来的样子」取自哪个文件的哪一段：整段替换是整个单元，
        // 镜头替换是那个镜头。
        //
        // **底片固定过的单元取的是那条素材**，不是原片——它的镜头坐标是
        // 「单元起点 + 素材内偏移」，照原片那个时间点抽出来的是一段毫不
        // 相干的画面，而这张卡的用处正是「拿它当参照物比对候选」
        final onBase = unit != null && hasOwnBaseShots(unit);
        final shift = onBase ? -unit.startMs : 0;
        final originStart =
            (item.shot == null ? unit?.startMs : shot?.startMs).plusOrNull(shift);
        final originEnd =
            (item.shot == null ? unit?.endMs : shot?.endMs).plusOrNull(shift);
        return _Section(
          id: id,
          unitIndex: item.unit,
          shotIndex: item.shot,
          title: item.shot == null
              ? 'U${item.unit + 1} · 整段替换'
              : 'U${item.unit + 1} · S${item.shot! + 1}',
          transcript: unit?.transcript ?? '',
          slotMs: item.shot == null ? null : shot?.durationMs,
          originStartMs: originStart,
          originEndMs: originEnd,
          originCandidateId: onBase ? unit.baseCandidateId : null,
          items: [],
        );
      });
      map[id]!.items.add(item);
    }
    return map.values.toList();
  }();

  int get _droppedCount => _dropped.length;

  // ---- 交互 ----

  void _toggle(ReviewItem item) {
    // Agent 正在动它——这时人点一下，两边会打架，而且它下一步就把界面
    // 覆盖回去了。想插手就等它收工（或在 Agent 那头喊停）
    if (_agent != null) return;
    final key = keyOf(item);
    setState(() {
      _dropped.contains(key) ? _dropped.remove(key) : _dropped.add(key);
    });
  }

  void _onHover(
    String key,
    bool entered, {
    required Future<String> Function() resolve,
    int? startMs,
    int? endMs,
  }) {
    _hoverDebounce?.cancel();
    if (!entered) {
      if (_hoveringKey == key) {
        setState(() => _hoveringKey = null);
        _hover.stop();
      }
      return;
    }
    // 250ms 防抖：鼠标扫过一排卡时别把每张都拉起来播一下
    _hoverDebounce = Timer(const Duration(milliseconds: 250), () async {
      if (!mounted) return;
      setState(() => _hoveringKey = key);
      try {
        final path = await resolve();
        if (!mounted || _hoveringKey != key) return;
        await _hover.play(path, startMs: startMs, endMs: endMs);
      } catch (_) {
        if (mounted && _hoveringKey == key) {
          setState(() => _hoveringKey = null);
        }
      }
    });
  }

  Future<String> _resolveMaterial(int id) {
    final resolve = widget.resolveMedia ??
        (int id) async {
          final fetch = ref.read(materialFetcherProvider);
          if (fetch == null) throw StateError('素材下载器未就绪');
          return fetch(widget.task.id, id);
        };
    return resolve(id);
  }

  void _jumpTo(String sectionId) {
    final key = _sectionKeys[sectionId];
    final ctx = key?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx,
          duration: const Duration(milliseconds: 250),
          alignment: 0,
          curve: Curves.easeOut);
    }
  }

  Future<void> _confirm() async {
    final decisions = [
      for (final item in _items)
        ReviewDecision(
          unit: item.unit,
          shot: item.shot,
          material: item.material,
          keep: !_dropped.contains(keyOf(item)),
        ),
    ];

    // 工作台内嵌：决定交回工作台，它在自己的会话里应用并走既有的自动保存
    if (widget.onApply case final apply?) {
      apply(decisions);
      if (mounted) Navigator.of(context).pop(_outcome());
      return;
    }

    // 独立模式：锁在进门时已持有，这里直接写盘
    try {
      final repo = ref.read(taskRepositoryProvider);
      final current = await repo.findById(widget.task.id) ?? widget.task;
      final units = current.units ?? const <SemanticUnit>[];
      final pruned =
          applyReviewDecisions(current.replacementsFor(units), decisions);
      await repo.save(current.copyWith(
          replacementsByUid: RenewTask.byUid(units, pruned),
          updatedAt: DateTime.now()));
      await ref.read(taskListProvider.notifier).reload();
      if (!mounted) return;
      // 审核完回到来处——它不是终点站，主流程才是
      Navigator.of(context).pop(_outcome());
    } catch (e) {
      if (mounted) {
        setState(() => _error = userFacingError(e,
            fallback: '确认失败，改动未保存，请稍后重试'));
      }
    }
  }

  ReviewOutcome _outcome() => ReviewOutcome(
      kept: _items.length - _droppedCount, dropped: _droppedCount);

  // ---- 视图 ----

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.surface,
          titleSpacing: 0,
          title: Row(children: [
            TaskIdBadge(task: widget.task),
            const SizedBox(width: AppSpacing.sm),
            Expanded(child: _titleText()),
          ]),
        ),
        body: _blockedBy != null
            ? _blockedState()
            : (_items.isEmpty
                ? const _EmptyState()
                : Column(children: [
                    // Agent 在干活 / 刚替人干完活：两种都要在最显眼处说出来。
                    // 界面不说话，人只会以为软件自己乱跳
                    if (_agent != null) _agentBanner(_agent!),
                    if (_agent == null && _delegateNote != null)
                      _delegateBanner(_delegateNote!),
                    Expanded(child: _reviewBody()),
                  ])),
        bottomNavigationBar:
            _items.isEmpty || _blockedBy != null ? null : _confirmBar(),
      );

  Widget _titleText() => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('审核候选',
                  style: TextStyle(
                      fontSize: AppFontSize.emphasis,
                      fontWeight: FontWeight.w600)),
              Text(widget.task.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: AppFontSize.micro,
                      color: AppColors.textTertiary)),
            ],
          );

  Widget _reviewBody() => Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _railView(),
          const VerticalDivider(width: 1, color: AppColors.border),
          Expanded(child: _sectionsView()),
        ],
      );

  /// 左栏：位置导航 + 进度。审核是逐位置过一遍的活，要能看到全貌
  Widget _railView() => SizedBox(
        width: 220,
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(
                  AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.xs),
              child: Text('位置',
                  style: TextStyle(
                      fontSize: AppFontSize.caption,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textSecondary)),
            ),
            for (final section in _sections)
              _RailRow(
                title: section.title,
                kept: section.items
                    .where((i) => !_dropped.contains(keyOf(i)))
                    .length,
                total: section.items.length,
                onTap: () => _jumpTo(section.id),
              ),
          ],
        ),
      );

  Widget _sectionsView() => ListView(
        controller: _scroll,
        padding: const EdgeInsets.all(AppSpacing.xl),
        children: [
          const Text('悬停播放，点击剔除/恢复。确认后被剔除的从方案里拿掉，其余照旧。',
              style: TextStyle(
                  fontSize: AppFontSize.caption,
                  color: AppColors.textTertiary)),
          const SizedBox(height: AppSpacing.lg),
          for (final section in _sections) ...[
            KeyedSubtree(
              key: _sectionKeys.putIfAbsent(section.id, GlobalKey.new),
              child: _sectionHeader(section),
            ),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.md,
              runSpacing: AppSpacing.md,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                // 原片这一段打头：审核就是「原来是什么 → 换成什么」的对比
                if (widget.task.sourcePath != null &&
                    section.originStartMs != null &&
                    section.originEndMs != null) ...[
                  _originalCard(section),
                  const Icon(Icons.arrow_forward,
                      size: 18, color: AppColors.textTertiary),
                ],
                for (final item in section.items)
                  _card(item, slotMs: section.slotMs),
              ],
            ),
            const SizedBox(height: AppSpacing.xl),
          ],
        ],
      );

  Widget _sectionHeader(_Section section) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            Text(section.title,
                style: const TextStyle(
                    fontSize: AppFontSize.emphasis,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary)),
            if (section.slotMs case final ms?) ...[
              const SizedBox(width: AppSpacing.sm),
              Text('坑位 ${(ms / 1000).toStringAsFixed(1)}s',
                  style: const TextStyle(
                      fontSize: AppFontSize.caption,
                      color: AppColors.textTertiary)),
            ],
          ]),
          // 标签**独占一行、全部铺开**：挤在标题旁边的话，镜头层十来个标签
          // 会被压成很窄的一条。它们是这一段的检索键，看的就是「全都有哪些」
          _tagRow(section),
          if (section.transcript.isNotEmpty)
            Container(
              // 一行别超过这个宽度。**不是为了留白，是为了读得动**：
              // 1100px 一行是 100 多个汉字，眼睛扫到行尾再回到下一行行首
              // 很容易串行——而这段话正是人判断候选贴不贴题的依据
              // （2026-09-09 设计走查）
              constraints: const BoxConstraints(maxWidth: _transcriptMaxWidth),
              padding: const EdgeInsets.only(top: 2),
              // **台词不截断**：截成两行加省略号，等于把人要判断的东西藏起来
              // ——他正是靠这段话决定候选贴不贴题的
              child: Text(section.transcript,
                  style: const TextStyle(
                      fontSize: AppFontSize.caption,
                      height: 1.5,
                      color: AppColors.textSecondary)),
            ),
        ],
      );

  /// 台词一行最宽多少。约 45 个汉字——排版上舒服的行长是 45~75 个字符，
  /// 中文取下限那一档
  static const double _transcriptMaxWidth = 720;

  /// 这一段的标签。**摆出来，而且能就地改。**
  ///
  /// 为什么要摆在这里：标签就是这一段候选的检索键。人在这一屏判断候选
  /// 「像不像」的时候，得能看见它当初是按什么搜出来的——看不见就只能猜，
  /// 猜错了也只会反复剔除，问题根子（标签打偏了）一直没人动。
  ///
  /// 取哪一层跟着替换粒度走：整段替换检索用的是单元标签，逐镜头替换用的是
  /// 那个镜头的标签——摆另一层等于给人看一份跟这次检索无关的东西。
  Widget _tagRow(_Section section) {
    final tags = _tagsOf(section);
    final editable = _agent == null && _blockedBy == null;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xs),
      child: Wrap(
        spacing: AppSpacing.xs,
        runSpacing: AppSpacing.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (tags.isEmpty)
            const Text('未打标',
                style: TextStyle(
                    fontSize: AppFontSize.caption,
                    color: AppColors.textTertiary))
          else
            for (final tag in tags) _chip(tag),
          if (editable)
            TextButton(
              key: ValueKey('review-edit-tags-${section.id}'),
              onPressed: () => unawaited(_editTags(section)),
              style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm, vertical: 0),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              child: const Text('改标签',
                  style: TextStyle(fontSize: AppFontSize.caption)),
            ),
        ],
      ),
    );
  }

  /// 改这一段的标签：打开选择器（当前的预先带勾），勾选/取消都在里面完成
  /// ——删一个和加一个是同一个动作，跟编导台那边一致。
  ///
  /// **只给这条任务自己的标签组**（onlyPreferred）：标签是下一步的检索键，
  /// 给出任务标签组以外的词等于让人挑一个这个项目根本没素材的标签，
  /// 搜完才发现是空的，那时也不知道是标签选错了。
  Future<void> _editTags(_Section section) async {
    final groups = section.shotIndex == null
        ? widget.task.unitTagGroups
        : widget.task.shotTagGroups;
    final picked = await showTagPicker(
      context,
      tags: ref.read(miaoaTagServiceProvider),
      selected: _tagsOf(section),
      preferredGroupIds: {for (final g in groups) g.id},
      onlyPreferred: true,
    );
    if (picked == null || !mounted) return;
    _applyTags(section, [for (final t in picked) t.name]);
  }

  /// 标签改动落地。
  ///
  /// **内嵌模式不自己写盘**：那时工作台开着同一条任务，它保存的是整份任务
  /// 对象，这边再写一次，谁后写谁赢——人在审核页改的标签会被工作台的下一次
  /// 保存抹掉。所以交回它，由它跟切分改动走同一条保存通路。
  void _applyTags(_Section section, List<String> tags) {
    setState(() => _units = _withTags(_units, section, tags));
    final onTagsChanged = widget.onTagsChanged;
    if (onTagsChanged != null) {
      onTagsChanged(_units);
      return;
    }
    // 独立模式：进门就持着锁，这份任务此刻归自己写
    unawaited(ref
        .read(taskRepositoryProvider)
        .save(widget.task.copyWith(units: _units, updatedAt: DateTime.now())));
  }

  /// 这一段检索用的那一层标签
  List<String> _tagsOf(_Section section) {
    if (section.unitIndex >= _units.length) return const [];
    final unit = _units[section.unitIndex];
    final shotIndex = section.shotIndex;
    if (shotIndex == null) return unit.tags;
    return shotIndex < unit.shots.length ? unit.shots[shotIndex].tags : const [];
  }

  /// 原片卡：这一段本来的样子。不可剔除（它不是候选，是参照物），
  /// 悬停播的是原片的这个区间
  Widget _originalCard(_Section section) {
    final key = 'orig/${section.id}';
    final hovering = _hoveringKey == key;
    final source = _originPathOf(section.originCandidateId);
    if (source == null) return const SizedBox.shrink();
    final start = section.originStartMs!;
    final end = section.originEndMs!;
    return MouseRegion(
      onEnter: (_) => _onHover(key, true,
          resolve: () async => source, startMs: start, endMs: end),
      onExit: (_) => _onHover(key, false,
          resolve: () async => source, startMs: start, endMs: end),
      child: Container(
        key: Key('review-original-${section.id}'),
        width: 150,
        decoration: BoxDecoration(
          color: AppColors.surfaceCard,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: hovering ? AppColors.accentBlue : AppColors.accentBlueLight,
            width: hovering ? 1.5 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 9 / 16,
              child: ClipRRect(
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(8)),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (_originThumbs[section.id] case final thumb?)
                      ThumbImage(
                          key: Key('review-original-thumb-${section.id}'),
                          path: thumb)
                    else
                      Container(
                          color: AppColors.surfaceCard,
                          child: const Icon(Icons.theaters_outlined,
                              size: 32, color: AppColors.textTertiary)),
                    if (hovering) _hover.buildVideo(),
                    Positioned(
                      left: 6,
                      top: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.accentBlue,
                          borderRadius: BorderRadius.circular(AppRadius.xs),
                        ),
                        child: const Text('原片',
                            style: TextStyle(
                                fontSize: AppFontSize.micro,
                                color: Colors.white)),
                      ),
                    ),
                    Positioned(
                      left: 6,
                      bottom: 6,
                      child:
                          _chip('${((end - start) / 1000).toStringAsFixed(1)}s'),
                    ),
                  ],
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.all(AppSpacing.xs),
              child: Text('这一段本来的样子',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: AppFontSize.micro,
                      color: AppColors.textTertiary)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _card(ReviewItem item, {int? slotMs}) {
    final key = keyOf(item);
    final material = _materialOf(item.material);
    final dropped = _dropped.contains(key);
    final hovering = _hoveringKey == key;
    final thumb = material?.thumbPath;

    // 镜头替换要变速对齐坑位：倍率如实标出来，人看一眼就知道会不会像快进
    String? rate;
    if (slotMs != null && slotMs > 0 && material?.durationMs != null) {
      rate = SpeedFit.describe(
          SpeedFit.factorFor(candidateMs: material!.durationMs!, slotMs: slotMs));
    }

    return KeyedSubtree(
      // 位置锚点：Agent 动到哪张，就把哪张滚进视野
      key: _cardKeys.putIfAbsent(key, GlobalKey.new),
      child: MouseRegion(
      onEnter: (_) => _onHover(key, true,
          resolve: () => _resolveMaterial(item.material)),
      onExit: (_) => _onHover(key, false,
          resolve: () => _resolveMaterial(item.material)),
      child: GestureDetector(
        key: Key('review-card-$key'),
        onTap: () => _toggle(item),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 120),
          opacity: dropped ? 0.38 : 1,
          child: Container(
            width: 150,
            decoration: BoxDecoration(
              color: AppColors.surfaceRaised,
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(
                color: dropped
                    ? AppColors.red
                    : (hovering ? AppColors.accentBlue : AppColors.border),
                width: dropped || hovering ? 1.5 : 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AspectRatio(
                  aspectRatio: 9 / 16,
                  child: ClipRRect(
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(8)),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (thumb != null && File(thumb).existsSync())
                          ThumbImage(path: thumb)
                        else
                          // **说清为什么是空的**。只摆一个胶片图标的话，人
                          // 分不出「还没抽到帧」和「这条素材坏了」——而他
                          // 正要靠画面决定留不留（2026-09-09 设计走查：
                          // U1·S7 的预览版就是一块空灰底，什么都没说）
                          Container(
                            color: AppColors.surfaceCard,
                            padding: const EdgeInsets.all(AppSpacing.sm),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.movie_outlined,
                                    color: AppColors.textTertiary),
                                const SizedBox(height: AppSpacing.xs),
                                Text(
                                  thumb == null ? '画面还没抽出来' : '画面文件不见了',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                      fontSize: AppFontSize.micro,
                                      color: AppColors.textTertiary),
                                ),
                              ],
                            ),
                          ),
                        // 悬停时缩略图上盖真视频（有声、循环）
                        if (hovering && !dropped) _hover.buildVideo(),
                        // 角标们
                        Positioned(
                          left: 6,
                          bottom: 6,
                          child: Row(children: [
                            if (material?.durationMs case final ms?)
                              _chip('${(ms / 1000).toStringAsFixed(1)}s'),
                            if (rate != null) ...[
                              const SizedBox(width: 4),
                              _chip(rate, color: AppColors.orange),
                            ],
                          ]),
                        ),
                        if (_previewKeys.contains(key))
                          Positioned(
                              right: 6, top: 6, child: _chip('★ 预览版')),
                        if (dropped)
                          Center(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: AppSpacing.sm,
                                  vertical: AppSpacing.xs),
                              decoration: BoxDecoration(
                                color: AppColors.red.withValues(alpha: 0.85),
                                borderRadius:
                                    BorderRadius.circular(AppRadius.sm),
                              ),
                              child: const Text('已剔除',
                                  style: TextStyle(
                                      fontSize: AppFontSize.caption,
                                      color: Colors.white)),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(AppSpacing.xs),
                  child: Text(
                    material == null
                        ? '素材 ${item.material}'
                        : _tail(material.name),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: AppFontSize.micro,
                        color: AppColors.textTertiary),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      ),
    );
  }

  Widget _chip(String text, {Color? color}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.65),
          borderRadius: BorderRadius.circular(AppRadius.xs),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: AppFontSize.micro, color: color ?? Colors.white)),
      );

  static String _tail(String name) =>
      name.length <= 18 ? name : '…${name.substring(name.length - 17)}';

  Widget _confirmBar() => Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg, vertical: AppSpacing.md),
        decoration: const BoxDecoration(
          color: AppColors.surface,
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        child: SafeArea(
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _error ??
                      '共 ${_items.length} 条 · 保留 '
                          '${_items.length - _droppedCount} · '
                          '剔除 $_droppedCount',
                  style: TextStyle(
                      fontSize: AppFontSize.body,
                      color: _error == null
                          ? AppColors.textSecondary
                          : AppColors.orange),
                ),
              ),
              FilledButton(
                key: const Key('review-confirm'),
                // Agent 正在动这一页时按不得：它下一步就把状态覆盖了
                onPressed: _agent == null ? _confirm : null,
                child: Text(_droppedCount == 0
                    ? '确认 · 全部保留'
                    : '确认 · 剔除 $_droppedCount 条'),
              ),
            ],
          ),
        ),
      );

  /// Agent 正在动这一页：说清它在做什么，并告诉人现在是只读。
  ///
  /// 「它在做什么」这一句是可视模式的全部意义——只说「有人占着」等于没说
  Widget _agentBanner(AgentPresence agent) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
        color: AppColors.accentBlue.withValues(alpha: 0.14),
        child: Row(children: [
          const Icon(Icons.smart_toy_outlined,
              size: 16, color: AppColors.accentBlue),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${agent.holder} 正在这一页上操作，当前为只读',
                    style: const TextStyle(
                        fontSize: AppFontSize.caption,
                        color: AppColors.textSecondary)),
                if (agent.action.isNotEmpty)
                  Text(agent.action,
                      key: const Key('review-agent-action'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: AppFontSize.body,
                          color: AppColors.textPrimary)),
              ],
            ),
          ),
        ]),
      );

  /// Agent 替人点完了几张卡。**必须说清还没落盘**——不说的话人以为完事了，
  /// 关掉窗口就白干
  Widget _delegateBanner(String note) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
        color: AppColors.accentBlue.withValues(alpha: 0.10),
        child: Row(children: [
          const Icon(Icons.smart_toy_outlined,
              size: 16, color: AppColors.accentBlue),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(note,
                key: const Key('review-delegate-note'),
                style: const TextStyle(
                    fontSize: AppFontSize.caption,
                    color: AppColors.textPrimary)),
          ),
          TextButton(
            onPressed: () => setState(() => _delegateNote = null),
            child: const Text('知道了'),
          ),
        ]),
      );

  /// 进门时锁在别人手里。互斥与工作台同一套长相：说清是谁、给强制接管
  Widget _blockedState() => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.lock_outline,
                size: 40, color: AppColors.orange),
            const SizedBox(height: AppSpacing.md),
            Text('$_blockedBy 正在操作这个任务',
                style: const TextStyle(
                    fontSize: AppFontSize.body, color: AppColors.textPrimary)),
            const SizedBox(height: AppSpacing.xs),
            const Text('等它结束再进，或者强制接管（它那边的写入会被拒绝）',
                style: TextStyle(
                    fontSize: AppFontSize.caption,
                    color: AppColors.textTertiary)),
            const SizedBox(height: AppSpacing.md),
            Row(mainAxisSize: MainAxisSize.min, children: [
              OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('返回')),
              const SizedBox(width: AppSpacing.sm),
              FilledButton(
                  key: const Key('review-takeover'),
                  onPressed: _forceTakeover,
                  child: const Text('强制接管')),
            ]),
          ],
        ),
      );
}

/// 审核结果（pop 回来处时带上，来处弹条提示用）
class ReviewOutcome {
  final int kept;
  final int dropped;
  const ReviewOutcome({required this.kept, required this.dropped});
}

/// 换掉某个单元（或它某个镜头）的标签，其余原样返回新列表。
/// 抽成纯函数：改标签是不可变更新，就地改会让 setState 前后指向同一个对象
List<SemanticUnit> _withTags(
    List<SemanticUnit> units, _Section section, List<String> tags) {
  if (section.unitIndex >= units.length) return units;
  return [
    for (var i = 0; i < units.length; i++)
      if (i != section.unitIndex)
        units[i]
      else if (section.shotIndex == null)
        units[i].copyWith(tags: tags)
      else
        units[i].copyWith(shots: [
          for (var j = 0; j < units[i].shots.length; j++)
            if (j == section.shotIndex)
              units[i].shots[j].copyWith(tags: tags)
            else
              units[i].shots[j],
        ]),
  ];
}

class _Section {
  final String id;
  final String title;
  final String transcript;

  /// 这一段落在哪个单元；[shotIndex] 为 null 表示整段替换。
  /// 标签要按这两个下标去任务里取——**取哪一层由替换粒度决定**：
  /// 整段替换检索用的是单元标签，逐镜头替换用的是那个镜头的标签
  final int unitIndex;
  final int? shotIndex;

  /// 镜头替换的固定坑位时长；整段替换为 null（时长跟素材走）
  final int? slotMs;

  /// 「本来的样子」那一段的区间（悬停原片卡播的就是它）。
  /// 空白任务没有原片时为 null
  final int? originStartMs;
  final int? originEndMs;

  /// 这一段取自哪条**素材**（底片固定过的单元）。null = 取自任务原片。
  /// 不记的话原片卡会去原片的同一个时间点抽一段毫不相干的画面，
  /// 而这张卡的用处正是「拿它当参照物比对候选」
  final int? originCandidateId;
  final List<ReviewItem> items;

  _Section({
    required this.id,
    required this.title,
    required this.transcript,
    required this.unitIndex,
    this.shotIndex,
    required this.slotMs,
    this.originStartMs,
    this.originEndMs,
    this.originCandidateId,
    required this.items,
  });
}

class _RailRow extends StatelessWidget {
  final String title;
  final int kept;
  final int total;
  final VoidCallback onTap;

  const _RailRow(
      {required this.title,
      required this.kept,
      required this.total,
      required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md, vertical: AppSpacing.sm),
          child: Row(
            children: [
              Expanded(
                child: Text(title,
                    style: const TextStyle(
                        fontSize: AppFontSize.caption,
                        color: AppColors.textPrimary)),
              ),
              Text(
                kept == total ? '$total 条' : '$kept/$total',
                style: TextStyle(
                    fontSize: AppFontSize.micro,
                    // 有剔除的位置标橙——一眼看出哪儿动过刀
                    color: kept == total
                        ? AppColors.textTertiary
                        : AppColors.orange),
              ),
            ],
          ),
        ),
      );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) => const Center(
        child: Text('这条任务还没有挑过任何候选，没有可审核的。',
            style: TextStyle(color: AppColors.textTertiary)),
      );
}

/// `null + n` 还是 null——底片偏移只对算得出来的那些生效
extension _NullableShift on int? {
  int? plusOrNull(int delta) => this == null ? null : this! + delta;
}
