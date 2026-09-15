import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/agent_stage.dart';
import 'package:ishkafel/core/storage/agent_presence.dart';
import 'package:ishkafel/core/storage/ui_wake.dart';

/// 两种模式不是技术开关，是两种使用场景：
/// 静默 = 人不在场，跑完看结果；可视 = 人站在旁边看着它干活。
void main() {
  group('全局槽', _globalSlotTests);

  late Directory dir;
  final launched = <List<String>>[];

  setUp(() async {
    launched.clear();
    dir = await Directory.systemTemp.createTemp('stage');
  });
  tearDown(() => dir.delete(recursive: true));

  Future<ProcessResult> fakeOpen(String exe, List<String> args) async {
    launched.add([exe, ...args]);
    return ProcessResult(1, 0, '', '');
  }

  AgentStage stage(AgentStageMode mode) => AgentStage(
    appExists: (_) => true,
    mode: mode,
    dataDir: dir,
    taskId: 't1',
    stepTimeout: const Duration(milliseconds: 120),
    run: fakeOpen,
  );

  test('静默模式：不弹窗、不写在场状态——那条路径要保持原来的速度', () async {
    await stage(AgentStageMode.silent).begin('挑镜头');
    expect(launched, isEmpty);
    expect(readAgentPresence(dataDir: dir, taskId: 't1'), isNull);
  });

  test('可视模式：把软件拉起来，并让它落到这个任务上', () async {
    await stage(AgentStageMode.visual).begin('挑镜头');
    expect(
      launched.single.join(' '),
      contains(Platform.isWindows ? r'Ishkafel\ishkafel.exe' : 'open -a'),
    );
    // 「去哪个任务」走唤醒文件而不是启动参数——app 已经在跑时启动参数
    // 会被静默丢弃（open 命令那边真机撞到过）
    expect(
      File('${dir.path}/ui_wake.json').existsSync(),
      isTrue,
      reason: '冷启动、热启动要走同一条路',
    );
  });

  test('可视模式：每一步都说清在做什么、界面该看哪儿', () async {
    final s = stage(AgentStageMode.visual);
    await s.begin('开工');
    await s.show(
      '正在给第 10 句挑镜头',
      focus: const AgentFocus(
        module: 'director',
        lineIndex: 9,
        panel: AgentPanel.findShots,
      ),
    );
    final p = readAgentPresence(dataDir: dir, taskId: 't1')!;
    expect(p.action, '正在给第 10 句挑镜头');
    expect(p.focus!.module, 'director');
    expect(p.focus!.panel, AgentPanel.findShots);
    expect(p.step, greaterThan(1), reason: '步号要递增，界面按它回执');
  });

  test('界面回执了就立刻往下走，不白等', () async {
    final s = stage(AgentStageMode.visual);
    // 界面很快就展示完（每一步都马上回执）
    unawaited(() async {
      for (var i = 1; i <= 3; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        writeAgentAck(dataDir: dir, taskId: 't1', step: i);
      }
    }());
    final watch = Stopwatch()..start();
    await s.begin('开工');
    await s.show('第二步');
    watch.stop();
    expect(
      watch.elapsedMilliseconds,
      lessThan(200),
      reason: '界面跟得上就别拖着——节奏由界面决定，不是猜时间',
    );
  });

  test('界面没开：等一下就照常往下跑，不把正事卡死', () async {
    final s = stage(AgentStageMode.visual);
    final watch = Stopwatch()..start();
    await s.begin('开工'); // 没人回执
    watch.stop();
    expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(100));
    expect(
      readAgentPresence(dataDir: dir, taskId: 't1'),
      isNotNull,
      reason: '状态还是要写——万一界面晚一点开起来，它能看到',
    );
  });

  test('换模块就把人带过去——他可能停在任务列表，也可能停在别的模块', () async {
    final s = stage(AgentStageMode.visual);
    await s.begin(
      '开工',
      focus: const AgentFocus(module: 'director', lineIndex: 0),
    );
    File('${dir.path}/ui_wake.json').deleteSync(); // 界面消费掉了

    await s.show(
      '去工作台看候选',
      focus: const AgentFocus(module: 'workbench', unitIndex: 3),
    );
    final wake = File('${dir.path}/ui_wake.json').readAsStringSync();
    expect(wake, contains('workbench'), reason: '跨模块跳转走唤醒文件，模块内部定位走在场状态');
  });

  test('同一个模块里连着做几步：不重复唤醒（别把界面弹来弹去）', () async {
    final s = stage(AgentStageMode.visual);
    await s.begin(
      '开工',
      focus: const AgentFocus(module: 'director', lineIndex: 0),
    );
    File('${dir.path}/ui_wake.json').deleteSync();

    await s.show(
      '还在编导台',
      focus: const AgentFocus(module: 'director', lineIndex: 5),
    );
    expect(File('${dir.path}/ui_wake.json').existsSync(), isFalse);
  });

  test('收工：在场状态与回执都撤掉，人立刻能动手', () async {
    final s = stage(AgentStageMode.visual);
    await s.begin('开工');
    s.end();
    expect(readAgentPresence(dataDir: dir, taskId: 't1'), isNull);
    expect(readAgentAck(dataDir: dir, taskId: 't1'), -1);
  });

  test('模式可以由环境变量给——Agent 把它贯穿整个会话', () {
    expect(
      AgentStageMode.from(env: {'ISHKAFEL_VISUAL': '1'}),
      AgentStageMode.visual,
    );
    expect(AgentStageMode.from(env: const {}), AgentStageMode.silent);
  });
}

void unawaited(Future<void> f) {}

/// 全局槽：**没有任务归属的活儿**（导入时任务还没建出来）。
///
/// 这一层不能跳转——没有任务可跳。只把软件拉起来，状态显示在任务列表页上。
void _globalSlotTests() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('stage_global_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('全局槽不写唤醒文件——没有任务可跳，跳了只会把人甩到别处', () async {
    final calls = <List<String>>[];
    final stage = AgentStage(
      appExists: (_) => true,
      mode: AgentStageMode.visual,
      dataDir: dir,
      taskId: globalPresenceSlot,
      stepTimeout: const Duration(milliseconds: 80),
      run: (bin, args) async {
        calls.add([bin, ...args]);
        return ProcessResult(0, 0, '', '');
      },
    );
    await stage.begin('正在导入 a.mp4');
    // 软件照样弹出来
    expect(
      calls.single.first,
      Platform.isWindows ? endsWith(r'Ishkafel\ishkafel.exe') : 'open',
    );
    expect(consumeUiWake(dir), isNull);
    // 状态照样报出去，任务列表页盯的就是它
    final presence = readAgentPresence(
      dataDir: dir,
      taskId: globalPresenceSlot,
    );
    expect(presence!.action, '正在导入 a.mp4');
    stage.end();
    expect(readAgentPresence(dataDir: dir, taskId: globalPresenceSlot), isNull);
  });

  /// 每一步都握手（界面展示完才回执）是为了让人跟得上，但界面**没开着**的时候
  /// 每步都得干等超时——一条命令报五步就白等 25 秒，而 Agent 什么也没等到。
  ///
  /// 静默模式下压根不该等；可视模式下连着没人应，就认了：后面几步直接过。
  group('界面没人应的时候不能一步步干等', () {
    test('连着两步没回执，后面就不等了', () async {
      final dir = Directory.systemTemp.createTempSync('nowait');
      final stage = AgentStage(
        mode: AgentStageMode.visual,
        dataDir: dir,
        taskId: 't1',
        appExists: (_) => true,
        run: (_, _) async => ProcessResult(0, 0, '', ''),
        stepTimeout: const Duration(milliseconds: 60),
      );

      for (var i = 0; i < 6; i++) {
        await stage.show('第 $i 步');
      }

      // **数「等了几次」，不拿墙钟量**：并发跑测试时机器一忙，
      // 两次超时加调度开销就能顶穿任何一个墙钟阈值——这条用例为此
      // 假红过三次（2026-09-09）。要验的性质本来就是次数，不是耗时。
      expect(
        stage.waitedCount,
        2,
        reason:
            '前两步各等一个超时，后面四步该直接过——'
            '六步全等的话人和 Agent 都在白耗',
      );
      dir.deleteSync(recursive: true);
    });
  });
}
