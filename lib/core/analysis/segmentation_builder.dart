import '../models/semantic_unit.dart';
import '../models/shot.dart';
import '../models/unit_uid.dart';
import 'boundary_snapper.dart';

/// 语义单元草稿（LLM 语义分组的输出：粗边界 + 台词）
class UnitDraft {
  final int startMs;
  final int endMs;
  final String transcript;

  const UnitDraft({
    required this.startMs,
    required this.endMs,
    required this.transcript,
  });

  Map<String, dynamic> toJson() =>
      {'startMs': startMs, 'endMs': endMs, 'transcript': transcript};

  /// 宽松解析：**任何一处不对就返回 null**，由调用方当作「没有缓存」。
  /// 缓存读错比重算一次贵得多——那会把另一条片子的切分安到这条上
  static UnitDraft? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final start = raw['startMs'];
    final end = raw['endMs'];
    if (start is! int || end is! int || end <= start) return null;
    return UnitDraft(
      startMs: start,
      endMs: end,
      transcript: raw['transcript'] is String ? raw['transcript'] as String : '',
    );
  }
}

/// 两层构树（纯算法）：
/// 1. 内部单元边界经 BoundarySnapper 吸附（首边界恒为 0，尾边界恒为片长）
/// 2. 每单元内部按落入其中的镜头边界切出 shots，保证严格包含与无缝覆盖
class SegmentationBuilder {
  final BoundarySnapper snapper;

  const SegmentationBuilder({this.snapper = const BoundarySnapper()});

  List<SemanticUnit> build({
    required List<UnitDraft> drafts,
    required List<int> shotBoundaryMs,
    required List<int> silenceValleyMs,
    required int videoDurationMs,
    required double fps,
  }) {
    if (drafts.isEmpty) return const [];

    // 镜头边界先统一帧对齐、去重、排序：吸附结果与 inner 分割必须使用同一份
    // 对齐后的边界，否则吸附得到帧对齐值而 inner 分割仍用原始值，会在两者
    // 差值处产出毫秒级 sliver shot，且该边界不满足"帧对齐"约束。
    final alignedShotBoundaries = shotBoundaryMs
        .map((b) => snapper.snapToFrame(b, fps))
        .toSet()
        .toList()
      ..sort();

    final frameWidthMs = fps > 0 ? (1000 / fps).round() : 1;

    final bounds = <int>[0];
    for (var i = 0; i < drafts.length - 1; i++) {
      var b = snapper.snap(
        drafts[i].endMs,
        shotBoundaries: alignedShotBoundaries,
        silenceValleys: silenceValleyMs,
        fps: fps,
      );
      // 吸附导致越过前一边界时回退为原位帧对齐；仍越界则强制递增一帧宽度
      if (b <= bounds.last) b = snapper.snapToFrame(drafts[i].endMs, fps);
      if (b <= bounds.last) b = bounds.last + frameWidthMs;

      // 夹紧到 [上一边界+一帧, 片长-一帧]，避免 draft.endMs 逼近/超出片长时
      // 帧对齐把内部边界推到 >= videoDurationMs，产出零/负时长单元。
      // 若该区间本身无效（片长过短装不下所有边界），退化为「上一边界+一帧」，
      // 仅保证严格递增，这是最简单的正确兜底。
      final lowerBound = bounds.last + frameWidthMs;
      final upperBound = videoDurationMs - frameWidthMs;
      if (upperBound >= lowerBound) {
        if (b < lowerBound) b = lowerBound;
        if (b > upperBound) b = upperBound;
      } else {
        b = lowerBound;
      }
      // 兜底：无论如何不得达到或超过片长，保证末尾追加的 videoDurationMs 严格更大
      if (b >= videoDurationMs) b = videoDurationMs - 1;
      bounds.add(b);
    }
    bounds.add(videoDurationMs);

    final units = <SemanticUnit>[];
    for (var i = 0; i < drafts.length; i++) {
      final start = bounds[i];
      final end = bounds[i + 1];
      final inner =
          alignedShotBoundaries.where((b) => b > start && b < end).toList()
            ..sort();
      final edges = [start, ...inner, end];
      units.add(SemanticUnit(
        // **身份在这儿发**：切分出来那一刻就有，别等落库再读回来补
        // （`unit_uid.dart` 开头写的就是这一条）。中间这段空窗期正好覆盖
        // 「切分好放人进去 → 后台打标 → 把标签合并回来」——那一步按身份
        // 配对，源头不发身份就一个都配不上（2026-09-16）
        uid: newUnitUid(),
        index: i,
        startMs: start,
        endMs: end,
        transcript: drafts[i].transcript,
        shots: [
          for (var k = 0; k < edges.length - 1; k++)
            Shot(startMs: edges[k], endMs: edges[k + 1]),
        ],
      ));
    }
    return List.unmodifiable(units);
  }
}
