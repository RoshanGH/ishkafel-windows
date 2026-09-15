import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ffmpeg/media_tools_locator.dart';
import 'package:ishkafel/core/ffmpeg/process_runner.dart';

/// 假子进程：不依赖真实二进制即可验证超时与收尾逻辑
class _FakeProcess implements Process {
  @override
  final int pid = 4242;
  final Completer<int> _exitCode = Completer<int>();
  final String stdoutText;
  final String stderrText;
  int killCount = 0;

  _FakeProcess({this.stdoutText = '', this.stderrText = ''});

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  Stream<List<int>> get stdout => Stream.value(utf8.encode(stdoutText));

  @override
  Stream<List<int>> get stderr => Stream.value(utf8.encode(stderrText));

  @override
  IOSink get stdin => throw UnimplementedError();

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killCount++;
    if (!_exitCode.isCompleted) _exitCode.complete(-9);
    return true;
  }

  void finish(int code) => _exitCode.complete(code);
}

void main() {
  group('TimeoutProcessInvoker', () {
    test('子进程正常结束时返回 exitCode 与 stdout/stderr', () async {
      final process = _FakeProcess(stdoutText: '正常输出', stderrText: '警告');
      final invoker = TimeoutProcessInvoker(
        timeout: const Duration(seconds: 5),
        starter: (_, _, {environment}) async {
          Future.microtask(() => process.finish(0));
          return process;
        },
      );

      final result = await invoker('ffmpeg', const ['-version']);

      expect(result.exitCode, 0);
      expect(result.stdout, '正常输出');
      expect(result.stderr, '警告');
      expect(process.killCount, 0);
    });

    /// 真机事故（2026-09-04）：点「重新分离」报「未检测到人声分离工具」，
    /// 可工具装得好好的。缺的是它自己要调的 **ffmpeg**——GUI 进程继承的
    /// launchd PATH 里没有 Homebrew，第三方程序绕不开这一条。
    test('起子进程时把装工具的目录交给它——第三方程序自己要去 PATH 上找 ffmpeg', () async {
      final process = _FakeProcess();
      Map<String, String>? handed;
      final invoker = TimeoutProcessInvoker(
        timeout: const Duration(seconds: 5),
        starter: (_, _, {environment}) async {
          handed = environment;
          Future.microtask(() => process.finish(0));
          return process;
        },
      );

      await invoker('audio-separator', const []);

      expect(handed?['PATH'], isNotNull, reason: '不交 PATH 等于让它自己碰运气');
      if (Platform.isWindows) {
        expect(handed!['PATH'], contains(';'));
        expect(
          handed!['PATH'],
          isNot(contains('C;\\')),
          reason: 'Windows 盘符不能被冒号分隔逻辑拆坏',
        );
      } else {
        expect(handed!['PATH'], contains('/opt/homebrew/bin'));
      }
    });

    test('超时后杀掉子进程并抛出带中文说明的异常', () async {
      final process = _FakeProcess();
      final invoker = TimeoutProcessInvoker(
        timeout: const Duration(milliseconds: 30),
        starter: (_, _, {environment}) async => process, // 永不结束
      );

      await expectLater(
        invoker('ffmpeg', const ['-i', 'x.mp4']),
        throwsA(
          isA<FfmpegException>().having(
            (e) => e.message,
            'message',
            allOf(contains('超时'), contains('ffmpeg')),
          ),
        ),
      );
      expect(process.killCount, 1, reason: '必须杀掉卡住的子进程，避免永久挂起');
    });

    test('默认超时时长为正且足够整片场景检测（不小于 5 分钟）', () {
      expect(defaultProcessTimeout.inMinutes, greaterThanOrEqualTo(5));
    });
  });

  group('ResolvingProcessRunner', () {
    test('裸名 ffmpeg 先解析成绝对路径再启动子进程', () async {
      final invoked = <String>[];
      final runner = ResolvingProcessRunner(
        locator: MediaToolsLocator(
          operatingSystem: 'macos',
          probe: (path) => path.startsWith('/opt/homebrew/bin/'),
          lookupOnPath: (_) => null,
        ),
        invoke: (executable, args) async {
          invoked.add(executable);
          return ProcessResult(1, 0, '', '');
        },
      );

      final result = await runner('ffmpeg', const ['-version']);

      expect(result.exitCode, 0);
      expect(invoked, ['/opt/homebrew/bin/ffmpeg']);
    });

    test('工具缺失时抛中文提示的 FfmpegException，且不启动任何子进程', () async {
      final runner = ResolvingProcessRunner(
        locator: MediaToolsLocator(
          probe: (_) => false,
          lookupOnPath: (_) => null,
        ),
        invoke: (_, _) async => fail('工具缺失时不应启动子进程'),
      );

      await expectLater(
        runner('ffprobe', const []),
        throwsA(
          isA<FfmpegException>().having(
            (e) => e.message,
            'message',
            allOf(contains('ffprobe'), contains('未找到')),
          ),
        ),
      );
    });

    test('绝对路径调用不再二次解析，直接透传', () async {
      final invoked = <String>[];
      final runner = ResolvingProcessRunner(
        locator: MediaToolsLocator(
          probe: (_) => fail('绝对路径无需解析'),
          lookupOnPath: (_) => fail('绝对路径无需解析'),
        ),
        invoke: (executable, args) async {
          invoked.add(executable);
          return ProcessResult(1, 0, '', '');
        },
      );

      await runner('/custom/bin/ffmpeg', const []);

      expect(invoked, ['/custom/bin/ffmpeg']);
    });

    test('Windows 盘符和 UNC 绝对路径同样直接透传', () async {
      final invoked = <String>[];
      final runner = ResolvingProcessRunner(
        locator: MediaToolsLocator(
          probe: (_) => fail('绝对路径无需解析'),
          lookupOnPath: (_) => fail('绝对路径无需解析'),
        ),
        invoke: (executable, _) async {
          invoked.add(executable);
          return ProcessResult(1, 0, '', '');
        },
      );

      await runner(
        r'C:\Program Files\Ishkafel\ishkafel_renderer.exe',
        const [],
      );
      await runner(r'\\server\share\ffmpeg.exe', const []);

      expect(invoked, [
        r'C:\Program Files\Ishkafel\ishkafel_renderer.exe',
        r'\\server\share\ffmpeg.exe',
      ]);
    });
  });
}
