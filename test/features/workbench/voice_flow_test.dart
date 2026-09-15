import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:typed_data';

import 'package:ishkafel/core/analysis/audio_extractor.dart';
import 'package:ishkafel/core/analysis/providers.dart';
import 'package:ishkafel/core/audio/audio_preview.dart';
import 'package:ishkafel/core/audio/delivery_analyzer.dart';
import 'package:ishkafel/core/audio/prosody_profile.dart';
import 'package:ishkafel/core/audio/tts_client.dart';
import 'package:ishkafel/core/audio/voice_swap_service.dart';
import 'package:path/path.dart' as p;
import 'package:ishkafel/features/workbench/voice_swap_runner.dart';
import 'package:ishkafel/core/audio/voice_plan.dart';
import 'package:ishkafel/core/ffmpeg/thumbnail_service.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/models/video_info.dart';
import 'package:ishkafel/core/playback/playback_controller.dart';
import 'package:ishkafel/core/storage/task_repository.dart';
import 'package:ishkafel/features/tasks/task_list_controller.dart';
import 'package:ishkafel/features/workbench/timeline_media_builder.dart';
import 'package:ishkafel/features/workbench/workbench_page.dart';

class _Repo implements TaskRepository {
  final _store = <String, RenewTask>{};
  @override
  Future<List<RenewTask>> findAll() async => _store.values.toList();
  @override
  Future<RenewTask?> findById(String id) async => _store[id];
  @override
  Future<void> save(RenewTask task) async => _store[task.id] = task;
  @override
  Future<void> delete(String id) async => _store.remove(id);
}

TimelineMediaBuilder _fakeMediaBuilder() => TimelineMediaBuilder(
  thumbnails: ThumbnailService(
    run: (_, args) async {
      await File(args.last).writeAsBytes(List<int>.filled(600, 1));
      return ProcessResult(1, 0, '', '');
    },
  ),
  audio: AudioExtractor(
    run: (_, args) async {
      await File(args.last).writeAsBytes(List<int>.filled(64, 0));
      return ProcessResult(1, 0, '', '');
    },
  ),
);

RenewTask _task({VoicePlan voices = VoicePlan.empty}) => RenewTask(
  id: 'v-1',
  name: '滴露',
  sourcePath: '/v/a.mp4',
  status: RenewTaskStatus.ready,
  createdAt: DateTime.utc(2026, 8, 4),
  updatedAt: DateTime.utc(2026, 8, 4),
  voices: voices,
  units: const [
    SemanticUnit(
      uid: 'u0',
      index: 0,
      startMs: 0,
      endMs: 2000,
      transcript: '第一句',
      shots: [Shot(startMs: 0, endMs: 2000)],
    ),
    SemanticUnit(
      uid: 'u1',
      index: 1,
      startMs: 2000,
      endMs: 4000,
      transcript: '第二句',
      shots: [Shot(startMs: 2000, endMs: 4000)],
    ),
  ],
  videoInfo: const VideoInfo(
    width: 1080,
    height: 1920,
    duration: Duration(milliseconds: 4000),
    fps: 30,
    fileSizeBytes: 1,
  ),
);

/// 假的换音色服务：不碰云端，直接产出几个字节，让流程能被端到端验证
class _FakeSwap extends VoiceSwapService {
  final Set<String> failOn;
  final progress = <(int, int)>[];

  _FakeSwap({this.failOn = const {}})
    : super(
        tts: const TtsClient(appId: 'a', accessToken: 'b'),
        analyzer: _FakeAnalyzer(),
        sliceOriginal: (_, _) async => const [],
        measureMs: (_) async => 0,
      );

  @override
  Future<Map<String, VoiceSwapResult>> run({
    required List<SemanticUnit> units,
    required List<AsrSentence> sentences,
    required VoicePlan plan,
    void Function(int done, int total)? onProgress,
  }) async {
    failures.clear();
    final targets = plan.assignedUnits;
    final out = <String, VoiceSwapResult>{};
    for (final i in targets) {
      if (failOn.contains(i)) {
        failures[i] = '合成超时';
      } else {
        out[i] = VoiceSwapResult(
          audio: Uint8List.fromList([1, 2, 3]),
          analysis: const DeliveryAnalysis(description: '', instruction: ''),
          synthesizedMs: 2000,
          targetMs: 2000,
        );
      }
      onProgress?.call(out.length + failures.length, targets.length);
      progress.add((out.length + failures.length, targets.length));
    }
    return out;
  }
}

class _FakeAnalyzer implements DeliveryAnalyzer {
  @override
  Future<DeliveryAnalysis> analyze({
    required List<int> audioWav,
    required String transcript,
    ProsodyProfile? prosody,
  }) async => const DeliveryAnalysis(description: '', instruction: '');
}

class _FakePreview extends AudioPreview {
  final played = <String>[];
  @override
  Future<void> play(String path) async => played.add(path);
  @override
  Future<void> dispose() async {}
}

Future<_Repo> _open(
  WidgetTester tester, {
  VoicePlan voices = VoicePlan.empty,
}) async {
  final repo = _Repo();
  final task = _task(voices: voices);
  await repo.save(task);
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [taskRepositoryProvider.overrideWithValue(repo)],
      child: MaterialApp(
        home: WorkbenchPage(
          task: task,
          playbackFactory: FakePlaybackController.new,
          mediaBuilder: _fakeMediaBuilder(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

void main() {
  testWidgets('选中一个单元 → 换音色 → 落库', (tester) async {
    final repo = await _open(tester);

    await tester.tap(find.byKey(const Key('unit-row-0')));
    await tester.pumpAndSettle();
    expect(
      find.text('保持原片配音'),
      findsOneWidget,
      reason: '没换的时候要写出来，留空用户分不清是没换还是功能没生效',
    );

    await tester.tap(find.byKey(const Key('inspector-change-voice')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('voice-unit-1')));
    await tester.pump();
    await tester.tap(
      find.byKey(const Key('voice-option-zh_female_vv_uranus_bigtts')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('voice-confirm')));
    await tester.pumpAndSettle();

    final saved = await repo.findById('v-1');
    expect(saved!.voices.assignedUnits, {'u0', 'u1'}, reason: '面板里勾了两句，就该两句都换');
    expect(saved.voices.voiceOf('u0')!.name, 'vivi 2.0');
    expect(
      find.textContaining('vivi 2.0'),
      findsWidgets,
      reason: '检查器上要立刻反映出来',
    );
    expect(
      find.text('vivi 2.0（待生成）'),
      findsOneWidget,
      reason: '只选了音色还没跑，导出时不会有新声音——这两件事要分清',
    );
  });

  testWidgets('改回原声后卡片写回「保持原片配音」', (tester) async {
    const vivi = VoiceRef(id: 'zh_female_vv_uranus_bigtts', name: 'vivi 2.0');
    final repo = await _open(
      tester,
      voices: VoicePlan.empty.assign(['u0'], vivi),
    );

    await tester.tap(find.byKey(const Key('unit-row-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('inspector-change-voice')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('voice-revert')));
    await tester.pumpAndSettle();

    final saved = await repo.findById('v-1');
    expect(saved!.voices.voiceOf('u0'), isNull);
    expect(find.text('保持原片配音'), findsOneWidget);
  });

  group('生成配音', () {
    const vivi = VoiceRef(id: 'zh_female_vv_uranus_bigtts', name: 'vivi 2.0');

    /// 打开一个已经选好音色的工作台，注入假服务与假试听
    Future<(_FakeSwap, _FakePreview, Directory)> openWithSwap(
      WidgetTester tester, {
      Set<String> failOn = const {},
    }) async {
      final repo = _Repo();
      final task = _task(voices: VoicePlan.empty.assign(['u0'], vivi));
      await repo.save(task);
      final dir = Directory.systemTemp.createTempSync('ishkafel_voice_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final swap = _FakeSwap(failOn: failOn);
      final preview = _FakePreview();

      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [taskRepositoryProvider.overrideWithValue(repo)],
          child: MaterialApp(
            home: WorkbenchPage(
              task: task,
              playbackFactory: FakePlaybackController.new,
              mediaBuilder: _fakeMediaBuilder(),
              audioPreview: preview,
              voiceSwapFactory: (_) =>
                  VoiceSwapJob(service: swap, outputDir: dir),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return (swap, preview, dir);
    }

    testWidgets('点一下就跑完，产物落盘且能试听', (tester) async {
      final (swap, preview, dir) = await openWithSwap(tester);

      expect(
        find.byKey(const Key('workbench-generate-voices-btn')),
        findsOneWidget,
        reason: '选了音色就该有生成入口',
      );

      await tester.tap(find.byKey(const Key('workbench-generate-voices-btn')));
      await tester.pumpAndSettle();

      expect(swap.progress, isNotEmpty, reason: '按钮要真的把服务跑起来');
      // 产物按单元的**身份**命名（见 VoiceSwapJob.audioFor）：写下标的话，
      // 人挪一次单元，取到的就是别人的配音
      final file = File(p.join(dir.path, 'unit_u0.mp3'));
      expect(file.existsSync(), isTrue, reason: '只留在内存里的话，关掉页面这一轮几十秒就白跑了');
      expect(file.readAsBytesSync(), [1, 2, 3]);

      await tester.tap(find.byKey(const Key('unit-row-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('inspector-preview-voice')));
      await tester.pumpAndSettle();

      expect(preview.played, [file.path]);
      expect(find.text('vivi 2.0'), findsWidgets, reason: '生成完就不该再写「待生成」');
    });

    testWidgets('没生成过的单元不给试听按钮——点了没声音比没有还糟', (tester) async {
      await openWithSwap(tester);

      await tester.tap(find.byKey(const Key('unit-row-0')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('inspector-preview-voice')), findsNothing);
    });

    testWidgets('失败的那几句要点名，用户才知道去补哪几句', (tester) async {
      await openWithSwap(tester, failOn: {'u0'});

      await tester.tap(find.byKey(const Key('workbench-generate-voices-btn')));
      await tester.pumpAndSettle();

      // 只找提示条上的那一句：'U1' 在左栏单元列表里也会出现
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.textContaining('U1 失败'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('一句都没换音色时不显示生成入口', (tester) async {
      await _open(tester);

      expect(
        find.byKey(const Key('workbench-generate-voices-btn')),
        findsNothing,
      );
    });
  });
}
