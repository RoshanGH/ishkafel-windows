import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows runner 固定默认尺寸、最小尺寸、居中和 DPI 最小客户区', () {
    final main = File('windows/runner/main.cpp').readAsStringSync();
    final header = File('windows/runner/win32_window.h').readAsStringSync();
    final implementation =
        File('windows/runner/win32_window.cpp').readAsStringSync();

    expect(main, contains('Win32Window::Size size(1440, 900)'));
    expect(main, contains('Win32Window::Size minimum_size(1100, 880)'));
    expect(main, contains('window.SetMinimumSize(minimum_size)'));
    expect(main, contains('window.CenterOnCurrentMonitor()'));
    expect(header, contains('void SetMinimumSize'));
    expect(header, contains('void CenterOnCurrentMonitor'));
    expect(implementation, contains('WM_GETMINMAXINFO'));
    expect(implementation, contains('FlutterDesktopGetDpiForHWND'));
    expect(implementation, contains('AdjustWindowRectExForDpi'));
  });
}
