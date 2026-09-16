import 'dart:async';
import 'package:characters/characters.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/analysis/analysis_pipeline.dart';
import '../../core/analysis/tagging_service.dart';
import '../../core/audio/bgm_plan.dart';
import '../../core/audio/vocal_separator.dart';
import '../../core/audio/voice_plan.dart';
import '../../core/log/app_log.dart';
import '../../core/models/project_ref.dart';
import '../../core/storage/task_copy.dart';
import '../settings/settings_providers.dart';
import '../../core/models/renew_task.dart';
import '../../core/models/semantic_unit.dart';
import '../../core/models/tag_group_ref.dart';
import '../../core/models/export_record.dart';
import '../../core/replacement/picked_material.dart';
import '../../core/replacement/replacement_plan.dart';
import '../../core/storage/file_task_repository.dart';
import '../../core/storage/task_repository.dart';
import '../../core/storage/task_seq.dart';
import '../import_flow/import_service.dart';
import 'analysis_error_message.dart';
import 'analysis_progress_store.dart';
import '../../core/analysis/base_transcriber.dart';
import '../../core/analysis/unit_segmenter.dart';
import 'task_artifact_cleaner.dart';
import 'task_list_merge.dart';

/// 由 main.dart（或测试）override 提供实例
final taskRepositoryProvider = Provider<TaskRepository>(
    (ref) => throw UnimplementedError('在 ProviderScope 中 override'));
final importServiceProvider = Provider<ImportService>(
    (ref) => throw UnimplementedError('在 ProviderScope 中 override'));

/// 分析管线：null 表示凭据未配置，导入后跳过自动分析（main.dart 按凭据完整性 override）
final analysisPipelineProvider = Provider<AnalysisPipeline?>((ref) => null);

/// 打标服务：工作台里「改完之后重新打标」直接用它，不必把整条分析管线
/// （抽音频、ASR、语义切分）再拖进来。缺省取自分析管线，凭据未配置时为 null。
final taggingServiceProvider = Provider<TaggingService?>(
    (ref) => ref.watch(analysisPipelineProvider)?.tagging);

/// 单段底片切分器：跟全片切分同一条链路（采信号 → 双判据 → 灰区画面复核），
/// 只是喂进去的视频换成了这一段自己的底片。null 表示凭据未配置
final unitSegmenterProvider = Provider<UnitSegmenter?>((ref) {
  final pipeline = ref.watch(analysisPipelineProvider);
  if (pipeline == null) return null;
  return UnitSegmenter(
      scenes: pipeline.scenes, boundaries: pipeline.shotBoundaries);
});

/// 底片转写器：给切开的那一段拿到它自己的词级时间戳——字幕这条线从头到尾
/// 建立在词级时间戳上，拿别的凑不出来。null 表示凭据未配置
final baseTranscriberProvider = Provider<BaseTranscriber?>((ref) {
  final pipeline = ref.watch(analysisPipelineProvider);
  if (pipeline == null) return null;
  return BaseTranscriber(
      audio: pipeline.audio, asr: pipeline.asr, workDir: pipeline.workDir);
});

/// 任务中间产物清理器：null 表示未接线（测试场景），删除任务时只删记录
final taskArtifactCleanerProvider = Provider<TaskArtifactCleaner?>((ref) => null);

/// 分析失败原因落库前的最大长度，避免超长堆栈/报错文本污染任务 JSON
const _maxAnalysisErrorLength = 300;

/// 上次运行中途退出留下的「分析中」任务，装载时写入此原因，
/// 使其能走已有的失败重试路径（不新增状态枚举值——新增会让旧版本读不出）
const stalledAnalysisMessage = '上次分析被中断（应用退出或异常关闭），请重新分析';

/// 分析管线不可用（AI 凭据缺失）时写入任务的原因，面向用户不含技术黑话
const pipelineUnavailableMessage = 'AI 服务未配置，无法自动分析。请补齐凭据后重启应用再重试。';

/// 触发分析的结果，供 UI 给出对应反馈（不能静默 return，否则用户点了没反应）
enum RetryOutcome {
  /// 已开始分析
  started,

  /// 该任务已有分析在进行中，忽略本次触发
  alreadyRunning,

  /// 分析管线不可用（AI 未配置）
  pipelineUnavailable,

  /// 该任务的记录已不在磁盘上（触发入口还停留在屏幕上时任务被删除了）
  taskMissing,
}

/// 重命名结果，供 UI 给出对应反馈
enum RenameOutcome {
  /// 已重命名
  renamed,

  /// 名称为空白，视为无效输入
  invalidName,

  /// 该任务的记录已不在磁盘上（对话框还开着时任务被删除了）
  taskMissing,
}

/// 记录已被删除时给用户的说明（对话框/SnackBar 可能比任务活得更久）
const taskMissingMessage = '该任务已被删除，本次操作未生效。';

/// 任务列表整体装载失败时给用户的说明。
///
/// 不能把 `PathNotFoundException: Cannot open file, path = '...'
/// (OS Error: ..., errno = 2)` 这类原文摊给用户——它既不解释发生了什么，
/// 也不告诉用户能做什么。原始异常只进日志。
const taskLoadFailedMessage = '任务列表读取失败，可能是数据目录暂时无法访问。请点「重试」重新加载。';

class TaskListController extends AsyncNotifier<List<RenewTask>> {
  /// 正在分析中的任务 id 集合：并发守卫。同一任务 id 若已在集合中，
  /// 新的分析触发（自动分析 or 手动重试）一律忽略，避免用户快速连点
  /// 或「自动分析未完成时手动重试」两条路径对同一 workDir/源文件并发
  /// 重复跑 ffmpeg/ASR。
  final Set<String> _analyzingTaskIds = {};

  /// 最近一次装载中被跳过的损坏任务文件数（供列表页常驻提示；只写日志的话
  /// 用户看到的只是「我的任务不见了」）
  int _skippedTaskFileCount = 0;
  int get skippedTaskFileCount => _skippedTaskFileCount;

  @override
  Future<List<RenewTask>> build() async {
    final tasks = await _findAll();
    // 老任务补短编号（#N，见 task_seq.dart）：幂等，只在启动装载做一次
    final numbered =
        await ensureTaskSeqs(ref.read(taskRepositoryProvider), tasks);
    return _recoverStalledTasks(numbered);
  }

  Future<List<RenewTask>> _findAll() async {
    final repo = ref.read(taskRepositoryProvider);
    final tasks = await repo.findAll();
    // TaskLoadDiagnostics 与 TaskRepository 无继承关系，用模式匹配取诊断信息
    _skippedTaskFileCount = switch (repo) {
      TaskLoadDiagnostics(:final skippedTaskFileCount) => skippedTaskFileCount,
      _ => 0,
    };
    return tasks;
  }

  /// 启动装载：把「状态仍是分析中、又没有任何进行中分析」的任务标记为已中断。
  ///
  /// 分析是纯内存态的后台任务（unawaited），进程一关就没了，而任务状态停在
  /// analyzing 且 analysisError 为 null——列表只显示「分析中」、点开只提示
  /// 「请稍候」、重试入口又只在有 analysisError 时出现，用户走进死路。
  /// 只在 build（启动装载）做，reload 不做，避免把本次运行中真正在分析的
  /// 任务误标为中断。
  Future<List<RenewTask>> _recoverStalledTasks(List<RenewTask> tasks) async {
    final repo = ref.read(taskRepositoryProvider);
    final recovered = <RenewTask>[];
    for (final task in tasks) {
      // 陈旧的中断标记：状态已经回到 ready，说明后来分析成功了，
      // 那句「上次分析被中断」是上一轮留下的。不清掉的话，人看到的是一条
      // 完整可用的任务显示红色失败，点「重试」还要再花一次分析的钱
      if (task.status == RenewTaskStatus.ready &&
          task.analysisError == stalledAnalysisMessage) {
        final healed = task.copyWith(clearAnalysisError: true);
        try {
          await repo.save(healed);
        } catch (e) {
          AppLog.warn('任务 ${task.id} 清理陈旧中断标记失败：$e');
        }
        recovered.add(healed);
        continue;
      }
      if (!_isStalled(task)) {
        recovered.add(task);
        continue;
      }
      final marked = task.copyWith(analysisError: stalledAnalysisMessage);
      try {
        await repo.save(marked);
        AppLog.warn('任务 ${task.id} 上次分析被中断，已标记为可重试');
      } catch (e) {
        // 落库失败不影响本次展示，下次启动会再尝试
        AppLog.warn('任务 ${task.id} 中断标记落库失败：$e');
      }
      recovered.add(marked);
    }
    return List.unmodifiable(recovered);
  }

  bool _isStalled(RenewTask task) =>
      task.status == RenewTaskStatus.analyzing &&
      task.analysisError == null &&
      !_analyzingTaskIds.contains(task.id);

  /// 本次运行中已被删除的任务 id（墓碑）。
  ///
  /// id 由导入时刻的微秒时间戳生成，单调递增、不会被复用，因此墓碑不会误伤
  /// 后续新建的任务；每条只占一个短字符串，一次会话内的删除量级可忽略。
  final Set<String> _deletedTaskIds = {};

  /// 删除任务：先清理中间产物（失败不阻断），再删记录并从列表中移除那一条
  Future<void> deleteTask(RenewTask task) async {
    // 墓碑要在任何 await 之前立起来：清理与删记录都是异步的，期间到达的
    // 「重试/重命名/分析失败落库」必须立刻被拒绝，否则会把它重新写回磁盘
    _deletedTaskIds.add(task.id);
    try {
      await ref.read(taskArtifactCleanerProvider)?.cleanup(task.id);
    } catch (e) {
      AppLog.warn('任务 ${task.id} 中间产物清理失败（不影响删除）：$e');
    }
    try {
      await ref.read(taskRepositoryProvider).delete(task.id);
    } catch (e) {
      // 没删成功，任务还在磁盘上，墓碑必须撤掉，否则这条任务本次会话
      // 再也无法重命名/重试（等于把 Critical 2 那类死锁换个地方复现）
      _deletedTaskIds.remove(task.id);
      rethrow;
    }
    if (!_removeLocally(task.id)) await reload();
  }

  /// 重命名：空白名称视为无效输入，直接忽略（调用方在 UI 层已给出提示）。
  ///
  /// 以磁盘上的当前记录为基线，而不是调用方传进来的 [task]：重命名对话框
  /// 可以长时间停留，期间后台分析可能已经写入了 units/新状态，拿旧快照
  /// copyWith 会把这些成果一并抹掉。记录已不存在时不落库（见 [_currentRecord]）。
  /// 复制一条任务。返回新任务；源任务已被删掉时返回 null。
  ///
  /// **两条任务此后完全隔离**——该带走的产物一并复制、任务里存的路径全部
  /// 改写到新任务名下（见 [TaskCopier]）。
  Future<RenewTask?> copyTask(RenewTask task) async {
    final current = await _currentRecord(task, action: '复制');
    if (current == null) return null;
    final dataDir = ref.read(dataDirProvider);
    if (dataDir == null) return null;
    final repository = ref.read(taskRepositoryProvider);
    final all = await repository.findAll();
    final copy = await TaskCopier(dataDir).duplicate(
      current,
      // 和导入那条路同一个身份生成方式（见 ImportService._defaultId）
      newId: DateTime.now().microsecondsSinceEpoch.toRadixString(36),
      seq: await nextTaskSeq(repository),
      now: DateTime.now(),
      name: copiedTaskName(current.name, [for (final t in all) t.name]),
    );
    await repository.save(copy);
    await _refreshAfterSave(copy);
    return copy;
  }

  Future<RenameOutcome> renameTask(RenewTask task, String newName) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty) {
      AppLog.warn('任务 ${task.id} 重命名已忽略：名称为空');
      return RenameOutcome.invalidName;
    }
    final current = await _currentRecord(task, action: '重命名');
    if (current == null) return RenameOutcome.taskMissing;
    final renamed = current.copyWith(name: trimmed, updatedAt: DateTime.now());
    await ref.read(taskRepositoryProvider).save(renamed);
    await _refreshAfterSave(renamed);
    return RenameOutcome.renamed;
  }

  /// 读取磁盘上仍然存在的那条记录；已被删除时返回 null 并落日志。
  ///
  /// `save` 是「有则覆盖、无则创建」，对已删除的 id 等于重新创建一条——而
  /// 它的封面、PCM、抽帧在删除时已被清理器删掉，复活出来的任务不会自愈。
  /// 触发入口（带「重试」的 SnackBar、重命名对话框）都可能比任务本身活得
  /// 更久，因此每次「更新已有任务」前都要先确认记录还在。
  ///
  /// 两道判定缺一不可：
  /// - 查磁盘：覆盖「上次运行删掉、本次运行还拿着旧对象」这类跨进程情形，
  ///   同时顺带取回最新记录，避免用陈旧快照覆盖磁盘上的新数据；
  /// - 查 [_deletedTaskIds]：查存在性本身是 check-then-act，删除若发生在
  ///   「查完」与「写入」之间仍会复活（后台分析失败落库尤其容易撞上）。
  ///
  /// 导入新任务不经过这里（它本来就该创建记录），因此不会被误伤。
  Future<RenewTask?> _currentRecord(RenewTask task,
      {required String action}) async {
    final current = _deletedTaskIds.contains(task.id)
        ? null
        : await ref.read(taskRepositoryProvider).findById(task.id);
    if (current == null || _deletedTaskIds.contains(task.id)) {
      AppLog.warn('任务 ${task.id} $action已跳过：记录已被删除，不再写回磁盘');
      return null;
    }
    return current;
  }

  /// 全量重新装载。
  ///
  /// 用 `copyWithPrevious` 保留上一份数据：直接置 `AsyncLoading()` 会把 value
  /// 抹成 null，列表页据此渲染整页 spinner——于是「确认切分」「保存草稿」这类
  /// 只动一条任务的操作，也会让整个任务网格白屏闪一下。保留旧数据后，加载中
  /// 只是 `isRefreshing`，页面继续显示旧列表直到新数据就绪。
  Future<void> reload() async {
    state = const AsyncLoading<List<RenewTask>>().copyWithPrevious(state);
    // 记下起步代次：这之后发生的局部更新不在这份快照里，回写前要叠加回去
    final since = _localChangeGeneration;
    _reloadsInFlight++;
    try {
      final snapshot = await _findAll();
      state = AsyncData(List.unmodifiable(mergeLocalChanges(
        snapshot: snapshot,
        changes: _localChanges,
        since: since,
      )));
    } catch (e, stackTrace) {
      // 原始异常（PathNotFoundException + errno 之类）只进日志：
      // AsyncValue.guard 会把它静默塞进 state，页面再原样摊给用户
      AppLog.warn('任务列表装载失败：$e');
      state = AsyncError(e, stackTrace);
    } finally {
      _reloadsInFlight--;
      // 没有 reload 在飞时这些记录就没人再用了，及时清空防止无界增长
      if (_reloadsInFlight == 0) _localChanges.clear();
    }
  }

  /// 保存单条任务后刷新列表：优先局部更新，只有在列表尚未装载出来（还在
  /// loading 或上次装载出错）时才退回全量重读。
  ///
  /// 全量重读会遍历任务目录并把每条任务 JSON 完整解码重建对象——实测约
  /// 1 ms/任务（96 秒素材，40 KB JSON），5 分钟素材外推约 3.5 ms/任务；
  /// 而「保存草稿」在审片台里是高频操作，每次都付这份钱不划算。
  Future<void> _refreshAfterSave(RenewTask updated) async {
    if (!_upsertLocally(updated)) await reload();
  }

  /// 就地替换（或插入）一条任务，返回是否成功应用局部更新。
  ///
  /// 全程不可变：构造新列表而不改动原列表。
  bool _upsertLocally(RenewTask updated) {
    final current = state.valueOrNull;
    if (current == null) return false;
    final rest = current.where((t) => t.id != updated.id).toList(growable: false);
    state = AsyncData(List.unmodifiable(insertByUpdatedAtDesc(rest, updated)));
    _recordLocalChange(updated.id, updated);
    return true;
  }

  /// 从列表中移除一条任务，返回是否成功应用局部更新
  bool _removeLocally(String id) {
    final current = state.valueOrNull;
    if (current == null) return false;
    state = AsyncData(
        List.unmodifiable(current.where((t) => t.id != id).toList()));
    _recordLocalChange(id, null);
    return true;
  }

  /// 代次号：每次局部更新自增，[reload] 用它判断哪些更新发生在自己起步之后
  int _localChangeGeneration = 0;

  /// 正在进行中的 reload 数量（可能有多个并发：后台分析结束 + 用户操作）
  int _reloadsInFlight = 0;

  /// 有 reload 在飞时才需要留档，否则记录立刻就没人用了
  final List<LocalTaskChange> _localChanges = [];

  void _recordLocalChange(String id, RenewTask? task) {
    _localChangeGeneration++;
    if (_reloadsInFlight == 0) return;
    _localChanges.add(LocalTaskChange(
        generation: _localChangeGeneration, id: id, task: task));
  }

  /// 导入并自动分析。[unitTagGroups] / [shotTagGroups] 是新建向导选定的两层
  /// miaoa 标签组，随任务落库，分析时据此解析各自的受控词表。
  /// 建一条空白任务。**不排分析**——没有原片可分析，建出来直接可编辑
  Future<RenewTask> createBlankTask({
    required String name,
    List<TagGroupRef> unitTagGroups = const [],
    List<TagGroupRef> shotTagGroups = const [],
    String unitTagPrompt = '',
    String shotTagPrompt = '',
    ProjectRef? project,
  }) async {
    final task = await ref.read(importServiceProvider).createBlank(
          name: name,
          project: project,
          unitTagGroups: unitTagGroups,
          shotTagGroups: shotTagGroups,
          unitTagPrompt: unitTagPrompt,
          shotTagPrompt: shotTagPrompt,
        );
    await reload();
    // 把建出来的那条报回去：调用方（尤其是 Agent 那条路）得知道是哪一条，
    // 而不是建完去任务库里翻「最新的那条」猜
    return task;
  }

  /// 建一条脚本成片任务。**不排分析**——脚本从空白写起，建出来直接进编导台
  Future<RenewTask> createScriptTask({
    required String name,
    List<TagGroupRef> unitTagGroups = const [],
    List<TagGroupRef> shotTagGroups = const [],
    String unitTagPrompt = '',
    String shotTagPrompt = '',
    ProjectRef? project,
  }) async {
    final task = await ref.read(importServiceProvider).createScript(
          name: name,
          project: project,
          unitTagGroups: unitTagGroups,
          shotTagGroups: shotTagGroups,
          unitTagPrompt: unitTagPrompt,
          shotTagPrompt: shotTagPrompt,
        );
    await reload();
    return task;
  }

  Future<RenewTask?> importFile(
    String path, {
    List<TagGroupRef> unitTagGroups = const [],
    List<TagGroupRef> shotTagGroups = const [],
    String unitTagPrompt = '',
    String shotTagPrompt = '',
    ProjectRef? project,
  }) async {
    final task = await ref.read(importServiceProvider).importLocalFile(
          path,
          project: project,
          unitTagGroups: unitTagGroups,
          shotTagGroups: shotTagGroups,
          unitTagPrompt: unitTagPrompt,
          shotTagPrompt: shotTagPrompt,
        );
    await reload();

    final pipeline = ref.read(analysisPipelineProvider);
    if (pipeline == null) {
      // 不能静默返回：任务会永远停在「分析中」，且因 analysisError 为空
      // 连重试入口都够不到
      AppLog.warn('任务 ${task.id} 未自动分析：分析管线未配置');
      await _markAnalysisFailed(task, pipelineUnavailableMessage);
      // 任务本身建出来了，只是没能自动分析——照样把它报回去
      return task;
    }
    if (!_analyzingTaskIds.add(task.id)) {
      AppLog.info('任务 ${task.id} 分析已在进行中，忽略重复触发（并发守卫）');
      return task;
    }
    unawaited(_runAnalyze(pipeline, task));
    return task;
  }

  /// 分析失败反馈：落库 analysisError（保持原状态，通常仍是 analyzing），
  /// 供任务列表展示红色失败徽标并支持用户手动重试
  Future<void> _markAnalysisFailed(RenewTask task, Object error) async {
    final repo = ref.read(taskRepositoryProvider);
    // 分析期间任务可能已被删除：失败落库不能把它复活
    final current = await _currentRecord(task, action: '分析失败落库');
    if (current == null) return;
    final failed = current.copyWith(
      analysisError: _truncateAnalysisError(error),
      updatedAt: DateTime.now(),
    );
    await repo.save(failed);
    await reload();
  }

  /// 翻译成中文人话后再做码点安全截断。
  ///
  /// 码点安全：Dart String 按 UTF-16 code unit 索引，朴素 substring 可能切在
  /// 代理对（surrogate pair）中间，留下落单的 high surrogate，写盘 UTF-8
  /// 编码时会被静默替换为 U+FFFD。改用 Characters 按用户可感知字符
  /// （grapheme cluster）截断，天然不会切碎代理对或组合字符。
  String _truncateAnalysisError(Object error) {
    final message = describeAnalysisError(error);
    final characters = message.characters;
    return characters.length > _maxAnalysisErrorLength
        ? characters.take(_maxAnalysisErrorLength).toString()
        : message;
  }

  /// 实际执行一次分析（调用方需已完成 `_analyzingTaskIds` 守卫占位）；
  /// 无论成功或失败，结束时都在 finally 中释放守卫，避免占位泄漏导致
  /// 任务永久无法再次触发分析。
  Future<void> _runAnalyze(AnalysisPipeline pipeline, RenewTask task) async {
    final progress = ref.read(analysisProgressProvider.notifier);
    try {
      await pipeline.analyze(
        task,
        onProgress: (p) => progress.report(task.id, p),
        // 切分一好就刷新列表：那一刻任务已经能打开干活了，剩下的打标
        // 在后台补。让人对着「分析中」多等三倍时间没道理。
        onUnitsReady: (_) => unawaited(reload()),
      );
      await reload();
    } catch (e) {
      AppLog.warn('任务 ${task.id} 分析失败：$e');
      await _markAnalysisFailed(task, e);
    } finally {
      // 成功与失败都要清：留着最后一步的文案，卡片看起来像还在跑
      progress.clear(task.id);
      _analyzingTaskIds.remove(task.id);
    }
  }

  /// 分析失败后手动重试：清空 analysisError、状态置回 analyzing 并落库刷新，
  /// 随后重新触发分析管线；管线未配置（凭据缺失）时记录告警并直接返回；
  /// 若该任务已在分析中（并发守卫命中，例如用户快速连点或自动分析尚未
  /// 完成）则忽略本次触发，不重复跑 ffmpeg/ASR。
  Future<RetryOutcome> retryAnalysis(RenewTask task) async {
    final pipeline = ref.read(analysisPipelineProvider);
    if (pipeline == null) {
      AppLog.warn('任务 ${task.id} 重试分析已跳过：分析管线未配置');
      await _markAnalysisFailed(task, pipelineUnavailableMessage);
      return RetryOutcome.pipelineUnavailable;
    }
    if (!_analyzingTaskIds.add(task.id)) {
      AppLog.info('任务 ${task.id} 分析已在进行中，忽略重复触发（并发守卫）');
      return RetryOutcome.alreadyRunning;
    }

    // 守卫占位后到 _runAnalyze 真正接管之间的任何异常（磁盘写满、数据目录
    // 只读）都必须先释放占位再冒泡：否则 _runAnalyze 的 finally 根本没机会
    // 执行，该 id 会永远留在集合里，用户后续每次重试都被告知「正在分析中」，
    // 而实际上没有任何分析在跑，整个进程生命周期内该任务的分析入口失效。
    final RenewTask resetTask;
    try {
      // 记录已被删除时不重建：SnackBar 上的「重试」可能比任务活得更久
      final current = await _currentRecord(task, action: '重试分析');
      if (current == null) {
        _analyzingTaskIds.remove(task.id);
        return RetryOutcome.taskMissing;
      }
      resetTask = current.copyWith(
        clearAnalysisError: true,
        status: RenewTaskStatus.analyzing,
        updatedAt: DateTime.now(),
      );
      await ref.read(taskRepositoryProvider).save(resetTask);
      await reload();
    } catch (e) {
      _analyzingTaskIds.remove(task.id);
      rethrow;
    }

    unawaited(_runAnalyze(pipeline, resetTask));
    return RetryOutcome.started;
  }

  /// 「替换选材」：保存各台词语义单元的替换方案。
  ///
  /// 不改变任务状态——状态要等阶段③真正导出后才该流转到 exported，
  /// 提前改会让任务在列表里显示成已导出却拿不到成片。
  /// [replacements] 按位置排（界面就是这么摆的），落库时翻译成
  /// 「哪个单元的身份 → 哪份方案」
  Future<void> savePickingPlan(
      RenewTask task, List<UnitReplacement> replacements) async {
    final units = task.units ?? const <SemanticUnit>[];
    final updated = task.copyWith(
      replacementsByUid: RenewTask.byUid(units, replacements),
      updatedAt: DateTime.now(),
    );
    await ref.read(taskRepositoryProvider).save(updated);
    await _refreshAfterSave(updated);
  }

  /// 记下一次导出。**追加**而不是覆盖：项目会被反复导出，每一次都是一条
  /// 独立的记录（哪天、导了几条、成了几条、在哪个目录）
  Future<void> addExportRecord(RenewTask task, ExportRecord record) async {
    final updated = task.copyWith(
      exports: [...task.exports, record],
      updatedAt: DateTime.now(),
    );
    await ref.read(taskRepositoryProvider).save(updated);
    await _refreshAfterSave(updated);
  }

  /// 已挑中素材的落地记录。和替换方案分开存：方案是「选了哪些 id」，
  /// 这里是「那些 id 到底是什么」——后者是为了让用户随时看得见自己选了什么，
  /// 和检索结果、翻到第几页、换没换项目组都无关。
  Future<void> savePickedMaterials(
      RenewTask task, List<PickedMaterial> materials) async {
    final updated = task.copyWith(
      pickedMaterials: materials,
      updatedAt: DateTime.now(),
    );
    await ref.read(taskRepositoryProvider).save(updated);
    await _refreshAfterSave(updated);
  }

  /// 改这条任务用哪些标签组。
  ///
  /// 标签组本来只在新建向导里选一次；选漏了或选错了就再也改不了，那条任务
  /// 从此打不出标签、候选检索的标签主路径也就永远用不上。
  /// 存「保留素材原声」的全片打底设置。传进来的 task 已经带上新值了
  Future<void> saveMaterialAudio(RenewTask task) async {
    final updated = task.copyWith(updatedAt: DateTime.now());
    await ref.read(taskRepositoryProvider).save(updated);
    await _refreshAfterSave(updated);
  }

  /// 存手改过的字幕轨。传进来的 task 已经带上新值了
  Future<void> saveSubtitleTrack(RenewTask task) async {
    final updated = task.copyWith(updatedAt: DateTime.now());
    await ref.read(taskRepositoryProvider).save(updated);
    await _refreshAfterSave(updated);
  }

  Future<void> saveTagGroups(
    RenewTask task, {
    required List<TagGroupRef> unit,
    required List<TagGroupRef> shot,
    String? unitPrompt,
    String? shotPrompt,
    ProjectRef? project,
  }) async {
    final updated = task.copyWith(
      project: project,
      // 显式选了「不限项目」时要真的清掉，不能被 ?? 当成「没传」
      clearProject: project == null,
      unitTagGroups: unit,
      shotTagGroups: shot,
      unitTagPrompt: unitPrompt,
      shotTagPrompt: shotPrompt,
      updatedAt: DateTime.now(),
    );
    await ref.read(taskRepositoryProvider).save(updated);
    await _refreshAfterSave(updated);
  }

  /// 保存配乐方案。与切分、替换方案同一条「随手落库」通路。
  Future<void> saveBgm(RenewTask task, BgmPlan bgm) async {
    final updated = task.copyWith(bgm: bgm, updatedAt: DateTime.now());
    await ref.read(taskRepositoryProvider).save(updated);
    await _refreshAfterSave(updated);
  }

  /// 记下这条任务自己的人声轨。
  ///
  /// 人声轨**归任务所有**，两条任务之间不共用（见 [PreparedCache]）：它被
  /// 别人删任务时一起清掉、或当初那次分离失败过，用户都能在工作台点
  /// 「重新分离」补一份，补完就落在这里
  Future<void> saveVocals(RenewTask task, SeparatedAudio stems) async {
    final updated = task.copyWith(
      vocalsPath: stems.vocalsPath,
      backgroundPath: stems.backgroundPath,
      updatedAt: DateTime.now(),
    );
    await ref.read(taskRepositoryProvider).save(updated);
    await _refreshAfterSave(updated);
  }

  /// 保存换音色方案。与切分、替换方案、配乐同一条「随手落库」通路。
  Future<void> saveVoices(RenewTask task, VoicePlan voices) async {
    final updated = task.copyWith(voices: voices, updatedAt: DateTime.now());
    await ref.read(taskRepositoryProvider).save(updated);
    await _refreshAfterSave(updated);
  }

  /// 工作台落库：保存编辑后的 units。
  ///
  /// 工作台里的每次改动都直接落库（防抖 800ms），不需要用户点「保存」或
  /// 「确认」——他改完就该当作已经存下了。状态不变：editing 一直到导出。
  Future<void> saveSegmentationDraft(
      RenewTask task, List<SemanticUnit> units) async {
    final updated = task.copyWith(units: units, updatedAt: DateTime.now());
    await ref.read(taskRepositoryProvider).save(updated);
    await _refreshAfterSave(updated);
  }
}

final taskListProvider =
    AsyncNotifierProvider<TaskListController, List<RenewTask>>(
        TaskListController.new);


/// 启动时要直接打开的任务（来自 `ishkafel open <task>` 传的 `--task=`）。
///
/// null 表示照常进列表页。用完即弃：打开过一次就不该再自动跳，否则用户
/// 返回列表会被立刻弹回去
final initialTaskIdProvider = Provider<String?>((ref) => null);

