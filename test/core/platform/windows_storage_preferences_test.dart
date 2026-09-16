import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/platform/windows_storage_preferences.dart';

void main() {
  group('WindowsStoragePreferences', () {
    test('从当前用户注册表读取数据和导出位置', () {
      final commands = <List<String>>[];
      final preferences = WindowsStoragePreferences(
        operatingSystem: 'windows',
        runSync: (executable, arguments) {
          commands.add([executable, ...arguments]);
          final value = arguments.last == storageRootValueName
              ? r'D:\Ishkafel\UserData'
              : r'D:\Ishkafel\Media\Exports';
          return ProcessResult(
            1,
            0,
            '    ${arguments.last}    REG_SZ    $value\r\n',
            '',
          );
        },
      );

      expect(preferences.readStorageRoot(), r'D:\Ishkafel\UserData');
      expect(preferences.readExportRoot(), r'D:\Ishkafel\Media\Exports');
      expect(commands, everyElement(contains(windowsStorageRegistryKey)));
    });

    test('注册表不存在或值为空时视为未配置', () {
      final missing = WindowsStoragePreferences(
        operatingSystem: 'windows',
        runSync: (_, arguments) => ProcessResult(1, 1, '', 'not found'),
      );
      final blank = WindowsStoragePreferences(
        operatingSystem: 'windows',
        runSync: (_, arguments) =>
            ProcessResult(1, 0, 'StorageRoot REG_SZ    ', ''),
      );

      expect(missing.readStorageRoot(), isNull);
      expect(blank.readStorageRoot(), isNull);
    });

    test('非 Windows 不运行 reg.exe', () {
      var calls = 0;
      final preferences = WindowsStoragePreferences(
        operatingSystem: 'macos',
        runSync: (_, arguments) {
          calls++;
          return ProcessResult(1, 0, '', '');
        },
      );

      expect(preferences.readStorageRoot(), isNull);
      expect(preferences.readExportRoot(), isNull);
      expect(calls, 0);
    });

    test('保存位置写入当前用户注册表且保留含空格路径', () {
      final commands = <List<String>>[];
      final preferences = WindowsStoragePreferences(
        operatingSystem: 'windows',
        runSync: (executable, arguments) {
          commands.add([executable, ...arguments]);
          return ProcessResult(1, 0, '', '');
        },
      );

      preferences.writeStorageRoot(r'D:\Ishkafel Data\UserData');
      preferences.writeExportRoot(r'D:\Ishkafel Data\Media\Exports');

      expect(commands[0], [
        'reg.exe',
        'add',
        windowsStorageRegistryKey,
        '/v',
        storageRootValueName,
        '/t',
        'REG_SZ',
        '/d',
        r'D:\Ishkafel Data\UserData',
        '/f',
      ]);
      expect(commands[1], contains(exportRootValueName));
      expect(commands[1], contains(r'D:\Ishkafel Data\Media\Exports'));
    });

    test('注册表写入失败时明确抛错而不是假装保存成功', () {
      final preferences = WindowsStoragePreferences(
        operatingSystem: 'windows',
        runSync: (_, arguments) => ProcessResult(1, 5, '', 'Access is denied.'),
      );

      expect(
        () => preferences.writeStorageRoot(r'D:\Ishkafel\UserData'),
        throwsA(isA<FileSystemException>()),
      );
    });
  });
}
