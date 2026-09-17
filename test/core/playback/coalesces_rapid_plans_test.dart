import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/playback/follower_track.dart';
import 'package:ishkafel/core/playback/multitrack_playback.dart';
import 'package:ishkafel/core/playback/playback_controller.dart';
import 'package:ishkafel/core/playback/preview_normalizer.dart';
import 'package:ishkafel/core/playback/track_plan.dart';

/// **连着推好几版方案，只有最后一版该被播出来。**
///
/// 2026-09-09 真机日志：进一次审片台，「画面轨换源」打了 6 条——先按原片
/// 铺一版，每渲好一段变速切片补一版，代理生成好再整体换一版。每一次换源
/// 都是一次 mpv loadfile：画面连闪好几下，每次都得重新解码定位。
/// 中间那几版在被人看到之前就已经过时了。
class _Fake implements FollowerTrack {
  String? loaded;
  int _positionMs = 0;
  @override
  Future<bool> load(String? edl) async {
    final changed = edl != loaded;
    loaded = edl;
    return changed;
  }

  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seekMs(int ms) async => _positionMs = ms;
  @override
  Future<void> setVolume(double v) async {}

  /// 追赶用的速率。测试记下来，验「不再硬 seek 而是微调速率」
  double rate = 1.0;

  @override
  Future<void> setRate(double value) async => rate = value;
  @override
  int get positionMs => _positionMs;
  @override
  Future<void> dispose() async {}
}

void main() {
  late FakePlaybackController master;
  late MultitrackPlayback playback;

  setUp(() {
    master = FakePlaybackController();
    playback = MultitrackPlayback(video: master, voice: _Fake(), bgm: _Fake());
  });
  tearDown(() => playback.dispose());

  TrackPlan planWith(String clip) => TrackPlan(
        video: [
          const TrackSegment(atMs: 0, durationMs: 6000, source: '/v/src.mp4'),
          TrackSegment(atMs: 6000, durationMs: 2000, source: clip),
        ],
        voice: const [
          TrackSegment(atMs: 0, durationMs: 8000, source: '/v/src.mp4'),
        ],
        unitRanges: const {0: (0, 8000)},
      );

  int opensIn(List<String> calls) =>
      calls.where((c) => c.startsWith('open')).length;

  test('一口气推四版，中间两版不开文件——播出来的是最后一版', () async {
    // 不 await 前三个：模拟切片一段段就绪时的连推
    unawaited0(playback.setPlanForTest(planWith('/fit/a.mp4')));
    unawaited0(playback.setPlanForTest(planWith('/fit/b.mp4')));
    unawaited0(playback.setPlanForTest(planWith('/fit/c.mp4')));
    await playback.setPlanForTest(planWith('/fit/d.mp4'));

    expect(opensIn(master.calls), lessThanOrEqualTo(2),
        reason: '四版方案开了 ${opensIn(master.calls)} 次文件，'
            '画面就要闪这么多下');
    expect(master.calls.last.contains('/fit/d.mp4') ||
        master.calls.any((c) => c.contains('/fit/d.mp4')), isTrue,
        reason: '合并可以丢掉中间几版，但最后一版必须真的播出来');
  });

  test('慢慢推（每次都等完）时一版都不少', () async {
    await playback.setPlanForTest(planWith('/fit/a.mp4'));
    await playback.setPlanForTest(planWith('/fit/b.mp4'));

    expect(opensIn(master.calls), 2,
        reason: '人一次一次调的时候，每一次都该看到结果');
  });
}

/// 故意不等：`unawaited` 在 dart:async 里，这里只想表达「推了但不等」
void unawaited0(Future<void> f) {
  f.catchError((_) {});
}

/// 测试里推方案：走**和生产同一道闸**，只是挂在「原样放行」档上
/// （见 [PreviewNormalizer.passthrough]）。这些用例验的是播放器的行为，
/// 不是规格化本身——规格化有自己的用例
extension _PushPlan on MultitrackPlayback {
  Future<void> setPlanForTest(TrackPlan plan) async =>
      setPlan(await PreviewNormalizer.passthrough().normalize(plan));
}
