import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/features/shared/shortcuts_cheatsheet.dart';
import 'package:ishkafel/features/workbench/workbench_shortcuts.dart';

/// **说得出的键必须真的绑上，绑上的键必须说得出。**
///
/// 2026-09-09 设计走查：JKL 走带、⇧←→ 一次 10 帧、Home/End 这些都实现了，
/// 界面上却没有任何地方说得出来——功能存在等于不存在。反过来更糟：清单和
/// 绑定各写各的，改了键位那份说明就成了谎话。
void main() {
  Set<LogicalKeyboardKey> boundKeys() => {
        for (final activator in workbenchPlaybackShortcuts.keys)
          if (activator is SingleActivator) activator.trigger,
      };

  test('速查表里提到的键，实际都绑上了', () {
    final bound = boundKeys();
    const mustBeBound = <LogicalKeyboardKey>[
      LogicalKeyboardKey.space,
      LogicalKeyboardKey.keyJ,
      LogicalKeyboardKey.keyK,
      LogicalKeyboardKey.keyL,
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.home,
      LogicalKeyboardKey.end,
      LogicalKeyboardKey.keyZ,
    ];

    for (final key in mustBeBound) {
      expect(bound, contains(key),
          reason: '速查表里写着 ${key.keyLabel}，实际没绑——那是在骗人');
    }
  });

  test('速查表本身不为空，每条都说清了干什么', () {
    expect(playbackShortcuts, isNotEmpty);
    for (final s in playbackShortcuts) {
      expect(s.keys.trim(), isNotEmpty);
      expect(s.what.trim(), isNotEmpty);
    }
  });

  test('Windows 速查表写 Ctrl，不把 Mac 的 Command 键展示给用户', () {
    final windows = playbackShortcutsFor('windows');
    expect(windows,
        contains((keys: 'Ctrl+Z / Ctrl+Shift+Z', what: '撤销 / 重做')));
    expect(windows.map((entry) => entry.keys).join(' '), isNot(contains('⌘')));
  });

  test('「怎么查快捷键」这件事本身也有快捷键', () {
    expect(boundKeys(), contains(LogicalKeyboardKey.slash),
        reason: '记不住键位的人得有地方问——? 和 ⌘/ 是通行做法');
  });

  test('清单只有一份：帮助弹窗引用它，不自己再抄一遍键位', () {
    final help =
        File('lib/features/home/help_sheet.dart').readAsStringSync();

    expect(help, contains('playbackShortcuts'),
        reason: '帮助里要引用同一份清单，抄一遍迟早跟实现走散');
  });

  test('审片台接上了速查表的入口', () {
    final body =
        File('lib/features/workbench/workbench_body.dart').readAsStringSync();

    expect(body, contains('showShortcutsCheatSheet'),
        reason: '键绑了、清单有了，没人把它们接起来的话按 ? 还是没反应');
  });
}
