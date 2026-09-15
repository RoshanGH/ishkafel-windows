import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/agent_skill/agent_skill_doc.dart';
import '../../core/agent_skill/skill_installer.dart';
import '../../core/platform/platform_paths.dart';
import 'settings_providers.dart';
import 'settings_widgets.dart';

/// 「Agent 说明书」卡片。
///
/// 只有一种分发方式：**把全文给 Agent，让它自己装**。之前还有一个「安装」
/// 按钮替用户写 ~/.claude/skills 和 ~/.codex/skills，砍掉了——技能目录
/// 每家 Agent 都不一样（Cursor、Warp、各家桌面版……）穷举不完，而说明书
/// 本身就是一份 Markdown，Agent 认字就知道该把它装到自己哪儿。
/// 替两家装、别家不管，反而让人以为只支持那两家。
class AgentSkillCard extends ConsumerStatefulWidget {
  /// 测试注入用
  final SkillInstaller? installer;

  const AgentSkillCard({super.key, this.installer});

  @override
  ConsumerState<AgentSkillCard> createState() => _AgentSkillCardState();
}

class _AgentSkillCardState extends ConsumerState<AgentSkillCard> {
  late final SkillInstaller _installer = widget.installer ??
      SkillInstaller.forCurrentUser(
          markdown: agentSkillMarkdown, version: appVersion);
  String? _message;
  bool _failed = false;

  Future<void> _copy() async {
    await Clipboard.setData(
        ClipboardData(text: _installer.markdownForSharing));
    if (!mounted) return;
    setState(() {
      _failed = false;
      // 自装指令已经写在文档第一段里，粘过去 Agent 自己就会装并回报路径
      _message = '已复制。粘给任何 Agent（Claude Code、Codex、Cursor、'
          'Warp、各家桌面版…）即可——文档开头就是给它的自装指令，'
          '它会回你一句「技能已装到哪儿」';
    });
  }

  /// 存成 .md 文件，方便发给别人（微信、邮件）
  Future<void> _saveFile() async {
    try {
      final file = File(p.join(
        PlatformPaths().desktopDirectory,
        'ishkafel-说明书.md',
      ));
      file.writeAsStringSync(_installer.markdownForSharing);
      if (!mounted) return;
      setState(() {
        _failed = false;
        _message = '已存到桌面：${p.basename(file.path)}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _message = '存不下来：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) => SettingsCard(
        title: 'Agent 说明书',
        children: [
          const SettingsNote(
              '教 Agent 用 ishkafel 出片的完整手册（一份 Markdown），'
              '替换裂变和脚本成片两条线都在里面。\n'
              '「复制全文」后粘给任何 Agent 即可——文档开头就是给它的自装'
              '指令，它会自己装成技能并回报装到了哪儿。之后直接说'
              '「用 ishkafel 把这条片子换一批画面」或者'
              '「照这份稿子做一条新片」，它就知道该走哪条线。\n'
              '要发给同事就「存成文件」，微信发过去即可。'),
          if (_message != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(_message!,
                style: TextStyle(
                    fontSize: AppFontSize.caption,
                    height: 1.6,
                    color: _failed ? AppColors.orange : AppColors.green)),
          ],
          const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.xs,
              children: [
                FilledButton(
                    onPressed: _copy, child: const Text('复制全文')),
                TextButton(
                    onPressed: _saveFile, child: const Text('存成文件')),
              ],
            ),
          ),
        ],
      );
}
