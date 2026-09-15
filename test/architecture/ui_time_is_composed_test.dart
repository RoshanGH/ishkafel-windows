import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **界面上的时间数字一律成片时间。**
///
/// 2026-09-08 讨论，用户原话：「那每一次实际上它的时间都是不一致的……
/// 那么就把这个改成帧数吧，然后每次重新计算。」
///
/// 症结不是单位（本来就是 分:秒.帧），是**基准**：左栏和属性栏给的是原片
/// 时间，时间线和播放器给的是成片时间。同一镜属性栏写 00:45.03、时间线画在
/// 01:03——两个数谁也对不上谁，而且没有任何地方会报错。
///
/// 所以盯住：显示时间的地方不许直接拿 unit/shot 的 startMs 去格式化。
void main() {
  /// 主数字必须走成片轴的文件
  const displays = {
    'lib/features/workbench/unit_list_panel.dart',
    'lib/features/workbench/inspector_panel.dart',
  };

  test('左栏和属性栏都接了成片时间轴', () {
    for (final path in displays) {
      expect(
        File(path).readAsStringSync(),
        contains('ComposedTimeline'),
        reason: '$path 显示时间却没接成片轴，给的就是原片位置',
      );
    }
  });

  test('原片时间只出现在「取自原片」那一行里', () {
    // 主数字（镜头开始/结束、单元起止）一律走成片轴；原片位置单独一行、
    // 标清楚出处。两者混在同一个字段里正是这条 bug 的形态。
    for (final path in displays) {
      final src = File(path).readAsStringSync();
      final raw = RegExp(
        r'formatTimecode\((?:unit|shot)\.(?:start|end)Ms',
      ).allMatches(src).length;
      final labelled = '取自原片'.allMatches(src).length;

      expect(
        raw,
        lessThanOrEqualTo(labelled * 2),
        reason:
            '$path 里有 $raw 处直接格式化原片时间，'
            '而只有 $labelled 行标着「取自原片」——'
            '多出来的那些是摆在主位置上的原片时间',
      );
    }
  });

  test('时间码格式化只有一处实现', () {
    final offenders = <String>[];
    for (final f
        in Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))) {
      final path = f.path.replaceAll(r'\', '/');
      if (path == 'lib/core/time/timecode.dart') continue;
      if (path.contains('inspector_panel.dart')) continue; // 只是转出去
      if (f.readAsStringSync().contains('String formatTimecode(')) {
        offenders.add(f.path);
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          '又自己写了一份时间码格式化：\n${offenders.join('\n')}\n'
          '两份实现迟早不一样，而差的是帧位，肉眼看不出来',
    );
  });
}
