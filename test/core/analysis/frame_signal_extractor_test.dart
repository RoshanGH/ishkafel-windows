import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/frame_signal_extractor.dart';

const _side = 4; // 测试用小图，逻辑与 32 完全相同
const _frameSize = _side * _side * 3;

/// 一帧纯色图
List<int> _solid(int value) => List<int>.filled(_frameSize, value);

String _meta(List<(double seconds, double score)> records) => [
  for (final (t, s) in records)
    'frame:0 pts:0 pts_time:$t\nlavfi.scene_score=$s\n',
].join();

void main() {
  group('帧对齐（错开一帧不会报错，只会让结果悄悄失真）', () {
    test('第 j 条记录对应第 j+1 帧的画面变化', () {
      // 三帧：黑、黑、白。真正的画面突变发生在第 2 帧（下标 2）
      final thumbs = [..._solid(0), ..._solid(0), ..._solid(255)];
      // 两条记录：描述第 1 帧、第 2 帧
      final meta = _meta([(0.033, 0.01), (0.067, 0.90)]);

      final signals = buildFrameSignals(
        sceneMetadata: meta,
        thumbBytes: thumbs,
        side: _side,
      );

      expect(signals, hasLength(2));
      expect(signals[0].histDistance, 0, reason: '第 1 帧相对第 0 帧没有变化（黑→黑）');
      expect(
        signals[1].histDistance,
        closeTo(2, 0.01),
        reason:
            '第 2 帧相对第 1 帧是黑→白。若把记录对到第 j 帧而不是 '
            'j+1，这里会变成 0，而两个指标的高分位就完全错开——'
            '标定时实测交集为 0，代码却一声不吭',
      );
    });

    test('时间戳取自 metadata，不靠帧号自己推算', () {
      final thumbs = [..._solid(0), ..._solid(10), ..._solid(20)];
      final meta = _meta([(1.5, 0.1), (2.25, 0.2)]);

      final signals = buildFrameSignals(
        sceneMetadata: meta,
        thumbBytes: thumbs,
        side: _side,
      );

      expect(signals.map((s) => s.ms), [1500, 2250]);
    });

    test('scene 分数原样带出，不做任何加工', () {
      final thumbs = [..._solid(0), ..._solid(0)];
      final meta = _meta([(0.033, 0.4567)]);

      final signals = buildFrameSignals(
        sceneMetadata: meta,
        thumbBytes: thumbs,
        side: _side,
      );

      expect(signals.single.sceneScore, closeTo(0.4567, 1e-9));
    });
  });

  group('两份产物长度对不上时不越界', () {
    test('记录比画面帧多：多出来的丢掉', () {
      final thumbs = [..._solid(0), ..._solid(0)]; // 只有 2 帧
      final meta = _meta([(0.033, 0.1), (0.067, 0.2), (0.1, 0.3)]);

      final signals = buildFrameSignals(
        sceneMetadata: meta,
        thumbBytes: thumbs,
        side: _side,
      );

      expect(signals, hasLength(1), reason: '第 2 条记录要的是第 2 帧，而画面只有 0、1 两帧');
    });

    test('画面帧比记录多：按记录数为准', () {
      final thumbs = [for (var i = 0; i < 5; i++) ..._solid(i * 20)];
      final meta = _meta([(0.033, 0.1)]);

      final signals = buildFrameSignals(
        sceneMetadata: meta,
        thumbBytes: thumbs,
        side: _side,
      );

      expect(signals, hasLength(1));
    });

    test('画面不足两帧时直接返回空，不做除零或负下标', () {
      expect(
        buildFrameSignals(
          sceneMetadata: _meta([(0.033, 0.1)]),
          thumbBytes: _solid(0),
          side: _side,
        ),
        isEmpty,
      );
      expect(
        buildFrameSignals(
          sceneMetadata: _meta([(0.033, 0.1)]),
          thumbBytes: const [],
          side: _side,
        ),
        isEmpty,
      );
    });

    test('metadata 为空时返回空', () {
      final thumbs = [..._solid(0), ..._solid(255)];

      expect(
        buildFrameSignals(sceneMetadata: '', thumbBytes: thumbs, side: _side),
        isEmpty,
      );
    });
  });

  group('ffmpeg 参数', () {
    test('scene 用 gt(scene,0)：每帧都出记录，阈值判定留给 Dart 侧', () {
      final args = FrameSignalExtractor.sceneArgs('/v/a.mp4', '/tmp/o.txt');

      expect(
        args.join(' '),
        contains("gt(scene,0)"),
        reason: '写死阈值就拿不到完整分数曲线，也就没法按素材自适应',
      );
      expect(args.join(' '), contains('metadata=print'));
    });

    test('scene 的 Windows 输出路径按 filtergraph 语法转义', () {
      final args = FrameSignalExtractor.sceneArgs(
        r'D:\项目 文件\分析,结果.txt',
        r'C:\临时\unused.txt',
      );

      expect(args[3], contains(r'metadata=print:file=C\\:/临时/unused.txt'));
      expect(
        args[3],
        isNot(contains(r'C:\临时')),
        reason: '反斜杠在 filtergraph 里是转义符，不能原样传入',
      );
    });

    test('缩略图带 -y，重跑分析不会卡在覆盖确认上', () {
      final args = FrameSignalExtractor.thumbArgs('/v/a.mp4', '/tmp/o.raw');

      expect(
        args.first,
        '-y',
        reason:
            '本项目踩过这个坑：-y 放在输入之后不生效，ffmpeg 会等在'
            '「文件已存在，是否覆盖」的交互上，表现为分析永久卡住',
      );
      expect(args.join(' '), contains('rawvideo'));
    });
  });
}
