import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ffmpeg/filtergraph_escape.dart';
import 'package:ishkafel/core/platform/platform_shell.dart';
import 'package:path/path.dart' as p;

void main() {
  test('真实 FFmpeg 能写入带盘符、空格和中文的 metadata 路径', () async {
    if (!Platform.isWindows) return;
    final ffmpeg = PlatformShell().lookupOnPath('ffmpeg');
    if (ffmpeg == null) return;

    final root = await Directory.systemTemp.createTemp('ishkafel 路径 ');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final output = p.join(root.path, '场景 结果.txt');
    final filter = 'metadata=mode=add:key=ishkafel:value=ok,'
        'metadata=print:file=${escapeFfmpegFilterPath(output)}';

    final result = await Process.run(ffmpeg, [
      '-hide_banner',
      '-loglevel',
      'error',
      '-f',
      'lavfi',
      '-i',
      'color=black:s=16x16:d=0.1',
      '-vf',
      filter,
      '-f',
      'null',
      '-',
    ]);

    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(File(output).existsSync(), isTrue);
    expect(File(output).readAsStringSync(), contains('ishkafel=ok'));
  });
}
