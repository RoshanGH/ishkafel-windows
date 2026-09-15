import 'dart:io';

import 'package:path/path.dart' as p;

import '../ffmpeg/media_tools_locator.dart';

/// miaoa 可执行文件的常见安装目录。
///
/// 与 ffmpeg 同一个坑（见 [MediaToolsLocator] 的说明）：macOS 上由 Finder /
/// `open` 启动的 GUI 进程继承 launchd 的空 PATH，只剩系统默认目录。miaoa 的
/// 默认安装位置是用户级的 `~/.local/bin`，它既不在系统默认 PATH 里、`which`
/// 也查不到——不显式搜索的话，装好的 CLI 会被误报成「未安装」。
final List<String> miaoaSearchDirs = miaoaSearchDirsFor(
  Platform.operatingSystem,
  Platform.environment,
);

List<String> miaoaSearchDirsFor(
  String operatingSystem,
  Map<String, String> environment,
) {
  final windows = operatingSystem == 'windows';
  final context = p.Context(style: windows ? p.Style.windows : p.Style.posix);
  final home = windows ? environment['USERPROFILE'] : environment['HOME'];
  final localAppData = environment['LOCALAPPDATA'];
  return List.unmodifiable([
    if (home != null && home.isNotEmpty) context.join(home, '.local', 'bin'),
    if (windows && localAppData != null && localAppData.isNotEmpty)
      context.join(localAppData, 'Programs', 'miaoa', 'bin'),
    ...MediaToolsLocator.defaultSearchDirsFor(operatingSystem),
  ]);
}

/// [MediaToolsLocator] 本身是通用的可执行文件定位器（缓存 + 目录探测 +
/// which 回退），这里换一组搜索目录复用它，不另造一套
final _miaoaLocator = MediaToolsLocator(searchDirs: miaoaSearchDirs);

/// 解析 miaoa 可执行文件路径。
///
/// 找不到时回退裸名 `miaoa`：让子进程照常启动并抛 ProcessException，从而走
/// 统一的「未安装」中文引导（见 miaoa_failure.dart），而不是在这里另立一套
/// 判空分支。
String resolveMiaoaBinary({MediaToolsLocator? locator}) =>
    (locator ?? _miaoaLocator).resolve('miaoa') ?? 'miaoa';

/// 忘掉「没找到 miaoa」这个结论，让下一次解析重新看一眼磁盘。
///
/// 见 [MediaToolsLocator.forgetMisses]：用户是在 app 开着的时候装工具的，
/// 不清掉未命中缓存，装完就得重启 app 才认——而界面上并没有说要重启。
void forgetMiaoaProbeMisses() => _miaoaLocator.forgetMisses();
