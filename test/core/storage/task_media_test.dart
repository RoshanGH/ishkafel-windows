import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/storage/task_media.dart';
import 'package:path/path.dart' as p;

/// 一个任务用到的**物料**存在哪儿。
///
/// 规矩是「按项目存、不留孤儿」：素材、配乐、配音都落在这个任务名下，
/// 删任务时跟着一起走。此前它们在跨任务共享的 `material_cache/`、
/// `bgm_cache/` 里按素材 id 命名——省了重复下载，但任务删了没人收，
/// 盘上永远躺着一批不知道归谁的文件。
///
/// **路径只此一处算**：此前 12 个地方各写各的 `p.join(dataDir,
/// 'material_cache', '$id.mp4')`，改一个漏一个。
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('task_media_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('素材与配乐各自落在这个任务名下', () {
    final m = TaskMedia(dataDir: dir, taskId: 't1');
    expect(m.materialsDir.path, endsWith(p.join('materials', 't1')));
    expect(m.bgmDir.path, endsWith(p.join('bgm', 't1')));
  });

  test('两个任务用同一条素材：各存一份，互不影响', () {
    final a = TaskMedia(dataDir: dir, taskId: 'a');
    final b = TaskMedia(dataDir: dir, taskId: 'b');
    expect(a.materialPath(100), isNot(b.materialPath(100)));
  });

  test('文件不在就返回 null——不能只看路径拼得出来就当命中', () {
    final m = TaskMedia(dataDir: dir, taskId: 't1');
    expect(m.localMaterial(100), isNull);
    m.materialsDir.createSync(recursive: true);
    File(m.materialPath(100)).writeAsStringSync('x');
    expect(m.localMaterial(100), m.materialPath(100));
  });

  test('配乐认多种扩展名——曲子不一定是 mp3', () {
    final m = TaskMedia(dataDir: dir, taskId: 't1');
    m.bgmDir.createSync(recursive: true);
    File('${m.bgmDir.path}/7.m4a').writeAsStringSync('x');
    expect(m.localBgm(7), endsWith('7.m4a'));
  });

  test('派生产物也在这个任务名下——删任务一起走', () {
    final m = TaskMedia(dataDir: dir, taskId: 't1');
    expect(m.proxyDir.path, endsWith(p.join('proxy', 't1')));
    expect(m.vocalsDir.path, endsWith(p.join('vocals', 't1')));
  });

  test('删任务就把这个任务的物料一起收走', () {
    final m = TaskMedia(dataDir: dir, taskId: 't1');
    m.materialsDir.createSync(recursive: true);
    m.bgmDir.createSync(recursive: true);
    File(m.materialPath(1)).writeAsStringSync('x');
    File('${m.bgmDir.path}/2.mp3').writeAsStringSync('x');

    m.proxyDir.createSync(recursive: true);
    m.vocalsDir.createSync(recursive: true);

    m.deleteAll();
    expect(m.materialsDir.existsSync(), isFalse);
    expect(m.bgmDir.existsSync(), isFalse);
    expect(m.proxyDir.existsSync(), isFalse);
    expect(m.vocalsDir.existsSync(), isFalse);
  });

  test('删别的任务不碰我的', () {
    final a = TaskMedia(dataDir: dir, taskId: 'a')
      ..materialsDir.createSync(recursive: true);
    final b = TaskMedia(dataDir: dir, taskId: 'b')
      ..materialsDir.createSync(recursive: true);
    b.deleteAll();
    expect(a.materialsDir.existsSync(), isTrue);
  });

  test('目录本来就不存在时删除不炸', () {
    expect(
      () => TaskMedia(dataDir: dir, taskId: '没有').deleteAll(),
      returnsNormally,
    );
  });
}
