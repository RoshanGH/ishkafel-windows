import 'dart:io';

import 'package:path/path.dart' as p;

import '../ffmpeg/media_tools_locator.dart';
import '../ffmpeg/process_runner.dart';
import '../log/app_log.dart';

/// 分离出来的两条轨
class SeparatedAudio {
  /// 纯人声（口播）
  final String vocalsPath;

  /// 纯背景（原片自带的音乐/环境声）
  final String backgroundPath;

  const SeparatedAudio({required this.vocalsPath, required this.backgroundPath});
}

/// 把原片音频拆成「纯人声口播」与「纯背景音乐」两条轨。
///
/// **为什么必须真的分离**：产品要换掉背景音乐。不分离的话，新配乐只能叠在
/// 原声之上——原片自带的背景音还在，两首曲子一起响。
///
/// **但分离是有损的**：真机实测，人声轨 + 背景轨相加与原混音相减，残差在
/// -27dB（听得出来）。所以只有**真的换了配乐的段落**才用分离结果，其余段落
/// 一律用原混音，一个字节都不动。这条策略在混音那一层实现，本类只管分离。
///
/// 走 `audio-separator` 命令行（BS-Roformer 模型，见 [model]）。
/// 给分离工具抽一道它读得懂的音频（立体声 wav）。
///
/// 与 [AudioExtractor] 那条不是一回事：那边出的是给 ASR 用的单声道 16k PCM，
/// 分离要的是原采样率的立体声——降过声道再分，出来的两轨都是废的。
Future<String> extractAudioForSeparation(
  String input,
  String out, {
  ProcessRunner run = systemProcessRunner,
}) async {
  final result = await run('ffmpeg', [
    '-y', '-v', 'error',
    '-i', input,
    // 只要声音；保持立体声与原采样率
    '-vn', '-ac', '2', '-ar', '44100',
    out,
  ]);
  if (result.exitCode != 0) {
    throw VocalSeparationException(
        '抽音频失败（exit=${result.exitCode}）：${result.stderr}');
  }
  return out;
}

class VocalSeparator {
  final ProcessRunner run;

  /// 可执行文件路径（由 [resolveVocalSeparatorBinary] 解析）
  final String binary;

  /// 模型文件落地目录。**必须显式指定**：这个工具默认放 `/tmp`，
  /// 系统清理临时目录后每次都要重新下载几百兆。
  final Directory modelDir;

  /// 把视频/任意媒体抽成分离工具读得懂的音频。返回落地的路径。
  ///
  /// **必须先抽这一道**：`audio-separator` 走 `soundfile` 读输入，它认
  /// wav/flac 这类，**不认 mp4**——直接把视频喂过去就是
  /// `Format not recognised`，而界面上只会显示「分离失败」。
  /// 真机 2026-09-07：这台机器上分离从来没成功过，就是栽在这儿。
  final Future<String> Function(String input, String out)? extractAudio;

  const VocalSeparator({
    required this.modelDir,
    this.run = systemProcessRunner,
    this.binary = 'audio-separator',
    this.extractAudio,
  });

  /// 这些后缀 `soundfile` 直接读得了，不用白抽一道
  static const Set<String> readableExtensions = {
    '.wav', '.flac', '.aiff', '.aif', '.ogg',
  };

  /// 用的模型：UVR-MDX-NET-Inst_HQ_3。
  ///
  /// **选它是拿音质换速度，这是产品决定，不是技术判断**。同一条 96 秒素材上
  /// 实测（M1 Pro）：
  ///
  /// | 模型 | 耗时 | 模型体积 | 听感 |
  /// |---|---|---|---|
  /// | 本模型（MDX 系列） | **15s** | 64MB | 人声里还留着背景音乐 |
  /// | 两遍 MDX | 29s | 64MB×2 | 未评 |
  /// | BS-Roformer | 81s | 610MB | 几乎只剩人声 |
  /// | Mel-Band Roformer | 94s | 961MB | 未评 |
  /// | demucs.cpp（MixCut 用的） | 227s | 80MB | 可接受 |
  ///
  /// 质量最好的是 BS-Roformer，但它慢 5 倍、模型大 10 倍。用户权衡后选了速度。
  ///
  /// **另一条记录**：这几个模型的差异**用指标测不出来**——RMS、频段能量、
  /// 包络相关性在它们之间全在 -30dB 以下。压在人声下面 20~30dB 的音乐在总
  /// 能量里只占千分之几，人耳却一听一个准。这类判断只能靠听。
  static const String model = 'UVR-MDX-NET-Inst_HQ_3.onnx';

  /// 模型的短标记，进产物文件名——换模型后能自动重算，不会复用旧产物。
  /// 这次换模型正是靠它：旧的 roformer 产物还在磁盘上，不会被误当成新结果。
  static String get modelTag =>
      model.contains('roformer') ? 'roformer' : 'mdx';

  /// 攒批与分段。**对当前这个 MDX 模型是决定性的**：默认的 batch 1 /
  /// segment 256 要 2 分 09 秒，改成 8 / 512 只要 15 秒——8.6 倍，而两次
  /// 输出逐样本相减的残差只有 -40dB（听不出差别）。
  ///
  /// MDXC（Roformer 那一支）的参数名不同，也一并给上：不认的那套会被忽略，
  /// 换模型时不必跟着改调用点。（顺带记一笔：加大 batch 对 Roformer 没用，
  /// 实测 1:22 vs 1:23，Apple GPU 已经吃满。）
  static const int batchSize = 8;
  static const int segmentSize = 512;

  /// 在途的分离，**按产物路径**登记。
  ///
  /// 静态是有意的：调用方每次都现造一个分离器（见 main.dart 里的
  /// `materialVocals`），登记在实例上根本拦不住；而要守的东西本来就是全局
  /// 的——同一组产物文件。
  ///
  /// 真机事故（2026-09-04）：一条素材被并发起了 **14 个**分离进程，还都往
  /// 同一组文件里写。下面那句「已经分离过就直接复用」只认**跑完**的产物，
  /// 上一次还在跑的那段时间里，每个调用方都会再起一个。以前没人发现，是
  /// 因为它们全都因为找不到 ffmpeg 秒退；PATH 一修好就把机器拖垮了。
  static final Map<String, Future<SeparatedAudio>> _inFlight = {};

  /// 分离 [audioPath]，两条轨落到 [outputDir]。
  ///
  /// 已经分离过就直接复用（重进任务不该再等一遍）；**上一次还在跑就等它**，
  /// 不再起第二个（见 [_inFlight]）。
  Future<SeparatedAudio> separate({
    required String audioPath,
    required Directory outputDir,
  }) {
    outputDir.createSync(recursive: true);
    modelDir.createSync(recursive: true);

    // 文件名带上模型标记：换了模型就该重新分离，而不是把上一个模型的产物
    // 当成新结果接着用——那正是这次踩到的问题（旧模型分不干净）
    final stem = '${p.basenameWithoutExtension(audioPath)}-$modelTag';
    final vocals = File(p.join(outputDir.path, '$stem-人声.wav'));
    final background = File(p.join(outputDir.path, '$stem-背景.wav'));
    if (vocals.existsSync() &&
        background.existsSync() &&
        vocals.lengthSync() > 0 &&
        background.lengthSync() > 0) {
      return Future.value(SeparatedAudio(
          vocalsPath: vocals.path, backgroundPath: background.path));
    }

    final running = _inFlight[vocals.path];
    if (running != null) return running;

    final job = _separate(audioPath, outputDir, stem, vocals, background);
    _inFlight[vocals.path] = job;
    // 失败也要摘登记，否则这条素材在本次启动里就永远重试不了
    job.whenComplete(() => _inFlight.remove(vocals.path)).ignore();
    return job;
  }

  /// 交给分离工具的那个文件：本来就读得了就原样用，否则抽一道音频。
  ///
  /// 抽出来的中间文件跟产物落在同一个目录——按任务归属，删任务时一并清掉，
  /// 不会变成孤儿
  Future<String> _readableInput(
      String audioPath, Directory outputDir, String stem) async {
    final ext = p.extension(audioPath).toLowerCase();
    if (readableExtensions.contains(ext)) return audioPath;
    final extract = extractAudio;
    if (extract == null) return audioPath;
    return extract(audioPath, p.join(outputDir.path, '$stem-输入.wav'));
  }

  Future<SeparatedAudio> _separate(String audioPath, Directory outputDir,
      String stem, File vocals, File background) async {
    // 视频（或任何 soundfile 读不了的东西）先抽成 wav 再喂
    final input = await _readableInput(audioPath, outputDir, stem);
    final result = await run(binary, [
      input,
      '--model_filename', model,
      '--model_file_dir', modelDir.path,
      '--output_dir', outputDir.path,
      '--output_format', 'WAV',
      '--mdx_batch_size', '$batchSize',
      '--mdx_segment_size', '$segmentSize',
      '--mdxc_batch_size', '$batchSize',
      // 输出文件名固定，省得去猜工具按模型名拼出来的那一长串
      '--custom_output_names',
      '{"Vocals": "$stem-人声", "Instrumental": "$stem-背景"}',
    ]);

    if (result.exitCode != 0) {
      throw VocalSeparationException(
          _friendlyError(result.exitCode, '${result.stderr}'));
    }
    if (!vocals.existsSync() || !background.existsSync()) {
      AppLog.warn('人声分离没有产出预期文件：${result.stdout}');
      throw const VocalSeparationException('人声分离没有产出音轨文件，请重试');
    }
    return SeparatedAudio(
        vocalsPath: vocals.path, backgroundPath: background.path);
  }

  /// 把命令行的失败翻译成用户能照做的中文。
  ///
  /// **分清是谁没找到**：这个工具自己还要调 ffmpeg 来解码，缺 ffmpeg 时它抛的
  /// 同样是「No such file」。真机上（2026-09-04）就因此把人支使去装一个早就
  /// 装好的工具——说错原因比不说更糟，他会照做，然后发现还是不行。
  static String _friendlyError(int exitCode, String stderr) {
    final lower = stderr.toLowerCase();
    final missing =
        lower.contains('no such file') || lower.contains('not found');
    if (missing && lower.contains('ffmpeg')) {
      return '人声分离工具找不到 ffmpeg（它要靠 ffmpeg 解码）。'
          '请确认已安装 ffmpeg 后重新启动本应用';
    }
    if (missing) {
      return '未检测到人声分离工具，请先安装后重试';
    }
    if (lower.contains('connection') || lower.contains('timed out')) {
      return '下载分离模型失败，请检查网络后重试';
    }
    AppLog.warn('人声分离失败（exit=$exitCode）：$stderr');
    return '人声分离失败，请稍后重试';
  }
}

class VocalSeparationException implements Exception {
  final String message;
  const VocalSeparationException(this.message);
  @override
  String toString() => 'VocalSeparationException: $message';
}

/// `audio-separator` 的常见安装位置。
///
/// 与 miaoa 同一个坑：GUI 进程的 PATH 里没有用户级 bin 目录。`uv tool install`
/// 装到 `~/.local/bin`，pipx 也是。
List<String> vocalSeparatorSearchDirsFor({
  String? operatingSystem,
  Map<String, String>? environment,
  List<String>? defaultDirs,
}) {
  final os = operatingSystem ?? Platform.operatingSystem;
  final env = environment ?? Platform.environment;
  final home = env[os == 'windows' ? 'USERPROFILE' : 'HOME'];
  final path = p.Context(
      style: os == 'windows' ? p.Style.windows : p.Style.posix);
  return List.unmodifiable([
    if (home != null && home.isNotEmpty) path.join(home, '.local', 'bin'),
    ...(defaultDirs ?? MediaToolsLocator.defaultSearchDirsFor(os)),
  ]);
}

final List<String> vocalSeparatorSearchDirs = vocalSeparatorSearchDirsFor();

final _locator = MediaToolsLocator(searchDirs: vocalSeparatorSearchDirs);

/// 解析可执行文件路径；找不到时回退裸名，让子进程照常抛出「未安装」
String resolveVocalSeparatorBinary({MediaToolsLocator? locator}) =>
    (locator ?? _locator).resolve('audio-separator') ?? 'audio-separator';

/// 忘掉「没找到 audio-separator」这个结论，让下一次解析重新探测。
/// 理由同 [forgetMiaoaProbeMisses]：装工具时 app 是开着的。
void forgetVocalSeparatorProbeMisses() => _locator.forgetMisses();
