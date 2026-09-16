import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/features/workbench/timeline/thumbs_span.dart';

/// **胶片条按单元分段放，不再拿原片时刻直接换算像素。**
///
/// 以前每一格的原片时刻直接 `msToPx` 过去，走的是病态的「原片 → 成片」换算，
/// 调过序之后整条胶片条会错位到别人身上。
void main() {
  /// U1 手加（原片里没有它）排在最前；U2 取自原片 0~10s；U3 取自 10~20s
  List<SemanticUnit> units() => const [
        SemanticUnit(
            index: 0,
            startMs: 20000,
            endMs: 30000,
            transcript: '',
            hasSource: false),
        SemanticUnit(index: 1, startMs: 0, endMs: 10000, transcript: '一'),
        SemanticUnit(index: 2, startMs: 10000, endMs: 20000, transcript: '二'),
      ];

  /// 成片 30s → 300px（10px/s）：U1 0~100，U2 100~200，U3 200~300
  (double, double) px(int i) => switch (i) {
        0 => (0, 100),
        1 => (100, 200),
        2 => (200, 300),
        _ => (0, 0),
      };

  test('原片 20s 分 4 格，每格 5s：前两格进 U2，后两格进 U3', () {
    final cells = thumbCells(units: units(), count: 4, pxOfUnit: px);

    expect(cells.map((c) => c.imageIndex), [0, 1, 2, 3]);
    expect(cells[0].left, 100, reason: '第 0 格是原片 0~5s，落在 U2 的前半');
    expect(cells[0].right, 150);
    expect(cells[1].left, 150);
    expect(cells[2].left, 200, reason: '第 2 格是原片 10~15s，落在 U3 的前半');
    expect(cells[3].right, 300);
  });

  test('手加的单元那一段留空——本来就没有原片画面可放', () {
    final cells = thumbCells(units: units(), count: 4, pxOfUnit: px);

    expect(cells.every((c) => c.right <= 100 ? false : true), isTrue);
    expect(cells.any((c) => c.left < 100), isFalse,
        reason: 'U1 占的是成片 0~100px，那里不该有原片缩略图');
  });

  test('调序不影响正确性：单元换个位置，格子跟着它走', () {
    // U3 排到最前
    final reordered = [units()[2], units()[0], units()[1]];
    final cells = thumbCells(
        units: reordered, count: 4, pxOfUnit: px);

    // U3（原片 10~20s，第 2、3 格）现在占成片 0~100px
    final third = cells.where((c) => c.imageIndex == 2).single;
    expect(third.left, 0);
    expect(third.right, 50);
  });

  test('没有原片来源的任务不画', () {
    const blank = [
      SemanticUnit(
          index: 0,
          startMs: 0,
          endMs: 10000,
          transcript: '',
          hasSource: false),
    ];

    expect(thumbCells(units: blank, count: 4, pxOfUnit: px), isEmpty);
  });

  test('格数为 0 时不画', () {
    expect(thumbCells(units: units(), count: 0, pxOfUnit: px), isEmpty);
  });

  test('固定过底片的那一段不铺原片缩略图——画面已经换成另一条素材了', () {
    // 真机（拼片任务 U1）：hasSource 为真、同时固定了底片。只判 hasSource
    // 的话，原片同一个时间点的缩略图会铺到一段毫不相干的画面上，
    // 而底片自己的缩略图也在那儿画——两份画面叠着
    final pinned = [
      units()[0],
      // U2 取自原片 0~10s，现在固定了底片、切成两镜
      units()[1].copyWith(baseCandidateId: 114799, shots: const [
        Shot(startMs: 0, endMs: 5000),
        Shot(startMs: 5000, endMs: 10000),
      ]),
      units()[2],
    ];
    final cells = thumbCells(units: pinned, count: 4, pxOfUnit: px);

    expect(cells.where((c) => c.imageIndex == 0), isEmpty,
        reason: '第 0 格是原片 0~5s，落在 U2 身上——它已经换底片了');
    expect(cells.where((c) => c.imageIndex == 1), isEmpty);
    expect(cells.where((c) => c.imageIndex == 2), isNotEmpty,
        reason: 'U3 没动，照旧铺');
  });
}
