import 'dart:io';

import '../../core/ai/ai_credentials.dart';
import '../../core/ffmpeg/process_runner.dart';
import '../../core/miaoa/miaoa_gateway.dart';
import '../app_locator.dart';

/// 开工前的体检：把「干到一半才会暴露」的环境问题一次性问完。
///
/// 为什么要有这条命令：`import` 不需要 AI 凭据，所以它总能跑成功，给人一个
/// 「环境没问题」的假象；到第二步 `analyze` 才炸，而那时视频已经导进去、
/// 任务也建好了。体检要在花时间之前把话说完。
///
/// 退出码沿用全局约定：0 = 都齐了，5 = 环境没配好（转告人去补，别重试）。
Future<int> runDoctorCommand({
  required Directory dataDir,
  required StringSink out,
  required StringSink err,
  Map<String, String>? env,
  String? currentDir,
  Future<bool> Function()? miaoaProbe,
  Future<bool> Function()? ffmpegProbe,
  ProcessRunner? mediaToolRun,
}) async {
  final problems = <String>[];

  final credentials = CredentialsLoader.load(
    env: env,
    secretsDirs: cliSecretsDirs(dataDir: dataDir, currentDir: currentDir),
  );
  final missing = <String>[
    if (credentials.arkApiKey.isEmpty) 'ark_api_key',
    if (credentials.speechAppId.isEmpty) 'speech_app_id',
    if (credentials.speechAccessToken.isEmpty) 'speech_access_token',
  ];
  if (missing.isEmpty) {
    out.writeln('✓ AI 凭据：齐了');
  } else {
    out.writeln('✗ AI 凭据：缺 ${missing.join('、')}');
    problems.add(
      '缺 AI 凭据（${missing.join('、')}）。'
      '正常情况下正式包会自带；这台机器上没有的话，'
      '把这几个文件放到 ${dataDir.path}/credentials/，'
      '或者用环境变量 ARK_API_KEY / SPEECH_APP_ID / SPEECH_ACCESS_TOKEN。'
      '缺了就没法分析视频、没法配音。',
    );
  }

  final miaoaOk = await (miaoaProbe ?? _probeMiaoa)();
  if (miaoaOk) {
    out.writeln('✓ 素材库：登录着');
  } else {
    out.writeln('✗ 素材库：没登录，或者 miaoa 这个工具没装');
    problems.add(
      '素材库连不上。请人自己在终端里敲 `miaoa auth login`'
      '——这条命令要跳浏览器，Agent 代跑不了。'
      '连不上就挑不了素材，换画面做不下去。',
    );
  }

  final ffmpegOk =
      await (ffmpegProbe ??
          () => _probeFfmpeg(mediaToolRun ?? systemProcessRunner))();
  if (ffmpegOk) {
    out.writeln('✓ ffmpeg：在');
  } else {
    out.writeln('✗ ffmpeg：找不到');
    problems.add('找不到 ffmpeg。合成、导出都要用它，装一个再来。');
  }

  if (problems.isEmpty) {
    out.writeln('');
    out.writeln('都齐了，可以开工。');
    return 0;
  }
  err.writeln('开工前的体检没过，下面这些得先补上——都要人动手，别重试：');
  for (final line in problems) {
    err.writeln('  · $line');
  }
  return 5;
}

Future<bool> _probeMiaoa() async {
  try {
    await MiaoaGateway().text(['auth', 'status', '--json'], what: '检查登录状态');
    return true;
  } catch (_) {
    return false;
  }
}

Future<bool> _probeFfmpeg(ProcessRunner run) async {
  try {
    final r = await run('ffmpeg', ['-version']);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}
