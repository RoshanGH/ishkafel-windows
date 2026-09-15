import 'dart:io';

import 'package:path/path.dart' as p;

import '../ffmpeg/process_runner.dart';
import '../ffmpeg/filtergraph_escape.dart';
import 'frame_signal.dart';
import '../log/app_log.dart';

/// `metadata=print` 的每条记录：`pts_time:0.0333 … lavfi.scene_score=0.101`
final _sceneRecord = RegExp(
  r'pts_time:([0-9]+(?:\.[0-9]+)?)[\s\S]*?lavfi\.scene_score=([0-9.]+)',
);

/// 缩略图边长。取小是刻意的：分辨率越低越不受运动细节影响，只留色彩构成，
/// 而整片的逐帧特征也才几 MB（96 秒 30fps 约 8.8MB）。
const int signalThumbSide = 32;

/// 把 ffmpeg 的两份产物拼成逐帧信号（纯函数，对齐逻辑可穷举验证）。
///
/// **对齐是这里唯一容易错、且错了不报警的地方**：`scene_score` 描述的是
/// 「这一帧相对前一帧」，所以 metadata 的第 j 条对应缩略图的第 **j+1** 帧
/// （第 0 帧没有前一帧，不产生记录）。标定时错开一帧的后果是两个指标的
/// 高分位完全不重合（实测交集为 0），而代码本身不会报任何错。
List<FrameSignal> buildFrameSignals({
  required String sceneMetadata,
  required List<int> thumbBytes,
  int side = signalThumbSide,
}) {
  final frameSize = side * side * 3;
  if (frameSize <= 0 || thumbBytes.length < frameSize * 2) return const [];
  final frameCount = thumbBytes.length ~/ frameSize;

  List<double> histAt(int i) => histogramOfRgb24(
    thumbBytes.sublist(i * frameSize, (i + 1) * frameSize),
    side: side,
  );

  final signals = <FrameSignal>[];
  var previous = histAt(0);
  var j = 0;
  for (final m in _sceneRecord.allMatches(sceneMetadata)) {
    final i = j + 1; // 见上：第 j 条记录描述的是第 j+1 帧
    j++;
    if (i >= frameCount) break;
    final current = histAt(i);
    signals.add(
      FrameSignal(
        ms: (double.parse(m.group(1)!) * 1000).round(),
        sceneScore: double.parse(m.group(2)!),
        histDistance: histogramDistance(previous, current),
      ),
    );
    previous = current;
  }
  return List.unmodifiable(signals);
}

/// 采集逐帧画面变化信号（scene 分数 + 颜色直方图）。
///
/// 走两次 ffmpeg 而不是一条 filter_complex：后者要用 split + 双输出映射，
/// 写法晦涩且一处参数写错就静默产出错位数据。两次调用在 96 秒素材上各约
/// 10 秒，相比后面几分钟的打标可以忽略。
class FrameSignalExtractor {
  final ProcessRunner run;
  final Directory workDir;

  const FrameSignalExtractor({
    required this.workDir,
    this.run = systemProcessRunner,
  });

  /// 只取 scene 分数用的 filter：`gt(scene,0)` 让**每一帧**都产出记录，
  /// 而不是只留超过阈值的那些——阈值判定放到 Dart 侧做，才能自适应
  static List<String> sceneArgs(String videoPath, String outPath) => [
    '-i',
    videoPath,
    '-vf',
    "select='gt(scene,0)',metadata=print:file=${escapeFfmpegFilterPath(outPath)}",
    '-f',
    'null',
    '-',
  ];

  static List<String> thumbArgs(String videoPath, String outPath) => [
    '-y',
    '-i',
    videoPath,
    '-vf',
    'scale=$signalThumbSide:$signalThumbSide:flags=bilinear,format=rgb24',
    '-f',
    'rawvideo',
    outPath,
  ];

  Future<List<FrameSignal>> extract(
    String videoPath, {
    required String taskId,
  }) async {
    await workDir.create(recursive: true);
    final scenePath = p.join(workDir.path, '${taskId}_scene.txt');
    final thumbPath = p.join(workDir.path, '${taskId}_thumbs.raw');

    final sceneResult = await run('ffmpeg', sceneArgs(videoPath, scenePath));
    if (sceneResult.exitCode != 0) {
      throw FfmpegException(
        'ffmpeg 场景分析失败（exit=${sceneResult.exitCode}）：${sceneResult.stderr}',
      );
    }
    final thumbResult = await run('ffmpeg', thumbArgs(videoPath, thumbPath));
    if (thumbResult.exitCode != 0) {
      throw FfmpegException(
        'ffmpeg 缩略图提取失败（exit=${thumbResult.exitCode}）：${thumbResult.stderr}',
      );
    }

    final sceneFile = File(scenePath);
    final thumbFile = File(thumbPath);
    if (!await sceneFile.exists() || !await thumbFile.exists()) {
      throw const FfmpegException('画面分析产物缺失，无法检测视觉镜头切点');
    }
    final signals = buildFrameSignals(
      sceneMetadata: await sceneFile.readAsString(),
      thumbBytes: await thumbFile.readAsBytes(),
    );
    // 这两个是 ffmpeg 与 Dart 之间的中转文件，读完就再没人看了。
    // 缩略图流一条 96 秒的片子就是 8.5MB，留着只是白占地方
    await _discard(sceneFile);
    await _discard(thumbFile);
    return signals;
  }

  /// 删不掉不算错误：中转文件留下来最多占点地方，为它中断切点检测才是本末倒置
  static Future<void> _discard(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (e) {
      AppLog.warn('清理画面分析中转文件失败 ${file.path}：$e');
    }
  }
}
