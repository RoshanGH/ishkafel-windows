import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/storage/task_artifacts.dart';
import 'package:path/path.dart' as p;

late Directory _root;

void _file(String relative, [int bytes = 10]) {
  File('${_root.path}/$relative')
    ..createSync(recursive: true)
    ..writeAsBytesSync(List<int>.filled(bytes, 0));
}

List<String> _names(List<FileSystemEntity> entities) =>
    entities
        .map((e) => p.relative(e.path, from: _root.path).replaceAll(r'\', '/'))
        .toList()
      ..sort();

void main() {
  setUp(() => _root = Directory.systemTemp.createTempSync('ishkafel_ta_'));
  tearDown(() => _root.deleteSync(recursive: true));

  group('一条任务在盘上留下什么', () {
    test('七种产物一样不落', () {
      _file('covers/ab.jpg');
      _file('analysis_work/ab.pcm');
      _file('analysis_work/ab_thumbs.raw');
      _file('analysis_work/ab_frames/batch_000.jpg');
      _file('analysis_work/stems/ab/人声.wav');
      _file('speed_fit/ab/fit_x.mp4');
      _file('export_work/ab/out.mp4');
      _file('voices/ab/u0.wav');
      _file('picked_thumbs/ab/100.jpg');

      expect(_names(TaskArtifacts(_root).of('ab')), [
        'analysis_work/ab.pcm',
        'analysis_work/ab_frames',
        'analysis_work/ab_thumbs.raw',
        'analysis_work/stems/ab',
        'covers/ab.jpg',
        'export_work/ab',
        'picked_thumbs/ab',
        'speed_fit/ab',
        'voices/ab',
      ]);
    });

    test('不认 id 只是前缀相同的别人家产物', () {
      _file('analysis_work/abc.pcm');
      _file('covers/abc.jpg');
      _file('speed_fit/abc/x.mp4');

      expect(TaskArtifacts(_root).of('ab'), isEmpty);
    });
  });

  group('孤儿清扫', () {
    test('归属不到任何现存任务的全部报出来', () {
      _file('covers/alive.jpg');
      _file('covers/ghost.jpg');
      _file('analysis_work/alive.pcm');
      _file('analysis_work/ghost_thumbs.raw');
      _file('analysis_work/stems/ghost/人声.wav');
      _file('speed_fit/ghost/x.mp4');

      expect(_names(TaskArtifacts(_root).orphans({'alive'})), [
        'analysis_work/ghost_thumbs.raw',
        'analysis_work/stems/ghost',
        'covers/ghost.jpg',
        'speed_fit/ghost',
      ]);
    });

    test('封面按去掉扩展名之后的名字判归属', () {
      _file('covers/ab.jpg');

      expect(
        TaskArtifacts(_root).orphans({'ab'}),
        isEmpty,
        reason: '拿 ab.jpg 整个去比的话，活着的任务的封面会被当成孤儿删掉',
      );
    });

    test('删掉之后返回实际释放的字节数', () {
      _file('covers/ghost.jpg', 100);
      _file('speed_fit/ghost/x.mp4', 400);
      final artifacts = TaskArtifacts(_root);

      final freed = artifacts.delete(artifacts.orphans({'alive'}));

      expect(freed, 500);
      expect(
        Directory('${_root.path}/preview_video/ghost').existsSync(),
        isFalse,
      );
    });

    test('一个任务都没有时，所有产物都是孤儿', () {
      _file('covers/a.jpg');
      _file('analysis_work/a.pcm');

      expect(TaskArtifacts(_root).orphans(const {}), hasLength(2));
    });

    test('目录整个不存在时不炸，也不会把目录建出来', () {
      final blank = Directory('${_root.path}/blank');

      expect(TaskArtifacts(blank).orphans(const {'a'}), isEmpty);
      expect(TaskArtifacts(blank).of('a'), isEmpty);
      expect(blank.existsSync(), isFalse);
    });
  });

  group('用完即弃的中转文件，不管归属都该删', () {
    /// 它们只在产生自己的那一步里被读一次。新代码用完就删，这里管的是
    /// 老存档留下的那批——它们归属得到现存任务，孤儿判定永远不会碰。
    test('认出四类中转文件', () {
      _file('analysis_work/ab.pcm');
      _file('analysis_work/ab_thumbs.raw');
      _file('analysis_work/ab_scene.txt');
      _file('analysis_work/ab_rev17100.jpg');
      // 这几样有后续用途，一个都不能碰
      _file('analysis_work/ab_tl_0.jpg'); // 时间线缩略图
      _file('analysis_work/ab_shot0_1.jpg'); // 打标痕迹要回看的帧
      _file('analysis_work/ab_wave.json'); // 波形包络缓存

      expect(_names(TaskArtifacts(_root).transients()), [
        'analysis_work/ab.pcm',
        'analysis_work/ab_rev17100.jpg',
        'analysis_work/ab_scene.txt',
        'analysis_work/ab_thumbs.raw',
      ]);
    });

    test('任务还活着照删不误——这类文件的定义就是用完即弃', () {
      _file('analysis_work/alive.pcm');

      expect(TaskArtifacts(_root).orphans({'alive'}), isEmpty);
      expect(TaskArtifacts(_root).transients(), hasLength(1));
    });
  });
}
