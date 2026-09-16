import 'dart:io';

import 'package:path/path.dart' as p;

import '../log/app_log.dart';
import 'audio_extractor.dart';
import 'providers.dart';

/// 把**一段底片素材**转写出来，拿到它自己的词级时间戳。
///
/// 为什么非要转写：底片换成一条素材之后，原片那份 ASR 跟这段画面毫无关系
/// ——拿它取词，烧上去的台词和画面对不上。而字幕这条线从头到尾都建立在
/// 「词级时间戳」上（见 [subtitleLinesInSlot]），拿别的东西凑不出来：
/// 按时长摊字数出来的时间点在成片里一看就飘。
///
/// 产品负责人在 A（按时长摊）和 B（真转写）之间选了 B：
/// 「这条产品线的字幕是要交付的。」
class BaseTranscriber {
  final AudioExtractor audio;
  final AsrProvider asr;
  final Directory workDir;

  const BaseTranscriber({
    required this.audio,
    required this.asr,
    required this.workDir,
  });

  /// 转写 [videoPath]。[key] 只用来给中转的 PCM 起名（带上任务 id 前缀，
  /// 清理器才认得出是谁的）。
  ///
  /// **失败返回 null 而不是空列表**：空列表的意思是「转过、这条素材没人说话」，
  /// 两者在界面上要分得开——一个说「没有台词」，一个说「转写失败，重试」
  Future<List<AsrSentence>?> transcribe({
    required String videoPath,
    required String key,
  }) async {
    await workDir.create(recursive: true);
    final pcmPath = p.join(workDir.path, '$key.pcm');
    try {
      await audio.extractSamples(videoPath: videoPath, outPcmPath: pcmPath);
      final sentences = await asr.transcribe(pcmPath);
      return List.unmodifiable(sentences);
    } catch (e) {
      AppLog.warn('底片转写失败（$videoPath）：$e');
      return null;
    } finally {
      // PCM 是纯中转的（一条 16 秒的素材约 500KB，长素材更大），
      // 转完即弃——留着既占盘又没人读
      try {
        final f = File(pcmPath);
        if (f.existsSync()) await f.delete();
      } catch (_) {
        // 删不掉不值得打断什么，孤儿清扫会兜住
      }
    }
  }
}
