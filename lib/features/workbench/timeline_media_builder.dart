import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../../core/analysis/analysis_pipeline.dart';
import '../../core/analysis/audio_extractor.dart';
import '../../core/ffmpeg/thumbnail_service.dart';
import '../../core/log/app_log.dart';

/// 时间线辅助素材：等间隔缩略帧序列 + 归一化波形包络
class TimelineMedia {
  /// 抽帧路径，**下标即时间格**。失败的那一格保留为 null 而不是从列表里挤掉：
  /// 挤掉之后剩余各张会被按新长度重新等分铺开，从失败点起每格显示的都是
  /// 下一格的画面，用户按画面定位切点会一直定错，且界面零提示。
  final List<String?> thumbPaths;
  final List<double> waveEnvelope;

  /// 用不可变列表包裹，避免调用方误改已构建好的产物
  TimelineMedia({required List<String?> thumbPaths, required List<double> waveEnvelope})
      : thumbPaths = List.unmodifiable(thumbPaths),
        waveEnvelope = List.unmodifiable(waveEnvelope);

  /// 几张没抽出来。**界面要照着它说话**
  int get thumbsMissing => thumbPaths.where((p) => p == null).length;

  /// 一张都没抽出来——那条轨是空的，不能当成「已就绪」画一片空白
  bool get thumbsAllMissing =>
      thumbPaths.isEmpty || thumbPaths.every((p) => p == null);

  /// 波形没算出来。失败时兜底返回的是**全 0 的列表**（不是空列表），
  /// 只判 isEmpty 会漏掉：画出来是贴着底的一条直线，看着像「这段没声音」，
  /// 而实际是没算成（2026-09-15 真机：「这个音频和画面轨是空的？」）
  bool get waveAllSilent =>
      waveEnvelope.isEmpty || waveEnvelope.every((v) => v == 0);
}

/// 时间线媒体构建器：抽取等间隔缩略图 + 计算音频波形包络
///
/// 时间线是辅助视觉，任何一步失败都不应阻断审片台页面：
/// 抽帧失败则跳过该张，音频提取失败则包络返回全 0，均只记录警告日志。
class TimelineMediaBuilder {
  final ThumbnailService thumbnails;
  final AudioExtractor audio;

  TimelineMediaBuilder({required this.thumbnails, required this.audio});

  /// 缩略图缓存最小有效字节数：远小于正常抽帧输出（JPEG 文件头 + 最小编码数据
  /// 通常远超过此值），只用于过滤 0 字节/被中途截断的坏缓存文件
  static const int _minValidThumbBytes = 512;

  /// PCM 缓存最小有效字节数（严格大于此值才算有效）：16 位小端采样至少占 2
  /// 字节，阈值取 1 即要求长度 >= 2，否则视为损坏产物（例如上次运行中途失败
  /// 留下的半截文件，凑不出一个完整采样）
  static const int _minValidPcmBytes = 1;

  /// 胶片条抽帧密度：每多少毫秒一张
  ///
  /// 固定 14 张时，96 秒素材每张代表 6.9 秒、5 分钟素材每张代表 21.4 秒，
  /// 胶片条退化成十几块彩色噪声，起不到"按画面定位"的作用。按每 3 秒一张
  /// 取，并设上限控制首次加载耗时（4 路并发下 32 张约 1.2 秒）。
  static const int _msPerThumb = 3000;

  /// 抽帧张数下限/上限
  static const int _minThumbCount = 14;
  static const int _maxThumbCount = 32;

  /// 按片长推导抽帧张数
  static int thumbCountFor(int durationMs) =>
      (durationMs / _msPerThumb).round().clamp(_minThumbCount, _maxThumbCount);

  /// 包络采样密度（每秒样本数）。
  ///
  /// 波形的用途是让用户看清语句之间的停顿来定切点，因此它的分辨率必须跟得上
  /// **放大后**的像素密度：固定 240 桶时，5 分钟素材每桶 1.25 秒，放大 20 倍后
  /// 满屏只有十几根等高宽柱，完全看不出停顿。按每秒 100 个样本取，20 倍放大下
  /// 每样本约 10ms，与像素密度同量级。代价可忽略：10 分钟素材 60000 个 double
  /// 约 480KB，且 computeEnvelope 的耗时只与 PCM 采样数有关、与桶数无关。
  static const int _envelopeSamplesPerSecond = 100;

  /// 包络桶数下限（极短素材也要有足够的柱子）
  static const int _minEnvelopeBuckets = 240;

  /// 包络桶数上限（超长素材的内存兜底）
  static const int _maxEnvelopeBuckets = 60000;

  /// 按片长推导包络桶数
  static int envelopeBucketsFor(int durationMs) {
    final byDuration =
        (durationMs / 1000 * _envelopeSamplesPerSecond).round();
    return byDuration.clamp(_minEnvelopeBuckets, _maxEnvelopeBuckets);
  }

  /// 抽帧并发上限。视频解码是重活，无上限并发会把 CPU 打满、拖慢正在
  /// 播放的预览；实测 4 路已能把 14 张的总耗时从 2.04s 压到 1.4s 以内。
  static const int _thumbConcurrency = 4;

  Future<TimelineMedia> build({
    required String videoPath,
    required String taskId,
    required int durationMs,
    required Directory workDir,
    int? thumbCount,
    int? waveBuckets,
  }) async {
    // The production work directory is task data, not a temporary directory
    // created by the caller. A task's first workbench open therefore reaches
    // this method before the directory exists.
    await workDir.create(recursive: true);
    // 抽帧与波形互不依赖，并行推进：此前波形要等 14 张图全抽完才开始，
    // 白白把两件事的耗时串成一条
    final results = await Future.wait([
      _buildThumbnails(
        videoPath: videoPath,
        taskId: taskId,
        durationMs: durationMs,
        workDir: workDir,
        thumbCount: thumbCount ?? thumbCountFor(durationMs),
      ),
      _buildEnvelope(
        videoPath: videoPath,
        taskId: taskId,
        workDir: workDir,
        waveBuckets: waveBuckets ?? envelopeBucketsFor(durationMs),
      ),
    ]);
    return TimelineMedia(
      thumbPaths: results[0] as List<String?>,
      waveEnvelope: results[1] as List<double>,
    );
  }

  Future<List<String?>> _buildThumbnails({
    required String videoPath,
    required String taskId,
    required int durationMs,
    required Directory workDir,
    required int thumbCount,
  }) async {
    // 结果按下标回填而不是按完成顺序 append：胶片条是按时间平铺的，
    // 顺序错乱会让用户看到与时间对不上的画面
    final slots = List<String?>.filled(thumbCount, null);
    var next = 0;

    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= thumbCount) return;
        // 文件名带上总张数：张数变化时旧缓存不再命中。否则把 14 张改成 32 张
        // 后，前 14 个下标会沿用「14 张布局」算出的时间点，胶片条与时间对不上。
        final outPath = '${workDir.path}/${taskId}_tl${thumbCount}_$i.jpg';
        if (await _isValidCacheFile(outPath, _minValidThumbBytes)) {
          slots[i] = outPath;
          continue;
        }
        final atSeconds = durationMs * (i + 0.5) / thumbCount / 1000.0;
        try {
          slots[i] = await thumbnails.extractCover(
            videoPath: videoPath,
            outPath: outPath,
            atSeconds: atSeconds,
          );
        } catch (e) {
          AppLog.warn('时间线抽帧失败（第 $i 张，taskId=$taskId）：$e');
        }
      }
    }

    await Future.wait(
        List.generate(math.min(_thumbConcurrency, thumbCount), (_) => worker()));
    return List.unmodifiable(slots);
  }

  Future<List<double>> _buildEnvelope({
    required String videoPath,
    required String taskId,
    required Directory workDir,
    required int waveBuckets,
  }) async {
    // 缓存的是**算好的包络**（几百个浮点，几 KB），不是 PCM 本身。
    //
    // 早先是留着那份 16kHz 单声道 PCM 复用——可它一条 96 秒的片子就有 18MB，
    // 而时间线要的只有包络。存包络之后 PCM 就成了纯中转文件，分析跑完即删。
    final wavePath = timelineWavePath(workDir, taskId);
    final cached = await _readEnvelope(wavePath, waveBuckets);
    if (cached != null) return cached;

    final pcmPath = analysisPcmPath(workDir, taskId);
    try {
      final samples = await _isValidCacheFile(pcmPath, _minValidPcmBytes)
          ? AudioExtractor.bytesToPcm16(await File(pcmPath).readAsBytes())
          : await audio.extractSamples(
              videoPath: videoPath, outPcmPath: pcmPath);
      final envelope = computeEnvelope(samples, waveBuckets);
      await _writeEnvelope(wavePath, envelope);
      // 算完就把中转的 PCM 丢掉：下次进来直接读包络，不必再解一遍音频
      await _discard(File(pcmPath));
      return envelope;
    } catch (e) {
      AppLog.warn('时间线音频提取失败（taskId=$taskId）：$e');
      return List.filled(waveBuckets, 0.0);
    }
  }

  /// 读缓存的包络。桶数对不上（换了窗口宽度）就当没有——按别的桶数画出来
  /// 的波形会和时间线对不齐
  static Future<List<double>?> _readEnvelope(String path, int buckets) async {
    final file = File(path);
    if (!await file.exists()) return null;
    try {
      final json = jsonDecode(await file.readAsString());
      if (json is! Map) return null;
      if (json['buckets'] != buckets) return null;
      final values = json['envelope'];
      if (values is! List) return null;
      return List<double>.unmodifiable(
          values.map((v) => (v as num).toDouble()));
    } catch (e) {
      // 半截文件/格式变了：当没有，重算一遍就是
      AppLog.warn('读取时间线波形缓存失败 $path：$e');
      return null;
    }
  }

  static Future<void> _writeEnvelope(String path, List<double> envelope) async {
    try {
      await File(path).writeAsString(jsonEncode({
        'buckets': envelope.length,
        // 三位小数足够画波形，全精度会让文件大三倍
        'envelope': [
          for (final v in envelope) double.parse(v.toStringAsFixed(3)),
        ],
      }));
    } catch (e) {
      AppLog.warn('写入时间线波形缓存失败 $path：$e');
    }
  }

  static Future<void> _discard(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (e) {
      AppLog.warn('清理中转 PCM 失败 ${file.path}：$e');
    }
  }

  /// 缓存文件有效性校验：存在且字节数超过阈值，避免复用 0 字节/被截断的坏产物
  Future<bool> _isValidCacheFile(String path, int minValidBytes) async {
    final file = File(path);
    if (!await file.exists()) return false;
    return await file.length() > minValidBytes;
  }

  /// 纯函数：PCM 采样均分为 buckets 份，逐份计算 RMS，再按全局最大值归一化到 [0,1]
  ///
  /// 全静音（最大值为 0）或采样为空时返回全 0（长度仍为 buckets）
  static List<double> computeEnvelope(List<int> samples, int buckets) {
    if (buckets <= 0) return const [];
    if (samples.isEmpty) return List.filled(buckets, 0.0);

    final rms = List<double>.filled(buckets, 0.0);
    for (var b = 0; b < buckets; b++) {
      final start = (samples.length * b / buckets).floor();
      final end = (samples.length * (b + 1) / buckets).floor();
      if (end <= start) continue;
      var sumSquares = 0.0;
      for (var i = start; i < end; i++) {
        final value = samples[i].toDouble();
        sumSquares += value * value;
      }
      rms[b] = math.sqrt(sumSquares / (end - start));
    }

    final maxValue = rms.reduce(math.max);
    if (maxValue == 0) return List.filled(buckets, 0.0);
    return rms.map((v) => v / maxValue).toList();
  }
}
