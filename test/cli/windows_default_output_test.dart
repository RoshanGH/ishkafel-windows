import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/commands/export_command.dart';
import 'package:ishkafel/cli/commands/script_run_command.dart';
import 'package:ishkafel/core/platform/platform_paths.dart';

void main() {
  final windowsPaths = PlatformPaths(
    operatingSystem: 'windows',
    environment: const {
      'USERPROFILE': r'C:\Users\Mayn',
      'APPDATA': r'C:\Users\Mayn\AppData\Roaming',
      'LOCALAPPDATA': r'C:\Users\Mayn\AppData\Local',
      'TEMP': r'C:\Users\Mayn\AppData\Local\Temp',
    },
    windowsKnownFolder: (name) => switch (name) {
      'Desktop' => r'D:\OneDrive\桌面',
      'My Video' => r'D:\OneDrive\视频',
      _ => null,
    },
  );

  test('常规 CLI 导出默认进入 Windows 视频 Known Folder', () {
    expect(
      defaultExportDirectory('task-01', paths: windowsPaths).path,
      r'D:\OneDrive\视频\ishkafel-task-01',
    );
  });

  test('脚本成片 CLI 默认进入 Windows 视频 Known Folder', () {
    expect(
      defaultScriptExportDirectory(paths: windowsPaths),
      r'D:\OneDrive\视频\ishkafel-脚本成片',
    );
  });
}
