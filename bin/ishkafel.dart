import 'dart:io';

import 'package:args/args.dart';
import 'package:ishkafel/cli/cli_output.dart';
import 'package:ishkafel/cli/commands/analyze_command.dart';
import 'package:ishkafel/cli/commands/status_command.dart';
import 'package:ishkafel/cli/commands/blank_command.dart';
import 'package:ishkafel/cli/commands/apply_command.dart';
import 'package:ishkafel/cli/commands/candidates_command.dart';
import 'package:ishkafel/cli/commands/doctor_command.dart';
import 'package:ishkafel/cli/commands/export_command.dart';
import 'package:ishkafel/cli/commands/import_command.dart';
import 'package:ishkafel/cli/commands/jianying_command.dart';
import 'package:ishkafel/cli/commands/peek_command.dart';
import 'package:ishkafel/cli/commands/subtitle_command.dart';
import 'package:ishkafel/core/storage/agent_presence.dart';
import 'package:ishkafel/core/storage/task_lock.dart';
import 'package:ishkafel/cli/commands/open_command.dart';
import 'package:ishkafel/cli/commands/review_command.dart';
import 'package:ishkafel/cli/commands/ui_command.dart';
import 'package:ishkafel/cli/commands/bgm_command.dart';
import 'package:ishkafel/cli/commands/clean_command.dart';
import 'package:ishkafel/core/audio/bgm_library.dart';
import 'package:ishkafel/cli/commands/voice_command.dart';
import 'package:ishkafel/cli/commands/voices_command.dart';
import 'package:ishkafel/cli/commands/script_command.dart';
import 'package:ishkafel/cli/commands/skill_command.dart';
import 'package:ishkafel/cli/commands/task_command.dart';
import 'package:ishkafel/cli/commands/tasks_command.dart';
import 'package:ishkafel/cli/commands/todo_command.dart';
import 'package:ishkafel/cli/commands/unit_command.dart';
import 'package:ishkafel/cli/data_dir.dart';
import 'package:ishkafel/cli/console_encoding.dart';

/// ishkafel 的命令行入口。
///
/// **存在的理由**：让 Agent（Claude Code / Codex / 任何能跑 bash 的）驱动
/// 全流程——导入、分析、挑素材、配乐、导出，人只看成片；也可以在任意一步
/// 停下来，把 GUI 弹出来转人工。
///
/// **为什么是 CLI 不是 MCP Server**（详见
/// `docs/superpowers/specs/2026-08-11-agent-cli-design.md` 第二节）：
/// - 决定性的一条是**跨平台**：Codex 用不了 MCP，但谁都能跑 bash
/// - 任务是文件存储，CLI 与 GUI 天然读同一份数据，不需要进程间通信
/// - 人能直接跑同一条命令复现问题；MCP 要专门的客户端才能调试
Future<void> main(List<String> args) async {
  configureConsoleEncoding();
  final parser = ArgParser()
    ..addFlag('json', help: '输出结构化 JSON', defaultsTo: true)
    ..addOption('data-dir', help: '数据目录（默认与 app 一致）')
    ..addOption('unit', help: '单元下标（从 0 开始）')
    ..addOption('shot', help: '镜头下标（从 0 开始）')
    ..addOption(
      'text',
      help:
          'unit subtitle 用：这一镜的字幕，多段用 | 分开；'
          '给空串表示不要字幕',
    )
    ..addFlag('auto', negatable: false, help: 'unit subtitle 用：清掉手改，回到自动算')
    ..addOption(
      'audio',
      help:
          'unit audio 用：none 不播 / vocals 人声 / background 背景声 / '
          'original 原声 / follow 跟随全片',
    )
    ..addOption('line', help: 'script 用：行号（从 1 开始，与界面上一致）')
    ..addOption('voice', help: 'script voice 用：音色 id')
    ..addFlag(
      'visual',
      negatable: false,
      help:
          '可视模式：把 app 拉起来，一步一步演给人看'
          '（也可以用 ISHKAFEL_VISUAL=1）',
    )
    ..addOption('file', help: 'apply 用：结果文件（不给就从 stdin 读）')
    ..addFlag('yes', negatable: false, help: 'task-delete 用：确认删除（不可逆）')
    ..addOption(
      'by',
      help: 'script shots 用：检索方式 tags/content/image/voiceover/name',
    )
    ..addOption('materials', help: 'script peek 用：要看哪几条素材的画面，逗号分隔')
    ..addOption(
      'mode',
      help:
          'ui new-task 用：replace（替换裂变，要 --file）/ '
          'blank（替换裂变但不用原片）/ script（脚本成片）',
    )
    ..addOption(
      'items',
      help:
          'review drop/keep 用：要动的候选，单元:镜头:素材（逗号分隔），'
          '整体替换的候选镜头位写 `-`',
    )
    ..addOption('out', help: 'export 用：输出目录')
    ..addOption('tag-groups', help: 'import 用：标签组 id，逗号分隔')
    ..addOption(
      'module',
      help: 'ui open 用：去哪个模块（director / workbench / review）',
    )
    ..addFlag('install', negatable: false, help: 'skill 用：把说明书装成技能（确定性落盘）')
    ..addOption('keyword', help: 'candidates 用：按画面描述语义检索（替代标签）')
    ..addOption('units', help: 'voice 用：给哪几个单元换音色（0,2）')
    ..addOption('from', help: 'bgm 用：从第几个单元开始铺')
    ..addOption('to', help: 'bgm 用：铺到第几个单元；unit move 用：挪到第几个位置（都从 0 开始）')
    ..addOption('volume', help: 'bgm 用：配乐音量；unit audio 用：素材原声压到几成（都是 0~1）')
    ..addFlag('remove', help: 'bgm 用：删掉从 --from 开始的那一段')
    ..addOption(
      'preset',
      help:
          'subtitle 用：字幕样式预设。'
          'whiteBox / blurBox 能盖住素材自带的烧录字幕',
    )
    ..addOption('bottom', help: 'subtitle 用：字幕距画面底部的比例（如 0.22）')
    ..addOption('font', help: 'subtitle 用：字号占画面高度的比例（如 0.034）')
    ..addFlag('probe', help: 'candidates 用：探一下每条候选多长、选它会变速多少（慢一些）')
    ..addOption('video', help: 'peek 用：要看哪个视频文件')
    ..addOption('at', help: 'peek 用：看第几毫秒（缺省 1000）')
    ..addOption('ats', help: 'peek 用：一次看好几个时间点，逗号分隔')
    ..addOption(
      'exclude-projects',
      help:
          'candidates 用：排除这些项目的素材（逗号分隔的项目 id）。'
          '替换裂变常用 --exclude-projects <原片项目> 换掉原来那批画面',
    )
    ..addOption('page', help: 'candidates 用：第几页（从 1 开始）')
    ..addOption(
      'tag-mode',
      defaultsTo: 'or',
      help: 'candidates 用：标签检索 and（全满足）| or（任一）',
    )
    ..addOption('dir', help: 'skill --install 用：装到指定技能目录（不认默认目录的 Agent 自报）')
    ..addOption('name', help: 'blank create / ui new-task 用：任务名')
    ..addOption('resolution', help: 'export 用：短边 480/720/1080/1440/2160')
    ..addOption('fps', help: 'export 用：24/25/30/50/60')
    ..addOption('bitrate', help: 'export 用：recommended/higher/lower 或 kbps 数字')
    ..addOption('codec', help: 'export 用：h264/hevc')
    ..addOption('format', help: 'export 用：mp4/mov')
    ..addOption(
      'tags',
      help:
          'blank tags 用：标签，逗号分隔。'
          'script shots 也用它：这次检索带哪些标签'
          '（不给就用参考镜打出来的；给空串就不带标签约束）',
    )
    ..addOption('external', help: 'analyze 用：哪几步交给调用方做（segment,tag）')
    ..addFlag('help', abbr: 'h', negatable: false, help: '显示这份用法');

  final ArgResults parsed;
  try {
    parsed = parser.parse(args);
  } on FormatException catch (e) {
    failWith('${e.message}\n\n${usageText(parser)}', code: exitBadUsage);
  }

  if (parsed['help'] as bool) {
    stdout.writeln(usageText(parser));
    exit(0);
  }
  if (parsed.rest.isEmpty) {
    failWith('缺少命令。\n\n${usageText(parser)}', code: exitBadUsage);
  }

  final command = parsed.rest.first;
  final rest = parsed.rest.skip(1).toList();

  final Directory dataDir;
  try {
    dataDir = resolveDataDir(override: parsed['data-dir'] as String?);
  } on StateError catch (e) {
    failWith(e.message, code: exitBadUsage);
  }

  // 人在 Agent 那头喊停（Ctrl+C）时**立刻放手**：撤掉在场状态与锁。
  //
  // 不这么做的话，人按了停止还要干等一分钟心跳超时才能自己动手——
  // 「随时插手」就成了一句空话。这正是站在实习生旁边最要紧的那件事：
  // 你说停，他就得马上把手拿开
  _installInterruptHandler(dataDir: dataDir, rest: rest);

  final code = switch (command) {
    'import' => await runImportCommand(
      rest: rest,
      dataDir: dataDir,
      tagGroups: parsed['tag-groups'] as String?,
      visual: parsed['visual'] as bool,
    ),
    'doctor' => await runDoctorCommand(
      dataDir: dataDir,
      out: stdout,
      err: stderr,
    ),
    'subtitle' => await runSubtitleCommand(
      rest: rest,
      dataDir: dataDir,
      visual: parsed['visual'] as bool,
      preset: parsed['preset'] as String?,
      bottomRatio: parsed['bottom'] as String?,
      fontRatio: parsed['font'] as String?,
    ),
    'peek' => await runPeekCommand(
      rest: rest,
      dataDir: dataDir,
      videoPath: parsed['video'] as String?,
      atMs: int.tryParse(parsed['at'] as String? ?? ''),
      atMsList: parsed['ats'] as String?,
      materials: parsed['materials'] as String?,
    ),
    'jianying' => await runJianyingCommand(
      rest: rest,
      dataDir: dataDir,
      visual: parsed['visual'] as bool,
    ),
    // voice generate <任务> 与 voice <任务>：前者真合成，后者只定方案
    'clean' => await runCleanCommand(
      rest: rest,
      dataDir: dataDir,
      confirmed: parsed['yes'] as bool,
    ),
    'bgm' => await runBgmCommand(
      rest: rest,
      dataDir: dataDir,
      visual: parsed['visual'] as bool,
      fromUnit: parsed['from'] as String?,
      toUnit: parsed['to'] as String?,
      materialIds: parsed['materials'] as String?,
      volume: parsed['volume'] as String?,
      remove: parsed['remove'] as bool,
      fetchMaterial: (id) async => (await BgmLibrary().search(
        pageSize: 200,
      )).items.where((m) => m.id == id).firstOrNull,
    ),
    'voice' =>
      rest.isNotEmpty && rest.first == 'generate'
          ? await runVoiceGenerateCommand(
              rest: rest.sublist(1),
              dataDir: dataDir,
              visual: parsed['visual'] as bool,
            )
          : await runVoiceCommand(
              rest: rest,
              dataDir: dataDir,
              units: parsed['units'] as String?,
              voiceId: parsed['voice'] as String?,
            ),
    'voices' => runVoicesCommand(),
    'tag-groups' => await runTagGroupsCommand(),
    'analyze' => await runAnalyzeCommand(
      rest: rest,
      dataDir: dataDir,
      visual: parsed['visual'] as bool,
      external: parsed['external'] as String?,
    ),
    'skill' => await runSkillCommand(
      rest: rest,
      install: parsed['install'] as bool,
      dir: parsed['dir'] as String?,
    ),
    'task-rename' => await runTaskRenameCommand(
      rest: rest,
      dataDir: dataDir,
      name: parsed['name'] as String?,
    ),
    'task-copy' => await runTaskCopyCommand(
      rest: rest,
      dataDir: dataDir,
      name: parsed['name'] as String?,
    ),
    'task-delete' => await runTaskDeleteCommand(
      rest: rest,
      dataDir: dataDir,
      yes: parsed['yes'] as bool,
    ),
    'ui' => await runUiCommand(
      rest: rest,
      dataDir: dataDir,
      mode: parsed['mode'] as String?,
      file: parsed['file'] as String?,
      tagGroups: parsed['tag-groups'] as String?,
      name: parsed['name'] as String?,
      module: parsed['module'] as String?,
    ),
    'review' => await runReviewCommand(
      rest: rest,
      dataDir: dataDir,
      items: parsed['items'] as String?,
      file: parsed['file'] as String?,
      visual: parsed['visual'] as bool,
    ),
    'blank' => await runBlankCommand(
      rest: rest,
      dataDir: dataDir,
      name: parsed['name'] as String?,
      tagGroups: parsed['tag-groups'] as String?,
      unit: int.tryParse(parsed['unit'] as String? ?? ''),
      tags: parsed['tags'] as String?,
    ),
    'unit' => await runUnitCommand(
      rest: rest,
      dataDir: dataDir,
      unit: int.tryParse(parsed['unit'] as String? ?? ''),
      shot: int.tryParse(parsed['shot'] as String? ?? ''),
      to: int.tryParse(parsed['to'] as String? ?? ''),
      tags: parsed['tags'] as String?,
      audio: parsed['audio'] as String?,
      text: parsed['text'] as String?,
      auto: parsed['auto'] as bool,
      volume: double.tryParse(parsed['volume'] as String? ?? ''),
      visual: parsed['visual'] == true,
    ),
    'todo' => await runTodoCommand(rest: rest, dataDir: dataDir),
    'script' => await runScriptCommand(
      rest: rest,
      dataDir: dataDir,
      searchTags: parsed['tags'] as String?,
      line: int.tryParse(parsed['line'] as String? ?? ''),
      file: parsed['file'] as String?,
      voiceId: parsed['voice'] as String?,
      outputDir: parsed['out'] as String?,
      visual: parsed['visual'] as bool,
      keyword: parsed['keyword'] as String?,
      materials: parsed['materials'] as String?,
      by: parsed['by'] as String?,
    ),
    'task' => await runTaskCommand(rest: rest, dataDir: dataDir),
    'tasks' => await runTasksCommand(dataDir: dataDir),
    // 接手用：每条任务干到哪了、下一步敲什么、现场有没有别人在动
    'status' => await runStatusCommand(
      rest: rest,
      dataDir: dataDir,
      json: parsed['json'] as bool,
    ),
    'open' => await runOpenCommand(rest: rest, dataDir: dataDir),
    'apply' => await runApplyCommand(
      rest: rest,
      dataDir: dataDir,
      file: parsed['file'] as String?,
      visual: parsed['visual'] as bool,
    ),
    'export' => await runExportCommand(
      rest: rest,
      dataDir: dataDir,
      outputDir: parsed['out'] as String?,
      resolution: parsed['resolution'] as String?,
      fps: parsed['fps'] as String?,
      bitrate: parsed['bitrate'] as String?,
      codec: parsed['codec'] as String?,
      format: parsed['format'] as String?,
      visual: parsed['visual'] as bool,
    ),
    'candidates' => await runCandidatesCommand(
      rest: rest,
      dataDir: dataDir,
      unitIndex: int.tryParse(parsed['unit'] as String? ?? ''),
      shotIndex: int.tryParse(parsed['shot'] as String? ?? ''),
      keyword: parsed['keyword'] as String?,
      excludeProjects: parsed['exclude-projects'] as String?,
      probeDurations: parsed['probe'] as bool,
      visual: parsed['visual'] as bool,
      page: int.tryParse(parsed['page'] as String? ?? '') ?? 1,
      tagMode: parsed['tag-mode'] as String,
    ),
    _ => failWith('未知命令：$command\n\n${usageText(parser)}', code: exitBadUsage),
  };
  exit(code);
}

/// 用法说明。抽出来是为了让「没给命令」「命令不认识」「-h」三条路
/// 给出同一份文本——三份各写各的迟早会漂
String usageText(ArgParser parser) =>
    '''
ishkafel —— 竖屏口播短视频工具的命令行入口

用法：ishkafel <命令> [参数]

命令：
  clean [--yes]    把盘上没主的东西清掉（不给 --yes 只报会删什么）
  status [<任务>]   **接手先看这条**：每条任务干到哪了、下一步敲什么、
                   现场有没有别人在动。打断之后接着干，全靠它
  doctor           开工前体检：AI 凭据、素材库登录、ffmpeg 是否都就位。
                   第一件事就该敲它——import 不需要凭据，能跑通不代表后面能跑
  bgm <task> [--from 0 --to 2 --materials 7,8] [--remove] [--volume 0.3]
                   给一段单元铺配乐。一段选好几首是互为备选，导出时轮流用
  voice <task> --units 0,2 --voice <音色 id>
                   给这几句换音色（只定方案，不立刻合成）
  voice generate <task>
                   把定好的音色真正合成。**只选不生成的话导出会被拦下**
  voices           有哪些音色可选（配音前先问人要哪个，别自己挑）
  tag-groups       当前企业下有哪些标签组（import 要用它的 id）
  import <视频> [--tag-groups <id,id>]
                   建任务。**标签组要在这一步定**——它是打标的受控词表，
                   没有它后面挑替换素材时会没有标签可用
  analyze <id> [--external=segment,tag]
                   跑分析。--external 指定哪几步由你来做——那时会停下来
                   输出待办，你做完用 apply 交回来。ASR 不可外包
  apply segment|tags <id> --file <json>
                   回填外部结果
  todo <id>        把当前欠着的那件外包待办再吐一遍（丢了输出时用，不重跑分析）
  skill [--install] [--dir <目录>]
                   给 Agent 的操作手册。--install 装成技能（缺省认
                   Claude Code / Codex 的目录；别家用 --dir 自报），
                   之后在任意文件夹、任意会话都生效
  tasks            列出所有任务（短编号/id/名字/状态）。用户说「#12」时
                   用这条把编号换成 id
  task <id>        任务全貌（单元、镜头、标签、导出历史）。<id> 处也可以
                   直接给短编号（#12 或 12）——所有带 <id> 的命令都认
  candidates <id> --unit <i> [--shot <j>]
                   候选素材与上下文（本单元台词、相邻镜头及其已选素材）
  open <id>        把 app 弹出来并落到这个任务的工作台
  review <id>      把 app 弹出来进**审核模式**：人过一遍你挑的候选、勾选去留。
                   确认后 task <id> 里的方案就是最终结果，等用户发话再继续
  task-rename <id> --name "新名字"     给任务改名
  task-delete <id> --yes
                   删掉一条任务，连同它的素材/配音/预览产物。不可逆
  ui new-task --mode <replace|blank|script> --tag-groups <id,id> [--file <原片>]
                   **当着人的面**新建任务：软件弹出来、向导打开、字段填上、
                   点创建。人在旁边看着时用它；人不在场用 script new 更快
  ui open <id> [--module director|workbench|review]
                   **把界面叫到这条任务上**。可视模式下每一步开工前都该
                   在现场——命令自己也会确认，这条是给你的显式入口。
                   已经在那一页就直接返回，不会把页面弹来弹去
  ui tasks         把界面支开、退回任务列表。**可视模式下一般用不着**：
                   撞上界面的锁时命令会自动请它让位（人留在那一页看着）。
                   支开就等于关掉了可视化现场，得用 ui open 才叫得回来
  review list <id> 列出待审候选（带编号，直接能喂给 drop/keep）
  review drop <id> --items 0:-:100,1:2:202
                   替人剔掉这几条——人在审片台看着说「删掉哪几条」时用它
  review keep <id> --items 0:-:100      把剔掉的恢复回来
  apply plans <id> --file <json>
                   提交完整方案列表（每条都是整体设计过的，不做笛卡尔积）
  export <id> [--out <目录>] [--resolution N] [--fps N]
              [--bitrate recommended|higher|lower|<kbps>]
              [--codec h264|hevc] [--format mp4|mov]
                   按已提交的方案逐条导出。规格缺省 1080/30fps/推荐码率
  blank create --name <名> --tag-groups <id,id>
                   建空白任务（不用原片，从素材拼），自带 4 个空分子
  blank add|remove|tags <id> [--unit i] [--tags a,b]
                   空白任务的分子增删与打标（标签必须在词表内）

通用参数：
${parser.usage}
''';

/// Ctrl+C / kill 时把这个任务的在场状态与锁撤干净，人立刻能接手。
///
/// 任务 id 从命令参数里认（`script apply shots <task>` 这类第二个位置），
/// 认不出就只撤在场目录里跟本进程有关的那一份——宁可少撤，不要撤错别人的
void _installInterruptHandler({
  required Directory dataDir,
  required List<String> rest,
}) {
  void bail(ProcessSignal signal) {
    for (final id in rest.where((a) => !a.startsWith('-'))) {
      try {
        clearAgentPresence(dataDir: dataDir, taskId: id);
        clearAgentAck(dataDir: dataDir, taskId: id);
        TaskLockFile(dataDir: dataDir, taskId: id).release('Agent');
      } catch (_) {}
    }
    stderr.writeln('已停止，界面可以动了。');
    exit(130); // 130 = 被 SIGINT 中断，与 shell 的惯例一致
  }

  ProcessSignal.sigint.watch().listen(bail);
  if (!Platform.isWindows) ProcessSignal.sigterm.watch().listen(bail);
}
