import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ffmpeg/process_runner.dart';

void main() {
  group('工具缺失提示要给出**这个工具**的安装办法', () {
    test('ffmpeg / ffprobe 指向 brew install ffmpeg', () {
      for (final tool in ['ffmpeg', 'ffprobe']) {
        final message = missingToolMessage(tool, operatingSystem: 'macos');
        expect(message, contains(tool));
        expect(message, contains('brew install ffmpeg'));
      }
    });

    test('Windows 内置 ffmpeg 缺失时提示重装而不是要求安装 Homebrew', () {
      for (final tool in ['ffmpeg', 'ffprobe']) {
        final message = missingToolMessage(tool, operatingSystem: 'windows');
        expect(message, contains(tool));
        expect(message, contains('重新安装 Ishkafel'));
        expect(message, isNot(contains('brew')));
      }
    });

    test('miaoa 不能也让人去装 ffmpeg', () {
      final message = missingToolMessage('miaoa');

      expect(
        message,
        isNot(contains('brew install ffmpeg')),
        reason:
            '照着「请执行 brew install ffmpeg」去做，miaoa 还是不存在——'
            '用户会以为软件坏了。CLI 缺失时提示必须指向 miaoa 自己的安装方式',
      );
      expect(message, contains('miaoa'));
    });

    test('Windows 人声分离工具提示使用 PowerShell', () {
      final message = missingToolMessage(
        'audio-separator',
        operatingSystem: 'windows',
      );

      expect(message, contains('PowerShell'));
      expect(message, isNot(contains('brew')));
    });

    test('未知工具名给通用措辞，不冒充具体安装命令', () {
      final message = missingToolMessage('some-tool');
      expect(message, contains('some-tool'));
      expect(message, isNot(contains('brew install ffmpeg')));
    });

    test('异常的 message 就是可直接展示的文案，不带类名前缀', () {
      const e = MediaToolMissingException('ffmpeg');
      expect(e.message, isNot(contains('Exception')));
      expect(e.message, contains('ffmpeg'));
    });
  });
}
