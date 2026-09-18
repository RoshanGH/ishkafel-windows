import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/diagnostics/report_service.dart';
import '../../app/theme/app_spacing.dart';

final reportServiceProvider = Provider<ReportService?>((ref) => null);
final diagnosticNavigatorKey = GlobalKey<NavigatorState>();

/// 全局入口与设置页共用，无必填项；点击提交才收集和发送。
class DiagnosticReportButton extends ConsumerWidget {
  const DiagnosticReportButton({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.watch(reportServiceProvider);
    if (service == null) return const SizedBox.shrink();
    return TextButton.icon(
      icon: const Icon(Icons.bug_report_outlined, size: 18),
      label: const Text('提交诊断报告'),
      onPressed: () => showDialog<void>(
        context: diagnosticNavigatorKey.currentContext ?? context,
        barrierDismissible: false,
        builder: (_) => _ReportDialog(service: service),
      ),
    );
  }
}

class _ReportDialog extends StatefulWidget {
  final ReportService service;
  const _ReportDialog({required this.service});
  @override
  State<_ReportDialog> createState() => _ReportDialogState();
}

class _ReportDialogState extends State<_ReportDialog> {
  final _description = TextEditingController();
  File? _screenshot;
  File? _prepared;
  bool _busy = false;
  String? _message;
  bool _sent = false;
  @override
  void dispose() {
    _description.dispose();
    super.dispose();
  }

  Future<void> _send({bool retry = false}) async {
    setState(() {
      _busy = true;
      _message = '正在收集并发送，硬件检测最多约 30 秒，请稍候…';
    });
    try {
      if (retry) {
        final ids = await widget.service.retryPending();
        if (mounted) {
          setState(() {
            _message = ids.isEmpty
                ? '没有待发送的报告。'
                : '已发送 ${ids.length} 份报告。编号：${ids.join('、')}';
            _sent = ids.isNotEmpty;
          });
        }
      } else {
        _prepared ??= await widget.service.prepare(
          description: _description.text,
          screenshot: _screenshot,
        );
        final id = await widget.service.send(_prepared!);
        _prepared = null;
        if (mounted) {
          setState(() {
            _message = '报告已提交。编号：$id';
            _sent = true;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _message = e is ReportFailure ? e.message : '未能收集报告，请检查存储空间后重试。';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: const Text('提交诊断报告'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('自动发送近期日志、软件版本、系统和硬件信息，不包含原视频文件。日志可能含任务上下文；无需填写也可以提交。'),
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: _description,
                enabled: !_busy && !_sent && _prepared == null,
                maxLines: 3,
                maxLength: 500,
                decoration: const InputDecoration(labelText: '补充说明（选填）'),
              ),
              TextButton.icon(
                icon: const Icon(Icons.image_outlined),
                label: Text(_screenshot == null ? '附加截图（选填）' : '已选择截图，点击更换'),
                onPressed: _busy || _sent || _prepared != null
                    ? null
                    : () async {
                        final file = await openFile(
                          acceptedTypeGroups: [
                            const XTypeGroup(
                              label: '截图',
                              extensions: ['png', 'jpg', 'jpeg'],
                            ),
                          ],
                        );
                        if (file != null && mounted) {
                          setState(() {
                            _screenshot = File(file.path);
                          });
                        }
                      },
              ),
              if (_screenshot != null) ...[
                const Text('请确认截图中没有密码或其他不希望上传的内容。'),
                TextButton(
                  onPressed: _busy || _prepared != null
                      ? null
                      : () => setState(() {
                          _screenshot = null;
                        }),
                  child: const Text('移除截图'),
                ),
              ],
              if (_message != null) SelectableText(_message!),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.only(top: AppSpacing.sm),
                  child: LinearProgressIndicator(),
                ),
            ],
          ),
        ),
      ),
      actions: [
        if (!_sent && _prepared == null)
          TextButton(
            onPressed: _busy ? null : () => _send(retry: true),
            child: const Text('重传待发报告'),
          ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: Text(_sent ? '关闭' : '取消'),
        ),
        if (!_sent)
          FilledButton(
            onPressed: _busy ? null : _send,
            child: Text(_prepared == null ? '提交报告' : '重试发送'),
          ),
      ],
    ),
  );
}
