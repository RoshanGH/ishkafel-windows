import 'package:flutter/foundation.dart';

/// 一条轨上的一段：**成片时间轴上的 [atMs, atMs+durationMs)** 这段时间，
/// 播 [source] 这个文件的 [inMs] 开始处。
///
/// 段与段之间在同一条轨上不重叠、按 [atMs] 升序。
@immutable
class TrackSegment {
  /// 在成片时间轴上从什么时候开始
  final int atMs;

  /// 在成片时间轴上占多长
  final int durationMs;

  /// 播哪个文件
  final String source;

  /// 从这个文件的什么位置开始播
  final int inMs;

  /// 这一段自己的音量（0~1）。画面轨用它表达「素材原声出多大」——
  /// 音效要听得见，但不能盖过口播；逐镜可以不一样
  final double volume;

  /// 这一段在**原片时间轴**上对应哪一段（起点，时长）。
  ///
  /// 时间线画的是原片切分，播放头要靠它换算回去。绝大多数段落就是自己
  /// （播的就是原片那一段），只有**整体替换**不同：播的是另一条素材，
  /// 原片时刻在那儿根本不存在，但时间线上那个格子还是按原单元的长度画的。
  final int sourceStartMs;
  final int sourceSpanMs;

  const TrackSegment({
    required this.atMs,
    required this.durationMs,
    required this.source,
    this.inMs = 0,
    this.volume = 1.0,
    int? sourceStartMs,
    int? sourceSpanMs,
  })  : sourceStartMs = sourceStartMs ?? inMs,
        sourceSpanMs = sourceSpanMs ?? durationMs;

  int get endMs => atMs + durationMs;

  /// 换一个源文件，别的一概不动。
  ///
  /// 规格化用它把某一段换成同规格的代理（见 [PreviewNormalizer]）——
  /// 时间轴上的位置、取材点、音量、对应的原片区间**必须原样保留**，
  /// 代理和原文件是同一段内容的两份编码，时间是对齐的
  TrackSegment withSource(String next) => TrackSegment(
        atMs: atMs,
        durationMs: durationMs,
        source: next,
        inMs: inMs,
        volume: volume,
        sourceStartMs: sourceStartMs,
        sourceSpanMs: sourceSpanMs,
      );

  bool covers(int ms) => ms >= atMs && ms < endMs;

  /// 成片时刻 [ms] 对应原片的哪一刻。
  ///
  /// **整体替换段按比例映射**：候选 11.3 秒顶掉原来的 15.1 秒，1:1 映射会让
  /// 播放头走到格子的 3/4 处就到头，下一拍直接跳到下一个单元——用户看到的
  /// 是「还剩 1/5 就跳过去了」。按比例走才能匀速走完整个格子，而且语义上也
  /// 对：那一段播的是别的素材，本来就没有一一对应的原片时刻。
  int sourceMsAt(int ms) {
    final into = ms - atMs;
    if (sourceSpanMs == durationMs || durationMs <= 0) {
      return sourceStartMs + into;
    }
    return sourceStartMs + (into * sourceSpanMs / durationMs).round();
  }

  @override
  bool operator ==(Object other) =>
      other is TrackSegment &&
      other.atMs == atMs &&
      other.durationMs == durationMs &&
      other.source == source &&
      other.inMs == inMs &&
      other.volume == volume &&
      other.sourceStartMs == sourceStartMs &&
      other.sourceSpanMs == sourceSpanMs;

  @override
  int get hashCode =>
      Object.hash(atMs, durationMs, source, inMs, volume, sourceStartMs,
          sourceSpanMs);

  @override
  String toString() => 'TrackSegment($atMs+$durationMs ← $source@$inMs)';
}

/// 配乐段落多带音量与曲子本身的长度——每段音量独立（见 [BgmSegment.volume]）；
/// 曲长用来算「不够长就循环」时该从曲子的哪一刻接上
@immutable
class BgmTrackSegment {
  final TrackSegment clip;
  final double volume;

  /// 这首曲子本身有多长。为 0 表示不知道，那就不循环、播完即止
  final int sourceDurationMs;

  const BgmTrackSegment({
    required this.clip,
    required this.volume,
    this.sourceDurationMs = 0,
  });

  /// 成片时刻 [ms] 该播这首曲子的哪一刻。曲子比这一段短就绕回开头
  /// （「时长不够就循环」——产品定的配乐原则）
  int sourceMsAt(int ms) {
    final offset = ms - clip.atMs;
    if (sourceDurationMs <= 0) return offset;
    return offset % sourceDurationMs;
  }

  @override
  bool operator ==(Object other) =>
      other is BgmTrackSegment &&
      other.clip == clip &&
      other.volume == volume &&
      other.sourceDurationMs == sourceDurationMs;

  @override
  int get hashCode => Object.hash(clip, volume, sourceDurationMs);
}

/// 预览要播的东西——**三条各自独立的轨**，谁到点了谁播自己那一段。
///
/// **为什么不再预合成**：此前预览是先用 ffmpeg 把 43 段拼成一整条新片子再喂
/// 给播放器，一轮几分钟、几百兆磁盘，而其中 42 段是把原片原封不动切了一遍。
/// 用户原话：「它就不能像剪映一样各是各的吗？播放的时候一起播放。」——能，
/// 而且实测可行：libmpv 的 `edl://` 能把「原片一段 + 候选一段」当成一个虚拟
/// 文件直接播（零转码），多个播放器实例同时跑的偏差在 ±70ms 以内且不累积。
///
/// 原片的背景音**刻意不单独成轨**：人声分离是有损的（实测残差 −27dB，
/// 听得出来）。没铺配乐的段落直接用原混音、一个字节不改，只有被配乐盖住的
/// 段落才换成纯人声——否则全片都要先损一道。
@immutable
/// 一段放不了的成片区间：这个单元还没挑素材，画面无从谈起。
class UnplayableSpan {
  final int unitIndex;
  final int startMs;
  final int endMs;

  const UnplayableSpan(
      {required this.unitIndex, required this.startMs, required this.endMs});

  bool covers(int composedMs) => composedMs >= startMs && composedMs < endMs;

  @override
  String toString() => 'U${unitIndex + 1} $startMs-$endMs';
}

class TrackPlan {
  /// 画面：没替换的用原片、整体替换用候选整条、镜头替换用变速对齐后的切片
  final List<TrackSegment> video;

  /// 口播：换过音色用配音、整体替换用候选自己的声音、被配乐盖住用纯人声、
  /// 其余用原混音
  final List<TrackSegment> voice;

  /// 配乐：各段各的曲子与音量
  final List<BgmTrackSegment> bgm;

  /// 口播轨的总音量（0~1）。
  ///
  /// **按轨给而不是按段给**：这条轨是一整条 EDL 交给播放器的，
  /// mpv 没法为 EDL 里的某一段单独设音量。口播段落之间也不需要各自不同
  final double voiceVolume;

  /// 哪几段配乐这一次没铺上（人话，可直接展示）。
  /// 预览可以少一段垫乐——人还在编辑、听得出来——但必须说出来
  final List<String> bgmMissing;

  /// 「原片这一镜的声音」选了人声/背景声，但那条分离轨这一刻不在——
  /// 预览只能先放原混音。人话标签（`U2·S3`），可直接展示。
  ///
  /// **预览可以退回原混音，但必须说出来**：不说的话人听到的和导出的
  /// 不是一回事，而他正是照着预览在挑组合
  final List<String> sourceStemMissing;

  /// 「替换分镜的声音」选了人声/背景声的那几镜。人话标签（`U2·S3`）。
  ///
  /// 预览里这一层读的是**变速切片**，切片带的是素材原混音；而导出用的是
  /// 分离出来的那一路。和 [sourceStemMissing] 同一个道理：预览可以退回
  /// 原混音，但必须说出来——不说的话人听到的和导出的不是一回事，
  /// 而他正是照着预览在挑组合
  final List<String> materialStemMissing;

  /// 空白任务里还没挑素材、这一轮预览**跳过**了的分子（下标，从 0 起）。
  ///
  /// 没有原片可以垫底，跳过是唯一的选择——但跳过必须说出来，否则用户看到
  /// 的片子比他排的短一段，还以为是自己记错了
  final List<int> skippedEmptyUnits;

  /// 放不了的那几段在**成片**时间轴上占的区间。
  ///
  /// **跳过的是画面，不是时间**：这些单元照样占着它们在成片里的位置，
  /// 后面的单元不许因此往前挪。2026-09-08 真机上就是挪了——用户把手加的
  /// 单元拖到最前面，一按播放直接从 U2 开始，时间线画到 01:46 而播放器只到
  /// 01:36，他以为软件把他加的那一段吃了。
  ///
  /// 播放头走到这些区间要**停下来并点名**，不是悄悄滑过去。用户原话：
  /// 「你提醒他就好了呀，你必须得选个视频，他这个部分才能播放。」
  final List<UnplayableSpan> unplayable;

  /// 整条成片有多长——**含那些放不了的段**。画面轨末尾算不出它
  final int composedTotalMs;

  /// 每个单元在**成片**上占的 [起, 止)。换方案时靠它记住「我停在哪儿」
  final Map<int, (int, int)> unitRanges;

  const TrackPlan({
    this.video = const [],
    this.voice = const [],
    this.bgm = const [],
    this.bgmMissing = const [],
    this.sourceStemMissing = const [],
    this.materialStemMissing = const [],
    this.skippedEmptyUnits = const [],
    this.unplayable = const [],
    this.composedTotalMs = 0,
    this.unitRanges = const {},
    this.voiceVolume = 1.0,
  });

  static const empty = TrackPlan();

  /// 换一条画面轨，别的一概不动（规格化用，见 [PreviewNormalizer]）
  TrackPlan withVideo(List<TrackSegment> next) => TrackPlan(
        video: List.unmodifiable(next),
        voice: voice,
        bgm: bgm,
        bgmMissing: bgmMissing,
        sourceStemMissing: sourceStemMissing,
        materialStemMissing: materialStemMissing,
        skippedEmptyUnits: skippedEmptyUnits,
        unplayable: unplayable,
        composedTotalMs: composedTotalMs,
        unitRanges: unitRanges,
        voiceVolume: voiceVolume,
      );

  bool get isEmpty => video.isEmpty && voice.isEmpty && bgm.isEmpty;

  /// 成片总长。
  ///
  /// **不能只按画面轨末尾算**：还没挑素材的那几段没有画面可放，却照样占着
  /// 成片里的位置。只按画面算的话，末尾会比时间线短一截（真机上短了 10s）
  int get totalMs {
    final byVideo = video.isEmpty ? 0 : video.last.endMs;
    return byVideo > composedTotalMs ? byVideo : composedTotalMs;
  }

  /// 换方案时的位置锚点：**(单元下标, 单元内偏移, 当时这个单元有多长)**。
  ///
  /// 直接记成片毫秒不行——新方案的总长一变，同一个毫秒对应的内容就完全不是
  /// 同一处了，用户点一下 ★ 就被扔到片子的别处。
  ///
  /// 也**不能绕原片时刻**：那要走「原片 → 成片」的换算，而那个方向是病态的
  /// （开区间边界会落到相邻段上，调过序后彻底失效，见
  /// `docs/2026-09-08-成片时间轴重构-TRD.md` 二、2.2）。而且垫黑场那一段的
  /// 「原片区间」本来就是假的，锚在上面必然错。
  ///
  /// **带上当时的长度是为了按比例还原**：整体替换把 4 秒的单元换成 2 秒的
  /// 素材，人看到一半是 1 秒处；取消替换之后「一半」应该是 2 秒处，
  /// 而不是还停在 1 秒（那才走了四分之一）。长度没变时按比例算恰好等于
  /// 原样搬过去，不引入误差。
  (int, int, int)? anchorAt(int composedMs) {
    for (final e in unitRanges.entries) {
      if (composedMs >= e.value.$1 && composedMs < e.value.$2) {
        return (e.key, composedMs - e.value.$1, e.value.$2 - e.value.$1);
      }
    }
    return null;
  }

  /// 把锚点还原成新方案里的成片毫秒。单元没了就落到片头——
  /// 悄悄跳到片尾是最糟的，用户会以为片子被截断了
  int composedAt((int, int, int) anchor) {
    final range = unitRanges[anchor.$1];
    if (range == null) return 0;
    final span = range.$2 - range.$1;
    if (span <= 0) return range.$1;
    final was = anchor.$3;
    final into = was <= 0
        ? anchor.$2
        : (anchor.$2 * span / was).round();
    return range.$1 + into.clamp(0, span - 1);
  }


  /// 成片时刻 → 原片时刻。**换方案时要靠它记住「我停在哪儿」**：
  /// 直接记成片毫秒的话，新方案的总长一变，同一个毫秒对应的内容就完全不是
  /// 同一处了——用户点一下 ★ 就被扔到片子的别处。
  int toSourceMs(int composedMs) {
    for (final segment in video) {
      if (segment.covers(composedMs)) return segment.sourceMsAt(composedMs);
    }
    return video.isEmpty ? composedMs : video.last.sourceMsAt(video.last.endMs - 1);
  }


  /// [ms] 时刻该播哪一段配乐；没有就返回 null
  BgmTrackSegment? bgmAt(int ms) {
    for (final segment in bgm) {
      if (segment.clip.covers(ms)) return segment;
    }
    return null;
  }


}
