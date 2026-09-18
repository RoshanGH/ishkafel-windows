import 'dart:convert';
import 'dart:io';
import 'package:ishkafel/core/diagnostics/report_factory.dart';
import 'package:ishkafel/core/diagnostics/report_service.dart';

/// 主窗口无响应时仍能独立提交；不终止主进程，不默认抓屏/内存。
Future<void> main(List<String> args) async {
  stdout.encoding = utf8;
  final service = standaloneReportService();
  stdout.writeln(
    'Ishkafel 故障诊断\n将发送近期日志、系统和硬件信息，不发送原视频。\n按 Enter 提交新报告；输入 R 后按 Enter 重传待发报告；关闭窗口取消。',
  );
  final choice = stdin.readLineSync();
  if (choice == null) return;
  try {
    stdout.writeln('正在收集并发送…');
    if (choice.trim().toLowerCase() == 'r') {
      final ids = await service.retryPending();
      stdout.writeln(ids.isEmpty ? '没有待发送的报告。' : '已重传，报告编号：${ids.join('、')}');
    } else {
      final file = await service.prepare(kind: 'unresponsive');
      final id = await service.send(file);
      stdout.writeln('已提交，报告编号：$id');
    }
  } catch (error) {
    stdout.writeln(error is ReportFailure ? error.message : '收集失败，请检查磁盘空间。');
    exitCode = 1;
  }
  stdout.writeln('按 Enter 关闭。');
  stdin.readLineSync();
}
