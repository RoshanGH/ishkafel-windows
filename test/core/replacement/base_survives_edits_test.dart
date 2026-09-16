import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/providers.dart' show AsrSentence;
import 'package:ishkafel/core/editing/unit_reorder.dart';
import 'package:ishkafel/core/export/composed_timeline.dart';
import 'package:ishkafel/core/export/export_plan.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';

/// **按用户真实走法验一遍**：他说的路径是「添加一个台词语义单元 → 把它换个
/// 位置 → 选底片 → 切割 → 对某一镜做镜头替换」。
///
/// 「换个位置」这一步以前没验过。插入段的 `startMs/endMs` 是塞在原片末尾的
/// 占位，而调序只改下标不改它——底片镜头的坐标是「单元起点 + 素材内偏移」，
/// 两者必须一起对上，否则画面会取到素材里另一个时间点。
void main() {
  /// U0/U1 取自原片；U2 是插入段，底片 16.3 秒切成 3 镜
  List<SemanticUnit> units() => [
        const SemanticUnit(
            uid: 'a',
            index: 0,
            startMs: 0,
            endMs: 5000,
            transcript: '第一句',
            shots: [Shot(startMs: 0, endMs: 5000)]),
        const SemanticUnit(
            uid: 'b',
            index: 1,
            startMs: 5000,
            endMs: 10000,
            transcript: '第二句',
            shots: [Shot(startMs: 5000, endMs: 10000)]),
        const SemanticUnit(
          uid: 'c',
          index: 2,
          startMs: 10000,
          endMs: 20000,
          transcript: '底片转出来的话',
          hasSource: false,
          baseCandidateId: 7,
          baseSentences: [
            AsrSentence(startMs: 500, endMs: 9000, text: '底片转出来的话', words: []),
          ],
          shots: [
            Shot(startMs: 10000, endMs: 14000),
            Shot(startMs: 14000, endMs: 20000),
            Shot(startMs: 20000, endMs: 26300),
          ],
        ),
      ];

  group('把插入段拖到最前之后', () {
    List<SemanticUnit> moved() => moveUnit(units(), from: 2, to: 0);

    test('底片、镜头、转写一样不少地跟着走', () {
      final u = moved().first;

      expect(u.uid, 'c');
      expect(u.index, 0);
      expect(u.baseCandidateId, 7);
      expect(u.shots, hasLength(3));
      expect(u.baseSentences, hasLength(1));
      expect(u.startMs, 10000,
          reason: '插入段的起止是占位，调序不该动它——一动，'
              '按它算的素材内偏移就全错了');
    });

    test('成片上它排在最前，长度还是底片的长度', () {
      final axis =
          ComposedTimeline.of(units: moved(), wholeDurations: const {});

      expect(axis.startOf(0), 0);
      expect(axis.durationOf(0), 16300);
      expect(axis.startOf(1), 16300, reason: '后面的跟着往后挪');
      expect(axis.totalMs, 26300);
    });

    test('导出段落取的还是素材内偏移 0 / 4000 / 10000', () {
      final segs = ExportPlanner.enumerate(
        units: moved(),
        replacements: [
          UnitReplacement.keepOriginal(),
          UnitReplacement.keepOriginal(),
          UnitReplacement.keepOriginal(),
        ],
        materialDurations: const {7: 16300},
      ).single.segments.where((s) => s.unitIndex == 0).toList();

      expect(segs.map((s) => s.baseStartMs).toList(), [0, 4000, 10000]);
      expect(segs.every((s) => s.baseCandidateId == 7), isTrue);
    });

    test('调序之后再换某一镜的素材，字幕来源仍然是底片', () {
      final segs = ExportPlanner.enumerate(
        units: moved(),
        replacements: [
          UnitReplacement.perShot({
            1: [9]
          }),
          UnitReplacement.keepOriginal(),
          UnitReplacement.keepOriginal(),
        ],
        materialDurations: const {7: 16300, 9: 3000},
      ).single.segments;

      final replaced = segs.firstWhere((s) => s.candidateId == 9);
      expect(replaced.unitBaseCandidateId, 7);
      expect(replaced.baseStartMs, 4000,
          reason: '这一镜替代的是底片 4~10 秒那一段，字幕要从那儿取词');
    });
  });
}
