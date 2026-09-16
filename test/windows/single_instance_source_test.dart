import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows runner 用命名互斥保证单实例，并唤醒已有窗口', () {
    final source = File('windows/runner/main.cpp').readAsStringSync();

    expect(source, contains('CreateMutexW'));
    expect(source, contains('ERROR_ALREADY_EXISTS'));
    expect(source, contains('FindWindowW'));
    expect(source, contains('SW_RESTORE'));
    expect(source, contains('SetForegroundWindow'));
    expect(source, contains('CloseHandle'));
  });
}
