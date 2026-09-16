import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/platform/runtime_directories.dart';
import 'package:path/path.dart' as p;

void main() {
  group('RuntimeDirectories', () {
    test('默认继续使用系统应用支持目录，保持现有用户数据位置不变', () {
      final support = Directory(p.join('C:', 'Users', 'Mayn', 'AppData', 'Roaming', 'app'));
      final paths = RuntimeDirectories(supportDirectory: support, environment: const {});

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
        environment: const {
          'ISHKAFEL_DATA_DIR': '   ',
          'ISHKAFEL_LOG_DIR': '',
        },
      );

      expect(paths.dataDirectory.path, p.join(support.path, 'ishkafel_data'));
      expect(paths.logDirectory.path, p.join(support.path, 'logs'));
    });
  });
}
