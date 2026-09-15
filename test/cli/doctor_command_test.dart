import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/commands/doctor_command.dart';
import 'package:ishkafel/core/ffmpeg/process_runner.dart';

/// 开工前的体检。
///
/// 由来：验收 Agent 拿到正式包，`import` 顺利跑完（那一步不需要 AI 凭据），
/// 于是以为一切正常；到第二步 `analyze` 才炸——而那时视频已经导进去了、
/// 任务也建好了。它自己的话是「import 给了我一个『一切正常』的假象」。
///
/// 体检要在花任何时间之前把该报的都报了，而不是让人一步一步踩。
void main() {
  Directory tempDir() => Directory.systemTemp.createTempSync('doctor');

  test('样样齐全时退出码 0，并且把查了什么说出来', () async {
    final dir = tempDir();
    final creds = Directory('${dir.path}/credentials')..createSync();
    for (final f in ['ark_api_key', 'speech_app_id', 'speech_access_token']) {
      File('${creds.path}/$f').writeAsStringSync('x');
    }
    final out = StringBuffer();

    final code = await runDoctorCommand(
      dataDir: dir,
      out: out,
      err: StringBuffer(),
      env: const {},
      currentDir: dir.path,
      miaoaProbe: () async => true,
      ffmpegProbe: () async => true,
    );

    expect(code, 0);
    expect(out.toString(), contains('AI 凭据'));
    expect(out.toString(), contains('素材库'));
    expect(out.toString(), contains('ffmpeg'));
    dir.deleteSync(recursive: true);
  });

  test('凭据缺了就退 5，并点名缺哪个——别让人自己猜', () async {
    final dir = tempDir();
    final err = StringBuffer();

    final code = await runDoctorCommand(
      dataDir: dir,
      out: StringBuffer(),
      err: err,
      env: const {},
      currentDir: dir.path,
      miaoaProbe: () async => true,
      ffmpegProbe: () async => true,
    );

    expect(code, 5, reason: '5 = 环境没配好，转告人去补，别重试');
    expect(err.toString(), contains('ark_api_key'));
    dir.deleteSync(recursive: true);
  });

  test('凭据齐了但素材库没登录，照样拦下来', () async {
    final dir = tempDir();
    final err = StringBuffer();

    final code = await runDoctorCommand(
      dataDir: dir,
      out: StringBuffer(),
      err: err,
      currentDir: dir.path,
      env: const {
        'ARK_API_KEY': 'x',
        'SPEECH_APP_ID': 'x',
        'SPEECH_ACCESS_TOKEN': 'x',
      },
      miaoaProbe: () async => false,
      ffmpegProbe: () async => true,
    );

    expect(code, 5);
    expect(
      err.toString(),
      contains('miaoa auth login'),
      reason: '这条命令得由人自己去敲——手册明写不许 Agent 代跑',
    );
    dir.deleteSync(recursive: true);
  });

  test('默认 ffmpeg 体检走统一媒体执行器而不是直接查进程 PATH', () async {
    final dir = tempDir();
    final calls = <(String, List<String>)>[];

    final code = await runDoctorCommand(
      dataDir: dir,
      out: StringBuffer(),
      err: StringBuffer(),
      currentDir: dir.path,
      env: const {
        'ARK_API_KEY': 'x',
        'SPEECH_APP_ID': 'x',
        'SPEECH_ACCESS_TOKEN': 'x',
      },
      miaoaProbe: () async => true,
      mediaToolRun: (executable, args) async {
        calls.add((executable, args));
        return ProcessResult(1, 0, 'ffmpeg version fixture', '');
      },
    );

    expect(code, 0);
    expect(calls, hasLength(1));
    expect(calls.single.$1, 'ffmpeg');
    expect(calls.single.$2, ['-version']);
    dir.deleteSync(recursive: true);
  });
}
