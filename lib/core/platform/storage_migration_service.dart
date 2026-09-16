import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

typedef StorageRootActivator = void Function(String path);
typedef StorageFileCopier = Future<void> Function(File source, File target);

class StorageMigrationReport {
  final String sourceDataDirectory;
  final String destinationDataDirectory;
  final int fileCount;
  final int totalBytes;
  final Map<String, String> sha256ByRelativePath;

  const StorageMigrationReport({
    required this.sourceDataDirectory,
    required this.destinationDataDirectory,
    required this.fileCount,
    required this.totalBytes,
    required this.sha256ByRelativePath,
  });
}

/// 将现有数据复制到新的存储根目录，并在逐文件校验后切换设置。
///
/// 这个服务永远不删除源目录。删除旧副本必须在新位置重启并真人验收后，由
/// 明确的外部迁移流程完成。
class StorageMigrationService {
  final StorageRootActivator activateStorageRoot;
  final StorageFileCopier copyFile;

  StorageMigrationService({
    required this.activateStorageRoot,
    StorageFileCopier? copyFile,
  }) : copyFile = copyFile ?? _copyFile;

  Future<StorageMigrationReport> copyVerifyAndActivate({
    required Directory sourceDataDirectory,
    required Directory targetStorageRoot,
  }) async {
    final source = Directory(sourceDataDirectory.absolute.path);
    final root = Directory(targetStorageRoot.absolute.path);
    final destination = Directory(p.join(root.path, 'data'));
    _validateDistinctTrees(source, root, destination);
    if (!await source.exists()) {
      throw FileSystemException('原数据目录不存在', source.path);
    }
    if (await destination.exists() &&
        !(await destination.list(followLinks: false).isEmpty)) {
      throw FileSystemException('目标 data 目录不是空的，拒绝覆盖', destination.path);
    }

    await root.create(recursive: true);
    final staging = Directory(
      p.join(
        root.path,
        '.ishkafel-migration-$pid-${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    await staging.create();

    try {
      final sourceHashes = <String, String>{};
      var totalBytes = 0;
      await for (final entity in source.list(
        recursive: true,
        followLinks: false,
      )) {
        final relative = p.relative(entity.path, from: source.path);
        if (entity is Directory) {
          await Directory(
            p.join(staging.path, relative),
          ).create(recursive: true);
          continue;
        }
        if (entity is! File) {
          throw FileSystemException('数据目录含不支持的链接或特殊文件', entity.path);
        }
        final target = File(p.join(staging.path, relative));
        await target.parent.create(recursive: true);
        final sourceHash = await _sha256(entity);
        await copyFile(entity, target);
        final targetHash = await _sha256(target);
        if (sourceHash != targetHash ||
            await entity.length() != await target.length()) {
          throw FileSystemException('复制校验失败', relative);
        }
        sourceHashes[relative] = sourceHash;
        totalBytes += await entity.length();
      }

      if (await destination.exists()) await destination.delete();
      await staging.rename(destination.path);
      activateStorageRoot(root.path);
      return StorageMigrationReport(
        sourceDataDirectory: source.path,
        destinationDataDirectory: destination.path,
        fileCount: sourceHashes.length,
        totalBytes: totalBytes,
        sha256ByRelativePath: Map.unmodifiable(sourceHashes),
      );
    } catch (_) {
      if (await staging.exists()) await staging.delete(recursive: true);
      rethrow;
    }
  }

  static void _validateDistinctTrees(
    Directory source,
    Directory root,
    Directory destination,
  ) {
    final sourcePath = p.normalize(source.path).toLowerCase();
    final rootPath = p.normalize(root.path).toLowerCase();
    final destinationPath = p.normalize(destination.path).toLowerCase();
    final overlap =
        sourcePath == rootPath ||
        sourcePath == destinationPath ||
        p.isWithin(sourcePath, rootPath) ||
        p.isWithin(rootPath, sourcePath) ||
        p.isWithin(sourcePath, destinationPath) ||
        p.isWithin(destinationPath, sourcePath);
    if (overlap) {
      throw FileSystemException('新旧存储位置不能相同或相互嵌套', root.path);
    }
  }

  static Future<void> _copyFile(File source, File target) async {
    await source.openRead().pipe(target.openWrite());
  }

  static Future<String> _sha256(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();
}
