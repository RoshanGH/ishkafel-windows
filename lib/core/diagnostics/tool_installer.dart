import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../ffmpeg/media_tools_locator.dart';
import '../ffmpeg/process_runner.dart';
import '../log/app_log.dart';

/// 一个外部工具的安装配方。
///
/// **命令是要摆给用户看的**：这一步会在他的机器上跑一条真实的安装命令，
/// 有的还会从网上取脚本执行。不给看就跑，等于替他做了一个他不知道的决定。
class InstallRecipe {
  /// 装的是哪个可执行文件（与 [MediaToolsLocator] 里的名字一致）
  final String tool;

  /// 这条配方依赖的命令（`brew` / `uv`）。null 表示自包含。
  ///
  /// 前置不在就**不跑**——`brew install` 在没有 brew 的机器上只会吐一句
  /// command not found，用户看了不知道该干嘛
  final String? requires;

  /// 要执行的完整命令。展示给用户的就是这一条，跑的也是这一条
  final List<String> command;

  /// 这一步在干什么、大概要多久（安装动辄几分钟，必须先说）
  final String description;

  /// 前置缺失时该怎么办。**只说怎么装前置，不代装**——
  /// Homebrew / uv 是系统级的东西，替用户装它超出了本应用的职责
  final String prerequisiteHint;

  /// 追加给子进程的环境变量（**国内镜像源**主要靠它，见 [Mirrors]）。
  /// 父进程环境照常继承，这里只是覆盖几个键
  final Map<String, String> environment;

  const InstallRecipe({
    required this.tool,
    required this.command,
    required this.description,
    this.requires,
    this.prerequisiteHint = '',
    this.environment = const {},
  });

  /// 展示给用户看的那一行。**环境变量也要写出来**——用的是哪个镜像源属于
  /// 「这条命令到底会做什么」的一部分，藏起来就不算给看过
  String get displayCommand => [
        for (final e in environment.entries) '${e.key}=${e.value}',
        ...command.map((a) => a.contains(' ') ? '"$a"' : a),
      ].join(' ');
}

/// 国内镜像源。
///
/// 默认源在国内基本装不上：Homebrew 的 bottle 走 GitHub Releases、PyPI 走
/// 境外 CDN，动辄几十 KB/s 或直接超时。而 audio-separator 连着 PyTorch 有
/// 1GB——不换源等于这个按钮点了也白点。
///
/// 选清华 TUNA：老牌、带宽足、两个源都全。换源只改这一处。
abstract final class Mirrors {
  static const _tuna = 'https://mirrors.tuna.tsinghua.edu.cn';

  /// Homebrew：bottle 是预编译包（真正的大头），api 是元数据。
  ///
  /// 另外两个变量与镜像无关但同样要紧：`NO_AUTO_UPDATE` 跳过每次安装前
  /// 那次动辄几分钟的自更新，`NO_INSTALL_CLEANUP` 跳过装完的清理——
  /// 用户等的是 ffmpeg，不是这两件事
  static const brew = {
    'HOMEBREW_API_DOMAIN': '$_tuna/homebrew-bottles/api',
    'HOMEBREW_BOTTLE_DOMAIN': '$_tuna/homebrew-bottles',
    'HOMEBREW_NO_AUTO_UPDATE': '1',
    'HOMEBREW_NO_INSTALL_CLEANUP': '1',
  };

  /// PyPI。uv 认 `UV_DEFAULT_INDEX`（新）与 `UV_INDEX_URL`（旧），
  /// 两个都给，免得因 uv 版本差异悄悄走回默认源
  static const pypi = {
    'UV_DEFAULT_INDEX': '$_tuna/pypi/web/simple',
    'UV_INDEX_URL': '$_tuna/pypi/web/simple',
  };
}

/// 三个外部依赖各自怎么装。
///
/// 为什么值得做进 app：这三样缺一样，对应的功能就是废的，而用户看到的只是
/// 一句「未安装，请在终端执行……」——要他离开这个 app 去敲命令，再回来重启。
/// 到 C 软件不该这样。
abstract final class InstallRecipes {
  /// ffmpeg 与 ffprobe 同一个包，装一次两个都有
  static const ffmpeg = InstallRecipe(
    tool: 'ffmpeg',
    requires: 'brew',
    command: ['brew', 'install', 'ffmpeg'],
    description: '安装视频处理组件（走清华镜像，约 2~5 分钟）',
    environment: Mirrors.brew,
    prerequisiteHint: '需要先装 Homebrew。请在终端执行官网给出的安装命令'
        '（brew.sh），装好后回到这里点「重新检测」；'
            '命令行那头跑 ishkafel doctor 复查。',
  );

  /// miaoa CLI：官方安装脚本，**按平台下对应的二进制**
  static const miaoa = InstallRecipe(
    tool: 'miaoa',
    command: [
      'bash',
      '-c',
      'curl -fsSL https://miaoa.mininglamp.com/api/cli/install.sh '
          '| bash -s -- --host https://miaoa.mininglamp.com',
    ],
    description: '安装 miaoa 命令行工具（约 1 分钟）',
  );

  /// 人声分离。装 CPU 版：GPU 版在 macOS 上没有意义，还多几个 G
  static const audioSeparator = InstallRecipe(
    tool: 'audio-separator',
    requires: 'uv',
    command: ['uv', 'tool', 'install', 'audio-separator[cpu]'],
    description: '安装人声分离工具（走清华镜像，约 1GB / 5~15 分钟；'
        '只有换配乐时才用得到）',
    environment: Mirrors.pypi,
    prerequisiteHint: '需要先装 uv（Python 工具管理器）。请在终端执行 '
        'brew install uv，装好后回到这里点「重新检测」；'
            '命令行那头跑 ishkafel doctor 复查。',
  );

  static const windowsAudioSeparator = InstallRecipe(
    tool: 'audio-separator',
    requires: 'uv',
    command: ['uv', 'tool', 'install', 'audio-separator[cpu]'],
    description: '安装人声分离工具（走清华镜像，约 1GB / 5~15 分钟；'
        '只有换配乐时才用得到）',
    environment: Mirrors.pypi,
    prerequisiteHint: '需要先安装 Windows 版 uv（Python 工具管理器）。请按 uv 官方文档'
        '安装，完成后回到这里点「重新检测」；PowerShell 中可运行 '
        'ishkafel doctor 复查。',
  );

  static const all = [ffmpeg, miaoa, audioSeparator];

  /// 这个工具有没有配方
  static InstallRecipe? forTool(String tool, {String? operatingSystem}) {
    if ((operatingSystem ?? Platform.operatingSystem) == 'windows') {
      // FFmpeg/ffprobe 是正式包的一部分；缺失说明包损坏，在线装另一版会破坏
      // 成片确定性。miaoa 尚无经确认的 Windows 安装器，也不能拿 bash 配方硬跑。
      if (tool == 'audio-separator') return windowsAudioSeparator;
      return null;
    }
    for (final r in all) {
      // ffprobe 跟着 ffmpeg 一起装
      if (r.tool == tool || (r.tool == 'ffmpeg' && tool == 'ffprobe')) return r;
    }
    return null;
  }
}

/// 安装过程中的一行输出，或者一个终局。
class InstallEvent {
  /// 子进程吐的一行（已去掉行尾换行）
  final String? line;

  /// 非 null 表示装完了：true 成功，false 失败
  final bool? done;

  /// 失败原因（可直接展示）
  final String? failure;

  const InstallEvent.output(String this.line)
      : done = null,
        failure = null;

  const InstallEvent.succeeded()
      : line = null,
        done = true,
        failure = null;

  const InstallEvent.failed(String this.failure)
      : line = null,
        done = false;
}

/// 在用户的机器上跑一条安装命令，**逐行把输出交出去**。
///
/// 为什么必须流式：这些命令动辄几分钟。一个不说话的转圈和一个卡死的程序，
/// 用户分不出来——而 `brew install ffmpeg` 中途还会问东西、报进度，那些都
/// 是他判断「还活着吗」的依据。
class ToolInstaller {
  /// 起子进程。抽出来是为了让流程能脱离真实安装单测
  final Future<Process> Function(
      String executable, List<String> args, Map<String, String> env) start;

  /// 解析可执行文件（GUI 进程的 PATH 里没有 Homebrew 目录，见
  /// [MediaToolsLocator]）
  final String? Function(String name) resolve;

  ToolInstaller({
    Future<Process> Function(String, List<String>, Map<String, String>)? start,
    String? Function(String)? resolve,
  })  : start = start ?? _startWith,
        resolve = resolve ?? sharedMediaToolsLocator.resolve;

  /// 起子进程并把镜像源等环境变量**追加**进去（父进程环境照常继承，
  /// 否则 PATH、HOME 全没了，brew 与 uv 都跑不起来）
  static Future<Process> _startWith(
          String executable, List<String> args, Map<String, String> env) =>
      Process.start(executable, args, environment: env);

  /// 前置命令在不在。不在就别跑——见 [InstallRecipe.requires]
  bool prerequisiteReady(InstallRecipe recipe) =>
      recipe.requires == null || resolve(recipe.requires!) != null;

  /// 跑这条配方。返回的流会先逐行吐输出，最后一个事件是 done。
  Stream<InstallEvent> run(InstallRecipe recipe) async* {
    if (!prerequisiteReady(recipe)) {
      yield InstallEvent.failed(recipe.prerequisiteHint);
      return;
    }
    // 前置命令要用解析到的绝对路径起：GUI 进程的 PATH 里往往没有它
    final executable = resolve(recipe.command.first) ?? recipe.command.first;
    final args = recipe.command.sublist(1);

    yield InstallEvent.output('\$ ${recipe.displayCommand}');
    final Process process;
    try {
      process = await start(executable, args, recipe.environment);
    } catch (e) {
      AppLog.warn('启动安装命令失败（${recipe.tool}）：$e');
      yield InstallEvent.failed('起不了安装命令：$e');
      return;
    }

    final lines = StreamController<String>();
    // stdout 与 stderr 都要：安装工具习惯把进度写在 stderr，只收 stdout
    // 会得到一个几分钟不动的空面板
    final subs = [
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      process.stderr.transform(utf8.decoder).transform(const LineSplitter()),
    ].map((s) => s.listen(lines.add, onError: (Object e) => lines.add('$e')));
    unawaited(Future.wait(subs.map((s) => s.asFuture<void>()))
        .whenComplete(lines.close));

    final tail = <String>[];
    await for (final line in lines.stream) {
      tail.add(line);
      if (tail.length > _tailKept) tail.removeAt(0);
      yield InstallEvent.output(line);
    }

    final code = await process.exitCode;
    if (code == 0) {
      yield const InstallEvent.succeeded();
      return;
    }
    yield InstallEvent.failed(_explain(recipe, tail, code));
  }

  /// 失败时说什么。**原始报文要给出来**——安装失败的原因千奇百怪（网络、
  /// 磁盘、权限、平台不支持），糊一句「安装失败」等于让人去猜。
  static String _explain(InstallRecipe recipe, List<String> tail, int code) {
    final text = tail.join('\n');
    // miaoa 的官方约定：脚本说这个平台不支持就到此为止，不去找别的安装途径
    if (text.toLowerCase().contains('unsupported platform')) {
      return '这台机器的系统或 CPU 架构，miaoa 官方安装脚本不支持。'
          '请把这条信息告诉 miaoa 团队，不要自行下载其它来源的二进制。';
    }
    final last = tail.reversed.firstWhere((l) => l.trim().isNotEmpty,
        orElse: () => '');
    return '安装失败（退出码 $code）${last.isEmpty ? '' : '：$last'}';
  }

  /// 失败时回看多少行。太少看不出原因，太多把界面淹了
  static const _tailKept = 40;
}
