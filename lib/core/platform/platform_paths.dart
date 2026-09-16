import 'dart:io';

import 'package:path/path.dart' as p;

import 'windows_storage_preferences.dart';

const String ishkafelBundleId = 'com.jichuang.ishkafel';
const String ishkafelCompanyName = 'com.jichuang';
const String ishkafelProductName = 'ishkafel';

typedef WindowsKnownFolderReader = String? Function(String valueName);

/// CLI 与 GUI 共用的系统目录契约。
///
/// Windows 的应用支持目录必须复刻 path_provider 从 Runner.rc 读取
/// CompanyName/ProductName 后的规则，否则两个进程会各自看到一套任务。
class PlatformPaths {
  final String operatingSystem;
  final Map<String, String> environment;
  final WindowsKnownFolderReader windowsKnownFolder;
  final WindowsStorageValueReader windowsStorageValue;

  PlatformPaths({
    String? operatingSystem,
    Map<String, String>? environment,
    WindowsKnownFolderReader? windowsKnownFolder,
    WindowsStorageValueReader? windowsStorageValue,
  }) : operatingSystem = operatingSystem ?? Platform.operatingSystem,
       environment = Map.unmodifiable(environment ?? Platform.environment),
       windowsKnownFolder = windowsKnownFolder ?? _readWindowsUserShellFolder,
       windowsStorageValue =
           windowsStorageValue ??
           WindowsStoragePreferences(
             operatingSystem: operatingSystem ?? Platform.operatingSystem,
           ).readValue;

  p.Context get _path => p.Context(
    style: operatingSystem == 'windows' ? p.Style.windows : p.Style.posix,
  );

  String get userHome =>
      _required(operatingSystem == 'windows' ? 'USERPROFILE' : 'HOME');

  String get videosDirectory => operatingSystem == 'windows'
      ? _windowsKnownFolder('My Video') ?? _path.join(userHome, 'Videos')
      : _path.join(userHome, operatingSystem == 'macos' ? 'Movies' : 'Videos');

  String get desktopDirectory => operatingSystem == 'windows'
      ? _windowsKnownFolder('Desktop') ?? _path.join(userHome, 'Desktop')
      : _path.join(userHome, 'Desktop');

  String get temporaryDirectory => switch (operatingSystem) {
    'windows' =>
      _nonBlank(environment['TEMP']) ??
          _nonBlank(environment['TMP']) ??
          _path.join(localApplicationData, 'Temp'),
    _ => _nonBlank(environment['TMPDIR']) ?? '/tmp',
  };

  String get applicationSupport => switch (operatingSystem) {
    'windows' => _path.join(
      _required('APPDATA'),
      ishkafelCompanyName,
      ishkafelProductName,
    ),
    'macos' => _path.join(
      _required('HOME'),
      'Library',
      'Application Support',
      ishkafelBundleId,
    ),
    _ => _path.join(
      _nonBlank(environment['XDG_DATA_HOME']) ??
          _path.join(_required('HOME'), '.local', 'share'),
      ishkafelBundleId,
    ),
  };

  String get localApplicationData => switch (operatingSystem) {
    'windows' => _path.join(
      _required('LOCALAPPDATA'),
      ishkafelCompanyName,
      ishkafelProductName,
    ),
    'macos' => _path.join(
      _required('HOME'),
      'Library',
      'Caches',
      ishkafelBundleId,
    ),
    _ => _path.join(
      _nonBlank(environment['XDG_CACHE_HOME']) ??
          _path.join(_required('HOME'), '.cache'),
      ishkafelBundleId,
    ),
  };

  String? get configuredStorageRoot =>
      _nonBlank(environment['ISHKAFEL_STORAGE_ROOT']) ??
      (operatingSystem == 'windows'
          ? _nonBlank(windowsStorageValue(storageRootValueName))
          : null);

  String get dataDir =>
      _nonBlank(environment['ISHKAFEL_DATA_DIR']) ??
      _underConfiguredStorage('data') ??
      _path.join(applicationSupport, 'ishkafel_data');

  String? _underConfiguredStorage(String child) {
    final root = configuredStorageRoot;
    return root == null ? null : _path.join(root, child);
  }

  bool isTemporaryPath(String candidate) {
    bool sameOrWithin(String root) {
      final normalizedRoot = _path.normalize(root);
      final normalizedCandidate = _path.normalize(candidate);
      if (operatingSystem == 'windows') {
        final left = normalizedRoot.toLowerCase();
        final right = normalizedCandidate.toLowerCase();
        return left == right || _path.isWithin(left, right);
      }
      return normalizedRoot == normalizedCandidate ||
          _path.isWithin(normalizedRoot, normalizedCandidate);
    }

    if (sameOrWithin(temporaryDirectory)) return true;
    return operatingSystem == 'macos' && sameOrWithin('/private/tmp');
  }

  String? _windowsKnownFolder(String valueName) {
    final value = _nonBlank(windowsKnownFolder(valueName));
    return value == null ? null : _expandWindowsEnvironment(value);
  }

  String _expandWindowsEnvironment(String value) {
    return value.replaceAllMapped(RegExp(r'%([^%]+)%'), (match) {
      final name = match.group(1)!;
      for (final entry in environment.entries) {
        if (entry.key.toLowerCase() == name.toLowerCase()) return entry.value;
      }
      return match.group(0)!;
    });
  }

  static String? _readWindowsUserShellFolder(String valueName) {
    if (!Platform.isWindows) return null;
    try {
      final result = Process.runSync('reg.exe', [
        'query',
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders',
        '/v',
        valueName,
      ], runInShell: false);
      if (result.exitCode != 0) return null;
      final output = result.stdout.toString();
      final pattern = RegExp(
        '^\\s*${RegExp.escape(valueName)}\\s+REG_(?:EXPAND_)?SZ\\s+(.+?)\\s*\$',
        caseSensitive: false,
        multiLine: true,
      );
      return _nonBlank(pattern.firstMatch(output)?.group(1));
    } catch (_) {
      return null;
    }
  }

  String _required(String name) {
    final value = _nonBlank(environment[name]);
    if (value == null) {
      throw StateError('读不到 $name，无法定位 Ishkafel 系统目录');
    }
    return value;
  }

  static String? _nonBlank(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}
