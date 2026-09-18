import '../ffmpeg/media_spec.dart';
import '../ffmpeg/proxy_spec.dart';
import '../log/app_log.dart';
import 'track_plan.dart';

/// **画面轨的每一段必须是同一个规格。**
///
/// ## 这不是优化，是预览能不能平稳播放的前提
///
/// 画面轨是一条 `edl://`：把好几个源文件描述成一条流。段与段规格不一致时，
/// 播放器在接缝处要**重建解码器、重建视频输出**——
///
/// - 分辨率一变就重建 GL 纹理（真机日志：`TextureGL: resize: 720.0x1280.0`），
///   看上去就是画面闪一下
/// - 重建期间主时钟停住（真机量到 25ms），而口播轨是独立实例、照常往前播，
///   于是相对超前；下一次对表发现偏差过线，就把口播轨**往回 seek**——
///   那一小段声音重播一遍，听感是「一句话说了两遍」
///
/// 产品负责人 2026-09-16 的原话：「无论我怎么调换位置，无论我怎么去替换，
/// 替换上来的这些东西都得是像剪映的那个时序帧的轨道一样，无论在任何地方、
/// 任何衔接处都是平稳在播放的。」
///
/// ## 为什么要有这道闸，而不是各处自觉
///
/// 这条规则**早就定下来了**：[ProxySpec] 的文档写着「预览链路上的每一段都
/// 转成我们说了算的同一个规格」，`ProxyBuilder` 也造好了、已合规的零成本放行。
/// 可它反复失效：
///
/// - 2026-08-10 诊断过一次（变速镜头在替换点加速播放，量到 1.67× 连跑 6.5 秒）
/// - 2026-08-25 在**口播轨**上实施过一次（`PreviewVoiceNormalizer`，
///   48kHz 立体声），画面轨没做
/// - 2026-09-16 又回来了：整体替换用的素材在重开 app 之后走的是
///   `materials/` 里的原始下载（1080×1920），和 720×1280 的代理、切片混播
///
/// 每次修的都是**那一处**，没有任何东西守着规则本身。产品负责人：「每次都是
/// 在开发一些其他功能以后，这种问题就又出现。」——所以这次把它做成**管线上
/// 一道必经的闸**：播放器只接受 [NormalizedTrackPlan]，而这个类型只能由
/// [PreviewNormalizer] 产出。以后谁加新的素材来源（底片、拼片、脚本成片、
/// 还没想到的），都必然经过这里。

/// 已经逐段验过规格的轨道计划。**播放器只认它**。
///
/// 构造函数是私有的——拿不到一个没验过的实例，这是编译期的保证。
class NormalizedTrackPlan {
  final TrackPlan plan;

  /// 哪几段没能统一到预览规格（取不到代理、转不动）。
  ///
  /// **不静默**：这几段在接缝处仍会闪一下，上层要把它说出来。空列表 = 全齐
  final List<String> offSpec;

  const NormalizedTrackPlan._(this.plan, this.offSpec);

  /// 空轨（没有可播的东西）。它没有任何段落，自然也就没有接缝
  static const empty = NormalizedTrackPlan._(TrackPlan.empty, []);

  bool get allOnSpec => offSpec.isEmpty;
}

/// 把一份轨道计划里的画面段统一到预览规格。
///
/// **正常情况下这里一次转码都不会发生**：素材下载时就转过代理了
/// （见 workbench_page 的 `_buildMediaCache`），原片也有代理，变速切片本来
/// 就是按预览规格渲的。这道闸是**兜底 + 强制**——它保证的是「漏了的那一条
/// 会被逮住」，而不是「在这里现转」。
class PreviewNormalizer {
  /// 读一个文件的规格。读不出来返回 null
  final Future<MediaSpec?> Function(String path) probe;

  /// 把一个文件转成预览代理，返回可播路径。转不动就返回原路径
  /// （[ProxyBuilder.build] 正是这个约定）
  final Future<String> Function(String path) toProxy;

  /// 成功读到的规格。临时读不到不能缓存，否则文件就绪后也无法恢复。
  /// 逐段 ffprobe 会拖慢换轨；文件重新生成时由 forget 清掉旧规格。
  final Map<String, MediaSpec> _specs = {};

  /// 已确认合规的路径：原路径 → 该播的那一份。失败降级不能混入。
  final Map<String, String> _resolved = {};

  /// 原样放行：一段都不验、一段都不换。
  ///
  /// **只给测试和精简装配用**。真装了闸却让它放行，等于没设防——所以它是
  /// 一个显式的、扫得到的名字，而不是「normalizer 传 null」那种看不出来的
  /// 缺省。守卫盯着它不许出现在正常的装配路径上
  final bool passthrough;

  PreviewNormalizer({required this.probe, required this.toProxy})
    : passthrough = false;

  PreviewNormalizer.passthrough()
    : probe = _neverProbe,
      toProxy = _neverProxy,
      passthrough = true;

  static Future<MediaSpec?> _neverProbe(String _) async => null;
  static Future<String> _neverProxy(String path) async => path;

  /// 清掉探测缓存。文件可能被重新生成（重导代理、重渲切片）时调用
  void forget(String path) {
    _specs.remove(path);
    _resolved.removeWhere(
      (source, resolved) => source == path || resolved == path,
    );
  }

  Future<NormalizedTrackPlan> normalize(TrackPlan plan) async {
    // 放行档：原样过，也不记 offSpec——它本来就没验过，报「有几段不合规」
    // 反而是假消息
    if (passthrough) return NormalizedTrackPlan._(plan, const []);
    if (plan.video.isEmpty) {
      return NormalizedTrackPlan._(plan, const []);
    }
    final offSpec = <String>[];
    // 同轮重复片段共享失败结果，避免对同一个失败源反复转码；下轮允许重试。
    final failed = <String>{};
    final video = <TrackSegment>[];
    for (final segment in plan.video) {
      final resolved = failed.contains(segment.source)
          ? segment.source
          : await _resolve(segment.source, failed);
      if (failed.contains(segment.source)) {
        offSpec.add(_shortName(segment.source));
      }
      video.add(
        resolved == segment.source ? segment : segment.withSource(resolved),
      );
    }
    if (offSpec.isNotEmpty) {
      // **说出来**：这几段在接缝处会闪。不报的话，下一个人又要从头查一遍
      AppLog.warn(
        '画面轨有 ${offSpec.length} 段没能统一到预览规格，'
        '接缝处会闪一下：${offSpec.join('、')}',
      );
    }
    return NormalizedTrackPlan._(
      plan.withVideo(video),
      List.unmodifiable(offSpec),
    );
  }

  Future<MediaSpec?> _probe(String path) async {
    if (_specs[path] case final spec?) return spec;
    final spec = await probe(path);
    if (spec != null) _specs[path] = spec;
    return spec;
  }

  Future<String> _resolve(String path, Set<String> failed) async {
    if (_resolved[path] case final done?) return done;
    final spec = await _probe(path);
    if (ProxySpec.matches(spec)) {
      return _resolved[path] = path; // 已经合规，一个字节都不用动
    }
    // 不合规：取它的代理。**绝大多数时候这只是查一次缓存**——
    // 素材下载时已经转过，内容指纹一样就直接命中
    final proxy = await toProxy(path);
    if (proxy != path) {
      final proxySpec = await _probe(proxy);
      if (ProxySpec.matches(proxySpec)) {
        return _resolved[path] = proxy;
      }
      // 转码器可能在同一路径重建代理，失败规格不能挡住下轮重新校验。
      _specs.remove(proxy);
    }
    // 转不动（或转出来还是不合规）：如实记下来，仍然播原文件——
    // 宁可留着那一下接缝顿挫，也不能让这一段整个放不了
    failed.add(path);
    return path;
  }

  /// 报给人看的时候只留文件名：完整路径又长又不说明问题
  static String _shortName(String path) => path.split('/').last;
}
