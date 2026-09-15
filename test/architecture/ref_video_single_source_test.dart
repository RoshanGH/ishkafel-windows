import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 「这一行的参考片是哪个文件」只能有一个取法。
///
/// 这条测试是拿真实事故换来的：界面写的是
/// `line.reference?.videoPath ?? _doc.refVideoPath`（对的），
/// CLI 三处写的是 `reference?.videoPath`（漏了回落）。而 `script extract`
/// 整片提取时行级那个字段**按设计就是 null**，于是参考片复刻在命令行上
/// 从第一步（tag-ref / frames / shots）就断，报的还是「手写的脚本没有参考镜」。
///
/// 这个项目栽在「同一个东西两处算」上不止一次了（收素材、产物清单）。
/// 取法收敛在 ScriptDoc.refVideoOf，谁都别再自己拼一遍。
void main() {
  test('没有人绕过 ScriptDoc.refVideoOf 自己拼回落', () {
    final offenders = <String>[];
    for (final dir in ['lib/cli', 'lib/features', 'lib/core']) {
      for (final f
          in Directory(dir)
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.dart'))) {
        // script_doc.dart 自己就是那唯一一份
        if (f.path
            .replaceAll(r'\', '/')
            .endsWith('core/script/script_doc.dart')) {
          continue;
        }
        final src = f.readAsStringSync();
        if (src.contains('reference?.videoPath ??') ||
            src.contains('reference!.videoPath ??')) {
          offenders.add(f.path);
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          '这些地方在自己拼「行级 ?? 文档级」：${offenders.join('、')}。'
          '改用 doc.refVideoOf(line)——多一份实现就多一次漏回落的机会',
    );
  });

  test('要复刻的那三条命令都从文档上取参考片，不只看行级', () {
    final src = File('lib/cli/commands/script_command.dart').readAsStringSync();
    expect(
      src.contains('refVideoOf'),
      isTrue,
      reason:
          'tag-ref / frames / shots 是参考片复刻的前三步，'
          '它们只看 reference?.videoPath 的话，整片提取出来的脚本全都用不了',
    );
    // 光有 refVideoOf 不够——不能有人在旁边又留一条只看行级的老路
    for (final bad in ['reference?.videoPath;', 'reference!.videoPath;']) {
      expect(
        src.contains(bad),
        isFalse,
        reason: '还留着只看行级的取法（$bad）——那正是当初断掉的那条路',
      );
    }
  });
}
