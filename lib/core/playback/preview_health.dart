/// **预览平不平稳，用数字说了算。**
///
/// 产品负责人 2026-09-16：「每次都是在开发一些其他功能以后，这种问题就又
/// 出现。」——闸挡住了代码层面的绕过、守卫挡住了规则被拆，而这一层挡的是
/// **真实播放效果的退化**：哪天有人改了代理规格、新素材类型带来了别的
/// 毛病、或者机器慢到接缝撑不住，代码扫描都看不出来，只有真播一遍才知道。
///
/// 判据全部来自播放日志（`scripts/preview_health.sh` 负责真播一遍并收集）。
/// 每一条都对应一个**他能感觉到的**症状，不是内部指标。
library;

/// 一次体检的结论
class PreviewHealth {
  /// 画面输出被重建了几次。**每一次就是他看到的「闪一下」**
  ///
  /// 根因永远是同一个：这一段和上一段规格不同（分辨率/帧率），
  /// 播放器要重建解码器和 GL 纹理
  final int videoRebuilds;

  /// 跟随轨被硬拽了几次。**每一次就是他听到的「一句话说了两遍」**
  ///
  /// 正常的追赶是悄悄调速，不该出现硬拽。出现了只有两种可能：偏差大到
  /// 1.2 秒以上（那不是漂移，是换了地方），或者调速那条路坏了
  final int hardSeeks;

  /// 有几段没能统一到预览规格。这几段的接缝处必然闪
  final int offSpecSegments;

  /// 生成代理失败了几次。失败就意味着那一段退回原规格
  final int proxyFailures;

  /// 音画偏差的取值范围（毫秒，负 = 声音慢于画面）。
  ///
  /// **不含起播那几秒**：刚按下播放时口播轨要起播、要追到位，偏差大是
  /// 必然的（实测头一两秒到过 100ms），而那时画面才刚出来，人不会在那一刻
  /// 判断音画同不同步。追赶算法本来也需要几秒收敛。
  /// 稳态之后才是他真正在听的东西
  final int minDriftMs;
  final int maxDriftMs;

  /// 主时钟采样点之间最长的一次间隔（毫秒）。定时器是 1 秒一次，
  /// 明显超过 1 秒说明主时钟在那一刻**卡住了**——接缝顿挫就是这么量的
  final int worstTickMs;

  /// 一共取到几个采样点。太少说明根本没播起来，那时别的数字都不作数
  final int samples;

  const PreviewHealth({
    required this.videoRebuilds,
    required this.hardSeeks,
    required this.offSpecSegments,
    required this.proxyFailures,
    required this.minDriftMs,
    required this.maxDriftMs,
    required this.worstTickMs,
    required this.samples,
  });

  /// 声音最多晚了画面多少（毫秒）。0 表示从没晚过
  int get worstLagMs => minDriftMs < 0 ? -minDriftMs : 0;

  /// 声音最多早了画面多少（毫秒）。0 表示从没早过
  int get worstLeadMs => maxDriftMs > 0 ? maxDriftMs : 0;
}

/// 判定用的线。**每一条都写清楚为什么是这个数**——否则下一个人只会把它
/// 调大让检查通过
abstract final class PreviewHealthLimits {
  /// 画面闪一次都不许有。规格统一之后它就该是 0，不是「少一点」
  static const int maxVideoRebuilds = 0;

  /// 硬拽一次都不许有。正常播放全程都该是调速追赶
  static const int maxHardSeeks = 0;

  static const int maxOffSpecSegments = 0;
  static const int maxProxyFailures = 0;

  /// 音画偏差上限。**两个方向不一样**，这不是偷懒，是人耳就这样：
  ///
  /// - **声音晚于画面**容忍度高——现实里远处的声音本来就晚，人一辈子都在
  ///   适应它。广播级标准（ITU-R BT.1359）给到 125ms 才算可察觉
  /// - **声音早于画面**容忍度低——现实中不存在这种事，45ms 就能听出别扭
  ///
  /// 各留一点余量：滞后取 100ms、超前取 40ms。真机实测规格统一后是
  /// −69 ~ +20ms，均值 −11ms。**哪天滞后过了 100ms，那就是真出事了**
  static const int maxAudioLagMs = 100;
  static const int maxAudioLeadMs = 40;

  /// 主时钟一次采样最多允许多久。定时器 1 秒一跳，留 150ms 的调度抖动；
  /// 再多就说明主时钟在接缝处真的停住了
  static const int maxTickMs = 1150;

  /// 至少要取到这么多采样点，否则这一轮不作数（根本没播起来）
  static const int minSamples = 20;
}

/// 这一轮体检没过的地方。空列表 = 全过
List<String> previewHealthFailures(PreviewHealth h) => [
      if (h.samples < PreviewHealthLimits.minSamples)
        '只取到 ${h.samples} 个采样点（至少要 ${PreviewHealthLimits.minSamples} 个）'
            '——根本没播起来，这一轮不作数',
      if (h.videoRebuilds > PreviewHealthLimits.maxVideoRebuilds)
        '画面输出重建了 ${h.videoRebuilds} 次——那就是看得见的「闪一下」',
      if (h.hardSeeks > PreviewHealthLimits.maxHardSeeks)
        '跟随轨被硬拽了 ${h.hardSeeks} 次——那就是听得见的「一句话说了两遍」',
      if (h.offSpecSegments > PreviewHealthLimits.maxOffSpecSegments)
        '有 ${h.offSpecSegments} 段没统一到预览规格——它们的接缝处必然闪',
      if (h.proxyFailures > PreviewHealthLimits.maxProxyFailures)
        '生成代理失败 ${h.proxyFailures} 次——失败的那几段退回了原规格',
      if (h.worstLagMs > PreviewHealthLimits.maxAudioLagMs)
        '声音最多晚了画面 ${h.worstLagMs}ms'
            '（上限 ${PreviewHealthLimits.maxAudioLagMs}ms）',
      if (h.worstLeadMs > PreviewHealthLimits.maxAudioLeadMs)
        '声音最多早了画面 ${h.worstLeadMs}ms'
            '（上限 ${PreviewHealthLimits.maxAudioLeadMs}ms）'
            '——声音跑到画面前面比晚更容易听出别扭',
      if (h.worstTickMs > PreviewHealthLimits.maxTickMs)
        '主时钟有一次停了 ${h.worstTickMs}ms（上限 ${PreviewHealthLimits.maxTickMs}ms）'
            '——接缝处卡住了',
    ];

/// 起播之后跳过几个采样点再开始算偏差。
///
/// 一秒一个采样点，跳 3 个 = 给追赶三秒收敛。**这不是为了让检查好过**：
/// 画面闪、硬拽这两项一个都不跳，从第一帧就算
const int _warmUpSamples = 3;

/// 从播放日志里量出这几个数。
///
/// 只认日志里那几句固定的话——它们是产品代码里**本来就要打**的
/// （「换了什么必须留痕：这套『谁在什么时候播哪个文件的哪一段』是产品的
/// 核心，出问题时没有它就只能靠猜」），不是为体检额外加的埋点
PreviewHealth readPreviewHealth(String log) {
  var rebuilds = 0;
  var hardSeeks = 0;
  var offSpec = 0;
  var proxyFail = 0;
  var minDrift = 0;
  var maxDrift = 0;
  var worstTick = 0;
  final ticks = <int>[];

  final drift = RegExp(r'偏差 (-?\d+)ms');
  final master = RegExp(r'主时钟 (\d+)ms、口播轨');
  final offSpecCount = RegExp(r'画面轨有 (\d+) 段没能统一');
  var seen = 0;

  for (final line in log.split('\n')) {
    // mpv 重建视频输出。**这一行不是我们打的**，是 media_kit 打的——
    // 正因为不是自己人打的，它不会因为谁改了日志文案就失效
    if (line.contains('TextureGL: resize')) rebuilds++;
    if (line.contains('换了地方')) hardSeeks++;
    if (line.contains('生成预览代理失败')) proxyFail++;
    if (offSpecCount.firstMatch(line) case final m?) {
      final n = int.tryParse(m.group(1)!) ?? 0;
      if (n > offSpec) offSpec = n;
    }
    if (drift.firstMatch(line) case final m?) {
      seen++;
      if (seen > _warmUpSamples) {
        final d = int.parse(m.group(1)!);
        if (d < minDrift) minDrift = d;
        if (d > maxDrift) maxDrift = d;
      }
    }
    if (master.firstMatch(line) case final m?) {
      ticks.add(int.parse(m.group(1)!));
    }
  }

  // **第一个采样点不算**：它量的是「从按下播放到第一次对表」，
  // 不是接缝停顿
  for (var i = 1; i < ticks.length; i++) {
    final gap = ticks[i] - ticks[i - 1];
    if (gap > worstTick) worstTick = gap;
  }

  return PreviewHealth(
    videoRebuilds: rebuilds,
    hardSeeks: hardSeeks,
    offSpecSegments: offSpec,
    proxyFailures: proxyFail,
    minDriftMs: minDrift,
    maxDriftMs: maxDrift,
    worstTickMs: worstTick,
    samples: ticks.length,
  );
}
