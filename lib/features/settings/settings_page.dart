import 'package:flutter/material.dart';

import '../shared/scroll_fade.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import 'sections/about_section.dart';
import 'sections/account_section.dart';
import 'sections/cache_section.dart';
import 'sections/environment_section.dart';
import 'sections/storage_section.dart';

export 'settings_providers.dart' show appVersion;

/// 设置页的一个分区
class _Section {
  final String title;
  final IconData icon;
  final Widget Function() build;

  const _Section({required this.title, required this.icon, required this.build});
}

/// 分区清单。
///
const _sections = <_Section>[
  _Section(title: 'miaoa 账号', icon: Icons.account_circle_outlined, build: AccountSection.new),
  _Section(title: '运行环境', icon: Icons.build_outlined, build: EnvironmentSection.new),
  _Section(title: '存储位置', icon: Icons.folder_outlined, build: StorageSection.new),
  _Section(title: '缓存管理', icon: Icons.storage_outlined, build: CacheSection.new),
  _Section(title: '关于', icon: Icons.info_outline, build: AboutSection.new),
];

/// 设置页：左侧分区导航 + 右侧内容（设计稿 `外围页面` 第 3 屏）
/// 设置页内容区最宽多少：卡片 640 + 两侧 24 的页边距
const double _contentMaxWidth = 688;

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  int _selected = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.surface,
          title: const Text('设置',
              style: TextStyle(
                  fontSize: AppFontSize.title, fontWeight: FontWeight.w700)),
        ),
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Nav(
              selected: _selected,
              onSelect: (i) => setState(() => _selected = i),
            ),
            // **内容整块居中**：1440 宽的窗口里，内容只有 640 宽，
            // 贴着左边导航栏摆的话右手边空出 580px 什么都没有，
            // 看起来像页面没做完（2026-09-09 设计走查）。
            // 整块居中、块内仍然靠左——卡片、说明、按钮就都对得齐
            Expanded(
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints:
                      const BoxConstraints(maxWidth: _contentMaxWidth),
                  // 「运行环境」这一页一屏放不下（最底下的「Agent 说明书」
                  // 被截断），而 macOS 的滚动条不动鼠标不出现
                  child: ScrollFade(
                    background: AppColors.background,
                    child: _sections[_selected].build(),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
}

class _Nav extends StatelessWidget {
  final int selected;
  final ValueChanged<int> onSelect;

  const _Nav({required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) => Container(
        width: 190,
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm, vertical: AppSpacing.md),
        decoration: const BoxDecoration(
          color: AppColors.surface,
          border: Border(right: BorderSide(color: AppColors.border)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < _sections.length; i++)
              _NavItem(
                section: _sections[i],
                selected: i == selected,
                onTap: () => onSelect(i),
              ),
          ],
        ),
      );
}

class _NavItem extends StatelessWidget {
  final _Section section;
  final bool selected;
  final VoidCallback onTap;

  const _NavItem(
      {required this.section, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Material(
          color: selected
              ? AppColors.accentBlue.withValues(alpha: 0.14)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(AppRadius.md),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md, vertical: AppSpacing.sm),
              child: Row(
                children: [
                  Icon(section.icon,
                      size: 15,
                      color: selected
                          ? AppColors.textPrimary
                          : AppColors.textSecondary),
                  const SizedBox(width: AppSpacing.sm),
                  Text(
                    section.title,
                    style: TextStyle(
                      fontSize: AppFontSize.body,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                      color: selected
                          ? AppColors.textPrimary
                          : AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
}
