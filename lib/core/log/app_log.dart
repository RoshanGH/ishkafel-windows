import 'dart:convert';
import 'dart:io';

/// 轻量日志出口：统一前缀，并在打包 GUI 中持久写入滚动文件。
///
/// 出口用 `stderr` 而不是 `debugPrint`：真机以 `open` 或直接跑
/// `xxx.app/Contents/MacOS/xxx` 启动时，`debugPrint` 的输出**完全不进
/// stdout**——M3 真机验收踩过这个坑，一个「绘制中途抛异常导致整帧后续绘制
/// 全部丢失」的故障在日志里查无痕迹，只能靠逐段插桩重建才定位到。
abstract final class AppLog {
  /// 日志出口，测试可替换以捕获输出
  static void Function(String line) sink = _writeToStderr;

  /// 真出事了：该出的东西没出来、用户拿不到结果。
  /// 和 warn 分开是因为 warn 用得太随意，一屏里全是它，
  /// 「三条成片一条都没导出来」混在中间会被人和脚本一起滑过去
  static void error(String message) => sink('[ishkafel][error] $message');

  static void warn(String message) => sink('[ishkafel][warn] $message');
  static void info(String message) => sink('[ishkafel][info] $message');

  /// 把后续日志同时写入现有可见出口和滚动文件。
  ///
  /// [also] 默认仍写 stderr，CLI 和开发启动时继续能实时看到；Windows 打包
  /// GUI 即使没有可见控制台，也能从应用支持目录的 logs/ishkafel.log 取证。
  static void startFileLogging(
    Directory directory, {
    void Function(String line)? also,
    int maxBytes = 4 * 1024 * 1024,
    int backupCount = 3,
  }) {
    final visible = also ?? _writeToStderr;
    final fileSink = _RotatingFileLogSink(
      File('${directory.path}${Platform.pathSeparator}ishkafel.log'),
      maxBytes: maxBytes,
      backupCount: backupCount,
    );
    sink = (line) {
      visible(line);
      try {
        fileSink.write(line);
      } catch (error) {
        visible('[ishkafel][warn] 文件日志写入失败：$error');
      }
    };
  }

  static void _writeToStderr(String line) => stderr.writeln(line);
}

class _RotatingFileLogSink {
  final File file;
  final int maxBytes;
  final int backupCount;

  const _RotatingFileLogSink(
    this.file, {
    required this.maxBytes,
    required this.backupCount,
  });

  void write(String line) {
    file.parent.createSync(recursive: true);
    final record = '${DateTime.now().toUtc().toIso8601String()} $line\n';
    final bytes = utf8.encode(record).length;
    if (file.existsSync() && file.lengthSync() + bytes > maxBytes) {
      _rotate();
    }
    file.writeAsStringSync(record, mode: FileMode.append, flush: true);
  }

  void _rotate() {
    if (backupCount <= 0) {
      file.writeAsStringSync('');
      return;
    }
    for (var index = backupCount; index >= 1; index--) {
      final destination = File('${file.path}.$index');
      final source = index == 1 ? file : File('${file.path}.${index - 1}');
      if (!source.existsSync()) continue;
      if (destination.existsSync()) destination.deleteSync();
      source.renameSync(destination.path);
    }
  }
}
