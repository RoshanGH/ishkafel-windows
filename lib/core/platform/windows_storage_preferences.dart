import 'dart:io';

const String windowsStorageRegistryKey = r'HKCU\Software\RoshanGH\Ishkafel';
const String storageRootValueName = 'StorageRoot';
const String exportRootValueName = 'ExportRoot';

typedef RegistryProcessRunner =
    ProcessResult Function(String executable, List<String> arguments);
typedef WindowsStorageValueReader = String? Function(String valueName);

/// Windows 用户级存储位置。
///
/// 只存两个短路径值，不把业务数据或凭据写进注册表。同步调用只发生在启动和
/// 用户主动保存设置时，避免为很短的 `reg.exe` 调用引入异步初始化竞态。
class WindowsStoragePreferences {
  final String operatingSystem;
  final RegistryProcessRunner runSync;

  WindowsStoragePreferences({
    String? operatingSystem,
    RegistryProcessRunner? runSync,
  }) : operatingSystem = operatingSystem ?? Platform.operatingSystem,
       runSync = runSync ?? _runRegistry;

  String? readStorageRoot() => _read(storageRootValueName);

  String? readExportRoot() => _read(exportRootValueName);

  String? readValue(String valueName) => _read(valueName);

  void writeStorageRoot(String path) => _write(storageRootValueName, path);

  void writeExportRoot(String path) => _write(exportRootValueName, path);

  String? _read(String valueName) {
    if (operatingSystem != 'windows') return null;
    try {
      final result = runSync('reg.exe', [
        'query',
        windowsStorageRegistryKey,
        '/v',
        valueName,
      ]);
      if (result.exitCode != 0) return null;
      final match = RegExp(
        '^\\s*${RegExp.escape(valueName)}\\s+REG_(?:EXPAND_)?SZ\\s+(.+?)\\s*\$',
        caseSensitive: false,
        multiLine: true,
      ).firstMatch(result.stdout.toString());
      return _nonBlank(match?.group(1));
    } catch (_) {
      return null;
    }
  }

  void _write(String valueName, String path) {
    final value = _nonBlank(path);
    if (operatingSystem != 'windows') {
      throw const FileSystemException('存储位置设置只支持 Windows');
    }
    if (value == null) {
      throw const FileSystemException('存储位置不能为空');
    }
    final result = runSync('reg.exe', [
      'add',
      windowsStorageRegistryKey,
      '/v',
      valueName,
      '/t',
      'REG_SZ',
      '/d',
      value,
      '/f',
    ]);
    if (result.exitCode != 0) {
      throw FileSystemException(
        '保存 Windows 存储位置失败（exit=${result.exitCode}）',
        value,
      );
    }
  }

  static ProcessResult _runRegistry(
    String executable,
    List<String> arguments,
  ) => Process.runSync(executable, arguments, runInShell: false);

  static String? _nonBlank(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}
