import 'dart:async';

/// 提交媒体加载并等待本次加载确认。
///
/// media_kit 原生 open 会先 stop，推送零时长，再提交 loadlist。
/// 必须看到这次重置之后的正时长，不能把上一条媒体的时长当成就绪。
Future<void> openMediaAndWaitForDuration({
  required Stream<Duration> durations,
  required Stream<String> errors,
  required Future<void> Function() open,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final loaded = Completer<void>();
  var resetSeen = false;

  void fail(Object error, [StackTrace? stack]) {
    if (!loaded.isCompleted) loaded.completeError(error, stack);
  }

  final durationSubscription = durations.listen((duration) {
    if (duration == Duration.zero) {
      resetSeen = true;
    } else if (resetSeen && duration > Duration.zero && !loaded.isCompleted) {
      loaded.complete();
    }
  }, onError: fail);
  final errorSubscription = errors.listen((message) {
    fail(StateError('预览媒体加载失败：$message'));
  }, onError: fail);
  try {
    // 命令返回只表示提交成功；同时等待加载信号。超时也覆盖命令卡住的情况。
    await Future.wait<void>([
      loaded.future,
      Future<void>.sync(open),
    ], eagerError: true).timeout(timeout);
  } finally {
    await durationSubscription.cancel();
    await errorSubscription.cancel();
  }
}
