import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ishkafel/core/ffmpeg/media_spec.dart';
import 'package:ishkafel/core/ffmpeg/proxy_spec.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/models/video_info.dart';
import 'package:ishkafel/core/playback/follower_track.dart';
import 'package:ishkafel/core/playback/multitrack_playback.dart';
import 'package:ishkafel/core/playback/playback_controller.dart';
import 'package:ishkafel/core/playback/preview_normalizer.dart';
import 'package:ishkafel/core/playback/track_plan.dart';
import 'package:ishkafel/features/workbench/preview_tracks.dart';
import 'package:ishkafel/features/workbench/workbench_page.dart';
import 'package:ishkafel/features/tasks/task_list_controller.dart';
import 'workbench_page_test.dart' show InMemoryTaskRepository;

class _Audio implements FollowerTrack {
  String? loaded;
  @override
  Future<bool> load(String? path) async {
    final changed = loaded != path;
    loaded = path;
    return changed;
  }

  @override
  int get positionMs => 0;
  @override
  Future<void> dispose() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> seekMs(int ms) async {}
  @override
  Future<void> setRate(double rate) async {}
  @override
  Future<void> setVolume(double volume) async {}
}

class _FailOnceVideo extends FakePlaybackController {
  int attempts = 0;
  @override
  Future<void> open(String path) async {
    attempts++;
    if (attempts == 1) throw StateError('模拟视频打开失败');
    await super.open(path);
  }
}

class _QueuedVideo extends FakePlaybackController {
  final started = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> open(String path) async {
    if (path.contains('/a.mp4')) {
      started.complete();
      await release.future;
    }
    if (path.contains('/c.mp4')) throw StateError('最后一版加载失败');
    await super.open(path);
  }
}

class _ErrorVideo extends FakePlaybackController
    implements PlaybackErrorSource {
  final errors = StreamController<String>.broadcast(sync: true);
  @override
  Stream<String> get playbackErrors => errors.stream;
  @override
  Future<void> dispose() async {
    await errors.close();
    await super.dispose();
  }
}

final _units = [
  const SemanticUnit(
    uid: 'u1',
    index: 0,
    startMs: 0,
    endMs: 4000,
    transcript: '测试',
    shots: [Shot(startMs: 0, endMs: 4000)],
  ),
];

RenewTask _task(String path) => RenewTask(
  id: 'preview-test',
  name: '预览回归',
  sourcePath: path,
  status: RenewTaskStatus.ready,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  units: _units,
  videoInfo: const VideoInfo(width: 720, height: 1280, duration: Duration(seconds: 4), fps: 30, fileSizeBytes: 1000),
);

Future<void> _update(PreviewTracks tracks, String path) =>
    tracks.update(task: _task(path), units: _units, voiceAudio: const {});

void main() {
  testWidgets('工作台多轨预览只由轨道计划打开，不能并行打开裸原片', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1600, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final video = FakePlaybackController();
    final playback = MultitrackPlayback(video: video, voice: _Audio(), bgm: _Audio());
    final repo = InMemoryTaskRepository();
    final task = _task('/a.mp4');
    await repo.save(task);
    await tester.pumpWidget(ProviderScope(
      overrides: [taskRepositoryProvider.overrideWithValue(repo)],
      child: MaterialApp(home: WorkbenchPage(task: task, playbackFactory: () => playback)),
    ));
    await tester.pumpAndSettle();
    expect(video.calls.where((c) => c.startsWith('open(')), hasLength(1));
    expect(video.calls, isNot(contains('open(/a.mp4)')));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
  test('打开完成后才收到播放器错误也能让同源重试重新打开', () async {
    final video = _ErrorVideo();
    final playback = MultitrackPlayback(
      video: video,
      voice: _Audio(),
      bgm: _Audio(),
    );
    final tracks = PreviewTracks(
      playback: playback,
      normalizer: PreviewNormalizer.passthrough(),
    );
    addTearDown(() async {
      tracks.dispose();
      await playback.dispose();
    });
    await _update(tracks, '/a.mp4');
    video.errors.add('模拟异步解码失败');
    await Future<void>.delayed(Duration.zero);
    expect(tracks.notice, contains('失败'));
    expect(tracks.noticeRetryable, isTrue);
    await _update(tracks, '/a.mp4');
    expect(video.calls.where((c) => c.startsWith('open(')), hasLength(2));
    expect(tracks.notice, isNull);
  });
  test('合并队列时最后一版的失败必须返回最后一个请求', () async {
    final video = _QueuedVideo();
    final playback = MultitrackPlayback(
      video: video,
      voice: _Audio(),
      bgm: _Audio(),
    );
    addTearDown(playback.dispose);
    Future<NormalizedTrackPlan> plan(String path) =>
        PreviewNormalizer.passthrough().normalize(
          TrackPlan(
            video: [TrackSegment(atMs: 0, durationMs: 4000, source: path)],
          ),
        );
    final a = playback.setPlan(await plan('/a.mp4'));
    await video.started.future;
    final b = playback.setPlan(await plan('/b.mp4'));
    final c = playback.setPlan(await plan('/c.mp4'));
    final bResult = b.then((_) => true, onError: (_) => false);
    final cResult = c.then((_) => true, onError: (_) => false);
    video.release.complete();
    await a;
    expect(await cResult, isFalse, reason: 'C 不能假成功并被上层缓存');
    expect(await bResult, isTrue, reason: '被跳过的 B 不负责 C 的错误');
  });
  test('视频打开失败后同一 EDL 必须重新打开，不能缓存成成功', () async {
    final video = _FailOnceVideo();
    final playback = MultitrackPlayback(
      video: video,
      voice: _Audio(),
      bgm: _Audio(),
    );
    addTearDown(playback.dispose);
    final plan = await PreviewNormalizer.passthrough().normalize(
      const TrackPlan(
        video: [TrackSegment(atMs: 0, durationMs: 4000, source: '/a.mp4')],
      ),
    );
    await expectLater(playback.setPlan(plan), throwsStateError);
    await playback.setPlan(plan);
    expect(video.attempts, 2);
    expect(video.calls.where((c) => c.startsWith('open(')), hasLength(1));
  });

  test('预览失败可见且相同方案能重试，无需选择再取消替换素材', () async {
    final video = _FailOnceVideo();
    final playback = MultitrackPlayback(
      video: video,
      voice: _Audio(),
      bgm: _Audio(),
    );
    final tracks = PreviewTracks(
      playback: playback,
      normalizer: PreviewNormalizer.passthrough(),
    );
    addTearDown(() async {
      tracks.dispose();
      await playback.dispose();
    });
    await _update(tracks, '/a.mp4');
    expect(tracks.notice, contains('失败'));
    expect(tracks.noticeRetryable, isTrue);
    await _update(tracks, '/a.mp4');
    expect(video.attempts, 2);
    expect(tracks.notice, isNull);
    await _update(tracks, '/a.mp4');
    expect(video.attempts, 2, reason: '真正成功后仍须去重，不能反复黑闪');
  });

  test('先发后到的旧规格化结果不得覆盖新方案', () async {
    final started = Completer<void>();
    final old = Completer<MediaSpec?>();
    final playback = MultitrackPlayback(
      video: FakePlaybackController(),
      voice: _Audio(),
      bgm: _Audio(),
    );
    final tracks = PreviewTracks(
      playback: playback,
      normalizer: PreviewNormalizer(
        probe: (path) async {
          if (path == '/old.mp4') {
            started.complete();
            return old.future;
          }
          return ProxySpec.at('30');
        },
        toProxy: (path) async => path,
      ),
    );
    addTearDown(() async {
      tracks.dispose();
      await playback.dispose();
    });
    final first = _update(tracks, '/old.mp4');
    await started.future;
    await _update(tracks, '/new.mp4');
    old.complete(ProxySpec.at('30'));
    await first;
    expect(playback.plan.video.single.source, '/new.mp4');
    expect(tracks.plan.video.single.source, '/new.mp4');
  });

  test('离开工作台后规格化完成不得再加载已销毁播放器', () async {
    final started = Completer<void>();
    final ready = Completer<MediaSpec?>();
    final video = FakePlaybackController();
    final playback = MultitrackPlayback(
      video: video,
      voice: _Audio(),
      bgm: _Audio(),
    );
    final tracks = PreviewTracks(
      playback: playback,
      normalizer: PreviewNormalizer(
        probe: (_) {
          started.complete();
          return ready.future;
        },
        toProxy: (path) async => path,
      ),
    );
    final pending = _update(tracks, '/a.mp4');
    await started.future;
    tracks.dispose();
    ready.complete(ProxySpec.at('30'));
    await pending;
    expect(video.calls.where((c) => c.startsWith('open(')), isEmpty);
    await playback.dispose();
  });
}
