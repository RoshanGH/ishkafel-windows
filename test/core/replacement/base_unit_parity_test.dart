import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/providers.dart' show AsrSentence, AsrWord;
import 'package:ishkafel/core/audio/material_audio.dart';
import 'package:ishkafel/core/export/composed_timeline.dart';
import 'package:ishkafel/core/export/export_plan.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/models/tag_trace.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';
import 'package:ishkafel/core/replacement/unit_base.dart';
import 'package:ishkafel/core/subtitle/slot_subtitles.dart';
import 'package:ishkafel/core/subtitle/subtitle_track.dart';

/// **「把它当成参考视频里的一段，该走的流程全部走完」**——产品负责人的原话。
///
/// 所以这一组不测「底片这条线自己对不对」，而是把同一段口播、同一套切点
/// 摆两遍：一个当参考视频的台词语义单元，一个当固定了底片的插入段，
/// 然后**逐项比对两边的产出**。只要有一项不一样，这条线就还没做完。
void main() {
  /// 一句口播的词级时间戳，[base] 是这一段的起点
  List<AsrWord> saidAt(int base) => [
        AsrWord(startMs: base, endMs: base + 200, text: '大'),
        AsrWord(startMs: base + 200, endMs: base + 400, text: '肠'),
        AsrWord(startMs: base + 400, endMs: base + 600, text: '杆'),
        AsrWord(startMs: base + 600, endMs: base + 800, text: '菌'),
        AsrWord(startMs: base + 900, endMs: base + 1100, text: '灭'),
        AsrWord(startMs: base + 1100, endMs: base + 1300, text: '火'),
      ];

  /// 这一段在时间轴上从 10 秒开始，长 6 秒，切成三镜
  const unitStart = 10000;
  const spanMs = 6000;
  const cuts = [0, 2000, 4000, spanMs];

  List<Shot> shots() => [
        for (var i = 0; i < cuts.length - 1; i++)
          Shot(
            startMs: unitStart + cuts[i],
            endMs: unitStart + cuts[i + 1],
            tags: const ['厨房情景'],
            description: '第 $i 镜',
            productBrand: 'Dettol',
            boundaryTrace: const BoundaryTrace(
                sceneScore: 0.6, histDistance: 0.4, decision: 'confirmed'),
            materialAudioMode: MaterialAudioMode.background,
            sourceAudioMode: MaterialAudioMode.vocals,
          ),
      ];

  /// A：参考视频里的一段——台词来自原片 ASR，画面来自原片
  SemanticUnit originUnit() => SemanticUnit(
        uid: 'a',
        index: 0,
        startMs: unitStart,
        endMs: unitStart + spanMs,
        transcript: '大肠杆菌灭火',
        tags: const ['主卖点解决方案'],
        shots: shots(),
      );

  /// B：自己加的那一段——台词来自底片转写，画面来自底片素材
  SemanticUnit baseUnit() => SemanticUnit(
        uid: 'b',
        index: 0,
        startMs: unitStart,
        endMs: unitStart + spanMs,
        transcript: '大肠杆菌灭火',
        tags: const ['主卖点解决方案'],
        hasSource: false,
        baseCandidateId: 7,
        baseSentences: [
          AsrSentence(
              startMs: 0, endMs: 1300, text: '大肠杆菌灭火', words: saidAt(0)),
        ],
        shots: shots(),
      );

  final originSentences = [
    AsrSentence(
        startMs: unitStart,
        endMs: unitStart + 1300,
        text: '大肠杆菌灭火',
        words: saidAt(unitStart)),
  ];

  group('单元身上挂的东西：一项都不能少', () {
    test('台词、标签两边都有', () {
      expect(baseUnit().transcript, originUnit().transcript);
      expect(baseUnit().tags, originUnit().tags);
    });

    test('每一镜的标签、画面描述、产品品牌、切点依据都有', () {
      for (var i = 0; i < 3; i++) {
        final o = originUnit().shots[i];
        final b = baseUnit().shots[i];
        expect(b.tags, o.tags);
        expect(b.description, o.description);
        expect(b.productBrand, o.productBrand);
        expect(b.boundaryTrace?.decision, o.boundaryTrace?.decision);
      }
    });

    test('两层镜头声音的档位都设得上', () {
      for (var i = 0; i < 3; i++) {
        expect(baseUnit().shots[i].materialAudioMode,
            originUnit().shots[i].materialAudioMode);
        expect(baseUnit().shots[i].sourceAudioMode,
            originUnit().shots[i].sourceAudioMode);
      }
    });
  });

  group('字幕：同一段口播，两边取出来必须一字不差', () {
    List<String> linesOf({required bool onBase, required int shotIndex}) {
      final unit = onBase ? baseUnit() : originUnit();
      final shot = unit.shots[shotIndex];
      return subtitleLinesForSlot(
        track: const SubtitleTrack.empty(),
        sentences: onBase ? const [] : originSentences,
        unitUid: unit.uid,
        shotIndex: shotIndex,
        slotStartMs: shot.startMs,
        slotEndMs: shot.endMs,
        onMaterialBase: onBase,
        baseSentences: onBase ? unit.baseSentences : null,
        baseSlotStartMs: onBase ? shot.startMs - unit.startMs : null,
        baseSlotEndMs: onBase ? shot.endMs - unit.startMs : null,
      ).map((l) => '${l.startMs}-${l.endMs}:${l.text}').toList();
    }

    for (var i = 0; i < 3; i++) {
      test('第 ${i + 1} 镜', () {
        expect(linesOf(onBase: true, shotIndex: i),
            linesOf(onBase: false, shotIndex: i),
            reason: '同一句话、同样的切点，参考视频那条路取到什么，'
                '这条路就该取到什么');
      });
    }

    test('头一镜真的取到了字，不是两边都空', () {
      expect(linesOf(onBase: false, shotIndex: 0), isNotEmpty);
    });
  });

  group('导出：段落结构与字幕来源', () {
    List<ExportSegment> segsOf(SemanticUnit unit) => ExportPlanner.enumerate(
          units: [unit],
          replacements: [
            UnitReplacement.perShot({
              1: [9]
            })
          ],
          materialDurations: const {7: spanMs, 9: 3000},
        ).single.segments;

    test('都拆成三段，坑位一样', () {
      final o = segsOf(originUnit());
      final b = segsOf(baseUnit());

      expect(b.length, o.length);
      for (var i = 0; i < o.length; i++) {
        expect(b[i].startMs, o[i].startMs);
        expect(b[i].endMs, o[i].endMs);
        expect(b[i].candidateId, o[i].candidateId);
        expect(b[i].durationMs, o[i].durationMs);
      }
    });

    test('换过素材的那一镜，两边都认得出「要重渲字幕」', () {
      final o = segsOf(originUnit()).firstWhere((s) => s.candidateId == 9);
      final b = segsOf(baseUnit()).firstWhere((s) => s.candidateId == 9);

      expect(o.shotIndex, isNotNull);
      expect(b.shotIndex, isNotNull, reason: '整段替换才是 null，镜头替换必须有');
      expect(b.unitBaseCandidateId, 7, reason: '字幕从底片的转写里取');
    });
  });

  group('成片时间轴', () {
    test('两边的镜头都能定位到成片上', () {
      final o = ComposedTimeline.of(
          units: [originUnit()], wholeDurations: const {});
      final b =
          ComposedTimeline.of(units: [baseUnit()], wholeDurations: const {});

      for (var i = 0; i < 3; i++) {
        expect(b.composedShotStart(0, i), o.composedShotStart(0, i));
        expect(b.composedShotEnd(0, i), o.composedShotEnd(0, i));
      }
    });

    test('都不画成一整块——镜头是真实存在的', () {
      final b =
          ComposedTimeline.of(units: [baseUnit()], wholeDurations: const {});

      expect(b.isSolidBlock(0), isFalse);
      expect(hasOwnBaseShots(baseUnit()), isTrue);
    });
  });
}
