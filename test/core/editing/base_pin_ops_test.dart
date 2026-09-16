import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/providers.dart' show AsrSentence;
import 'package:ishkafel/core/editing/base_pin_ops.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';
import 'package:ishkafel/core/replacement/unit_base.dart';

SemanticUnit _inserted({int index = 1}) => SemanticUnit(
      uid: 'u$index',
      index: index,
      startMs: 10000,
      endMs: 16000,
      transcript: '',
      hasSource: false,
    );

SemanticUnit _fromSource({int index = 0}) => SemanticUnit(
      uid: 's$index',
      index: index,
      startMs: 0,
      endMs: 4000,
      transcript: '一句台词',
      shots: const [Shot(startMs: 0, endMs: 4000)],
    );

List<Shot> _cut() => const [
      Shot(startMs: 10000, endMs: 12000),
      Shot(startMs: 12000, endMs: 16000),
    ];

void main() {
  group('能不能切分这一段', () {
    test('挑了素材的插入段：可以——那条素材就是它的底片', () {
      expect(
        BasePinOps.segmentBlockedReason(
            unit: _inserted(), replacement: UnitReplacement.whole([7])),
        isNull,
      );
    });

    test('还没挑素材的插入段：说清楚下一步做什么', () {
      final why = BasePinOps.segmentBlockedReason(
          unit: _inserted(), replacement: UnitReplacement.keepOriginal());

      expect(why, isNotNull);
      expect(why, contains('挑'));
    });

    test('用原片的那一段：分镜早就切好了，不给重切', () {
      final why = BasePinOps.segmentBlockedReason(
          unit: _fromSource(), replacement: UnitReplacement.keepOriginal());

      expect(why, contains('原片'));
    });

    test('已经固定过底片的：可以再切（换底片走这条路）', () {
      final pinned = _inserted().copyWith(baseCandidateId: 7, shots: _cut());

      expect(
        BasePinOps.segmentBlockedReason(
            unit: pinned, replacement: UnitReplacement.whole([7])),
        isNull,
      );
    });
  });

  group('固定之前先算清楚作废什么', () {
    test('只选了一条：什么都不掉', () {
      final cost = BasePinOps.costOf(
          unit: _inserted(),
          replacement: UnitReplacement.whole([7]),
          candidateId: 7);

      expect(cost.isFree, isTrue);
    });

    test('选了三条：另外两条会被取消勾选', () {
      final cost = BasePinOps.costOf(
          unit: _inserted(),
          replacement: UnitReplacement.whole([7, 8, 9]),
          candidateId: 7);

      expect(cost.droppedCandidates, 2);
    });

    test('已经挑过镜头：那些选择会被清掉', () {
      final cost = BasePinOps.costOf(
        unit: _inserted(),
        replacement: UnitReplacement.perShot({
          0: [11],
          1: [12]
        }),
        candidateId: 7,
      );

      expect(cost.droppedShotPicks, 2);
    });
  });

  group('固定底片', () {
    test('记下底片是谁、镜头按它切', () {
      final (units, _) = BasePinOps.pin(
        [_fromSource(), _inserted()],
        [UnitReplacement.keepOriginal(), UnitReplacement.whole([7])],
        1,
        candidateId: 7,
        shots: _cut(),
      );

      expect(units[1].baseCandidateId, 7);
      expect(units[1].shots.length, 2);
      expect(hasOwnBaseShots(units[1]), isTrue);
    });

    test('别的单元一个字节都不动', () {
      final before = _fromSource();
      final (units, _) = BasePinOps.pin(
        [before, _inserted()],
        [UnitReplacement.keepOriginal(), UnitReplacement.whole([7])],
        1,
        candidateId: 7,
        shots: _cut(),
      );

      expect(units[0], before);
    });

    test('整体替换的候选清空——它们的角色由底片接管了', () {
      final (_, plans) = BasePinOps.pin(
        [_inserted()],
        [UnitReplacement.whole([7, 8, 9], previewId: 9)],
        0,
        candidateId: 7,
        shots: _cut(),
      );

      expect(plans[0].wholeCandidateIds, isEmpty,
          reason: '留着别的，成片会按别人的时长排，而镜头是按 7 切的');
    });

    test('切完直接落到镜头替换上——人下一步就是挑镜头', () {
      final (_, plans) = BasePinOps.pin(
        [_inserted()],
        [UnitReplacement.whole([7])],
        0,
        candidateId: 7,
        shots: _cut(),
      );

      expect(plans[0].mode, ReplacementMode.perShot);
    });

    test('底片记在单元身上，不靠方案记——切模式也丢不了', () {
      final (units, plans) = BasePinOps.pin(
        [_inserted()],
        [UnitReplacement.whole([7])],
        0,
        candidateId: 7,
        shots: _cut(),
      );

      expect(baseChoiceOf(unit: units[0], replacement: plans[0]),
          const MaterialBase(7));
    });

    test('新切的镜头还没打标：标成过期，重新打标会把它们捡起来', () {
      final (units, _) = BasePinOps.pin(
        [_inserted()],
        [UnitReplacement.whole([7])],
        0,
        candidateId: 7,
        shots: _cut(),
      );

      expect(units[0].tagsStale, isTrue);
    });

    test('下标越界：原样返回，不崩', () {
      final units = [_inserted()];
      final plans = [UnitReplacement.whole([7])];
      final (u, p) = BasePinOps.pin(units, plans, 9,
          candidateId: 7, shots: _cut());

      expect(u, same(units));
      expect(p, same(plans));
    });
  });

  group('换底片：先把旧的清干净', () {
    test('底片标记和镜头一起清掉', () {
      final pinned = _inserted().copyWith(baseCandidateId: 7, shots: _cut());
      final (units, _) = BasePinOps.unpin(
          [pinned], [UnitReplacement.whole([7])], 0);

      expect(units[0].baseCandidateId, isNull);
      expect(units[0].shots, isEmpty);
    });

    test('挂在旧镜头上的选择也清掉——那些镜头已经不存在了', () {
      final pinned = _inserted().copyWith(baseCandidateId: 7, shots: _cut());
      final (_, plans) = BasePinOps.unpin(
        [pinned],
        [
          UnitReplacement.perShot({
            0: [11]
          })
        ],
        0,
      );

      expect(plans[0].mode, ReplacementMode.keepOriginal);
      expect(plans[0].shotCandidateIds, isEmpty);
    });

    test('本来就没固定过：什么都不做', () {
      final units = [_inserted()];
      final plans = [UnitReplacement.whole([7])];
      final (u, p) = BasePinOps.unpin(units, plans, 0);

      expect(u, same(units));
      expect(p, same(plans));
    });

    test('清完之后底片回到回退链算出来的那张', () {
      final pinned = _inserted().copyWith(baseCandidateId: 7, shots: _cut());
      final (units, plans) = BasePinOps.unpin(
          [pinned], [UnitReplacement.whole([7])], 0);

      expect(
        baseChoiceOf(unit: units[0], replacement: plans[0]),
        const NoBase(),
        reason: '清掉之后这一段没挑素材了，要重新挑',
      );
    });
  });

  group('转写出来的台词要落进单元', () {
    const said = [
      AsrSentence(startMs: 40, endMs: 3320, text: '如果你以为它只能灭火李斯特菌，', words: []),
      AsrSentence(startMs: 3360, endMs: 8400, text: '那你就错了。', words: []),
    ];

    test('左栏、时间线、台词框读的都是它——不写就是三处空白', () {
      final (units, _) = BasePinOps.pin(
        [_inserted()],
        [UnitReplacement.whole([7])],
        0,
        candidateId: 7,
        shots: _cut(),
        sentences: said,
      );

      expect(units[0].transcript, '如果你以为它只能灭火李斯特菌，那你就错了。');
    });

    test('人自己填过的不覆盖——模型那份只是个起点', () {
      final mine = _inserted().copyWith(transcript: '我自己写的台词');
      final (units, _) = BasePinOps.pin(
        [mine],
        [UnitReplacement.whole([7])],
        0,
        candidateId: 7,
        shots: _cut(),
        sentences: said,
      );

      expect(units[0].transcript, '我自己写的台词');
    });

    test('没转出话来：台词还是空的，不硬凑', () {
      final (units, _) = BasePinOps.pin(
        [_inserted()],
        [UnitReplacement.whole([7])],
        0,
        candidateId: 7,
        shots: _cut(),
        sentences: const [],
      );

      expect(units[0].transcript, isEmpty);
    });

    test('换底片时台词跟着清——它是从那张底片转出来的', () {
      final pinned = _inserted().copyWith(
          baseCandidateId: 7, shots: _cut(), transcript: '底片转出来的话');
      final (units, _) = BasePinOps.unpin(
          [pinned], [UnitReplacement.whole([7])], 0);

      expect(units[0].transcript, isEmpty);
      expect(units[0].baseSentences, isNull);
    });
  });
}
