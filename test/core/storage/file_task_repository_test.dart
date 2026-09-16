import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/providers.dart';
import 'package:ishkafel/core/log/app_log.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/models/video_info.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';

RenewTask makeTask(String id, DateTime updatedAt) => RenewTask(
  id: id,
  name: '任务$id',
  sourcePath: '/v/$id.mp4',
  status: RenewTaskStatus.analyzing,
  createdAt: DateTime.utc(2026, 7, 29),
  updatedAt: updatedAt,
);

/// 真实规模的任务：96 秒素材 / 10 个台词语义单元 / 48 个视觉镜头 /
/// 26 句 ASR / 586 个字级时间戳，落盘约 44 KB——线上任务 JSON 的真实体量。
RenewTask makeHeavyTask(String id) {
  const totalMs = 96000;
  const shotsPerUnit = 5;
  final units = [
    for (var i = 0; i < 10; i++)
      SemanticUnit(
        index: i,
        startMs: i * 9600,
        endMs: (i + 1) * 9600,
        transcript: '这是第 $i 个台词语义单元的完整台词文本，长度贴近真实口播的一句话内容。',
        tags: const ['口播', '产品特写'],
        shots: [
          for (var s = 0; s < shotsPerUnit; s++)
            Shot(
              startMs: i * 9600 + s * 1920,
              endMs: i * 9600 + (s + 1) * 1920,
              tags: const ['近景'],
            ),
        ],
      ),
  ];
  final sentences = [
    for (var i = 0; i < 26; i++)
      AsrSentence(
        startMs: i * 3692,
        endMs: (i + 1) * 3692,
        text: '第 $i 句识别文本，内容与口播台词一致，用于对齐语义单元边界。',
        words: [
          for (var w = 0; w < 23; w++)
            AsrWord(
              startMs: i * 3692 + w * 160,
              endMs: i * 3692 + (w + 1) * 160,
              text: '字',
              confidence: 0.93,
            ),
        ],
      ),
  ];
  return RenewTask(
    id: id,
    name: '滴露_植源喷雾_$id',
    sourcePath: '/Users/x/Movies/素材/$id.mp4',
    videoInfo: const VideoInfo(
      width: 1080,
      height: 1920,
      duration: Duration(milliseconds: totalMs),
      fps: 30,
      fileSizeBytes: 41234567,
    ),
    coverPath: '/Users/x/Library/ishkafel/covers/$id.jpg',
    status: RenewTaskStatus.ready,
    createdAt: DateTime.utc(2026, 7, 20, 10),
    updatedAt: DateTime.utc(
      2026,
      7,
      20,
      11,
    ).add(Duration(seconds: id.hashCode % 1000)),
    units: units,
    asrSentences: sentences,
  );
}

void main() {
  late Directory tempDir;
  late FileTaskRepository repo;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ishkafel_test_');
    repo = FileTaskRepository(tempDir);
  });

  tearDown(() async => tempDir.delete(recursive: true));

  test('save 后 findById 取回相同任务', () async {
    final task = makeTask('a', DateTime.utc(2026, 7, 29, 10));
    await repo.save(task);
    expect(await repo.findById('a'), task);
  });

  test('findById 不存在返回 null', () async {
    expect(await repo.findById('nope'), isNull);
  });

  test('findAll 按 updatedAt 倒序', () async {
    await repo.save(makeTask('old', DateTime.utc(2026, 7, 28)));
    await repo.save(makeTask('new', DateTime.utc(2026, 7, 30)));
    final all = await repo.findAll();
    expect(all.map((t) => t.id).toList(), ['new', 'old']);
  });

  test('save 同 id 为覆盖更新', () async {
    final t = makeTask('a', DateTime.utc(2026, 7, 29));
    await repo.save(t);
    await repo.save(t.copyWith(name: '改名'));
    expect((await repo.findById('a'))!.name, '改名');
    expect((await repo.findAll()).length, 1);
  });

  test('并发保存同一任务不争抢 Windows rename 且最后一次调用获胜', () async {
    final initial = makeHeavyTask('concurrent-save');
    await repo.save(initial);

    final writes = [
      for (var i = 0; i < 64; i++)
        repo.save(initial.copyWith(
          name: '版本$i',
          updatedAt: initial.updatedAt.add(Duration(milliseconds: i)),
        )),
    ];
    await Future.wait(writes);

    expect((await repo.findById(initial.id))!.name, '版本63');
    final leakedTemps = await Directory('${tempDir.path}/tasks')
        .list()
        .where((entity) => entity.path.endsWith('.tmp'))
        .toList();
    expect(leakedTemps, isEmpty);
  });

  test('delete 后不可见且不抛错', () async {
    await repo.save(makeTask('a', DateTime.utc(2026, 7, 29)));
    await repo.delete('a');
    await repo.delete('a'); // 幂等
    expect(await repo.findById('a'), isNull);
  });

  test('损坏的 JSON 文件被跳过而非炸掉 findAll', () async {
    await repo.save(makeTask('good', DateTime.utc(2026, 7, 29)));
    final bad = File('${tempDir.path}/tasks/bad.json');
    await bad.writeAsString('{not valid');
    final all = await repo.findAll();
    expect(all.map((t) => t.id).toList(), ['good']);
  });

  test('语法合法但字段类型错误的 JSON 被 findAll 跳过', () async {
    await repo.save(makeTask('good', DateTime.utc(2026, 7, 29)));
    final badType = File('${tempDir.path}/tasks/badtype.json');
    // id 是数字，不是字符串 → RenewTask.fromJson 会抛 TypeError
    await badType.writeAsString(
      '{"id": 123, "name": "test", "sourcePath": "/v/test.mp4", "status": "analyzing", "createdAt": "2026-07-29T00:00:00.000Z", "updatedAt": "2026-07-29T00:00:00.000Z"}',
    );
    final all = await repo.findAll();
    expect(all.map((t) => t.id).toList(), ['good']);
  });

  test('字段类型错误的 JSON 文件 findById 返回 null', () async {
    final tasksDir = Directory('${tempDir.path}/tasks');
    await tasksDir.create(recursive: true);
    final badType = File('${tempDir.path}/tasks/badtype.json');
    await badType.writeAsString(
      '{"id": 123, "name": "test", "sourcePath": "/v/test.mp4", "status": "analyzing", "createdAt": "2026-07-29T00:00:00.000Z", "updatedAt": "2026-07-29T00:00:00.000Z"}',
    );
    expect(await repo.findById('badtype'), isNull);
  });

  test('status 为未知枚举名的任务仍能读出（回退安全状态，不再整条消失）', () async {
    await repo.save(makeTask('good', DateTime.utc(2026, 7, 29)));
    final bad = File('${tempDir.path}/tasks/bad_enum.json');
    await bad.create(recursive: true);
    await bad.writeAsString(
      '{"id":"bad_enum","name":"n","sourcePath":"/x.mp4","status":"notAStatus",'
      '"createdAt":"2026-01-01T00:00:00.000Z","updatedAt":"2026-01-01T00:00:00.000Z"}',
    );
    final all = await repo.findAll();
    expect(all.map((t) => t.id).toSet(), {'good', 'bad_enum'});
    expect(repo.skippedTaskFileCount, 0);
  });

  test('status 为未知枚举名的文件 findById 也能读出', () async {
    final bad = File('${tempDir.path}/tasks/x.json');
    await bad.create(recursive: true);
    await bad.writeAsString(
      '{"id":"x","name":"n","sourcePath":"/x.mp4","status":"notAStatus",'
      '"createdAt":"2026-01-01T00:00:00.000Z","updatedAt":"2026-01-01T00:00:00.000Z"}',
    );
    final parsed = await repo.findById('x');
    expect(parsed, isNotNull);
    expect(parsed!.status, RenewTaskStatus.ready);
  });

  group('单个文件的 I/O 异常只跳过那一个文件（Important 7）', () {
    test('读不出来的任务文件被跳过并计数，其余任务照常返回', () async {
      await repo.save(makeTask('good', DateTime.utc(2026, 7, 29)));
      final locked = File('${tempDir.path}/tasks/locked.json');
      await locked.writeAsString('{}');
      // 模拟「权限不足 / 文件刚好被删 / 外接卷掉线」这类 FileSystemException：
      // readAsString 会抛 PathNotFoundException 等 FileSystemException 子类，
      // 它们不是 FormatException/TypeError/ArgumentError，会穿透整批装载
      if (Platform.isWindows) {
        final user = Platform.environment['USERNAME']!;
        final denied = await Process.run('icacls.exe', [
          locked.path,
          '/inheritance:r',
          '/deny',
          '$user:(R)',
        ]);
        expect(denied.exitCode, 0, reason: '${denied.stderr}');
        addTearDown(
          () =>
              Process.run('icacls.exe', [locked.path, '/grant:r', '$user:(F)']),
        );
      } else {
        await Process.run('chmod', ['000', locked.path]);
        addTearDown(() => Process.run('chmod', ['644', locked.path]));
      }

      final all = await repo.findAll();

      expect(all.map((t) => t.id).toList(), [
        'good',
      ], reason: '一个读不出来的文件不能让整个任务列表消失');
      expect(repo.skippedTaskFileCount, 1);
    });
  });

  group('跳过的损坏任务文件要上报，不能只写日志', () {
    test('findAll 记录本次跳过的文件数', () async {
      await repo.save(makeTask('good', DateTime.utc(2026, 7, 29)));
      await File('${tempDir.path}/tasks/bad1.json').writeAsString('{not valid');
      await File('${tempDir.path}/tasks/bad2.json').writeAsString(
        '{"id": 123, "name": "t", "sourcePath": "/v.mp4",'
        '"status": "analyzing", "createdAt": "2026-07-29T00:00:00.000Z",'
        '"updatedAt": "2026-07-29T00:00:00.000Z"}',
      );

      final all = await repo.findAll();

      expect(all.map((t) => t.id).toList(), ['good']);
      expect(repo.skippedTaskFileCount, 2);
    });

    test('再次 findAll 全部正常时计数归零（反映最近一次装载）', () async {
      await Directory('${tempDir.path}/tasks').create(recursive: true);
      await File('${tempDir.path}/tasks/bad.json').writeAsString('{not valid');
      await repo.findAll();
      expect(repo.skippedTaskFileCount, 1);

      await File('${tempDir.path}/tasks/bad.json').delete();
      await repo.save(makeTask('good', DateTime.utc(2026, 7, 29)));
      await repo.findAll();

      expect(repo.skippedTaskFileCount, 0);
    });
  });

  group('解码不占用 UI isolate', () {
    /// 模拟 60fps 渲染：每 16.67 ms 在主 isolate 上占用 12 ms 做同步工作
    /// （用户正在滚动任务网格时的真实帧成本），即主 isolate 只剩约 28% 余量。
    Timer startFrameLoad() =>
        Timer.periodic(const Duration(microseconds: 16667), (_) {
          final busy = Stopwatch()..start();
          while (busy.elapsedMicroseconds < 12000) {}
        });

    Future<int> measureFindAllMs() async {
      final stopwatch = Stopwatch()..start();
      await repo.findAll();
      return stopwatch.elapsedMilliseconds;
    }

    test('UI 忙于渲染时 findAll 不被拖慢（说明解码没跟渲染抢主 isolate）', () async {
      for (var i = 0; i < 60; i++) {
        await repo.save(makeHeavyTask('h$i'));
      }
      await repo.findAll(); // 预热：抹平 isolate 冷启动与文件缓存差异

      final idleMs = await measureFindAllMs();
      final frameLoad = startFrameLoad();
      final busyMs = await measureFindAllMs();
      frameLoad.cancel();

      expect(idleMs, greaterThanOrEqualTo(5), reason: '样本太小则比值没有区分度');
      // 解码留在 UI isolate 时只能抢到约 28% 的主线程，耗时会涨到 3~5 倍
      // （实测 100 条：131 ms → 573 ms）；搬到后台 isolate 后基本不受影响。
      expect(
        busyMs,
        lessThan(idleMs * 2.5),
        reason: '解码仍在 UI isolate 上跟渲染抢时间片（空闲 $idleMs ms → 繁忙 $busyMs ms）',
      );
    });

    test('跳过坏文件的告警仍走主 isolate 的 AppLog 出口（不能因换 isolate 而丢日志）', () async {
      final captured = <String>[];
      final original = AppLog.sink;
      AppLog.sink = captured.add;
      addTearDown(() => AppLog.sink = original);

      await repo.save(makeTask('good', DateTime.utc(2026, 7, 29)));
      await File('${tempDir.path}/tasks/bad.json').writeAsString('{not valid');
      await repo.findAll();

      expect(
        captured.where((l) => l.contains('bad.json')),
        isNotEmpty,
        reason: '后台 isolate 的 AppLog.sink 是另一份 static，日志必须带回主 isolate 输出',
      );
    });

    test('跨 isolate 传回的任务对象与原对象逐字段相等（含 units / ASR 字级时间戳）', () async {
      final original = makeHeavyTask('roundtrip');
      await repo.save(original);

      final loaded = (await repo.findAll()).single;

      expect(loaded, original);
      expect(loaded.units!.length, 10);
      expect(loaded.asrSentences!.expand((s) => s.words).length, 26 * 23);
    });
  });
}
