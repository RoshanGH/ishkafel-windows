import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';

/// 一条快捷键：键位 + 它干什么
typedef ShortcutEntry = ({String keys, String what});

/// **全 app 只有这一份快捷键清单。**
///
/// 原来它硬编码在首页的帮助弹窗里，于是：人在审片台干活时想查，得先退回
/// 首页；而清单和真正绑定的键位是两处各写各的，改了键位没人管这份说明
/// （2026-09-09 设计走查：JKL 走带、⇧←→ 粗调这些都实现了，界面上却没有
/// 任何地方说得出来——功能存在等于不存在）。
///
/// `test/architecture/shortcuts_documented_test.dart` 盯着「这里列的键
/// 真的绑上了」。
List<ShortcutEntry> playbackShortcutsFor(String operatingSystem) => [
  (keys: '空格 / 回车', what: '播放、暂停'),
  (keys: 'J K L', what: '倒着走 · 停 · 往前走（连按加速）'),
  (keys: '← →', what: '逐帧'),
  (keys: '⇧ ← →', what: '一次 10 帧'),
  (keys: '↑ ↓', what: '选中上一个 / 下一个'),
  (keys: 'Home / End', what: '跳到片头 / 片尾'),
  (keys: operatingSystem == 'windows' ? 'Ctrl+Z / Ctrl+Shift+Z' : '⌘Z / ⇧⌘Z',
      what: '撤销 / 重做'),
];

List<ShortcutEntry> get playbackShortcuts =>
    playbackShortcutsFor(Platform.operatingSystem);

/// 审片台里随时能叫出来的速查表（`?` 或平台对应的斜杠快捷键）
Future<void> showShortcutsCheatSheet(BuildContext context) => showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surfaceRaised,
        title: const Text('快捷键',
            style: TextStyle(fontSize: AppFontSize.title)),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final s in playbackShortcuts)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 110,
                        child: Text(s.keys,
                            style: const TextStyle(
                                fontSize: AppFontSize.body,
                                color: AppColors.textPrimary,
                                fontWeight: FontWeight.w600)),
                      ),
                      Expanded(
                        child: Text(s.what,
                            style: const TextStyle(
                                fontSize: AppFontSize.body,
                                color: AppColors.textSecondary)),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: AppSpacing.xs),
              const Text('在台词输入框里打字时，这些键全部让给输入法。',
                  style: TextStyle(
                      fontSize: AppFontSize.caption,
                      color: AppColors.textTertiary)),
            ],
          ),
        ),
        actions: [
          FilledButton(
              key: const ValueKey('shortcuts-close'),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('知道了')),
        ],
      ),
    );
