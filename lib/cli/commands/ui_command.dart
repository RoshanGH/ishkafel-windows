import 'dart:io';

import '../../core/storage/agent_request.dart';
import '../../core/storage/file_task_repository.dart';
import '../../core/storage/agent_presence.dart';
import '../../core/storage/task_seq.dart';
import '../../core/storage/ui_action.dart';
import '../../core/storage/ui_wake.dart';
import '../../core/storage/ui_where.dart';
import '../cli_output.dart';
import '../app_locator.dart';

/// `ishkafel ui new-task --mode script --tag-groups 1261` ——
/// **让界面当着人的面新建任务**。
///
/// 和 `script new` / `blank create` 的区别不是结果，是**过程**：
/// 那两条在后台把任务建好，界面一动不动；这一条会把软件拉起来、
/// 真的弹出新建向导、真的把来源和标签组填上、真的点「创建」。
///
/// 为什么值得单独有一条：严格交付的活儿，人要看得见每一步才敢信。
/// 前面走错一两步，后面差很远——只有当着人的面稳稳跑过很多次，
/// 人才会放心切到静默模式。人不在场时用 `script new` 就好，那条更快。
Future<int> runUiCommand({
  required List<String> rest,
  required Directory dataDir,
  String? mode,
  String? file,
  String? tagGroups,

  /// 任务名。不给就用软件的默认命名（「脚本 08-27 20:57」这种）
  String? name,

  /// `ui open` 要去哪个模块：`director` / `workbench` / `review`。
  /// 不给就按任务类型选（脚本成片进编导台，其余进工作台）
  String? module,
  String? holder,
  Future<ProcessResult> Function(String, List<String>)? run,
  Map<String, String>? env,

  /// 测试注入：app 在不在。真机走默认（看目录存不存在）
  bool Function(String path)? appExists,
  Duration waitForUi = const Duration(seconds: 90),

  /// 冷启动后等多久再下单。界面那头也有一道同样的缓冲
  Duration coldStartWait = const Duration(seconds: 6),
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  const subs = ['new-task', 'tasks', 'open'];
  if (rest.isEmpty || !subs.contains(rest.first)) {
    sink.writeln(
      '用法：\n'
      '  ishkafel ui new-task --mode <replace|blank|script> '
      '--tag-groups <id,id> [--file <原片>]\n'
      '  ishkafel ui open <任务> [--module director|workbench|review]\n'
      '      把界面叫到这条任务上。**可视模式下每一步开工前都该在现场**\n'
      '  ishkafel ui tasks\n'
      '      把界面支开、退回任务列表。可视模式下一般用不着：撞上界面的锁\n'
      '      时命令会自动请它让位（人留在那一页看着），不需要你先支开它。\n'
      '      支开了就等于关掉了可视化现场，要再用 ui open 才叫得回来',
    );
    return exitBadUsage;
  }
  if (rest.first == 'open') {
    return _openTaskPage(
      rest: rest.sublist(1),
      dataDir: dataDir,
      module: module,
      run: run,
      env: env,
      appExists: appExists,
      waitForUi: waitForUi,
      out: out,
      err: err,
    );
  }
  if (rest.first == 'tasks') {
    return _backToTaskList(
      dataDir: dataDir,
      run: run,
      env: env,
      appExists: appExists,
      waitForUi: waitForUi,
      out: out,
      err: err,
    );
  }

  final parsed = WizardMode.parse(mode);
  if (parsed == null) {
    // 报错里的词必须是现在的词：人照着报错去敲，写出来的就是这几个。
    // 这儿曾经还写着废弃的 renew，而手册早改成 replace 了
    sink.writeln(
      '--mode 要是 replace / blank / script 之一：\n'
      '  replace  替换裂变，拿一条现成的片子换画面（要 --file）\n'
      '  blank    替换裂变但不用原片：拼画面、没有台词与配音\n'
      '  script   脚本成片，从台词造一条新片',
    );
    return exitBadUsage;
  }
  final ids = <int>[
    for (final piece in (tagGroups ?? '').split(','))
      ?int.tryParse(piece.trim()),
  ];
  // 先在本地拦一道：让人看着向导弹出来又因为参数不对关掉，比不弹更糟
  final issues = validateWizardFill(
    mode: parsed,
    filePath: file,
    tagGroupIds: ids,
  );
  if (issues.isNotEmpty) {
    for (final i in issues) {
      sink.writeln('· $i');
    }
    return exitBadUsage;
  }

  // 界面没开就先拉起来——这条命令的意义就是让人看见
  final exec = run ?? Process.run;
  final appPath = resolveAppPath(env: env, exists: appExists);
  // 冷启动的话，界面要几秒才起得来。先探一眼它在不在，好决定等多久
  final wasRunning = appPath != null && await _appIsRunning(exec, appPath);
  final failure = await launchApp(run: exec, env: env, exists: appExists);
  if (failure != null) {
    sink.writeln(failure);
    return exitEnv;
  }
  if (!wasRunning) {
    // 刚拉起来的软件不能立刻使唤：界面 1.5 秒就能接单，但那时播放器的
    // 底层还没初始化完，建完任务一进编导台就会整个 abort（真机撞过两次）。
    // 界面那头也有一道缓冲，这里是第二道——两边都等，别指望其中一边
    sink.writeln('软件刚启动，等它就绪…');
    await Future<void>.delayed(coldStartWait);
  }

  final id = writeAgentRequest(
    dataDir: dataDir,
    taskId: globalPresenceSlot,
    kind: UiAction.wizardOpen.wire,
    payload: {
      'mode': parsed.wire,
      'filePath': ?file,
      if ((name ?? '').trim().isNotEmpty) 'name': name!.trim(),
      'tagGroupIds': ids,
    },
  );
  sink.writeln('已让界面打开新建任务向导，正在等它建完…');
  final result = await waitForAgentRequest(
    dataDir: dataDir,
    taskId: globalPresenceSlot,
    id: id,
    timeout: waitForUi,
  );
  if (result == null) {
    // 这里超时是**真失败**：活儿没干。报成功的话人会以为任务建好了
    sink.writeln(
      '界面没有回应（等了 ${waitForUi.inSeconds} 秒）。'
      '可能它没开、或者停在别的页面上——让用户看一眼',
    );
    return exitEnv;
  }
  if (!result.ok) {
    sink.writeln('没有建成：${result.message}');
    return exitFailed;
  }
  // 界面把它**真正建出来的那条**回传了，不再去任务库里翻「最新的那条」猜。
  // 猜的后果真机上撞到过：授权框挡住创建、任务压根没建成，
  // 猜出来的是上一次的任务，还报「已经建好了」
  final newId = '${result.payload['taskId'] ?? ''}';
  if (newId.isEmpty) {
    sink.writeln(
      '界面说建好了，却没报出是哪一条任务。'
      '用 ishkafel tasks 看一眼，别照着猜的 id 往下走',
    );
    return exitFailed;
  }
  final created = await FileTaskRepository(dataDir).findById(newId);
  final kind = '${result.payload['kind'] ?? ''}';
  emitJson({
    'ok': true,
    'via': 'ui',
    'message': result.message,
    'id': newId,
    if (created?.seq != null) 'seq': created!.seq,
    if (created != null) 'name': created.name,
    'kind': kind,
    // **下一步要跟着任务类型走**：以前恒定给 script show，
    // 而替换裂变任务照着跑会被 CLI 自己拒绝（验收 Agent 撞到）
    // 界面这会儿正停在新任务上占着锁，而下一步多半要写这条任务。
    // 不说的话 Agent 会直接撞上「人（编导台）正在操作这个任务」，
    // 而它看不出这是常态、更看不出出路在哪（验收 Agent 卡在这儿过）
    'note':
        '界面正停在这条任务上，它占着写锁。接下来要写这条任务的话'
        '（script extract / analyze 这些），先让界面退回列表：'
        'ishkafel ui tasks',
    'next': switch (kind) {
      'script' => 'ishkafel ui tasks && ishkafel script extract $newId <参考片>',
      'blank' => 'ishkafel blank tags $newId --unit 0 --tags <标签>',
      _ => 'ishkafel task $newId',
    },
  }, out: out);
  return 0;
}

/// app 是不是已经在跑。冷启动和已运行要等的时间差很多
Future<bool> _appIsRunning(
  Future<ProcessResult> Function(String, List<String>) exec,
  String appPath,
) async {
  try {
    if (Platform.isWindows) {
      final r = await exec('tasklist.exe', [
        '/FI',
        'IMAGENAME eq ishkafel.exe',
        '/FO',
        'CSV',
        '/NH',
      ]);
      return r.exitCode == 0 &&
          '${r.stdout}'.toLowerCase().contains('ishkafel.exe');
    }
    final r = await exec('pgrep', ['-f', '$appPath/Contents/MacOS/']);
    return r.exitCode == 0 && '${r.stdout}'.trim().isNotEmpty;
  } catch (_) {
    return false;
  }
}

/// `ishkafel ui tasks` —— 让界面退回任务列表，**松开它占着的那把锁**。
///
/// 可视模式下这是 Agent 唯一的解锁出路。`ui new-task` 建完任务后界面就
/// 停在那条任务上，而下一步（`script extract` / `analyze`）必须写它——
/// 「建完立刻干活」这条最自然的路因此走不通。
///
/// 以前的绕法是 `open <另一条任务>` 把界面支开。那只在**恰好还有第二条
/// 任务**时成立：验收 Agent 就是这么绕的，等它把老任务删光，就彻底卡死了。
Future<int> _backToTaskList({
  required Directory dataDir,
  Future<ProcessResult> Function(String, List<String>)? run,
  Map<String, String>? env,
  bool Function(String path)? appExists,
  Duration waitForUi = const Duration(seconds: 90),
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  final failure = await launchApp(
    run: run ?? Process.run,
    env: env,
    exists: appExists,
  );
  if (failure != null) {
    sink.writeln(failure);
    return exitEnv;
  }
  final id = writeAgentRequest(
    dataDir: dataDir,
    taskId: globalPresenceSlot,
    kind: UiAction.tasksOpen.wire,
    payload: const {},
  );
  final result = await waitForAgentRequest(
    dataDir: dataDir,
    taskId: globalPresenceSlot,
    id: id,
    timeout: waitForUi,
  );
  if (result == null) {
    sink.writeln(
      '界面没有回应（等了 ${waitForUi.inSeconds} 秒）。'
      '它可能没开——那样也就没有锁挡着，直接往下走试试',
    );
    return exitEnv;
  }
  if (!result.ok) {
    sink.writeln('退不回列表：${result.message}');
    return exitFailed;
  }
  emitJson({'ok': true, 'via': 'ui', 'message': result.message}, out: out);
  return 0;
}

/// `ishkafel ui open <任务> [--module …]` —— **把界面叫到现场**。
///
/// 可视模式此前只有出口没有入口：[UiAction.tasksOpen] 能把界面支开，
/// 却没有任何办法把它叫回来。真机上 Agent 为了拿写锁调了 `ui tasks`，
/// 界面退到任务列表，此后二十句配音全程在列表页上以文字滚过——播报没
/// 说谎，可视化却结束了，而且回不去。产品负责人的话：「它并不判断当前
/// 是否是它执行的那个页面，这样的话可视化的意义就没有了。」
///
/// 各条命令自己也会在每一步开工前确认现场（见 `AgentStage`），这条命令
/// 是给 Agent 的显式入口：接着干之前先把人带回该看的那一页。
Future<int> _openTaskPage({
  required List<String> rest,
  required Directory dataDir,
  String? module,
  Future<ProcessResult> Function(String, List<String>)? run,
  Map<String, String>? env,
  bool Function(String path)? appExists,
  Duration waitForUi = const Duration(seconds: 90),
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  if (rest.isEmpty) {
    sink.writeln('要指定任务：ishkafel ui open <任务 id>');
    return exitBadUsage;
  }
  const modules = ['director', 'workbench', 'review'];
  if (module != null && !modules.contains(module)) {
    // 写错了就点名。默默去个别的地方，人对着不相干的页面等半天
    sink.writeln('--module 要是 ${modules.join(' / ')} 之一');
    return exitBadUsage;
  }
  final task = await resolveTaskRef(FileTaskRepository(dataDir), rest.first);
  if (task == null) {
    sink.writeln('没有这个任务：${rest.first}');
    return exitNotFound;
  }
  final target = module ?? (task.isScript ? 'director' : 'workbench');
  // 已经在这一页就别再唤醒：唤醒会把页面关掉重开，滚动位置、展开的镜头
  // 全丢，人看到的是画面弹回第一行
  if (readUiWhere(dataDir)?.isOn(module: target, taskId: task.id) == true) {
    emitJson({
      'ok': true,
      'already': true,
      'module': target,
      'task': task.id,
    }, out: out);
    return 0;
  }
  final failure = await launchApp(
    run: run ?? Process.run,
    env: env,
    exists: appExists,
  );
  if (failure != null) {
    sink.writeln(failure);
    return exitEnv;
  }
  writeUiWake(dataDir, task.id, review: target == 'review', module: target);
  // 等它真的到位再返回：命令一返回就接着干活的话，头几步又落在空场上
  final deadline = DateTime.now().add(waitForUi);
  while (DateTime.now().isBefore(deadline)) {
    if (readUiWhere(dataDir)?.isOn(module: target, taskId: task.id) == true) {
      emitJson({'ok': true, 'module': target, 'task': task.id}, out: out);
      return 0;
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  // 没等到不算失败：软件可能正在冷启动，唤醒文件躺在那儿，它起来就会落位
  sink.writeln(
    '界面还没落到「$target」（等了 ${waitForUi.inSeconds} 秒）。'
    '唤醒已经写下了，软件起来就会过去。',
  );
  emitJson({
    'ok': true,
    'module': target,
    'task': task.id,
    'landed': false,
  }, out: out);
  return 0;
}
