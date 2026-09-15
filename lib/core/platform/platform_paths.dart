import 'dart:io';

import 'package:path/path.dart' as p;

const String ishkafelBundleId = 'com.jichuang.ishkafel';
const String ishkafelCompanyName = 'com.jichuang';
const String ishkafelProductName = 'ishkafel';

/// CLI 与 GUI 共用的系统目录契约。
///
/// Windows 的应用支持目录必须复刻 path_provider 从 Runner.rc 读取
/// CompanyName/ProductName 后的规则，否则两个进程会各自看到一套任务。
class PlatformPaths {
  final String operatingSystem;
  final Map<String, String> environment;

  PlatformPaths({
    String? operatingSystem,
    Map<String, String>? environment,
  })  : operatingSystem = operatingSystem ?? Platform.operatingSystem,
        environment = Map.unmodifiable(environment ?? Platform.environment);

  p.Context get _path => p.Context(
        style: operatingSystem == 'windows' ? p.Style.windows : p.Style.posix,
      );

  String get userHome =>
      _required(operatingSystem == 'windows' ? 'USERPROFILE' : 'HOME');

  String get videosDirectory =>
      _path.join(userHome, operatingSystem == 'macos' ? 'Movies' : 'Videos');

  String get desktopDirectory => _path.join(userHome, 'Desktop');

  String get applicationSupport => switch (operatingSystem) {
        'windows' => _path.join(
            _required('APPDATA'), ishkafelCompanyName, ishkafelProductName),
        'macos' => _path.join(_required('HOME'), 'Library',
            'Application Support', ishkafelBundleId),
        _ => _path.join(
            _nonBlank(environment['XDG_DATA_HOME']) ??
                _path.join(_required('HOME'), '.local', 'share'),
            ishkafelBundleId),
      };

  String get localApplicationData => switch (operatingSystem) {
        'windows' => _path.join(
            _required('LOCALAPPDATA'), ishkafelCompanyName, ishkafelProductName),
        'macos' => _path.join(_required('HOME'), 'Library', 'Caches',
            ishkafelBundleId),
        _ => _path.join(
            _nonBlank(environment['XDG_CACHE_HOME']) ??
                _path.join(_required('HOME'), '.cache'),
            ishkafelBundleId),
      };

  String get dataDir => _path.join(applicationSupport, 'ishkafel_data');

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
