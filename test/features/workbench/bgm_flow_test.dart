import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/audio_extractor.dart';
import 'package:ishkafel/core/audio/bgm_library.dart';
import 'package:ishkafel/core/audio/bgm_plan.dart';
import 'package:ishkafel/core/ffmpeg/thumbnail_service.dart';
import 'package:ishkafel/core/ffmpeg/process_runner.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/models/video_info.dart';
import 'package:ishkafel/core/playback/playback_controller.dart';
import 'package:ishkafel/core/storage/task_repository.dart';
import 'package:ishkafel/features/tasks/task_list_controller.dart';
import 'package:ishkafel/features/workbench/bgm_picker_sheet.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_hit_tester.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_painter.dart';
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

class _Library implements BgmLibrary {
  @override
  Future<BgmSearchPage> search({
    String? keyword,
    List<int> projectIds = const [],
    int page = 1,
    int pageSize = 30,
  }) async => const BgmSearchPage(items: [
        BgmMaterial(id: 1, name: '轻快垫乐', durationMs: 30000, previewUrl: null),
      ]);

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FailingLibrary implements BgmLibrary {
  @override
  Future<BgmSearchPage> search({
    String? keyword,
    List<int> projectIds = const [],
    int page = 1,
    int pageSize = 30,
  }) => Future.error(const MediaToolMissingException(
        'miaoa',
        operatingSystem: 'windows',
      ));

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

TimelineMediaBuilder _fakeMediaBuilder() => TimelineMediaBuilder(
      thumbnails: ThumbnailService(run: (_, args) async {
        await File(args.last).writeAsBytes(List<int>.filled(600, 1));
        return ProcessResult(1, 0, '', '');
      }),
      audio: AudioExtractor(run: (_, args) async {
        await File(args.last).writeAsBytes(List<int>.filled(64, 0));
        return ProcessResult(1, 0, '', '');
      }),
    );

/// 两个单元共 3 个镜头：U1(S1 0-2000, S2 2000-5000)、U2(S1 5000-10000)
RenewTask _task({BgmPlan bgm = BgmPlan.empty}) => RenewTask(
      id: 'bgm-1',
      name: '滴露',
      sourcePath: '/v/a.mp4',
      status: RenewTaskStatus.ready,
      createdAt: DateTime.utc(2026, 8, 4),
      updatedAt: DateTime.utc(2026, 8, 4),
      bgm: bgm,
      units: const [
        SemanticUnit(
          index: 0,
          startMs: 0,
          endMs: 5000,
          transcript: '前半段',
          shots: [
            Shot(startMs: 0, endMs: 2000),
            Shot(startMs: 2000, endMs: 5000),
          ],
        ),
        SemanticUnit(
          index: 1,
          startMs: 5000,
          endMs: 10000,
          transcript: '后半段',
          shots: [Shot(startMs: 5000, endMs: 10000)],
        ),
      ],
      videoInfo: const VideoInfo(
        width: 1080,
        height: 1920,
        duration: Duration(milliseconds: 10000),
        fps: 30,
        fileSizeBytes: 1,
      ),
    );

Future<_Repo> _open(WidgetTester tester,
    {BgmPlan bgm = BgmPlan.empty, BgmLibrary? library}) async {
  final repo = _Repo();
  final task = _task(bgm: bgm);
  await repo.save(task);
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(ProviderScope(
    overrides: [
      taskRepositoryProvider.overrideWithValue(repo),
      bgmLibraryProvider.overrideWithValue(library ?? _Library()),
    ],
    child: MaterialApp(
      home: WorkbenchPage(
        task: task,
        playbackFactory: FakePlaybackController.new,
        mediaBuilder: _fakeMediaBuilder(),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return repo;
}

/// 轨道坐标是相对**画布**的，不是相对 TimelineView（它上面还套着别的层）
Finder get _canvas => find.byWidgetPredicate(
    (w) => w is CustomPaint && w.painter is TimelinePainter);

Offset _onBgmTrack(WidgetTester tester, double x) {
  final origin = tester.getTopLeft(_canvas);
  return Offset(origin.dx + x,
      origin.dy + TimelineTracks.bgmTop + TimelineTracks.bgmH / 2);
}

/// 在配乐轨上从 [fromX] 拖到 [toX]（相对画布左边缘）
Future<void> _dragOnBgmTrack(
    WidgetTester tester, double fromX, double toX) async {
  await tester.dragFrom(
      _onBgmTrack(tester, fromX), Offset(toX - fromX, 0));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('音频库失败只显示人话，不把异常类名摊给用户', (tester) async {
    await _open(tester, library: _FailingLibrary());

    await _dragOnBgmTrack(tester, 10, 400);
    await tester.pumpAndSettle();

    expect(find.textContaining('未找到 miaoa 命令行工具'), findsOneWidget);
    expect(find.textContaining('MediaToolMissingException'), findsNothing);
  });

  testWidgets('框选一段镜头 → 挑一首 → 落库', (tester) async {
    final repo = await _open(tester);

    await _dragOnBgmTrack(tester, 10, 400);
    await tester.pumpAndSettle();

    expect(find.text('轻快垫乐'), findsOneWidget, reason: '前提：选择面板弹出来了');
    // 一段可以选多首（互为备选），所以点一条只是勾上，要再点「确定」
    await tester.tap(find.byKey(const Key('bgm-item-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('bgm-confirm')));
    await tester.pumpAndSettle();

    final saved = await repo.findById('bgm-1');
    expect(saved!.bgm.segments, hasLength(1));
    expect(saved.bgm.segments.single.previewMaterial.name, '轻快垫乐');
    expect(saved.bgm.segments.single.startUnit, 0);
  });

  testWidgets('点已有的一段可以移除', (tester) async {
    final repo = await _open(
      tester,
      bgm: const BgmPlan([
        BgmSegment(
          startUnit: 0,
          endUnit: 1,
          materials: [BgmMaterial(
              id: 1, name: '轻快垫乐', durationMs: 30000, previewUrl: null)],
          fit: BgmFit.cut,
        ),
      ]),
    );

    await tester.tapAt(_onBgmTrack(tester, 20));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('bgm-clear')));
    await tester.pumpAndSettle();

    final saved = await repo.findById('bgm-1');
    expect(saved!.bgm.segments, isEmpty);
  });
}
