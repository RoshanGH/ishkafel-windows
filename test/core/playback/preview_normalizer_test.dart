import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ffmpeg/media_spec.dart';
import 'package:ishkafel/core/ffmpeg/proxy_spec.dart';
import 'package:ishkafel/core/playback/preview_normalizer.dart';
import 'package:ishkafel/core/playback/track_plan.dart';

/// **画面轨的每一段必须是同一个规格**，否则播放器在接缝处要重建解码器和
/// 视频输出——画面闪一下、主时钟停一拍，跟随轨随即被往回拽，
/// 听感是「一句话说了两遍」。
///
/// 产品负责人 2026-09-16：「无论我怎么调换位置，无论我怎么去替换，
/// 替换上来的这些东西都得是像剪映的那个时序帧的轨道一样，无论在任何地方、
/// 任何衔接处都是平稳在播放的。」
///
/// 这条规则以前靠各处自觉，反复失效（8-10 诊断、8-25 只修了口播轨、
/// 9-16 画面轨又破）。现在它是管线上一道必经的闸。
void main() {
  MediaSpec onSpec({String frameRate = '30/1'}) => MediaSpec(
    codec: ProxySpec.codec,
    profile: ProxySpec.profile,
    pixelFormat: ProxySpec.pixelFormat,
    width: ProxySpec.width,
    height: ProxySpec.height,
    frameRate: frameRate,
  );

  /// 真机上那条混进来的原始素材：1080×1920，和 720×1280 的代理混播
  MediaSpec offSpec() => MediaSpec(
    codec: 'h264',
    profile: 'High',
    pixelFormat: 'yuv420p',
    width: 1080,
    height: 1920,
    frameRate: '25/1',
  );

  TrackPlan planOf(List<String> sources) => TrackPlan(
    video: [
      for (var i = 0; i < sources.length; i++)
        TrackSegment(
          atMs: i * 1000,
          durationMs: 1000,
          source: sources[i],
          inMs: 500,
          sourceStartMs: 7000 + i * 1000,
          sourceSpanMs: 1000,
        ),
    ],
    voice: [const TrackSegment(atMs: 0, durationMs: 3000, source: '/v.mp3')],
  );

  test('全都已经是预览规格：一段都不动，一次转码都不发生', () async {
    var proxied = 0;
    final gate = PreviewNormalizer(
      probe: (_) async => onSpec(),
      toProxy: (path) async {
        proxied++;
        return path;
      },
    );

    final plan = planOf(['/a.mp4', '/b.mp4']);
    final out = await gate.normalize(plan);

    expect(out.plan.video.map((s) => s.source), ['/a.mp4', '/b.mp4']);
    expect(proxied, 0, reason: '已经合规还去转，等于每次换轨都白烧一次 ffmpeg');
    expect(out.allOnSpec, isTrue);
  });

  test('混进来一段别的规格：换成它的代理，其余不动', () async {
    final gate = PreviewNormalizer(
      probe: (path) async =>
          (path.contains('原始') && !path.startsWith('/proxy_of_'))
          ? offSpec()
          : onSpec(),
      toProxy: (path) async => '/proxy_of_${path.split('/').last}',
    );

    final out = await gate.normalize(planOf(['/代理.mp4', '/原始.mp4']));

    expect(out.plan.video[0].source, '/代理.mp4');
    expect(out.plan.video[1].source, '/proxy_of_原始.mp4');
    expect(out.allOnSpec, isTrue);
  });

  test('换源只换源——时间轴上的一切原样保留', () async {
    // 代理和原文件是同一段内容的两份编码，时间是对齐的。这几个数一旦跟着变，
    // 画面和台词就错位了
    final gate = PreviewNormalizer(
      probe: (path) async => path.startsWith('/proxy') ? onSpec() : offSpec(),
      toProxy: (_) async => '/proxy.mp4',
    );

    final before = planOf(['/原始.mp4']).video.single;
    final after = (await gate.normalize(planOf(['/原始.mp4']))).plan.video.single;

    expect(after.source, '/proxy.mp4');
    expect(after.atMs, before.atMs);
    expect(after.durationMs, before.durationMs);
    expect(after.inMs, before.inMs);
    expect(after.volume, before.volume);
    expect(after.sourceStartMs, before.sourceStartMs);
    expect(after.sourceSpanMs, before.sourceSpanMs);
  });

  test('转不动的照样播，但要点名——不静默降级', () async {
    final gate = PreviewNormalizer(
      // 转出来还是老规格（真机上「转完验时长对不上就退回原文件」那条路）
      probe: (_) async => offSpec(),
      toProxy: (path) async => path,
    );

    final out = await gate.normalize(planOf(['/转不动的.mp4']));

    expect(
      out.plan.video.single.source,
      '/转不动的.mp4',
      reason: '宁可留着那一下接缝顿挫，也不能让这一段整个放不了',
    );
    expect(out.offSpec, ['转不动的.mp4'], reason: '不报的话，下一个人又要从头查一遍这是为什么闪');
    expect(out.allOnSpec, isFalse);
  });

  test('同一个文件只探一次规格——逐段 ffprobe 会拖慢每一次换轨', () async {
    var probes = 0;
    final gate = PreviewNormalizer(
      probe: (_) async {
        probes++;
        return onSpec();
      },
      toProxy: (path) async => path,
    );

    // 同一条原片在轨上出现三次（很常见：几个镜头都取自它）
    await gate.normalize(planOf(['/同一条.mp4', '/同一条.mp4', '/同一条.mp4']));
    // 再换一次轨（改配乐、改音量都会重推）
    await gate.normalize(planOf(['/同一条.mp4']));

    expect(probes, 1);
  });

  test('声音轨不归它管——那是另一套规格（48kHz 立体声）', () async {
    final gate = PreviewNormalizer(
      probe: (_) async => onSpec(),
      toProxy: (path) async => '/不该被调用',
    );

    final out = await gate.normalize(planOf(['/a.mp4']));

    expect(out.plan.voice.single.source, '/v.mp3');
  });

  test('探测临时读不到时，下次装轨重新探测并恢复', () async {
    var available = false;
    var probes = 0;
    final gate = PreviewNormalizer(
      probe: (_) async {
        probes++;
        return available ? onSpec() : null;
      },
      toProxy: (path) async => path,
    );
    final plan = planOf(['/a.mp4']);
    expect((await gate.normalize(plan)).allOnSpec, isFalse);
    available = true;
    expect((await gate.normalize(plan)).allOnSpec, isTrue);
    expect(probes, 2, reason: '必须重新确认规格，不能把上一轮降级当成合规');
  });

  test('代理临时失败后，下次装轨可以取得代理', () async {
    var available = false;
    final gate = PreviewNormalizer(
      probe: (path) async => path == '/proxy.mp4' ? onSpec() : offSpec(),
      toProxy: (path) async => available ? '/proxy.mp4' : path,
    );
    final plan = planOf(['/a.mp4']);
    expect((await gate.normalize(plan)).allOnSpec, isFalse);
    available = true;
    final out = await gate.normalize(plan);
    expect(out.plan.video.single.source, '/proxy.mp4');
    expect(out.allOnSpec, isTrue);
  });

  test('失败源同轮只转一次，每轮的每段都继续报告降级', () async {
    var conversions = 0;
    final gate = PreviewNormalizer(
      probe: (_) async => offSpec(),
      toProxy: (path) async {
        conversions++;
        return path;
      },
    );
    final plan = planOf(['/a.mp4', '/a.mp4']);
    for (var round = 1; round <= 2; round++) {
      final out = await gate.normalize(plan);
      expect(out.offSpec, ['a.mp4', 'a.mp4']);
      expect(conversions, round);
    }
  });

  test('代理校验失败后同路径重建，下轮重新校验', () async {
    var rebuilt = false;
    final gate = PreviewNormalizer(
      probe: (path) async =>
          path == '/proxy.mp4' && rebuilt ? onSpec() : offSpec(),
      toProxy: (_) async => '/proxy.mp4',
    );
    final plan = planOf(['/a.mp4']);
    expect((await gate.normalize(plan)).allOnSpec, isFalse);
    rebuilt = true;
    final out = await gate.normalize(plan);
    expect(out.plan.video.single.source, '/proxy.mp4');
    expect(out.allOnSpec, isTrue);
  });

  test('成功代理跨轮复用，forget 代理后重新校验关联源', () async {
    var valid = true;
    var conversions = 0;
    final gate = PreviewNormalizer(
      probe: (path) async =>
          path == '/proxy.mp4' && valid ? onSpec() : offSpec(),
      toProxy: (_) async {
        conversions++;
        return '/proxy.mp4';
      },
    );
    final plan = planOf(['/a.mp4']);
    await gate.normalize(plan);
    expect((await gate.normalize(plan)).plan.video.single.source, '/proxy.mp4');
    expect(conversions, 1);
    valid = false;
    gate.forget('/proxy.mp4');
    final out = await gate.normalize(plan);
    expect(out.plan.video.single.source, '/a.mp4');
    expect(out.allOnSpec, isFalse);
  });

  test('forget 原路径后会重新探测源文件', () async {
    var valid = true;
    final gate = PreviewNormalizer(
      probe: (_) async => valid ? onSpec() : offSpec(),
      toProxy: (path) async => path,
    );
    final plan = planOf(['/a.mp4']);
    expect((await gate.normalize(plan)).allOnSpec, isTrue);
    valid = false;
    gate.forget('/a.mp4');
    expect((await gate.normalize(plan)).allOnSpec, isFalse);
  });

  test('放行档：一段都不验、也不谎报「有几段不合规」', () async {
    final out = await PreviewNormalizer.passthrough().normalize(
      planOf(['/随便.mov']),
    );

    expect(out.plan.video.single.source, '/随便.mov');
    expect(out.offSpec, isEmpty);
  });
}
