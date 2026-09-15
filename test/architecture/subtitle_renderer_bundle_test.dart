import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows bundle 包含独立 Flutter/Skia 字幕进程与固定字体', () {
    final rootCmake = File('windows/CMakeLists.txt').readAsStringSync();
    final rendererCmake =
        File('windows/renderer/CMakeLists.txt').readAsStringSync();
    final rendererMain = File('windows/renderer/main.cpp').readAsStringSync();
    final dartMain = File('lib/main.dart').readAsStringSync();
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final smokeScript =
        File('scripts/windows/test_renderer.ps1').readAsStringSync();
    final workflow =
        File('.github/workflows/windows-ci.yml').readAsStringSync();

    expect(rootCmake, contains('add_subdirectory("renderer")'));
    expect(rootCmake, contains(r'install(TARGETS ${RENDERER_BINARY_NAME}'));
    expect(rendererCmake, contains('ishkafel_renderer'));
    expect(rendererCmake, contains('flutter_wrapper_app'));
    expect(rendererMain, contains('FlutterEngine'));
    expect(rendererMain, contains('subtitleRendererMain'));
    expect(
      rendererMain,
      contains('set_impeller_switch(flutter::ImpellerSwitch::Disabled)'),
    );
    expect(dartMain, contains("@pragma('vm:entry-point')"));
    expect(dartMain, contains('subtitleRendererMain'));
    expect(pubspec, contains('NotoSansCJKsc-Medium.otf'));
    expect(File('assets/fonts/NotoSansCJKsc-Medium.otf').existsSync(), isTrue);
    expect(File('assets/fonts/OFL.txt').existsSync(), isTrue);
    expect(smokeScript, contains('Windows 原生字幕测试'));
    expect(smokeScript, contains('Get-FileHash -Algorithm SHA256'));
    expect(workflow, contains('test_renderer.ps1 -Mode Release'));
  });
}
