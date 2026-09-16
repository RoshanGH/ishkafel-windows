import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/export/export_plan.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';

/// 换过素材的那一镜，字幕该从**这个单元的底片**的转写里取——它替代的正是
/// 底片的那一段。
///
/// 2026-09-15 真机导出一条才发现：预览里有字、导出来没有。根因是拿
/// 「这一段画面从哪儿剪」（baseCandidateId，换过素材的那一镜是 null）
/// 当了字幕的判据，于是换过素材的镜头一律取不到字幕。
void main() {
  List<SemanticUnit> units() => [
        const SemanticUnit(
          uid: 'u0',
          index: 0,
          startMs: 0,
          endMs: 16300,
          transcript: '底片转出来的台词',
          hasSource: false,
          baseCandidateId: 114799,
          shots: [
            Shot(startMs: 0, endMs: 4400),
            Shot(startMs: 4400, endMs: 7567),
            Shot(startMs: 7567, endMs: 16300),
          ],
        ),
      ];

  List<ExportSegment> segs() => ExportPlanner.enumerate(
        units: units(),
        replacements: [
          UnitReplacement.perShot({
            1: [106868]
          })
        ],
        materialDurations: const {114799: 16300, 106868: 12200},
      ).single.segments;

  test('换过素材的那一镜也带着单元的底片——字幕靠它', () {
    final replaced = segs().firstWhere((s) => s.candidateId == 106868);

    expect(replaced.unitBaseCandidateId, 114799,
        reason: '这一镜替代的正是底片的那一段，台词该从底片的转写里取');
    expect(replaced.baseCandidateId, isNull,
        reason: '画面是从新素材剪的，不是从底片剪');
  });

  test('坑位给的是素材内偏移——用单元坐标会取空', () {
    final replaced = segs().firstWhere((s) => s.candidateId == 106868);

    expect(replaced.baseStartMs, 4400);
  });

  test('没换素材的那几镜两样都有：画面从底片剪，字幕也从底片取', () {
    final kept = segs().where((s) => s.candidateId == null).toList();

    expect(kept, hasLength(2));
    for (final s in kept) {
      expect(s.baseCandidateId, 114799);
      expect(s.unitBaseCandidateId, 114799);
    }
  });

  test('没固定底片的单元一个都不带', () {
    final plain = ExportPlanner.enumerate(
      units: [
        const SemanticUnit(
            uid: 'a',
            index: 0,
            startMs: 0,
            endMs: 4000,
            transcript: '一句台词',
            shots: [Shot(startMs: 0, endMs: 4000)])
      ],
      replacements: [
        UnitReplacement.perShot({
          0: [9]
        })
      ],
      materialDurations: const {9: 3000},
    ).single.segments;

    expect(plain.single.unitBaseCandidateId, isNull);
  });
}
