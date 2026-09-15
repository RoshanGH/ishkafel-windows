import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ffmpeg/media_tools_locator.dart';

/// 真机事故（2026-09-04）：工作台点「重新分离」，界面报「未检测到人声分离工具，
/// 请先安装后重试」。可工具装得好好的，终端里手跑 11 秒就分完了。
///
/// 真正缺的是 **ffmpeg**——`audio-separator` 是个第三方 Python 程序，它自己要去
/// PATH 上找 ffmpeg 来解码。GUI 进程继承的是 launchd 的 PATH（只有
/// `/usr/bin:/bin:/usr/sbin:/sbin`），Homebrew 不在里面，于是它抛
/// `FileNotFoundError: 'ffmpeg'`，而 app 又把这句翻译成了「工具没装」。
///
/// 本 app 自己调 ffmpeg 早就用绝对路径绕开了这个坑（见 [MediaToolsLocator]），
/// 但**替我们起的第三方进程**绕不开——得把这些目录交到它手上。
void main() {
  test('装 ffmpeg 的目录要排在前面，子进程才找得到', () {
    final path = childProcessPath(
      currentPath: '/usr/bin:/bin',
      home: '/Users/someone',
      operatingSystem: 'macos',
    );

    expect(
      path.split(':').first,
      '/opt/homebrew/bin',
      reason: 'Homebrew 优先——真机上 ffmpeg 就装在这儿',
    );
    expect(path, contains('/usr/local/bin'), reason: 'Intel 机器上的 Homebrew');
    expect(
      path,
      contains('/Users/someone/.local/bin'),
      reason: 'uv tool install / pipx 装的东西在这儿',
    );
  });

  test('继承来的 PATH 一个都不能丢——丢了会连累别的工具', () {
    final path = childProcessPath(
      currentPath: '/usr/bin:/bin:/opt/custom',
      home: '/Users/someone',
      operatingSystem: 'macos',
    );

    for (final dir in ['/usr/bin', '/bin', '/opt/custom']) {
      expect(path.split(':'), contains(dir));
    }
  });

  test('重复的目录只留一份，不把 PATH 撑成一串复读', () {
    final path = childProcessPath(
      currentPath: '/opt/homebrew/bin:/usr/bin',
      home: '/Users/someone',
      operatingSystem: 'macos',
    );

    expect(
      path.split(':').where((d) => d == '/opt/homebrew/bin'),
      hasLength(1),
    );
  });

  test('拿不到 HOME 也不能拼出 `null/.local/bin` 这种垃圾路径', () {
    final path = childProcessPath(
      currentPath: '/usr/bin',
      home: null,
      operatingSystem: 'macos',
    );

    expect(path, isNot(contains('null')));
    expect(path.split(':'), everyElement(startsWith('/')));
  });

  test('PATH 为空时也要给出可用的目录，而不是空字符串', () {
    final path = childProcessPath(
      currentPath: '',
      home: '/Users/someone',
      operatingSystem: 'macos',
    );

    expect(path.split(':'), contains('/opt/homebrew/bin'));
    expect(path.split(':'), isNot(contains('')));
  });

  test('Windows PATH 按分号拆分且不能拆坏盘符', () {
    final path = childProcessPath(
      currentPath: r'C:\Windows\System32;D:\媒体工具\bin',
      home: r'C:\Users\someone',
      operatingSystem: 'windows',
      defaultDirs: const [r'C:\Program Files\Ishkafel\tools'],
    );

    expect(path.split(';'), [
      r'C:\Program Files\Ishkafel\tools',
      r'C:\Windows\System32',
      r'D:\媒体工具\bin',
    ]);
  });
}
