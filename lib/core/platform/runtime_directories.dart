import 'dart:io';

import 'package:path/path.dart' as p;

typedef DefaultSupportDirectoryLoader = Future<Directory> Function();

/// Windows 已经把全部运行期写入切到自选存储根时，不再调用 path_provider。
///
/// `getApplicationSupportDirectory()` 会创建默认目录；即使 [RuntimeDirectories]
/// 最终不用它，也会在 C 盘留下空目录。这里仍返回同一个默认路径作为纯 fallback，
/// 但只有未配置存储根时才调用真正的系统 API。
Future<Directory> resolveRuntimeSupportDirectory({
  required String operatingSystem,
  required String? configuredStorageRoot,
  required String fallbackSupportPath,
  required DefaultSupportDirectoryLoader loadDefaultSupportDirectory,
}) {
  if (operatingSystem == 'windows' &&
      configuredStorageRoot != null &&
      configuredStorageRoot.trim().isNotEmpty) {
    return Future.value(Directory(fallbackSupportPath));
  }
  return loadDefaultSupportDirectory();
}

/// GUI 运行期实际读写的目录。
///
/// 默认位置保持不变；显式环境变量用于自动化验收、并行开发环境和故障复现，
/// 避免这些过程碰到用户日常任务。CLI 已支持 ISHKAFEL_DATA_DIR，GUI 也遵循
/// 同一份约定，才能保证两端在测试环境中仍读写同一库。
class RuntimeDirectories {
  final Directory supportDirectory;
  final Map<String, String> environment;
  final String? configuredStorageRoot;

  const RuntimeDirectories({
    required this.supportDirectory,
    this.environment = const {},
    this.configuredStorageRoot,
  });

  Directory get dataDirectory => Directory(
    _override('ISHKAFEL_DATA_DIR') ??
        _underStorageRoot('data') ??
        p.join(supportDirectory.path, 'ishkafel_data'),
  );

  Directory get logDirectory => Directory(
    _override('ISHKAFEL_LOG_DIR') ??
        _underStorageRoot('logs') ??
        p.join(supportDirectory.path, 'logs'),
  );

  String? _underStorageRoot(String child) {
    final root =
        _override('ISHKAFEL_STORAGE_ROOT') ?? _nonBlank(configuredStorageRoot);
    return root == null ? null : p.join(root, child);
  }

  String? _override(String name) {
    return _nonBlank(environment[name]);
  }

  static String? _nonBlank(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}
