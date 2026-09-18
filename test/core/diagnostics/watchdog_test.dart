import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/diagnostics/watchdog.dart';
import 'package:ishkafel/core/log/app_log.dart';

void main() {
  test('桌面进程仅继承系统 PSModulePath 时也及时采样', () async {
    final directory = await Directory(
      'D:/Ishkafel/Diagnostics',
    ).createTemp('watchdog-desktop-environment-');
    final windows = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final programFiles =
        Platform.environment['ProgramFiles'] ?? r'C:\Program Files';
    final process = await Process.start(
      'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-WindowStyle',
        'Hidden',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        File('scripts/windows/diagnostic_watchdog.ps1').absolute.path,
        '-AppPid',
        '$pid',
        '-LogDirectory',
        directory.path,
      ],
      environment: {
        'PSModulePath':
            '$programFiles\\WindowsPowerShell\\Modules;'
            '$windows\\system32\\WindowsPowerShell\\v1.0\\Modules',
      },
    );
    process.stdout.drain<void>();
    process.stderr.drain<void>();
    await process.stdin.close();
    addTearDown(() async {
      process.kill();
      await process.exitCode;
      await directory.delete(recursive: true);
    });
    final report = File('${directory.path}/watchdog.json');
    final deadline = Stopwatch()..start();
    while (!await report.exists() && deadline.elapsedMilliseconds < 2500) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(
      await report.exists(),
      isTrue,
      reason: '桌面启动不能依赖终端注入的 PowerShell 7 模块路径',
    );
    final samples = jsonDecode(await report.readAsString()) as List;
    expect(samples.last['pid'], pid);
    expect(samples.last['workingSetBytes'], greaterThan(0));
  }, skip: !Platform.isWindows);

  test('脚本失败给出阶段与错误类型而不输出任意环境内容', () async {
    final directory = await Directory(
      'D:/Ishkafel/Diagnostics',
    ).createTemp('watchdog-script-failure-');
    addTearDown(() => directory.delete(recursive: true));
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-WindowStyle',
      'Hidden',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      File('scripts/windows/diagnostic_watchdog.ps1').absolute.path,
      '-AppPid',
      '2147483647',
      '-LogDirectory',
      directory.path,
    ]);
    expect(result.exitCode, 1);
    expect(result.stderr, contains('stage=attach'));
    expect(result.stderr, contains('type='));
    expect(result.stderr, isNot(contains(directory.path)));
  }, skip: !Platform.isWindows);

  test('监测进程提前退出时报告退出码与有界脱敏错误', () async {
    final directory = await Directory(
      'D:/Ishkafel/Diagnostics',
    ).createTemp('watchdog-failed-launch-');
    final script = File('${directory.path}/failure.ps1');
    await script.writeAsString(
      "[Console]::Error.WriteLine('watchdog-stage=init token=private-value');\n"
      "[Console]::Error.WriteLine(('x' * 10000));\nexit 7\n",
    );
    final lines = <String>[];
    final previousSink = AppLog.sink;
    AppLog.sink = lines.add;
    addTearDown(() async {
      AppLog.sink = previousSink;
      await directory.delete(recursive: true);
    });
    final elapsed = Stopwatch()..start();
    await startDiagnosticWatchdog(directory, script: script);
    expect(lines.join('\n'), contains('exit=7'));
    expect(lines.join('\n'), contains('watchdog-stage=init'));
    expect(lines.join('\n'), isNot(contains('private-value')));
    expect(lines.join('\n').length, lessThan(5000));
    expect(elapsed.elapsed, lessThan(const Duration(seconds: 4)));
  }, skip: !Platform.isWindows);

  for (final previousReport in ['[]', '[', '{}', '[null]']) {
    test('应用启动入口忽略旧异常报告 $previousReport 并确认本次采样', () async {
      final directory = await Directory.systemTemp.createTemp(
        'ishkafel-watchdog-launch-',
      );
      final lines = <String>[];
      final previousSink = AppLog.sink;
      AppLog.sink = lines.add;
      // 上一次运行留下空报告时，应等本次采样，不能把解析异常当启动失败。
      await File(
        '${directory.path}/watchdog.json',
      ).writeAsString(previousReport);
      int? monitorPid;
      addTearDown(() async {
        AppLog.sink = previousSink;
        if (monitorPid != null) Process.killPid(monitorPid);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await directory.delete(recursive: true);
      });
      await startDiagnosticWatchdog(
        directory,
        script: File('scripts/windows/diagnostic_watchdog.ps1'),
      );
      expect(
        lines.any((line) => line.contains('已启动并确认采样')),
        isTrue,
        reason: lines.join('\n'),
      );
      final samples =
          jsonDecode(
                await File('${directory.path}/watchdog.json').readAsString(),
              )
              as List;
      monitorPid = samples.last['watchdogPid'] as int;
      expect(samples.last['pid'], pid);
      expect(samples.last['workingSetBytes'], greaterThan(0));
      if (previousReport == '[]') {
        await Future<void>.delayed(const Duration(milliseconds: 5200));
        final later =
            jsonDecode(
                  await File('${directory.path}/watchdog.json').readAsString(),
                )
                as List;
        expect(later.length, greaterThan(samples.length));
        expect(later.last['pid'], pid);
      }
    }, skip: !Platform.isWindows);
  }

  test('Windows 监测脚本及时写出首个真实进程样本', () async {
    final directory = await Directory.systemTemp.createTemp(
      'ishkafel-watchdog-test-',
    );
    final process = await Process.start('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-WindowStyle',
      'Hidden',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      File('scripts/windows/diagnostic_watchdog.ps1').absolute.path,
      '-AppPid',
      '$pid',
      '-LogDirectory',
      directory.path,
    ]);
    addTearDown(() async {
      process.kill();
      await process.exitCode;
      await directory.delete(recursive: true);
    });
    final report = File('${directory.path}/watchdog.json');
    final deadline = Stopwatch()..start();
    while (!await report.exists() && deadline.elapsedMilliseconds < 2500) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(await report.exists(), isTrue, reason: '启动后应立即确认真实采样，不能只假定进程已启动');
    final samples = jsonDecode(await report.readAsString()) as List;
    expect(samples.last['pid'], pid);
    expect(samples.last['exited'], false);
    expect(samples.last['workingSetBytes'], greaterThan(0));
  }, skip: !Platform.isWindows);
}
