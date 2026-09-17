import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/export/export_cancel.dart';
import 'package:ishkafel/core/export/export_runner.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';
import 'package:path/path.dart' as p;

/// **导出能停下来，已经导完的一条都不少。**
///
/// 产品负责人 2026-09-16：「导出一次好几十条，甚至 100 条，让导出可以取消，
/// 已经导出的就留着当导出成功的物料。」
///
/// 停的规矩是他定的：已导完的全留、正在导的那条丢掉（不许在输出目录里留
/// 半成品——它看起来和成片一模一样）、还没轮到的标「已停止」而不是「失败」。
void main() {
  /// 假 ffmpeg。[onCall] 用来在「跑到第几次」时按下停止
  ({ExportRunner runner, Directory out, List<List<String>> calls}) build({
    void Function(List<String> args)? onCall,
  }) {
    final calls = <List<String>>[];
    final work = Directory.systemTemp.createTempSync('ishkafel_cancel_work_');
    final out = Directory.systemTemp.createTempSync('ishkafel_cancel_out_');
    addTearDown(() {
      if (work.existsSync()) work.deleteSync(recursive: true);
      if (out.existsSync()) out.deleteSync(recursive: true);
    });
    Future<ProcessResult> run(String bin, List<String> args) async {
      calls.add(args);
      onCall?.call(args);
      File(args.last).writeAsStringSync('x');
      return ProcessResult(1, 0, '', '');
    }

    return (
      runner: ExportRunner(
        run: run,
        workDir: work,
        fetchMaterial: (id) async {
          final f = File('${work.path}/m$id.mp4')..writeAsStringSync('m');
          return f.path;
        },
      ),
      out: out,
      calls: calls,
    );
  }

  List<SemanticUnit> units() => const [
    SemanticUnit(
      index: 0,
      startMs: 0,
      endMs: 2000,
      transcript: 'U1',
      shots: [Shot(startMs: 0, endMs: 2000)],
    ),
    SemanticUnit(
      index: 1,
      startMs: 2000,
      endMs: 5000,
      transcript: 'U2',
      shots: [Shot(startMs: 2000, endMs: 5000)],
    ),
  ];

  /// 四条变体：镜头替换，声音共用一份
  List<UnitReplacement> fourWays() => [
    UnitReplacement.perShot(const {
      0: [11, 12, 13, 14],
    }),
    UnitReplacement.keepOriginal(),
  ];

  test('没按停止时一切照旧——开关只是挂在那儿，不影响正常导出', () async {
    final b = build();
    final cancel = ExportCancelToken();

    final results = await b.runner.exportAll(
      sourcePath: '/v/a.mp4',
      units: units(),
      replacements: fourWays(),
      outputDir: b.out,
      cancel: cancel,
    );

    expect(results.map((r) => r.ok), [true, true, true, true]);
    expect(results.every((r) => r.cancelled), isFalse);
  });

  test('导到一半按停止：已导完的全留着，剩下的标「已停止」不是「失败」', () async {
    late ExportCancelToken cancel;
    // 第一条的成片一落地就按停止
    final b = build(
      onCall: (args) {
        if (args.last.endsWith('变体1.mp4')) cancel.cancel();
      },
    );
    cancel = ExportCancelToken();

    final results = await b.runner.exportAll(
      sourcePath: '/v/a.mp4',
      units: units(),
      replacements: fourWays(),
      outputDir: b.out,
      cancel: cancel,
    );

    expect(results, hasLength(4), reason: '四条都要有交代，不能凭空少几条');
    expect(results.first.ok, isTrue, reason: '第一条已经导完了，它是能交付的物料');
    expect(File(results.first.path!).existsSync(), isTrue);

    final rest = results.skip(1);
    expect(rest.every((r) => r.cancelled), isTrue);
    expect(
      rest.every((r) => r.failure == null),
      isTrue,
      reason: '失败要人去查原因，而停止的原因就是他自己按的',
    );
  });

  test('正在导的那条不许在输出目录里留半成品', () async {
    late ExportCancelToken cancel;
    // 第一条导完之后、第二条还在渲的途中按下停止
    var seenFirst = false;
    final b = build(
      onCall: (args) {
        if (args.last.endsWith('变体1.mp4')) {
          seenFirst = true;
          return;
        }
        if (seenFirst) cancel.cancel();
      },
    );
    cancel = ExportCancelToken();

    final results = await b.runner.exportAll(
      sourcePath: '/v/a.mp4',
      units: units(),
      replacements: fourWays(),
      outputDir: b.out,
      cancel: cancel,
    );

    final files = b.out
        .listSync()
        .whereType<File>()
        .map((f) => p.basename(f.path))
        .toList();
    expect(
      files,
      ['变体1.mp4'],
      reason:
          '输出目录里只该有导完的那一条——半成品看起来和成片一模一样，'
          '留着迟早被当成能交付的东西发出去',
    );
    expect(results.where((r) => r.ok), hasLength(1));
  });

  test('一条都还没导完就停：全标「已停止」，不报成一屏失败', () async {
    late ExportCancelToken cancel;
    // 第一次拉 ffmpeg 就按停止（那时还在合声音）
    final b = build(onCall: (_) => cancel.cancel());
    cancel = ExportCancelToken();

    final results = await b.runner.exportAll(
      sourcePath: '/v/a.mp4',
      units: units(),
      replacements: fourWays(),
      outputDir: b.out,
      cancel: cancel,
    );

    expect(results, hasLength(4));
    expect(results.every((r) => r.cancelled), isTrue);
    expect(
      results.every((r) => r.failure == null),
      isTrue,
      reason: '按了停止却看到一屏「声音合成失败」，人会以为软件坏了',
    );
  });

  test('开了停止之后一步都不许再跑——按下就是按下', () async {
    late ExportCancelToken cancel;
    var callsAfterCancel = 0;
    var cancelled = false;
    final b = build(
      onCall: (_) {
        if (cancelled) callsAfterCancel++;
        if (!cancelled) {
          cancel.cancel();
          cancelled = true;
        }
      },
    );
    cancel = ExportCancelToken();

    await b.runner.exportAll(
      sourcePath: '/v/a.mp4',
      units: units(),
      replacements: fourWays(),
      outputDir: b.out,
      cancel: cancel,
    );

    expect(callsAfterCancel, 0, reason: '检查点在拉子进程之前，按下之后不该再起新的 ffmpeg');
  });
}
