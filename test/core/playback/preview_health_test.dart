import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/playback/preview_health.dart';

/// **预览平不平稳，用数字说了算。**
///
/// 产品负责人 2026-09-16：「每次都是在开发一些其他功能以后，这种问题就又
/// 出现。」闸挡的是代码层面的绕过、守卫挡的是规则被拆，而这一层挡的是
/// **真实播放效果的退化**——那是代码扫描一个都看不出来的。
///
/// 这组用例喂的是**真机日志的原文**（修之前那一轮、修之后那一轮），
/// 验它能不能把两者分开。分不开的话，这条检查就只是个摆设。
void main() {
  /// 修之前那一轮的日志形状：规格混播 → 视频输出重建、口播被硬拽
  const before = '''
[ishkafel][info] 同步采样：主时钟 27033ms、口播轨 26950ms、偏差 -83ms、前瞻 0ms
2026-09-17 00:42:54.340 ishkafel[57871:14491883] TextureGL: resize: 720.0x1280.0
[ishkafel][info] 同步采样：主时钟 28058ms、口播轨 28017ms、偏差 -41ms、前瞻 0ms
[ishkafel][info] 同步采样：主时钟 29058ms、口播轨 28998ms、偏差 -60ms、前瞻 0ms
[ishkafel][info] 同步采样：主时钟 30058ms、口播轨 29977ms、偏差 -181ms、前瞻 0ms
[ishkafel][info] 口播轨差了 -153ms（不是漂移，是换了地方），跳到 8533
[ishkafel][info] 同步采样：主时钟 31058ms、口播轨 31014ms、偏差 -144ms、前瞻 0ms
''';

  /// 修之后那一轮：规格统一、调速追赶
  const after = '''
[ishkafel][info] 同步采样：主时钟 23033ms、口播轨 23007ms、偏差 -26ms、前瞻 0ms
[ishkafel][info] 口播轨偏 27ms，用 0.993× 追
[ishkafel][info] 同步采样：主时钟 24033ms、口播轨 24023ms、偏差 -10ms、前瞻 0ms
[ishkafel][info] 同步采样：主时钟 25033ms、口播轨 25054ms、偏差 21ms、前瞻 0ms
[ishkafel][info] 同步采样：主时钟 26033ms、口播轨 26010ms、偏差 -23ms、前瞻 0ms
[ishkafel][info] 同步采样：主时钟 27033ms、口播轨 27021ms、偏差 -12ms、前瞻 0ms
''';

  test('修之前那一轮：画面闪和硬拽都要被逮住', () {
    final h = readPreviewHealth(before);

    expect(h.videoRebuilds, 1, reason: 'TextureGL resize 就是看得见的那一下闪');
    expect(h.hardSeeks, 1, reason: '硬拽就是听得见的「说了两遍」');

    final failures = previewHealthFailures(h);
    expect(failures.any((f) => f.contains('闪')), isTrue);
    expect(failures.any((f) => f.contains('两遍')), isTrue);
  });

  test('修之后那一轮：这几项都该是 0', () {
    final h = readPreviewHealth(after);

    expect(h.videoRebuilds, 0);
    expect(h.hardSeeks, 0);
    expect(h.offSpecSegments, 0);
    expect(h.proxyFailures, 0);
  });

  test('起播那几秒的偏差不算——那时画面刚出来，人不在那一刻判断同步', () {
    // 头三个采样点偏差很大（口播轨还在起播、追赶还没收敛），
    // 第四个之后才是稳态
    const log = '''
偏差 -300ms
偏差 -200ms
偏差 -150ms
偏差 -12ms
偏差 8ms
''';
    final h = readPreviewHealth(log);

    expect(h.worstLagMs, 12, reason: '前三个是暖机，不该算进来');
    expect(h.worstLeadMs, 8);
  });

  test('声音早于画面比晚更难忍——两个方向的线不一样', () {
    // 这不是偷懒：现实里远处的声音本来就晚，人一辈子在适应它；
    // 而声音跑到画面前面是现实中不存在的事
    expect(PreviewHealthLimits.maxAudioLeadMs,
        lessThan(PreviewHealthLimits.maxAudioLagMs));

    // 晚 80ms：能忍
    expect(
        previewHealthFailures(_at(lag: 80)).where((f) => f.contains('晚')),
        isEmpty);
    // 早 80ms：不能忍
    expect(previewHealthFailures(_at(lead: 80)).where((f) => f.contains('早')),
        isNotEmpty);
  });

  test('没播起来就不下结论——别拿两个采样点说「一切正常」', () {
    final h = readPreviewHealth('偏差 0ms\n主时钟 1000ms、口播轨 1000ms');

    expect(previewHealthFailures(h).any((f) => f.contains('不作数')), isTrue);
  });

  test('主时钟卡住要被逮住——那是接缝顿挫的量法', () {
    const stalled = '''
主时钟 1000ms、口播轨 1000ms
主时钟 2000ms、口播轨 2000ms
主时钟 3600ms、口播轨 3600ms
''';
    final h = readPreviewHealth(stalled);

    expect(h.worstTickMs, 1600);
    expect(previewHealthFailures(h).any((f) => f.contains('停了')), isTrue);
  });
}

/// 造一份「只有这一项越线」的体检结果
PreviewHealth _at({int lag = 0, int lead = 0}) => PreviewHealth(
      videoRebuilds: 0,
      hardSeeks: 0,
      offSpecSegments: 0,
      proxyFailures: 0,
      minDriftMs: -lag,
      maxDriftMs: lead,
      worstTickMs: 1000,
      samples: 60,
    );
