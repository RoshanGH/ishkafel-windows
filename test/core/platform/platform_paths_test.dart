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
      );

      expect(paths.applicationSupport,
          r'D:\OneDrive 重定向\AppData\Roaming\com.jichuang\ishkafel');
      expect(paths.dataDir,
          r'D:\OneDrive 重定向\AppData\Roaming\com.jichuang\ishkafel\ishkafel_data');
      expect(paths.localApplicationData,
          r'D:\OneDrive 重定向\AppData\Local\com.jichuang\ishkafel');
      expect(paths.userHome, r'D:\用户\阿明');
      expect(paths.videosDirectory, r'D:\用户\阿明\Videos');
      expect(paths.desktopDirectory, r'D:\用户\阿明\Desktop');
    });

    test('macOS 保持现有 bundle id 目录', () {
      final paths = PlatformPaths(
        operatingSystem: 'macos',
        environment: const {'HOME': '/Users/阿明'},
      );

      expect(paths.applicationSupport,
          '/Users/阿明/Library/Application Support/com.jichuang.ishkafel');
      expect(paths.dataDir,
          '/Users/阿明/Library/Application Support/com.jichuang.ishkafel/ishkafel_data');
      expect(paths.userHome, '/Users/阿明');
      expect(paths.videosDirectory, '/Users/阿明/Movies');
      expect(paths.desktopDirectory, '/Users/阿明/Desktop');
    });

    test('必要的系统根目录缺失时明确失败', () {
      final paths = PlatformPaths(
        operatingSystem: 'windows',
        environment: const {},
      );
      expect(() => paths.applicationSupport, throwsStateError);
    });
  });
}
