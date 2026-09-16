import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/platform/storage_migration_service.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory sandbox;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('ishkafel-storage-move-');
  });

  tearDown(() async {
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  test('复制全部数据并逐文件校验后才切换存储根目录', () async {
    final source = Directory(p.join(sandbox.path, 'old', 'data'))
      ..createSync(recursive: true);
    File(
      p.join(source.path, 'tasks.json'),
    ).writeAsStringSync('{"task":"真实任务"}');
    File(p.join(source.path, 'media', 'clip.bin'))
      ..createSync(recursive: true)
      ..writeAsBytesSync([0, 1, 2, 3, 255]);
    Directory(p.join(source.path, 'empty')).createSync();
    final root = Directory(p.join(sandbox.path, 'new-root'));
    String? activated;
    final service = StorageMigrationService(
      activateStorageRoot: (path) => activated = path,
    );

    final report = await service.copyVerifyAndActivate(
      sourceDataDirectory: source,
      targetStorageRoot: root,
    );

    expect(activated, root.absolute.path);
    expect(report.fileCount, 2);
    expect(report.totalBytes, 28);
    expect(report.destinationDataDirectory, p.join(root.absolute.path, 'data'));
    expect(
      File(p.join(root.path, 'data', 'tasks.json')).readAsStringSync(),
      '{"task":"真实任务"}',
    );
    expect(Directory(p.join(root.path, 'data', 'empty')).existsSync(), isTrue);
    expect(source.existsSync(), isTrue, reason: '软件迁移不能自动删除唯一原件');
  });

  test('目标与源相同或相互嵌套时拒绝迁移', () async {
    final source = Directory(p.join(sandbox.path, 'old', 'data'))
      ..createSync(recursive: true);
    final service = StorageMigrationService(activateStorageRoot: (_) {});

    await expectLater(
      service.copyVerifyAndActivate(
        sourceDataDirectory: source,
        targetStorageRoot: source,
      ),
      throwsA(isA<FileSystemException>()),
    );
    await expectLater(
      service.copyVerifyAndActivate(
        sourceDataDirectory: source,
        targetStorageRoot: Directory(p.join(source.path, 'nested')),
      ),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('目标 data 已有文件时拒绝覆盖', () async {
    final source = Directory(p.join(sandbox.path, 'old', 'data'))
      ..createSync(recursive: true);
    File(p.join(source.path, 'source.txt')).writeAsStringSync('source');
    final root = Directory(p.join(sandbox.path, 'new'))..createSync();
    File(p.join(root.path, 'data', 'existing.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('keep');
    final service = StorageMigrationService(activateStorageRoot: (_) {});

    await expectLater(
      service.copyVerifyAndActivate(
        sourceDataDirectory: source,
        targetStorageRoot: root,
      ),
      throwsA(isA<FileSystemException>()),
    );

    expect(
      File(p.join(root.path, 'data', 'existing.txt')).readAsStringSync(),
      'keep',
    );
  });

  test('复制内容损坏时不切换配置且保留源文件', () async {
    final source = Directory(p.join(sandbox.path, 'old', 'data'))
      ..createSync(recursive: true);
    final original = File(p.join(source.path, 'credentials', 'secret.bin'))
      ..createSync(recursive: true)
      ..writeAsBytesSync([10, 20, 30, 40]);
    var activated = false;
    final service = StorageMigrationService(
      activateStorageRoot: (_) => activated = true,
      copyFile: (from, to) async {
        await to.parent.create(recursive: true);
        await to.writeAsBytes([99, 99, 99, 99]);
      },
    );

    await expectLater(
      service.copyVerifyAndActivate(
        sourceDataDirectory: source,
        targetStorageRoot: Directory(p.join(sandbox.path, 'new')),
      ),
      throwsA(isA<FileSystemException>()),
    );

    expect(activated, isFalse);
    expect(original.readAsBytesSync(), [10, 20, 30, 40]);
  });
}
