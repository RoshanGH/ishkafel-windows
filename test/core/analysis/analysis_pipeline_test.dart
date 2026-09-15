import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ai/ark_chat_client.dart';
import 'package:ishkafel/core/audio/vocal_separator.dart';
import 'package:ishkafel/core/ai/tag_dimension.dart';
import 'package:ishkafel/core/ai/taggers.dart';
import 'package:ishkafel/core/analysis/analysis_pipeline.dart';
import 'package:ishkafel/core/analysis/audio_extractor.dart';
import 'package:ishkafel/core/analysis/boundary_snapper.dart';
import 'package:ishkafel/core/analysis/providers.dart';
import 'package:path/path.dart' as p;
import 'package:ishkafel/core/analysis/scene_detector.dart';
import 'package:ishkafel/core/analysis/segmentation_builder.dart';
import 'package:ishkafel/core/analysis/silence_detector.dart';
import 'package:ishkafel/core/analysis/tag_vocabulary.dart';
import 'package:ishkafel/core/log/app_log.dart';
import 'package:ishkafel/core/models/tag_group_ref.dart';
import 'package:ishkafel/core/ffmpeg/thumbnail_service.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/video_info.dart';
import 'package:ishkafel/core/net/json_poster.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';

/// 假 ASR：返回固定句子
class FakeAsr implements AsrProvider {
  @override
  Future<List<AsrSentence>> transcribe(String pcmPath) async => const [
    AsrSentence(startMs: 0, endMs: 4100, text: '第一句'),
    AsrSentence(startMs: 4100, endMs: 9200, text: '第二句'),
  ];
}

/// 假语义切分：每句一个单元
class FakeSplitter implements SemanticSplitter {
  @override
  Future<List<UnitDraft>> split(List<AsrSentence> sentences) async => [
    for (final s in sentences)
      UnitDraft(startMs: s.startMs, endMs: s.endMs, transcript: s.text),
  ];
}

const showinfoFixture =
    '[Parsed_showinfo_1 @ 0x60] n: 0 pts: 120 pts_time:4.0 fmt:yuv420p\n';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ishkafel_pipeline_');
  });

  tearDown(() async => tempDir.delete(recursive: true));

  /// 假分离器：按真实工具的行为造出两条 stem
  VocalSeparator fakeSeparator({
    bool fail = false,
    List<int>? calls,
  }) => VocalSeparator(
    modelDir: Directory('${tempDir.path}/models'),
    run: (bin, args) async {
      calls?.add(1);
      if (fail) return ProcessResult(1, 1, '', '模型下载失败');
      final outDir = args[args.indexOf('--output_dir') + 1];
      Directory(outDir).createSync(recursive: true);
      // 产物名带模型标记（换模型要重算，见 VocalSeparator）
      final stem =
          '${args.first.split('/').last.split('.').first}-${VocalSeparator.modelTag}';
      File('$outDir/$stem-人声.wav').writeAsStringSync('v');
      File('$outDir/$stem-背景.wav').writeAsStringSync('b');
      return ProcessResult(1, 0, '', '');
    },
  );

  AnalysisPipeline makePipeline(
    FileTaskRepository repo, {
    VocalSeparator? separator,
  }) => AnalysisPipeline(
    separator: separator,
    audio: AudioExtractor(
      run: (_, args) async {
        // 假 ffmpeg 音频提取：写入 0.5 秒 16kHz 静音采样
        await File(
          args[args.length - 1],
        ).writeAsBytes(Uint8List(16000)); // 8000 个零采样
        return ProcessResult(1, 0, '', '');
      },
    ),
    silence: const SilenceDetector(),
    scenes: SceneDetector(
      run: (_, _) async => ProcessResult(1, 0, '', showinfoFixture),
    ),
    asr: FakeAsr(),
    splitter: FakeSplitter(),
    builder: const SegmentationBuilder(snapper: BoundarySnapper()),
    repository: repo,
    workDir: Directory('${tempDir.path}/work'),
    clock: () => DateTime.utc(2026, 7, 29, 12),
  );

  RenewTask makeTask({String id = 't1', String? sourcePath}) => RenewTask(
    id: id,
    name: '测试片',
    sourcePath: sourcePath ?? '/v/a.mp4',
    videoInfo: const VideoInfo(
      width: 1080,
      height: 1920,
      duration: Duration(milliseconds: 9200),
      fps: 30,
      fileSizeBytes: 1,
    ),
    status: RenewTaskStatus.analyzing,
    createdAt: DateTime.utc(2026, 7, 29),
    updatedAt: DateTime.utc(2026, 7, 29),
  );

  test('analyze 产出两层结构并落库，状态转 awaitingCut', () async {
    final repo = FileTaskRepository(tempDir);
    final task = makeTask();
    await repo.save(task);

    final result = await makePipeline(repo).analyze(task);

    expect(result.status, RenewTaskStatus.ready);
    expect(result.units, isNotNull);
    expect(result.units!.length, 2);
    // 内部边界 4100 吸附到镜头边界 4000（fixture 的 pts_time:4.0）
    expect(result.units![0].endMs, 4000);
    expect(result.units![1].startMs, 4000);
    expect(result.units![1].endMs, 9200);
    for (final u in result.units!) {
      expect(u.shotsStrictlyNested, true);
      expect(u.shots.first.startMs, u.startMs);
      expect(u.shots.last.endMs, u.endMs);
    }
    // 已落库
    final persisted = await repo.findById('t1');
    expect(persisted, result);
  });

  test('ASR 转完就把中转 PCM 丢掉——一条 96 秒的片子 18MB，留着只会只增不减', () async {
    final repo = FileTaskRepository(tempDir);
    final task = makeTask();
    await repo.save(task);
    final workDir = Directory('${tempDir.path}/work');

    await makePipeline(repo).analyze(task);

    expect(analysisPcmPath(workDir, 't1'), p.join(workDir.path, 't1.pcm'));
    expect(
      await File(analysisPcmPath(workDir, 't1')).exists(),
      isFalse,
      reason: 'ASR 是它唯一的读者；时间线波形存的是算好的包络，不是 PCM',
    );
  });

  test('videoInfo 缺失抛 StateError 且不落库变更', () async {
    final repo = FileTaskRepository(tempDir);
    final noInfo = RenewTask(
      id: 't2',
      name: 'n',
      sourcePath: '/v/b.mp4',
      status: RenewTaskStatus.analyzing,
      createdAt: DateTime.utc(2026, 7, 29),
      updatedAt: DateTime.utc(2026, 7, 29),
    );
    await expectLater(
      makePipeline(repo).analyze(noInfo),
      throwsA(isA<StateError>()),
    );
    expect(await repo.findById('t2'), isNull);
  });

  test('analyze 后 asrSentences 与 FakeAsr 输出逐值相等（精度红线）', () async {
    final repo = FileTaskRepository(tempDir);
    final task = makeTask();
    await repo.save(task);

    final result = await makePipeline(repo).analyze(task);

    expect(result.asrSentences, await FakeAsr().transcribe(''));
    final persisted = await repo.findById('t1');
    expect(persisted!.asrSentences, result.asrSentences);
  });

  group('两层打标的受控词表按任务的标签组解析（不同任务不共用一份词表）', () {
    /// 假词表源：按组 id 返回不同词表，并记录被问过哪些组
    final asked = <int>[];
    TagVocabularySource fakeSource(Map<int, List<String>> byGroup) =>
        _FakeVocabularySource(byGroup, asked);

    setUp(asked.clear);

    AnalysisPipeline taggingPipeline(
      FileTaskRepository repo, {
      UnitTagger? unitTagger,
      ShotTagger? shotTagger,
      TagVocabularySource? vocabulary,
      ThumbnailService? thumbnails,
    }) => AnalysisPipeline(
      audio: AudioExtractor(
        run: (_, args) async {
          await File(args.last).writeAsBytes(Uint8List(16000));
          return ProcessResult(1, 0, '', '');
        },
      ),
      silence: const SilenceDetector(),
      scenes: SceneDetector(
        run: (_, _) async => ProcessResult(1, 0, '', showinfoFixture),
      ),
      asr: FakeAsr(),
      splitter: FakeSplitter(),
      builder: const SegmentationBuilder(snapper: BoundarySnapper()),
      repository: repo,
      workDir: Directory('${tempDir.path}/work'),
      clock: () => DateTime.utc(2026, 7, 30),
      unitTagger: unitTagger,
      shotTagger: shotTagger,
      thumbnails: thumbnails,
      vocabulary: vocabulary,
    );

    ThumbnailService fakeThumbnails() => ThumbnailService(
      run: (_, args) async {
        await File(args.last).writeAsBytes(Uint8List.fromList([1, 2, 3]));
        return ProcessResult(1, 0, '', '');
      },
    );

    test('视觉镜头打标并发进行（串行时 32 个镜头要跑近十分钟）', () async {
      final repo = FileTaskRepository(tempDir);
      final task = makeTask().copyWith(
        shotTagGroups: [const TagGroupRef(id: 136, name: '画面类型')],
      );
      await repo.save(task);

      var inFlight = 0;
      var peak = 0;
      var calls = 0;

      // 用闸门而不是 sleep：靠「睡 5 毫秒」制造重叠，在机器负载高时会退化成
      // 一个接一个跑完，peak 变成 1，测试无缘无故地红。闸门在攒够 4 个在飞
      // 的调用时自己放行，因此并发是确定的；若实现退回串行，闸门永远攒不满，
      // 由兜底定时器放行，断言照常报「峰值恒为 1」而不是把测试挂死。
      const cap = 4;
      final gate = Completer<void>();
      void releaseIfSaturated() {
        if (!gate.isCompleted && inFlight >= cap) gate.complete();
      }

      unawaited(
        Future<void>.delayed(const Duration(seconds: 2), () {
          if (!gate.isCompleted) gate.complete();
        }),
      );

      await taggingPipeline(
        repo,
        shotTagger: _FakeShotTagger(
          onTag: () {
            calls++;
            inFlight++;
            if (inFlight > peak) peak = inFlight;
            releaseIfSaturated();
          },
          work: () async {
            await gate.future;
            inFlight--;
          },
        ),
        thumbnails: fakeThumbnails(),
        vocabulary: fakeSource({
          136: const ['开箱'],
        }),
      ).analyze(task);

      expect(calls, greaterThan(1), reason: '前提：确实跑了多个镜头的打标');
      expect(
        peak,
        greaterThan(1),
        reason:
            '串行打标下峰值并发恒为 1。真机实测单个镜头的视觉打标约 18 秒，'
            '32 个镜头串行就是近十分钟，用户只能对着「分析中」干等',
      );
      expect(peak, lessThanOrEqualTo(cap), reason: '云端 API 有并发与配额限制，不能无上限地打出去');
    });

    test('配置 taggers 后单元按本任务的单元标签组打标', () async {
      final repo = FileTaskRepository(tempDir);
      final task = makeTask().copyWith(
        unitTagGroups: [const TagGroupRef(id: 1279, name: '衣清.消毒液')],
      );
      await repo.save(task);
      final tagger = _RecordingUnitTagger(reply: const ['功效演示']);

      final result = await taggingPipeline(
        repo,
        unitTagger: tagger,
        vocabulary: fakeSource({
          1279: const ['功效演示', '价格机制'],
        }),
      ).analyze(task);

      expect(tagger.calls, result.units!.length);
      expect(result.units!.first.tags, ['功效演示']);
      expect(tagger.vocabularies.first, [
        '功效演示',
        '价格机制',
      ], reason: '词表必须来自本任务选的那个标签组');
      expect(asked, [1279]);
    });

    test('两个任务选了不同标签组时，各自拿到各自的词表', () async {
      final repo = FileTaskRepository(tempDir);
      final source = fakeSource({
        1279: const ['功效演示'],
        1281: const ['开箱'],
      });
      final tagger = _RecordingUnitTagger(reply: const []);
      final a = makeTask().copyWith(
        unitTagGroups: [const TagGroupRef(id: 1279, name: '衣清.消毒液')],
      );
      final b = RenewTask.fromJson(
        makeTask().toJson(),
      ).copyWith(unitTagGroups: [const TagGroupRef(id: 1281, name: '衣清.立白卫仕')]);
      await repo.save(a);

      await taggingPipeline(
        repo,
        unitTagger: tagger,
        vocabulary: source,
      ).analyze(a);
      final vocabA = tagger.vocabularies.last;
      await taggingPipeline(
        repo,
        unitTagger: tagger,
        vocabulary: source,
      ).analyze(b);

      expect(vocabA, ['功效演示']);
      expect(tagger.vocabularies.last, ['开箱']);
    });

    test('镜头层按视觉镜头标签组打标（抽帧 + 该组词表）', () async {
      final repo = FileTaskRepository(tempDir);
      final task = makeTask().copyWith(
        shotTagGroups: [const TagGroupRef(id: 136, name: '画面类型')],
      );
      await repo.save(task);
      var shotCalls = 0;

      final result = await taggingPipeline(
        repo,
        shotTagger: _FakeShotTagger(onTag: () => shotCalls++),
        thumbnails: fakeThumbnails(),
        vocabulary: fakeSource({
          136: const ['开箱'],
        }),
      ).analyze(task);

      final totalShots = result.units!.fold<int>(
        0,
        (n, u) => n + u.shots.length,
      );
      expect(shotCalls, totalShots);
      expect(result.units!.first.shots.first.tags, ['开箱']);
      expect(asked, [136]);
    });

    test('任务没选标签组时该层不打标，也不去拉词表（不许退回共用词表）', () async {
      final repo = FileTaskRepository(tempDir);
      final task = makeTask();
      await repo.save(task);
      final tagger = _RecordingUnitTagger(reply: const ['功效演示']);

      final result = await taggingPipeline(
        repo,
        unitTagger: tagger,
        vocabulary: fakeSource({
          1279: const ['功效演示'],
        }),
      ).analyze(task);

      expect(tagger.calls, 0);
      expect(asked, isEmpty);
      for (final u in result.units!) {
        expect(u.tags, isEmpty);
      }
    });

    test('拉词表失败不中断分析：该层留空并告警（不静默）', () async {
      final logs = <String>[];
      final previous = AppLog.sink;
      AppLog.sink = logs.add;
      addTearDown(() => AppLog.sink = previous);

      final repo = FileTaskRepository(tempDir);
      final task = makeTask().copyWith(
        unitTagGroups: [const TagGroupRef(id: 1279, name: '衣清.消毒液')],
      );
      await repo.save(task);

      final result = await taggingPipeline(
        repo,
        unitTagger: _RecordingUnitTagger(reply: const ['功效演示']),
        vocabulary: _ThrowingVocabularySource(),
      ).analyze(task);

      expect(result.status, RenewTaskStatus.ready);
      for (final u in result.units!) {
        expect(u.tags, isEmpty);
      }
      expect(logs.join(), contains('词表'));
    });

    test('标签组存在但组内没有标签时跳过打标并告警（空词表打标毫无意义）', () async {
      final logs = <String>[];
      final previous = AppLog.sink;
      AppLog.sink = logs.add;
      addTearDown(() => AppLog.sink = previous);

      final repo = FileTaskRepository(tempDir);
      final task = makeTask().copyWith(
        unitTagGroups: [const TagGroupRef(id: 1279, name: '空组')],
      );
      await repo.save(task);
      final tagger = _RecordingUnitTagger(reply: const ['功效演示']);

      await taggingPipeline(
        repo,
        unitTagger: tagger,
        vocabulary: fakeSource({1279: const []}),
      ).analyze(task);

      expect(tagger.calls, 0);
      expect(logs.join(), contains('空组'));
    });

    test('unitTagger 抛异常不中断分析，该单元 tags 留空', () async {
      final repo = FileTaskRepository(tempDir);
      final task = makeTask().copyWith(
        unitTagGroups: [const TagGroupRef(id: 1279, name: '衣清.消毒液')],
      );
      await repo.save(task);

      final result = await taggingPipeline(
        repo,
        unitTagger: _ThrowingUnitTagger(),
        vocabulary: fakeSource({
          1279: const ['功效演示'],
        }),
      ).analyze(task);

      expect(result.units, isNotNull);
      for (final u in result.units!) {
        expect(u.tags, isEmpty);
      }
    });
  });

  _multiGroupVocabulary();

  group('口播与背景音分离', () {
    test('分离出来的两条轨记在任务上，之后一直用', () async {
      final repo = FileTaskRepository(tempDir);
      final task = makeTask();
      await repo.save(task);

      final done = await makePipeline(
        repo,
        separator: fakeSeparator(),
      ).analyze(task);

      expect(done.vocalsPath, endsWith('-人声.wav'));
      expect(done.backgroundPath, endsWith('-背景.wav'));
      expect(File(done.vocalsPath!).existsSync(), isTrue);
    });

    test('分离失败不中断整条分析——切分与打标本身仍然有价值', () async {
      final repo = FileTaskRepository(tempDir);
      final task = makeTask();
      await repo.save(task);

      final done = await makePipeline(
        repo,
        separator: fakeSeparator(fail: true),
      ).analyze(task);

      expect(done.units, isNotNull, reason: '为了一条音轨把几分钟的分析废掉不划算');
      expect(done.vocalsPath, isNull, reason: '没成功就得是 null，不能给个不存在的路径');
    });

    test('没装分离工具时照常分析', () async {
      final repo = FileTaskRepository(tempDir);
      final task = makeTask();
      await repo.save(task);

      final done = await makePipeline(repo).analyze(task);

      expect(done.units, isNotNull);
      expect(done.vocalsPath, isNull);
    });
  });

  /// 人声轨**归任务所有**，两条任务之间不共用。
  ///
  /// 真机事故（2026-09-04）：项目 A 与项目 B 用的是同一条源片。A 先分析，
  /// 人声轨落在 A 名下；分析结果按**源文件内容**缓存，缓存里存着那条
  /// 绝对路径。后来 A 被删，软件按规矩清光 A 名下的文件——人声轨跟着走了。
  /// B 再打开时命中缓存，拿回一条指向空地址的路径，界面就一直喊
  /// 「没有分离出纯人声轨」，而且**怎么重新分析都好不了**：缓存命中就
  /// 直接返回，压根走不到分离那一步。
  ///
  /// 定下的规矩：项目 A 就是项目 A，项目 B 就是项目 B，谁删都不许影响对方。
  group('人声轨不跨任务共用', () {
    /// 造一条真实存在的源文件——[sourcePrintOf] 读不到文件就返回 null，
    /// 缓存那条路整个不会走，这个 bug 也就复现不出来（现有测试全用
    /// `/v/a.mp4` 这个不存在的路径，正是它让这条线一直没被测到）
    File makeSource() {
      final f = File('${tempDir.path}/同一条片子.mp4');
      f.writeAsBytesSync(List<int>.filled(4096, 7));
      return f;
    }

    test('删掉先分析那条任务的产物后，另一条任务仍有自己能用的人声轨', () async {
      final repo = FileTaskRepository(tempDir);
      final source = makeSource();

      final a = makeTask(id: '任务A', sourcePath: source.path);
      await repo.save(a);
      final doneA = await makePipeline(
        repo,
        separator: fakeSeparator(),
      ).analyze(a);
      expect(
        File(doneA.vocalsPath!).existsSync(),
        isTrue,
        reason: '前提：A 自己得先分离成功',
      );

      // 删掉任务 A——软件按规矩清光它名下的产物
      Directory('${tempDir.path}/work/stems/任务A').deleteSync(recursive: true);

      final b = makeTask(id: '任务B', sourcePath: source.path);
      await repo.save(b);
      final doneB = await makePipeline(
        repo,
        separator: fakeSeparator(),
      ).analyze(b);

      expect(doneB.vocalsPath, isNotNull, reason: 'B 有自己的人声轨，不该因为 A 被删就没了');
      expect(
        File(doneB.vocalsPath!).existsSync(),
        isTrue,
        reason: '存的路径必须真的有文件——指向空地址等于没有',
      );
      expect(doneB.vocalsPath, contains('任务B'), reason: '产物要落在 B 自己名下，不能借用别人的');
    });

    test('两条任务各分离各的，谁也不借用谁的产物', () async {
      final repo = FileTaskRepository(tempDir);
      final source = makeSource();
      final calls = <int>[];

      final a = makeTask(id: '任务A', sourcePath: source.path);
      await repo.save(a);
      final doneA = await makePipeline(
        repo,
        separator: fakeSeparator(calls: calls),
      ).analyze(a);

      final b = makeTask(id: '任务B', sourcePath: source.path);
      await repo.save(b);
      final doneB = await makePipeline(
        repo,
        separator: fakeSeparator(calls: calls),
      ).analyze(b);

      expect(calls, hasLength(2), reason: '各跑各的分离，不共用一份产物');
      expect(
        doneA.vocalsPath,
        isNot(doneB.vocalsPath),
        reason: '两条任务的人声轨必须是两个文件',
      );
      expect(File(doneA.vocalsPath!).existsSync(), isTrue);
      expect(File(doneB.vocalsPath!).existsSync(), isTrue);
    });

    test('单独重新分离：只补这条任务自己的人声轨，不重跑分析', () async {
      final repo = FileTaskRepository(tempDir);
      final source = makeSource();
      final calls = <int>[];
      final pipeline = makePipeline(
        repo,
        separator: fakeSeparator(calls: calls),
      );

      final a = makeTask(id: '任务A', sourcePath: source.path);
      await repo.save(a);
      final done = await pipeline.analyze(a);
      // 产物被清掉（别人删任务、或磁盘清理）
      Directory('${tempDir.path}/work/stems/任务A').deleteSync(recursive: true);
      expect(File(done.vocalsPath!).existsSync(), isFalse, reason: '前提：确实丢了');

      final stems = await pipeline.separateVocals(done);

      expect(stems, isNotNull);
      expect(File(stems!.vocalsPath).existsSync(), isTrue);
      expect(calls, hasLength(2), reason: '只多跑了一次分离');
    });

    test('空白任务没有原片，重新分离直接说没有——不许拿空路径去跑 ffmpeg', () async {
      final repo = FileTaskRepository(tempDir);
      final blank = RenewTask(
        id: '空白',
        name: '空白任务',
        status: RenewTaskStatus.ready,
        createdAt: DateTime.utc(2026, 7, 29),
        updatedAt: DateTime.utc(2026, 7, 29),
      );

      expect(
        await makePipeline(
          repo,
          separator: fakeSeparator(),
        ).separateVocals(blank),
        isNull,
      );
    });

    test('句子与切分照旧复用——省下的 ASR 与 LLM 不能一起赔掉', () async {
      final repo = FileTaskRepository(tempDir);
      final source = makeSource();

      final a = makeTask(id: '任务A', sourcePath: source.path);
      await repo.save(a);
      final doneA = await makePipeline(
        repo,
        separator: fakeSeparator(),
      ).analyze(a);

      final b = makeTask(id: '任务B', sourcePath: source.path);
      await repo.save(b);
      final doneB = await makePipeline(
        repo,
        separator: fakeSeparator(),
      ).analyze(b);

      // 同一条片子切出来的单元数必须一样——这正是按内容缓存要保住的东西
      expect(doneB.units!.length, doneA.units!.length);
      expect(doneB.units![0].endMs, doneA.units![0].endMs);
    });
  });
}

/// 假词表源：按组 id 给不同词表，并记录被问过的组 id
class _FakeVocabularySource implements TagVocabularySource {
  final Map<int, List<String>> byGroup;
  final List<int> asked;
  _FakeVocabularySource(this.byGroup, this.asked);

  @override
  Future<List<String>> vocabularyOf(int groupId) async {
    asked.add(groupId);
    return byGroup[groupId] ?? const [];
  }
}

class _ThrowingVocabularySource implements TagVocabularySource {
  @override
  Future<List<String>> vocabularyOf(int groupId) async =>
      throw StateError('拉词表失败（模拟）');
}

/// 记录每次调用与传入词表的假 UnitTagger
class _RecordingUnitTagger extends UnitTagger {
  final List<String> reply;
  final vocabularies = <List<String>>[];
  int calls = 0;

  _RecordingUnitTagger({required this.reply})
    : super(
        chat: ArkChatClient(
          apiKey: 'x',
          post: (_, _, _) async =>
              const JsonPostResult(statusCode: 200, body: '{}'),
        ),
      );

  @override
  Future<ShotUnderstanding> understand({
    required String transcript,
    required List<TagDimension> dimensions,
    String? constraint,
  }) async {
    calls++;
    vocabularies.add([for (final d in dimensions) ...d.vocabulary]);
    return ShotUnderstanding(tags: reply, rawReply: '{"tags":$reply}');
  }
}

class _ThrowingUnitTagger extends UnitTagger {
  _ThrowingUnitTagger()
    : super(
        chat: ArkChatClient(
          apiKey: 'x',
          post: (_, _, _) async =>
              const JsonPostResult(statusCode: 200, body: '{}'),
        ),
      );
  @override
  Future<ShotUnderstanding> understand({
    required String transcript,
    required List<TagDimension> dimensions,
    String? constraint,
  }) async {
    throw StateError('打标服务不可用');
  }
}

/// 视觉镜头打标的并发度：真机实测单个镜头的视觉打标约 18 秒，
/// 32 个镜头串行就是近十分钟，用户只能对着「分析中」干等。
class _FakeShotTagger extends ShotTagger {
  final void Function() onTag;
  final Future<void> Function()? work;
  _FakeShotTagger({required this.onTag, this.work})
    : super(
        chat: ArkChatClient(
          apiKey: 'x',
          post: (_, _, _) async =>
              const JsonPostResult(statusCode: 200, body: '{}'),
        ),
      );
  @override
  Future<ShotUnderstanding> understand({
    required List<List<int>> frames,
    required List<TagDimension> dimensions,
    String? constraint,
  }) async {
    onTag();
    if (work != null) await work!();
    return const ShotUnderstanding(tags: ['开箱'], description: '开箱画面');
  }
}

void _multiGroupVocabulary() {
  group('多个标签组的词表合并成一份', () {
    test('两个组的标签都进了受控词表，重复词只留一个', () async {
      final asked = <int>[];
      final source = _FakeVocabularySource({
        1: const ['真人口播', '产品特写'],
        2: const ['产品特写', '情绪激动'], // 与组 1 有重复
      }, asked);

      final merged = <String>[];
      for (final id in [1, 2]) {
        for (final w in await source.vocabularyOf(id)) {
          if (!merged.contains(w)) merged.add(w);
        }
      }

      expect(merged, ['真人口播', '产品特写', '情绪激动'], reason: '重复词只会稀释提示词，去重按标签名');
      expect(asked, [1, 2], reason: '每个选中的组都要拉一次');
    });
  });
}
