import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/script/script_cover.dart';
import 'package:ishkafel/core/script/script_doc.dart';
import 'package:path/path.dart' as p;

/// 脚本任务的封面 = 成片第一帧。没有它，列表页上一条排好 27 句的片子
/// 和一个空任务长得一模一样，人分不出哪条做过。
void main() {
  late Directory dir;
  final calls = <List<String>>[];

  setUp(() async {
    calls.clear();
    dir = await Directory.systemTemp.createTemp('cover');
  });
  tearDown(() => dir.delete(recursive: true));

  Future<ProcessResult> fakeFfmpeg(String exe, List<String> args) async {
    calls.add(args);
    File(args.last).writeAsBytesSync([0xFF, 0xD8]); // 假装抽出一张 jpg
    return ProcessResult(1, 0, '', '');
  }

  ScriptDoc docWith(List<LineShot> shots) => ScriptDoc([
    ScriptLine.create(text: '第一句'),
    ScriptLine.create(text: '第二句').withShots(shots),
  ]);

  test('拿第一个有画面的镜头抽帧——前几行还没配镜头就往后找', () async {
    final src = File(p.join(dir.path, 'm.mp4'))..writeAsBytesSync([0]);
    final cover = await ensureScriptCover(
      doc: docWith([
        LineShot(materialId: 7, name: 'a', durationMs: 9000, trimStartMs: 2000),
      ]),
      dataDir: dir,
      taskId: 't1',
      localPathOf: (_) => src.path,
      run: fakeFfmpeg,
    );
    expect(cover, endsWith(p.join('covers', 't1.jpg')));
    expect(File(cover!).existsSync(), isTrue);
    expect(
      calls.single.join(' '),
      contains('-ss 2.0'),
      reason:
          '从这一镜实际用到的那一刻取——取过段的镜头，'
          '素材开头那一帧根本不会出现在成片里',
    );
  });

  test('第一镜没换就不重抽（不做一次性的脏活）', () async {
    final src = File(p.join(dir.path, 'm.mp4'))..writeAsBytesSync([0]);
    final doc = docWith([LineShot(materialId: 7, name: 'a', durationMs: 9000)]);
    await ensureScriptCover(
      doc: doc,
      dataDir: dir,
      taskId: 't1',
      localPathOf: (_) => src.path,
      run: fakeFfmpeg,
    );
    calls.clear();
    await ensureScriptCover(
      doc: doc,
      dataDir: dir,
      taskId: 't1',
      localPathOf: (_) => src.path,
      run: fakeFfmpeg,
    );
    expect(calls, isEmpty);
  });

  test('换了第一镜就重抽', () async {
    final src = File(p.join(dir.path, 'm.mp4'))..writeAsBytesSync([0]);
    await ensureScriptCover(
      doc: docWith([LineShot(materialId: 7, name: 'a', durationMs: 9000)]),
      dataDir: dir,
      taskId: 't1',
      localPathOf: (_) => src.path,
      run: fakeFfmpeg,
    );
    calls.clear();
    await ensureScriptCover(
      doc: docWith([LineShot(materialId: 9, name: 'b', durationMs: 9000)]),
      dataDir: dir,
      taskId: 't1',
      localPathOf: (_) => src.path,
      run: fakeFfmpeg,
    );
    expect(calls, hasLength(1));
  });

  test('一个镜头都没有：不抽，也不报错——空任务黑着是对的', () async {
    final cover = await ensureScriptCover(
      doc: ScriptDoc([ScriptLine.create(text: '只有台词')]),
      dataDir: dir,
      taskId: 't1',
      localPathOf: (_) => null,
      run: fakeFfmpeg,
    );
    expect(cover, isNull);
    expect(calls, isEmpty);
  });

  test('素材还没下载到本地：先不抽，等下载完再说', () async {
    final cover = await ensureScriptCover(
      doc: docWith([LineShot(materialId: 7, name: 'a', durationMs: 9000)]),
      dataDir: dir,
      taskId: 't1',
      localPathOf: (_) => null,
      run: fakeFfmpeg,
    );
    expect(cover, isNull);
  });
}
