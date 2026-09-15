import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/app/theme/app_typography.dart';

void main() {
  test('Windows 正式构建只能走注入全部配置的脚本', () {
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
      'UPDATE_TOS_MANIFEST_KEY',
    ]) {
      expect(script, contains(name), reason: '$name 没有进入构建配置');
    }
    expect(
      script,
      contains(r'--dart-define=$($entry.Key)=$($entry.Value)'),
      reason: '构建配置没有转换成 flutter 的 dart define 参数',
    );
    expect(
      script,
      isNot(contains(r'Write-Output $value')),
      reason: '构建日志不许回显 secret',
    );
  });

  test('Windows CLI 有独立构建入口', () {
    final script = File('scripts/windows/build_cli.ps1').readAsStringSync();
    final appScript = File('scripts/windows/build_app.ps1').readAsStringSync();
    final cmake = File('windows/CMakeLists.txt').readAsStringSync();
    expect(script, contains('dart build cli'));
    expect(script, contains('ishkafel.exe'));
    expect(appScript, contains("build_cli.ps1"));
    expect(cmake, contains('build/cli/windows_x64/bundle'));
    expect(cmake, contains(r'DESTINATION "${CMAKE_INSTALL_PREFIX}/cli"'));
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
      'scripts/windows/capture_app.ps1',
      'scripts/windows/package_app.ps1',
      'scripts/windows/prepare_media_tools.ps1',
      'scripts/windows/sync_upstream.ps1',
      'scripts/windows/test_distribution.ps1',
      'scripts/windows/test_media_pipeline.ps1',
      'scripts/windows/test_renderer.ps1',
    ]) {
      final bytes = File(path).readAsBytesSync();
      final hasUtf8Bom =
          bytes.length >= 3 &&
          bytes[0] == 0xef &&
          bytes[1] == 0xbb &&
          bytes[2] == 0xbf;
      final isAscii = bytes.every((byte) => byte < 0x80);
      expect(
        hasUtf8Bom || isAscii,
        isTrue,
        reason: '$path 必须带 UTF-8 BOM，或只含 ASCII',
      );
    }
  });

  test('Windows CI 同时守住 analyze、test、CLI 和 app', () {
    final workflow = File(
      '.github/workflows/windows-ci.yml',
    ).readAsStringSync();
    expect(workflow, contains("flutter-version: '3.47.4'"));
    expect(workflow, contains('flutter analyze'));
    expect(workflow, contains('flutter test'));
    expect(workflow, contains('./scripts/windows/build_cli.ps1'));
    expect(workflow, contains('flutter build windows --release'));
    expect(workflow, contains('./scripts/windows/prepare_media_tools.ps1'));
    expect(workflow, contains('./scripts/windows/test_media_pipeline.ps1'));
  });

  test('业务页面不直接调用 macOS open', () {
    for (final path in const [
      'lib/features/export/export_dialog.dart',
      'lib/features/settings/sections/about_section.dart',
      'lib/features/workbench/workbench_page.dart',
      'lib/features/director/director_page.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(
        source,
        isNot(contains("Process.run('open'")),
        reason: '$path 必须通过 PlatformShell 处理 Windows/macOS 差异',
      );
    }
  });

  test('1440×900 指客户区，不让 Windows 标题栏吃掉产品画布', () {
    final source = File('windows/runner/win32_window.cpp').readAsStringSync();
    final create = source.substring(
      source.indexOf('bool Win32Window::Create('),
      source.indexOf('bool Win32Window::Show()'),
    );
    expect(create, contains('AdjustWindowRectExForDpi'));
    expect(create, contains('desired_client'));
    expect(
      create.indexOf('AdjustWindowRectExForDpi'),
      lessThan(create.indexOf('CreateWindow(')),
    );
  });

  test('业务页面不使用 HOME 手工拼 Windows 用户目录', () {
    for (final path in const [
      'lib/features/director/director_page.dart',
      'lib/features/settings/agent_skill_card.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(
        source,
        isNot(contains("Platform.environment['HOME']")),
        reason: '$path 必须通过 PlatformPaths 解析桌面目录',
      );
    }
  });

  test('Mac 同步只能开 PR，不能自动合并', () {
    final local = File('scripts/windows/sync_upstream.ps1').readAsStringSync();
    final workflow = File(
      '.github/workflows/sync-upstream.yml',
    ).readAsStringSync();
    expect(local, contains('git fetch upstream main'));
    expect(local, contains('git merge --no-edit upstream/main'));
    expect(workflow, contains('schedule:'));
    expect(workflow, contains('workflow_dispatch:'));
    expect(workflow, contains('gh pr create'));
    expect(
      workflow,
      isNot(contains('gh pr merge')),
      reason: '上游更新必须通过 Windows CI 和人工复核',
    );
  });

  test('Windows 仓库身份与差异清单有唯一入口', () {
    final readme = File('README.md').readAsStringSync();
    final agent = File('CLAUDE.md').readAsStringSync();
    final differences = File('docs/platform-differences.md').readAsStringSync();
    expect(readme, contains('RoshanGH/ishkafel-windows'));
    expect(readme, contains('upstream'));
    expect(agent, contains('scripts/windows/build_app.ps1'));
    expect(agent, contains('未登记的平台差异 = bug'));
    expect(differences, contains('Windows 原生标题栏'));
    expect(differences, contains('Ctrl'));
    expect(differences, contains('资源管理器'));
    expect(differences, contains('Videos'));
  });

  test('Windows 等宽文本使用系统自带 Consolas，不依赖 Mac Menlo', () {
    final typography = File(
      'lib/app/theme/app_typography.dart',
    ).readAsStringSync();
    expect(monospaceFontFamily('windows'), 'Consolas');
    expect(typography, contains("'Consolas'"));
    for (final path in const [
      'lib/features/workbench/tag_trace_section.dart',
      'lib/features/settings/tool_install_panel.dart',
      'lib/features/settings/sections/environment_section.dart',
      'lib/features/settings/sections/account_section.dart',
    ]) {
      expect(
        File(path).readAsStringSync(),
        isNot(contains("fontFamily: 'Menlo'")),
        reason: '$path 不应在 Windows 构建里硬编码 Mac 字体',
      );
    }
  });
}
