import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../core/log/app_log.dart';
import '../../../core/platform/platform_shell.dart';
import '../settings_providers.dart';
import '../product_owner_card.dart';
import '../update_card.dart';
import '../settings_widgets.dart';
import '../diagnostic_report_button.dart';

/// 在系统文件管理器中打开目录（注入点：测试不真的拉起外部程序）
typedef DirectoryRevealer = Future<void> Function(Directory dir);

Future<void> _revealInFileManager(Directory dir) async {
  await PlatformShell().openPath(dir.path);
}

final directoryRevealerProvider =
    Provider<DirectoryRevealer>((ref) => _revealInFileManager);

/// 关于分区：版本号 + 数据目录。
///
/// 这两条不是装饰——出问题时，「你用的哪个版本」和「数据在哪」是排查的第一
/// 步。没有它们，同事只能截一张看不出版本的界面图过来。
class AboutSection extends ConsumerWidget {
  const AboutSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dataDir = ref.watch(dataDirProvider);
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.xl),
      children: [
        // 更新入口就放在版本号旁边——人找版本号的时候正是他想升级的时候
        const UpdateCard(),
        // 有问题找谁：来这一页的人多半正是遇上事了，把去处摆在最前面
        const ProductOwnerCard(),
        const DiagnosticReportButton(),
        SettingsCard(
          title: 'ishkafel',
          children: [
            const SettingsRow(label: '版本', value: appVersion),
            const Divider(height: 1, color: AppColors.border),
            SettingsRow(
              label: '数据目录',
              value: dataDir?.path ?? '尚未初始化',
              trailing: dataDir == null
                  ? null
                  : TextButton(
                      key: const Key('settings-reveal-data-dir'),
                      onPressed: () => _reveal(context, ref, dataDir),
                      child: Text(PlatformShell().revealLabel),
                    ),
            ),
            const SettingsNote('任务数据、封面与分析中间产物都存放在这里。'
                '反馈问题时附上版本号，能省掉大半来回。'),
          ],
        ),
        const SettingsCard(
          title: '这个工具做什么',
          children: [
            SettingsNote('做竖屏口播短视频。机制只有一句话：'
                '台词决定时间，画面填进去。\n\n'
                '两条线，平级的，进来先选一条：\n'
                '· 替换裂变——拿一条现成的片子，台词与结构原样不动，'
                '画面全换成新素材，一次产出若干条结构相同、画面全新的片子。\n'
                '· 脚本成片——从台词开始造一条新片：自己写或从参考片提取、'
                '合成配音、给每句配画面、铺配乐、导出。不需要原片。'),
          ],
        ),
      ],
    );
  }

  Future<void> _reveal(
      BuildContext context, WidgetRef ref, Directory dir) async {
    try {
      await ref.read(directoryRevealerProvider)(dir);
    } catch (e) {
      AppLog.warn('打开数据目录失败：$e');
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法打开数据目录，可复制上面的路径手动前往。')));
    }
  }
}
