import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/storage/task_artifacts.dart';
import 'package:path/path.dart' as p;

/// 固定底片的单元各自抽一份缩略图、算一份波形。它们按 `<taskId>_u<uid>`
/// 命名，删任务时跟着走——但**换底片、删这个单元**时任务还在，不单独清
/// 一道就永远躺在盘上没人读。反复试几次底片就是几十兆。
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('unit_art'));
  tearDown(() => dir.deleteSync(recursive: true));

  File work(String name) {
    final f = File(p.join(dir.path, 'analysis_work', name));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync('x' * 2048);
    return f;
  }

  test('按单元身份认领：这个单元的缩略图、波形、中转文件都算它的', () {
    work('t1_uabc_tl14_0.jpg');
    work('t1_uabc_tl14_1.jpg');
    work('t1_uabc_wave.json');
    work('t1_uabc_scene.txt');

    expect(TaskArtifacts(dir).ofUnit('t1', 'abc'), hasLength(4));
  });

  test('别的单元、别的任务一个都不碰', () {
    work('t1_uabc_tl14_0.jpg');
    work('t1_uzzz_tl14_0.jpg'); // 同一条任务的另一个单元
    work('t2_uabc_tl14_0.jpg'); // 另一条任务
    work('t1_thumbs.raw'); // 任务级的，不是这个单元的

    final mine = TaskArtifacts(dir)
        .ofUnit('t1', 'abc')
        .map((e) => p.basename(e.path))
        .toList();

    expect(mine, ['t1_uabc_tl14_0.jpg']);
  });

  test('uid 是另一个的前缀时不误删', () {
    work('t1_uab_tl14_0.jpg'); // uid = ab
    work('t1_uabc_tl14_0.jpg');

    final mine = TaskArtifacts(dir)
        .ofUnit('t1', 'abc')
        .map((e) => p.basename(e.path))
        .toList();

    expect(mine, ['t1_uabc_tl14_0.jpg'],
        reason: 'ab 的文件不该被 abc 认领');
  });

  test('空 uid 不认领任何东西——宁可不清，也不能乱删', () {
    work('t1_uabc_tl14_0.jpg');

    expect(TaskArtifacts(dir).ofUnit('t1', ''), isEmpty);
  });

  test('删掉之后别人的还在', () {
    work('t1_uabc_tl14_0.jpg');
    work('t1_uzzz_tl14_0.jpg');

    final artifacts = TaskArtifacts(dir);
    artifacts.delete(artifacts.ofUnit('t1', 'abc'));

    final left = Directory(p.join(dir.path, 'analysis_work'))
        .listSync()
        .map((e) => p.basename(e.path))
        .toList();
    expect(left, ['t1_uzzz_tl14_0.jpg']);
  });

  test('删任务时这些照样跟着走（前缀仍是 taskId）', () {
    work('t1_uabc_tl14_0.jpg');

    expect(
      TaskArtifacts(dir).of('t1').map((e) => p.basename(e.path)),
      contains('t1_uabc_tl14_0.jpg'),
    );
  });
}
