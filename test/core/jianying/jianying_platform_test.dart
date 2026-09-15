import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/jianying/jianying_writer.dart';
import 'package:ishkafel/core/platform/platform_shell.dart';

void main() {
  test('Windows 剪映草稿写进 LOCALAPPDATA 的真实默认目录', () {
    expect(
      defaultJianyingRoot(
        operatingSystem: 'windows',
        environment: const {'LOCALAPPDATA': r'D:\用户 数据\Local'},
      ),
      r'D:\用户 数据\Local\JianyingPro\User Data\Projects\com.lveditor.draft',
    );
  });

  test('macOS 剪映草稿目录保持现有 Movies 契约', () {
    expect(
      defaultJianyingRoot(
        operatingSystem: 'macos',
        environment: const {'HOME': '/Users/mayn'},
      ),
      '/Users/mayn/Movies/JianyingPro/User Data/Projects/com.lveditor.draft',
    );
  });

  test('系统根目录缺失时明确失败，不写入当前目录', () {
    expect(
      () => defaultJianyingRoot(
        operatingSystem: 'windows',
        environment: const {},
      ),
      throwsStateError,
    );
  });

  test('Windows 剪映启动优先使用显式覆盖路径', () async {
    final calls = <(String, List<String>)>[];
    final shell = PlatformShell(
      operatingSystem: 'windows',
      run: (name, arguments) async {
        calls.add((name, arguments));
        return ProcessResult(1, 0, '', '');
      },
    );

    await launchJianying(
      shell: shell,
      environment: const {
        'ISHKAFEL_JIANYING_APP': r'D:\剪映 专业版\JianyingPro.exe',
      },
      exists: (path) => path == r'D:\剪映 专业版\JianyingPro.exe',
    );

    expect(calls, hasLength(1));
    expect(calls.single.$1, r'D:\剪映 专业版\JianyingPro.exe');
    expect(calls.single.$2, isEmpty);
  });

  test('Windows 能从 LOCALAPPDATA 默认安装位置发现剪映', () {
    const expected = r'C:\Users\mayn\AppData\Local\JianyingPro\JianyingPro.exe';
    expect(
      resolveJianyingExecutable(
        environment: const {
          'LOCALAPPDATA': r'C:\Users\mayn\AppData\Local',
        },
        exists: (path) => path == expected,
      ),
      expected,
    );
  });

  test('Windows 找不到剪映时给出可执行的配置提示', () async {
    await expectLater(
      launchJianying(
        shell: PlatformShell(operatingSystem: 'windows'),
        environment: const {},
        exists: (_) => false,
      ),
      throwsA(isA<StateError>().having(
        (error) => error.message,
        'message',
        allOf(contains('找不到剪映'), contains('ISHKAFEL_JIANYING_APP')),
      )),
    );
  });

  test('macOS 启动仍使用 VideoFusion-macOS app 名', () async {
    final calls = <(String, List<String>)>[];
    final shell = PlatformShell(
      operatingSystem: 'macos',
      run: (name, arguments) async {
        calls.add((name, arguments));
        return ProcessResult(1, 0, '', '');
      },
    );

    await launchJianying(shell: shell);

    expect(calls.single.$1, 'open');
    expect(calls.single.$2, ['-a', 'VideoFusion-macOS']);
  });
}
