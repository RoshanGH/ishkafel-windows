import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';
import 'package:ishkafel/features/workbench/candidate_badge.dart';

void main() {
  group('「替换素材」tab 上的角标是「当前这个单元已选了几条素材」', () {
    test('只选了替换方式、一条素材都没挑时不显示角标', () {
      final text = candidateBadgeText([
        UnitReplacement.perShot(const {}),
        UnitReplacement.keepOriginal(),
      ], unitIndex: 0);

      expect(text, isNull,
          reason: '真机复现：U1 切到「镜头替换」但六个镜头全是「原片」，'
              '角标却显示 1——用户点进去找不到那一条到底是哪个');
    });

    test('数的是素材条数，不是设了替换方式的单元数', () {
      final plan = [
        UnitReplacement.whole(const [101, 102, 103]),
        UnitReplacement.perShot(const {
          0: [201],
          2: [202, 203],
        }),
      ];

      expect(candidateBadgeText(plan, unitIndex: 0), '3');
      expect(candidateBadgeText(plan, unitIndex: 1), '3');
    });

    test('只数当前这个单元的——隔壁挑的不算在它头上', () {
      // 产品负责人 2026-09-16 真机：U1 整体替换只选了 1 条，角标写着 3
      // ——另外 2 条是 U2 的某一镜挑的
      final plan = [
        UnitReplacement.whole(const [101]),
        UnitReplacement.perShot(const {
          0: [201, 202],
        }),
      ];

      expect(candidateBadgeText(plan, unitIndex: 0), '1');
      expect(candidateBadgeText(plan, unitIndex: 1), '2');
    });

    test('没选中任何单元时不显示——那时面板里也没有谁的候选可言', () {
      final plan = [UnitReplacement.whole(const [101])];

      expect(candidateBadgeText(plan), isNull);
      expect(candidateBadgeText(plan, unitIndex: 9), isNull,
          reason: '下标越界（刚删掉那个单元）时也不能崩');
    });

    test('一条都没有时为 null，而不是「0」', () {
      expect(candidateBadgeText(const [], unitIndex: 0), isNull);
      expect(
          candidateBadgeText([UnitReplacement.keepOriginal()], unitIndex: 0),
          isNull,
          reason: '显示一个 0 会被读成「有 0 条可用素材」的坏消息');
    });

    test('同一条素材在不同镜头各算一次（它确实要放两处）', () {
      final text = candidateBadgeText([
        UnitReplacement.perShot(const {
          0: [201],
          1: [201],
        }),
      ], unitIndex: 0);

      expect(text, '2');
    });

    test('数目很大时不撑破角标', () {
      final text = candidateBadgeText([
        UnitReplacement.whole(List.generate(150, (i) => i)),
      ], unitIndex: 0);

      expect(text, '99+');
    });
  });
}
