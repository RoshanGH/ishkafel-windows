import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/diagnostics/tool_installer.dart';

/// 在 app 里一键装外部依赖。
///
/// 三条硬要求：
/// 1. **走国内源**。默认源在国内基本装不上，而 audio-separator 连着 PyTorch
///    有 1GB——不换源等于这个按钮点了也白点。
/// 2. **命令要给用户看**，包括用的是哪个镜像源。这一步会在他机器上跑真实的
///    安装命令，有的还从网上取脚本执行，不给看就跑等于替他做了个他不知道的决定。
/// 3. **失败要说原因**，原始报文给出来。安装失败千奇百怪（网络、磁盘、权限、
///    平台不支持），糊一句「安装失败」等于让人去猜。
void main() {
  group('国内镜像源', () {
    test('Homebrew 的 bottle 与 api 都指向清华', () {
      for (final key in ['HOMEBREW_BOTTLE_DOMAIN', 'HOMEBREW_API_DOMAIN']) {
        expect(InstallRecipes.ffmpeg.environment[key],
            contains('mirrors.tuna.tsinghua.edu.cn'),
            reason: '$key 没换源，bottle 会去 GitHub Releases 拉');
      }
    });

    test('跳过 brew 自更新与装后清理——用户等的是 ffmpeg，不是这两件事', () {
      expect(InstallRecipes.ffmpeg.environment['HOMEBREW_NO_AUTO_UPDATE'], '1');
      expect(
          InstallRecipes.ffmpeg.environment['HOMEBREW_NO_INSTALL_CLEANUP'], '1');
    });

    test('PyPI 新旧两个变量都给，免得因 uv 版本差异悄悄走回默认源', () {
      for (final key in ['UV_DEFAULT_INDEX', 'UV_INDEX_URL']) {
        expect(InstallRecipes.audioSeparator.environment[key],
            contains('mirrors.tuna.tsinghua.edu.cn'));
      }
    });

    test('miaoa 走官方域名，本来就在国内，不需要也不应该换', () {
      expect(InstallRecipes.miaoa.command.join(' '),
          contains('miaoa.mininglamp.com'));
      expect(InstallRecipes.miaoa.environment, isEmpty);
    });
  });

  group('命令要摆给用户看', () {
    test('展示的那一行带上镜像源，不把它藏起来', () {
      final shown = InstallRecipes.ffmpeg.displayCommand;
      expect(shown, contains('brew install ffmpeg'));
      expect(shown, contains('HOMEBREW_BOTTLE_DOMAIN='));
    });

    test('带空格/方括号的参数加引号，照着敲也能跑', () {
      expect(InstallRecipes.audioSeparator.displayCommand,
          contains('audio-separator[cpu]'));
    });
  });

  group('前置不在就不跑', () {
    test('没有 brew 时直接给出怎么装 brew，而不是让它吐 command not found', () async {
      final installer = ToolInstaller(
        resolve: (_) => null,
        start: (_, _, _) async => throw StateError('不该起进程'),
      );
      final events = await installer.run(InstallRecipes.ffmpeg).toList();
      expect(events.single.done, isFalse);
      expect(events.single.failure, contains('Homebrew'));
    });

    test('自包含的配方（miaoa）没有前置，照跑', () {
      final installer = ToolInstaller(resolve: (_) => null);
      expect(installer.prerequisiteReady(InstallRecipes.miaoa), isTrue);
      expect(installer.prerequisiteReady(InstallRecipes.ffmpeg), isFalse);
    });
  });

  group('跑起来之后', () {
    ToolInstaller installerYielding(
      List<String> stdout,
      List<String> stderr,
      int exitCode,
    ) =>
        ToolInstaller(
          resolve: (name) => '/fake/$name',
          start: (_, _, _) async => _FakeProcess(stdout, stderr, exitCode),
        );

    test('第一条是那行命令本身——让人看见到底跑了什么', () async {
      final events =
          await installerYielding(['ok'], [], 0).run(InstallRecipes.miaoa).toList();
      expect(events.first.line, startsWith('\$ '));
      expect(events.first.line, contains('miaoa.mininglamp.com'));
    });

    test('stdout 与 stderr 都收——安装工具习惯把进度写在 stderr', () async {
      final events = await installerYielding(['下载中 50%'], ['编译中'], 0)
          .run(InstallRecipes.miaoa)
          .toList();
      final lines = events.map((e) => e.line).whereType<String>().toList();
      expect(lines, contains('下载中 50%'));
      expect(lines, contains('编译中'));
    });

    test('退出码 0 就是成功', () async {
      final events =
          await installerYielding([], [], 0).run(InstallRecipes.miaoa).toList();
      expect(events.last.done, isTrue);
    });

    test('失败时把最后一行原始报文带出来，不糊成「安装失败」', () async {
      final events = await installerYielding([], ['curl: (28) 连接超时'], 1)
          .run(InstallRecipes.miaoa)
          .toList();
      expect(events.last.done, isFalse);
      expect(events.last.failure, contains('连接超时'));
      expect(events.last.failure, contains('1'), reason: '退出码也要给');
    });

    test('miaoa 说这个平台不支持时到此为止，不去找别的安装途径', () async {
      final events = await installerYielding([], ['error: unsupported platform'], 1)
          .run(InstallRecipes.miaoa)
          .toList();
      expect(events.last.failure, contains('不支持'));
      expect(events.last.failure, contains('miaoa 团队'));
      expect(events.last.failure, contains('不要自行下载'),
          reason: '官方约定：不自己编译、不下其它来源的二进制');
    });

    test('起不了进程也要说清楚，而不是静默什么都没发生', () async {
      final installer = ToolInstaller(
        resolve: (name) => '/fake/$name',
        start: (_, _, _) async =>
            throw const ProcessException('brew', [], '权限不足'),
      );
      final events = await installer.run(InstallRecipes.miaoa).toList();
      expect(events.last.done, isFalse);
      expect(events.last.failure, contains('权限不足'));
    });
  });

  test('ffprobe 跟着 ffmpeg 一起装，不另开一条配方', () {
    expect(
      InstallRecipes.forTool('ffprobe', operatingSystem: 'macos'),
      same(InstallRecipes.ffmpeg),
    );
    expect(
      InstallRecipes.forTool('ffmpeg', operatingSystem: 'macos'),
      same(InstallRecipes.ffmpeg),
    );
    expect(
      InstallRecipes.forTool('不存在的工具', operatingSystem: 'macos'),
      isNull,
    );
  });

  group('Windows 配方不照搬 macOS', () {
    test('内置 ffmpeg 损坏只能重装完整包，不提供 brew 安装按钮', () {
      expect(
        InstallRecipes.forTool('ffmpeg', operatingSystem: 'windows'),
        isNull,
      );
      expect(
        InstallRecipes.forTool('ffprobe', operatingSystem: 'windows'),
        isNull,
      );
    });

    test('miaoa 没有官方 Windows 安装器前不执行 bash 脚本', () {
      expect(
        InstallRecipes.forTool('miaoa', operatingSystem: 'windows'),
        isNull,
      );
    });

    test('Windows 人声分离仍可用 uv，但提示里没有 Homebrew', () {
      final recipe = InstallRecipes.forTool(
        'audio-separator',
        operatingSystem: 'windows',
      );
      expect(recipe, isNotNull);
      expect(recipe!.command, contains('audio-separator[cpu]'));
      expect(recipe.prerequisiteHint, contains('uv'));
      expect(recipe.prerequisiteHint, isNot(contains('brew')));
    });
  });
}

/// 假子进程：按给定内容吐 stdout/stderr，然后以给定退出码结束
class _FakeProcess implements Process {
  final List<String> _out;
  final List<String> _err;
  final int _code;

  _FakeProcess(this._out, this._err, this._code);

  @override
  Stream<List<int>> get stdout => _lines(_out);

  @override
  Stream<List<int>> get stderr => _lines(_err);

  Stream<List<int>> _lines(List<String> lines) =>
      // 必须 UTF-8 编码：解码端是 utf8.decoder，用 codeUnits（UTF-16 码元）
      // 中文会解成乱码，测试里就表现为「明明吐了却收不到」
      Stream.fromIterable(lines.map((l) => utf8.encode('$l\n')));

  @override
  Future<int> get exitCode async => _code;

  @override
  int get pid => 1;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;

  @override
  IOSink get stdin => throw UnimplementedError();
}
