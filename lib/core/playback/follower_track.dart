import 'package:flutter/foundation.dart';

import 'track_plan.dart';

/// 一条**只出声的跟随轨**：自己不管时间轴，主时钟说到哪就跟到哪。
///
/// 抽成接口是为了让下面那套「什么时候该 load / seek / 校正」的判断能脱离
/// media_kit 单测——多轨同步是这套架构唯一的技术风险，不能只靠真机手感。
abstract class FollowerTrack {
  /// 换源。[edl] 为 null 表示这一轨这次没东西可播。
  /// 返回 true 表示**真的换了**——没换的话调用方不必重新定位
  Future<bool> load(String? edl);

  Future<void> play();
  Future<void> pause();
  Future<void> seekMs(int ms);

  /// 0.0 ~ 1.0
  Future<void> setVolume(double volume);

  /// 播放速率（1.0 = 原速）。**用来微调着追主时钟**，不是给人调倍速的。
  ///
  /// 为什么不用 seek 追：seek 是一次跳变，往回跳就重播一小段（听感是
  /// 「一句话说了两遍」），往前跳就吞掉一小段。而把速率调到 1.02 追上再
  /// 恢复，人是听不出来的——mpv 默认开着音调校正，变速不变调。
  /// 这是播放器做音画同步的标准做法
  Future<void> setRate(double rate);

  /// 当前位置（毫秒）。还没加载时返回 0
  int get positionMs;

  Future<void> dispose();
}

/// 主时钟与跟随轨之间容许多大偏差。
///
/// 真机实测：三个播放器实例同时跑 10 秒，偏差在 ±70ms 以内且**不累积**
/// （在正负之间抖，说明主要是分三次读位置的时间差，不是真漂移）。阈值取
/// 150ms——比抖动幅度留出一倍余量，否则会被抖动骗得反复 seek，而每次 seek
/// 都是一次可闻的接缝。
const int syncToleranceMs = 150;

/// 该不该纠偏。[follower] 为 null（还没加载）时不纠
bool needsResync({required int masterMs, required int? followerMs}) {
  if (followerMs == null) return false;
  return (followerMs - masterMs).abs() > syncToleranceMs;
}

/// 偏差大到这个数就不微调了，直接跳。
///
/// 这不是"漂移"，是**换了个地方**：人拖了播放头、换了源、EDL 重开。
/// 那时候慢慢追要追好几十秒，跳过去才是对的
const int seekInsteadOfChaseMs = 1200;

/// 追平用多长时间。太短则速率偏离大到能听出来，太长则一次接缝的偏差
/// 要拖好几秒才抹平。4 秒对应 100ms 偏差 = 2.5% 速率偏离，听不出来
const int chaseWindowMs = 4000;

/// 速率最多偏离多少。±6% 是音调校正下还自然的上限
const double maxChaseRate = 0.06;

/// 进了这个范围就收手，把速率放回 1.0。
///
/// **必须比 [syncToleranceMs] 小得多**：踩着阈值收手的话，刚回到 149ms
/// 就停止追赶，下一次采样又超线，于是一直在追——而 65ms 的恒定偏差正是
/// 这么来的（2026-09-16 真机：全程落后 26~139ms，够不着 150ms 的硬阈值，
/// 所以永远不纠，音画一直差着）
const int chaseDeadZoneMs = 25;

/// 这一刻跟随轨该用什么速率去追主时钟。
///
/// [drift] = 跟随轨位置 − 主时钟位置。负数 = 落后，要加速。
/// 返回 1.0 表示不用追（已经够近了）
double chaseRate(int drift) {
  if (drift.abs() <= chaseDeadZoneMs) return 1.0;
  final adjust = (-drift / chaseWindowMs).clamp(-maxChaseRate, maxChaseRate);
  return 1.0 + adjust;
}

/// 这一刻配乐轨应该是什么样。[source] 为 null 表示这一刻不该出声。
@immutable
class BgmCue {
  final String? source;

  /// 该播这首曲子的哪一刻（已按「不够长就循环」取过模）
  final int inMs;
  final double volume;

  const BgmCue({this.source, this.inMs = 0, this.volume = 1});

  static const silent = BgmCue();

  @override
  bool operator ==(Object other) =>
      other is BgmCue &&
      other.source == source &&
      other.inMs == inMs &&
      other.volume == volume;

  @override
  int get hashCode => Object.hash(source, inMs, volume);
}

/// 成片走到 [masterMs] 这一刻，配乐轨该播什么。
///
/// 段与段不重叠，所以最多命中一段。没命中就静音——这就是「太长就播到段尾停」：
/// 走出这一段的范围，配乐自然停了。
BgmCue bgmCueAt(TrackPlan plan, int masterMs) {
  final segment = plan.bgmAt(masterMs);
  if (segment == null) return BgmCue.silent;
  return BgmCue(
    source: segment.clip.source,
    inMs: segment.sourceMsAt(masterMs),
    volume: segment.volume,
  );
}
