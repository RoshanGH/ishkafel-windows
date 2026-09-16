import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **挂在台词语义单元上的东西，一律按它自己的身份记。**
///
/// 产品负责人 2026-09-09：
///
/// > 这个台词语义单元应该有一个自己的编号，但不是 U1 U2 U3，因为它位置排序
/// > 是有可能会变的。它这个编号下的所有数据都是跟着这个编号走。
///
/// 半年里因为「按位置记」漏搬过三次，每次都是不报错、只有把片子导出来看一遍
/// 才发现：配音念错段落（09-07）、挑好的素材留在原来那一格（09-08）、
/// 手改字幕烧到别人的画面上（09-09）。
///
/// 现在四份都按身份记了。这条守卫盯的是**别再冒出第五种按位置记的**：
/// 存档里凡是「某个单元的什么」，键必须是 `unitUid`，不能是 `unitIndex`。
void main() {
  test('落盘的键里不许再出现 unitIndex', () {
    final offenders = <String>[];
    for (final path in [
      'lib/core/models/renew_task.dart',
      'lib/core/models/semantic_unit.dart',
      'lib/core/audio/voice_plan.dart',
      'lib/core/subtitle/subtitle_track.dart',
      'lib/core/replacement/replacement_plan.dart',
    ]) {
      final src = File(path).readAsStringSync();
      for (final line in src.split('\n')) {
        final code = line.trim();
        if (code.startsWith('//') || code.startsWith('///')) continue;
        // 只查**写出去**的那一侧：读老存档时认 unitIndex 是迁移，必须留着
        if (RegExp(r"'unitIndex':").hasMatch(code)) {
          offenders.add('$path: $code');
        }
      }
    }

    expect(offenders, isEmpty,
        reason: '这些地方还在按位置往存档里写「哪个单元的什么」。'
            '人一挪单元它就指错人，而且不报错：\n${offenders.join('\n')}');
  });

  /// 配乐是**唯一**还按下标记的一份，而且是故意的：它记的不是「某个单元的
  /// 什么」，是**一段区间**——「这几段连着铺一首曲子」。区间天生就是位置的
  /// 概念，把两端换成身份不会让它变简单：所有的重叠切分、相邻合并、拉伸
  /// 都要在位置上算，只会来回换算两遍。
  ///
  /// 而且挪动确实会改变「这一段盖住谁」——那是要跟人说清楚的事
  /// （`remapBgmAfterMove` 会把被打断的段落报出来），不是搬一下就完的。
  ///
  /// 这条测试把这个例外钉住：只剩配乐一份，再多一份就得回来重新想。
  test('还按位置搬的只剩配乐一份', () {
    final remaps = <String>[];
    for (final path in [
      'lib/core/editing/unit_reorder.dart',
      'lib/core/editing/blank_unit_removal.dart',
    ]) {
      final src = File(path).readAsStringSync();
      for (final line in src.split('\n')) {
        final m = RegExp(r'^\w[\w<>, ]* (remap|shift)(\w+)(After\w+)\(')
            .firstMatch(line);
        if (m != null) remaps.add(m.group(2)!);
      }
    }

    expect(remaps.toSet(), {'Bgm'},
        reason: '除了配乐，别的都该按单元的身份记、一份都不用搬。'
            '这里多出来一个，说明有人又加了一份按位置记的数据：$remaps');
  });

  test('打标结果写回必须按身份配对——跨过用户编辑的那一步最容易错', () {
    // 2026-09-16 真机：新加的空单元拖到第一位，还没做任何操作就凭空带上了
    // 隔壁那个的标签。两处都是「后台打标 → 重读任务 → 写回」，而写回按的是
    // 下标；重读回来的那份正是人改过的，下标早就换了一套人。
    //
    // 这两条路都跨越用户编辑，所以判据钉死在「按 uid 配对」上
    String codeOf(String path) => [
          for (final line in File(path).readAsStringSync().split('\n'))
            if (!line.trim().startsWith('//')) line,
        ].join('\n');

    // 后台补标签：跑完重读任务再写回，中间人可能加过单元、拖过顺序
    final resumer = codeOf('lib/features/tasks/tagging_resumer.dart');
    expect(resumer, contains('taggedByUid'),
        reason: '标签写回要按单元身份配对');
    expect(resumer.contains('tagged[i]'), isFalse,
        reason: '还在按下标从打标结果里取——重读回来的列表顺序早就变了，'
            '标签会糊到别人身上');

    // 分析流程的合并：打标占总时长七成，那七成里人就在时间线前面改
    final merge = codeOf('lib/core/analysis/tag_merge.dart');
    expect(merge, contains('byUid'), reason: '单元层要按身份建索引');
    expect(merge.contains('byIndex'), isFalse,
        reason: '还在按下标给打标结果建索引');
    // 镜头那层按下标是对的：传进去的是**同一个单元**的两份镜头列表，
    // 而且还校验了起止毫秒。镜头没有自己的身份，也不需要
  });

  test('身份在切分那一刻就发——别等落库读回来才补', () {
    // unit_uid.dart 开头写的就是「切分出来那一刻生成」，但源头一直没发，
    // 靠读档时 ensureUnitUids 兜底。那中间有一段空窗期：切分好放人进去、
    // 后台打标、把标签合并回来——全在落库与读档之间，单元一个身份都没有，
    // 按身份配对自然一个都配不上（2026-09-16）
    expect(File('lib/core/analysis/segmentation_builder.dart')
        .readAsStringSync(),
        contains('newUnitUid()'),
        reason: '切分产出的单元要当场带上身份');
  });
}
