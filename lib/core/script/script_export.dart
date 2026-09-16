import 'dart:io';

import 'package:path/path.dart' as p;

import '../analysis/providers.dart' show AsrSentence;
import '../export/export_commands.dart';
import '../export/export_spec.dart';
import '../export/unique_export_path.dart';
import '../ffmpeg/process_runner.dart';
import '../presentation/user_facing_exception.dart';
import '../subtitle/subtitle_overlay.dart';
import '../subtitle/subtitle_rasterizer.dart';
import 'skipped_lines_summary.dart';
import '../subtitle/subtitle_style.dart';
import 'script_doc.dart';
import 'shot_coverage.dart';
import 'shot_allocation.dart';

/// 导出失败：message 面向用户，点名到行/镜头
class ScriptExportException implements UserFacingException {
  @override
  final String message;
  final Object? cause;
  const ScriptExportException(this.message, {this.cause});
  @override
  String toString() => message;
}

/// 导出进度（等待要有交代：一段一报）
class ScriptExportProgress {
  final String step;
  final double fraction;

  /// 正在处理哪一行、哪一镜（都从 0 起；不针对具体某行时为 null）。
  ///
  /// **给可视模式用**：只有一句「正在导出：渲染第 10 行第 1 镜」的话，
  /// 界面不知道该看哪儿——人盯着屏幕看到的就是任务列表上一行滚动的字，
  /// 而画面本身纹丝不动
  final int? lineIndex;
  final int? shotIndex;

  const ScriptExportProgress(this.step, this.fraction,
      {this.lineIndex, this.shotIndex});
}

/// 「脚本 → 成片」的导出编排：
///
/// 每镜渲一个规格化切片（框选起点 + 变速 + 字幕烧制）→ concat 视频；
/// 每行出一段音频（配音，画面行为静音）→ concat 音轨 → mux。
///
/// **交付拦截**（最高准则「不静默降级」）：任何一行没就绪（没配音、没镜头、
/// 没分配、素材不在本地）直接失败并点名——成片少一段是不允许的那类错，
/// 预览可以跳行，导出不行。
class ScriptExportRunner {
  final ProcessRunner run;
  final Directory workDir;
  final SubtitleRasterizer rasterizer;

  /// 已固定素材的本地路径（materialId → path）；null = 不在本地
  final String? Function(int materialId) localPathOf;

  /// 本地源镜头（参考段）的文件是否仍然存在
  final bool Function(String path) localSourceOk;

  ScriptExportRunner({
    required this.workDir,
    required this.localPathOf,
    bool Function(String path)? localSourceOk,
    this.run = systemProcessRunner,
    SubtitleRasterizer? rasterizer,
  })  : localSourceOk = localSourceOk ?? ((path) => File(path).existsSync()),
        rasterizer = rasterizer ?? SubtitleRasterizer(run: run);

  /// 导出一条成片到 [outPath]。返回实际输出路径。
  Future<String> export({
    required ScriptDoc doc,
    required String outPath,
    ExportSpec spec = ExportSpec.standard,
    SubtitleStyle? subtitleStyle,
    bool burnSubtitles = true,

    /// 配乐曲子的本地路径（materialId → path）。方案里有段却给不出
    /// 本地文件时直接拦下——成片悄悄少配乐不行
    String? Function(int materialId)? bgmPathOf,
    void Function(ScriptExportProgress progress)? onProgress,
  }) async {
    final style = subtitleStyle ?? doc.subtitle;
    for (final seg in doc.bgmSegments) {
      if (bgmPathOf?.call(seg.material.id) == null) {
        // 正常路径上，界面在这之前已经等过下载、也给过重试与出路；
        // 走到这儿说明确实拿不到文件——说清是哪一段、下一步做什么
        throw ScriptExportException(
            '配乐「${seg.material.name}」在本地找不到，这一版成片会缺这段配乐，'
            '所以先停下了。到配乐色带上重试下载，或把这一段配乐去掉再导。');
      }
    }
    // 画面铺不满坑位的，成片里只能靠克隆最后一帧补满——那是几秒钟的
    // 定格，用户不会当成「设计」，只会当成软件坏了。停下来点名
    final gaps = shotCoverageGaps(doc);
    if (gaps.isNotEmpty) {
      final g = gaps.first;
      throw ScriptExportException(
          '第 ${g.lineIndex + 1} 行第 ${g.shotIndex + 1} 镜的画面只有 '
          '${(g.usableMs / 1000).toStringAsFixed(1)} 秒，'
          '铺不满 ${(g.allocMs / 1000).toStringAsFixed(1)} 秒'
          '${gaps.length > 1 ? '（另有 ${gaps.length - 1} 处同样的问题）' : ''}。'
          '换条长一点的素材、放慢这一镜，或把它截短，再导出。');
    }
    final lines = _readyLines(doc);
    if (lines.isEmpty) {
      throw const ScriptExportException('脚本里还没有可导出的行。');
    }
    await workDir.create(recursive: true);
    final videoParts = <String>[];
    final audioParts = <String>[];
    final totalShots =
        lines.fold(0, (a, e) => a + e.line.shots.length) + lines.length + 2;
    var done = 0;
    void tick(String step, {int? lineIndex, int? shotIndex}) =>
        onProgress?.call(ScriptExportProgress(step, ++done / totalShots,
            lineIndex: lineIndex, shotIndex: shotIndex));

    for (final entry in lines) {
      final line = entry.line;
      final lineIndex = entry.index;
      // 行的字幕（相对行起点的时间轴）；跨镜连续由逐镜裁剪自然形成。
      // 行级覆盖优先（素材自带字幕位置不同时按行改）
      final lineStyle = line.subtitleOverride ?? style;
      final sentences = burnSubtitles
          ? _sentenceOf(line, line.subtitleOverride ?? style)
          : const <AsrSentence>[];
      var shotAtMs = 0;
      for (var j = 0; j < line.shots.length; j++) {
        final shot = line.shots[j];
        final String? src;
        if (shot.localSource != null) {
          src = localSourceOk(shot.localSource!) ? shot.localSource : null;
          if (src == null) {
            throw ScriptExportException(
                '第 ${lineIndex + 1} 行第 ${j + 1} 镜引用的参考视频已不在原位，导出被拦下。');
          }
        } else {
          src = localPathOf(shot.materialId);
          if (src == null) {
            throw ScriptExportException(
                '第 ${lineIndex + 1} 行第 ${j + 1} 镜的素材在本地找不到，'
                '成片会缺这一段画面，所以先停下了。'
                '到这一镜的卡片上重试下载，或换一条素材再导。');
          }
        }
        final allocMs = shot.allocMs!;
        final overlays = await _overlaysFor(
          sentences: sentences,
          slotStartMs: shotAtMs,
          slotEndMs: shotAtMs + allocMs,
          spec: spec,
          style: lineStyle,
        );
        final out = p.join(workDir.path, 'v_${lineIndex}_$j.mp4');
        await _exec(
          _shotVideoArgs(
            input: src,
            trimStartMs: shot.trimStartMs,
            allocMs: allocMs,
            speed: shot.speed,
            spec: spec,
            overlays: overlays,
            out: out,
          ),
          what: '第 ${lineIndex + 1} 行第 ${j + 1} 镜',
        );
        videoParts.add(out);
        shotAtMs += allocMs;
        tick('渲染第 ${lineIndex + 1} 行第 ${j + 1} 镜',
            lineIndex: lineIndex, shotIndex: j);
      }
      // 行音频：配音行 = 配音（截/补到行画面长）；画面行 = 素材原声
      final lineSpanMs = shotAtMs;
      final audioOut = p.join(workDir.path, 'a_$lineIndex.wav');
      final vo = line.voiceover;
      if (line.type == ScriptLineType.voiced && vo != null) {
        // 素材原声：分镜自带的声音里常有音效（喷雾声、开门声）。
        // 配音行默认跟随全片基调（默认 0：原声会和口播叠成两份），
        // 逐镜可以单独开小灶。音量只此一处算（见 sourceVolumeFor）
        final sourceTrack = await _lineSourceAudio(
          line: line,
          lineIndex: lineIndex,
          volumeOf: (shot) => doc.sourceVolumeFor(line, shot),
          localPathOf: localPathOf,
        );
        // 口播轨总音量：与预览同一条规则（见 ScriptDoc.voiceVolume）
        final vv = doc.voiceVolume;
        final voFilter =
            (vv - 1).abs() < 1e-6 ? 'apad' : 'volume=${vv.toStringAsFixed(3)},apad';
        if (sourceTrack == null) {
          await _exec([
            '-y', '-v', 'error',
            '-i', vo.audioPath,
            '-af', voFilter,
            '-t', _sec(lineSpanMs),
            '-ar', '48000', '-ac', '2', '-c:a', 'pcm_s16le',
            audioOut,
          ], what: '第 ${lineIndex + 1} 行配音');
        } else {
          // 口播与原声同时响：normalize=0 保住各自的音量（默认的归一化
          // 会把两路都压小，听感上像是口播突然变轻）
          await _exec([
            '-y', '-v', 'error',
            '-i', vo.audioPath,
            '-i', sourceTrack,
            '-filter_complex',
            '[0:a]$voFilter[vo];[1:a]apad[src];'
                '[vo][src]amix=inputs=2:duration=first:normalize=0[out]',
            '-map', '[out]',
            '-t', _sec(lineSpanMs),
            '-ar', '48000', '-ac', '2', '-c:a', 'pcm_s16le',
            audioOut,
          ], what: '第 ${lineIndex + 1} 行配音与原声混合');
        }
      } else {
        // 画面行本来就用素材自己的声音（设计稿：有画面有音乐或用分镜
        // 自己的声音），所以基调是满音量——除非这一镜单独压过
        final track = await _lineSourceAudio(
          line: line,
          lineIndex: lineIndex,
          volumeOf: (shot) => doc.sourceVolumeFor(line, shot),
          localPathOf: localPathOf,
        );
        if (track != null) {
          File(track).renameSync(audioOut);
        } else {
          await _exec([
            '-y', '-v', 'error',
            '-f', 'lavfi', '-i', 'anullsrc=r=48000:cl=stereo',
            '-t', _sec(lineSpanMs),
            '-c:a', 'pcm_s16le',
            audioOut,
          ], what: '第 ${lineIndex + 1} 行静音垫');
        }
      }
      audioParts.add(audioOut);
      tick('铺第 ${lineIndex + 1} 行声音', lineIndex: lineIndex);
    }

    // 拼接与合流
    final videoConcat = p.join(workDir.path, 'video_all.mp4');
    final videoList = File(p.join(workDir.path, 'video.txt'))
      ..writeAsStringSync(ExportCommands.concatList(videoParts));
    await _exec(ExportCommands.concat(listFile: videoList.path, out: videoConcat),
        what: '拼接画面');
    tick('拼接画面');

    final audioConcat = p.join(workDir.path, 'audio_all.wav');
    final audioList = File(p.join(workDir.path, 'audio.txt'))
      ..writeAsStringSync(ExportCommands.concatList(audioParts));
    await _exec([
      '-y', '-v', 'error',
      '-f', 'concat', '-safe', '0', '-i', audioList.path,
      '-c', 'copy', audioConcat,
    ], what: '拼接声音');

    // 配乐段逐个叠上去（行区间 → 成片轴区间；每段各自的曲子与音量）
    var finalAudio = audioConcat;
    if (doc.bgmSegments.isNotEmpty && bgmPathOf != null) {
      // 每行在成片轴的起点：按就绪行的画面长顺序累计
      final lineStartMs = <int, int>{};
      var at = 0;
      for (final entry in lines) {
        lineStartMs[entry.index] = at;
        at += entry.line.shots.fold(0, (b, s) => b + (s.allocMs ?? 0));
      }
      var mixIndex = 0;
      for (final seg in doc.bgmSegments) {
        int? fromMs;
        var toMs = 0;
        for (final entry in lines) {
          if (entry.index < seg.startLine || entry.index > seg.endLine) {
            continue;
          }
          fromMs ??= lineStartMs[entry.index];
          toMs = lineStartMs[entry.index]! +
              entry.line.shots.fold(0, (b, s) => b + (s.allocMs ?? 0));
        }
        if (fromMs == null || toMs <= fromMs) continue;
        final mixed = p.join(workDir.path, 'audio_bgm_${mixIndex++}.wav');
        await _exec(
            ExportCommands.mixBgm(
              voice: finalAudio,
              bgm: bgmPathOf(seg.material.id)!,
              out: mixed,
              startMs: fromMs,
              durationMs: toMs - fromMs,
              // 段上是相对值，乘配乐轨总音量——与预览同一条规则
              bgmVolume: doc.bgmVolumeOf(seg.volume),
            ),
            what: '混配乐（${seg.material.name}）');
        finalAudio = mixed;
      }
    }

    final outFile = File(outPath);
    await outFile.parent.create(recursive: true);
    // 名字撞上就往后排。这条线的名字带到分钟（`#12_0910_1432.mp4`），
    // 同一分钟内导第二次照样重名——ffmpeg 的 `-y` 会把上一条盖掉
    final finalOut = uniqueExportPath(outFile.parent.path, p.basename(outPath));
    await _exec(
        ExportCommands.mux(
            video: videoConcat, audio: finalAudio, out: finalOut),
        what: '合成成片');
    tick('合成成片');
    return finalOut;
  }

  /// 交付拦截：一行行验，问题点名到行。空行（无字无镜头）跳过。
  ///
  /// **同一个原因不抄好几遍**：四行都没挑镜头时，原来会摞出四条一模一样
  /// 的「第 N 行还没挑镜头」——该省的是重复的那句原因，不是行号
  /// （2026-09-10 真机走查，与编导台中栏那处同一个毛病）。
  List<({int index, ScriptLine line})> _readyLines(ScriptDoc doc) {
    final (ready, blocked) = _validateLines(doc);
    if (blocked != null) throw ScriptExportException(blocked);
    return ready;
  }

  /// 交付拦截的**纯函数版**：给界面在打开导出对话框**之前**先问一句。
  ///
  /// 2026-09-10 真机走查：脚本四句只挑了一句的镜头，点「导出成片」照样
  /// 弹出规格面板，人选完分辨率码率点了「开始导出」，才蹦出「没能导出」。
  /// 白填一遍表单——该拦的地方在进门口，不在出门口。
  ///
  /// 返回 null 表示可以导。
  static String? blockingReason(ScriptDoc doc) => _validateLines(doc).$2;

  static (List<({int index, ScriptLine line})>, String?) _validateLines(
      ScriptDoc doc) {
    final ready = <({int index, ScriptLine line})>[];
    final problems = <int, String>{};
    for (var i = 0; i < doc.lines.length; i++) {
      final line = doc.lines[i];
      if (line.text.trim().isEmpty && line.shots.isEmpty) continue;
      final root = ShotAllocation.rootMsOf(line);
      if (root == null) {
        problems[i] = line.type == ScriptLineType.voiced
            ? '还没生成配音'
            : '还没确定时长';
        continue;
      }
      if (line.type == ScriptLineType.voiced &&
          line.voiceState == LineVoiceState.stale) {
        problems[i] = '台词改过了，配音还是旧的（重新生成后再导）';
        continue;
      }
      if (line.shots.isEmpty) {
        problems[i] = '还没挑镜头';
        continue;
      }
      if (line.shots.any((s) => s.allocMs == null)) {
        problems[i] = '镜头还没分时长';
        continue;
      }
      ready.add((index: i, line: line));
    }
    if (problems.isNotEmpty) {
      return (ready, '导出被拦下：\n${_groupProblems(problems)}');
    }
    return (ready, null);
  }

  /// 按原因归堆，行号并成区间
  static String _groupProblems(Map<int, String> problems) {
    final byReason = <String, List<int>>{};
    for (final e in problems.entries) {
      (byReason[e.value] ??= []).add(e.key + 1);
    }
    return [
      for (final e in byReason.entries)
        '${lineNumberRanges(e.value)}${e.key}',
    ].join('\n');
  }

  /// 一行的**素材原声**轨：逐镜截取、变速跟 atempo、按音量缩放，
  /// 素材没有音轨的那一镜垫静音。全行音量都是 0 时返回 null——
  /// 那就没必要多混一路进去。
  ///
  /// 配音行与画面行共用这一份：区别只在 [volumeOf] 给的基调不同
  /// （画面行本来就靠素材出声，配音行默认静音、开了才响）
  Future<String?> _lineSourceAudio({
    required ScriptLine line,
    required int lineIndex,
    required double Function(LineShot shot) volumeOf,
    required String? Function(int materialId) localPathOf,
  }) async {
    if (line.shots.every((s) => volumeOf(s) <= 0.001)) return null;
    final segParts = <String>[];
    for (var j = 0; j < line.shots.length; j++) {
      final shot = line.shots[j];
      final segOut = p.join(workDir.path, 'a_${lineIndex}_$j.wav');
      final srcPath = shot.localSource ?? localPathOf(shot.materialId)!;
      final tempo = shot.speed;
      final volume = volumeOf(shot);
      final filters = [
        if ((tempo - 1).abs() > 1e-6) 'atempo=$tempo',
        if ((volume - 1).abs() > 1e-6) 'volume=${volume.toStringAsFixed(3)}',
        'apad',
      ].join(',');
      final r = volume <= 0.001
          ? null
          : await run('ffmpeg', [
              '-y', '-v', 'error',
              '-ss', _sec(shot.trimStartMs),
              '-t', _sec((shot.allocMs! * tempo).round()),
              '-i', srcPath,
              '-vn',
              '-af', filters,
              '-t', _sec(shot.allocMs!),
              '-ar', '48000', '-ac', '2', '-c:a', 'pcm_s16le',
              segOut,
            ]);
      // 这一镜静音、或者素材根本没有音轨：垫一段静音，保住时间轴
      if (r == null ||
          r.exitCode != 0 ||
          !File(segOut).existsSync() ||
          File(segOut).lengthSync() == 0) {
        await _exec([
          '-y', '-v', 'error',
          '-f', 'lavfi', '-i', 'anullsrc=r=48000:cl=stereo',
          '-t', _sec(shot.allocMs!),
          '-c:a', 'pcm_s16le',
          segOut,
        ], what: '第 ${lineIndex + 1} 行第 ${j + 1} 镜静音垫');
      }
      segParts.add(segOut);
    }
    final out = p.join(workDir.path, 'asrc_$lineIndex.wav');
    final segList = File(p.join(workDir.path, 'asrc_$lineIndex.txt'))
      ..writeAsStringSync(ExportCommands.concatList(segParts));
    await _exec([
      '-y', '-v', 'error',
      '-f', 'concat', '-safe', '0', '-i', segList.path,
      '-c', 'copy', out,
    ], what: '第 ${lineIndex + 1} 行素材原声');
    return out;
  }

  /// 字幕屏 → 字幕句。**四处同一份派生**（预览层 / 镜头卡 / 卡上播放 /
  /// 成片），且都按这一行生效样式推出的每屏字数——成片与预览一字不差
  List<AsrSentence> _sentenceOf(ScriptLine line, SubtitleStyle style) {
    if (line.type != ScriptLineType.voiced || line.voiceover == null) {
      return const [];
    }
    return [
      for (final seg
          in line.subtitleScreensAt(maxChars: style.maxCharsPerScreen))
        AsrSentence(startMs: seg.startMs, endMs: seg.endMs, text: seg.text),
    ];
  }

  Future<List<SubtitleOverlayImage>> _overlaysFor({
    required List<AsrSentence> sentences,
    required int slotStartMs,
    required int slotEndMs,
    required ExportSpec spec,
    required SubtitleStyle style,
  }) async {
    if (sentences.isEmpty) return const [];
    final lines = subtitleLinesInSlot(
        sentences: sentences, slotStartMs: slotStartMs, slotEndMs: slotEndMs);
    return rasterizer.rasterize(
      lines: lines,
      width: spec.width,
      height: spec.height,
      style: style,
      outDir: Directory(p.join(workDir.path, 'subtitles')),
    );
  }

  /// 一个镜头的规格化切片：框选起点 + 变速 + 统一规格 + 字幕叠加 +
  /// 精确帧数（scale/pad 与 ExportCommands 同一套口径）
  List<String> _shotVideoArgs({
    required String input,
    required int trimStartMs,
    required int allocMs,
    required double speed,
    required ExportSpec spec,
    required List<SubtitleOverlayImage> overlays,
    required String out,
  }) {
    final scalePad = 'scale=${spec.width}:${spec.height}'
        ':force_original_aspect_ratio=decrease,'
        'pad=${spec.width}:${spec.height}:(ow-iw)/2:(oh-ih)/2:black,setsar=1';
    final speedFilter =
        (speed - 1).abs() < 1e-6 ? '' : ',setpts=PTS/$speed';
    final baseChain =
        '$scalePad$speedFilter,tpad=stop_mode=clone:stop_duration=${_sec(allocMs)}';
    return [
      '-y', '-v', 'error',
      '-ss', _sec(trimStartMs),
      '-t', _sec((allocMs * speed).round()),
      '-i', input,
      for (final o in overlays) ...['-i', o.pngPath],
      '-an',
      if (overlays.isEmpty) ...[
        '-vf', baseChain,
      ] else ...[
        '-filter_complex',
        subtitleFilterComplex(baseChain: baseChain, overlays: overlays),
        '-map', subtitleFilterOutLabel(overlays.length),
      ],
      '-r', '${spec.fps}',
      ...spec.encodeArgs,
      '-pix_fmt', 'yuv420p',
      '-frames:v', '${ExportCommands.frameCount(allocMs, atFps: spec.fps.toDouble())}',
      out,
    ];
  }

  Future<void> _exec(List<String> args, {required String what}) async {
    final result = await run('ffmpeg', args);
    if (result.exitCode != 0) {
      throw ScriptExportException('$what渲染失败（ffmpeg exit=${result.exitCode}）',
          cause: result.stderr);
    }
  }

  static String _sec(int ms) => (ms / 1000).toStringAsFixed(3);
}
