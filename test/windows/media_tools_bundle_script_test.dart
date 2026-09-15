import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  final windowsOnly = !Platform.isWindows
      ? '需要 PowerShell 与 Windows ZIP 支持'
      : false;

  test('校验归档后只暂存 ffmpeg、ffprobe 与许可材料', () async {
    final fixture = await _createFixture();
    addTearDown(() => fixture.root.deleteSync(recursive: true));
    final output = Directory(p.join(fixture.root.path, 'staged'));

    final result = await _runPrepare(
      archive: fixture.archive,
      expectedSha256: fixture.sha256,
      output: output,
    );

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(
      File(p.join(output.path, 'tools', 'ffmpeg.exe')).readAsStringSync(),
      'ffmpeg fixture',
    );
    expect(
      File(p.join(output.path, 'tools', 'ffprobe.exe')).readAsStringSync(),
      'ffprobe fixture',
    );
    expect(
      File(p.join(output.path, 'LICENSE.txt')).readAsStringSync(),
      contains('GPL fixture'),
    );
    expect(
      File(p.join(output.path, 'NOTICE.md')).readAsStringSync(),
      contains('FFmpeg'),
    );
  }, skip: windowsOnly);

  test('SHA-256 不一致时失败且不留下可被打包的 tools 目录', () async {
    final fixture = await _createFixture();
    addTearDown(() => fixture.root.deleteSync(recursive: true));
    final output = Directory(p.join(fixture.root.path, 'staged'));

    final result = await _runPrepare(
      archive: fixture.archive,
      expectedSha256: '0' * 64,
      output: output,
    );

    expect(result.exitCode, isNot(0));
    expect('${result.stderr}${result.stdout}', contains('SHA-256'));
    expect(Directory(p.join(output.path, 'tools')).existsSync(), isFalse);
  }, skip: windowsOnly);
}

Future<ProcessResult> _runPrepare({
  required File archive,
  required String expectedSha256,
  required Directory output,
}) {
  return Process.run('powershell.exe', [
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    p.join(
      Directory.current.path,
      'scripts',
      'windows',
      'prepare_media_tools.ps1',
    ),
    '-ArchivePath',
    archive.path,
    '-ExpectedSha256',
    expectedSha256,
    '-OutputDirectory',
    output.path,
  ]);
}

Future<({Directory root, File archive, String sha256})> _createFixture() async {
  final root = await Directory.systemTemp.createTemp('ishkafel_ffmpeg_bundle_');
  final package = Directory(p.join(root.path, 'ffmpeg-fixture'));
  final bin = Directory(p.join(package.path, 'bin'))
    ..createSync(recursive: true);
  File(p.join(bin.path, 'ffmpeg.exe')).writeAsStringSync('ffmpeg fixture');
  File(p.join(bin.path, 'ffprobe.exe')).writeAsStringSync('ffprobe fixture');
  File(p.join(package.path, 'LICENSE')).writeAsStringSync('GPL fixture');
  File(p.join(package.path, 'README.txt')).writeAsStringSync('fixture readme');

  final archive = File(p.join(root.path, 'fixture.zip'));
  final command =
      "Compress-Archive -LiteralPath '${package.path.replaceAll("'", "''")}' "
      "-DestinationPath '${archive.path.replaceAll("'", "''")}' -Force";
  final zipped = await Process.run('powershell.exe', [
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    command,
  ]);
  if (zipped.exitCode != 0) {
    throw StateError('测试归档创建失败：${zipped.stderr}');
  }
  final digest = sha256.convert(await archive.readAsBytes()).toString();
  return (root: root, archive: archive, sha256: digest);
}
