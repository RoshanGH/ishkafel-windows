import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/playback/media_load_gate.dart';

void main() {
  late StreamController<Duration> durations;
  late StreamController<String> errors;

  setUp(() {
    durations = StreamController<Duration>.broadcast(sync: true);
    errors = StreamController<String>.broadcast(sync: true);
  });
  tearDown(() async {
    await durations.close();
    await errors.close();
  });

  test('提交命令后仍等待本次零时长到正时长，忽略旧时长', () async {
    var completed = false;
    final loading = openMediaAndWaitForDuration(
      durations: durations.stream,
      errors: errors.stream,
      open: () async {
        durations.add(const Duration(seconds: 30));
      },
    ).then((_) => completed = true);
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    durations.add(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    durations.add(const Duration(seconds: 5));
    await loading;
    expect(durations.hasListener, isFalse);
    expect(errors.hasListener, isFalse);
  });

  test('提交命令前已订阅，不漏掉同步加载事件', () async {
    await openMediaAndWaitForDuration(
      durations: durations.stream,
      errors: errors.stream,
      open: () async {
        expect(durations.hasListener, isTrue);
        expect(errors.hasListener, isTrue);
        durations.add(Duration.zero);
        durations.add(const Duration(seconds: 5));
      },
    );
    expect(durations.hasListener, isFalse);
    expect(errors.hasListener, isFalse);
  });

  test('加载错误立刻向上抛且清理监听', () async {
    final loading = openMediaAndWaitForDuration(
      durations: durations.stream,
      errors: errors.stream,
      open: () async {
        durations.add(Duration.zero);
        errors.add('无法解码');
      },
    );
    await expectLater(loading, throwsA(isA<StateError>()));
    expect(durations.hasListener, isFalse);
    expect(errors.hasListener, isFalse);
  });

  test('加载没有有效时长时有界超时并清理监听', () async {
    final loading = openMediaAndWaitForDuration(
      durations: durations.stream,
      errors: errors.stream,
      timeout: const Duration(milliseconds: 20),
      open: () async => durations.add(Duration.zero),
    );
    await expectLater(loading, throwsA(isA<TimeoutException>()));
    expect(durations.hasListener, isFalse);
    expect(errors.hasListener, isFalse);
  });

  test('命令未返回也受超时约束', () async {
    final command = Completer<void>();
    final loading = openMediaAndWaitForDuration(
      durations: durations.stream,
      errors: errors.stream,
      timeout: const Duration(milliseconds: 20),
      open: () => command.future,
    );
    await expectLater(loading, throwsA(isA<TimeoutException>()));
    command.complete();
    expect(durations.hasListener, isFalse);
    expect(errors.hasListener, isFalse);
  }, timeout: const Timeout(Duration(seconds: 1)));

  test('命令自身失败保持原错误并清理监听', () async {
    final failure = StateError('提交失败');
    final loading = openMediaAndWaitForDuration(
      durations: durations.stream,
      errors: errors.stream,
      open: () => throw failure,
    );
    await expectLater(loading, throwsA(same(failure)));
    expect(durations.hasListener, isFalse);
    expect(errors.hasListener, isFalse);
  });
}
