import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **每一条导出路都要把声音设置整套带上。**
///
/// 2026-09-10 真机自查撞到的：命令行那条导出路从来没传过 `materialAudio`，
/// 于是 Agent 导出来的片子里「替换分镜的声音」那一层一次都没响过，
/// 而界面导出的会响——同一个方案，两条路出来的不是同一条片子，
/// 而且哪儿都不报错。同一天新加的「原片这一镜的声音」差点重演一遍：
/// 预览接好了、导出两条路都漏了。
///
/// 这类漏不是逻辑写错，是**加参数时忘了改调用点**，只有静态扫描拦得住。
void main() {
  /// 调用 exportAll / exportCombinations 的地方，以及那一次调用的参数文本
  List<(String file, String call)> exportCalls() {
    final out = <(String, String)>[];
    for (final f
        in Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))) {
      // 定义本身不算
      if (f.path
          .replaceAll(r'\', '/')
          .endsWith('core/export/export_runner.dart')) {
        continue;
      }
      final src = f.readAsStringSync();
      for (final name in const ['exportAll(', 'exportCombinations(']) {
        var from = 0;
        while (true) {
          final at = src.indexOf(name, from);
          if (at < 0) break;
          from = at + name.length;
          // 从调用括号开始配对到闭合括号：参数里有嵌套的括号与集合
          var depth = 0;
          var end = at + name.length - 1;
          for (var i = at + name.length - 1; i < src.length; i++) {
            if (src[i] == '(') depth++;
            if (src[i] == ')') {
              depth--;
              if (depth == 0) {
                end = i;
                break;
              }
            }
          }
          out.add((f.path, src.substring(at, end + 1)));
        }
      }
    }
    return out;
  }

  test('导出调用点一个都不能少传声音设置', () {
    final calls = exportCalls();
    expect(calls, isNotEmpty, reason: '一个调用点都没扫到，说明这条测试本身失效了');

    // 少了任何一个，人在界面上设的那一档就只在预览里生效，导出时消失
    const required = [
      'materialAudio:', // 替换分镜那一层
      'sourceAudio:', // 原片那一层
      'backgroundPath:', // 「背景声」要读的分离轨
      'vocalsPath:', // 「人声」要读的分离轨
      'subtitleTrack:', // 手改过的字幕
      'voiceAudio:', // 换音色生成的配音
    ];
    final offenders = <String>[];
    for (final (file, call) in calls) {
      for (final key in required) {
        if (!call.contains(key)) offenders.add('$file 少了 $key');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          '这些导出调用点漏了参数，导出来的片子和界面/预览里不是一回事：\n'
          '${offenders.join('\n')}',
    );
  });
}
