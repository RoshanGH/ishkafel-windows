import 'dart:io';

import '../../core/audio/material_audio.dart';
import '../../core/audio/source_audio.dart';
import '../../app/service_wiring.dart';
import '../../core/analysis/base_transcriber.dart';
import '../../core/analysis/scene_detector.dart';
import '../../core/analysis/unit_segmenter.dart';
import '../../core/editing/base_pin_ops.dart';
import '../../core/replacement/replacement_plan.dart';
import '../../core/replacement/unit_base.dart';
import '../../core/storage/task_media.dart';
import '../../core/editing/blank_unit_ops.dart';
import '../../core/editing/blank_unit_removal.dart';
import '../../core/editing/segmentation_edit_ops.dart';
import '../../core/editing/unit_reorder.dart';
import '../../core/models/renew_task.dart';
import '../../core/subtitle/subtitle_track.dart';
import '../../core/subtitle/subtitle_overlay.dart';
import '../../core/storage/agent_presence.dart';
import '../../core/storage/file_task_repository.dart';
import '../../core/storage/task_lock.dart';
import '../../core/storage/task_seq.dart';
import '../agent_lock_holder.dart';
import '../agent_stage.dart';
import '../cli_output.dart';
import '../task_view.dart';
import 'analyze_command.dart' show loadCliCredentials, vocabularyFor;

/// `ishkafel unit <add|remove|move|tags|audio> …` —— 台词语义单元这一层的旋钮。
///
/// **两种任务都能用**：有原片的（替换裂变）和没原片的（拼片）。
/// 人在工作台上能拧的，这里一个不少——少一个，Agent 就只能被动接受软件给的
/// 默认值，那又退回成规则了。
///
/// 与 GUI 同一套规则、同一批补偿函数：
/// - 有原片的任务加出来的单元**原片上没有它**（`hasSource=false`），只能接末尾；
///   想排到前面，加完用 `move`
/// - 删只删手动加的那些（分析切出来的删掉等于把原片少放一段，是另一件事）
/// - 增删改序时，**替换方案 / 配音 / 配乐**三份按下标记的数据一起搬
///   （见 `unit_reorder.dart` 与 `blank_unit_removal.dart`）
Future<int> runUnitCommand({
  required List<String> rest,
  required Directory dataDir,
  int? unit,
  int? shot,
  int? to,
  bool visual = false,
  String? tags,
  String? audio,
  String? text,
  bool auto = false,
  double? volume,
  String? holder,
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  if (rest.isEmpty) {
    sink.writeln(_usage);
    return exitBadUsage;
  }
  final what = rest.first;
  if (rest.length < 2) {
    sink.writeln('少了任务 id。用法：ishkafel unit $what <任务 id> …');
    return exitBadUsage;
  }
  final repository = FileTaskRepository(dataDir);
  final task = await resolveTaskRef(repository, rest[1]);
  if (task == null) {
    sink.writeln('没有这个任务：${rest[1]}');
    return exitNotFound;
  }

  final stage = AgentStage(
    mode: AgentStageMode.from(visual: visual),
    dataDir: dataDir,
    taskId: task.id,
    holder: holder ?? agentLockHolder,
  );
  final lock = TaskLockFile(dataDir: dataDir, taskId: task.id);
  if (!lock.acquire(holder ?? agentLockHolder)) {
    sink.writeln('${lock.read()?.holder ?? '别人'} 正在操作这个任务，改不了');
    return exitLocked;
  }
  try {
    final o = out ?? stdout;
    // 这几条都改成片的结构，可视模式下界面要跟过来——人正是为了看你怎么想
    // 才开着那一页的，动了什么必须一眼看得出来
    await stage.begin(_stageWord(what),
        focus: const AgentFocus(module: 'workbench'));
    return switch (what) {
      'add' => await _add(repository, task, o),
      'remove' => await _remove(repository, task, unit, sink, o),
      'move' => await _move(repository, task, unit, to, sink, o),
      'tags' => await _tags(repository, task, unit, tags, sink, o),
      'audio' =>
        await _audio(repository, task, unit, shot, audio, volume, sink, o),
      'source-audio' => await _sourceAudio(
          repository, task, unit, shot, audio, volume, sink, o),
      'subtitle' =>
        await _subtitle(repository, task, unit, shot, text, auto, sink, o),
      'base' => await _base(task, unit, sink, o),
      'segment' => await _segment(repository, task, unit, dataDir, sink, o),
      'unpin' => await _unpin(repository, task, unit, sink, o),
      _ => () {
          sink.writeln('认不出「$what」。'
              '可用：add / remove / move / tags / audio / '
              'source-audio / subtitle / base / segment / unpin');
          return exitBadUsage;
        }(),
    };
  } finally {
    stage.end();
    lock.release(holder ?? agentLockHolder);
  }
}

/// 播报只说人话——「正在挪单元顺序」，不是「runUnitCommand move」
String _stageWord(String what) => switch (what) {
      'base' => '正在看这一段的底片',
      'segment' => '正在切分这一段的底片（还会转写、打标）',
      'unpin' => '正在换这一段的底片',
      'add' => '正在加一个台词语义单元',
      'remove' => '正在删掉一个台词语义单元',
      'move' => '正在调整台词语义单元的顺序',
      'tags' => '正在给台词语义单元填标签',
      'audio' => '正在设置替换分镜的声音',
      'source-audio' => '正在设置原片这一镜的声音',
      'subtitle' => '正在改这一镜的字幕',
      _ => '正在改台词语义单元',
    };

const String _usage = '用法：\n'
    '  ishkafel unit add <任务 id>                          在末尾加一个单元\n'
    '  ishkafel unit remove <任务 id> --unit N              删掉一个单元\n'
    '  ishkafel unit move <任务 id> --unit N --to M         把第 N 个挪到第 M 位\n'
    '  ishkafel unit tags <任务 id> --unit N --tags a,b     手填这个单元的标签\n'
    '  ishkafel unit audio <任务 id> [--unit N --shot M] \\\n'
    '      --audio none|vocals|background|original|follow \\\n'
    '      [--volume 0.25]                                 替换分镜放哪一路声音\n'
    '  ishkafel unit source-audio <任务 id> [--unit N --shot M] \\\n'
    '      --audio none|vocals|background|original|follow|auto \\\n'
    '      [--volume 1.0]                                  原片这一镜放哪一路声音\n'
    '  ishkafel unit subtitle <任务 id> --unit N --shot M \\\n'
    '      --text "第一句|第二句" | --auto                   改这一镜要烧的字幕\n'
    '  ishkafel unit base <任务 id> --unit N                这一段的底片是谁\n'
    '  ishkafel unit segment <任务 id> --unit N             切分这一段的底片\n'
    '  ishkafel unit unpin <任务 id> --unit N               换一张底片（清掉旧的）';

Future<int> _add(
    FileTaskRepository repository, RenewTask task, StringSink out) async {
  final units = task.units ?? const [];
  // 空白任务的分子和有原片任务里手加的单元，走各自那套（前者没有原片这个
  // 概念，后者要标上「原片里没有它」）
  final next = task.copyWith(
    units: task.isBlank
        ? BlankUnitOps.append(units)
        // 帧率读不出来就给 0（appendUnit 那边会原样不动，不去瞎对齐）
        : SegmentationEditOps.appendUnit(units,
            fps: task.videoInfo?.fps ?? 0),
    updatedAt: DateTime.now(),
  );
  await repository.save(next);
  emitJson(taskToJson(next), out: out);
  return 0;
}

Future<int> _remove(FileTaskRepository repository, RenewTask task, int? unit,
    StringSink sink, StringSink out) async {
  final units = task.units ?? const [];
  if (unit == null || unit < 0 || unit >= units.length) {
    sink.writeln('要给 --unit <下标>（0 起，当前 ${units.length} 个）');
    return exitBadUsage;
  }
  if (task.isBlank && units.length <= blankMinUnits) {
    sink.writeln('至少要留 $blankMinUnits 个分子，删不了');
    return exitBadUsage;
  }
  // 有原片的任务只能删**手动加的**那些：分析切出来的单元删掉等于把原片少放
  // 一段，那是另一件事，不在这个入口做
  if (!task.isBlank && units[unit].hasSource) {
    sink.writeln('U${unit + 1} 是分析切出来的，删掉等于把原片少放一段——'
        '这个入口只删手动加的单元');
    return exitBadUsage;
  }
  final next = task.copyWith(
    // 有原片的任务只重排下标：单元的起止和单元里的视觉镜头都是原片坐标，
    // 重铺时间轴会让两层对不上（见 [removeUnitAt]）
    units: task.isBlank
        ? BlankUnitOps.removeAt(units, unit)
        : removeUnitAt(units, unit),
    // 替换方案按单元的身份记，只需要把没人认领的那条丢掉
    replacementsByUid: {
      for (final e in task.replacementsByUid.entries)
        if (removeUnitAt(units, unit).any((u) => u.uid == e.key))
          e.key: e.value,
    },
    bgm: shiftBgmAfterRemoval(task.bgm, removed: unit),
    voices: task.voices
        .keepingOnly({for (final u in removeUnitAt(units, unit)) u.uid}),
    subtitleTrack: task.subtitleTrack
        .keepingOnly({for (final u in removeUnitAt(units, unit)) u.uid}),
    updatedAt: DateTime.now(),
  );
  await repository.save(next);
  emitJson(taskToJson(next), out: out);
  return 0;
}

Future<int> _move(FileTaskRepository repository, RenewTask task, int? unit,
    int? to, StringSink sink, StringSink out) async {
  final units = task.units ?? const [];
  if (unit == null || unit < 0 || unit >= units.length) {
    sink.writeln('要给 --unit <下标>（0 起，当前 ${units.length} 个）');
    return exitBadUsage;
  }
  if (to == null || to < 0 || to >= units.length) {
    sink.writeln('要给 --to <目标位置>（0 起，当前 ${units.length} 个）');
    return exitBadUsage;
  }
  final moved = moveUnit(units, from: unit, to: to);
  if (identical(moved, units)) {
    sink.writeln('没挪动（--unit 和 --to 一样）');
    return exitBadUsage;
  }
  final bgm = remapBgmAfterMove(task.bgm, from: unit, to: to);
  final next = task.copyWith(
    units: moved,
    // 替换方案、配音、手改字幕都按身份记，挪顺序一份都不用动
    bgm: bgm.plan,
    updatedAt: DateTime.now(),
  );
  await repository.save(next);
  // 配乐盖的范围被打断了就说出来——用户当初是照着那几段的内容选的曲子，
  // 悄悄改成另一个范围是不行的
  if (bgm.brokenSegments.isNotEmpty) {
    sink.writeln('注意：有配乐是按连续几段铺的，挪动之后盖的范围变了，'
        '请用 ishkafel bgm 复核');
  }
  emitJson(taskToJson(next), out: out);
  return 0;
}

Future<int> _tags(FileTaskRepository repository, RenewTask task, int? unit,
    String? tags, StringSink sink, StringSink out) async {
  final units = task.units ?? const [];
  if (unit == null || unit < 0 || unit >= units.length) {
    sink.writeln('要给 --unit <下标>（0 起，当前 ${units.length} 个）');
    return exitBadUsage;
  }
  // 手填标签只对**没有台词**的单元有意义：有台词的那些标签是模型按台词打的，
  // 在这儿手改会和「重新打标」互相覆盖，而谁赢看不出来
  if (!task.isBlank && units[unit].hasSource) {
    sink.writeln('U${unit + 1} 是分析切出来的，标签由模型按台词打；'
        '要重打用 ishkafel analyze，手填只对手动加的单元开放');
    return exitBadUsage;
  }
  final wanted = [
    for (final piece in (tags ?? '').split(','))
      if (piece.trim().isNotEmpty) piece.trim(),
  ];
  // 与 GUI 同一条规矩：标签必须逐字命中词表。「厨房场景」和「厨房情景」
  // 在检索时是两回事，而手打的那个搜不出任何东西、还看不出异常
  final vocabulary = (await vocabularyFor(task.unitTagGroups)).toSet();
  final unknown = wanted.where((t) => !vocabulary.contains(t)).toList();
  if (unknown.isNotEmpty) {
    sink.writeln('这些标签不在受控词表里：${unknown.join('、')}。'
        '词表见 ishkafel task ${task.id}');
    return exitBadUsage;
  }
  final next = task.copyWith(
    units: BlankUnitOps.setTags(units, unit, wanted),
    updatedAt: DateTime.now(),
  );
  await repository.save(next);
  emitJson(taskToJson(next), out: out);
  return 0;
}

/// 「替换分镜的声音」：不给 --unit/--shot 就是设**全片打底**，
/// 给了就是设**那一镜的覆盖**。
///
/// 四档：`none` 不播 / `vocals` 只放素材里的人声 / `background` 只放它的现场音
/// / `original` 原样整条。镜头这一层还能给 `follow`，表示跟随全片。
Future<int> _audio(
  FileTaskRepository repository,
  RenewTask task,
  int? unit,
  int? shot,
  String? audio,
  double? volume,
  StringSink sink,
  StringSink out,
) async {
  final names = MaterialAudioMode.values.map((m) => m.name).join(' / ');
  if (audio == null) {
    sink.writeln('要给 --audio（$names / follow）');
    return exitBadUsage;
  }
  final mode = MaterialAudioMode.byName(audio);
  if (mode == null && audio != 'follow') {
    sink.writeln('认不出「$audio」。--audio 要是：$names / follow');
    return exitBadUsage;
  }
  if (volume != null && (volume < 0 || volume > 1)) {
    sink.writeln('--volume 要在 0~1 之间');
    return exitBadUsage;
  }

  // 没指定镜头 = 设全片打底
  if (unit == null && shot == null) {
    if (mode == null) {
      sink.writeln('全片这一层没有「跟随」可跟——--audio 要给一个具体的档位：$names');
      return exitBadUsage;
    }
    final next = task.copyWith(
      materialAudio: MaterialAudioSetting(
          mode: mode, volume: volume ?? task.materialAudio.volume),
      updatedAt: DateTime.now(),
    );
    await repository.save(next);
    emitJson(taskToJson(next), out: out);
    return 0;
  }

  final units = task.units ?? const [];
  if (unit == null || unit < 0 || unit >= units.length) {
    sink.writeln('要给 --unit <下标>（0 起，当前 ${units.length} 个）');
    return exitBadUsage;
  }
  final shots = units[unit].shots;
  if (shot == null || shot < 0 || shot >= shots.length) {
    sink.writeln('要给 --shot <下标>（0 起，U${unit + 1} 有 ${shots.length} 个镜头）');
    return exitBadUsage;
  }
  final next = task.copyWith(
    units: [
      for (var i = 0; i < units.length; i++)
        if (i != unit)
          units[i]
        else
          units[i].copyWith(shots: [
            for (var j = 0; j < shots.length; j++)
              if (j != shot)
                shots[j]
              else
                // 走 withMaterialAudioOverride 而不是 copyWith：
                // copyWith 的 `??` 传 null 等于「不改」，而 follow（跟随全片）
                // 正是 null
                shots[j]
                    .withMaterialAudioOverride(mode: mode, volume: volume),
          ]),
    ],
    updatedAt: DateTime.now(),
  );
  await repository.save(next);
  emitJson(taskToJson(next), out: out);
  return 0;
}

/// 「原片这一镜的声音」：不给 --unit/--shot 就是设**全片打底**，
/// 给了就是设**那一镜的覆盖**。
///
/// 档位和替换分镜那条是同一套（none / vocals / background / original），
/// 外加两个状态词：全片这一层的 `auto`（还没选过，走老行为——原混音，
/// 被配乐盖住时换纯人声），镜头那一层的 `follow`（跟随全片）。
///
/// **只对换过素材的镜头有效**：没换素材的镜头照旧走自动那条路，
/// 这里设了也不起作用（和界面同一条规则）。
Future<int> _sourceAudio(
  FileTaskRepository repository,
  RenewTask task,
  int? unit,
  int? shot,
  String? audio,
  double? volume,
  StringSink sink,
  StringSink out,
) async {
  final names = MaterialAudioMode.values.map((m) => m.name).join(' / ');
  if (audio == null) {
    sink.writeln('要给 --audio（$names / follow / auto）');
    return exitBadUsage;
  }
  final mode = MaterialAudioMode.byName(audio);
  if (mode == null && audio != 'follow' && audio != 'auto') {
    sink.writeln('认不出「$audio」。--audio 要是：$names / follow / auto');
    return exitBadUsage;
  }
  if (volume != null && (volume < 0 || volume > 1)) {
    sink.writeln('--volume 要在 0~1 之间');
    return exitBadUsage;
  }

  // 没指定镜头 = 设全片打底
  if (unit == null && shot == null) {
    if (audio == 'follow') {
      sink.writeln('全片这一层没有「跟随」可跟——要回到默认请用 auto');
      return exitBadUsage;
    }
    final next = task.copyWith(
      sourceAudio: SourceAudioSetting(
          mode: audio == 'auto' ? null : mode,
          volume: volume ?? task.sourceAudio.volume),
      updatedAt: DateTime.now(),
    );
    await repository.save(next);
    emitJson(taskToJson(next), out: out);
    return 0;
  }

  final units = task.units ?? const [];
  if (unit == null || unit < 0 || unit >= units.length) {
    sink.writeln('要给 --unit <下标>（0 起，当前 ${units.length} 个）');
    return exitBadUsage;
  }
  final shots = units[unit].shots;
  if (shot == null || shot < 0 || shot >= shots.length) {
    sink.writeln('要给 --shot <下标>（0 起，U${unit + 1} 有 ${shots.length} 个镜头）');
    return exitBadUsage;
  }
  if (audio == 'auto') {
    sink.writeln('镜头这一层没有「自动」——auto 是全片那一层的状态。'
        '要回到跟随全片请用 follow');
    return exitBadUsage;
  }
  final next = task.copyWith(
    units: [
      for (var i = 0; i < units.length; i++)
        if (i != unit)
          units[i]
        else
          units[i].copyWith(shots: [
            for (var j = 0; j < shots.length; j++)
              if (j != shot)
                shots[j]
              else
                // 走 withSourceAudioOverride：copyWith 的 `??` 传 null 等于
                // 「不改」，而 follow（跟随全片）正是 null
                shots[j].withSourceAudioOverride(mode: mode, volume: volume),
          ]),
    ],
    updatedAt: DateTime.now(),
  );
  await repository.save(next);
  emitJson(taskToJson(next), out: out);
  return 0;
}

/// 改这一镜要烧上去的字幕。
///
/// **只有换过素材的镜头才烧字幕**：没换的那些字烧在原片像素里，我们既读不出
/// 也不重渲。默认按 ASR 的词级时间戳切给各镜，而「哪里断句好看」是编导的
/// 判断——真机上「了」的声音落在下一镜，那一镜的字幕就以一个孤零零的「了」
/// 开头。所以给人手改。
///
/// **字幕是字幕，台词是台词**：改这里不动单元的 transcript。
Future<int> _subtitle(
  FileTaskRepository repository,
  RenewTask task,
  int? unit,
  int? shot,
  String? text,
  bool auto,
  StringSink sink,
  StringSink out,
) async {
  final units = task.units ?? const [];
  if (unit == null || unit < 0 || unit >= units.length) {
    sink.writeln('要给 --unit <下标>（0 起，当前 ${units.length} 个）');
    return exitBadUsage;
  }
  final shots = units[unit].shots;
  if (shot == null || shot < 0 || shot >= shots.length) {
    sink.writeln('要给 --shot <下标>（0 起，U${unit + 1} 有 ${shots.length} 个镜头）');
    return exitBadUsage;
  }
  // 按单元的**身份**记：人在界面上说 U3，存的却是它自己那个编号，
  // 挪过顺序也还认得回来
  final slot = SubtitleSlot(unitUid: units[unit].uid, shotIndex: shot);

  // --auto：清掉手改，回到按 ASR 现算
  if (auto) {
    final next = task.copyWith(
        subtitleTrack: task.subtitleTrack.cleared(slot),
        updatedAt: DateTime.now());
    await repository.save(next);
    emitJson(taskToJson(next), out: out);
    return 0;
  }
  if (text == null) {
    sink.writeln('要给 --text "第一句|第二句"（用 | 分段），'
        '或者 --auto 改回自动。给 --text "" 表示这一镜不要字幕');
    return exitBadUsage;
  }

  // 时间在坑位内平均分——精确到毫秒的调整在界面上做，命令行给一个够用的默认
  final pieces = [
    for (final p in text.split('|'))
      if (p.trim().isNotEmpty) p.trim(),
  ];
  final span = shots[shot].endMs - shots[shot].startMs;
  final lines = [
    for (var i = 0; i < pieces.length; i++)
      SubtitleLine(
        startMs: (span * i / pieces.length).round(),
        endMs: (span * (i + 1) / pieces.length).round(),
        text: pieces[i],
      ),
  ];
  final next = task.copyWith(
      subtitleTrack: task.subtitleTrack.withLines(slot, lines),
      updatedAt: DateTime.now());
  await repository.save(next);
  emitJson(taskToJson(next), out: out);
  return 0;
}


/// `unit base` —— 这一段的画面从哪儿来、能不能切。
///
/// **先问再做**：Agent 拿到「能不能切、切了会掉什么」才谈得上自己判断，
/// 不给它就只能试一下看报错
Future<int> _base(
    RenewTask task, int? unit, StringSink sink, StringSink out) async {
  final units = task.units ?? const [];
  if (unit == null || unit < 0 || unit >= units.length) {
    sink.writeln('要给 --unit N（0 开始，共 ${units.length} 个）');
    return exitBadUsage;
  }
  final u = units[unit];
  final plan = task.replacementsFor(units).elementAtOrNull(unit) ??
      UnitReplacement.keepOriginal();
  final choice = baseChoiceOf(unit: u, replacement: plan);
  final blocked =
      BasePinOps.segmentBlockedReason(unit: u, replacement: plan);
  final pinnedId = u.baseCandidateId;
  final cost = pinnedId == null && choice is MaterialBase
      ? BasePinOps.costOf(
          unit: u, replacement: plan, candidateId: choice.candidateId)
      : null;

  emitJson({
    'unit': unit,
    'uid': u.uid,
    'base': switch (choice) {
      MaterialBase(:final candidateId) => {
          'kind': 'material',
          'candidateId': candidateId,
        },
      OriginalBase(:final startMs, :final endMs) => {
          'kind': 'original',
          'startMs': startMs,
          'endMs': endMs,
        },
      NoBase() => {'kind': 'none'},
    },
    // 固定过 = 镜头是按这张底片切出来的，这一段从此只能用它
    'pinned': pinnedId != null,
    'pinnedCandidateId': pinnedId,
    'shots': u.shots.length,
    // 这一段的镜头打过标没有。**没打就别急着按标签/画面搜素材**——
    // 检索键就是它们，一条都搜不出来时你会以为素材库里没有
    'shotsTagged': u.shots.where((s) => s.tags.isNotEmpty).length,
    // 底片转写出几句。字幕从这一份取；0 句（或没转过）就是这一段没字幕，
    // 要的话用 `unit subtitle` 自己排
    'baseSentenceCount': u.baseSentences?.length,
    'transcript': u.transcript,
    'canSegment': blocked == null,
    'blockedReason': ?blocked,
    if (cost != null)
      'segmentWouldDrop': {
        'otherCandidates': cost.droppedCandidates,
        'shotPicks': cost.droppedShotPicks,
      },
  }, out: out);
  return 0;
}

/// `unit segment` —— 切这一段的底片，从此每一镜都能单独换素材。
///
/// 跟界面上那个按钮同一条路：同样要跑 ffmpeg 采信号、同样会把其余候选
/// 收敛掉。**会花时间也会花钱**，所以它是显式命令，不在挑素材时自动跑
Future<int> _segment(FileTaskRepository repository, RenewTask task, int? unit,
    Directory dataDir, StringSink sink, StringSink out) async {
  final units = task.units ?? const [];
  if (unit == null || unit < 0 || unit >= units.length) {
    sink.writeln('要给 --unit N（0 开始，共 ${units.length} 个）');
    return exitBadUsage;
  }
  final u = units[unit];
  final plans = task.replacementsFor(units);
  final plan = plans.elementAtOrNull(unit) ?? UnitReplacement.keepOriginal();

  final blocked =
      BasePinOps.segmentBlockedReason(unit: u, replacement: plan);
  if (blocked != null) {
    sink.writeln(blocked);
    return exitBadUsage;
  }
  final choice = baseChoiceOf(unit: u, replacement: plan);
  if (choice is! MaterialBase) {
    sink.writeln('这一段没有可切的底片');
    return exitBadUsage;
  }
  final candidateId = choice.candidateId;

  final media = TaskMedia(dataDir: dataDir, taskId: task.id);
  final basePath = media.localMaterial(candidateId);
  if (basePath == null) {
    sink.writeln('素材 $candidateId 还没下到本地，切不了。'
        '先跑一次预览或导出把它拉下来');
    return exitEnv;
  }

  final credentials = loadCliCredentials(dataDir);
  final pipeline = buildAnalysisPipeline(credentials, dataDir);
  final segmenter = UnitSegmenter(
      scenes: SceneDetector(), boundaries: pipeline?.shotBoundaries);

  final durationMs = task.pickedMaterials
          .where((m) => m.id == candidateId)
          .map((m) => m.durationMs)
          .firstOrNull ??
      u.durationMs;
  final shots = await segmenter.segment(
    unit: u,
    base: UnitBase(
        path: basePath,
        startMs: 0,
        endMs: durationMs,
        candidateId: candidateId),
    taskId: task.id,
    fps: task.videoInfo?.fps ?? 25,
  );
  if (shots.isEmpty) {
    sink.writeln('这条素材读不出时长，切不出镜头');
    return exitEnv;
  }

  // **顺手把这条素材转写一遍**：字幕要的词级时间戳只能从这儿来，原片那份
  // 量的是原片、跟这段画面对不上。转不出来不挡切分——那一段就是没字幕
  final sentences = pipeline == null
      ? null
      : await BaseTranscriber(
              audio: pipeline.audio,
              asr: pipeline.asr,
              workDir: pipeline.workDir)
          .transcribe(videoPath: basePath, key: '${task.id}_u${u.uid}');

  var (nextUnits, nextPlans) = BasePinOps.pin(units, plans, unit,
      candidateId: candidateId, shots: shots, sentences: sentences);

  // **切完接着打标**——界面上那条路是这么走的，这里少一步，Agent 切出来的
  // 镜头就没有标签也没有画面描述，`candidates --shot` 按标签/画面一条都
  // 搜不出来。两条路做出来的必须是同一份东西
  final tagging = pipeline?.tagging;
  if (tagging != null) {
    try {
      nextUnits = await tagging.tag(
        task.copyWith(units: nextUnits),
        nextUnits,
        only: {unit},
        // 抽帧要从**底片**上抽：跑去原片同一个时间点，打出来的标签张冠李戴
        baseVideoPaths: {u.index: basePath},
      );
    } catch (e) {
      // 打标失败不回滚切分——切分本身有价值，标签可以之后再打
      // （单元上已经标了 tagsStale，重打标那条路会把它捡起来）
      sink.writeln('切分好了，但打标没成：$e');
      sink.writeln('跑 ishkafel analyze <任务> 或在界面上重打一次');
    }
  }

  final next = task.copyWith(
    units: nextUnits,
    replacementsByUid: {
      for (var i = 0; i < nextUnits.length && i < nextPlans.length; i++)
        nextUnits[i].uid: nextPlans[i],
    },
    updatedAt: DateTime.now(),
  );
  await repository.save(next);
  emitJson(taskToJson(next), out: out);
  return 0;
}

/// `unit unpin` —— 换一张底片：旧底片切出来的镜头和挑在上面的素材全清掉
Future<int> _unpin(FileTaskRepository repository, RenewTask task, int? unit,
    StringSink sink, StringSink out) async {
  final units = task.units ?? const [];
  if (unit == null || unit < 0 || unit >= units.length) {
    sink.writeln('要给 --unit N（0 开始，共 ${units.length} 个）');
    return exitBadUsage;
  }
  if (units[unit].baseCandidateId == null) {
    sink.writeln('U${unit + 1} 的底片本来就没固定过，没有可清的');
    return exitBadUsage;
  }
  final plans = task.replacementsFor(units);
  final (nextUnits, nextPlans) = BasePinOps.unpin(units, plans, unit);
  final next = task.copyWith(
    units: nextUnits,
    replacementsByUid: {
      for (var i = 0; i < nextUnits.length && i < nextPlans.length; i++)
        nextUnits[i].uid: nextPlans[i],
    },
    updatedAt: DateTime.now(),
  );
  await repository.save(next);
  emitJson(taskToJson(next), out: out);
  return 0;
}
