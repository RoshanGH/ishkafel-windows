import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows 真机视觉验收有可重复截图入口', () {
    final file = File('scripts/windows/capture_app.ps1');
    expect(file.existsSync(), isTrue);
    final source = file.readAsStringSync();
    expect(source, contains('SetForegroundWindow'));
    expect(source, contains('GetWindowRect'));
    expect(source, contains('GetClientRect'));
    expect(source, contains('ClientToScreen'));
    expect(source, contains('CopyFromScreen'));
    expect(source, contains('windows-task-list.png'));
    expect(source, contains('1440x900 基准'));
  });
}
