import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/console_encoding.dart';

void main() {
  test('Windows 同时把输入和输出代码页设为 UTF-8', () {
    final calls = <String>[];
    final configured = configureConsoleEncoding(
      operatingSystem: 'windows',
      setInputCodePage: (codePage) {
        calls.add('in:$codePage');
        return true;
      },
      setOutputCodePage: (codePage) {
        calls.add('out:$codePage');
        return true;
      },
    );

    expect(configured, isTrue);
    expect(calls, ['in:65001', 'out:65001']);
  });

  test('非 Windows 不调用 Win32 API', () {
    final configured = configureConsoleEncoding(
      operatingSystem: 'macos',
      setInputCodePage: (_) => fail('macOS 不应调用 SetConsoleCP'),
      setOutputCodePage: (_) => fail('macOS 不应调用 SetConsoleOutputCP'),
    );
    expect(configured, isFalse);
  });

  test('CLI 在解析参数前建立编码契约，Windows shim 也设置代码页', () {
    final entry = File('bin/ishkafel.dart').readAsStringSync();
    final setup = entry.indexOf('configureConsoleEncoding();');
    final parser = entry.indexOf('ArgParser()');
    expect(setup, greaterThanOrEqualTo(0));
    expect(setup, lessThan(parser));

    final buildScript = File(
      'scripts/windows/build_cli.ps1',
    ).readAsStringSync();
    expect(buildScript, contains('chcp 65001 >nul'));
    expect(buildScript, contains(r'%~dp0ishkafel.exe'));
  });
}
