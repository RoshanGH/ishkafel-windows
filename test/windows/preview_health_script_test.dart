import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  final windowsOnly = !Platform.isWindows ? '需要 Windows PowerShell' : false;

  test('Windows 预览体检脚本会把健康日志交给同一套判据并返回成功', () async {
    final fixture = await _healthLog();
    addTearDown(() => fixture.parent.deleteSync(recursive: true));

    final result = await _analyze(fixture);

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect('${result.stdout}', contains('Preview health analysis passed.'));
  }, skip: windowsOnly);

  test('Windows 预览体检脚本会把画面重建判成失败并传回非零退出码', () async {
    final fixture = await _healthLog(extra: 'TextureGL: resize');
    addTearDown(() => fixture.parent.deleteSync(recursive: true));

    final result = await _analyze(fixture);

    expect(result.exitCode, isNot(0));
    expect(
      '${result.stdout}${result.stderr}',
      contains('Preview health analysis failed (exit=1).'),
    );
  }, skip: windowsOnly);
}

Future<File> _healthLog({String extra = ''}) async {
  final dir = await Directory.systemTemp.createTemp('ishkafel_health_script_');
  final lines = <String>[
    if (extra.isNotEmpty) extra,
    for (var i = 0; i < 25; i++)
      '[ishkafel][info] 同步采样：主时钟 ${i * 1000}ms、口播轨 '
          '${i * 1000 - 10}ms、偏差 -10ms、前瞻 0ms',
  ];
  return File(p.join(dir.path, 'play.log'))
    ..writeAsStringSync(lines.join('\n'));
}

Future<ProcessResult> _analyze(File log) => Process.run('powershell.exe', [
  '-NoProfile',
  '-NonInteractive',
  '-ExecutionPolicy',
  'Bypass',
  '-File',
  p.join(Directory.current.path, 'scripts', 'windows', 'preview_health.ps1'),
  '-AnalyzeLogPath',
  log.path,
  '-DartExecutable',
  _dartExecutable(),
], workingDirectory: Directory.current.path);

String _dartExecutable() {
  final currentExecutable = File(Platform.resolvedExecutable);
  if (p.basenameWithoutExtension(currentExecutable.path) == 'dart') {
    return currentExecutable.path;
  }

  var directory = currentExecutable.parent;
  while (directory.parent.path != directory.path) {
    final candidate = File(
      p.join(directory.path, 'bin', 'cache', 'dart-sdk', 'bin', 'dart.exe'),
    );
    if (candidate.existsSync()) return candidate.path;
    directory = directory.parent;
  }
  throw StateError('找不到 Flutter SDK 自带的 dart.exe');
}
