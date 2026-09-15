import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/features/tasks/task_artifact_cleaner.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempDir;
  late Directory coversDir;
  late Directory workDir;
  late FileTaskArtifactCleaner cleaner;

  Future<File> touch(Directory dir, String name) async {
    final file = File('${dir.path}/$name');
    await file.create(recursive: true);
    await file.writeAsString('x');
    return file;
  }

  /// 目录里剩下的文件名（排序后便于逐项比对）
  Future<List<String>> names(Directory dir) async {
    final entities = await dir.list().toList();
    return entities.map((e) => p.basename(e.path)).toList()..sort();
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ishkafel_cleanup_');
    coversDir = Directory('${tempDir.path}/covers');
    workDir = Directory('${tempDir.path}/analysis_work');
    await coversDir.create(recursive: true);
    await workDir.create(recursive: true);
    cleaner = FileTaskArtifactCleaner(dataDir: tempDir);
  });

  tearDown(() async => tempDir.delete(recursive: true));

  test('删除封面与该任务的全部分析中间产物', () async {
    final cover = await touch(coversDir, 'ab.jpg');
    final pcm = await touch(workDir, 'ab.pcm');
    final shot = await touch(workDir, 'ab_shot0.jpg');
    final thumb = await touch(workDir, 'ab_tl_3.jpg');

    await cleaner.cleanup('ab');

    expect(await cover.exists(), isFalse);
    expect(await pcm.exists(), isFalse);
    expect(await shot.exists(), isFalse);
    expect(await thumb.exists(), isFalse);
  });

  test('不误删 id 只是前缀相同的其他任务产物', () async {
    final other = await touch(workDir, 'abc.pcm');
    final otherCover = await touch(coversDir, 'abc.jpg');

    await cleaner.cleanup('ab');

    expect(await other.exists(), isTrue);
    expect(await otherCover.exists(), isTrue);
  });

  test('目录整个不存在时静默通过，且不会把目录建出来', () async {
    final blank = Directory('${tempDir.path}/blank');
    final empty = FileTaskArtifactCleaner(dataDir: blank);

    await empty.cleanup('ab');

    expect(await blank.exists(), isFalse, reason: '清理不该反过来创建目录');
  });

  test('人声分离结果、抽帧目录、预览切片这些「目录型」产物也要删干净', () async {
    // 真机上就是这几样删不掉：清理器写的是 `if (entity is! File) continue`，
    // 把目录整个跳过了。一条任务的人声分离结果 32M，六条已删任务就是 200M
    final stems = Directory('${workDir.path}/stems/ab')
      ..createSync(recursive: true);
    await touch(stems, '人声.wav');
    final frames = Directory('${workDir.path}/ab_frames')..createSync();
    await touch(frames, 'batch_000.jpg');
    // speed_fit 曾经不在清单里：任务删了、变速切片目录还躺着
    final fit = Directory('${tempDir.path}/speed_fit/ab')
      ..createSync(recursive: true);
    await touch(fit, 'fit_abc.mp4');
    final voices = Directory('${tempDir.path}/voices/ab')
      ..createSync(recursive: true);
    await touch(voices, 'u0.wav');
    final thumbs = Directory('${tempDir.path}/picked_thumbs/ab')
      ..createSync(recursive: true);
    await touch(thumbs, '100.jpg');

    // 另一条任务的同类产物一个都不能碰
    final otherStems = Directory('${workDir.path}/stems/zz')
      ..createSync(recursive: true);
    await touch(otherStems, '人声.wav');

    await cleaner.cleanup('ab');

    for (final dir in [stems, frames, fit, voices, thumbs]) {
      expect(await dir.exists(), isFalse, reason: '${dir.path} 该被删掉');
    }
    expect(await otherStems.exists(), isTrue);
  });

  test('清理一个从不存在的任务：不抛异常，也不碰其他任务的产物', () async {
    final other = await touch(workDir, 'zz.pcm');
    final otherCover = await touch(coversDir, 'zz.jpg');

    await cleaner.cleanup('never-existed');

    expect(await other.exists(), isTrue);
    expect(await otherCover.exists(), isTrue);
    expect(await names(workDir), ['zz.pcm']);
    expect(await names(coversDir), ['zz.jpg']);
  });

  test('重复清理同一任务结果一致（幂等），第二次同样不波及其他任务', () async {
    await touch(coversDir, 'ab.jpg');
    await touch(workDir, 'ab.pcm');
    await touch(workDir, 'ab_shot0.jpg');
    await touch(workDir, 'abc.pcm');
    await touch(coversDir, 'abc.jpg');

    await cleaner.cleanup('ab');
    final afterFirst = (
      work: await names(workDir),
      covers: await names(coversDir),
    );

    await cleaner.cleanup('ab');
    final afterSecond = (
      work: await names(workDir),
      covers: await names(coversDir),
    );

    expect(afterFirst.work, ['abc.pcm']);
    expect(afterFirst.covers, ['abc.jpg']);
    expect(afterSecond.work, afterFirst.work, reason: '第二次清理必须是空操作');
    expect(afterSecond.covers, afterFirst.covers);
  });
}
