import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/storage/task_artifacts.dart';

/// **磁盘上每个按任务分的目录都必须在产物清单里。**
///
/// 不在清单里 = 删任务时不会被清 = 盘上永远躺着没人认领的文件。
/// 真机自查量到过：脚本成片那条线的五个目录（script_export、
/// speed_fit_script、shot_frames、script_refs、preview_voice）全都漏登记，
/// 加起来近 900M。
///
/// 这些路径是在界面里用 `p.join(dataDir, '目录名', taskId)` 现拼的，
/// 清单在 core，两边谁也不认识谁——所以要有这条测试把它们对上。
void main() {
  test('代码里现拼的按任务目录，都要在产物清单里登记', () {
    final registered = {
      ...TaskArtifacts.perTaskDirNames,
      ...TaskArtifacts.sharedCacheDirNames,
      ...TaskArtifacts.retiredDirNames,
      // 这些不是产物：任务本体、方案、锁、在场状态、Agent 看的帧图
      // （帧图按内容指纹存、跨任务复用，删任务不该带走）
      'tasks', 'plans', 'locks', 'presence', 'analysis_state',
      'agent_frames', 'preview_cache', 'credentials', 'covers',
      // analysis_work 有自己的清理路径（它第一层混着任务与非任务的东西，
      // 见 TaskArtifacts 里对 stems 的处理）
      'analysis_work',
      // 全局待传报告，不归属任务；ReportService 限量 20 份、确认收件即删除。
      'diagnostics',
    };

    final offenders = <String>[];
    final pattern =
        RegExp(r"""p\.join\(\s*dataDir(?:\.path)?\s*,\s*'([a-z_]+)'\s*,""");
    for (final f in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      for (final line in f.readAsStringSync().split('\n')) {
        // 注释里讲历史的路径不算数
        if (line.trimLeft().startsWith('//') ||
            line.trimLeft().startsWith('///')) {
          continue;
        }
        for (final m in pattern.allMatches(line)) {
          final name = m.group(1)!;
          if (!registered.contains(name)) offenders.add('${f.path} → $name');
        }
      }
    }

    expect(offenders.toSet(), isEmpty,
        reason: '这些目录按任务存却没登记，删任务时会变成孤儿：\n'
            '${offenders.toSet().join('\n')}');
  });
}
