import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/analysis_pipeline.dart';
import 'package:ishkafel/core/analysis/analysis_progress.dart';
import 'package:ishkafel/core/analysis/audio_extractor.dart';
import 'package:ishkafel/core/analysis/boundary_snapper.dart';
import 'package:ishkafel/core/analysis/providers.dart';
import 'package:ishkafel/core/analysis/scene_detector.dart';
import 'package:ishkafel/core/analysis/segmentation_builder.dart';
import 'package:ishkafel/core/analysis/silence_detector.dart';
import 'package:ishkafel/core/ffmpeg/ffprobe_service.dart';
import 'package:ishkafel/core/ffmpeg/process_runner.dart';
import 'package:ishkafel/core/net/json_poster.dart';
import 'package:ishkafel/core/ffmpeg/thumbnail_service.dart';
import 'package:ishkafel/core/log/app_log.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/tag_group_ref.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/replacement/picked_material.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';
import 'package:ishkafel/core/storage/task_repository.dart';
import 'package:ishkafel/features/import_flow/import_service.dart';
import 'package:ishkafel/features/tasks/analysis_error_message.dart';
import 'package:ishkafel/features/tasks/task_artifact_cleaner.dart';
import 'package:ishkafel/features/tasks/task_list_controller.dart';

/// 假 ASR/切分：不会被调用（_FakePipeline 覆写 analyze，不走真实管线）
class _NoopAsr implements AsrProvider {
  @override
  Future<List<AsrSentence>> transcribe(String pcmPath) async => const [];
}

class _NoopSplitter implements SemanticSplitter {
  @override
  Future<List<UnitDraft>> split(List<AsrSentence> sentences) async => const [];
}

/// 假分析管线：跳过真实音视频/AI 调用，直接模拟分析结果落库（或失败）
class _FakePipeline extends AnalysisPipeline {
  final TaskRepository repo;
  final bool shouldFail;

  /// 非 null 时直接抛出这个对象（用于验证各类真实异常的展示文案）
  final Object? failWith;
  int analyzeCallCount = 0;

  _FakePipeline({
    required this.repo,
    this.shouldFail = false,
    this.failWith,
  }) : super(
          audio: AudioExtractor(run: (_, _) async => ProcessResult(1, 0, '', '')),
          silence: const SilenceDetector(),
          scenes: SceneDetector(run: (_, _) async => ProcessResult(1, 0, '', '')),
          asr: _NoopAsr(),
          splitter: _NoopSplitter(),
          builder: const SegmentationBuilder(snapper: BoundarySnapper()),
          repository: repo,
          workDir: Directory.systemTemp,
        );

  @override
  Future<RenewTask> analyze(RenewTask task,
      {AnalysisProgressSink? onProgress,
      void Function(RenewTask ready)? onUnitsReady}) async {
    analyzeCallCount++;
    onProgress?.call(
        const AnalysisProgress(stage: AnalysisStage.extractingAudio));
    if (failWith != null) throw failWith!;
    if (shouldFail) throw StateError('分析失败（模拟）');
    final updated =
        task.copyWith(status: RenewTaskStatus.ready, updatedAt: DateTime.now());
    await repo.save(updated);
    return updated;
  }
}

/// 记录被清理的任务 id，验证删除确实连带清理中间产物
class _RecordingCleaner implements TaskArtifactCleaner {
  final List<String> cleaned;
  _RecordingCleaner(this.cleaned);
  @override
  Future<void> cleanup(String taskId) async => cleaned.add(taskId);
}

/// 清理失败的假实现：不应阻断任务删除
class _ThrowingCleaner implements TaskArtifactCleaner {
  @override
  Future<void> cleanup(String taskId) async =>
      throw const FileSystemException('磁盘只读');
}

/// 内存假实现，避免测试碰文件系统（仿照 task_list_page_test.dart 的做法）
class InMemoryTaskRepository implements TaskRepository {
  final _store = <String, RenewTask>{};
  @override
  Future<List<RenewTask>> findAll() async {
    final list = _store.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  @override
  Future<RenewTask?> findById(String id) async => _store[id];
  @override
  Future<void> save(RenewTask task) async => _store[task.id] = task;
  @override
  Future<void> delete(String id) async => _store.remove(id);
}

/// save 可被开关成「必定抛 I/O 异常」的假仓库：模拟磁盘写满 / 数据目录只读
class _SaveFailingRepository extends InMemoryTaskRepository {
  bool failSave = false;

  @override
  Future<void> save(RenewTask task) async {
    if (failSave) throw const FileSystemException('磁盘写入失败（模拟）');
    return super.save(task);
  }
}

/// findAll 可被开关成「必定抛 I/O 异常」的假仓库：模拟数据目录整体读不出来
class _FindAllFailingRepository extends InMemoryTaskRepository {
  bool failFindAll = false;

  @override
  Future<List<RenewTask>> findAll() async {
    if (failFindAll) {
      throw const PathNotFoundException('/tasks', OSError('No such file', 2));
    }
    return super.findAll();
  }
}

/// findAll 取完快照后可被挂起的假仓库。
///
/// 精确复刻真实行为：`findAll` 的结果是「**开始那一刻**的磁盘快照」
///（真实实现里是后台 isolate 遍历目录读盘，100 条约 131 ms），
/// 期间发生的写盘不会进入这一份快照。
class _SnapshotGatedRepository extends InMemoryTaskRepository {
  Completer<void>? gate;

  @override
  Future<List<RenewTask>> findAll() async {
    final snapshot = await super.findAll();
    final pending = gate;
    if (pending != null) await pending.future;
    return snapshot;
  }
}

/// 记录 findAll 调用次数的假仓库：用于证明「保存一条任务不再全量重读」
class _CountingRepository extends InMemoryTaskRepository {
  int findAllCallCount = 0;

  @override
  Future<List<RenewTask>> findAll() async {
    findAllCallCount++;
    return super.findAll();
  }
}

/// 挂起启用后的第一次保存，让第二个编辑动作有机会并发到达。
/// 真实文件仓库在 Windows 上正是在这段重叠里争抢 rename。
class _FirstSaveGatedRepository extends InMemoryTaskRepository {
  final firstSaveStarted = Completer<void>();
  final releaseFirstSave = Completer<void>();
  bool gateNextSave = false;
  int gatedSaveCount = 0;

  @override
  Future<void> save(RenewTask task) async {
    if (gateNextSave && gatedSaveCount++ == 0) {
      firstSaveStarted.complete();
      await releaseFirstSave.future;
    }
    await super.save(task);
  }
}

RenewTask makeExternalTask(String id, String name, DateTime updatedAt) =>
    RenewTask(
      id: id,
      name: name,
      sourcePath: '/v/$id.mp4',
      status: RenewTaskStatus.analyzing,
      createdAt: updatedAt,
      updatedAt: updatedAt,
    );

/// ffprobe 假返回，结构与 import_service_test.dart 保持一致
const probeJson = {
  'streams': [
    {
      'codec_type': 'video',
      'width': 1080,
      'height': 1920,
      'r_frame_rate': '30/1',
    },
  ],
  'format': {'duration': '10.0', 'size': '100'},
};

void main() {
  late InMemoryTaskRepository repo;
  late ImportService importService;
  late Directory tempDir;
  late ProviderContainer container;

  setUp(() async {
    tempDir =
        await Directory.systemTemp.createTemp('ishkafel_controller_test_');
    repo = InMemoryTaskRepository();
    importService = ImportService(
      repository: repo,
      // 假 ffprobe/ffmpeg ProcessRunner，避免测试依赖真实二进制
      ffprobe: FfprobeService(
          run: (_, _) async => ProcessResult(1, 0, jsonEncode(probeJson), '')),
      thumbnails:
          ThumbnailService(run: (_, _) async => ProcessResult(1, 0, '', '')),
      coversDir: Directory('${tempDir.path}/covers'),
      idGenerator: () => 'new-id',
      clock: () => DateTime.utc(2026, 7, 29, 12),
    );
    container = ProviderContainer(overrides: [
      taskRepositoryProvider.overrideWithValue(repo),
      importServiceProvider.overrideWithValue(importService),
    ]);
    addTearDown(container.dispose);
  });

  tearDown(() async => tempDir.delete(recursive: true));

  test('importFile 导入后新任务出现在任务列表中', () async {
    // 先等 build() 完成，建立初始（空）状态
    await container.read(taskListProvider.future);

    await container
        .read(taskListProvider.notifier)
        .importFile('/videos/新片.mp4');

    final state = container.read(taskListProvider);
    expect(state, isA<AsyncData<List<RenewTask>>>());
    final tasks = state.value!;
    expect(tasks.map((t) => t.id), contains('new-id'));
    expect(tasks.firstWhere((t) => t.id == 'new-id').name, '新片');
  });

  test('importFile 把向导选的两个标签组带给导入服务', () async {
    await container.read(taskListProvider.future);

    await container.read(taskListProvider.notifier).importFile(
          '/videos/新片.mp4',
          unitTagGroups: [const TagGroupRef(id: 1279, name: '衣清.消毒液')],
          shotTagGroups: [const TagGroupRef(id: 136, name: '画面类型')],
        );

    final task = container
        .read(taskListProvider)
        .value!
        .firstWhere((t) => t.id == 'new-id');
    expect(task.unitTagGroup, const TagGroupRef(id: 1279, name: '衣清.消毒液'));
    expect(task.shotTagGroup, const TagGroupRef(id: 136, name: '画面类型'));
  });

  test('reload 重新从仓库拉取内容', () async {
    await container.read(taskListProvider.future);
    expect(container.read(taskListProvider).value, isEmpty);

    // 绕过 controller 直接写仓库，模拟状态之外发生的变化
    await repo.save(makeExternalTask('ext', '外部任务', DateTime.utc(2026, 7, 29)));
    // 此时 controller 持有的 state 还未刷新
    expect(container.read(taskListProvider).value, isEmpty);

    await container.read(taskListProvider.notifier).reload();

    final tasks = container.read(taskListProvider).value!;
    expect(tasks.map((t) => t.id), contains('ext'));
  });

  test('并发保存替换方案与已选素材会在最新任务上合并，不互相覆盖', () async {
    final concurrentRepo = _FirstSaveGatedRepository();
    const unit = SemanticUnit(
      index: 0,
      startMs: 0,
      endMs: 1000,
      transcript: '第一句',
      shots: [Shot(startMs: 0, endMs: 1000)],
    );
    final task = RenewTask(
      id: 'concurrent-edit',
      name: '并发编辑',
      sourcePath: '/v/concurrent-edit.mp4',
      status: RenewTaskStatus.ready,
      createdAt: DateTime.utc(2026, 9, 16),
      updatedAt: DateTime.utc(2026, 9, 16),
      units: const [unit],
    );
    await concurrentRepo.save(task);
    final concurrentContainer = ProviderContainer(overrides: [
      taskRepositoryProvider.overrideWithValue(concurrentRepo),
      importServiceProvider.overrideWithValue(importService),
    ]);
    addTearDown(concurrentContainer.dispose);
    await concurrentContainer.read(taskListProvider.future);
    concurrentRepo.gateNextSave = true;

    final controller = concurrentContainer.read(taskListProvider.notifier);
    final savePlan = controller.savePickingPlan(
      task,
      [UnitReplacement.perShot(const {0: [101]})],
    );
    await concurrentRepo.firstSaveStarted.future;
    final saveMaterials = controller.savePickedMaterials(
      task,
      const [PickedMaterial(id: 101, name: '候选素材')],
    );
    await Future<void>.delayed(Duration.zero);
    concurrentRepo.releaseFirstSave.complete();
    await Future.wait([savePlan, saveMaterials]);

    final saved = (await concurrentRepo.findById(task.id))!;
    expect(saved.replacementsByUid[unit.uid]!.shotCandidateIds[0], [101]);
    expect(saved.pickedMaterials,
        const [PickedMaterial(id: 101, name: '候选素材')]);
  });

  test('importFile 后自动触发分析并刷新为 awaitingCut', () async {
    final pipelineContainer = ProviderContainer(overrides: [
      taskRepositoryProvider.overrideWithValue(repo),
      importServiceProvider.overrideWithValue(importService),
      analysisPipelineProvider
          .overrideWithValue(_FakePipeline(repo: repo)),
    ]);
    addTearDown(pipelineContainer.dispose);

    await pipelineContainer.read(taskListProvider.future);
    await pipelineContainer
        .read(taskListProvider.notifier)
        .importFile('/videos/新片.mp4');

    // importFile 本身只等落库+首次刷新（此时任务仍是 analyzing），
    // 后台分析异步完成后再刷新一次
    await pumpEventQueue();

    final tasks = pipelineContainer.read(taskListProvider).value!;
    final task = tasks.firstWhere((t) => t.id == 'new-id');
    expect(task.status, RenewTaskStatus.ready);
  });

  test('分析失败时任务保持 analyzing、落库 analysisError 且不崩溃', () async {
    final pipelineContainer = ProviderContainer(overrides: [
      taskRepositoryProvider.overrideWithValue(repo),
      importServiceProvider.overrideWithValue(importService),
      analysisPipelineProvider
          .overrideWithValue(_FakePipeline(repo: repo, shouldFail: true)),
    ]);
    addTearDown(pipelineContainer.dispose);

    await pipelineContainer.read(taskListProvider.future);
    await pipelineContainer
        .read(taskListProvider.notifier)
        .importFile('/videos/新片.mp4');

    await pumpEventQueue();

    final tasks = pipelineContainer.read(taskListProvider).value!;
    final task = tasks.firstWhere((t) => t.id == 'new-id');
    expect(task.status, RenewTaskStatus.analyzing);
    // 未知异常统一落成一句中文（详见 Important 5 分组），不再是 toString()
    expect(task.analysisError, unknownAnalysisErrorMessage);

    // 仓库中同样落库，保证重启后仍能读到失败原因
    final persisted = await repo.findById('new-id');
    expect(persisted!.analysisError, isNotNull);
  });

  test('分析失败信息落库前按 300 字截断，避免超长堆栈污染 JSON', () async {
    // 用「上层直接给出的中文原因」这条会原样透传的路径来验证截断
    // （未知异常已被翻译成固定短句，走不到截断逻辑）
    final longMessage = '错' * 500;
    final pipelineContainer = ProviderContainer(overrides: [
      taskRepositoryProvider.overrideWithValue(repo),
      importServiceProvider.overrideWithValue(importService),
      analysisPipelineProvider
          .overrideWithValue(_FakePipeline(repo: repo, failWith: longMessage)),
    ]);
    addTearDown(pipelineContainer.dispose);

    await pipelineContainer.read(taskListProvider.future);
    await pipelineContainer
        .read(taskListProvider.notifier)
        .importFile('/videos/新片.mp4');

    await pumpEventQueue();

    final tasks = pipelineContainer.read(taskListProvider).value!;
    final task = tasks.firstWhere((t) => t.id == 'new-id');
    expect(task.analysisError!.length, lessThanOrEqualTo(300));
  });

  test('分析失败信息截断码点安全，不切断 UTF-16 代理对（含 emoji 的错误信息）', () async {
    // ASCII 填充恰好占满 299 个 UTF-16 code unit，后面第一个 emoji
    //（占 2 个 code unit）恰好横跨第 300 个截断边界：若按 code unit 朴素
    // substring(0, 300) 截断会切在代理对中间，留下落单的高位 surrogate。
    final longMessage = '${'a' * 299}${'😀' * 10}';
    final pipelineContainer = ProviderContainer(overrides: [
      taskRepositoryProvider.overrideWithValue(repo),
      importServiceProvider.overrideWithValue(importService),
      analysisPipelineProvider
          .overrideWithValue(_FakePipeline(repo: repo, failWith: longMessage)),
    ]);
    addTearDown(pipelineContainer.dispose);

    await pipelineContainer.read(taskListProvider.future);
    await pipelineContainer
        .read(taskListProvider.notifier)
        .importFile('/videos/新片.mp4');
    await pumpEventQueue();

    final tasks = pipelineContainer.read(taskListProvider).value!;
    final task = tasks.firstWhere((t) => t.id == 'new-id');
    final result = task.analysisError!;

    // 不应以落单的高位代理（high surrogate, U+D800-U+DBFF）结尾
    expect(result.codeUnits.last, isNot(inInclusiveRange(0xD800, 0xDBFF)));
    // UTF-8 编解码往返一致（无落单 surrogate 才能安全编解码）
    expect(utf8.decode(utf8.encode(result)), result);
    // JSON 落库/读取往返一致
    final decoded = RenewTask.fromJson(jsonDecode(jsonEncode(task.toJson())));
    expect(decoded.analysisError, result);
  });

  group('AI 未配置：导入后不能静默卡死在「分析中」', () {
    test('管线不可用时导入立即落成失败态并带人话原因', () async {
      await container.read(taskListProvider.future);

      await container
          .read(taskListProvider.notifier)
          .importFile('/videos/新片.mp4');

      final task = container
          .read(taskListProvider)
          .value!
          .firstWhere((t) => t.id == 'new-id');
      expect(task.analysisError, isNotNull);
      expect(task.analysisError, contains('AI'));
      expect((await repo.findById('new-id'))!.analysisError, isNotNull,
          reason: '必须落库，重启后仍能看到原因并重试');
    });

    test('并发守卫命中时 retryAnalysis 返回 alreadyRunning', () async {
      final task = makeExternalTask('busy', '进行中', DateTime.utc(2026, 7, 29));
      await repo.save(task);
      final pipelineContainer = ProviderContainer(overrides: [
        taskRepositoryProvider.overrideWithValue(repo),
        importServiceProvider.overrideWithValue(importService),
        analysisPipelineProvider.overrideWithValue(_FakePipeline(repo: repo)),
      ]);
      addTearDown(pipelineContainer.dispose);
      await pipelineContainer.read(taskListProvider.future);
      final notifier = pipelineContainer.read(taskListProvider.notifier);

      final first = notifier.retryAnalysis(task);
      final second = notifier.retryAnalysis(task);
      final outcomes = await Future.wait([first, second]);
      await pumpEventQueue();

      expect(outcomes, [RetryOutcome.started, RetryOutcome.alreadyRunning]);
    });
  });

  group('启动装载：僵死的「分析中」任务恢复', () {
    RenewTask makeAnalyzing(String id, {String? analysisError}) => RenewTask(
          id: id,
          name: '任务$id',
          sourcePath: '/v/$id.mp4',
          status: RenewTaskStatus.analyzing,
          createdAt: DateTime.utc(2026, 7, 29),
          updatedAt: DateTime.utc(2026, 7, 29),
          analysisError: analysisError,
        );

    test('分析中途退出 app 的任务被标记为「已中断」并落库，从而可走重试路径', () async {
      await repo.save(makeAnalyzing('stalled'));

      final tasks = await container.read(taskListProvider.future);

      final task = tasks.firstWhere((t) => t.id == 'stalled');
      expect(task.status, RenewTaskStatus.analyzing);
      expect(task.analysisError, isNotNull);
      expect(task.analysisError, contains('中断'));
      expect((await repo.findById('stalled'))!.analysisError, isNotNull,
          reason: '必须落库，否则重启后仍然卡死');
    });

    test('已带失败原因的任务不被覆盖', () async {
      await repo.save(makeAnalyzing('failed', analysisError: '网络连接超时'));

      final tasks = await container.read(taskListProvider.future);

      expect(tasks.firstWhere((t) => t.id == 'failed').analysisError, '网络连接超时');
    });

    test('非「分析中」状态的任务不受影响', () async {
      await repo.save(makeAnalyzing('done').copyWith(
          status: RenewTaskStatus.ready, units: const []));

      final tasks = await container.read(taskListProvider.future);

      expect(tasks.firstWhere((t) => t.id == 'done').analysisError, isNull);
    });

    test('本次运行中正在分析的任务不会被 reload 误标为中断', () async {
      final pipelineContainer = ProviderContainer(overrides: [
        taskRepositoryProvider.overrideWithValue(repo),
        importServiceProvider.overrideWithValue(importService),
        analysisPipelineProvider.overrideWithValue(_FakePipeline(repo: repo)),
      ]);
      addTearDown(pipelineContainer.dispose);

      await pipelineContainer.read(taskListProvider.future);
      await pipelineContainer
          .read(taskListProvider.notifier)
          .importFile('/videos/新片.mp4');
      await pumpEventQueue();

      final task = pipelineContainer
          .read(taskListProvider)
          .value!
          .firstWhere((t) => t.id == 'new-id');
      expect(task.analysisError, isNull);
    });
  });

  group('删除 / 重命名', () {
    RenewTask makeTask(String id) => RenewTask(
          id: id,
          name: '任务$id',
          sourcePath: '/v/$id.mp4',
          status: RenewTaskStatus.ready,
          createdAt: DateTime.utc(2026, 7, 29),
          updatedAt: DateTime.utc(2026, 7, 29),
          units: const [],
        );

    test('deleteTask 从仓库移除并连带清理中间产物', () async {
      final cleaned = <String>[];
      await repo.save(makeTask('d1'));
      final deleteContainer = ProviderContainer(overrides: [
        taskRepositoryProvider.overrideWithValue(repo),
        importServiceProvider.overrideWithValue(importService),
        taskArtifactCleanerProvider.overrideWithValue(
            _RecordingCleaner(cleaned)),
      ]);
      addTearDown(deleteContainer.dispose);

      await deleteContainer.read(taskListProvider.future);
      await deleteContainer
          .read(taskListProvider.notifier)
          .deleteTask(makeTask('d1'));

      expect(await repo.findById('d1'), isNull);
      expect(cleaned, ['d1']);
      expect(deleteContainer.read(taskListProvider).value, isEmpty);
    });

    test('产物清理失败不阻断删除', () async {
      await repo.save(makeTask('d2'));
      final deleteContainer = ProviderContainer(overrides: [
        taskRepositoryProvider.overrideWithValue(repo),
        importServiceProvider.overrideWithValue(importService),
        taskArtifactCleanerProvider.overrideWithValue(_ThrowingCleaner()),
      ]);
      addTearDown(deleteContainer.dispose);

      await deleteContainer.read(taskListProvider.future);
      await deleteContainer
          .read(taskListProvider.notifier)
          .deleteTask(makeTask('d2'));

      expect(await repo.findById('d2'), isNull);
    });

    test('renameTask 保存新名称并刷新列表', () async {
      await repo.save(makeTask('r1'));
      await container.read(taskListProvider.future);

      await container
          .read(taskListProvider.notifier)
          .renameTask(makeTask('r1'), '  滴露_植源喷雾  ');

      final saved = await repo.findById('r1');
      expect(saved!.name, '滴露_植源喷雾', reason: '首尾空白应被去除');
      expect(container.read(taskListProvider).value!.single.name, '滴露_植源喷雾');
    });

    test('renameTask 以磁盘上的当前记录为基线，不把对话框打开时的旧快照写回去', () async {
      await repo.save(makeTask('r3'));
      await container.read(taskListProvider.future);
      // 重命名对话框停留期间后台分析完成，磁盘上多了 units 与新状态
      final analyzed = makeTask('r3').copyWith(
        status: RenewTaskStatus.ready,
        units: [
          SemanticUnit(
            index: 0,
            startMs: 0,
            endMs: 1000,
            transcript: '分析产出的台词',
            shots: const [Shot(startMs: 0, endMs: 1000)],
          ),
        ],
      );
      await repo.save(analyzed);

      // 传入的是对话框打开时捕获的旧对象（units 为空、状态是 awaitingCut）
      await container
          .read(taskListProvider.notifier)
          .renameTask(makeTask('r3'), '新名字');

      final saved = await repo.findById('r3');
      expect(saved!.name, '新名字');
      expect(saved.units, hasLength(1), reason: '重命名不该抹掉后台分析的成果');
      expect(saved.status, RenewTaskStatus.ready);
    });

    test('renameTask 空名称被拒绝，原名保留', () async {
      await repo.save(makeTask('r2'));
      await container.read(taskListProvider.future);

      await container.read(taskListProvider.notifier).renameTask(
            makeTask('r2'),
            '   ',
          );

      expect((await repo.findById('r2'))!.name, '任务r2');
    });
  });

  group('reload 的旧快照不能覆盖期间的局部更新（Important 3）', () {
    late _SnapshotGatedRepository gated;
    late ProviderContainer gatedContainer;

    RenewTask makeAwaitingCut(String id) => RenewTask(
          id: id,
          name: '任务$id',
          sourcePath: '/v/$id.mp4',
          status: RenewTaskStatus.ready,
          createdAt: DateTime.utc(2026, 7, 29),
          updatedAt: DateTime.utc(2026, 7, 29),
          units: const [],
        );

    List<SemanticUnit> makeUnits() => const [
          SemanticUnit(
            index: 0,
            startMs: 0,
            endMs: 1000,
            transcript: '确认切分后的台词',
            shots: [Shot(startMs: 0, endMs: 1000)],
          ),
        ];

    setUp(() async {
      gated = _SnapshotGatedRepository();
      await gated.save(makeAwaitingCut('b'));
      gatedContainer = ProviderContainer(overrides: [
        taskRepositoryProvider.overrideWithValue(gated),
        importServiceProvider.overrideWithValue(importService),
      ]);
      addTearDown(gatedContainer.dispose);
      await gatedContainer.read(taskListProvider.future);
    });

    test('后台分析结束触发的 reload 不把「确认切分」的结果冲掉', () async {
      final notifier = gatedContainer.read(taskListProvider.notifier);
      // ① 后台分析结束 → reload 起步，快照此刻已定格（任务 B 仍是 awaitingCut）
      final gate = Completer<void>();
      gated.gate = gate;
      final reloading = notifier.reload();

      // ② 这段时间里用户在工作台改了切分，自动落库成功
      //（这条路径走局部更新，不会再碰 findAll，因此闸门保持关着）
      await notifier.saveSegmentationDraft(makeAwaitingCut('b'), makeUnits());

      // ③ 步骤①的快照这才返回
      gate.complete();
      await reloading;

      final inMemory = gatedContainer
          .read(taskListProvider)
          .value!
          .firstWhere((t) => t.id == 'b');
      expect(inMemory.status, RenewTaskStatus.ready,
          reason: '内存态落后磁盘且不自愈：用户再进审片台会以旧 units 为基线，'
              '再保存就把上一次确认的切分永久覆盖');
      expect(inMemory.units, makeUnits());
    });

    test('reload 期间被删除的任务不会被旧快照带回列表', () async {
      final notifier = gatedContainer.read(taskListProvider.notifier);
      final gate = Completer<void>();
      gated.gate = gate;
      final reloading = notifier.reload();

      await notifier.deleteTask(makeAwaitingCut('b'));

      gate.complete();
      await reloading;

      expect(gatedContainer.read(taskListProvider).value, isEmpty);
    });

    test('没有并发局部更新时，reload 照常反映磁盘上的外部变化', () async {
      final notifier = gatedContainer.read(taskListProvider.notifier);
      await gated.save(makeAwaitingCut('ext'));

      await notifier.reload();

      expect(gatedContainer.read(taskListProvider).value!.map((t) => t.id).toSet(),
          {'b', 'ext'});
    });
  });

  group('分析失败原因要说人话（Important 5）', () {
    /// 让假管线抛出 [error]，返回落库后的 analysisError
    Future<String> analysisErrorFor(Object error) async {
      final pipelineContainer = ProviderContainer(overrides: [
        taskRepositoryProvider.overrideWithValue(repo),
        importServiceProvider.overrideWithValue(importService),
        analysisPipelineProvider
            .overrideWithValue(_FakePipeline(repo: repo, failWith: error)),
      ]);
      addTearDown(pipelineContainer.dispose);
      await pipelineContainer.read(taskListProvider.future);
      await pipelineContainer
          .read(taskListProvider.notifier)
          .importFile('/videos/新片.mp4');
      await pumpEventQueue();
      return (await repo.findById('new-id'))!.analysisError!;
    }

    test('MediaToolMissingException 的中文安装引导不再挂类名前缀', () async {
      final message =
          await analysisErrorFor(const MediaToolMissingException('ffmpeg'));

      expect(message, missingToolMessage('ffmpeg'),
          reason: 'message 本身就是可直接展示的安装引导，上层不该再包一层类名');
    });

    test('AiHttpException 不把类名与服务端英文原文摊给用户', () async {
      final message = await analysisErrorFor(const AiHttpException(
          'ASR 调用失败 [X-Api-Status-Code=45000001]：Invalid request parameter',
          statusCode: 400));

      expect(message, isNot(contains('AiHttpException')));
      expect(message, isNot(contains('Invalid request parameter')));
      expect(message, contains('AI'));
    });

    test('FfmpegException 不把类名与 ffmpeg 英文 stderr 摊给用户', () async {
      final message = await analysisErrorFor(const FfmpegException(
          'ffmpeg 音频提取失败（exit=1）：Invalid data found when processing input'));

      expect(message, isNot(contains('FfmpegException')));
      expect(message, isNot(contains('Invalid data found')));
    });

    test('未知异常统一落成一句中文，原始文本只进日志', () async {
      final captured = <String>[];
      final original = AppLog.sink;
      AppLog.sink = captured.add;
      addTearDown(() => AppLog.sink = original);

      final message =
          await analysisErrorFor(StateError('Concurrent modification'));

      expect(message, isNot(contains('Bad state')));
      expect(message, isNot(contains('Concurrent modification')));
      expect(captured.where((l) => l.contains('Concurrent modification')),
          isNotEmpty,
          reason: '原始文本要能在日志里查到');
    });

    test('已经是中文人话的原因（AI 未配置）原样保留', () async {
      await container.read(taskListProvider.future);

      await container
          .read(taskListProvider.notifier)
          .importFile('/videos/新片.mp4');

      expect((await repo.findById('new-id'))!.analysisError,
          pipelineUnavailableMessage);
    });
  });

  group('装载整体失败不清空任务网格（Important 7）', () {
    RenewTask makeStored(String id) => RenewTask(
          id: id,
          name: '任务$id',
          sourcePath: '/v/$id.mp4',
          status: RenewTaskStatus.ready,
          createdAt: DateTime.utc(2026, 7, 29),
          updatedAt: DateTime.utc(2026, 7, 29),
          units: const [],
        );

    test('reload 失败时保留上一次装载到的列表，并把失败标成可重试', () async {
      final failing = _FindAllFailingRepository();
      await failing.save(makeStored('keep'));
      final failContainer = ProviderContainer(overrides: [
        taskRepositoryProvider.overrideWithValue(failing),
        importServiceProvider.overrideWithValue(importService),
      ]);
      addTearDown(failContainer.dispose);
      await failContainer.read(taskListProvider.future);

      final captured = <String>[];
      final original = AppLog.sink;
      AppLog.sink = captured.add;
      addTearDown(() => AppLog.sink = original);

      failing.failFindAll = true;
      await failContainer.read(taskListProvider.notifier).reload();

      final state = failContainer.read(taskListProvider);
      expect(state.valueOrNull?.map((t) => t.id), ['keep'],
          reason: '一次性 I/O 抖动不该让整个任务网格清空');
      expect(state.hasError, isTrue, reason: 'UI 需要据此给出可重试的提示');
      expect(captured.where((l) => l.contains('PathNotFoundException')),
          isNotEmpty,
          reason: '原始异常不能被静默吞进 state，排查时要能在日志里找到');
    });

    test('恢复正常后再次 reload 能自愈', () async {
      final failing = _FindAllFailingRepository();
      await failing.save(makeStored('keep'));
      final failContainer = ProviderContainer(overrides: [
        taskRepositoryProvider.overrideWithValue(failing),
        importServiceProvider.overrideWithValue(importService),
      ]);
      addTearDown(failContainer.dispose);
      await failContainer.read(taskListProvider.future);
      failing.failFindAll = true;
      await failContainer.read(taskListProvider.notifier).reload();

      failing.failFindAll = false;
      await failing.save(makeStored('added'));
      await failContainer.read(taskListProvider.notifier).reload();

      final state = failContainer.read(taskListProvider);
      expect(state.hasError, isFalse);
      expect(state.value!.map((t) => t.id).toSet(), {'keep', 'added'});
    });
  });

  group('已删除的任务不能被「复活」回磁盘（Critical 3）', () {
    RenewTask makeDeletableTask() => RenewTask(
          id: 'gone',
          name: '已删除的任务',
          sourcePath: '/v/gone.mp4',
          status: RenewTaskStatus.analyzing,
          createdAt: DateTime.utc(2026, 7, 29),
          updatedAt: DateTime.utc(2026, 7, 29),
          analysisError: '分析失败（模拟）',
        );

    test('SnackBar 上残留的「重试」点下去，不会把已删除的任务写回磁盘', () async {
      final task = makeDeletableTask();
      await repo.save(task);
      final pipeline = _FakePipeline(repo: repo);
      final pipelineContainer = ProviderContainer(overrides: [
        taskRepositoryProvider.overrideWithValue(repo),
        importServiceProvider.overrideWithValue(importService),
        analysisPipelineProvider.overrideWithValue(pipeline),
      ]);
      addTearDown(pipelineContainer.dispose);
      await pipelineContainer.read(taskListProvider.future);
      final notifier = pipelineContainer.read(taskListProvider.notifier);

      // 用户在 SnackBar 停留期间删掉了这条任务（封面/PCM/抽帧已被清理）
      await notifier.deleteTask(task);
      // 闭包里捕获的仍是删除前的 task 对象
      final outcome = await notifier.retryAnalysis(task);
      await pumpEventQueue();

      expect(outcome, RetryOutcome.taskMissing);
      expect(await repo.findById('gone'), isNull,
          reason: '中间产物已被清理，复活出来的任务不会自愈');
      expect(pipelineContainer.read(taskListProvider).value, isEmpty);
      expect(pipeline.analyzeCallCount, 0);
    });

    test('重命名对话框上残留的「保存」点下去，不会把已删除的任务写回磁盘', () async {
      final task = makeDeletableTask();
      await repo.save(task);
      await container.read(taskListProvider.future);
      final notifier = container.read(taskListProvider.notifier);

      await notifier.deleteTask(task);
      await notifier.renameTask(task, '新名字');

      expect(await repo.findById('gone'), isNull);
      expect(container.read(taskListProvider).value, isEmpty);
    });

    test('分析进行中任务被删除：失败落库不能把它复活', () async {
      final task = makeDeletableTask();
      await repo.save(task);
      final pipelineContainer = ProviderContainer(overrides: [
        taskRepositoryProvider.overrideWithValue(repo),
        importServiceProvider.overrideWithValue(importService),
        analysisPipelineProvider
            .overrideWithValue(_FakePipeline(repo: repo, shouldFail: true)),
      ]);
      addTearDown(pipelineContainer.dispose);
      await pipelineContainer.read(taskListProvider.future);
      final notifier = pipelineContainer.read(taskListProvider.notifier);

      await notifier.retryAnalysis(task);
      await notifier.deleteTask(task);
      await pumpEventQueue();

      expect(await repo.findById('gone'), isNull);
    });

    test('导入新任务不受影响（同样走 save，但记录本来就该被创建）', () async {
      await container.read(taskListProvider.future);

      await container
          .read(taskListProvider.notifier)
          .importFile('/videos/新片.mp4');

      expect(await repo.findById('new-id'), isNotNull);
    });
  });

  group('retryAnalysis', () {
    RenewTask makeFailedTask() => RenewTask(
          id: 'fail-1',
          name: '失败任务',
          sourcePath: '/v/fail-1.mp4',
          status: RenewTaskStatus.analyzing,
          createdAt: DateTime.utc(2026, 7, 29),
          updatedAt: DateTime.utc(2026, 7, 29),
          analysisError: '分析失败（模拟）',
        );

    test('retryAnalysis 清空错误、重跑假管线成功后进入 awaitingCut', () async {
      final task = makeFailedTask();
      await repo.save(task);

      final pipelineContainer = ProviderContainer(overrides: [
        taskRepositoryProvider.overrideWithValue(repo),
        importServiceProvider.overrideWithValue(importService),
        analysisPipelineProvider.overrideWithValue(_FakePipeline(repo: repo)),
      ]);
      addTearDown(pipelineContainer.dispose);

      await pipelineContainer.read(taskListProvider.future);
      await pipelineContainer.read(taskListProvider.notifier).retryAnalysis(task);
      await pumpEventQueue();

      final tasks = pipelineContainer.read(taskListProvider).value!;
      final updated = tasks.firstWhere((t) => t.id == 'fail-1');
      expect(updated.status, RenewTaskStatus.ready);
      expect(updated.analysisError, isNull);
    });

    test('pipeline 未配置时 retryAnalysis 返回 pipelineUnavailable 并写入人话原因', () async {
      final task = makeFailedTask();
      await repo.save(task);
      await container.read(taskListProvider.future);

      final outcome =
          await container.read(taskListProvider.notifier).retryAnalysis(task);

      expect(outcome, RetryOutcome.pipelineUnavailable);
      final persisted = await repo.findById('fail-1');
      expect(persisted!.analysisError, contains('AI'));
      expect(persisted.analysisError, isNot(contains('Exception')));
      expect(persisted.status, RenewTaskStatus.analyzing);
    });

    test('pipeline 可用时 retryAnalysis 返回 started', () async {
      final task = makeFailedTask();
      await repo.save(task);
      final pipelineContainer = ProviderContainer(overrides: [
        taskRepositoryProvider.overrideWithValue(repo),
        importServiceProvider.overrideWithValue(importService),
        analysisPipelineProvider.overrideWithValue(_FakePipeline(repo: repo)),
      ]);
      addTearDown(pipelineContainer.dispose);
      await pipelineContainer.read(taskListProvider.future);

      final outcome = await pipelineContainer
          .read(taskListProvider.notifier)
          .retryAnalysis(task);
      await pumpEventQueue();

      expect(outcome, RetryOutcome.started);
    });

    test('并发守卫：连续两次触发 retryAnalysis 同一任务，假管线 analyze 只执行一次', () async {
      final task = makeFailedTask();
      await repo.save(task);

      final pipeline = _FakePipeline(repo: repo);
      final pipelineContainer = ProviderContainer(overrides: [
        taskRepositoryProvider.overrideWithValue(repo),
        importServiceProvider.overrideWithValue(importService),
        analysisPipelineProvider.overrideWithValue(pipeline),
      ]);
      addTearDown(pipelineContainer.dispose);

      await pipelineContainer.read(taskListProvider.future);
      final notifier = pipelineContainer.read(taskListProvider.notifier);

      // 模拟用户快速连点：不等待第一次调用完成即触发第二次
      final first = notifier.retryAnalysis(task);
      final second = notifier.retryAnalysis(task);
      await Future.wait([first, second]);
      await pumpEventQueue();

      expect(pipeline.analyzeCallCount, 1);

      final updated = pipelineContainer.read(taskListProvider).value!
          .firstWhere((t) => t.id == 'fail-1');
      expect(updated.status, RenewTaskStatus.ready);
    });

    test('落库失败时并发守卫必须释放，否则该任务本次会话再也无法重试（Critical 2）',
        () async {
      final task = makeFailedTask();
      final failing = _SaveFailingRepository();
      await failing.save(task);
      final pipeline = _FakePipeline(repo: failing);
      final pipelineContainer = ProviderContainer(overrides: [
        taskRepositoryProvider.overrideWithValue(failing),
        importServiceProvider.overrideWithValue(importService),
        analysisPipelineProvider.overrideWithValue(pipeline),
      ]);
      addTearDown(pipelineContainer.dispose);
      await pipelineContainer.read(taskListProvider.future);
      final notifier = pipelineContainer.read(taskListProvider.notifier);

      // 第一次：磁盘写入失败，异常应冒泡给 UI（UI 提示「请稍后再试」）
      failing.failSave = true;
      await expectLater(
          notifier.retryAnalysis(task), throwsA(isA<FileSystemException>()));

      // 用户照提示再点一次：磁盘恢复后必须能真的重新开始分析
      failing.failSave = false;
      final outcome = await notifier.retryAnalysis(task);
      await pumpEventQueue();

      expect(outcome, RetryOutcome.started,
          reason: '写盘失败没有跑过 _runAnalyze，守卫不能留在集合里假装「正在分析中」');
      expect(pipeline.analyzeCallCount, 1);
    });
  });

  group('saveSegmentationDraft', () {
    List<SemanticUnit> makeUnits() => [
          SemanticUnit(
            index: 0,
            startMs: 0,
            endMs: 1000,
            transcript: '编辑后的台词',
            shots: const [Shot(startMs: 0, endMs: 1000)],
          ),
        ];

    RenewTask makeAwaitingCutTask() => RenewTask(
          id: 'cut-1',
          name: '待切分任务',
          sourcePath: '/v/cut-1.mp4',
          status: RenewTaskStatus.ready,
          createdAt: DateTime.utc(2026, 7, 29),
          updatedAt: DateTime.utc(2026, 7, 29),
          units: const [],
        );

    test('saveSegmentationDraft 只保存 units 不改变状态', () async {
      final task = makeAwaitingCutTask();
      await repo.save(task);
      await container.read(taskListProvider.future);

      final units = makeUnits();
      await container
          .read(taskListProvider.notifier)
          .saveSegmentationDraft(task, units);

      final saved = await repo.findById('cut-1');
      expect(saved!.status, RenewTaskStatus.ready);
      expect(saved.units, units);
    });
  });

  group('保存后局部更新（不再全量重读所有任务 JSON）', () {
    late _CountingRepository counting;
    late ProviderContainer localContainer;

    RenewTask makeStored(String id, DateTime updatedAt) => RenewTask(
          id: id,
          name: '任务$id',
          sourcePath: '/v/$id.mp4',
          status: RenewTaskStatus.ready,
          createdAt: DateTime.utc(2026, 7, 1),
          updatedAt: updatedAt,
          units: const [],
        );

    List<SemanticUnit> makeUnits() => const [
          SemanticUnit(
            index: 0,
            startMs: 0,
            endMs: 1000,
            transcript: '第一句',
            shots: [Shot(startMs: 0, endMs: 1000)],
          ),
        ];

    setUp(() async {
      counting = _CountingRepository();
      // 三条任务，updatedAt 依次递增（列表按 updatedAt 倒序：c、b、a）
      await counting.save(makeStored('a', DateTime.utc(2026, 7, 20)));
      await counting.save(makeStored('b', DateTime.utc(2026, 7, 21)));
      await counting.save(makeStored('c', DateTime.utc(2026, 7, 22)));
      localContainer = ProviderContainer(overrides: [
        taskRepositoryProvider.overrideWithValue(counting),
        importServiceProvider.overrideWithValue(importService),
      ]);
      addTearDown(localContainer.dispose);
      await localContainer.read(taskListProvider.future);
    });

    test('saveSegmentationDraft 不触发 findAll，且列表里那一条已更新', () async {
      final before = counting.findAllCallCount;

      await localContainer
          .read(taskListProvider.notifier)
          .saveSegmentationDraft(makeStored('a', DateTime.utc(2026, 7, 20)),
              makeUnits());

      expect(counting.findAllCallCount, before,
          reason: '保存一条任务不应再遍历目录全量解码所有任务 JSON');
      final tasks = localContainer.read(taskListProvider).value!;
      expect(tasks.length, 3);
      final updated = tasks.firstWhere((t) => t.id == 'a');
      expect(updated.status, RenewTaskStatus.ready);
      expect(updated.units, makeUnits());
    });

    test('saveSegmentationDraft 不触发 findAll，且列表里那一条已更新', () async {
      final before = counting.findAllCallCount;

      await localContainer
          .read(taskListProvider.notifier)
          .saveSegmentationDraft(
              makeStored('b', DateTime.utc(2026, 7, 21)), makeUnits());

      expect(counting.findAllCallCount, before);
      final tasks = localContainer.read(taskListProvider).value!;
      expect(tasks.firstWhere((t) => t.id == 'b').units, makeUnits());
      expect(tasks.firstWhere((t) => t.id == 'b').status,
          RenewTaskStatus.ready);
    });

    test('局部更新后列表排序与全量重读一致（按 updatedAt 倒序）', () async {
      expect(localContainer.read(taskListProvider).value!.map((t) => t.id),
          ['c', 'b', 'a']);

      // 更新最旧的一条：updatedAt 变成 now，应排到最前
      await localContainer
          .read(taskListProvider.notifier)
          .saveSegmentationDraft(
              makeStored('a', DateTime.utc(2026, 7, 20)), makeUnits());

      final localOrder =
          localContainer.read(taskListProvider).value!.map((t) => t.id).toList();
      expect(localOrder, ['a', 'c', 'b']);

      // 与真正重读一次的结果逐条对齐，证明排序口径没有分叉
      await localContainer.read(taskListProvider.notifier).reload();
      expect(
          localContainer.read(taskListProvider).value!.map((t) => t.id).toList(),
          localOrder);
    });

    test('renameTask 同样局部更新，不全量重读', () async {
      final before = counting.findAllCallCount;

      await localContainer
          .read(taskListProvider.notifier)
          .renameTask(makeStored('c', DateTime.utc(2026, 7, 22)), '新名字');

      expect(counting.findAllCallCount, before);
      expect(localContainer.read(taskListProvider).value!
          .firstWhere((t) => t.id == 'c').name, '新名字');
    });

    test('deleteTask 局部移除那一条，不全量重读', () async {
      final before = counting.findAllCallCount;

      await localContainer
          .read(taskListProvider.notifier)
          .deleteTask(makeStored('b', DateTime.utc(2026, 7, 21)));

      expect(counting.findAllCallCount, before);
      expect(localContainer.read(taskListProvider).value!.map((t) => t.id),
          ['c', 'a']);
    });
  });
}
