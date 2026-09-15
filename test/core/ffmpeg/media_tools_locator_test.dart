import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ffmpeg/media_tools_locator.dart';

void main() {
  group('MediaToolsLocator.resolve', () {
    test('命中 Homebrew 目录（/opt/homebrew/bin）时返回绝对路径', () {
      final locator = MediaToolsLocator(
        operatingSystem: 'macos',
        probe: (path) => path == '/opt/homebrew/bin/ffmpeg',
        lookupOnPath: (_) => fail('候选目录已命中，不应再查 PATH'),
      );
      expect(locator.resolve('ffmpeg'), '/opt/homebrew/bin/ffmpeg');
    });

    test('Homebrew 目录缺失时回落 /usr/local/bin', () {
      final locator = MediaToolsLocator(
        operatingSystem: 'macos',
        probe: (path) => path == '/usr/local/bin/ffprobe',
        lookupOnPath: (_) => fail('候选目录已命中，不应再查 PATH'),
      );
      expect(locator.resolve('ffprobe'), '/usr/local/bin/ffprobe');
    });

    test('候选目录都没有时用 PATH 查找结果', () {
      final locator = MediaToolsLocator(
        operatingSystem: 'macos',
        probe: (_) => false,
        lookupOnPath: (name) => '/somewhere/custom/$name',
      );
      expect(locator.resolve('ffmpeg'), '/somewhere/custom/ffmpeg');
    });

    test('Windows 候选目录补 .exe 且使用反斜杠', () {
      final locator = MediaToolsLocator(
        operatingSystem: 'windows',
        searchDirs: const [r'C:\Program Files\Ishkafel\tools'],
        probe: (path) => path == r'C:\Program Files\Ishkafel\tools\ffmpeg.exe',
        lookupOnPath: (_) => fail('内置工具已命中，不应再查 PATH'),
      );

      expect(
        locator.resolve('ffmpeg'),
        r'C:\Program Files\Ishkafel\tools\ffmpeg.exe',
      );
    });

    test('候选目录与 PATH 都找不到时返回 null（不抛异常）', () {
      final locator = MediaToolsLocator(
        operatingSystem: 'macos',
        probe: (_) => false,
        lookupOnPath: (_) => null,
      );
      expect(locator.resolve('ffmpeg'), isNull);
    });

    test('解析结果缓存：命中与未命中都只探测一次', () {
      var probeCalls = 0;
      var lookupCalls = 0;
      final hit = MediaToolsLocator(
        operatingSystem: 'macos',
        probe: (path) {
          probeCalls++;
          return path == '/opt/homebrew/bin/ffmpeg';
        },
        lookupOnPath: (_) => null,
      );
      hit.resolve('ffmpeg');
      hit.resolve('ffmpeg');
      expect(probeCalls, 1, reason: '命中结果应被缓存');

      final miss = MediaToolsLocator(
        operatingSystem: 'macos',
        probe: (_) => false,
        lookupOnPath: (_) {
          lookupCalls++;
          return null;
        },
      );
      miss.resolve('ffmpeg');
      miss.resolve('ffmpeg');
      expect(lookupCalls, 1, reason: '未命中结果同样应被缓存，避免反复探测');
    });

    test('自定义候选目录按给定顺序优先', () {
      final locator = MediaToolsLocator(
        operatingSystem: 'macos',
        searchDirs: const ['/first/bin', '/opt/homebrew/bin'],
        probe: (path) =>
            path.startsWith('/first/bin') ||
            path.startsWith('/opt/homebrew/bin'),
        lookupOnPath: (_) => null,
      );
      expect(locator.resolve('ffmpeg'), '/first/bin/ffmpeg');
    });
  });

  group('MediaToolsStatus', () {
    test('ffmpeg 与 ffprobe 都解析到时 isReady 为 true 且无缺失项', () {
      final locator = MediaToolsLocator(
        operatingSystem: 'macos',
        probe: (path) => path.startsWith('/opt/homebrew/bin/'),
        lookupOnPath: (_) => null,
      );
      final status = locator.preflight();
      expect(status.isReady, isTrue);
      expect(status.missingTools, isEmpty);
      expect(status.ffmpegPath, '/opt/homebrew/bin/ffmpeg');
      expect(status.ffprobePath, '/opt/homebrew/bin/ffprobe');
    });

    test('全部缺失时 isReady 为 false，缺失项包含两个工具名', () {
      final locator = MediaToolsLocator(
        operatingSystem: 'macos',
        probe: (_) => false,
        lookupOnPath: (_) => null,
      );
      final status = locator.preflight();
      expect(status.isReady, isFalse);
      expect(status.missingTools, ['ffmpeg', 'ffprobe']);
    });

    test('只缺 ffprobe 时 isReady 为 false 且只列出 ffprobe', () {
      final locator = MediaToolsLocator(
        operatingSystem: 'macos',
        probe: (path) => path == '/usr/local/bin/ffmpeg',
        lookupOnPath: (_) => null,
      );
      final status = locator.preflight();
      expect(status.isReady, isFalse);
      expect(status.missingTools, ['ffprobe']);
    });
  });

  group('装好之后不必重启 app', () {
    test('forgetMisses 后重新探测，能发现新装好的工具', () {
      var installed = false;
      final locator = MediaToolsLocator(
        operatingSystem: 'macos',
        searchDirs: const ['/opt/homebrew/bin'],
        probe: (path) => installed && path == '/opt/homebrew/bin/ffmpeg',
        lookupOnPath: (_) => null,
      );

      expect(locator.resolve('ffmpeg'), isNull);

      // 用户照着横幅的提示装好了
      installed = true;
      expect(
        locator.resolve('ffmpeg'),
        isNull,
        reason: '前提：未命中结果是被缓存的，否则这条测试没有意义',
      );

      locator.forgetMisses();
      expect(
        locator.resolve('ffmpeg'),
        '/opt/homebrew/bin/ffmpeg',
        reason:
            '不清未命中缓存的话，用户装好后必须重启 app 才能恢复功能，'
            '而横幅上并没有说要重启',
      );
    });

    test('已命中的结果不被清掉（路径不会凭空变化，重探是白花开销）', () {
      var probeCalls = 0;
      final locator = MediaToolsLocator(
        operatingSystem: 'macos',
        searchDirs: const ['/opt/homebrew/bin'],
        probe: (path) {
          probeCalls++;
          return path == '/opt/homebrew/bin/ffmpeg';
        },
        lookupOnPath: (_) => null,
      );

      expect(locator.resolve('ffmpeg'), '/opt/homebrew/bin/ffmpeg');
      final callsAfterFirst = probeCalls;

      locator.forgetMisses();
      expect(locator.resolve('ffmpeg'), '/opt/homebrew/bin/ffmpeg');
      expect(probeCalls, callsAfterFirst);
    });
  });
}
