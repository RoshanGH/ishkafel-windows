import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'media_tools_locator.dart';

/// 子进程执行抽象（生产用 [systemProcessRunner]，测试注入假实现）
typedef ProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> args);

/// 真正拉起子进程的底层动作（注入点：测试可替换，无需真实二进制）
typedef ProcessInvoker =
    Future<ProcessResult> Function(String executable, List<String> args);

/// 子进程启动器（注入点：测试用假 Process，无需真实二进制）。
///
/// 带上 [environment] 是因为我们拉起的**第三方程序**（audio-separator）
/// 自己还要去 PATH 上找 ffmpeg，见 [childProcessPath]
typedef ProcessStarter =
    Future<Process> Function(
      String executable,
      List<String> args, {
      Map<String, String>? environment,
    });

/// 全局共享的工具定位器：解析结果缓存在实例上，各服务复用同一份避免重复探测
final MediaToolsLocator sharedMediaToolsLocator = MediaToolsLocator();

/// ffmpeg/ffprobe 子进程默认超时。
///
/// 取值依据：耗时最长的一步是整片场景检测（ffmpeg 需要全片解码），本机
/// 一条 5 分钟竖屏素材约数十秒；抽帧与 ffprobe 探测只需几秒。按最慢一步
/// 留一个数量级的余量取 10 分钟——既能容忍长素材与慢机器，又保证真正卡死
/// 的进程不会把任务永久钉在「分析中」。需要更严的可用
/// [timeoutProcessRunner] 单独配置。
const Duration defaultProcessTimeout = Duration(minutes: 10);

/// 默认实现：解析绝对路径 + 带超时执行
Future<ProcessResult> systemProcessRunner(
  String executable,
  List<String> args,
) => const ResolvingProcessRunner()(executable, args);

/// 按需定制超时的执行器工厂（仍是 [ProcessRunner]，可直接注入各服务）
ProcessRunner timeoutProcessRunner({
  Duration timeout = defaultProcessTimeout,
  MediaToolsLocator? locator,
}) => ResolvingProcessRunner(
  locator: locator,
  invoke: TimeoutProcessInvoker(timeout: timeout).call,
).call;

/// 带超时的子进程执行：Process.run 没有超时，ffmpeg 一旦卡住就永久挂起，
/// 任务随之永远停在「分析中」。这里改用 Process.start + exitCode.timeout，
/// 超时即 SIGKILL 子进程并抛出带中文说明的异常。
class TimeoutProcessInvoker {
  final Duration timeout;
  final ProcessStarter starter;

  const TimeoutProcessInvoker({
    this.timeout = defaultProcessTimeout,
    this.starter = Process.start,
  });

  Future<ProcessResult> call(String executable, List<String> args) async {
    // 把装着工具的目录交到子进程手上。本 app 自己调 ffmpeg 早就用绝对路径
    // 绕开了这个坑，但第三方程序绕不开——它自己要去 PATH 上找（见
    // [childProcessPath] 里记的那次真机事故）
    final process = await starter(
      executable,
      args,
      environment: {'PATH': childProcessPath()},
    );
    final stdoutFuture = _collect(process.stdout);
    final stderrFuture = _collect(process.stderr);
    try {
      final exitCode = await process.exitCode.timeout(timeout);
      return ProcessResult(
        process.pid,
        exitCode,
        await stdoutFuture,
        await stderrFuture,
      );
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      // 已挂起的输出收集不再有人接收，显式忽略避免未处理异常
      stdoutFuture.ignore();
      stderrFuture.ignore();
      throw FfmpegException(timeoutMessage(executable, timeout));
    }
  }

  /// 允许非法字节：ffmpeg 的日志可能夹带非 UTF-8 内容，解码不应反过来炸掉调用
  static Future<String> _collect(Stream<List<int>> stream) =>
      stream.transform(const Utf8Decoder(allowMalformed: true)).join();
}

/// 超时提示（面向用户，同时带上工具名便于日志定位）
String timeoutMessage(String executable, Duration timeout) =>
    '$executable 执行超时（等待超过 ${_formatDuration(timeout)}），已终止该进程。'
    '请确认素材文件可正常播放，或改用更短的素材重试。';

String _formatDuration(Duration d) {
  if (d.inMinutes >= 1) return '${d.inMinutes} 分钟';
  if (d.inSeconds >= 1) return '${d.inSeconds} 秒';
  return '${d.inMilliseconds} 毫秒';
}

/// 解析型执行器：把 `ffmpeg`/`ffprobe` 这类裸名解析为绝对路径后再执行。
///
/// GUI（Finder/`open`）启动的进程 PATH 不含 Homebrew 目录，裸名调用必然
/// ENOENT，因此统一在这一层收口；解析不到时抛出带中文引导的
/// [FfmpegException]，而不是把 `ProcessException` 原文摊给用户。
class ResolvingProcessRunner {
  /// null 表示使用全局共享定位器（保持 const 构造，默认值不能是非常量实例）
  final MediaToolsLocator? locator;

  /// null 表示使用默认的带超时执行器
  final ProcessInvoker? invoke;

  const ResolvingProcessRunner({this.locator, this.invoke});

  MediaToolsLocator get _locator => locator ?? sharedMediaToolsLocator;

  ProcessInvoker get _invoke => invoke ?? const TimeoutProcessInvoker().call;

  /// 声明为 async：解析失败的异常要落到返回的 Future 上，
  /// 而不是在调用瞬间同步抛出（同步抛出会绕过调用方的 await 错误处理）
  Future<ProcessResult> call(String executable, List<String> args) async {
    final resolved = _resolve(executable);
    return _invoke(resolved, args);
  }

  /// 已经是绝对路径时直接透传，不做解析
  String _resolve(String executable) {
    if (executable.startsWith('/') ||
        executable.startsWith(r'\\') ||
        RegExp(r'^[A-Za-z]:[\\/]').hasMatch(executable)) {
      return executable;
    }
    final resolved = _locator.resolve(executable);
    if (resolved == null) throw MediaToolMissingException(executable);
    return resolved;
  }
}

/// 视频处理组件缺失：与其他 ffmpeg 失败区分开，因为它的 [message] 已经是
/// 可直接展示给用户的安装引导，上层无需再翻译。
class MediaToolMissingException implements FfmpegException {
  final String executable;
  final String? operatingSystem;

  const MediaToolMissingException(this.executable, {this.operatingSystem});

  @override
  String get message =>
      missingToolMessage(executable, operatingSystem: operatingSystem);

  @override
  String toString() => 'MediaToolMissingException: $message';
}

/// 工具缺失时给用户的中文引导（面向用户，不含技术堆栈）。
///
/// 必须按工具给出**这个工具自己**的安装办法：这套子进程封装同时被 ffmpeg/
/// ffprobe 与 miaoa CLI 复用，一律写「请执行 brew install ffmpeg」的话，
/// miaoa 缺失时用户照做也解决不了，只会以为软件坏了。
String missingToolMessage(String executable, {String? operatingSystem}) {
  final os = operatingSystem ?? Platform.operatingSystem;
  switch (executable) {
    case 'ffmpeg':
    case 'ffprobe':
      if (os == 'windows') {
        return '安装包内置的视频处理组件 $executable 缺失或损坏。'
            '请重新安装 Ishkafel；不要另外修改 PATH。';
      }
      return '未找到视频处理组件 $executable。请先在终端执行 brew install ffmpeg '
          '完成安装，然后重新启动本应用。';
    case 'miaoa':
      return '未找到 miaoa 命令行工具。请先安装并执行 miaoa auth login 登录，'
          '然后重新启动本应用。';
    case 'audio-separator':
      // 这一项是可选的：缺了照样能分析、能替换画面，只是换配乐时新曲子会
      // 与原片自带的背景音叠在一起
      return '未找到人声分离工具（换配乐时需要）。请在终端执行 '
          'uv tool install "audio-separator[cpu]" 完成安装，然后重新启动本应用。';
    default:
      return '未找到所需的命令行工具 $executable。请先完成安装，然后重新启动本应用。';
  }
}

/// ffmpeg/ffprobe 执行失败
class FfmpegException implements Exception {
  final String message;
  const FfmpegException(this.message);
  @override
  String toString() => 'FfmpegException: $message';
}
