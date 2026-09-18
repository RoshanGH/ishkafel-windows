import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/diagnostics/report_service.dart';
import '../../core/log/app_log.dart';
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
  Uint8List? _screenshot;
  bool _pasting = false;
  File? _prepared;
  bool _busy = false;
  String? _message;
  bool _sent = false;
  bool get _editable => !_busy && !_sent && _prepared == null;

  Future<void> _paste() async {
    AppLog.info('诊断报告：收到粘贴请求');
    if (!_editable || _pasting) return;
    setState(() {
      _pasting = true;
    });
    try {
      final bytes = await const MethodChannel(
        'ishkafel/clipboard',
      ).invokeMethod<Uint8List>('readImage');
      AppLog.info('诊断报告：剪贴板图片字节数 ${bytes?.length ?? 0}');
      if (!mounted || !_editable) return;
      if (bytes != null) {
        if (bytes.length > 4 * 1024 * 1024) {
          throw const ReportFailure('截图请控制在 4 MB 以内。');
        }
        setState(() {
          _screenshot = bytes;
          _message = null;
        });
      } else {
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        if (!mounted || !_editable || data?.text == null) return;
        final value = _description.value;
        final selection = value.selection;
        final start = selection.isValid ? selection.start : value.text.length;
        final end = selection.isValid ? selection.end : start;
        final inserted = data!.text!;
        _description.value = LengthLimitingTextInputFormatter(500)
            .formatEditUpdate(
              value,
              TextEditingValue(
                text: value.text.replaceRange(start, end, inserted),
                selection: TextSelection.collapsed(
                  offset: start + inserted.length,
                ),
              ),
            );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _message = e is ReportFailure
              ? e.message
              : e is PlatformException
              ? e.message ?? '未能粘贴截图，请重新复制后再试。'
              : '未能粘贴截图，请重新复制后再试。';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _pasting = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _description.dispose();
    super.dispose();
  }

  Future<void> _send({bool retry = false}) async {
    if (_pasting || _busy) return;
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
          screenshotBytes: _screenshot,
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
    child: CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyV, control: true): _paste,
        const SingleActivator(LogicalKeyboardKey.insert, shift: true): _paste,
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          PasteTextIntent: CallbackAction<PasteTextIntent>(
            onInvoke: (_) {
              _paste();
              return null;
            },
          ),
        },
        child: AlertDialog(
          title: const Text('提交诊断报告'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '自动发送近期日志、软件版本、系统和硬件信息，不包含原视频文件。日志可能含任务上下文；无需填写也可以提交。',
                  ),
                  const SizedBox(height: AppSpacing.md),
                  TextField(
                    autofocus: true,
                    controller: _description,
                    enabled: !_busy && !_sent && _prepared == null,
                    maxLines: 3,
                    maxLength: 500,
                    decoration: const InputDecoration(
                      labelText: '补充说明（选填）',
                      hintText: '描述问题，或直接 Ctrl+V 粘贴截图',
                    ),
                  ),
                  if (_screenshot != null) ...[
                    Stack(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(AppRadius.md),
                          child: Image.memory(
                            _screenshot!,
                            width: 240,
                            height: 140,
                            fit: BoxFit.contain,
                            errorBuilder: (_, _, _) =>
                                const Text('截图无法预览，请重新复制。'),
                          ),
                        ),
                        Positioned(
                          right: 0,
                          top: 0,
                          child: IconButton.filledTonal(
                            tooltip: '移除截图',
                            onPressed: _editable
                                ? () => setState(() {
                                    _screenshot = null;
                                  })
                                : null,
                            icon: const Icon(Icons.close, size: 18),
                          ),
                        ),
                      ],
                    ),
                    const Text('请确认截图中没有密码或其他不希望上传的内容。'),
                  ],
                  if (_message != null) SelectableText(_message!),
                  if (_pasting) const Text('正在读取剪贴板…'),
                  if (_busy || _pasting)
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
                onPressed: _busy || _pasting ? null : () => _send(retry: true),
                child: const Text('重传待发报告'),
              ),
            TextButton(
              onPressed: _busy ? null : () => Navigator.pop(context),
              child: Text(_sent ? '关闭' : '取消'),
            ),
            if (!_sent)
              FilledButton(
                onPressed: _busy || _pasting ? null : _send,
                child: Text(_prepared == null ? '提交报告' : '重试发送'),
              ),
          ],
        ),
      ),
    ),
  );
}
