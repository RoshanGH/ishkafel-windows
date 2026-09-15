import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ffmpeg/ffprobe_service.dart';
import 'package:ishkafel/core/ffmpeg/process_runner.dart';
import 'package:ishkafel/core/ffmpeg/thumbnail_service.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/tag_group_ref.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';
import 'package:ishkafel/features/import_flow/import_exception.dart';
import 'package:ishkafel/features/import_flow/import_service.dart';
import 'dart:convert';
import 'package:path/path.dart' as p;

const probeJson = {
  'streams': [
    {
      'codec_type': 'video',
      'width': 1080,
      'height': 1920,
      'r_frame_rate': '30/1',
    },
  ],
  'format': {'duration': '96.2', 'size': '100'},
};

void main() {
  late Directory tempDir;
  late ImportService service;
  late FileTaskRepository repo;
  final ffmpegCalls = <List<String>>[];

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ishkafel_import_');
    repo = FileTaskRepository(tempDir);
    ffmpegCalls.clear();
    service = ImportService(
      repository: repo,
      ffprobe: FfprobeService(
        run: (_, _) async => ProcessResult(1, 0, jsonEncode(probeJson), ''),
      ),
      thumbnails: ThumbnailService(
        run: (_, args) async {
          ffmpegCalls.add(args);
          return ProcessResult(1, 0, '', '');
        },
      ),
      coversDir: Directory('${tempDir.path}/covers'),
      idGenerator: () => 'fixed-id',
      clock: () => DateTime.utc(2026, 7, 29, 12),
    );
  });

  tearDown(() async => tempDir.delete(recursive: true));

  test('导入本地文件：建任务、抽封面、落库', () async {
    final task = await service.importLocalFile('/videos/滴露_测试片.mp4');
    expect(task.id, 'fixed-id');
    expect(task.name, '滴露_测试片');
    expect(task.status, RenewTaskStatus.analyzing);
    expect(task.videoInfo!.width, 1080);
    expect(task.coverPath, endsWith(p.join('covers', 'fixed-id.jpg')));
    // 封面命令确实指向源视频
    expect(ffmpegCalls.single, contains('/videos/滴露_测试片.mp4'));
    // 已落库
    expect(await repo.findById('fixed-id'), task);
  });

  test('新建向导选定的两个标签组随任务一起落库（阶段②的检索键）', () async {
    final task = await service.importLocalFile(
      '/videos/滴露_测试片.mp4',
      unitTagGroups: [const TagGroupRef(id: 1279, name: '衣清.消毒液')],
      shotTagGroups: [const TagGroupRef(id: 136, name: '画面类型')],
    );

    expect(task.unitTagGroup, const TagGroupRef(id: 1279, name: '衣清.消毒液'));
    expect(task.shotTagGroup, const TagGroupRef(id: 136, name: '画面类型'));
    expect((await repo.findById('fixed-id'))!.unitTagGroup!.name, '衣清.消毒液');
  });

  test('不传标签组时任务的标签组为空（该层不打标）', () async {
    final task = await service.importLocalFile('/videos/滴露_测试片.mp4');
    expect(task.unitTagGroup, isNull);
    expect(task.shotTagGroup, isNull);
  });

  group('非法帧率素材在导入边界被拦下（审片台 frameMs(0) 会崩）', () {
    const badFpsJson = {
      'streams': [
        {
          'codec_type': 'video',
          'width': 1080,
          'height': 1920,
          'r_frame_rate': '0/0',
          'avg_frame_rate': '0/0',
        },
      ],
      'format': {'duration': '10.0', 'size': '100'},
    };

    test('帧率非法时拒绝导入：中文提示、不抽封面、不落库', () async {
      final coverCalls = <List<String>>[];
      final service2 = ImportService(
        repository: repo,
        ffprobe: FfprobeService(
          run: (_, _) async => ProcessResult(1, 0, jsonEncode(badFpsJson), ''),
        ),
        thumbnails: ThumbnailService(
          run: (_, args) async {
            coverCalls.add(args);
            return ProcessResult(1, 0, '', '');
          },
        ),
        coversDir: Directory('${tempDir.path}/covers'),
        idGenerator: () => 'bad-fps',
      );

      await expectLater(
        service2.importLocalFile('/videos/坏帧率.mp4'),
        throwsA(
          isA<ImportException>()
              .having((e) => e.message, 'message', contains('帧率'))
              // 面向用户的提示不应出现原始异常文本
              .having(
                (e) => e.message,
                'message',
                isNot(contains('Exception')),
              ),
        ),
      );
      expect(coverCalls, isEmpty);
      expect(await repo.findAll(), isEmpty);
    });

    test('ffprobe 执行失败时也给中文提示而非原始异常文本', () async {
      final failing = ImportService(
        repository: repo,
        ffprobe: FfprobeService(
          run: (_, _) async => ProcessResult(1, 1, '', 'bad file'),
        ),
        thumbnails: ThumbnailService(
          run: (_, _) async => ProcessResult(1, 0, '', ''),
        ),
        coversDir: Directory('${tempDir.path}/covers'),
      );
      await expectLater(
        failing.importLocalFile('/v/x.mp4'),
        throwsA(
          isA<ImportException>().having(
            (e) => e.message,
            'message',
            isNot(contains('exit=')),
          ),
        ),
      );
    });

    test('视频处理组件缺失时把安装引导原样透传给用户', () async {
      const guidance = MediaToolMissingException(
        'ffprobe',
        operatingSystem: 'windows',
      );
      final missing = ImportService(
        repository: repo,
        ffprobe: FfprobeService(
          run: (_, _) async => throw guidance,
        ),
        thumbnails: ThumbnailService(
          run: (_, _) async => ProcessResult(1, 0, '', ''),
        ),
        coversDir: Directory('${tempDir.path}/covers'),
      );
      await expectLater(
        missing.importLocalFile('/v/x.mp4'),
        throwsA(
          isA<ImportException>().having(
            (e) => e.message,
            'message',
            guidance.message,
          ),
        ),
      );
    });
  });

  test('ffprobe 失败时不落库并向上抛错', () async {
    final failing = ImportService(
      repository: repo,
      ffprobe: FfprobeService(
        run: (_, _) async => ProcessResult(1, 1, '', 'bad file'),
      ),
      thumbnails: ThumbnailService(
        run: (_, _) async => ProcessResult(1, 0, '', ''),
      ),
      coversDir: Directory('${tempDir.path}/covers'),
    );
    await expectLater(failing.importLocalFile('/v/x.mp4'), throwsException);
    expect(await repo.findAll(), isEmpty);
  });
}
