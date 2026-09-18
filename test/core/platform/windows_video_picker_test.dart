import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/platform/windows_video_picker.dart';
import 'package:ishkafel/core/log/app_log.dart';

class _Process extends Fake implements Process {
  final done = Completer<int>();
  var kills = 0;
  @override
  int get pid => 123;
  @override
  Future<int> get exitCode => done.future;
  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    kills++;
    if (!done.isCompleted) done.complete(-1);
    return true;
  }
}

void main() {
  late Directory root;
  setUp(
    () async => root = await Directory.systemTemp.createTemp('picker-test-'),
  );
  tearDown(() async => root.delete(recursive: true));

  test('独立进程参数传递、UTF8中文路径返回且仅清理本次目录', () async {
    final unrelated = File('${root.path}/keep.txt')..writeAsStringSync('keep');
    final picker = WindowsVideoPicker(
      tempRoot: root,
      executable: 'app.exe',
      start: (exe, args) async {
        expect(exe, 'app.exe');
        expect(args.first, '--pick-video');
        expect(args.last, '$pid');
        final process = _Process();
        await File(args[1]).writeAsString(r'D:\成片\中文 空格.mp4');
        process.done.complete(0);
        return process;
      },
    );
    expect(await picker.pick(), r'D:\成片\中文 空格.mp4');
    expect(await root.list().toList(), hasLength(1));
    expect(await unrelated.readAsString(), 'keep');
  });

  test('挂起选择可取消且连续请求只启动一个进程', () async {
    final process = _Process();
    final started = Completer<void>();
    var calls = 0;
    final picker = WindowsVideoPicker(
      tempRoot: root,
      start: (_, _) async {
        calls++;
        started.complete();
        return process;
      },
    );
    final first = picker.pick();
    final second = picker.pick();
    await started.future;
    picker.cancel();
    expect(await first, isNull);
    expect(await second, isNull);
    expect(calls, 1);
    expect(process.kills, 1);
    expect(await root.list().toList(), isEmpty);
  });

  test('进程尚在启动时取消仍会终止迟到进程', () async {
    final starting = Completer<void>();
    final process = _Process();
    final launched = Completer<Process>();
    final picker = WindowsVideoPicker(
      tempRoot: root,
      start: (_, _) {
        starting.complete();
        return launched.future;
      },
    );
    final result = picker.pick();
    await starting.future;
    picker.cancel();
    launched.complete(process);
    expect(await result, isNull);
    expect(process.kills, 1);
    expect(await root.list().toList(), isEmpty);
  });

  test('超时终止挂起进程并给可重试原因', () async {
    final process = _Process();
    final picker = WindowsVideoPicker(
      tempRoot: root,
      timeout: const Duration(milliseconds: 30),
      start: (_, _) async => process,
    );
    await expectLater(picker.pick(), throwsA(isA<VideoPickerException>()));
    expect(process.kills, 1);
    expect(await root.list().toList(), isEmpty);
  });

  test('启动失败释放选择锁，下一次可以重试', () async {
    var attempts = 0;
    final picker = WindowsVideoPicker(
      tempRoot: root,
      start: (_, _) async {
        if (++attempts == 1) throw const ProcessException('app', []);
        return _Process()..done.complete(1);
      },
    );
    await expectLater(picker.pick(), throwsA(isA<VideoPickerException>()));
    expect(await picker.pick(), isNull);
    expect(attempts, 2);
    expect(await root.list().toList(), isEmpty);
  });

  for (final stage in [
    'show',
    'failure at=show hr=0x80004005',
    r'D:\私人\视频.mp4',
  ]) {
    test('取消只记录白名单阶段：$stage', () async {
      final lines = <String>[];
      final sink = AppLog.sink;
      AppLog.sink = lines.add;
      addTearDown(() => AppLog.sink = sink);
      final started = Completer<void>();
      final picker = WindowsVideoPicker(
        tempRoot: root,
        start: (_, args) async {
          await File(
            '${File(args[1]).parent.path}/stage.txt',
          ).writeAsString(stage);
          started.complete();
          return _Process();
        },
      );
      final result = picker.pick();
      await started.future;
      picker.cancel();
      await result;
      final expectedStage = stage.startsWith('D:') ? 'invalid' : stage;
      expect(
        lines.any((line) => line.contains('nativeStage=$expectedStage')),
        isTrue,
      );
      expect(lines.any((line) => line.contains(root.path)), isFalse);
      expect(lines.any((line) => line.contains(r'D:\私人')), isFalse);
    });
  }

  for (final exit in [1, 2, 0]) {
    test('退出码 $exit 缺少结果不会伪造成功且清理目录', () async {
      final picker = WindowsVideoPicker(
        tempRoot: root,
        start: (_, _) async {
          final process = _Process()..done.complete(exit);
          return process;
        },
      );
      if (exit == 1) {
        expect(await picker.pick(), isNull);
      } else {
        await expectLater(picker.pick(), throwsA(isA<VideoPickerException>()));
      }
      expect(await root.list().toList(), isEmpty);
    });
  }
}
