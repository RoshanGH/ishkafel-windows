import 'dart:io';

import 'package:path/path.dart' as p;

/// GUI 运行期实际读写的目录。
///
/// 默认位置保持不变；显式环境变量用于自动化验收、并行开发环境和故障复现，
/// 避免这些过程碰到用户日常任务。CLI 已支持 ISHKAFEL_DATA_DIR，GUI 也遵循
/// 同一份约定，才能保证两端在测试环境中仍读写同一库。
class RuntimeDirectories {
  final Directory supportDirectory;
  final Map<String, String> environment;

  const RuntimeDirectories({
    required this.supportDirectory,
    this.environment = const {},
  });

  Directory get dataDirectory => Directory(
        _override('ISHKAFEL_DATA_DIR') ??
            p.join(supportDirectory.path, 'ishkafel_data'),
      );

  Directory get logDirectory => Directory(
        _override('ISHKAFEL_LOG_DIR') ?? p.join(supportDirectory.path, 'logs'),
      );

  String? _override(String name) {
    final value = environment[name]?.trim();
    return value == null || value.isEmpty ? null : value;
  }
}
