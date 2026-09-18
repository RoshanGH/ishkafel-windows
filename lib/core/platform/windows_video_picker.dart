import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../log/app_log.dart';

typedef VideoPickerProcessStarter =
    Future<Process> Function(String executable, List<String> arguments);

class VideoPickerException implements Exception {
  final String message;
  const VideoPickerException(this.message);
  @override
  String toString() => message;
}

/// Windows Shell 扩展只在本次选择的子进程中加载，主窗口始终可以取消。
class WindowsVideoPicker {
  final Directory tempRoot;
  final String executable;
  final VideoPickerProcessStarter start;
  final Duration timeout;
  _Selection? _active;

  WindowsVideoPicker({
    required this.tempRoot,
    String? executable,
    VideoPickerProcessStarter? start,
    this.timeout = const Duration(minutes: 3),
  }) : executable = executable ?? Platform.resolvedExecutable,
       start = start ?? ((exe, args) => Process.start(exe, args));

  Future<String?> pick() {
    final active = _active;
    if (active != null) return active.result;
    final selection = _Selection();
    _active = selection;
    selection.result = _run(selection);
    return selection.result;
  }

  void cancel() {
    final selection = _active;
    if (selection != null && !selection.cancelled.isCompleted) {
      selection.cancelled.complete();
    }
  }

  Future<String?> _run(_Selection selection) async {
    Directory? owned;
    String? root;
    Process? child;
    var exited = false;
    var outcome = 'error';
    try {
      await tempRoot.create(recursive: true);
      root = await tempRoot.resolveSymbolicLinks();
      owned = await Directory(root).createTemp('video-picker-');
      final result = File(p.join(owned.path, 'result.txt'));
      if (selection.cancelled.isCompleted) {
        outcome = 'cancel';
        return null;
      }
      child = await start(executable, ['--pick-video', result.path, '$pid']);
      unawaited(child.stdout.drain<void>());
      unawaited(child.stderr.drain<void>());
      final exit = child.exitCode.then((code) {
        exited = true;
        return code;
      });
      AppLog.info('video_picker_helper phase=started pid=${child.pid}');
      final code = await Future.any<int>([
        exit,
        selection.cancelled.future.then((_) => -1),
      ]).timeout(timeout, onTimeout: () => -2);
      if (selection.cancelled.isCompleted || code == 1) {
        outcome = 'cancel';
        return null;
      }
      if (code == -2 || code == 3) {
        outcome = 'timeout';
        throw const VideoPickerException('文件选择等待超过 3 分钟，已结束本次选择，请重试。');
      }
      if (code != 0) {
        AppLog.warn('video_picker_helper phase=failed exit=$code');
        throw const VideoPickerException('系统文件选择窗口未能打开，请重试或重新启动应用。');
      }
      if (await result.length() > 128 * 1024) {
        throw const VideoPickerException('文件选择返回内容异常，请重试。');
      }
      final path = await result.readAsString();
      if (!p.windows.isAbsolute(path) ||
          path.contains('\u0000') ||
          !['.mp4', '.mov'].contains(p.windows.extension(path).toLowerCase())) {
        throw const VideoPickerException('文件选择未返回有效的视频文件，请重试。');
      }
      outcome = 'success';
      return path;
    } on VideoPickerException {
      rethrow;
    } catch (error) {
      if (selection.cancelled.isCompleted) {
        outcome = 'cancel';
        return null;
      }
      AppLog.warn('video_picker_helper phase=error type=${error.runtimeType}');
      throw const VideoPickerException('文件选择未能完成，请重试。');
    } finally {
      if (child != null && !exited) {
        child.kill(ProcessSignal.sigkill);
        try {
          await child.exitCode.timeout(const Duration(seconds: 2));
          exited = true;
        } on TimeoutException {
          AppLog.warn('video_picker_helper phase=termination_pending');
        }
      }
      if (owned != null && root != null) {
        final stage = await _readStage(owned);
        AppLog.info('video_picker_helper phase=$outcome nativeStage=$stage');
        if (child == null || exited) {
          await _removeOwnedDirectory(owned, root);
        } else {
          // 进程仍存活时不能删其结果目录；退出后再回收本次创建的目录。
          unawaited(
            child.exitCode.then((_) => _removeOwnedDirectory(owned!, root!)),
          );
        }
      }
      if (identical(_active, selection)) _active = null;
    }
  }

  Future<String> _readStage(Directory owned) async {
    try {
      final file = File(p.join(owned.path, 'stage.txt'));
      if (await file.length() > 256) return 'invalid';
      final stage = await file.readAsString();
      const phase =
          '(?:com_init|dialog_create|initial_folder|show|result|failure)';
      return RegExp(
            '^$phase(?: at=$phase)?(?: hr=0x[0-9A-F]{8})?\$',
          ).hasMatch(stage)
          ? stage
          : 'invalid';
    } on FileSystemException {
      return 'unavailable';
    } on FormatException {
      return 'invalid';
    }
  }

  Future<void> _removeOwnedDirectory(Directory directory, String root) async {
    try {
      if (!await directory.exists()) return;
      final resolved = await directory.resolveSymbolicLinks();
      if (p.dirname(resolved) != root ||
          !p.basename(resolved).startsWith('video-picker-')) {
        AppLog.warn('video_picker_helper phase=cleanup_rejected');
        return;
      }
      await Directory(resolved).delete(recursive: true);
    } on FileSystemException {
      AppLog.warn('video_picker_helper phase=cleanup_failed');
    }
  }
}

class _Selection {
  final cancelled = Completer<void>();
  late Future<String?> result;
}
