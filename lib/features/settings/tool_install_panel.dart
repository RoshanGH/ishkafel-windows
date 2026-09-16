import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/diagnostics/tool_installer.dart';
import '../../core/presentation/user_facing_error.dart';

/// 一个工具的「装上它」面板：点一下就装，装的过程逐行摆出来。
///
/// 为什么不是弹个框转圈：这些命令动辄几分钟（audio-separator 连着 PyTorch
/// 有 1GB）。一个不说话的转圈和一个卡死的程序，用户分不出来——而下载进度、
/// 编译到哪一步，正是他判断「还活着吗」的唯一依据。
///
/// 命令本身（**连同用的哪个镜像源**）在开跑前就摆在那儿：这一步会在他的机器
/// 上跑一条真实的安装命令，有的还从网上取脚本执行，不给看就跑等于替他做了
/// 一个他不知道的决定。
class ToolInstallPanel extends StatefulWidget {
  final InstallRecipe recipe;
  final ToolInstaller installer;

  /// 装完了（成功才回调）——上层据此重新体检
  final VoidCallback? onInstalled;

  const ToolInstallPanel({
    super.key,
    required this.recipe,
    required this.installer,
    this.onInstalled,
  });

  @override
  State<ToolInstallPanel> createState() => _ToolInstallPanelState();
}

class _ToolInstallPanelState extends State<ToolInstallPanel> {
  final _lines = <String>[];
  final _scroll = ScrollController();
  StreamSubscription<InstallEvent>? _sub;
  bool _running = false;
  bool? _done;
  String? _failure;

  /// 输出留多少行。全留着会越滚越卡，而用户真正要看的是「现在到哪了」
  static const _keep = 200;

  @override
  void dispose() {
    _sub?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _start() {
    setState(() {
      _running = true;
      _done = null;
      _failure = null;
      _lines.clear();
    });
    _sub = widget.installer.run(widget.recipe).listen((event) {
      if (!mounted) return;
      setState(() {
        if (event.line != null) {
          _lines.add(event.line!);
          if (_lines.length > _keep) _lines.removeAt(0);
        }
        if (event.done != null) {
          _running = false;
          _done = event.done;
          _failure = event.failure;
        }
      });
      _scrollToEnd();
      if (event.done == true) widget.onInstalled?.call();
    }, onError: (Object e) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _done = false;
        _failure = userFacingError(e, fallback: '安装失败，请检查网络后重试');
      });
    });
  }

  /// 新的一行出来就滚到底——用户盯着的是最新进度，不是开头
  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.recipe.description,
              style: const TextStyle(
                  fontSize: AppFontSize.caption,
                  height: 1.6,
                  color: AppColors.textSecondary)),
          const SizedBox(height: AppSpacing.sm),
          _commandBox(),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              FilledButton(
                key: Key('install-${widget.recipe.tool}'),
                onPressed: _running ? null : _start,
                child: Text(_running
                    ? '安装中…'
                    : _done == false
                        ? '重试'
                        : '安装'),
              ),
              if (_running) ...[
                const SizedBox(width: AppSpacing.md),
                const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2)),
              ],
              if (_done == true) ...[
                const SizedBox(width: AppSpacing.md),
                const Text('已装好',
                    style: TextStyle(
                        fontSize: AppFontSize.caption, color: AppColors.green)),
              ],
            ],
          ),
          if (_failure != null) ...[
            const SizedBox(height: AppSpacing.sm),
            SelectableText(_failure!,
                key: const Key('install-failure'),
                style: const TextStyle(
                    fontSize: AppFontSize.caption,
                    height: 1.6,
                    color: AppColors.red)),
          ],
          if (_lines.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            _output(),
          ],
        ],
      );

  /// 要跑的那一行。**镜像源也写在里面**——用的是哪个源属于「这条命令到底会
  /// 做什么」的一部分
  Widget _commandBox() => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md, vertical: AppSpacing.sm),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: AppColors.border),
        ),
        child: SelectableText(widget.recipe.displayCommand,
            style: TextStyle(
                fontSize: AppFontSize.caption,
                height: 1.5,
                fontFamily: platformMonospaceFontFamily,
                color: AppColors.accentBlueLight)),
      );

  Widget _output() => Container(
        width: double.infinity,
        height: 160,
        padding: const EdgeInsets.all(AppSpacing.sm),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: AppColors.border),
        ),
        child: ListView.builder(
          key: const Key('install-output'),
          controller: _scroll,
          itemCount: _lines.length,
          itemBuilder: (_, i) => Text(_lines[i],
              style: TextStyle(
                  fontSize: AppFontSize.micro,
                  height: 1.5,
                  fontFamily: platformMonospaceFontFamily,
                  color: AppColors.textTertiary)),
        ),
      );
}
