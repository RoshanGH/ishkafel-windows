import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows 正式构建只能走注入八个配置的脚本', () {
    final script = File('scripts/windows/build_app.ps1').readAsStringSync();
    for (final name in const [
      'ARK_API_KEY',
      'SPEECH_APP_ID',
      'SPEECH_ACCESS_TOKEN',
      'UPDATE_TOS_REGION',
      'UPDATE_TOS_BUCKET',
      'UPDATE_TOS_ENDPOINT',
      'UPDATE_TOS_AK',
      'UPDATE_TOS_SK',
    ]) {
      expect(script, contains(name), reason: '$name 没有进入构建配置');
    }
    expect(script, contains(r'--dart-define=$($entry.Key)=$($entry.Value)'),
        reason: '八个配置没有转换成 flutter 的 dart define 参数');
    expect(script, isNot(contains(r'Write-Output $value')),
        reason: '构建日志不许回显 secret');
  });

  test('Windows CLI 有独立构建入口', () {
    final script = File('scripts/windows/build_cli.ps1').readAsStringSync();
    expect(script, contains('dart build cli'));
    expect(script, contains('ishkafel.exe'));
  });

  test('跨平台源码保持 LF，PowerShell 保持 CRLF', () {
    final attributes = File('.gitattributes').readAsStringSync();
    expect(attributes, contains('*.dart text eol=lf'));
    expect(attributes, contains('*.md text eol=lf'));
    expect(attributes, contains('*.ps1 text eol=crlf'));
  });

  test('Windows PowerShell 5.1 能按系统代码页安全解析构建脚本', () {
    for (final path in const [
      'scripts/windows/check_environment.ps1',
      'scripts/windows/build_app.ps1',
      'scripts/windows/build_cli.ps1',
    ]) {
      final bytes = File(path).readAsBytesSync();
      final hasUtf8Bom = bytes.length >= 3 &&
          bytes[0] == 0xef &&
          bytes[1] == 0xbb &&
          bytes[2] == 0xbf;
      final isAscii = bytes.every((byte) => byte < 0x80);
      expect(hasUtf8Bom || isAscii, isTrue,
          reason: '$path 必须带 UTF-8 BOM，或只含 ASCII');
    }
  });
}
