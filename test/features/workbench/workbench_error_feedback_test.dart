import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/audio_extractor.dart';
import 'package:ishkafel/core/ffmpeg/thumbnail_service.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/models/video_info.dart';
import 'package:ishkafel/core/playback/playback_controller.dart';
import 'package:ishkafel/core/storage/task_repository.dart';
import 'package:ishkafel/features/tasks/task_list_controller.dart';
import 'package:ishkafel/features/workbench/timeline_media_builder.dart';
import 'package:ishkafel/features/workbench/workbench_page.dart';

/// 保存必定失败的仓库：模拟磁盘写满 / 权限问题 / 文件被占用
class _FailingRepo implements TaskRepository {
  final _store = <String, RenewTask>{};
  bool failSave = true;

  @override
  Future<List<RenewTask>> findAll() async => _store.values.toList();
  @override
  Future<RenewTask?> findById(String id) async => _store[id];
  @override
  Future<void> save(RenewTask task) async {
    if (failSave) throw const FileSystemException('磁盘空间不足');
    _store[task.id] = task;
  }

  @override
  Future<void> delete(String id) async => _store.remove(id);
}

TimelineMediaBuilder _fakeMediaBuilder() => TimelineMediaBuilder(
      thumbnails: ThumbnailService(run: (_, args) async {
        await File(args.last).writeAsBytes(List<int>.filled(600, 1));
        return ProcessResult(1, 0, '', '');
      }),
      audio: AudioExtractor(run: (_, args) async {
        await File(args.last).writeAsBytes(List<int>.filled(64, 0));
        return ProcessResult(1, 0, '', '');
      }),
    );

RenewTask _task() => RenewTask(
      id: 't1',
      name: '测试成片',
      sourcePath: '/tmp/x.mp4',
      videoInfo: const VideoInfo(
        width: 1080,
        height: 1920,
        duration: Duration(milliseconds: 4000),
        fps: 30,
        fileSizeBytes: 1,
      ),
      status: RenewTaskStatus.ready,
      createdAt: DateTime(2026, 7, 31),
      updatedAt: DateTime(2026, 7, 31),
      units: [
        SemanticUnit(
          index: 0,
          startMs: 0,
          endMs: 2000,
          transcript: '第一句台词',
          shots: const [Shot(startMs: 0, endMs: 2000)],
        ),
        SemanticUnit(
          index: 1,
          startMs: 2000,
          endMs: 4000,
          transcript: '第二句台词',
          shots: const [Shot(startMs: 2000, endMs: 4000)],
        ),
      ],
    );

void main() {
  group('落库失败必须让用户看得见（否则表现为「按钮点了没反应」）', () {
    testWidgets('自动落库失败时给出可见提示，不让用户以为改动已经留住', (tester) async {
      final repo = _FailingRepo();
      repo.failSave = false;
      await repo.save(_task());
      repo.failSave = true;
      await tester.pumpWidget(ProviderScope(
        overrides: [taskRepositoryProvider.overrideWithValue(repo)],
        child: MaterialApp(
          home: WorkbenchPage(
            task: _task(),
            playbackFactory: FakePlaybackController.new,
            mediaBuilder: _fakeMediaBuilder(),
          ),
        ),
      ));
      await tester.pump();

      // 改一次边界，等自动落库的防抖窗口走完
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('unit-row-0')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('inspector-end-minus')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(SnackBar), findsOneWidget,
          reason: '自动保存悄悄失败最危险：用户以为改动已经留住，'
              '下次进来发现全没了');
      expect(find.textContaining('保存失败'), findsOneWidget,
          reason: '提示要说清是保存失败，而不是抛原始异常文本给用户');
    });
  });
}
