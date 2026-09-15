import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ffmpeg/media_tools_locator.dart';
import 'package:ishkafel/core/miaoa/miaoa_locator.dart';

void main() {
  test('搜索目录包含用户级 ~/.local/bin（miaoa 的默认安装位置）', () {
    final dirs = miaoaSearchDirsFor('macos', const {'HOME': '/Users/u'});
    expect(
      dirs.any((d) => d.endsWith('/.local/bin')),
      isTrue,
      reason: 'GUI 进程的 PATH 不含 ~/.local/bin，只靠 which 会误报「未安装」',
    );
  });

  test('Windows 同时搜索用户 .local 和 LocalAppData 安装目录', () {
    final dirs = miaoaSearchDirsFor('windows', const {
      'USERPROFILE': r'C:\Users\u',
      'LOCALAPPDATA': r'C:\Users\u\AppData\Local',
    });
    expect(dirs, contains(r'C:\Users\u\.local\bin'));
    expect(dirs, contains(r'C:\Users\u\AppData\Local\Programs\miaoa\bin'));
  });

  test('命中安装目录时返回绝对路径，而不是裸名', () {
    final locator = MediaToolsLocator(
      searchDirs: const ['/home/u/.local/bin', '/opt/homebrew/bin'],
      probe: (path) => path == '/home/u/.local/bin/miaoa',
      lookupOnPath: (_) => null,
      operatingSystem: 'linux',
    );

    expect(resolveMiaoaBinary(locator: locator), '/home/u/.local/bin/miaoa');
  });

  test('安装目录没有时退回 PATH 查找', () {
    final locator = MediaToolsLocator(
      searchDirs: const ['/opt/homebrew/bin'],
      probe: (_) => false,
      lookupOnPath: (name) => '/usr/bin/$name',
      operatingSystem: 'linux',
    );

    expect(resolveMiaoaBinary(locator: locator), '/usr/bin/miaoa');
  });

  test('哪儿都找不到时回退裸名，让子进程失败走「未安装」引导', () {
    final locator = MediaToolsLocator(
      searchDirs: const ['/opt/homebrew/bin'],
      probe: (_) => false,
      lookupOnPath: (_) => null,
      operatingSystem: 'linux',
    );

    expect(resolveMiaoaBinary(locator: locator), 'miaoa');
  });
}
