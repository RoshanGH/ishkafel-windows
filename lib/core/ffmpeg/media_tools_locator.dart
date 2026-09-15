import 'dart:io';

import 'package:path/path.dart' as p;

import '../log/app_log.dart';
import '../platform/platform_shell.dart';

/// 探测某个绝对路径上是否存在可执行文件（注入点，便于单测零真实依赖）
typedef ExecutableProbe = bool Function(String absolutePath);

/// 在当前 PATH 中查找可执行文件，返回绝对路径；找不到返回 null
typedef PathLookup = String? Function(String executableName);

/// ffmpeg/ffprobe 环境探测结果（不可变）
class MediaToolsStatus {
  final String? ffmpegPath;
  final String? ffprobePath;

  const MediaToolsStatus({this.ffmpegPath, this.ffprobePath});

  bool get isReady => ffmpegPath != null && ffprobePath != null;

  /// 缺失的工具名，顺序固定为 ffmpeg、ffprobe，便于稳定展示
  List<String> get missingTools => List.unmodifiable([
    if (ffmpegPath == null) MediaToolsLocator.ffmpeg,
    if (ffprobePath == null) MediaToolsLocator.ffprobe,
  ]);
}

/// 交给**子进程**用的 PATH。
///
/// 本 app 自己调 ffmpeg 用的是绝对路径（见下面的 [MediaToolsLocator]），
/// 已经绕开了「GUI 进程 PATH 里没有 Homebrew」这个坑。但我们还会拉起
/// **第三方程序**——`audio-separator` 就是一个，它自己要去 PATH 上找 ffmpeg
/// 来解码，绕不开。
///
/// 真机事故（2026-09-04）：点「重新分离」报「未检测到人声分离工具，请先安装
/// 后重试」，可工具装得好好的，终端里手跑 11 秒就分完了。真正缺的是它要用的
/// ffmpeg——子进程抛 `FileNotFoundError: 'ffmpeg'`，被翻译成了「工具没装」，
/// 于是用户照着提示反复装、反复重试，永远好不了。
///
/// 所以起子进程时把这些目录交到它手上。**继承来的 PATH 一个都不丢**：
/// 丢了会连累它要用的别的工具。
String childProcessPath({
  String? currentPath,
  List<String> extraDirs = const [],
  String? home,
  String? operatingSystem,
  List<String>? defaultDirs,
}) {
  final os = operatingSystem ?? Platform.operatingSystem;
  final shell = PlatformShell(operatingSystem: os);
  final resolvedHome = home ?? Platform.environment['HOME'];
  final dirs = <String>[
    ...(defaultDirs ?? MediaToolsLocator.defaultSearchDirsFor(os)),
    // uv tool install / pipx 都装在这儿（audio-separator 本身就在这里）
    if (os != 'windows' && resolvedHome != null && resolvedHome.isNotEmpty)
      '$resolvedHome/.local/bin',
    ...extraDirs,
    ...(currentPath ?? Platform.environment['PATH'] ?? '').split(
      shell.pathSeparator,
    ),
  ];
  // 去重并丢掉空段：PATH 里出现空段等于把当前目录也算进去，是个安全问题
  final seen = <String>{};
  return [
    for (final d in dirs)
      if (d.isNotEmpty && seen.add(d)) d,
  ].join(shell.pathSeparator);
}

/// ffmpeg/ffprobe 可执行文件定位。
///
/// 为什么需要：macOS 上由 Finder / `open` 启动的 GUI 进程继承的是 launchd 的
/// 环境，本机实测 `launchctl getenv PATH` 为空，于是进程只拿到系统默认
/// `/usr/bin:/bin:/usr/sbin:/sbin`——不含 Homebrew 的 `/opt/homebrew/bin`
/// 与 `/usr/local/bin`。裸名调用 `Process.start('ffmpeg', ...)` 必然
/// ENOENT，而终端里 `flutter run` 因为继承了 shell 的完整 PATH 所以从未暴露。
///
/// 解析顺序：常见安装目录（Apple Silicon Homebrew → Intel Homebrew）→ 当前
/// PATH（`which`）。结果（含未命中）一次性缓存，避免每次起子进程都做磁盘探测。
class MediaToolsLocator {
  static const String ffmpeg = 'ffmpeg';
  static const String ffprobe = 'ffprobe';

  /// Homebrew 在 Apple Silicon / Intel 上的默认安装目录
  static const List<String> defaultSearchDirs = [
    '/opt/homebrew/bin',
    '/usr/local/bin',
  ];

  final List<String> searchDirs;
  final ExecutableProbe probe;
  final PathLookup lookupOnPath;
  final String operatingSystem;
  final PlatformShell _shell;

  /// 解析缓存：值为 null 表示「已探测过且没找到」，同样不再重复探测
  final Map<String, String?> _cache = {};

  MediaToolsLocator({
    List<String>? searchDirs,
    ExecutableProbe? probe,
    PathLookup? lookupOnPath,
    String? operatingSystem,
    String? executableDirectory,
  }) : operatingSystem = operatingSystem ?? Platform.operatingSystem,
       searchDirs = List.unmodifiable(
         searchDirs ??
             defaultSearchDirsFor(
               operatingSystem ?? Platform.operatingSystem,
               executableDirectory: executableDirectory,
             ),
       ),
       probe = probe ?? _fileExists,
       _shell = PlatformShell(
         operatingSystem: operatingSystem ?? Platform.operatingSystem,
       ),
       lookupOnPath =
           lookupOnPath ??
           PlatformShell(
             operatingSystem: operatingSystem ?? Platform.operatingSystem,
           ).lookupOnPath;

  /// 解析可执行文件的绝对路径；找不到返回 null（由调用方决定如何提示用户）
  String? resolve(String executableName) => _cache.putIfAbsent(
    executableName,
    () => _resolveUncached(executableName),
  );

  /// 清掉「没找到」的缓存，让下一次解析重新探测。
  ///
  /// 缓存本身是必要的（否则每起一次子进程都做磁盘探测），但**未命中**的结果
  /// 不能永久缓存：用户按横幅提示装好 ffmpeg 后，不清缓存就必须重启 app 才能
  /// 恢复功能。已命中的结果保留——路径不会凭空变化，重探是白花开销。
  void forgetMisses() => _cache.removeWhere((_, path) => path == null);

  String? _resolveUncached(String executableName) {
    for (final dir in searchDirs) {
      final context = p.Context(
        style: operatingSystem == 'windows' ? p.Style.windows : p.Style.posix,
      );
      for (final name in _shell.executableNames(executableName)) {
        final candidate = context.join(dir, name);
        if (probe(candidate)) return candidate;
      }
    }
    return lookupOnPath(executableName);
  }

  /// 启动期预检：一次性解析 ffmpeg 与 ffprobe，供 UI 常驻展示环境状态
  MediaToolsStatus preflight() {
    final status = MediaToolsStatus(
      ffmpegPath: resolve(ffmpeg),
      ffprobePath: resolve(ffprobe),
    );
    if (!status.isReady) {
      AppLog.warn('未检测到 ${status.missingTools.join('、')}，视频处理功能不可用');
    }
    return status;
  }

  static bool _fileExists(String absolutePath) =>
      File(absolutePath).existsSync();

  /// 用绝对路径调用 `/usr/bin/which`（该目录在任何启动方式下都在 PATH 中）；
  /// which 自身异常（如系统裁剪）一律视为未找到，不向上抛。
  static List<String> defaultSearchDirsFor(
    String operatingSystem, {
    String? executableDirectory,
  }) {
    if (operatingSystem == 'windows') {
      final base =
          executableDirectory ?? p.dirname(Platform.resolvedExecutable);
      return [p.Context(style: p.Style.windows).join(base, 'tools')];
    }
    if (operatingSystem == 'macos') return defaultSearchDirs;
    return const ['/usr/local/bin', '/usr/bin'];
  }
}
