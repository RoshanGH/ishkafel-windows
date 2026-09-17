import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/playback/follower_track.dart';
import 'package:ishkafel/core/playback/multitrack_playback.dart';
import 'package:ishkafel/core/playback/playback_controller.dart';
import 'package:ishkafel/core/playback/preview_normalizer.dart';
import 'package:ishkafel/core/playback/track_plan.dart';

/// **换一段切片，人正看着的那一帧不能丢。**
///
/// 2026-09-09 真机：调字幕样式做成了「边调边看」，结果一动滑杆播放头就跳回
/// 片头——人正对着第 10.2 秒那一镜调字幕位置，一拖就被扔回 00:00，
/// 等于还是看不到自己在调什么。
///
/// 换源之后播放器的位置必然归零（重开了一个文件），所以 [MultitrackPlayback]
/// 换源前会记下**逻辑位置**（哪个单元、单元内偏移），换完再还原回去。
/// 这条线钉的就是这件事：只有切片路径变了（重烧了字幕）时，位置必须留在原处。
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

  /// 两个单元：U1 0~8000、U2 8000~16000。第二镜是重烧字幕的那一段
  TrackPlan planWith(String secondClip) => TrackPlan(
        video: [
          const TrackSegment(atMs: 0, durationMs: 6000, source: '/v/src.mp4'),
          TrackSegment(atMs: 6000, durationMs: 2000, source: secondClip),
          const TrackSegment(atMs: 8000, durationMs: 8000, source: '/v/src.mp4'),
        ],
        voice: const [
          TrackSegment(atMs: 0, durationMs: 16000, source: '/v/src.mp4'),
        ],
        unitRanges: const {0: (0, 8000), 1: (8000, 16000)},
      );

  test('只是重烧了字幕：人看的那一刻留在原处', () async {
    await playback.setPlanForTest(planWith('/fit/old.mp4'));
    master.emitPosition(6800); // 人停在第二镜上调字幕
    await Future<void>.delayed(const Duration(milliseconds: 10));

    await playback.setPlanForTest(planWith('/fit/new.mp4'));

    expect(master.positionMs, 6800,
        reason: '跳回片头的话，人正对着调的那一帧就没了——'
            '「边调边看」当场变成看不到');
  });

  /// 2026-09-09 真机上这条才是真凶：还原的 seek 确实发出去了，只是
  /// **播放器还在 loadfile，把它整个吞掉了**。代码里早有一条注释写着同一
  /// 件事（「参考弹窗每个分镜都从头播就是这么来的」），只是换方案这条路
  /// 没等。
  test('换源之后要等文件真加载完再跳——不等的话那一下会被吞掉', () async {
    await playback.setPlanForTest(planWith('/fit/old.mp4'));
    master.emitPosition(6800);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    master.calls.clear();

    await playback.setPlanForTest(planWith('/fit/new.mp4'));

    final waited = master.calls.indexOf('waitUntilLoaded');
    final sought = master.calls.indexWhere((c) => c.startsWith('seek'));
    expect(waited, isNot(-1), reason: '不等就跳，跳了也白跳');
    expect(waited, lessThan(sought), reason: '要先等加载完，再跳');
  });

  test('片长没变时是原样搬过去，不是按比例挪一点', () async {
    await playback.setPlanForTest(planWith('/fit/old.mp4'));
    master.emitPosition(12345);
    await Future<void>.delayed(const Duration(milliseconds: 10));

    await playback.setPlanForTest(planWith('/fit/new.mp4'));

    expect(master.positionMs, 12345);
  });
}

/// 测试里推方案：走**和生产同一道闸**，只是挂在「原样放行」档上
/// （见 [PreviewNormalizer.passthrough]）。这些用例验的是播放器的行为，
/// 不是规格化本身——规格化有自己的用例
extension _PushPlan on MultitrackPlayback {
  Future<void> setPlanForTest(TrackPlan plan) async =>
      setPlan(await PreviewNormalizer.passthrough().normalize(plan));
}
