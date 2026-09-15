import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/diagnostics/cli_installer.dart';
import 'settings_widgets.dart';

/// 命令行工具的安装入口。
///
/// 这张卡片存在的全部意义：**点一下就能用**。用户不该知道自己这台是 Intel
/// 还是 M 系列，不该去下载什么、编译什么、往哪个目录里放什么。
class CliInstallCard extends ConsumerStatefulWidget {
  /// 测试注入用；正式运行时按当前 app 的位置自己找
  final CliInstaller? installer;

  const CliInstallCard({super.key, this.installer});

  @override
  ConsumerState<CliInstallCard> createState() => _CliInstallCardState();
}

class _CliInstallCardState extends ConsumerState<CliInstallCard> {
  late CliInstaller _installer;
  late CliStatus _status;
  bool _busy = false;
  String? _message;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _installer = widget.installer ?? CliInstaller.forRunningApp();
    _status = _installer.inspect();
  }

  Future<void> _install() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    var result = await _installer.install();
    // /usr/local/bin 在干净的 macOS 上不可写。不要求用户先去开权限，
    // 直接换成弹系统授权框——那是他认得的东西
    if (!result.ok && result.needsAdmin) {
      result = await _installer.installWithAdmin();
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _failed = !result.ok;
      _message = result.message;
      _status = _installer.inspect();
    });
  }

  Future<void> _uninstall() async {
    setState(() => _busy = true);
    final removed = await _installer.uninstall();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _failed = !removed;
      _message = removed ? '已移除' : '没能移除——那个文件不是本应用装的';
      _status = _installer.inspect();
    });
  }

  @override
  Widget build(BuildContext context) => SettingsCard(
        title: '命令行工具',
        children: [
          SettingsRow(
            label: 'ishkafel',
            content: StatusDot(
                ok: _status == CliStatus.installed, text: _statusText),
          ),
          const SizedBox(height: AppSpacing.xs),
          SettingsNote(_explain),
          if (_message != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(_message!,
                style: TextStyle(
                    fontSize: AppFontSize.caption,
                    height: 1.6,
                    color: _failed ? AppColors.orange : AppColors.green)),
          ],
          if (_actionLabel != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FilledButton(
                    onPressed: _busy ? null : _install,
                    child: Text(_busy ? '安装中…' : _actionLabel!),
                  ),
                  if (_status == CliStatus.installed) ...[
                    const SizedBox(width: AppSpacing.sm),
                    TextButton(
                        onPressed: _busy ? null : _uninstall,
                        child: const Text('移除')),
                  ],
                ],
              ),
            ),
          ],
        ],
      );

  String get _statusText => switch (_status) {
        CliStatus.installed => '已安装',
        CliStatus.notInstalled => '未安装',
        CliStatus.stale => '需要重新安装',
        CliStatus.foreign => '被占用',
        CliStatus.unavailable => '此版本未包含',
      };

  /// 按钮文案跟着状态走。已安装时还留一个「重新安装」，因为 app 换了位置
  /// 或者升级过之后，重装一次是唯一要做的事
  String? get _actionLabel => switch (_status) {
        CliStatus.notInstalled => '安装',
        CliStatus.stale => '重新安装',
        CliStatus.installed => '重新安装',
        CliStatus.foreign => null,
        CliStatus.unavailable => null,
      };

  String get _explain => switch (_status) {
        CliStatus.installed =>
          '终端里执行 ishkafel --help 看用法。给 Agent 用的操作手册就在下面'
              '那张卡片里，点「复制全文」粘给它即可。',
        CliStatus.stale => 'app 换过位置，命令指向的还是老路径，现在敲会报找不到文件。重装一次即可。',
        CliStatus.foreign =>
          '${_installer.binDir.path}${Platform.pathSeparator}ishkafel'
              '${Platform.isWindows ? '.cmd' : ''} 已经存在，但不是本应用装的。'
              '为免覆盖别人的东西这里不动它——'
              '确认可以覆盖就先手动删掉。',
        CliStatus.unavailable => '调试运行的产物里不带命令行工具，请用正式打包的版本。',
        CliStatus.notInstalled => Platform.isWindows
            ? r'装进当前用户的 LOCALAPPDATA\Ishkafel\bin 并加入用户 PATH，'
                '之后在任意终端敲 ishkafel 就能用——不需要管理员授权。'
            : '装进 /usr/local/bin，之后在任意终端敲 ishkafel 就能用——让 Claude Code 这类 '
                'Agent 自己跑完导入、分析、挑素材、导出。需要一次管理员授权。',
      };
}
