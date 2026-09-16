import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/models/tag_group_ref.dart';
import 'package:ishkafel/core/models/video_info.dart';
import 'package:path/path.dart' as p;

RenewTask buildWindowsVisualFixture({
  required String sourcePath,
  required int sourceBytes,
}) {
  const shotCounts = [6, 5, 6, 5, 6, 5, 5];
  const transcripts = [
    '每天回到家，先把容易接触到的地方认真清洁一遍。',
    '细密喷雾覆盖更均匀，桌面、门把手和随身物品都能照顾到。',
    '清爽不黏手，日常使用也不会给生活增加负担。',
    '温和配方适合全家场景，让每一次接触都更安心。',
    '小巧瓶身放进包里，通勤和旅行随时都能拿出来。',
    '从进门到出门，把洁净变成顺手完成的小习惯。',
    '植源喷雾，陪你认真守护每一个日常瞬间。',
  ];
  final units = <SemanticUnit>[];
  var cursor = 0;
  for (var unitIndex = 0; unitIndex < shotCounts.length; unitIndex++) {
    final unitStart = cursor;
    final unitEnd = unitStart + 5000;
    final count = shotCounts[unitIndex];
    final shots = <Shot>[];
    for (var shotIndex = 0; shotIndex < count; shotIndex++) {
      final start = unitStart + (5000 * shotIndex / count).round();
      final end = unitStart + (5000 * (shotIndex + 1) / count).round();
      shots.add(
        Shot(
          startMs: start,
          endMs: end,
          tags: [shotIndex.isEven ? '产品特写' : '生活场景', '明亮'],
          description: '第 ${unitIndex + 1} 段第 ${shotIndex + 1} 个视觉镜头',
          productBrand: shotIndex == 0 ? '植源' : null,
        ),
      );
    }
    units.add(
      SemanticUnit(
        uid: 'windows-visual-u${unitIndex + 1}',
        index: unitIndex,
        startMs: unitStart,
        endMs: unitEnd,
        transcript: transcripts[unitIndex],
        tags: const ['家庭清洁', '安心守护'],
        shots: shots,
      ),
    );
    cursor = unitEnd;
  }

  final now = DateTime.utc(2026, 9, 16, 4, 0);
  return RenewTask(
    id: 'windows-visual-workbench',
    seq: 4,
    name: 'Windows 视觉回归 · 植源喷雾',
    sourcePath: sourcePath,
    videoInfo: VideoInfo(
      width: 1080,
      height: 1920,
      duration: Duration(milliseconds: cursor),
      fps: 30,
      fileSizeBytes: sourceBytes,
    ),
    status: RenewTaskStatus.ready,
    createdAt: now,
    updatedAt: now,
    units: units,
    unitTagGroups: const [TagGroupRef(id: 1001, name: '台词语义')],
    shotTagGroups: const [TagGroupRef(id: 1002, name: '视觉镜头')],
    unitTagPrompt: '按表达意图选择标签',
    shotTagPrompt: '按画面主体与场景选择标签',
    firstReadyMs: 42000,
  );
}

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('data-dir', mandatory: true)
    ..addOption('source', mandatory: true);
  final options = parser.parse(arguments);
  final dataDir = Directory(p.absolute(options.option('data-dir')!));
  final source = File(p.absolute(options.option('source')!));
  if (!source.existsSync()) {
    throw ArgumentError('Source video does not exist: ${source.path}');
  }
  final task = buildWindowsVisualFixture(
    sourcePath: source.path,
    sourceBytes: source.lengthSync(),
  );
  final tasksDir = Directory(p.join(dataDir.path, 'tasks'));
  await tasksDir.create(recursive: true);
  final destination = File(p.join(tasksDir.path, '${task.id}.json'));
  await destination.writeAsString(jsonEncode(task.toJson()));
  stdout.writeln(destination.path);
}
