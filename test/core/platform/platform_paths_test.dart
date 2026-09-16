import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/platform/platform_paths.dart';

void main() {
  group('PlatformPaths', () {
    test('Windows 应用数据目录与 Runner 版本信息一致', () {
      final paths = PlatformPaths(
        operatingSystem: 'windows',
        environment: const {
          'APPDATA': r'D:\OneDrive 重定向\AppData\Roaming',
          'LOCALAPPDATA': r'D:\OneDrive 重定向\AppData\Local',
          'USERPROFILE': r'D:\用户\阿明',
          'TEMP': r'D:\临时',
        },
        windowsKnownFolder: (name) => switch (name) {
          'Desktop' => r'D:\OneDrive 重定向\桌面',
          'My Video' => r'D:\OneDrive 重定向\视频',
          _ => null,
        },
        windowsStorageValue: (_) => null,
      );

      expect(
        paths.applicationSupport,
        r'D:\OneDrive 重定向\AppData\Roaming\com.jichuang\ishkafel',
      );
      expect(
        paths.dataDir,
        r'D:\OneDrive 重定向\AppData\Roaming\com.jichuang\ishkafel\ishkafel_data',
      );
      expect(
        paths.localApplicationData,
        r'D:\OneDrive 重定向\AppData\Local\com.jichuang\ishkafel',
      );
      expect(paths.userHome, r'D:\用户\阿明');
      expect(paths.videosDirectory, r'D:\OneDrive 重定向\视频');
      expect(paths.desktopDirectory, r'D:\OneDrive 重定向\桌面');
      expect(paths.temporaryDirectory, r'D:\临时');
    });

    test('Windows Known Folder 的环境变量会展开，查不到时才回退用户目录', () {
      final paths = PlatformPaths(
        operatingSystem: 'windows',
        environment: const {
          'APPDATA': r'C:\Users\Mayn\AppData\Roaming',
          'LOCALAPPDATA': r'C:\Users\Mayn\AppData\Local',
          'USERPROFILE': r'C:\Users\Mayn',
          'TEMP': r'C:\Users\Mayn\AppData\Local\Temp',
          'OneDrive': r'D:\云盘',
        },
        windowsKnownFolder: (name) => switch (name) {
          'Desktop' => r'%OneDrive%\桌面',
          _ => null,
        },
        windowsStorageValue: (_) => null,
      );

      expect(paths.desktopDirectory, r'D:\云盘\桌面');
      expect(paths.videosDirectory, r'C:\Users\Mayn\Videos');
      expect(
        paths.isTemporaryPath(r'C:\Users\Mayn\AppData\Local\Temp\ishkafel\out'),
        isTrue,
      );
      expect(
        paths.isTemporaryPath(r'c:\users\mayn\appdata\local\TEMP'),
        isTrue,
        reason: 'Windows 路径比较必须忽略大小写',
      );
      expect(paths.isTemporaryPath(r'D:\OneDrive\视频\成片'), isFalse);
    });

    test('Windows 默认导出位置优先用环境变量，其次用注册表', () {
      final fromRegistry = PlatformPaths(
        operatingSystem: 'windows',
        environment: const {
          'APPDATA': r'C:\Users\Mayn\AppData\Roaming',
          'USERPROFILE': r'C:\Users\Mayn',
        },
        windowsKnownFolder: (_) => null,
        windowsStorageValue: (name) => name == 'ExportRoot'
            ? r'D:\Ishkafel\Media\Exports'
            : null,
      );
      final fromEnvironment = PlatformPaths(
        operatingSystem: 'windows',
        environment: const {
          'APPDATA': r'C:\Users\Mayn\AppData\Roaming',
          'USERPROFILE': r'C:\Users\Mayn',
          'ISHKAFEL_EXPORT_DIR': r'E:\Automation Exports',
        },
        windowsKnownFolder: (_) => null,
        windowsStorageValue: (_) => r'D:\ignored',
      );

      expect(fromRegistry.exportDirectory, r'D:\Ishkafel\Media\Exports');
      expect(fromEnvironment.exportDirectory, r'E:\Automation Exports');
    });

    test('未配置默认导出位置时仍使用影片目录下的 ishkafel', () {
      final paths = PlatformPaths(
        operatingSystem: 'windows',
        environment: const {
          'APPDATA': r'C:\Users\Mayn\AppData\Roaming',
          'USERPROFILE': r'C:\Users\Mayn',
        },
        windowsKnownFolder: (name) =>
            name == 'My Video' ? r'D:\我的视频' : null,
        windowsStorageValue: (_) => null,
      );

      expect(paths.exportDirectory, r'D:\我的视频\ishkafel');
    });

    test('macOS 保持现有 bundle id 目录', () {
      final paths = PlatformPaths(
        operatingSystem: 'macos',
        environment: const {'HOME': '/Users/阿明'},
      );

      expect(
        paths.applicationSupport,
        '/Users/阿明/Library/Application Support/com.jichuang.ishkafel',
      );
      expect(
        paths.dataDir,
        '/Users/阿明/Library/Application Support/com.jichuang.ishkafel/ishkafel_data',
      );
      expect(paths.userHome, '/Users/阿明');
      expect(paths.videosDirectory, '/Users/阿明/Movies');
      expect(paths.desktopDirectory, '/Users/阿明/Desktop');
      expect(paths.temporaryDirectory, '/tmp');
      expect(paths.isTemporaryPath('/private/tmp/a'), isTrue);
      expect(paths.isTemporaryPath('/Users/阿明/Movies'), isFalse);
    });

    test('必要的系统根目录缺失时明确失败', () {
      final paths = PlatformPaths(
        operatingSystem: 'windows',
        environment: const {},
        windowsKnownFolder: (_) => null,
        windowsStorageValue: (_) => null,
      );
      expect(() => paths.applicationSupport, throwsStateError);
    });
  });
}
