import '../replacement/unit_base.dart';
import '../analysis/providers.dart' show AsrSentence;
import '../export/composed_timeline.dart';
import '../replacement/replacement_plan.dart';
import 'slot_subtitles.dart';
import 'subtitle_track.dart';

/// 预览画面上**此刻**该显示的那一行字；不该出字时返回 null。
///
/// **为什么要有这个函数**：字幕原来是 ffmpeg 烧进变速切片里的，
/// 于是调一次字号、挪一次位置就要重渲一遍切片、换一次播放源——转圈几秒、
/// 播放头弹回片头（2026-09-09 用户原话：「每次都要有一个加载的动效然后跳转
/// 到第一帧，这个跳转太煞笔了」）。预览要的是**看得准**，不是看的就是成片
/// 那几个字节：Flutter 直接在画面上叠一层实时画，改样式零 ffmpeg、
/// 零换源。导出那条路照旧烧录（见 `export_runner`）。
///
/// 出字的判据只有一条：**这一镜的画面是我们换上去的**。没换过的镜头，
/// 字幕本来就烧在原素材的像素里，再叠一层就是两行字打架。
String? previewSubtitleAt({
  required int composedMs,
  required ComposedTimeline timeline,
  required List<UnitReplacement> replacements,
  required SubtitleTrack track,
  required List<AsrSentence> sentences,
}) {
  final units = timeline.units;
  for (var u = 0; u < units.length; u++) {
    // 整体替换的那一段整个换成了另一条素材，原片的镜头切分已经不存在，
    // 也没有我们烧的字幕（见 `docs/术语表.md` 的「整体替换」）。
    //
    // **判据是 isSolidBlock 而不是 isReplaced**：固定过底片的单元
    // `isReplaced` 也为真（画面确实已经不是原片了），但它**有自己的镜头
    // 切分**，每一镜都能单独换素材、都该出字幕。用 isReplaced 的话整个
    // 单元在这儿被跳过，预览画面上一个字都不出——时间线的字幕轨却照画，
    // 于是「轨上有、画面上没有」（2026-09-16 真机）
    if (timeline.isSolidBlock(u)) continue;
    final shots = units[u].shots;
    for (var s = 0; s < shots.length; s++) {
      final start = timeline.composedShotStart(u, s);
      final end = timeline.composedShotEnd(u, s);
      if (start == null || end == null) continue;
      if (composedMs < start || composedMs >= end) continue;

      // 落到这一镜了——就地判完直接返回，不再往后找
      final plan = u < replacements.length ? replacements[u] : null;
      if (plan == null ||
          plan.mode != ReplacementMode.perShot ||
          plan.shotPreviewId(s) == null) {
        return null; // 画面是原素材的，字幕也归它
      }

      final lines = subtitleLinesForSlot(
        track: track,
        sentences: sentences,
        unitUid: units[u].uid,
        shotIndex: s,
        slotStartMs: shots[s].startMs,
        slotEndMs: shots[s].endMs,
        // 预览要和导出看到同一份（见 [subtitleLinesForSlot]）：底片是素材
        // 时不拿原片那份 ASR 硬凑，字幕从**底片自己的转写**里取，
        // 坑位也换成素材内偏移
        onMaterialBase: hasOwnBaseShots(units[u]),
        baseSentences: units[u].baseSentences,
        baseSlotStartMs: shots[s].startMs - units[u].startMs,
        baseSlotEndMs: shots[s].endMs - units[u].startMs,
      );
      // 行的时间轴以坑位开头为 0（见 [subtitleLinesInSlot]）
      final rel = composedMs - start;
      for (final line in lines) {
        if (rel >= line.startMs && rel < line.endMs) return line.text;
      }
      return null;
    }
  }
  return null;
}
