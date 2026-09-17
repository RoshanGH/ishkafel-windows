import '../replacement/replacement_plan.dart';

/// 成片里**哪几段会有台词字幕**。
///
/// 两种替换模式在这件事上不一样，而这个差别在界面上和命令行里都看不见：
///
/// - **镜头替换**：变速对齐回原坑位，台词字幕重渲上去——原片的字幕烧在
///   被换掉的画面里，不重渲那一段就没字了
/// - **整体替换**：原样接上、时长随候选，和原坑位对不齐。按原片时间戳算
///   的字幕没法直接烧上去，**于是那一段成片里没有台词字幕**
///
/// 后果是一条片子里字幕断断续续。而这个事实还决定了另一件事有多严重：
/// 素材自带烧录字时，**会烧台词字幕的段落**是两层字打架、片子废；
/// 不烧的段落只是「片子里放着别人的文案」——不算废，但也不能交。
class SubtitleCoverage {
  /// 这几个单元的成片段落会有台词字幕（下标从 0 起）
  final List<int> unitsWith;

  /// 这几个单元不会有——画面换掉了，原片字幕跟着没了，也没重渲
  final List<int> unitsWithout;

  const SubtitleCoverage({required this.unitsWith, required this.unitsWithout});
}

SubtitleCoverage subtitleCoverage(List<UnitReplacement> replacements) {
  final with_ = <int>[];
  final without = <int>[];
  for (var i = 0; i < replacements.length; i++) {
    final r = replacements[i];
    switch (r.mode) {
      case ReplacementMode.keepOriginal:
        // 画面没换，原片的字幕还烧在上面——不算缺
        break;
      case ReplacementMode.whole:
        // 一个候选都没选时画面照旧，也不算缺
        if (r.wholeCandidateIds.isNotEmpty) without.add(i);
      case ReplacementMode.perShot:
        if (r.shotCandidateIds.values.any((v) => v.isNotEmpty)) with_.add(i);
    }
  }
  return SubtitleCoverage(
      unitsWith: List.unmodifiable(with_),
      unitsWithout: List.unmodifiable(without));
}

/// 「这几段成片里没有台词字幕」的说法。都有就返回 null。
///
/// **点名是哪几个单元**：笼统一句「部分段落没有字幕」等于让人自己去数。
String? subtitleGapNotice(List<UnitReplacement> replacements) {
  final gaps = subtitleCoverage(replacements).unitsWithout;
  if (gaps.isEmpty) return null;
  final labels = [for (final i in gaps) 'U${i + 1}'].join('、');
  // **不许用 ** 加粗**：这句话是摆在导出确认页上给人看的，而 Text 一个字
  // 都不解析，星号会原样显示出来（2026-09-16 真机就是这样）。要强调就把
  // 结论放到句首，或者用「」
  return '$labels 这 ${gaps.length} 个单元用的是「整体替换」，'
      '成片里那几段没有台词字幕。'
      '整体替换原样接上、时长随候选，和原坑位对不齐，'
      '按原片时间戳算的字幕没法直接烧上去。'
      '要这几段也有字幕，改用镜头替换（它会变速对齐回原坑位并重渲字幕）。';
}
