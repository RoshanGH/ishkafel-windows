import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/commands/open_command.dart';
import 'package:ishkafel/core/storage/ui_wake.dart';

/// `ishkafel open <task>` —— 把 GUI 弹出来并落到这个任务。
///
/// 这是「Agent 做到某一步、让我审核」的落地方式。因为 GUI 和 CLI 读同一份
/// 任务数据，**不需要任何进程间通信**——只要把 app 拉起来、告诉它开哪个任务。
void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ishkafel_open_');
    Directory('${dir.path}/tasks').createSync(recursive: true);
    // open 现在通过仓储解析任务（顺带支持 #编号），档要能被 fromJson 读出
    File('${dir.path}/tasks/t1.json').writeAsStringSync(
      '{"id":"t1","name":"测试","sourcePath":"/v/t1.mp4","status":"ready",'
      '"createdAt":"2026-08-19T00:00:00Z","updatedAt":"2026-08-19T00:00:00Z"}',
    );
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('用 open -a 把 app 拉起来，并把任务 id 作为参数传过去', () async {
    final calls = <List<String>>[];
    final code = await runOpenCommand(
      rest: ['t1'],
      dataDir: dir,
      env: const {},
      appExists: (_) => true,
      run: (bin, args) async {
        calls.add([bin, ...args]);
        return ProcessResult(0, 0, '', '');
      },
    );
    expect(code, 0);
    expect(
      calls.single.first,
      Platform.isWindows ? endsWith(r'Ishkafel\ishkafel.exe') : 'open',
    );
    // 意图走唤醒文件：--args 只在冷启动生效，app 在跑时会被静默丢弃
    expect(calls.single.any((a) => a.contains('--task')), isFalse);
    expect(consumeUiWake(dir)!.taskId, 't1');
  });

  test('app 装在别处时认 ISHKAFEL_APP', () async {
    final calls = <List<String>>[];
    await runOpenCommand(
      rest: ['t1'],
      dataDir: dir,
      appExists: (_) => true,
      env: Platform.isWindows
          ? const {'ISHKAFEL_APP': r'C:\别处\Ishkafel'}
          : const {'ISHKAFEL_APP': '/tmp/别处/ishkafel.app'},
      run: (bin, args) async {
        calls.add([bin, ...args]);
        return ProcessResult(0, 0, '', '');
      },
    );
    expect(
      calls.single.join(' '),
      contains(Platform.isWindows ? r'C:\别处\Ishkafel' : '/tmp/别处/ishkafel.app'),
    );
  });

  test('任务不存在时不去拉 app——弹出一个空窗口只会让人困惑', () async {
    var launched = false;
    final code = await runOpenCommand(
      rest: ['不存在'],
      dataDir: dir,
      env: const {},
      appExists: (_) => true,
      run: (bin, args) async {
        launched = true;
        return ProcessResult(0, 0, '', '');
      },
    );
    expect(code, isNot(0));
    expect(launched, isFalse);
  });

  test('没给任务 id 时说用法', () async {
    final err = StringBuffer();
    final code = await runOpenCommand(
      rest: const [],
      dataDir: dir,
      env: const {},
      appExists: (_) => true,
      err: err,
      run: (bin, args) async => ProcessResult(0, 0, '', ''),
    );
    expect(code, isNot(0));
    expect(err.toString(), contains('用法'));
  });

  test('拉起失败时如实报错，不假装成功', () async {
    final err = StringBuffer();
    final code = await runOpenCommand(
      rest: ['t1'],
      dataDir: dir,
      env: const {},
      appExists: (_) => true,
      err: err,
      run: (bin, args) async => ProcessResult(0, 1, '', 'app not found'),
    );
    expect(code, isNot(0));
    expect(err.toString(), contains('打不开'));
  });

  group('GUI 侧认这个参数', () {
    test('认得出 --task=，认不出时返回 null', () {
      expect(initialTaskIdFrom(['--task=abc']), 'abc');
      expect(initialTaskIdFrom(['--other', '--task=x1']), 'x1');
      expect(initialTaskIdFrom(['--task=']), isNull);
      expect(initialTaskIdFrom(const []), isNull);
      expect(initialTaskIdFrom(['task=abc']), isNull);
    });
  });
}
