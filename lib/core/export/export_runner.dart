import 'dart:io';

import 'package:path/path.dart' as p;

import '../analysis/providers.dart' show AsrSentence;
import '../audio/bgm_plan.dart';
import '../audio/material_audio.dart';
import '../audio/source_audio.dart';
import '../audio/voice_plan.dart';
import '../ffmpeg/process_runner.dart';
import '../log/app_log.dart';
import '../models/semantic_unit.dart';
import '../replacement/replacement_plan.dart';
import '../audio/audio_track_builder.dart';
import 'composed_timeline.dart';
import 'shot_audio_plan.dart';
import '../subtitle/slot_subtitles.dart';
import '../subtitle/subtitle_overlay.dart';
import '../subtitle/subtitle_track.dart';
import '../subtitle/subtitle_rasterizer.dart';
import '../subtitle/subtitle_style.dart';
import 'export_commands.dart';
import 'export_file_name.dart';
import 'export_plan.dart';
import 'export_spec.dart';
import 'unique_export_path.dart';

/// 一条成片的导出结果
class ExportOutcome {
  final int index;

  /// 成功时是成片路径；失败时为 null
  final String? path;

  /// 失败原因（已是中文）；成功时为 null
  final String? failure;

  /// 导成了、但有话要说（已是中文，可直接展示）。
  ///
  /// 目前只有一件事：某一段声音叠出来过载了。它不是失败——片子导得出来，
  /// 只是那一段听着会发破，调不调是人的判断（用户定的：不偷偷压音量躲过去，
  /// 如实报出来是哪一段）
  final List<String> notes;

  const ExportOutcome({
    required this.index,
    this.path,
    this.failure,
    this.notes = const [],
  });

  bool get ok => path != null;
}

/// 导出进度：正在做第几条、总共几条、这一刻在做什么
typedef ExportProgress = void Function(int done, int total, String what);

/// 矩阵导出：把替换方案摊成若干条成片，逐条用 ffmpeg 合成。
///
/// **画面来自候选素材或原片，声音一律来自原片（或换音色后的配音）**：产品要的
/// 是「结构相同但画面全新」，所以候选素材自带的旁白要丢掉，只取它的画面。
///
/// 三处刻意的复用，不然十条成片要跑上一个钟头：
/// - **声音只做一遍**：所有组合的声音完全相同（画面才是变量）；
/// - **原片段只切一遍**：同一个单元的原片画面会在多条组合里重复出现；
/// - **素材只下载一遍**：同一条候选也会在多条组合里重复出现。
class ExportRunner {
  final ProcessRunner run;

  /// 中间产物目录（切片、下载的素材、清单文件）
  final Directory workDir;

  /// 下载一条候选素材到本地，返回落地路径。注入而不是内建 http：
  /// 这一层要能在不联网的情况下测。
  final Future<String> Function(int candidateId) fetchMaterial;

  /// 把一条配乐解析成本地可读的地址（见 [AudioTrackBuilder.resolveBgm]）。
  /// 不注入时退回素材自带的签名地址——它随时可能已经失效。
  final Future<String> Function(BgmMaterial material)? resolveBgm;

  /// 把一条替换素材分离成纯人声。整体替换的段落铺了配乐时要用它——
  /// 素材自带的背景音留着的话，它和新配乐会两首曲子一起响
  final Future<String?> Function(String materialPath)? separateMaterial;

  /// 出多大、多清楚的缺省值。按次导出可以用 exportAll/exportCombinations
  /// 的 [spec] 参数盖掉——同一个 runner 可能先导一版 1080 再导一版 720
  final ExportSpec defaultSpec;

  /// 读一条本地素材有多长（毫秒）。镜头替换要按它算变速倍率；读不出来
  /// 返回 null，那时退回裁/冻帧而不是瞎猜倍率。
  final Future<int?> Function(String path)? probeDurationMs;

  final SubtitleStyle subtitleStyle;

  /// 字幕图渲染器（系统渲字）。测试注入假实现
  final SubtitleRasterizer rasterizer;

  ExportRunner({
    required this.run,
    required this.workDir,
    required this.fetchMaterial,
    this.resolveBgm,
    this.separateMaterial,
    this.probeDurationMs,
    this.subtitleStyle = SubtitleStyle.standard,
    SubtitleRasterizer? rasterizer,
    this.defaultSpec = ExportSpec.standard,
  }) : rasterizer = rasterizer ?? SubtitleRasterizer();

  /// 出片前的拦截：有任何一条会让成片**静默出错**就返回原因，否则 null。
  ///
  /// 这几条的共同点是「导出来的片子看着正常，其实不是用户要的」——
  /// 用户发现不了，所以宁可不导。
  static String? _deliveryBlocker({
    required BgmPlan bgm,
    required String? vocalsPath,
    required VoicePlan voices,
    required Map<String, String> voiceAudio,
    // 单元列表：配音按**身份**记，而说给人听的话得说「U3」——那是位置，
    // 只有对着列表才知道
    required List<SemanticUnit> units,
    String? sourcePath,
    List<UnitReplacement> replacements = const [],
    SourceAudioSetting sourceAudio = SourceAudioSetting.auto,
    String? backgroundPath,
  }) {
    // 整体替换用的是候选素材自己的口播，换音色用的是 TTS 合成的口播——
    // 同一个单元两者矛盾，静默取其一正是用户反对的
    final conflict = [
      for (var i = 0; i < units.length; i++)
        // **固定过底片的单元不算冲突**：它的声音是按镜头从底片上剪的，
        // 不是「整段用素材自己的口播」。换音色后画面来自素材、口播来自
        // 合成——这是个有用的组合（插入段用别人的画面、自己的配音），
        // 拦下来等于把它禁掉
        if (voices.assignedUnits.contains(units[i].uid) &&
            units[i].baseCandidateId == null &&
            i < replacements.length &&
            replacements[i].mode == ReplacementMode.whole &&
            replacements[i].wholeCandidateIds.isNotEmpty)
          'U${i + 1}',
    ];
    if (conflict.isNotEmpty) {
      return '${conflict.join('、')} 既做了整体替换又选了音色。'
          '整体替换会用候选素材自己的口播，换音色会用合成的口播，'
          '同一段只能要一个——请取消其中一项';
    }

    // 有配乐却没有分离出来的人声轨：新配乐只能叠在原混音上，原片自带的
    // 背景音还在，成片里两首曲子一起响。
    // **空白任务豁免**：它没有原片，声音全部来自素材、由 separateMaterial
    // 逐条分离——按「必须有原片人声轨」拦它等于配了乐就永远导不出
    // （预览侧一直是豁免的，两边规则要一致）
    if (sourcePath != null &&
        bgm.segments.isNotEmpty &&
        (vocalsPath == null || !File(vocalsPath).existsSync())) {
      return '这条片子有配乐，但没有分离出来的纯人声轨——直接导出会让新配乐'
          '叠在原片背景音上（两首曲子一起响）。请先装好分离工具并重新分析';
    }

    // 「原片这一镜的声音」选了人声/背景声，却没有对应的分离轨：
    // 走到导出中途才抛，人已经等了几分钟。该拦的在进门口拦
    final needsStem = _shotsNeedingStem(
      units: units,
      replacements: replacements,
      sourceAudio: sourceAudio,
      vocalsPath: vocalsPath,
      backgroundPath: backgroundPath,
    );
    if (needsStem.isNotEmpty) {
      return '${needsStem.join('、')} 的原片声音选了要分离的那一档，'
          '但这条任务还没有对应的分离轨。在工作台上点「重新分离」，'
          '或者跑 ishkafel analyze <任务> 重跑一遍分析；'
          '也可以把它们改回「原声」';
    }

    // 选了音色却没生成配音：那一段会静默用回原声
    final missing = <String>[];
    for (var i = 0; i < units.length; i++) {
      if (!voices.assignedUnits.contains(units[i].uid)) continue;
      final path = voiceAudio[units[i].uid];
      if (path == null || !File(path).existsSync()) {
        missing.add('U${i + 1}');
      }
    }
    if (missing.isNotEmpty) {
      // **两边都要能照做**：这句话界面和命令行共用一份，只说「点按钮」
      // 的话，命令行那头没有按钮可点（Agent 真机撞到过这类死路）
      return '${missing.join('、')} 选了音色但还没生成配音，'
          '直接导出这几段会是原声。'
          '在工作台上点「生成配音」，或者跑 ishkafel voice generate <任务>';
    }
    return null;
  }

  /// 哪几镜的「原片这一镜的声音」选了要分离的档位、而分离轨还不在。
  /// 返回 `U2·S3` 这种人话标签
  static List<String> _shotsNeedingStem({
    required List<SemanticUnit> units,
    required List<UnitReplacement> replacements,
    required SourceAudioSetting sourceAudio,
    required String? vocalsPath,
    required String? backgroundPath,
  }) {
    bool has(String? path) => path != null && File(path).existsSync();
    final out = <String>[];
    for (var u = 0; u < units.length; u++) {
      final replacement = u < replacements.length ? replacements[u] : null;
      if (replacement?.mode != ReplacementMode.perShot) continue;
      // **底片是素材的那几镜不看原片分离轨**：它们要分的是那条素材，
      // 由 [AudioTrackBuilder] 按需分、分不出来自己点名。拿原片的分离轨
      // 判这里，原片有就放行、没有就叫人「去重新分离原片」——两种都不对
      if (units[u].baseCandidateId != null) continue;
      for (var sh = 0; sh < units[u].shots.length; sh++) {
        final picked = resolveSourceAudio(
          replaced: replacement!.shotCandidateIds[sh]?.isNotEmpty ?? false,
          taskDefault: sourceAudio,
          shotMode: units[u].shots[sh].sourceAudioMode,
          shotVolume: units[u].shots[sh].sourceAudioVolume,
        );
        final mode = picked?.mode;
        if (mode == null || !mode.needsSeparation) continue;
        final ready = mode == MaterialAudioMode.vocals
            ? has(vocalsPath)
            : has(backgroundPath);
        if (!ready) out.add('U${u + 1}·S${sh + 1}');
      }
    }
    return out;
  }

  /// 这一条成片里哪几镜换过素材。「原片这一镜的声音」只对它们生效
  static Set<(int, int)> _replacedShotsOf(ExportCombination combo) => {
        for (final segment in combo.segments)
          if (segment.shotIndex != null && segment.candidateId != null)
            (segment.unitIndex, segment.shotIndex!),
      };

  /// 导出全部组合到 [outputDir]。
  ///
  /// 一条失败不拖累其余：失败的那条记下原因继续跑下一条——十条里坏一条，
  /// 重跑那一条就行，没道理整批作废。
  Future<List<ExportOutcome>> exportAll({
    required String? sourcePath,
    required List<SemanticUnit> units,
    required List<UnitReplacement> replacements,
    required Directory outputDir,
    BgmPlan bgm = BgmPlan.empty,
    Map<String, String> voiceAudio = const {},

    /// 换音色方案。用来核对「选了音色的单元是不是都生成了配音」——
    /// 少了会静默导出原声
    VoicePlan voices = VoicePlan.empty,

    /// 分离出来的纯人声轨；被配乐覆盖的段落要用它，否则新旧背景一起响
    String? vocalsPath,
    int limit = ReplacementPlan.maxCombinations,
    ExportSpec? spec,
    List<AsrSentence> subtitleSentences = const [],

    /// 「保留素材原声」的全片打底设置。单个视觉镜头可以覆盖它
    /// （见 [Shot.keepMaterialAudio]）。默认关：存量任务导出来的声音不变
    MaterialAudioSetting materialAudio = MaterialAudioSetting.off,

    /// 「原片这一镜的声音」的全片打底。默认「自动」= 老行为
    SourceAudioSetting sourceAudio = SourceAudioSetting.auto,

    /// 分离出来的纯背景音轨（与 [vocalsPath] 同一次分离的两条产物）。
    /// 「原片这一镜的声音」选「背景声」时用它
    String? backgroundPath,

    /// **手改过的**字幕。没改过的坑位照 ASR 现算（见 [SubtitleTrack]）
    SubtitleTrack subtitleTrack = const SubtitleTrack.empty(),
    ExportProgress? onProgress,
  }) async {
    final combos = ExportPlanner.enumerate(
      units: units,
      replacements: replacements,
      limit: limit,
    );
    return exportCombinations(
      combos: combos,
      sourcePath: sourcePath,
      units: units,
      replacements: replacements,
      outputDir: outputDir,
      bgm: bgm,
      voiceAudio: voiceAudio,
      voices: voices,
      vocalsPath: vocalsPath,
      spec: spec,
      subtitleSentences: subtitleSentences,
      materialAudio: materialAudio,
      sourceAudio: sourceAudio,
      backgroundPath: backgroundPath,
      subtitleTrack: subtitleTrack,
      onProgress: onProgress,
    );
  }

  /// 导出**已经定好的那几条组合**，不再做笛卡尔积。
  ///
  /// [exportAll] 是「人挑候选 → 笛卡尔积」那条路；这条是给 Agent 用的——
  /// 它提交的是一份完整方案列表，每条都是整体设计过的（见 spec 第四节：
  /// 笛卡尔积隐含「任意搭配都成立」，与「挑的时候要看前后是否顺畅」冲突）。
  ///
  /// [replacements] 仍要传：交付前的检查（换过音色的单元有没有生成配音、
  /// 被配乐盖住的段落有没有纯人声）是按它判的。
  Future<List<ExportOutcome>> exportCombinations({
    required List<ExportCombination> combos,
    required String? sourcePath,
    required List<SemanticUnit> units,
    required List<UnitReplacement> replacements,
    required Directory outputDir,
    BgmPlan bgm = BgmPlan.empty,
    Map<String, String> voiceAudio = const {},
    VoicePlan voices = VoicePlan.empty,
    String? vocalsPath,
    ExportSpec? spec,

    /// 句级转写（任务的 asrSentences）。镜头替换换掉画面后，原片烧在像素
    /// 里的台词字幕跟着没了——用它在替换切片上重渲同一句台词；空表示没有
    /// 转写（老任务/空白任务），切片照渲、不带字幕
    List<AsrSentence> subtitleSentences = const [],

    /// 「保留素材原声」的全片打底设置。单个视觉镜头可以覆盖它
    /// （见 [Shot.keepMaterialAudio]）。默认关：存量任务导出来的声音不变
    MaterialAudioSetting materialAudio = MaterialAudioSetting.off,

    /// 「原片这一镜的声音」的全片打底。默认「自动」= 老行为
    SourceAudioSetting sourceAudio = SourceAudioSetting.auto,

    /// 分离出来的纯背景音轨（与 [vocalsPath] 同一次分离的两条产物）。
    /// 「原片这一镜的声音」选「背景声」时用它
    String? backgroundPath,

    /// **手改过的**字幕。没改过的坑位照 ASR 现算（见 [SubtitleTrack]）
    SubtitleTrack subtitleTrack = const SubtitleTrack.empty(),
    ExportProgress? onProgress,
  }) async {
    if (combos.isEmpty) return const [];

    workDir.createSync(recursive: true);
    outputDir.createSync(recursive: true);
    final total = combos.length;

    // 同一个候选会在预取和渲染两处用到，也会在多条组合里重复出现——
    // 记的是 **Future**：并行渲染时两个段同时要同一条素材，也只下载一次
    final renderSpec = spec ?? defaultSpec;
    final fetched = <int, Future<String>>{};
    Future<String> material(int id) => fetched[id] ??= fetchMaterial(id);
    // 同一条素材的时长探测同理：一次 ffprobe，处处复用
    final probed = <String, Future<int?>>{};
    Future<int?> probeOnce(String path) => probed[path] ??= _probeQuietly(path);

    // 出片前先把「会静默做错」的几件事拦掉。
    //
    // **预览可以降级，成片不行**：预览时人还在编辑、听得出来；成片少一段
    // 垫乐、少一句换过的配音、或者新旧背景叠在一起，交付出去没人会发现。
    // 宁可这一次导不出来，也不能给一条看起来正常、其实是错的片子。
    // 变速倍率**不设上限**：预览渲染的就是真实倍率的切片，用户在预览里
    // 看到 2.9× 什么样、导出来就是什么样——他看过并接受了，就不该拦。
    // 原来这里有一道 0.8×~2.0× 的闸，是在替用户做审美判断，已拆掉
    final blocker =
        _blankBlocker(combos, sourcePath) ??
        _deliveryBlocker(
          bgm: bgm,
          vocalsPath: vocalsPath,
          voices: voices,
          voiceAudio: voiceAudio,
          units: units,
          sourcePath: sourcePath,
          replacements: replacements,
          sourceAudio: sourceAudio,
          backgroundPath: backgroundPath,
        );
    if (blocker != null) {
      AppLog.warn('导出前置检查未通过：$blocker');
      return [
        for (final c in combos) ExportOutcome(index: c.index, failure: blocker),
      ];
    }

    onProgress?.call(0, total, '准备声音');
    // 整体替换的那些单元：把候选下到本地并读出真实时长。
    // 声音要取自它、后面所有单元的位置也要按它的新长度重算
    final Map<int, Map<int, ({String path, int ms})>> wholeByCombo = {};
    try {
      for (var i = 0; i < combos.length; i++) {
        final per = <int, ({String path, int ms})>{};
        for (final segment in combos[i].segments) {
          final id = segment.candidateId;
          // shotIndex == null 才是整体替换（镜头替换有 shotIndex）
          if (id == null || segment.shotIndex != null) continue;
          final path = await material(id);
          final ms = await _probeQuietly(path) ?? segment.durationMs;
          per[segment.unitIndex] = (path: path, ms: ms);
        }
        wholeByCombo[i] = per;
      }
    } catch (e) {
      AppLog.warn('导出：整体替换的素材准备失败：$e');
      return [
        for (final c in combos)
          ExportOutcome(index: c.index, failure: '整体替换的素材取不到：$e'),
      ];
    }

    // 底片固定过的单元：先把那几张底片下到本地。声音和画面取的必须是同
    // 一个文件，不然人听到的和看到的对不上
    final baseAudioPaths = <int, String>{};
    try {
      for (final unit in units) {
        if (unit.baseCandidateId case final id?) {
          baseAudioPaths[unit.index] = await material(id);
        }
      }
    } catch (e) {
      AppLog.warn('导出：底片素材准备失败：$e');
      return [
        for (final c in combos)
          ExportOutcome(index: c.index, failure: '底片素材取不到：$e'),
      ];
    }

    /// 合声音时量出来的话（目前只有过载）。**不是失败**，跟着成片一起报出去
    final audioNotes = <String>[];
    /// 共用那条声音的话——它对每一条成片都成立
    final sharedNotes = <String>[];

    // 配乐每段只有一首时所有变体的声音一模一样，合一次就够；有备选（轮流用）
    // 或整体替换（各条变体的候选不同、时长也不同）就得逐条合
    final perVariant =
        bgm.segments.any((s) => s.materials.length > 1) ||
        wholeByCombo.values.any((m) => m.isNotEmpty);

    /// 合第 [i] 条变体的声音。配乐没铺上就抛——成片少一段垫乐是静默的错。
    /// 抛出来的原因统一带「声音合成失败」前缀：调用方在两处接它（共用那条
    /// 在循环外、逐条那条在循环里），错误文案不该因为走了哪条路而不同
    Future<String> buildAudio(int i) async {
      final AudioTrack track;
      try {
        track =
            await AudioTrackBuilder(
              run: run,
              // 逐条合时各用各的目录，否则中间产物互相覆盖
              workDir: perVariant
                  ? Directory(p.join(workDir.path, 'audio_v$i'))
                  : workDir,
              resolveBgm: resolveBgm,
              separateMaterial: separateMaterial,
              exportFps: renderSpec.fps.toDouble(),
            ).build(
              sourcePath: sourcePath,
              units: units,
              vocalsPath: vocalsPath,
              backgroundPath: backgroundPath,
              // 「原片这一镜的声音」只对换过素材的那几镜生效
              replacedShots: _replacedShotsOf(combos[i]),
              sourceAudio: sourceAudio,
              bgm: bgm,
              voiceAudio: voiceAudio,
              variantIndex: i,
              wholeAudio: {
                for (final e in (wholeByCombo[i] ?? const {}).entries)
                  e.key: e.value.path,
              },
              // 底片固定过的单元：声音同样从底片上剪，不是从原片
              baseAudio: baseAudioPaths,
              wholeDurations: {
                for (final e in (wholeByCombo[i] ?? const {}).entries)
                  e.key: e.value.ms,
              },
              // 视觉镜头替换里开了「保留素材原声」的那几镜。参数全部沿用
              // 画面那一段的（同一条素材、同一个截取起点、同一个倍率），
              // 差一点声音和画面就越走越偏
              shotAudio: await planShotMaterialAudio(
                units: units,
                segments: combos[i].segments,
                taskDefault: materialAudio,
                timeline: ComposedTimeline.of(
                  units: units,
                  wholeDurations: {
                    for (final e in (wholeByCombo[i] ?? const {}).entries)
                      e.key: e.value.ms,
                  },
                ),
                resolveMaterial: material,
                probe: probeOnce,
              ),
            );
      } catch (e) {
        throw Exception('声音合成失败：$e');
      }
      if (track.bgmWarnings.isNotEmpty) {
        throw Exception('声音合成失败：配乐没能铺上——${track.bgmWarnings.join('；')}');
      }
      // 过载不中止导出，但要带到人眼前——量了不报等于没量
      for (final note in track.overloads) {
        AppLog.warn('导出：$note');
      }
      audioNotes.addAll(track.overloads);
      return track.path;
    }

    // 共用那条要在这里就合出来：它挂了**每一条**都成不了。
    // 逐条合的放到下面各自的 try 里——一条的声音挂了不该拖累其余。
    String? sharedAudio;
    if (!perVariant) {
      try {
        onProgress?.call(0, total, '合成声音（含人声分离，可能要几分钟）');
        sharedAudio = await buildAudio(0);
        // 共用的那条声音，它的话对每一条都成立
        sharedNotes.addAll(audioNotes);
      } catch (e) {
        AppLog.warn('导出：$e');
        // 共用的那条声音挂了，每一条都成不了——如实给同一个原因
        return [
          for (final c in combos) ExportOutcome(index: c.index, failure: '$e'),
        ];
      }
    }

    final clips = <String, Future<String>>{}; // 段落指纹 → 渲染中/已渲染的切片
    final out = <ExportOutcome>[];
    for (final combo in combos) {
      // 逐条合声音（有整体替换/多首配乐）时，第一步是人声分离——CPU 上
      // 一条素材要一两分钟。不说清的话进度会挂着不动五六分钟像卡死
      onProgress?.call(
          out.length,
          total,
          perVariant && sharedAudio == null
              ? '第 ${combo.index} 条：合成声音（含人声分离，可能要几分钟）'
              : '第 ${combo.index} 条');
      // 逐条合声音时各条各的话，别把上一条的算到这一条头上。
      // 共用那条是在循环外合的，它的话已经存进 sharedNotes，不能在这儿清掉
      if (sharedAudio == null) audioNotes.clear();
      try {
        final path = await _composeOne(
          combo: combo,
          subtitleTrack: subtitleTrack,
          sourcePath: sourcePath,
          material: material,
          probe: probeOnce,
          audio: sharedAudio ?? await buildAudio(out.length),
          outputDir: outputDir,
          clips: clips,
          renderSpec: renderSpec,
          subtitleSentences: subtitleSentences,
          // 底片固定过的单元字幕从它自己的转写里取——原片那份量的是原片
          baseSentencesOf: (u) =>
              u >= 0 && u < units.length ? units[u].baseSentences : null,
        );
        out.add(ExportOutcome(
          index: combo.index,
          path: path,
          notes: List.unmodifiable(
              sharedAudio == null ? audioNotes : sharedNotes),
        ));
      } catch (e) {
        // 一条成片没出来是**硬失败**，不是「注意一下」——用 error 级别，
        // 别让人在一屏 warn 里把它滑过去
        AppLog.error('导出：第 ${combo.index} 条失败：$e');
        out.add(ExportOutcome(index: combo.index, failure: '$e'));
      }
    }
    final failed = out.where((o) => o.failure != null).length;
    // 收尾话按结果说：三条全灭还打「完成」，只看进度行的人（和只 tail
    // 日志的脚本）会以为导完了
    onProgress?.call(
        total,
        total,
        failed == 0
            ? '完成'
            : failed == total
                ? '全部失败，一条都没出来'
                : '完成 ${total - failed} 条，失败 $failed 条');
    // 工作目录**留着**：切片和音轨都按内容指纹命名——改一个候选重导，
    // 没变的段落直接命中磁盘、一次 ffmpeg 都不跑（「算过一次的东西要落地
    // 复用，改动了才重算」）。它按任务归属在产物清单里：删任务时一并清、
    // 设置页可统计可清理，不会变成孤儿
    return List.unmodifiable(out);
  }

  /// 拼一条成片：逐段渲染画面 → concat → 与共用的声音合成
  Future<String> _composeOne({
    required ExportCombination combo,
    required String? sourcePath,
    required String audio,
    required Directory outputDir,
    required Map<String, Future<String>> clips,
    required Future<String> Function(int id) material,
    required Future<int?> Function(String path) probe,
    required ExportSpec renderSpec,
    required List<AsrSentence> subtitleSentences,
    required SubtitleTrack subtitleTrack,
    /// 底片固定过的单元自己的转写（字幕从它取，不是原片那份）
    List<AsrSentence>? Function(int unitIndex)? baseSentencesOf,
  }) async {
    // 段落渲染并行（窗口 3）：一条成片几十段逐段串行是导出慢的主因之一。
    // 窗口不开大——每个 ffmpeg 自己就吃多核，开太多只会互相抢
    final parts = List<String?>.filled(combo.segments.length, null);
    for (var i = 0; i < combo.segments.length; i += 3) {
      final batch = [
        for (var j = i; j < combo.segments.length && j < i + 3; j++)
          _renderSegment(
            combo.segments[j],
            sourcePath,
            clips,
            material,
            probe,
            renderSpec,
            subtitleSentences,
            subtitleTrack,
            baseSentencesOf,
          ).then((path) => parts[j] = path),
      ];
      await Future.wait(batch);
    }

    final listFile = File(p.join(workDir.path, 'concat_${combo.index}.txt'))
      ..writeAsStringSync(ExportCommands.concatList(parts.cast<String>()));
    final silent = p.join(workDir.path, 'video_${combo.index}.mp4');
    await _ffmpeg(
      ExportCommands.concat(listFile: listFile.path, out: silent),
      '拼接画面',
    );

    // 扩展名跟着格式走。选了 mov 却导出 .mp4，双击能开但拖进剪辑软件
    // 会被当成另一种东西。
    // 名字撞上就往后排：同一个目录导第二批时文件名一模一样，ffmpeg 的 `-y`
    // 会把上一批悄悄盖掉（见 [uniqueExportPath]）
    final out = uniqueExportPath(
      outputDir.path,
      exportFileName(
        name: combo.name,
        index: combo.index,
        extension: renderSpec.fileExtension,
      ),
    );
    await _ffmpeg(
      ExportCommands.mux(video: silent, audio: audio, out: out),
      '画面与声音合成',
    );
    return out;
  }

  /// 空白任务里还没挑素材的分子。
  ///
  /// 没有原片垫底，这种段落**没有任何东西可以放**。不能拿黑场顶上，也不能
  /// 悄悄跳过——那都属于「影响最终成片的东西出了错却不说」。一次把所有空着
  /// 的点名，免得用户填一个导一次。
  static String? _blankBlocker(
    List<ExportCombination> combos,
    String? sourcePath,
  ) {
    if (sourcePath != null) return null;
    final empty = <int>{};
    for (final combo in combos) {
      for (final segment in combo.segments) {
        // **底片那几镜不算空**：它们没挑替换素材，但画面取自这个单元的
        // 底片（`baseCandidateId`），不是「没东西可放」。不认这一条的话，
        // 拼片任务里切过底片的段落一律导不出去，报的还是「还没挑素材」
        // ——而人明明挑了、还切了、还打了标（2026-09-15 真机撞到）
        if (segment.isOriginal && segment.baseCandidateId == null) {
          empty.add(segment.unitIndex);
        }
      }
    }
    if (empty.isEmpty) return null;
    final names = (empty.toList()..sort()).map((i) => 'U${i + 1}').join('、');
    return '$names 还没有挑素材。删掉这些分子，或者把它们挑满，再导出';
  }

  /// 渲染一段画面。同一段在多条组合里会重复出现，按指纹缓存，只做一遍。
  Future<String> _renderSegment(
    ExportSegment segment,
    String? sourcePath,
    Map<String, Future<String>> clips,
    Future<String> Function(int id) material,
    Future<int?> Function(String path) probe,
    ExportSpec renderSpec,
    List<AsrSentence> subtitleSentences,
    SubtitleTrack subtitleTrack,
    /// 底片固定过的单元自己的转写（单元下标 → 素材内时间戳的句子）
    List<AsrSentence>? Function(int unitIndex)? baseSentencesOf,
  ) async {
    // 规格进指纹：同一段在 1080 和 720 下是两份不同的产物，
    // 不区分的话第二次导出会直接命中第一次的缓存，用户拿到的还是旧规格。
    // 镜头替换的字幕（内容 + 样式）同理——字幕在指纹里，改了就重渲
    // 手改过的字幕以人改的为准；没改过的照 ASR 现算。
    //
    // **整体替换不渲字幕**（shotIndex == null）：时长跟候选走、和原坑位对不齐，
    // 按原片时间戳算的字幕贴上去必然错位——这条没变
    final subtitleLines = segment.shotIndex == null
        ? const <SubtitleLine>[]
        : subtitleLinesForSlot(
            track: subtitleTrack,
            sentences: subtitleSentences,
            unitUid: segment.unitUid,
            shotIndex: segment.shotIndex!,
            slotStartMs: segment.startMs,
            slotEndMs: segment.endMs,
            // 底片是素材的那几镜：原片那份 ASR 量的是原片，跟这段画面毫不
            // 相干；字幕从**底片自己的转写**里取，坑位也换成素材内偏移
            onMaterialBase: segment.unitBaseCandidateId != null,
            baseSentences: baseSentencesOf?.call(segment.unitIndex),
            baseSlotStartMs: segment.baseStartMs,
            baseSlotEndMs: segment.baseStartMs + segment.sourceDurationMs,
          );
    final subFingerprint = subtitleFingerprint(subtitleLines);
    final subKey = subFingerprint.isEmpty
        ? ''
        : '_sub$subFingerprint'
            '_${subtitleStyle.fingerprint.hashCode}';
    final key =
        '${segment.startMs}_${segment.endMs}_${segment.candidateId}'
        // 底片进指纹：换了底片重导，不带这一项会命中上一张底片留下的切片
        '${segment.baseCandidateId == null ? '' : '_b${segment.baseCandidateId}'
            '@${segment.baseStartMs}'}'
        // 取段起点进指纹：改了截哪一段却复用上一份切片，
        // 人看到的是「调了没反应」，而盘上那份是旧画面
        '_t${segment.trimStartMs ?? 0}'
        '_${renderSpec.fingerprint}$subKey';
    // Future 记忆化：并行渲染时同一段只渲一次，后来的等同一个结果
    return clips[key] ??= () async {
      final out = p.join(workDir.path, 'clip_$key.mp4');
      // 增量重导：上次导出留下的切片按指纹直接复用——改一个候选重导，
      // 没变的段落一次 ffmpeg 都不跑
      if (File(out).existsSync() && File(out).lengthSync() > 0) return out;
      if (segment.isOriginal) {
        // 这一段没换素材——从**这个单元的底片**上剪。底片多半是任务原片；
        // 固定过底片的单元（见 [hasOwnBaseShots]）剪的是那条素材
        final fromMaterial = segment.baseCandidateId;
        final baseVideo =
            fromMaterial == null ? sourcePath : await material(fromMaterial);
        // 空白任务没有原片。走到这儿说明有一段没挑素材而前置检查漏了——
        // 让它掉进 ffmpeg 只会得到一句「No such file」，指不出是哪一段
        if (baseVideo == null) {
          throw StateError(
            'U${segment.unitIndex + 1} 这一段要用原片，但这条任务没有原片。'
            '请给它挑一条素材，或者删掉这个分子',
          );
        }
        await _ffmpeg(
          ExportCommands.trimOriginalVideo(
            source: baseVideo,
            startMs: segment.baseStartMs,
            endMs: segment.baseStartMs + segment.sourceDurationMs,
            out: out,
            spec: renderSpec,
          ),
          'U${segment.unitIndex + 1} 的${fromMaterial == null ? '原片' : '底片'}画面',
        );
      } else {
        final path = await material(segment.candidateId!);
        if (segment.shotIndex == null) {
          // **整体替换：原样接上**，不加速不放慢不裁不补，时长随候选
          await _ffmpeg(
            ExportCommands.wholeReplacementVideo(
              spec: renderSpec,
              input: path,
              out: out,
            ),
            'U${segment.unitIndex + 1} 的替换画面',
          );
        } else {
          // 镜头替换：变速对齐到原坑位（口播不动，画面必须严丝合缝），
          // 并把这段台词的字幕重渲上去——原片的字幕烧在被换掉的画面里
          final overlays = subtitleLines.isEmpty
              ? const <SubtitleOverlayImage>[]
              : await rasterizer.rasterize(
                  lines: subtitleLines,
                  // 与切片同一个输出分辨率——跟导出规格，不吃成片标准死值
                  width: renderSpec.width,
                  height: renderSpec.height,
                  style: subtitleStyle,
                  outDir: workDir,
                );
          await _ffmpeg(
            ExportCommands.fitCandidateVideo(
              input: path,
              durationMs: segment.durationMs,
              candidateDurationMs: await probe(path),
              trimStartMs: segment.trimStartMs,
              out: out,
              subtitleOverlays: overlays,
              // 规格必须贯穿：这段与原片段进同一条 concat 清单
              spec: renderSpec,
            ),
            'U${segment.unitIndex + 1} 的替换画面',
          );
        }
      }
      return out;
    }();
  }

  Future<int?> _probeQuietly(String path) async {
    final probe = probeDurationMs;
    if (probe == null) return null;
    try {
      final ms = await probe(path);
      return ms != null && ms > 0 ? ms : null;
    } catch (e) {
      AppLog.warn('读不出 $path 的时长，这一段退回裁/冻帧：$e');
      return null;
    }
  }

  Future<void> _ffmpeg(List<String> args, String what) async {
    final result = await run('ffmpeg', args);
    if (result.exitCode != 0) {
      // ffmpeg 的 stderr 动辄几百行，只留最后几行——真正的原因总在末尾
      final stderr = '${result.stderr}'.trim().split('\n');
      final tail = stderr.length > 3
          ? stderr.sublist(stderr.length - 3)
          : stderr;
      throw Exception('$what 失败：${tail.join(' / ')}');
    }
  }
}
