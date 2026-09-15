import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ai/ai_credentials.dart';
import 'package:ishkafel/core/diagnostics/environment_report.dart';
import 'package:ishkafel/core/ffmpeg/media_tools_locator.dart';
import 'package:ishkafel/core/ffmpeg/process_runner.dart';

const _secret = 'sk-super-secret-key-value-0930';

const _complete = AiCredentials(
  arkApiKey: _secret,
  speechAppId: 'app-123456',
  speechAccessToken: 'tok-abcdef',
);

Future<ProcessResult> _version(String exe, List<String> args) async =>
    ProcessResult(1, 0, '$exe version 7.1.1 built with clang', '');

EnvironmentProbe _probe({
  MediaToolsStatus tools = const MediaToolsStatus(
      ffmpegPath: '/opt/homebrew/bin/ffmpeg',
      ffprobePath: '/opt/homebrew/bin/ffprobe'),
  String? miaoaPath = '/Users/x/.local/bin/miaoa',
  String? separatorPath = '/Users/x/.local/bin/audio-separator',
  AiCredentials credentials = _complete,
  ProcessRunnerLike run = _version,
}) =>
    EnvironmentProbe(
      resolveMediaTools: () => tools,
      resolveMiaoa: () => miaoaPath,
      resolveSeparator: () => separatorPath,
      credentials: credentials,
      run: run,
    );

void main() {
  group('装好之后不必重启 app', () {
    test('重新体检时重新解析路径，能发现新装好的工具', () async {
      var installed = false;
      final probe = EnvironmentProbe(
        resolveMediaTools: () => installed
            ? const MediaToolsStatus(
                ffmpegPath: '/opt/homebrew/bin/ffmpeg',
                ffprobePath: '/opt/homebrew/bin/ffprobe')
            : const MediaToolsStatus(),
        resolveMiaoa: () => null,
        resolveSeparator: () => null,
        credentials: _complete,
        run: _version,
      );

      final before = await probe.collect();
      expect(before.tools.firstWhere((t) => t.name == 'ffmpeg').installed,
          isFalse);

      // 用户照着提示把工具装上了——app 一直开着
      installed = true;

      final after = await probe.collect();
      expect(after.tools.firstWhere((t) => t.name == 'ffmpeg').installed, isTrue,
          reason: '体检拿的是启动那一刻的旧结论的话，用户装完点「重新检测」'
              '还是显示未安装，只能重启 app——而界面上并没有说要重启');
    });
  });

  group('外部工具体检', () {
    test('列出 ffmpeg / ffprobe / miaoa 三项及其实际路径', () async {
      final report = await _probe().collect();

      expect(report.tools.map((t) => t.name),
          containsAll(<String>['ffmpeg', 'ffprobe', 'miaoa']));
      final ffmpeg = report.tools.firstWhere((t) => t.name == 'ffmpeg');
      expect(ffmpeg.installed, isTrue);
      expect(ffmpeg.path, '/opt/homebrew/bin/ffmpeg');
    });

    test('缺失的工具标为未安装，并给出该工具自己的安装办法', () async {
      final report = await _probe(
        tools: const MediaToolsStatus(ffprobePath: '/usr/bin/ffprobe'),
        miaoaPath: null,
      ).collect();

      final ffmpeg = report.tools.firstWhere((t) => t.name == 'ffmpeg');
      expect(ffmpeg.installed, isFalse);
      expect(ffmpeg.path, isNull);
      expect(ffmpeg.hint, missingToolMessage('ffmpeg'));

      final miaoa = report.tools.firstWhere((t) => t.name == 'miaoa');
      expect(miaoa.installed, isFalse);
      expect(miaoa.hint, isNot(missingToolMessage('ffmpeg')),
          reason: '照着装 ffmpeg 并不会让 miaoa 出现，用户会以为软件坏了');
    });

    test('读到版本号就展示，读不到也不当成「未安装」', () async {
      final report = await _probe(
        run: (_, _) async => throw const ProcessException('x', []),
      ).collect();

      final ffmpeg = report.tools.firstWhere((t) => t.name == 'ffmpeg');
      expect(ffmpeg.installed, isTrue,
          reason: '路径实实在在解析到了；版本读不出来只是信息少一条，'
              '标成未安装会把人引去重装一个已经装好的东西');
      expect(ffmpeg.version, isNull);
    });

    test('版本号只取首行，不把整段 banner 灌进界面', () async {
      final report = await _probe(
        run: (_, _) async =>
            ProcessResult(1, 0, 'ffmpeg version 7.1.1\nconfiguration: --a --b\n', ''),
      ).collect();

      final ffmpeg = report.tools.firstWhere((t) => t.name == 'ffmpeg');
      expect(ffmpeg.version, 'ffmpeg version 7.1.1');
    });

    test('未安装的工具不去启动子进程', () async {
      var invoked = 0;
      await _probe(miaoaPath: null, separatorPath: null, run: (e, a) async {
        invoked++;
        return ProcessResult(1, 0, 'v1', '');
      }).collect();

      expect(invoked, 2, reason: '只该探测 ffmpeg 与 ffprobe；对不存在的可执行'
          '文件起进程只会白等一次 ENOENT');
    });
  });

  group('云端凭据只报「有没有」', () {
    test('齐全时标为已配置', () async {
      final report = await _probe().collect();
      expect(report.credentialsReady, isTrue);
    });

    test('缺一项就是未配置', () async {
      final report = await _probe(
        credentials: const AiCredentials(
            arkApiKey: _secret, speechAppId: '', speechAccessToken: 'tok'),
      ).collect();

      expect(report.credentialsReady, isFalse);
      expect(report.credentialsHint, isNotNull);
    });

    test('报告的任何字段都不含凭据原文', () async {
      final report = await _probe().collect();

      final dumped = [
        report.credentialsHint ?? '',
        for (final t in report.tools) '${t.name}|${t.path}|${t.version}|${t.hint}',
      ].join('\n');

      expect(dumped, isNot(contains(_secret)),
          reason: '设置页是最容易被截图外发的一页。凭据一旦出现在这里，'
              '只要一张截图就等于泄露；「体检报告」永远只报有没有，不报是什么');
      expect(dumped, isNot(contains('app-123456')));
      expect(dumped, isNot(contains('tok-abcdef')));
    });
  });

  group('人声分离工具（可选项）', () {
    test('装了就报路径', () async {
      final report = await _probe().collect();

      final tool = report.tools.firstWhere((t) => t.name == 'audio-separator');
      expect(tool.installed, isTrue);
    });

    test('没装时给出安装命令，并说清它只影响换配乐', () async {
      final report = await _probe(separatorPath: null).collect();

      final tool = report.tools.firstWhere((t) => t.name == 'audio-separator');
      expect(tool.installed, isFalse);
      expect(tool.hint, contains('uv tool install'));
      expect(tool.hint, contains('换配乐'),
          reason: '缺了它照样能分析、能替换画面，不该让用户以为整个应用不能用');
    });
  });
}
