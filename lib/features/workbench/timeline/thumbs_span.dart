import '../../../core/models/semantic_unit.dart';
import '../../../core/replacement/unit_base.dart';

/// 胶片条（画面缩略图轨）铺在**原片**上覆盖多长。
///
/// 缩略图是从原片按等间隔抽出来的，所以它们代表的是「原片 0 ~ 原片时长」。
/// 不能拿 `geometry.durationMs`（**成片**总长）去等分——手动加的单元在原片上
/// 不存在，它占的那段时间里没有任何原片画面可放，算进去整条胶片条就整体
/// 压扁、和上面的单元块全部对不齐（2026-09-07 真机 bug）。
///
/// 返回 0 表示这条任务没有原片（空白任务，或全是手加的单元）——那时整条
/// 胶片条不该画。
int sourceSpanMs(List<SemanticUnit> units) {
  var max = 0;
  for (final u in units) {
    // 手加的单元原片上没有它，它的 startMs/endMs 只是时间线上的占位
    if (!u.hasSource) continue;
    if (u.endMs > max) max = u.endMs;
  }
  return max;
}

/// 一格缩略图画在哪儿：第 [imageIndex] 张，横向 [left]~[right] 像素
typedef ThumbCell = ({int imageIndex, double left, double right});

/// 把 [count] 张原片缩略图摆到**成片**时间轴上。
///
/// 缩略图是从原片按等间隔抽的，代表「原片 0 ~ 原片时长」。以前的做法是把
/// 每一格的原片时刻直接 `msToPx` 过去——那走的是病态的「原片 → 成片」换算，
/// 调过序之后整条胶片条会错位到别人身上（见
/// `docs/2026-09-08-成片时间轴重构-TRD.md` 二、2.2）。
///
/// 现在**按单元分段放**：一个单元在成片上占哪一段是按下标问出来的（确定），
/// 它取自原片的哪一段也是已知的（`startMs/endMs`），两者一比例就得到这个单元
/// 里每一格该落在哪儿。手加的单元没有原片来源，那一段留空——本来就没有
/// 原片画面可放。
///
/// [pxOfUnit] 给出第 i 个单元在成片上的左右像素（由 `track_px.dart` 提供）。
List<ThumbCell> thumbCells({
  required List<SemanticUnit> units,
  required int count,
  required (double, double) Function(int unitIndex) pxOfUnit,
}) {
  if (count <= 0) return const [];
  final spanMs = sourceSpanMs(units);
  if (spanMs <= 0) return const [];

  final cells = <ThumbCell>[];
  final cellMs = spanMs / count;
  for (var u = 0; u < units.length; u++) {
    final unit = units[u];
    if (!unit.hasSource) continue;
    // 固定过底片的那一段画面来自另一条素材，原片同一个时间点的缩略图
    // 跟它毫不相干——那儿由底片自己的缩略图铺（见 `baseThumbImages`），
    // 两份一起画就是叠着两段不同的画面
    if (hasOwnBaseShots(unit)) continue;
    final srcStart = unit.startMs;
    final srcLen = unit.endMs - unit.startMs;
    if (srcLen <= 0) continue;
    final (uLeft, uRight) = pxOfUnit(u);
    final uWidth = uRight - uLeft;
    if (uWidth <= 0) continue;

    // 与这个单元的原片区间有交集的那几格
    final first = (srcStart / cellMs).floor().clamp(0, count - 1);
    for (var i = first; i < count; i++) {
      final tStart = cellMs * i;
      if (tStart >= unit.endMs) break;
      final tEnd = cellMs * (i + 1);
      if (tEnd <= srcStart) continue;
      final a = (tStart < srcStart ? srcStart : tStart) - srcStart;
      final b = (tEnd > unit.endMs ? unit.endMs : tEnd) - srcStart;
      cells.add((
        imageIndex: i,
        left: uLeft + uWidth * a / srcLen,
        right: uLeft + uWidth * b / srcLen,
      ));
    }
  }
  return cells;
}
