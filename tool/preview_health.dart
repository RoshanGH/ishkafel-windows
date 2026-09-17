// 读一份播放日志，判断这一轮预览平不平稳。
//
//   dart run tool/preview_health.dart <日志文件>
//
// 由 scripts/preview_health.sh 调用——那个脚本负责真播一遍并收集日志。
// 判据与阈值都在 lib/core/playback/preview_health.dart（有单测盯着）。
import 'dart:io';

import 'package:ishkafel/core/playback/preview_health.dart';

Future<int> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('用法：dart run tool/preview_health.dart <日志文件>');
    return 64;
  }
  final file = File(args.first);
  if (!file.existsSync()) {
    stderr.writeln('找不到日志：${args.first}');
    return 66;
  }

  final h = readPreviewHealth(file.readAsStringSync());
  final failures = previewHealthFailures(h);

  stdout.writeln('预览体检（${h.samples} 个采样点）');
  stdout.writeln('  画面闪（输出重建）  ${h.videoRebuilds} 次'
      '   上限 ${PreviewHealthLimits.maxVideoRebuilds}');
  stdout.writeln('  声音被硬拽          ${h.hardSeeks} 次'
      '   上限 ${PreviewHealthLimits.maxHardSeeks}');
  stdout.writeln('  没统一规格的段      ${h.offSpecSegments} 段'
      '   上限 ${PreviewHealthLimits.maxOffSpecSegments}');
  stdout.writeln('  代理生成失败        ${h.proxyFailures} 次'
      '   上限 ${PreviewHealthLimits.maxProxyFailures}');
  stdout.writeln('  声音晚于画面        ${h.worstLagMs}ms'
      '   上限 ${PreviewHealthLimits.maxAudioLagMs}ms');
  stdout.writeln('  声音早于画面        ${h.worstLeadMs}ms'
      '   上限 ${PreviewHealthLimits.maxAudioLeadMs}ms');
  stdout.writeln('  主时钟最长一跳      ${h.worstTickMs}ms'
      '   上限 ${PreviewHealthLimits.maxTickMs}ms');
  stdout.writeln('');

  if (failures.isEmpty) {
    stdout.writeln('✓ 全过——这一轮播下来画面没闪、声音没被拽、音画对得上');
    return 0;
  }
  stdout.writeln('✗ 没过：');
  for (final f in failures) {
    stdout.writeln('  · $f');
  }
  return 1;
}
