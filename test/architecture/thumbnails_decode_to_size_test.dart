import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **缩略图只能走 [ThumbImage]，不许直接 Image.file。**
///
/// 2026-09-09 性能走查：全项目 11 处 Image.file，没有一处限制解码尺寸。
/// 盘上的缩略图是 360×640 / 270×480，一张解成 RGBA 是 0.5~0.9MB——
/// 候选面板一屏几十张、审核页一次上百张，加起来几十 MB，而画到屏幕上的
/// 只有一百来个逻辑像素宽（挑中托盘里那格更只有 13pt）。
/// 这类问题不会报错、不进日志，只表现为「这软件越用越卡」。
void main() {
  test('没人绕过 ThumbImage 直接解全尺寸位图', () {
    const allowed = {
      // 它自己就是那个唯一出口
      'lib/features/shared/thumb_image.dart',
    };
    final offenders = <String>[];
    for (final file
        in Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))) {
      if (allowed.contains(file.path.replaceAll(r'\', '/'))) continue;
      final src = file.readAsStringSync();
      // 只看真正的构造调用，注释里提到名字不算
      for (final line in src.split('\n')) {
        final code = line.split('//').first;
        if (code.contains('Image.file(')) {
          offenders.add(file.path);
          break;
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          '这些地方按图片自己的分辨率解码缩略图：\n'
          '${offenders.join('\n')}\n'
          '改成 ThumbImage(path: ...)，它按控件实际像素宽解码',
    );
  });
}
