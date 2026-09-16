import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/analysis_pipeline.dart';
import 'package:ishkafel/core/analysis/audio_extractor.dart';
import 'package:ishkafel/core/ffmpeg/thumbnail_service.dart';
import 'package:ishkafel/features/workbench/timeline_media_builder.dart';

/// 把 16 位有符号采样编码为小端 PCM 字节
Uint8List _pcm16Bytes(List<int> samples) {
  final bytes = Int16List.fromList(samples).buffer.asUint8List();
  return Uint8List.fromList(bytes);
}

void main() {
  group('TimelineMediaBuilder.computeEnvelope（纯函数）', () {
    test('返回定长数组，长度恒等于 buckets', () {
      final envelope =
          TimelineMediaBuilder.computeEnvelope([1, 2, 3, 4, 5, 6], 10);
      expect(envelope.length, 10);
    });

    test('响亮分段 bucket 高于静音分段，且峰值归一化为 1.0', () {
      // 8 个采样均分 4 个 bucket：[100,100] [0,0] [50,50] [0,0]
      final envelope =
          TimelineMediaBuilder.computeEnvelope([100, 100, 0, 0, 50, 50, 0, 0], 4);
      expect(envelope[0], 1.0); // 峰值 bucket 归一化到 1.0
      expect(envelope[1], 0.0); // 静音 bucket
      expect(envelope[2], 0.5); // 响度为峰值一半
      expect(envelope[3], 0.0); // 静音 bucket
    });

    test('全静音输入（最大值为 0）返回全 0', () {
      final envelope = TimelineMediaBuilder.computeEnvelope([0, 0, 0, 0], 4);
      expect(envelope, [0.0, 0.0, 0.0, 0.0]);
    });

    test('空采样返回全 0，长度仍为 buckets', () {
      final envelope = TimelineMediaBuilder.computeEnvelope([], 5);
      expect(envelope, [0.0, 0.0, 0.0, 0.0, 0.0]);
    });
  });

  group('TimelineMediaBuilder.build', () {
    late Directory workDir;

    setUp(() async {
      workDir = await Directory.systemTemp.createTemp('ishkafel_tl_media_');
    });

    tearDown(() async {
      if (await workDir.exists()) {
        await workDir.delete(recursive: true);
      }
    });

    /// 构造记录调用参数、且写出假文件的抽帧服务
    ({ThumbnailService service, List<List<String>> calls}) fakeThumbnails({
      bool Function(String outPath)? shouldFail,
    }) {
      final calls = <List<String>>[];
      final service = ThumbnailService(run: (exe, args) async {
        calls.add(args);
        final outPath = args.last;
        if (shouldFail != null && shouldFail(outPath)) {
          return ProcessResult(1, 1, '', '模拟抽帧失败');
        }
        // 模拟真实 ffmpeg 输出的 jpg 大小（需超过有效缓存阈值）
        await File(outPath).writeAsBytes(List<int>.filled(600, 1));
        return ProcessResult(1, 0, '', '');
      });
      return (service: service, calls: calls);
    }

    /// 构造记录调用参数、写出假 PCM 的音频提取服务
    ({AudioExtractor service, List<List<String>> calls}) fakeAudio({
      List<int> samples = const [100, -100, 100, -100],
      bool fail = false,
    }) {
      final calls = <List<String>>[];
      final service = AudioExtractor(run: (exe, args) async {
        calls.add(args);
        if (fail) {
          return ProcessResult(1, 1, '', '模拟音频提取失败');
        }
        final outPcmPath = args.last;
        await File(outPcmPath).writeAsBytes(_pcm16Bytes(samples));
        return ProcessResult(1, 0, '', '');
      });
      return (service: service, calls: calls);
    }

    test('首次打开任务时自动创建尚不存在的媒体工作目录', () async {
      final missingWorkDir = Directory('${workDir.path}/中文 analysis_work');
      final thumbs = fakeThumbnails();
      final audio = fakeAudio();

      final media = await TimelineMediaBuilder(
        thumbnails: thumbs.service,
        audio: audio.service,
      ).build(
        videoPath: '/v/a.mp4',
        taskId: 'first-open',
        durationMs: 3000,
        workDir: missingWorkDir,
        thumbCount: 2,
        waveBuckets: 4,
      );

      expect(missingWorkDir.existsSync(), isTrue);
      expect(media.thumbsMissing, 0);
      expect(media.waveAllSilent, isFalse);
    });

    test('等间隔取 thumbCount 个时间点并写出对应缩略图路径', () async {
      final thumbs = fakeThumbnails();
      final audio = fakeAudio();
      final builder =
          TimelineMediaBuilder(thumbnails: thumbs.service, audio: audio.service);

      final media = await builder.build(
        videoPath: '/v/a.mp4',
        taskId: 't1',
        durationMs: 9000,
        workDir: workDir,
        thumbCount: 3,
        waveBuckets: 8,
      );

      expect(media.thumbPaths, [
        '${workDir.path}/t1_tl3_0.jpg',
        '${workDir.path}/t1_tl3_1.jpg',
        '${workDir.path}/t1_tl3_2.jpg',
      ]);
      // atSeconds = durationMs * (i+0.5) / thumbCount / 1000.0 → 1.5, 4.5, 7.5（等间隔 3s）
      // 抽帧是并发的，调用**顺序**不再固定；这里要守的是「取样时间点正确且
      // 等间隔」，所以比较排序后的集合而不是调用顺序（顺序与下标的对应关系
      // 由 timeline_media_concurrency_test.dart 的乱序用例单独保证）
      final atSecondsSeq = thumbs.calls.map((args) {
        final idx = args.indexOf('-ss');
        return double.parse(args[idx + 1]);
      }).toList()
        ..sort();
      expect(atSecondsSeq, [1.5, 4.5, 7.5]);
      expect(media.waveEnvelope.length, 8);
    });

    test('缩略图文件已存在则跳过抽帧（缓存命中）', () async {
      final thumbs = fakeThumbnails();
      final audio = fakeAudio();
      final builder =
          TimelineMediaBuilder(thumbnails: thumbs.service, audio: audio.service);

      await builder.build(
        videoPath: '/v/a.mp4',
        taskId: 't2',
        durationMs: 6000,
        workDir: workDir,
        thumbCount: 3,
        waveBuckets: 8,
      );
      expect(thumbs.calls.length, 3);

      // 第二次调用：目标文件已存在，不应再触发 ffmpeg 抽帧
      await builder.build(
        videoPath: '/v/a.mp4',
        taskId: 't2',
        durationMs: 6000,
        workDir: workDir,
        thumbCount: 3,
        waveBuckets: 8,
      );
      expect(thumbs.calls.length, 3);
    });

    test('PCM 文件已存在则跳过音频提取（缓存命中）', () async {
      final thumbs = fakeThumbnails();
      final audio = fakeAudio();
      final builder =
          TimelineMediaBuilder(thumbnails: thumbs.service, audio: audio.service);

      final first = await builder.build(
        videoPath: '/v/a.mp4',
        taskId: 't3',
        durationMs: 6000,
        workDir: workDir,
        thumbCount: 2,
        waveBuckets: 8,
      );
      expect(audio.calls.length, 1);

      final second = await builder.build(
        videoPath: '/v/a.mp4',
        taskId: 't3',
        durationMs: 6000,
        workDir: workDir,
        thumbCount: 2,
        waveBuckets: 8,
      );
      expect(audio.calls.length, 1); // 未再次调用
      expect(second.waveEnvelope, first.waveEnvelope);
    });

    test('部分抽帧失败：失败那格保留为空洞，其余各张仍停在自己的下标上', () async {
      final thumbs =
          fakeThumbnails(shouldFail: (outPath) => outPath.contains('_tl3_1.jpg'));
      final audio = fakeAudio();
      final builder =
          TimelineMediaBuilder(thumbnails: thumbs.service, audio: audio.service);

      final media = await builder.build(
        videoPath: '/v/a.mp4',
        taskId: 't4',
        durationMs: 9000,
        workDir: workDir,
        thumbCount: 3,
        waveBuckets: 8,
      );

      // 这里原本断言的是「把失败项从列表里挤掉」——那正是缺陷本身：剩余
      // 各张会被按新长度重新等分铺开，从失败点起每格显示的都是下一格的画面。
      expect(media.thumbPaths, [
        '${workDir.path}/t4_tl3_0.jpg',
        null,
        '${workDir.path}/t4_tl3_2.jpg',
      ]);
    });

    test('音频提取失败：包络返回全 0，不抛异常，缩略图不受影响', () async {
      final thumbs = fakeThumbnails();
      final audio = fakeAudio(fail: true);
      final builder =
          TimelineMediaBuilder(thumbnails: thumbs.service, audio: audio.service);

      final media = await builder.build(
        videoPath: '/v/a.mp4',
        taskId: 't5',
        durationMs: 6000,
        workDir: workDir,
        thumbCount: 2,
        waveBuckets: 6,
      );

      expect(media.thumbPaths.length, 2);
      expect(media.waveEnvelope, List.filled(6, 0.0));
    });

    test('缩略图缓存文件为 0 字节（损坏）时应重新抽帧，不复用坏文件', () async {
      // 预置一个 0 字节的坏缓存文件（模拟上次运行中途失败留下的产物）
      final badPath = '${workDir.path}/t6_tl2_0.jpg';
      await File(badPath).writeAsBytes(const []);

      final thumbs = fakeThumbnails();
      final audio = fakeAudio();
      final builder =
          TimelineMediaBuilder(thumbnails: thumbs.service, audio: audio.service);

      final media = await builder.build(
        videoPath: '/v/a.mp4',
        taskId: 't6',
        durationMs: 6000,
        workDir: workDir,
        thumbCount: 2,
        waveBuckets: 4,
      );

      // 两张都应触发真实抽帧：坏缓存不能被当成命中
      expect(thumbs.calls.length, 2);
      expect(media.thumbPaths, [
        '${workDir.path}/t6_tl2_0.jpg',
        '${workDir.path}/t6_tl2_1.jpg',
      ]);
    });

    test('波形算完就把中转 PCM 丢掉，只留几 KB 的包络缓存', () async {
      final thumbs = fakeThumbnails();
      final audio = fakeAudio();
      final builder =
          TimelineMediaBuilder(thumbnails: thumbs.service, audio: audio.service);

      await builder.build(
        videoPath: '/v/a.mp4',
        taskId: 't8',
        durationMs: 6000,
        workDir: workDir,
        thumbCount: 1,
        waveBuckets: 4,
      );

      expect(audio.calls.single.last, analysisPcmPath(workDir, 't8'),
          reason: '提取仍走管线那条共享路径，不另写一份 _tl.pcm');
      expect(await File('${workDir.path}/t8.pcm').exists(), isFalse,
          reason: '18MB 的 PCM 只是中转，时间线要的是包络');
      expect(await File(timelineWavePath(workDir, 't8')).exists(), isTrue);
      expect(await File('${workDir.path}/t8_tl.pcm').exists(), isFalse);
    });

    test('第二次进来直接读包络缓存，不再解一遍音频', () async {
      final thumbs = fakeThumbnails();
      final audio = fakeAudio();
      final builder =
          TimelineMediaBuilder(thumbnails: thumbs.service, audio: audio.service);

      Future<TimelineMedia> once() => builder.build(
            videoPath: '/v/a.mp4',
            taskId: 't9',
            durationMs: 6000,
            workDir: workDir,
            thumbCount: 1,
            waveBuckets: 4,
          );

      final first = await once();
      final second = await once();

      expect(audio.calls, hasLength(1), reason: '第二次该命中包络缓存');
      expect(second.waveEnvelope, first.waveEnvelope);
    });

    test('换了桶数就重算——按别的桶数画的波形和时间线对不齐', () async {
      final thumbs = fakeThumbnails();
      final audio = fakeAudio();
      final builder =
          TimelineMediaBuilder(thumbnails: thumbs.service, audio: audio.service);

      Future<void> once(int buckets) => builder.build(
            videoPath: '/v/a.mp4',
            taskId: 't10',
            durationMs: 6000,
            workDir: workDir,
            thumbCount: 1,
            waveBuckets: buckets,
          );

      await once(4);
      await once(8);

      expect(audio.calls, hasLength(2));
    });

    test('分析管线已产出的 PCM 被直接复用，不再重复提取', () async {
      // 模拟分析管线先跑完留下的 PCM
      await File(analysisPcmPath(workDir, 't9'))
          .writeAsBytes(_pcm16Bytes(const [500, -500, 500, -500]));

      final thumbs = fakeThumbnails();
      final audio = fakeAudio();
      final builder =
          TimelineMediaBuilder(thumbnails: thumbs.service, audio: audio.service);

      await builder.build(
        videoPath: '/v/a.mp4',
        taskId: 't9',
        durationMs: 6000,
        workDir: workDir,
        thumbCount: 1,
        waveBuckets: 4,
      );

      expect(audio.calls, isEmpty);
    });

    test('PCM 缓存文件为 0 字节（损坏）时应重新提取音频，不复用坏文件', () async {
      // 预置一个 0 字节的坏 PCM 缓存（模拟上次运行中途失败留下的产物）
      final badPcmPath = analysisPcmPath(workDir, 't7');
      await File(badPcmPath).writeAsBytes(const []);

      final thumbs = fakeThumbnails();
      final audio = fakeAudio();
      final builder =
          TimelineMediaBuilder(thumbnails: thumbs.service, audio: audio.service);

      await builder.build(
        videoPath: '/v/a.mp4',
        taskId: 't7',
        durationMs: 6000,
        workDir: workDir,
        thumbCount: 2,
        waveBuckets: 4,
      );

      expect(audio.calls.length, 1);
    });
  });
}
