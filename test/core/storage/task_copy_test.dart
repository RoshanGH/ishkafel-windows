import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/providers.dart' show AsrSentence;
import 'package:ishkafel/core/ai/ai_usage.dart';
import 'package:ishkafel/core/audio/bgm_plan.dart';
import 'package:ishkafel/core/models/export_record.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/replacement/picked_material.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';
import 'package:ishkafel/core/storage/task_artifacts.dart';
import 'package:ishkafel/core/storage/task_copy.dart';
import 'package:path/path.dart' as p;

/// 复制一条任务，**两条任务之间完全隔离**。
///
/// 用户 2026-09-14：「它可以复制一个一模一样的任务，但是两个任务要完全隔离。
/// 我现在想明白这个问题了，任务间一定是完全隔离的。」
///
/// 隔离的判据很具体：**删掉原任务，副本必须一点事都没有**。
void main() {
  late Directory dir;
  late TaskCopier copier;
  const oldId = 'src123';
  const newId = 'copy789';

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ishkafel_copy_');
    copier = TaskCopier(dir);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  /// 在数据目录里造一个产物文件
  String put(String relative, [String content = 'x']) {
    final f = File(p.join(dir.path, relative));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
    return f.path;
  }

  RenewTask source() => RenewTask(
    id: oldId,
    seq: 3,
    name: 'JC_滴露_自然消毒液',
    // 用户自己的原片：**不在数据目录里**
    sourcePath: '/Users/me/Movies/原片.mp4',
    status: RenewTaskStatus.ready,
    createdAt: DateTime.utc(2026, 9, 1),
    updatedAt: DateTime.utc(2026, 9, 10),
    coverPath: put('covers/$oldId.jpg'),
    vocalsPath: put('analysis_work/stems/$oldId/人声.wav'),
    backgroundPath: put('analysis_work/stems/$oldId/背景.wav'),
    units: const [
      SemanticUnit(
        uid: 'u0',
        index: 0,
        startMs: 0,
        endMs: 4000,
        transcript: 'U1',
        shots: [Shot(startMs: 0, endMs: 4000)],
      ),
    ],
    replacementsByUid: {
      'u0': UnitReplacement.perShot({
        0: [77],
      }),
    },
    pickedMaterials: [
      PickedMaterial(
        id: 77,
        name: '素材 77',
        thumbPath: put('picked_thumbs/$oldId/77.jpg'),
      ),
    ],
    bgm: const BgmPlan([
      BgmSegment(
        startUnit: 0,
        endUnit: 0,
        fit: BgmFit.loop,
        materials: [
          BgmMaterial(id: 9, name: '垫乐', durationMs: 30000, previewUrl: null),
        ],
      ),
    ]),
    exports: [
      ExportRecord(
        at: DateTime.utc(2026, 9, 10),
        total: 2,
        succeeded: 2,
        outputDir: '/tmp/out',
      ),
    ],
    firstReadyMs: 22538,
    aiUsage: AiUsage.empty.plusService(
      service: SpeechService.asrFlash,
      quantity: 75,
    ),
  );

  Future<RenewTask> copy({int? seq = 8}) => copier.duplicate(
    source(),
    newId: newId,
    seq: seq,
    now: DateTime.utc(2026, 9, 14),
  );

  group('身份', () {
    test('新 id、新编号、名字带「的副本」、时间是现在', () async {
      final c = await copy();
      expect(c.id, newId);
      expect(c.seq, 8);
      expect(c.name, 'JC_滴露_自然消毒液 的副本');
      expect(c.createdAt, DateTime.utc(2026, 9, 14));
    });

    test('方案原样抄过去——「一模一样」说的就是这些', () async {
      final c = await copy();
      expect(c.units!.first.transcript, 'U1');
      expect(c.replacementsByUid['u0']!.shotCandidateIds[0], [77]);
      expect(c.pickedMaterials.single.id, 77);
      expect(c.bgm.segments.single.materials.single.id, 9);
      expect(c.sourcePath, '/Users/me/Movies/原片.mp4');
    });

    test('属于「那一次」的东西不抄：导出历史、花掉的钱、等待时长、上次的报错', () async {
      final c = await copy();
      expect(c.exports, isEmpty, reason: '副本还没导过片子');
      expect(c.aiUsage.calls, 0, reason: '副本没花过钱，抄过去等于重复计账');
      expect(c.firstReadyMs, isNull, reason: '副本没让人等过');
      expect(c.analysisError, isNull);
    });
  });

  group('路径改写：删了原任务，副本不能瞎', () {
    test('任务里存的每一条路径都指到新任务名下', () async {
      final c = await copy();
      expect(c.coverPath, p.join(dir.path, 'covers', '$newId.jpg'));
      expect(c.vocalsPath, contains(p.join('stems', newId)));
      expect(c.backgroundPath, contains(p.join('stems', newId)));
      expect(
        c.pickedMaterials.single.thumbPath,
        contains(p.join('picked_thumbs', newId)),
      );
      // 一条都不许还指着老任务
      for (final path in [
        c.coverPath,
        c.vocalsPath,
        c.backgroundPath,
        c.pickedMaterials.single.thumbPath,
      ]) {
        expect(path, isNot(contains(oldId)), reason: '$path 还指着原任务');
      }
    });

    test('用户自己的原片一个字节都不碰——它不在数据目录里', () async {
      final c = await copy();
      expect(c.sourcePath, '/Users/me/Movies/原片.mp4');
    });

    test('删掉原任务的全部产物，副本指的文件还都在', () async {
      final c = await copy();
      TaskArtifacts(dir).delete(TaskArtifacts(dir).of(oldId));

      expect(File(c.coverPath!).existsSync(), isTrue);
      expect(File(c.vocalsPath!).existsSync(), isTrue);
      expect(File(c.backgroundPath!).existsSync(), isTrue);
      expect(File(c.pickedMaterials.single.thumbPath!).existsSync(), isTrue);
    });
  });

  group('产物：该带的带、派生的不带', () {
    test('配音、素材、首帧图、人声轨、封面跟着走', () async {
      put('voices/$oldId/unit_u0.mp3');
      put('materials/$oldId/77.mp4');
      await copy();

      expect(
        File(p.join(dir.path, 'voices', newId, 'unit_u0.mp3')).existsSync(),
        isTrue,
        reason: '配音重做是花钱的 TTS',
      );
      expect(
        File(p.join(dir.path, 'materials', newId, '77.mp4')).existsSync(),
        isTrue,
      );
      expect(
        File(p.join(dir.path, 'covers', '$newId.jpg')).existsSync(),
        isTrue,
      );
    });

    test('导出中间产物不带——副本本来就该从零导', () async {
      put('export_work/$oldId/video_1.mp4');
      await copy();
      expect(
        Directory(p.join(dir.path, 'export_work', newId)).existsSync(),
        isFalse,
      );
    });

    test('预览代理、变速切片这些派生的不带，用到自然重建', () async {
      put('proxy/$oldId/proxy.mp4');
      put('speed_fit/$oldId/clip.mp4');
      await copy();
      expect(Directory(p.join(dir.path, 'proxy', newId)).existsSync(), isFalse);
      expect(
        Directory(p.join(dir.path, 'speed_fit', newId)).existsSync(),
        isFalse,
      );
    });

    test('原任务的产物原样留着——复制不是搬家', () async {
      put('materials/$oldId/77.mp4');
      await copy();
      expect(
        File(p.join(dir.path, 'materials', oldId, '77.mp4')).existsSync(),
        isTrue,
      );
    });

    test('先报要占多大：让人在点之前知道', () async {
      source(); // 造出封面、人声轨、首帧图
      put('materials/$oldId/big.mp4', 'x' * 1000);
      // 素材 1000 字节 + 封面 + 两条人声轨 + 首帧图，都该算进去
      expect(copier.estimatedBytes(oldId), greaterThan(1000));
      // 不该算的：导出中间产物（真机上一条 373M，副本不带它）
      put('export_work/$oldId/huge.mp4', 'x' * 5000);
      expect(copier.estimatedBytes(oldId), lessThan(2000));
    });
  });

  group('拦与命名', () {
    test('还在分析的不给复制——抄过去只有一半产物', () {
      final analyzing = RenewTask(
        id: 'a',
        name: 'x',
        status: RenewTaskStatus.analyzing,
        createdAt: DateTime.utc(2026, 9, 14),
        updatedAt: DateTime.utc(2026, 9, 14),
      );
      expect(taskCopyBlockedReason(analyzing), isNotNull);
      expect(taskCopyBlockedReason(source()), isNull);
    });

    test('连着复制同一条：名字往后排，不撞车', () {
      expect(copiedTaskName('片子', []), '片子 的副本');
      expect(copiedTaskName('片子', ['片子 的副本']), '片子 的副本 2');
      expect(copiedTaskName('片子', ['片子 的副本', '片子 的副本 2']), '片子 的副本 3');
    });
  });

  group('固定过底片的单元，复制之后一样不少', () {
    test('底片、转写、台词、镜头全带过去', () async {
      final src = source().copyWith(units: [
        const SemanticUnit(
          uid: 'ua',
          index: 0,
          startMs: 0,
          endMs: 16300,
          transcript: '底片转出来的话',
          hasSource: false,
          baseCandidateId: 7,
          baseSentences: [
            AsrSentence(startMs: 40, endMs: 3320, text: '底片转出来的话', words: []),
          ],
          shots: [
            Shot(startMs: 0, endMs: 8000),
            Shot(startMs: 8000, endMs: 16300),
          ],
        ),
      ]);
      final copy = await copier.duplicate(src,
          newId: 'c1', seq: 2, now: DateTime.utc(2026, 9, 15));
      final u = copy.units!.first;

      expect(u.baseCandidateId, 7, reason: '不带的话副本那一段就没画面了');
      expect(u.baseSentences, hasLength(1), reason: '不带就没字幕');
      expect(u.transcript, '底片转出来的话');
      expect(u.shots, hasLength(2));
    });
  });
}
