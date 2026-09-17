import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **进画面轨的每一段都必须过规格化那道闸。**
///
/// 产品负责人 2026-09-16：「我替换过后再去播放，它会经常在连接处闪一下，
/// 或者说这个回放一下……我觉得这应该是整个底层架构最核心的东西，就是无论我
/// 怎么调换位置，无论我怎么去替换，替换上来的这些东西都得是像剪映的那个
/// 时序帧的轨道一样，无论在任何地方、任何衔接处都是平稳在播放的。」
///
/// 以及他真正要解决的那件事：
///
/// > **每次都是在开发一些其他功能以后，这种问题就又出现。**
///
/// 查下来他说得对，这个病犯过三次：
///
/// - 2026-08-10 诊断（变速镜头在替换点加速播放，量到 1.67× 连跑 6.5 秒），
///   造了 `ProxyBuilder`、写了 `ProxySpec` 的规矩
/// - 2026-08-25 `6328b57` 在**口播轨**上实施了一次（PreviewVoiceNormalizer），
///   画面轨没做
/// - 2026-09-16 画面轨又破：整体替换的素材在重开 app 之后走
///   `PickedMediaCache.localPathOf` 的兜底分支，拿的是 `materials/` 里
///   1080×1920 的原始下载，和 720×1280 的代理、切片混播
///
/// **三次修的都是「那一处」，没有任何东西守着规则本身。** 所以这条守卫盯的
/// 不是某一段有没有规格化，而是**那道闸还在不在、有没有人绕过去**。
void main() {
  String read(String path) {
    final f = File(path);
    expect(f.existsSync(), isTrue, reason: '$path 挪了位置就把这条守卫一起改');
    return f.readAsStringSync();
  }

  test('播放器只收规格化过的方案——这是编译期的保证，不是自觉', () {
    final playback = read('lib/core/playback/multitrack_playback.dart');

    expect(playback, contains('setPlan(NormalizedTrackPlan'),
        reason: '一旦它又收回 TrackPlan，任何新来源都能把没验过的段塞进画面轨');
  });

  test('那个类型只能由闸产出——构造函数必须是私有的', () {
    final gate = read('lib/core/playback/preview_normalizer.dart');

    expect(gate, contains('const NormalizedTrackPlan._('),
        reason: '公开的构造函数等于后门：随手 new 一个就绕过去了');
    // 「没验过」不许伪装成「验过了」。放行档是显式的、扫得到的名字
    expect(gate, contains('PreviewNormalizer.passthrough()'));
  });

  test('两条产品线都要过闸——脚本成片那条以前整条都没有', () {
    // 替换裂变：PreviewTracks
    final tracks = read('lib/features/workbench/preview_tracks.dart');
    expect(tracks, contains('normalizer.normalize('),
        reason: '替换裂变的画面轨要过闸');
    expect(tracks, contains('required this.normalizer'),
        reason: '闸必须是必需参数——不能让「忘了传」和「有意放行」长得一样');

    // 脚本成片：DirectorPage。2026-09-17 之前这条线三处 setPlan 一处都没验
    final director = read('lib/features/director/director_page.dart');
    expect(director, contains('_normalizer.normalize('),
        reason: '脚本成片的画面轨也要过闸');
    expect(director.contains('playback.setPlan(result.plan)'), isFalse,
        reason: '这是绕过闸的老写法');
  });

  test('生产装配不许挂在「原样放行」档上', () {
    // 放行档只给测试和没有数据目录的精简装配用。真装了闸却让它放行，
    // 等于没设防——而这正是过去三次复发的形状
    final offenders = <String>[];
    for (final f in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .where((f) => !f.path.endsWith('preview_normalizer.dart'))) {
      // **只看代码行**：文档注释里提到这个名字是在解释规矩，不是在用它
      // （星号守卫踩过同一个坑：跨过引号去匹配，把注释也算进来了）
      final src = [
        for (final line in f.readAsStringSync().split('\n'))
          if (!line.trimLeft().startsWith('//')) line,
      ].join('\n');
      if (!src.contains('PreviewNormalizer.passthrough()')) continue;
      // 合法的两处：没有数据目录时（测试/精简环境）的兜底。它们必须在
      // 一个「dataDir == null」的判断里，或者是字段的缺省值
      final ok = src.contains('dataDir == null') ||
          src.contains('_normalizer = PreviewNormalizer.passthrough();');
      if (!ok) offenders.add(f.path);
    }

    expect(offenders, isEmpty,
        reason: '这些地方装了闸却让它原样放行，等于没设防：\n'
            '${offenders.join('\n')}');
  });

  test('规格的判据只有一份——别再冒出第二套「什么算合规」', () {
    // ProxySpec.matches 是唯一判据。第二份判据迟早和第一份走散，
    // 那时两边都觉得自己是对的
    final gate = read('lib/core/playback/preview_normalizer.dart');
    expect(gate, contains('ProxySpec.matches('));

    final spec = read('lib/core/ffmpeg/proxy_spec.dart');
    expect(spec, contains('static bool matches('));
  });

  test('换源只换源——时间轴上的数一个都不许跟着变', () {
    // 代理和原文件是同一段内容的两份编码，时间是对齐的。withSource 要是
    // 顺手改了 atMs/inMs/sourceStartMs，画面和台词当场错位，而且不报错
    final plan = read('lib/core/playback/track_plan.dart');
    final at = plan.indexOf('TrackSegment withSource(');
    expect(at, greaterThan(-1));
    final body = plan.substring(at, plan.indexOf('bool covers(', at));

    for (final field in const [
      'atMs: atMs',
      'durationMs: durationMs',
      'inMs: inMs',
      'volume: volume',
      'sourceStartMs: sourceStartMs',
      'sourceSpanMs: sourceSpanMs',
    ]) {
      expect(body, contains(field), reason: 'withSource 漏了 $field');
    }
  });

  test('跟随轨用调速追，不再硬 seek——否则接缝顿挫还是会变成可闻的重复', () {
    // 产品负责人的症状：「是谁说的，哎，是谁说的，说两遍」——那是硬 seek
    // 往回跳的声音。规格化把接缝顿挫压小了，但只要还用硬 seek，任何一次
    // 偶发的长停顿就还会变成一次可闻的重复。两层防护缺一不可
    final playback = read('lib/core/playback/multitrack_playback.dart');

    expect(playback, contains('chaseRate('),
        reason: '小偏差要用调速追平，不是跳');
    expect(playback, contains('seekInsteadOfChaseMs'),
        reason: '大偏差（换了地方）才跳');

    // 死区必须比硬阈值小得多，否则会留下一个永远不纠的恒定偏差
    // （真机量到 65ms：够不着 150ms，所以从来没被纠过）
    final follower = read('lib/core/playback/follower_track.dart');
    expect(follower, contains('chaseDeadZoneMs'));
  });

  test('体检那条线还在——代码扫描看不出真实播放退化', () {
    // 闸挡的是「有人绕过规则」，守卫挡的是「规则被拆」。都挡不住：
    // 代理规格被改、新素材类型带来别的毛病、机器慢到接缝撑不住——
    // 那些只有真播一遍才知道（产品负责人：「每次开发完这问题就又出现」）
    expect(File('scripts/preview_health.sh').existsSync(), isTrue,
        reason: '真播一遍的驱动脚本');
    expect(File('tool/preview_health.dart').existsSync(), isTrue,
        reason: '判定的入口');

    final limits =
        File('lib/core/playback/preview_health.dart').readAsStringSync();
    // 这几条线是「他能不能感觉到」，不是内部指标。**画面闪和硬拽一次都
    // 不许有**——规格统一之后它们就该是 0，谁把这两个数调大，
    // 等于把今天这件事重新放回去
    expect(limits, contains('maxVideoRebuilds = 0'));
    expect(limits, contains('maxHardSeeks = 0'));
  });
}
