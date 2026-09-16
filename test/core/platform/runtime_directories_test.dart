import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/platform/runtime_directories.dart';
import 'package:path/path.dart' as p;

void main() {
  group('resolveRuntimeSupportDirectory', () {
    test('Windows 已配置存储根时不调用会创建 C 盘目录的系统 API', () async {
      var defaultDirectoryRequested = false;

      final support = await resolveRuntimeSupportDirectory(
        operatingSystem: 'windows',
        configuredStorageRoot: r'D:\Ishkafel\UserData',
        fallbackSupportPath:
            r'C:\Users\Mayn\AppData\Roaming\com.jichuang\ishkafel',
        loadDefaultSupportDirectory: () async {
          defaultDirectoryRequested = true;
          return Directory(r'C:\created-by-path-provider');
        },
      );

      expect(defaultDirectoryRequested, isFalse);
      expect(
        support.path,
        r'C:\Users\Mayn\AppData\Roaming\com.jichuang\ishkafel',
      );
    });

    test('没有配置存储根时继续使用系统默认目录 API', () async {
      final support = await resolveRuntimeSupportDirectory(
        operatingSystem: 'windows',
        configuredStorageRoot: null,
        fallbackSupportPath: r'C:\fallback-only',
        loadDefaultSupportDirectory: () async =>
            Directory(r'C:\created-by-path-provider'),
      );

      expect(support.path, r'C:\created-by-path-provider');
    });
  });

  group('RuntimeDirectories', () {
    test('默认继续使用系统应用支持目录，保持现有用户数据位置不变', () {
      final support = Directory(
        p.join('C:', 'Users', 'Mayn', 'AppData', 'Roaming', 'app'),
      );
      final paths = RuntimeDirectories(
        supportDirectory: support,
        environment: const {},
      );

      expect(paths.dataDirectory.path, p.join(support.path, 'ishkafel_data'));
      expect(paths.logDirectory.path, p.join(support.path, 'logs'));
    });

    test('真机测试与多环境可分别隔离数据和日志', () {
      final paths = RuntimeDirectories(
        supportDirectory: Directory(r'C:\real-user-data'),
        environment: const {
          'ISHKAFEL_DATA_DIR': r'D:\隔离 测试\data',
          'ISHKAFEL_LOG_DIR': r'D:\隔离 测试\logs',
        },
      );

      expect(paths.dataDirectory.path, r'D:\隔离 测试\data');
      expect(paths.logDirectory.path, r'D:\隔离 测试\logs');
    });

    test('空白覆盖值不改变默认位置', () {
      final support = Directory(r'C:\support');
      final paths = RuntimeDirectories(
        supportDirectory: support,
        environment: const {'ISHKAFEL_DATA_DIR': '   ', 'ISHKAFEL_LOG_DIR': ''},
      );

      expect(paths.dataDirectory.path, p.join(support.path, 'ishkafel_data'));
      expect(paths.logDirectory.path, p.join(support.path, 'logs'));
    });

    test('Windows 用户选择的存储根目录同时承载数据和日志', () {
      final paths = RuntimeDirectories(
        supportDirectory: Directory(r'C:\support'),
        environment: const {},
        configuredStorageRoot: r'D:\Ishkafel\UserData',
      );

      expect(paths.dataDirectory.path, r'D:\Ishkafel\UserData\data');
      expect(paths.logDirectory.path, r'D:\Ishkafel\UserData\logs');
    });

    test('环境变量优先于 Windows 用户设置', () {
      final paths = RuntimeDirectories(
        supportDirectory: Directory(r'C:\support'),
        configuredStorageRoot: r'D:\configured',
        environment: const {
          'ISHKAFEL_STORAGE_ROOT': r'E:\automated',
          'ISHKAFEL_DATA_DIR': r'F:\explicit-data',
          'ISHKAFEL_LOG_DIR': r'F:\explicit-logs',
        },
      );

      expect(paths.dataDirectory.path, r'F:\explicit-data');
      expect(paths.logDirectory.path, r'F:\explicit-logs');
    });

    test('存储根目录环境变量派生 data 和 logs 子目录', () {
      final paths = RuntimeDirectories(
        supportDirectory: Directory(r'C:\support'),
        configuredStorageRoot: r'D:\configured',
        environment: const {'ISHKAFEL_STORAGE_ROOT': r'E:\Ishkafel User'},
      );

      expect(paths.dataDirectory.path, r'E:\Ishkafel User\data');
      expect(paths.logDirectory.path, r'E:\Ishkafel User\logs');
    });
  });
}
