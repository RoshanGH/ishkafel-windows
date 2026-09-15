import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/platform/platform_shell.dart';

void main() {
  group('PlatformShell', () {
    test('Windows 用资源管理器打开目录并选中文件', () async {
      final calls = <(String, List<String>)>[];
      final shell = PlatformShell(
        operatingSystem: 'windows',
        run: (name, arguments) async {
          calls.add((name, arguments));
          return ProcessResult(1, 0, '', '');
        },
      );

      await shell.openPath(r'C:\成片 目录');
      await shell.revealPath(r'C:\成片 目录\片子.mp4');

      expect(calls, hasLength(2));
      expect(calls[0].$1, 'explorer.exe');
      expect(calls[0].$2, [r'C:\成片 目录']);
      expect(calls[1].$1, 'explorer.exe');
      expect(calls[1].$2, ['/select,', r'C:\成片 目录\片子.mp4']);
      expect(shell.revealLabel, '在文件资源管理器中显示');
    });

    test('macOS 保持 open 与 open -R 语义', () async {
      final calls = <(String, List<String>)>[];
      final shell = PlatformShell(
        operatingSystem: 'macos',
        run: (name, arguments) async {
          calls.add((name, arguments));
          return ProcessResult(1, 0, '', '');
        },
      );

      await shell.openPath('/Users/me/Movies');
      await shell.revealPath('/Users/me/Movies/a.mp4');

      expect(calls, hasLength(2));
      expect(calls[0].$1, 'open');
      expect(calls[0].$2, ['/Users/me/Movies']);
      expect(calls[1].$1, 'open');
      expect(calls[1].$2, ['-R', '/Users/me/Movies/a.mp4']);
      expect(shell.revealLabel, '在访达中显示');
    });

    test('系统打开失败时把 stderr 变成可展示异常', () async {
      final shell = PlatformShell(
        operatingSystem: 'windows',
        run: (_, _) async => ProcessResult(1, 2, '', 'access denied'),
      );

      await expectLater(
        shell.openPath(r'C:\不存在'),
        throwsA(isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('access denied'),
        )),
      );
    });

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
