import 'dart:convert';
import 'dart:io';
import '../../core/storage/ui_action.dart';
import '../../core/storage/agent_request.dart';
import '../../core/models/renew_task.dart';

import '../export_warnings.dart';

import 'package:path/path.dart' as p;

import '../../core/audio/bgm_cache_factory.dart';
import '../../core/audio/material_vocal_cache.dart';
import '../../core/audio/vocal_separator.dart';
import '../../core/export/export_runner.dart';
import '../../core/export/export_spec.dart';
import '../../core/ffmpeg/ffprobe_service.dart';
import '../../core/ffmpeg/process_runner.dart';
import '../../core/miaoa/material_downloader.dart';
import '../../core/miaoa/miaoa_content_service.dart';
import '../../core/models/export_record.dart';
import '../../core/platform/platform_paths.dart';
import '../../core/storage/file_task_repository.dart';
import '../../core/storage/agent_presence.dart';
import '../../core/storage/task_lock.dart';
import '../../core/storage/task_media.dart';
import '../../core/storage/task_seq.dart';
import '../agent_stage.dart';
import '../agent_lock_holder.dart';
import '../cli_output.dart';
import '../plan_submission.dart';
import 'apply_command.dart';

/// `ishkafel export <task> [--out <目录>]`
///
/// 按 `apply plans` 提交的方案**逐条导出**，不做笛卡尔积。
///
/// **先说代价、但不设闸门**：会导几条、大概多久，如实输出；要不要继续是
/// 调用方的判断——我是工具，你来调用我（spec 第一节）。
Directory defaultExportDirectory(String taskId, {PlatformPaths? paths}) =>
    Directory(p.join(
      (paths ?? PlatformPaths()).videosDirectory,
      'ishkafel-$taskId',
    ));

Future<int> runExportCommand({
  required List<String> rest,
  required Directory dataDir,
  String? outputDir,
  String? resolution,
  String? fps,
  String? bitrate,
  String? codec,
  String? format,
  String? holder,

  /// 可视模式：把 app 拉起来落到这个任务，导出进度实时显示在横幅上
  bool? visual,
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  if (rest.isEmpty) {
    sink.writeln('用法：ishkafel export <任务 id> [--out <目录>] '
        '[--resolution 480|720|1080|1440|2160] [--fps 24|25|30|50|60] '
        '[--bitrate recommended|higher|lower|<kbps>] '
        '[--codec h264|hevc] [--format mp4|mov]');
    return exitBadUsage;
  }

  // 规格参数逐个校验，认不出就报错——静默用默认值会让调用方以为生效了
  final spec = _parseSpec(
    resolution: resolution,
    fps: fps,
    bitrate: bitrate,
    codec: codec,
    format: format,
    sink: sink,
  );
  if (spec == null) return exitBadUsage;
  final id = rest.first;

  final repository = FileTaskRepository(dataDir);
  final task = await resolveTaskRef(repository, id);
  if (task == null) {
    sink.writeln('没有这个任务：$id');
    return exitNotFound;
  }
  final units = task.units;
  if (units == null) {
    sink.writeln('这个任务还没分析完，没法导出');
    return exitNotFound;
  }

  final raw = readSubmittedPlans(dataDir, id);
  if (raw == null) {
    sink.writeln('还没有提交方案。先跑 ishkafel apply plans $id --file <方案.json>');
    return exitNotFound;
  }
  final validation = parsePlans(jsonDecode(raw), task);
  if (!validation.ok) {
    // 提交时校验过一次，这里再过一遍——中间任务可能被改过（比如切分变了）
    sink.writeln('已提交的方案对不上现在的任务了：');
    for (final problem in validation.errors) {
      sink.writeln('· $problem');
    }
    return exitBadUsage;
  }

  // 对照审核后的现状：人在审核里剔掉的素材绝不能静默导出去。
  // 剔除落在 task.replacements（主流程唯一真相），方案文件只是提案
  final blockedByReview =
      plansBlockedByReview(validation.plans, task.replacementsFor(units));
  if (blockedByReview.isNotEmpty) {
    sink.writeln('方案里有素材已被审核剔除，先更新方案再导出：');
    for (final problem in blockedByReview) {
      sink.writeln('· $problem');
    }
    return exitBadUsage;
  }


  final dest =
      outputDir == null ? defaultExportDirectory(task.id) : Directory(outputDir);
  // 素材时长：镜头层算倍速要靠它。任务里存过的直接用，没存过的这一步
  // 不去探（探一遍要几分钟）——导出那头会就地探本地文件，照样算得出
  final materialDurations = {
    for (final m in task.pickedMaterials)
      if (m.durationMs case final ms? when ms > 0) m.id: ms,
  };
  final combos = [
    for (var i = 0; i < validation.plans.length; i++)
      toCombination(validation.plans[i], units,
          index: i, materialDurations: materialDurations),
  ];

  final lock = TaskLockFile(dataDir: dataDir, taskId: task.id);
  if (!lock.acquire(holder ?? agentLockHolder)) {
    final current = lock.read();
    // **界面占着锁不是冲突，是委派的时机**——和提交方案同一个死结：
    // 可视模式要求界面停在这个任务上，而导出要求界面不能停在这个任务上，
    // 于是人最想看着的一步恰恰因为「人在看」而做不了。
    //
    // 但导出跑几分钟、又花钱，不适合一路替人点到底：委派的是
    // 「把导出对话框打开、参数填好」，最后那一下由人点
    if (isGuiHolder(current?.holder)) {
      return _openExportInUi(
        dataDir: dataDir,
        task: task,
        outputDir: dest.path,
        spec: spec,
        sink: sink,
        out: out,
      );
    }
    sink.writeln('${current?.holder ?? '别人'} 正在操作这个任务，导不了');
    return exitLocked;
  }

  // 这批素材有什么问题先说清楚——**不拦，但绝不能不说**。
  // 界面上的导出确认页会点名，这条路一度一声不吭：Agent 查得到
  // （task --json 里有），导出时不提，等于把「要不要用这条素材」
  // 这个判断悄悄跳过了
  for (final warn in exportWarnings(
      picked: task.pickedMaterials,
      units: task.units ?? const [],
      // 字幕样式一起看：白描边盖不住素材自带的字，那是两行字打架
      subtitle: task.subtitle,
      // 整体替换的段落不烧台词字幕——这决定了烧字警告有多严重
      replacements: task.replacementsFor(units))) {
    sink.writeln(warn);
  }

  // 代价先说清楚——但不拦。要不要继续是调用方的判断
  sink.writeln('将导出 ${combos.length} 条到 ${dest.path}'
      '（${spec.width}×${spec.height} · ${spec.fps}fps · '
      '${spec.kbps ~/ 1000} Mbps · ${spec.encoderName} · ${spec.fileExtension}）');

  // 导出是分钟级的活儿：可视模式下把它挂到界面上，人不用盯着终端
  final stage = AgentStage(
    mode: AgentStageMode.from(visual: visual),
    dataDir: dataDir,
    taskId: task.id,
    holder: holder ?? agentLockHolder,
  );
  await stage.begin('正在导出 ${combos.length} 条成片',
      focus: const AgentFocus(module: 'workbench'));

  final runner = ExportRunner(
    run: const ResolvingProcessRunner().call,
    // 字幕样式跟任务走：素材自带烧录字幕时人会把它切成底条/毛玻璃来遮挡，
    // 这里吃默认值的话那个设置等于白设
    subtitleStyle: task.subtitle,
    workDir: Directory(p.join(dataDir.path, 'export_work', id)),
    resolveBgm: bgmCache(dataDir, task.id).fetch,
    probeDurationMs: (path) async =>
        (await FfprobeService(run: const ResolvingProcessRunner().call)
                .probe(path))
            .duration
            .inMilliseconds,
    fetchMaterial: MaterialDownloader(
      content: MiaoaContentService(),
      cacheDir: TaskMedia(dataDir: dataDir, taskId: task.id).materialsDir,
    ).fetch,
    // 整体替换的段落铺了配乐时用素材的纯人声——与 GUI 同一条规则
    separateMaterial: MaterialVocalCache(
      separator: VocalSeparator(
        extractAudio: extractAudioForSeparation,
        binary: resolveVocalSeparatorBinary(),
        modelDir: Directory(p.join(dataDir.path, 'separator_models')),
      ),
      cacheDir: TaskMedia(dataDir: dataDir, taskId: task.id).vocalsDir,
    ).vocalsOf,
  );

  // 人在 GUI 设的换音色方案：配音产物按约定落在 voices/<taskId>/unit_<i>.mp3
  // （见 VoiceSwapJob.audioFor）。不带上它们的话，CLI 导出会静默用回原声，
  // 且「选了音色未生成配音」的交付拦截也会因 voices 为空而失效
  final voiceDir = p.join(dataDir.path, 'voices', id);
  // 按单元的**身份**取文件名（见 VoiceSwapJob.audioFor）：写下标的话，
  // 人挪过单元之后取到的是别人的配音
  final voiceAudio = {
    for (final uid in task.voices.assignedUnits)
      if (File(p.join(voiceDir, 'unit_$uid.mp3')).existsSync())
        uid: p.join(voiceDir, 'unit_$uid.mp3'),
  };

  final outcomes = await runner.exportCombinations(
    combos: combos,
    spec: spec,
    sourcePath: task.sourcePath,
    units: units,
    replacements: task.replacementsFor(units),
    outputDir: dest,
    bgm: task.bgm,
    voices: task.voices,
    voiceAudio: voiceAudio,
    vocalsPath: task.vocalsPath,
    backgroundPath: task.backgroundPath,
    // 两层镜头声音**都要带上**：这条路一度只传了 vocalsPath，于是命令行
    // 导出来的片子里替换素材那一层从来没响过，和界面导出的不是同一条片子
    materialAudio: task.materialAudio,
    sourceAudio: task.sourceAudio,
    // 镜头替换的切片上重渲台词字幕（原片字幕烧在被换掉的画面里）
    subtitleSentences: task.asrSentences ?? const [],
    // 手改过的字幕以人改的为准——Agent 走的是同一条导出路
    subtitleTrack: task.subtitleTrack,
    onProgress: (done, total, what) {
      sink.writeln('[$done/$total] $what');
      // 心跳而不是握手：导出不能为了等界面回执停下来
      stage.heartbeat('正在导出 $done/$total：$what',
          focus: const AgentFocus(module: 'workbench'));
    },
  );

  final succeeded = outcomes.where((o) => o.failure == null).length;
  // 导出历史进任务：人在 app 里要能看到「哪天导了几条、在哪儿」
  await repository.save(task.copyWith(exports: [
    ...task.exports,
    ExportRecord(
      at: DateTime.now(),
      total: outcomes.length,
      succeeded: succeeded,
      outputDir: dest.path,
    ),
  ]));
  stage.end();
  lock.release(holder ?? agentLockHolder);

  emitJson({
    'outputDir': dest.path,
    'total': outcomes.length,
    'succeeded': succeeded,
    'results': [
      for (var i = 0; i < outcomes.length; i++)
        {
          'name': validation.plans[i].name,
          'path': outcomes[i].path,
          'failure': outcomes[i].failure,
          // 导成了但有话要说（目前只有「这一段过载了」）。**存了就要报**：
          // Agent 查到的空看起来正好像「没问题」
          'notes': outcomes[i].notes,
        },
    ],
  }, out: out);
  // 有失败的就非零退出：调用方不该靠解析 JSON 才发现出了问题
  return succeeded == outcomes.length ? 0 : 1;
}


/// 把命令行给的规格参数拼成 [ExportSpec]。任何一个认不出都返回 null 并报错
ExportSpec? _parseSpec({
  required String? resolution,
  required String? fps,
  required String? bitrate,
  required String? codec,
  required String? format,
  required StringSink sink,
}) {
  var spec = ExportSpec.standard;
  if (resolution != null) {
    final side = int.tryParse(resolution);
    if (side == null ||
        !ExportSpec.resolutions.any((r) => r.shortSide == side)) {
      sink.writeln('认不出分辨率「$resolution」。可用：'
          '${ExportSpec.resolutions.map((r) => r.shortSide).join(' / ')}（短边）');
      return null;
    }
    spec = spec.copyWith(shortSide: side);
  }
  if (fps != null) {
    final value = int.tryParse(fps);
    if (value == null || !ExportSpec.frameRates.contains(value)) {
      sink.writeln('认不出帧率「$fps」。可用：${ExportSpec.frameRates.join(' / ')}');
      return null;
    }
    spec = spec.copyWith(fps: value);
  }
  if (bitrate != null) {
    switch (bitrate) {
      case 'recommended':
        spec = spec.copyWith(bitrate: BitrateMode.recommended);
      case 'higher':
        spec = spec.copyWith(bitrate: BitrateMode.higher);
      case 'lower':
        spec = spec.copyWith(bitrate: BitrateMode.lower);
      default:
        final kbps = int.tryParse(bitrate);
        if (kbps == null || kbps <= 0 || kbps > ExportSpec.maxCustomKbps) {
          sink.writeln('认不出码率「$bitrate」。可用：recommended / higher / '
              'lower，或直接给 kbps 数字（上限 ${ExportSpec.maxCustomKbps}）');
          return null;
        }
        spec = spec.copyWith(
            bitrate: BitrateMode.custom, customKbps: kbps);
    }
  }
  if (codec != null) {
    final value =
        VideoCodec.values.where((c) => c.name == codec).firstOrNull;
    if (value == null) {
      sink.writeln('认不出编码「$codec」。可用：h264 / hevc');
      return null;
    }
    spec = spec.copyWith(codec: value);
  }
  if (format != null) {
    final value =
        ContainerFormat.values.where((f) => f.name == format).firstOrNull;
    if (value == null) {
      sink.writeln('认不出格式「$format」。可用：mp4 / mov');
      return null;
    }
    spec = spec.copyWith(format: value);
  }
  return spec;
}


/// 请界面把导出对话框打开、参数填好——**人不用挪开，最后那一下他自己点**。
///
/// 为什么不替人点到底：导出跑几分钟、直接产出交付物、而且花钱。
/// 提交方案那种「下单 -> 界面做完 -> 回执」的节奏在这儿不合适，
/// 人在旁边时让他确认一下反而是对的。
Future<int> _openExportInUi({
  required Directory dataDir,
  required RenewTask task,
  required String outputDir,
  required ExportSpec spec,
  required StringSink sink,
  required StringSink? out,
}) async {
  final id = writeAgentRequest(
    dataDir: dataDir,
    taskId: task.id,
    kind: UiAction.exportOpen.wire,
    payload: {
      'outputDir': outputDir,
      'resolution': '${spec.height}',
      'fps': '${spec.fps}',
      'codec': spec.encoderName,
      'format': spec.fileExtension,
    },
  );
  sink.writeln('这个任务的页面正开着，已请界面把导出对话框打开、参数填好'
      '——最后那一下让用户点（导出跑几分钟、直接出交付物，不替他点）');
  final result = await waitForAgentRequest(
      dataDir: dataDir,
      taskId: task.id,
      id: id,
      timeout: const Duration(seconds: 30));
  if (result == null) {
    sink.writeln('界面没有回应（等了 30 秒）。让用户看一眼那个页面，'
        '或者把界面挪开再跑一次');
    return exitEnv;
  }
  if (!result.ok) {
    sink.writeln('没能打开导出：${result.message}');
    return exitFailed;
  }
  emitJson({
    'ok': true,
    'via': 'ui',
    'message': result.message,
    // **还没有成片**：对话框只是开着，人还没点。别让调用方以为导完了
    'exported': false,
    'next': '等用户在界面上点「开始导出」。导完了用 ishkafel task <任务> '
        '看 exports 里最新那一次',
  }, out: out);
  return 0;
}
