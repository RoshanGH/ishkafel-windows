import 'dart:io';

import 'package:path/path.dart' as p;

/// 把素材落到草稿目录里。
///
/// **为什么必须落地**：剪映是沙盒 app（`com.lemon.lvpro`），读不到
/// `~/Library/Application Support/com.jichuang.ishkafel/`。直接把缓存路径
/// 写进草稿，剪映里每一段都是「暂无访问权限」、预览一片「媒体格式不支持」
/// （真机实测）。素材必须放进它够得着的地方——它自己的草稿目录。
///
/// **为什么用硬链接而不是复制**：同一份数据两个路径，420MB 的素材零额外
/// 占盘，而两边**完全独立**：
///
/// - 用户在 ishkafel 里清缓存 → 草稿那份还在，剪映照常打开
/// - 用户在剪映里删草稿 → 我们的缓存还在，任务照常
/// - 两个都删了，空间才真正释放
///
/// 跨盘不能硬链接（草稿目录被搬到外置盘时），那时退回真复制。
class MaterialStager {
  MaterialStager(this.destDir);

  /// 草稿里的素材目录（`<草稿>/materials`）
  final String destDir;

  final Map<String, String> _staged = {};

  /// 已落地的素材数
  int get count => _staged.length;

  /// 落地一份，返回它在草稿里的绝对路径。同一个源只落一次。
  String stage(String source) {
    final hit = _staged[source];
    if (hit != null) return hit;
    final src = File(source);
    if (!src.existsSync()) {
      throw FileSystemException('素材文件不存在', source);
    }
    Directory(destDir).createSync(recursive: true);
    final dest = _freeNameFor(source);
    // 只能硬链接或真复制。**符号链接不行**：沙盒按最终目标路径判权限，
    // 剪映顺着链接读到我们的缓存目录，照样是「暂无访问权限」
    _hardLinkOrCopy(source, dest);
    _staged[source] = dest;
    return dest;
  }

  /// 同名不同源时让路（不同任务里可能有同名的 clip.mp4）
  String _freeNameFor(String source) {
    final base = p.basename(source);
    var dest = p.join(destDir, base);
    var n = 1;
    while (File(dest).existsSync() && !_sameFile(dest, source)) {
      final stem = p.basenameWithoutExtension(base);
      final ext = p.extension(base);
      dest = p.join(destDir, '$stem-$n$ext');
      n++;
    }
    return dest;
  }

  bool _sameFile(String a, String b) {
    try {
      return File(a).statSync().size == File(b).statSync().size &&
          File(a).resolveSymbolicLinksSync() ==
              File(b).resolveSymbolicLinksSync();
    } on FileSystemException {
      return false;
    }
  }

  void _hardLinkOrCopy(String source, String dest) {
    if (File(dest).existsSync()) return;
    // Dart 没有硬链接绑定：Windows 用 mklink /H，macOS/Linux 用 ln；
    // 失败（跨盘 EXDEV、权限策略等）就老实复制。
    final r = Platform.isWindows
        ? Process.runSync('cmd.exe', ['/d', '/c', 'mklink', '/H', dest, source])
        : Process.runSync('/bin/ln', [source, dest]);
    if (r.exitCode == 0 && File(dest).existsSync()) return;
    File(source).copySync(dest);
  }
}
