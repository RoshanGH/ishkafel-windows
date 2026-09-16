import '../presentation/user_facing_exception.dart';
import '../script/script_doc.dart';
import '../script/skipped_lines_summary.dart';
import '../script/shot_coverage.dart';

/// 把方案翻译成「剪映视角」的轨道计划——纯数据，不碰文件、不碰 JSON。
///
/// **这一层的唯一职责：把 ishkafel 里的结果原样搬过去。**
/// 用户在这边调的每个数（音量、倍率、框选起点），进剪映后必须还是那个数。
/// 剪映不是我们的下游渲染器，是用户接着干活的地方——他打开工程看到的第一眼，
/// 就该等于他在 ishkafel 里刚才看到的样子。
///
/// **为什么不复用 `TrackPlan`**：预览轨里的变速镜头指向的是预渲染好的对齐
/// 切片（见 `ShotSource` 注释），那是烧死的画面。喂给剪映就等于把「可以再调
/// 的倍率」变成「改不了的素材」——正好毁掉进剪映的意义。所以画面段一律从
/// [ScriptDoc] 的镜头直接构造：原始素材 + 框选起点 + 倍率，三样都留给用户。

/// 数据不对就抛它，绝不自己代偿。消息是给人看的，必须点名到行和镜。
class JianyingPlanException implements UserFacingException {
  @override
  final String message;
  const JianyingPlanException(this.message);
  @override
  String toString() => message;
}

/// 画面段：在成片 [atMs] 起占 [durationMs]，播 [path] 的
/// [sourceStartMs] 起、[sourceDurationMs] 那一段，按 [speed] 倍速。
class JyVideoSegment {
  final String path;
  final int atMs;
  final int durationMs;
  final int sourceStartMs;

  /// 这一段要吃掉多少素材 = [durationMs] × [speed]。
  /// 剪映靠 source/target 两个时长之比认出倍率，两个都得给对
  final int sourceDurationMs;

  final double speed;

  /// 素材原声音量。**唯一来源是 `doc.sourceVolumeFor`**，这里不许另算
  final double volume;

  /// 这条素材本身有多长（素材库展示用）。0 = 还不知道
  final int sourceTotalMs;

  const JyVideoSegment({
    required this.path,
    required this.atMs,
    required this.durationMs,
    required this.sourceStartMs,
    required this.sourceDurationMs,
    required this.speed,
    required this.volume,
    this.sourceTotalMs = 0,
  });

  int get endMs => atMs + durationMs;
}

/// 声音段（口播 / 配乐共用）
class JyAudioSegment {
  final String path;
  final int atMs;
  final int durationMs;
  final int sourceStartMs;
  final double volume;

  /// 曲子本身有多长（配乐用；0 = 不知道）
  final int sourceTotalMs;

  const JyAudioSegment({
    required this.path,
    required this.atMs,
    required this.durationMs,
    this.sourceStartMs = 0,
    required this.volume,
    this.sourceTotalMs = 0,
  });
}

/// 一屏字幕
class JyTextSegment {
  final String text;
  final int atMs;
  final int durationMs;
  const JyTextSegment(
      {required this.text, required this.atMs, required this.durationMs});
}

/// 四条轨，与剪映的轨道一一对应
class JianyingPlan {
  /// 画面轨，**从下往上**排：`videoTracks.first` 是底轨，最后一条盖在最上面。
  ///
  /// 替换裂变要把一个位置的所有候选都摆进同一份工程里——同一时间位置上
  /// 挑了几条素材就有几条轨，人在剪映里把上面那条关掉，下面那条就露出来。
  /// 脚本成片只有一条轨，那是这个结构的退化情形。
  final List<List<JyVideoSegment>> videoTracks;

  final List<JyAudioSegment> voice;
  final List<JyAudioSegment> bgm;
  final List<JyTextSegment> text;

  /// 进了草稿的行（0 起）→ 它在成片上的起点
  final Map<int, int> lineStarts;

  const JianyingPlan({
    this.videoTracks = const [],
    this.voice = const [],
    this.bgm = const [],
    this.text = const [],
    this.lineStarts = const {},
  });

  /// 单轨的便捷构造（脚本成片那条线一直是单轨）
  JianyingPlan.single({
    List<JyVideoSegment> video = const [],
    this.voice = const [],
    this.bgm = const [],
    this.text = const [],
    this.lineStarts = const {},
  }) : videoTracks = video.isEmpty ? const [] : [List.unmodifiable(video)];

  /// 底轨。成片时长、素材清点这些都以它为准——它是唯一铺满全片的那条
  List<JyVideoSegment> get video =>
      videoTracks.isEmpty ? const [] : videoTracks.first;

  /// 所有轨上的段落，清点素材用
  Iterable<JyVideoSegment> get allVideo => videoTracks.expand((t) => t);

  int get totalMs => video.isEmpty ? 0 : video.last.endMs;
  bool get isEmpty => videoTracks.isEmpty || video.isEmpty;
}

/// 把方案拼成剪映轨道计划。
///
/// [sourceOf] 给出这一镜的本地素材路径；返回 null = 还没就绪（下载中/失败），
/// 直接抛错点名——**导出工程不是预览，不许少一段**。
JianyingPlan buildJianyingPlan(
  ScriptDoc doc, {
  required String? Function(LineShot shot) sourceOf,

  /// 这一行的配音文件；null = 这一行没有配音（画面行就是如此）
  String? Function(ScriptLine line)? voiceOf,

  /// 配乐曲子的本地路径与时长；null = 还没下载好
  String? Function(int materialId)? bgmOf,
}) {
  final video = <JyVideoSegment>[];
  final voice = <JyAudioSegment>[];
  final text = <JyTextSegment>[];
  final lineStarts = <int, int>{};
  var cursorMs = 0;

  // **先把「缺镜头 / 缺时长」一次说清**，再往下逐镜细看。
  //
  // 原来是遇到第一行有问题就抛，于是四行都没挑镜头时只报「第 2 行」——
  // 人补完第 2 行再点，又说第 3 行，来回试（2026-09-10 真机走查）。
  // 这一类问题一眼能看全，就该一次报全。
  if (jianyingBlockingReason(doc) case final blocked?) {
    throw JianyingPlanException(blocked);
  }

  for (var i = 0; i < doc.lines.length; i++) {
    final line = doc.lines[i];
    // 纯空行（既没台词也没镜头）不占时间，也不值得点名
    if (line.text.trim().isEmpty && line.shots.isEmpty) continue;
    // 铺不满一律阻断——与预览/成片同一把尺（lineShotGaps），不在这儿另立规矩。
    // 绝不能自己算个倍率填上：那是把「数据有问题」偷偷变成「画面被拉慢了」，
    // 用户在剪映里看到的就不再是他的方案
    final gaps = lineShotGaps(line, lineIndex: i);
    if (gaps.isNotEmpty) {
      final g = gaps.first;
      throw JianyingPlanException(
          '第 ${i + 1} 行第 ${g.shotIndex + 1} 镜的画面只有 ${_sec(g.usableMs)} 秒，'
          '铺不满 ${_sec(g.allocMs)} 秒（差 ${_sec(g.gapMs)} 秒）——'
          '换条长一点的素材、放慢这一镜，或把它截短');
    }

    lineStarts[i] = cursorMs;
    var at = cursorMs;
    for (var j = 0; j < line.shots.length; j++) {
      final shot = line.shots[j];
      final path = sourceOf(shot);
      if (path == null) {
        throw JianyingPlanException(
            '第 ${i + 1} 行第 ${j + 1} 镜的素材还没就绪（下载未完成），'
            '等素材备齐再生成剪映草稿');
      }
      final alloc = shot.allocMs!;
      video.add(JyVideoSegment(
        path: path,
        atMs: at,
        durationMs: alloc,
        // 框选起点、倍率、吃掉的素材量——三样都是用户的结果，原样带走
        sourceStartMs: shot.trimStartMs,
        sourceDurationMs: shot.consumedSourceMs,
        speed: shot.speed,
        // 音量只此一处：显示、预览、成片、剪映读的是同一个数
        volume: doc.sourceVolumeFor(line, shot),
        sourceTotalMs: shot.durationMs ?? 0,
      ));
      at += alloc;
    }

    final lineMs = at - cursorMs;
    final voicePath = voiceOf?.call(line);
    if (voicePath != null) {
      voice.add(JyAudioSegment(
        path: voicePath,
        atMs: cursorMs,
        durationMs: lineMs,
        volume: doc.voiceVolume,
        sourceTotalMs: line.voiceover?.durationMs ?? 0,
      ));
    }
    // 字幕屏走 `subtitleScreensAt` —— 预览、卡片、成片、剪映同一份。
    // 字数上限由**生效样式的字号**推导，跟着行覆盖走，不在这里另定
    final style = line.subtitleOverride ?? doc.subtitle;
    for (final s in line.subtitleScreensAt(maxChars: style.maxCharsPerScreen)) {
      if (s.text.isEmpty) continue; // '' = 这一屏人为不出字
      text.add(JyTextSegment(
        text: s.text,
        atMs: cursorMs + s.startMs,
        durationMs: s.endMs - s.startMs,
      ));
    }
    cursorMs = at;
  }

  return JianyingPlan(
    videoTracks: [List.unmodifiable(video)],
    voice: List.unmodifiable(voice),
    bgm: List.unmodifiable(_buildBgm(doc, lineStarts, cursorMs, bgmOf)),
    text: List.unmodifiable(text),
    lineStarts: Map.unmodifiable(lineStarts),
  );
}

/// 配乐：段落按行区间铺，音量走 `doc.bgmVolumeOf`（段上是相对值，乘总控）
List<JyAudioSegment> _buildBgm(
  ScriptDoc doc,
  Map<int, int> lineStarts,
  int totalMs,
  String? Function(int materialId)? bgmOf,
) {
  if (bgmOf == null || doc.bgmSegments.isEmpty) return const [];
  final out = <JyAudioSegment>[];
  for (final seg in doc.bgmSegments) {
    // 「不要配乐」的段根本不落盘（见 bgmRail），所以到这儿的段一定有曲子
    final material = seg.material;
    final start = lineStarts[seg.startLine];
    if (start == null) continue; // 这一段的起始行没进草稿
    final end = _lineEnd(doc, lineStarts, seg.endLine, totalMs);
    if (end <= start) continue;
    final found = bgmOf(material.id);
    if (found == null) {
      // 配乐没下好就直接失败：成片里少一段垫乐是「静默降级」，
      // 工程里少一段同样是——用户在剪映里不会知道本该有配乐
      throw JianyingPlanException('配乐《${material.name}》还没下载好，等它备齐再生成剪映草稿');
    }
    out.add(JyAudioSegment(
      path: found,
      atMs: start,
      durationMs: end - start,
      volume: doc.bgmVolumeOf(seg.volume),
      // 曲子多长数据里就有，不必再探一次文件
      sourceTotalMs: material.durationMs,
    ));
  }
  return out;
}

/// 某一行在成片上的结束时刻（= 下一个进了草稿的行的起点，没有则片尾）
int _lineEnd(
    ScriptDoc doc, Map<int, int> lineStarts, int lineIndex, int totalMs) {
  var best = totalMs;
  for (final e in lineStarts.entries) {
    if (e.key > lineIndex && e.value < best) best = e.value;
  }
  return best;
}

String _sec(int ms) => (ms / 1000).toStringAsFixed(1);

/// 生成剪映草稿前的整体预检：**一次说清所有缺镜头 / 缺时长的行**。
///
/// 返回 null 表示这一关过了（逐镜的细节问题——铺不满、素材没下完——
/// 在 [buildJianyingPlan] 里继续逐个拦，那些是少数情况）。
///
/// 界面也该在点「剪映」之前先问一句，别等人等完素材归集才说不行。
String? jianyingBlockingReason(ScriptDoc doc) {
  final problems = <int, String>{};
  for (var i = 0; i < doc.lines.length; i++) {
    final line = doc.lines[i];
    if (line.text.trim().isEmpty && line.shots.isEmpty) continue;
    if (line.shots.isEmpty) {
      problems[i] = '还没挑镜头';
      continue;
    }
    if (line.shots.any((s) => s.allocMs == null)) {
      problems[i] = '有镜头还没分时长';
    }
  }
  if (problems.isEmpty) return null;

  final byReason = <String, List<int>>{};
  for (final e in problems.entries) {
    (byReason[e.value] ??= []).add(e.key + 1);
  }
  final lines = [
    for (final e in byReason.entries) '${lineNumberRanges(e.value)}${e.key}',
  ];
  return '${lines.join('\n')}\n补齐这些再生成剪映草稿。';
}
