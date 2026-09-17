
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/playback/follower_track.dart';
import 'package:ishkafel/core/playback/multitrack_playback.dart';
import 'package:ishkafel/core/playback/playback_controller.dart';
import 'package:ishkafel/core/playback/preview_normalizer.dart';
import 'package:ishkafel/core/playback/track_plan.dart';

/// 记录所有命令的假跟随轨
class _Fake implements FollowerTrack {
  final List<String> calls = [];
  String? loaded;
  int _positionMs = 0;
  double volume = 1;

  /// 让测试可以伪造「漂了」
  void pretendAt(int ms) => _positionMs = ms;

  @override
  Future<bool> load(String? edl) async {
    final changed = edl != loaded;
    loaded = edl;
    calls.add('load:$edl');
    return changed;
  }

  @override
  Future<void> play() async => calls.add('play');

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> seekMs(int ms) async {
    _positionMs = ms;
    calls.add('seek:$ms');
  }

  @override
  Future<void> setVolume(double v) async {
    volume = v;
    calls.add('volume:$v');
  }

  /// 追赶用的速率。测试记下来，验「不再硬 seek 而是微调速率」
  double rate = 1.0;

  @override
  Future<void> setRate(double value) async {
    rate = value;
    calls.add('rate:${value.toStringAsFixed(3)}');
  }

  @override
  int get positionMs => _positionMs;

  @override
  Future<void> dispose() async => calls.add('dispose');
}

TrackPlan _planWithBgm() => const TrackPlan(
      video: [TrackSegment(atMs: 0, durationMs: 10000, source: '/v/a.mp4')],
      voice: [TrackSegment(atMs: 0, durationMs: 10000, source: '/v/a.mp4')],
      bgm: [
        BgmTrackSegment(
          clip: TrackSegment(atMs: 4000, durationMs: 6000, source: '/b/1.mp3'),
          volume: 0.25,
          sourceDurationMs: 2000,
        ),
      ],
    );

void main() {
  _emptyVideoTrack();
  _switchBehaviour();
  group('跟随轨纠偏：只在真漂了的时候动手', () {
    test('抖动幅度内不纠——每次 seek 都是一次可闻的接缝', () {
      // 真机实测偏差在 ±70ms 之间来回抖，不是漂移
      expect(needsResync(masterMs: 5000, followerMs: 5070), isFalse);
      expect(needsResync(masterMs: 5000, followerMs: 4930), isFalse);
    });

    test('超出容许值才纠', () {
      expect(needsResync(masterMs: 5000, followerMs: 5200), isTrue);
      expect(needsResync(masterMs: 5000, followerMs: 4800), isTrue);
    });

    test('还没加载的轨不纠——它的 0 不是「漂到片头」', () {
      expect(needsResync(masterMs: 5000, followerMs: null), isFalse);
    });

    test('容许值比实测抖动留出余量', () {
      expect(syncToleranceMs, greaterThan(70),
          reason: '取得比抖动幅度还小的话，会被抖动骗着反复 seek');
    });
  });

  group('配乐按范围启停', () {
    test('没进范围时静音', () {
      expect(bgmCueAt(_planWithBgm(), 0), BgmCue.silent);
      expect(bgmCueAt(_planWithBgm(), 3999).source, isNull);
    });

    test('进了范围就播这首曲子的对应位置，带这一段自己的音量', () {
      final cue = bgmCueAt(_planWithBgm(), 4500);

      expect(cue.source, '/b/1.mp3');
      expect(cue.inMs, 500);
      expect(cue.volume, 0.25);
    });

    test('曲子比这一段短就绕回开头——「时长不够就循环」', () {
      // 曲子 2 秒，段落 6 秒；走到段内第 2.5 秒时该播曲子的第 0.5 秒
      expect(bgmCueAt(_planWithBgm(), 6500).inMs, 500);
      expect(bgmCueAt(_planWithBgm(), 8000).inMs, 0);
    });

    test('走出范围就停——「太长就播到段尾停」', () {
      expect(bgmCueAt(_planWithBgm(), 10000).source, isNull);
    });

    test('不知道曲长时不取模，播完即止', () {
      const plan = TrackPlan(bgm: [
        BgmTrackSegment(
          clip: TrackSegment(atMs: 0, durationMs: 6000, source: '/b/1.mp3'),
          volume: 1,
        ),
      ]);

      expect(bgmCueAt(plan, 5000).inMs, 5000);
    });
  });

  group('假跟随轨自身的行为（给上层用例做基准）', () {
    test('seek 之后位置就是 seek 到的那个值', () async {
      final fake = _Fake();
      await fake.seekMs(4200);

      expect(fake.positionMs, 4200);
      expect(fake.calls, ['seek:4200']);
    });

    test('音量夹在 0~1', () async {
      final fake = _Fake();
      await fake.setVolume(0.25);

      expect(fake.volume, 0.25);
    });
  });

  group('换方案时的切换行为（用户点 ★ / 取消勾选走的就是这里）', () {
    /// 三条必须守住的规矩，每一条都是「不这么做就不像商业软件」：
    /// 画面没变就一帧不动、正在播就接着播、按逻辑位置恢复。
    TrackPlan replaced() => const TrackPlan(
          video: [
            // U1 被换成 2 秒的候选（原本 4 秒）
            TrackSegment(
                atMs: 0,
                durationMs: 2000,
                source: '/m/71.mp4',
                sourceStartMs: 0,
                sourceSpanMs: 4000),
            TrackSegment(
                atMs: 2000, durationMs: 6000, source: '/v/a.mp4', inMs: 4000),
          ],
          voice: [TrackSegment(atMs: 0, durationMs: 8000, source: '/m/71.mp4')],
          unitRanges: {0: (0, 2000), 1: (2000, 8000)},
        );

    TrackPlan original() => const TrackPlan(
          video: [
            TrackSegment(atMs: 0, durationMs: 10000, source: '/v/a.mp4'),
          ],
          voice: [TrackSegment(atMs: 0, durationMs: 10000, source: '/v/a.mp4')],
          unitRanges: {0: (0, 4000), 1: (4000, 10000)},
        );

    test('取消 ★ 之后，「我停在 U1 的中间」这件事要保住', () {
      // 播到成片 1000ms：替换后的 U1（2 秒）走了一半
      final anchor = replaced().anchorAt(1000);

      expect(anchor, (0, 1000, 2000),
          reason: '锚的是「第 0 个单元、往里 1000ms、当时它有 2000ms 长」');
      // 换回原片：U1 恢复成 4 秒，同一个偏移还在它里面
      // U1 恢复成 4 秒，「一半」应该还是一半 → 2000
      expect(original().composedAt(anchor!), 2000);
    });

    test('反过来也对：从原片切到替换，还在同一个单元里', () {
      final anchor = original().anchorAt(2000);

      expect(anchor!.$1, 0);
      expect(replaced().composedAt(anchor), lessThan(2000),
          reason: 'U1 短了，同一个单元的这个偏移在新轴上要夹回它自己那一段');
    });

    test('来回切几次不会越飘越远', () {
      for (final ms in [0, 500, 1000, 1999]) {
        final anchor = replaced().anchorAt(ms);
        expect(replaced().composedAt(anchor!), ms);
      }
    });

    test('位置落在替换段之后时，锚到后一个单元', () {
      final anchor = replaced().anchorAt(3000);

      expect(anchor!.$1, 1, reason: '成片 3000 已经过了被换短的 U1');
      expect(original().composedAt(anchor), 5000,
          reason: '原片轴上 U2 从 4000 起，往里 1000');
    });
  });

  group('跟随轨换源要如实回报换没换', () {
    test('同一个源不重复加载——重开一次是一次可闻的接缝', () async {
      final fake = _Fake();

      expect(await fake.load('edl://a'), isTrue);
      expect(await fake.load('edl://a'), isFalse);
      expect(await fake.load('edl://b'), isTrue);
    });
  });
}

void _switchBehaviour() {
  /// 用户点 ★ / 取消勾选走的就是 setPlan。三条规矩不守就不像商业软件。
  group('换方案时画面到底动不动', () {
    late FakePlaybackController master;
    late _Fake voice;
    late _Fake bgm;
    late MultitrackPlayback playback;

    setUp(() {
      master = FakePlaybackController();
      voice = _Fake();
      bgm = _Fake();
      playback = MultitrackPlayback(video: master, voice: voice, bgm: bgm);
    });

    tearDown(() => playback.dispose());

    TrackPlan planWith({required String videoSource, String? bgmSource}) =>
        TrackPlan(
          video: [
            TrackSegment(
                atMs: 0, durationMs: 8000, source: videoSource, volume: 0),
          ],
          voice: const [
            TrackSegment(atMs: 0, durationMs: 8000, source: '/v/a.mp4'),
          ],
          bgm: [
            if (bgmSource != null)
              BgmTrackSegment(
                clip: TrackSegment(
                    atMs: 0, durationMs: 8000, source: bgmSource),
                volume: 0.25,
              ),
          ],
        );

    test('第一次推方案：打开画面轨，并且**永不解码它的音频**', () async {
      await playback.setPlanForTest(planWith(videoSource: '/v/a.mp4'));

      expect(master.calls.where((c) => c.startsWith('open(')), hasLength(1));
      expect(master.audioDisabled, isTrue,
          reason: '画面轨拼的是几十条来路不同的素材，有的带音轨有的不带；'
              '让它出声就要在接缝处重建音频链路，主时钟会当场卡死好几秒');
    });

    test('素材原声走独立的一条轨，跟着画面段走', () async {
      final source = _Fake();
      final pb = MultitrackPlayback(
          video: master, voice: voice, bgm: bgm, source: source);
      addTearDown(pb.dispose);
      await pb.setPlanForTest(TrackPlan(
        video: const [
          TrackSegment(
              atMs: 0, durationMs: 4000, source: '/v/a.mp4', volume: 0.3),
          TrackSegment(
              atMs: 4000, durationMs: 4000, source: '/v/b.mp4', volume: 0.9),
        ],
        voice: const [
          TrackSegment(atMs: 0, durationMs: 8000, source: '/vo.mp3'),
        ],
      ));
      expect(source.loaded, '/v/a.mp4', reason: '第一镜的原声挂上去');
      expect(source.volume, 0.3);

      master.emitPosition(5000);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(source.loaded, '/v/b.mp4', reason: '换镜头就换原声');
      expect(source.volume, 0.9, reason: '这一镜想把音效放大');
    });

    test('原声音量为 0 的段：原声轨停着，不做无谓的加载', () async {
      final source = _Fake();
      final pb = MultitrackPlayback(
          video: master, voice: voice, bgm: bgm, source: source);
      addTearDown(pb.dispose);
      await pb.setPlanForTest(TrackPlan(
        // 排轨时配音行的画面段拿的是全片原声音量，默认就是 0
        video: const [
          TrackSegment(
              atMs: 0, durationMs: 4000, source: '/v/a.mp4', volume: 0),
        ],
        voice: const [
          TrackSegment(atMs: 0, durationMs: 4000, source: '/vo.mp3'),
        ],
      ));
      expect(source.loaded, isNull, reason: '不出原声就别去加载它');
    });

    test('只改配乐时画面**一帧都不动**——重开一次就是一下黑闪', () async {
      await playback.setPlanForTest(
          planWith(videoSource: '/v/a.mp4', bgmSource: '/b/1.mp3'));
      final opensBefore =
          master.calls.where((c) => c.startsWith('open(')).length;

      await playback.setPlanForTest(
          planWith(videoSource: '/v/a.mp4', bgmSource: '/b/2.mp3'));

      expect(master.calls.where((c) => c.startsWith('open(')).length,
          opensBefore,
          reason: '画面轨的 EDL 没变，不该重新打开');
      expect(bgm.loaded, '/b/2.mp3', reason: '配乐该换成新的那首');
    });

    test('画面真的变了才重开', () async {
      await playback.setPlanForTest(planWith(videoSource: '/v/a.mp4'));
      await playback.setPlanForTest(planWith(videoSource: '/m/71.mp4'));

      expect(master.calls.where((c) => c.startsWith('open(')), hasLength(2));
    });

    test('换之前在播，换完接着播——点一下 ★ 就把播放停住是不能接受的', () async {
      await playback.setPlanForTest(planWith(videoSource: '/v/a.mp4'));
      await playback.play();
      expect(master.isPlaying, isTrue);

      await playback.setPlanForTest(planWith(videoSource: '/m/71.mp4'));

      expect(master.isPlaying, isTrue);
      expect(voice.calls, contains('play'));
    });

    test('换之前是暂停的就保持暂停，不擅自开始播', () async {
      await playback.setPlanForTest(planWith(videoSource: '/v/a.mp4'));
      await playback.setPlanForTest(planWith(videoSource: '/m/71.mp4'));

      expect(master.isPlaying, isFalse);
    });

    test('位置按逻辑位置恢复：取消整体替换后仍停在同一处画面', () async {
      // U1 被换成 2 秒的候选（原本 4 秒），后面是原片 4000~10000
      const replaced = TrackPlan(
        video: [
          TrackSegment(
              atMs: 0,
              durationMs: 2000,
              source: '/m/71.mp4',
              sourceStartMs: 0,
              sourceSpanMs: 4000),
          TrackSegment(
              atMs: 2000, durationMs: 6000, source: '/v/a.mp4', inMs: 4000),
        ],
        voice: [TrackSegment(atMs: 0, durationMs: 8000, source: '/v/a.mp4')],
        unitRanges: {0: (0, 2000), 1: (2000, 8000)},
      );
      const plain = TrackPlan(
        video: [TrackSegment(atMs: 0, durationMs: 10000, source: '/v/a.mp4')],
        voice: [TrackSegment(atMs: 0, durationMs: 10000, source: '/v/a.mp4')],
        unitRanges: {0: (0, 4000), 1: (4000, 10000)},
      );

      await playback.setPlanForTest(replaced);
      await playback.seekMs(1000); // 替换后的 U1 走了一半
      await playback.setPlanForTest(plain);

      expect(master.positionMs, 2000,
          reason: '「停在 U1 的一半」= 原片 2000ms；'
              '照搬成片毫秒的话会落到 1000ms，画面完全是别处');
    });
  });
}

/// 画面轨空了要**明确清掉**。
///
/// 「没有东西可播」和「什么都不做」是两回事。后者会让播放器一直挂着上一次
/// 打开的内容——真机上撞到过：新建的空白任务里播着上一条成片的一帧，
/// 用户完全没法理解那画面是从哪儿来的。
void _emptyVideoTrack() {
  group('画面轨空了', () {
    late FakePlaybackController master;
    late _Fake voice;
    late _Fake bgm;
    late MultitrackPlayback playback;

    setUp(() {
      master = FakePlaybackController();
      voice = _Fake();
      bgm = _Fake();
      playback = MultitrackPlayback(video: master, voice: voice, bgm: bgm);
    });
    tearDown(() => playback.dispose());

    test('从有内容变成空时，把画面源卸掉', () async {
      await playback.setPlanForTest(TrackPlan(video: [
        TrackSegment(atMs: 0, durationMs: 5000, source: '/a.mp4'),
      ]));
      master.calls.clear();

      await playback.setPlanForTest(const TrackPlan());

      expect(master.calls, contains('clearSource'));
    });

    test('本来就空时不反复卸——那会在每次重推轨道时多做一次无用功', () async {
      await playback.setPlanForTest(const TrackPlan());
      master.calls.clear();
      await playback.setPlanForTest(const TrackPlan());
      expect(master.calls, isNot(contains('clearSource')));
    });

    test('卸掉之后再给内容，照常打开', () async {
      await playback.setPlanForTest(const TrackPlan());
      await playback.setPlanForTest(TrackPlan(video: [
        TrackSegment(atMs: 0, durationMs: 5000, source: '/b.mp4'),
      ]));
      expect(master.calls.any((c) => c.startsWith('open')), isTrue);
    });
  });
}

/// 测试里推方案：走**和生产同一道闸**，只是挂在「原样放行」档上
/// （见 [PreviewNormalizer.passthrough]）。这些用例验的是播放器的行为，
/// 不是规格化本身——规格化有自己的用例
extension _PushPlan on MultitrackPlayback {
  Future<void> setPlanForTest(TrackPlan plan) async =>
      setPlan(await PreviewNormalizer.passthrough().normalize(plan));
}
