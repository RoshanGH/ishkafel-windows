import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/platform/platform_shell.dart';

void main() {
  group('PlatformShell', () {
    test('Windows 用 where.exe 并接受中文和空格路径', () {
      String? command;
      List<String>? arguments;
      final shell = PlatformShell(
        operatingSystem: 'windows',
        runSync: (name, args) {
          command = name;
          arguments = args;
          return ProcessResult(
            1,
            0,
            'C:\\工具\\ffmpeg.exe\r\nD:\\另一个\\ffmpeg.exe\r\n',
            '',
          );
        },
      );

      expect(shell.lookupOnPath('ffmpeg'), r'C:\工具\ffmpeg.exe');
      expect(command, 'where.exe');
      expect(arguments, ['ffmpeg']);
      expect(shell.pathSeparator, ';');
    });

    test('macOS 用绝对 which 并以冒号分隔 PATH', () {
      final shell = PlatformShell(
        operatingSystem: 'macos',
        runSync: (_, _) =>
            ProcessResult(1, 0, '/opt/homebrew/bin/ffmpeg\n', ''),
      );

      expect(shell.lookupOnPath('ffmpeg'), '/opt/homebrew/bin/ffmpeg');
      expect(shell.pathSeparator, ':');
    });

    test('Windows tasklist 精确匹配 PID', () {
      final shell = PlatformShell(
        operatingSystem: 'windows',
        runSync: (_, _) => ProcessResult(
          1,
          0,
          '"ishkafel.exe","4242","Console","1","10 K"\r\n',
          '',
        ),
      );

      expect(shell.isProcessAlive(4242), isTrue);
      expect(shell.isProcessAlive(42), isFalse);
    });
  });
}
