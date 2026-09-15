import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/export/export_plan.dart';
import 'package:ishkafel/core/export/export_runner.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';
import 'package:path/path.dart' as p;

/// 假 ffmpeg：真的把输出文件写出来（覆盖与否要看得见）
Future<ProcessResult> _ffmpeg(String bin, List<String> args) async {
  File(
    args.last,
  ).writeAsStringSync('这一批 ${DateTime.now().microsecondsSinceEpoch}');
  return ProcessResult(1, 0, '', '');
}

List<SemanticUnit> _units() => const [
  SemanticUnit(
    index: 0,
    startMs: 0,
    endMs: 2000,
    transcript: 'U1',
    shots: [Shot(startMs: 0, endMs: 2000)],
  ),
];

void main() {
  test('导第二批到同一个目录，上一批的成片还在——不能被同名顶掉', () async {
    final out = Directory.systemTemp.createTempSync('ishkafel_overwrite_out_');
    addTearDown(() => out.deleteSync(recursive: true));

    Future<List<String>> exportOnce(List<int> candidates) async {
      final work = Directory.systemTemp.createTempSync('ishkafel_overwrite_w_');
      addTearDown(() {
        if (work.existsSync()) work.deleteSync(recursive: true);
      });
      final runner = ExportRunner(
        run: _ffmpeg,
        workDir: work,
        fetchMaterial: (id) async =>
            (File('${work.path}/m$id.mp4')..writeAsStringSync('m')).path,
      );
      final results = await runner.exportAll(
        sourcePath: '/v/a.mp4',
        units: _units(),
        replacements: [UnitReplacement.whole(candidates)],
        outputDir: out,
      );
      expect(results.every((r) => r.ok), isTrue);
      return [for (final r in results) r.path!];
    }

    final first = await exportOnce([11, 12]);
    final firstBytes = {
      for (final path in first) path: File(path).readAsStringSync(),
    };

    // 换一批素材再导一次：组合数一样，文件名照旧算出「变体1/变体2」
    final second = await exportOnce([21, 22]);

    expect(
      second.toSet().intersection(first.toSet()),
      isEmpty,
      reason: '第二批不能落在第一批的文件名上',
    );
    for (final entry in firstBytes.entries) {
      expect(
        File(entry.key).existsSync(),
        isTrue,
        reason: '第一批的 ${entry.key} 不该消失',
      );
      expect(
        File(entry.key).readAsStringSync(),
        entry.value,
        reason: '第一批的 ${entry.key} 内容被改写了',
      );
    }
    expect(out.listSync().whereType<File>().length, 4, reason: '两批各两条，四个文件都该在');
    expect(second.map(p.basename), ['变体1(2).mp4', '变体2(2).mp4']);
  });

  test('同一批里两条方案重名，后一条也不覆盖前一条', () async {
    final out = Directory.systemTemp.createTempSync('ishkafel_dup_name_out_');
    final work = Directory.systemTemp.createTempSync('ishkafel_dup_name_w_');
    addTearDown(() {
      out.deleteSync(recursive: true);
      if (work.existsSync()) work.deleteSync(recursive: true);
    });
    final runner = ExportRunner(
      run: _ffmpeg,
      workDir: work,
      fetchMaterial: (id) async =>
          (File('${work.path}/m$id.mp4')..writeAsStringSync('m')).path,
    );

    // Agent 提交的方案列表允许重名（名字是它自己起的），撞了不能吃掉一条
    final combos =
        ExportPlanner.enumerate(
              units: _units(),
              replacements: [
                UnitReplacement.whole(const [11, 12]),
              ],
            )
            .map(
              (c) => ExportCombination(
                index: c.index,
                segments: c.segments,
                name: '居家写实线',
              ),
            )
            .toList();

    final results = await runner.exportCombinations(
      combos: combos,
      sourcePath: '/v/a.mp4',
      units: _units(),
      replacements: [
        UnitReplacement.whole(const [11, 12]),
      ],
      outputDir: out,
    );

    expect(results.map((r) => p.basename(r.path!)), [
      '居家写实线.mp4',
      '居家写实线(2).mp4',
    ]);
    expect(out.listSync().whereType<File>().length, 2);
  });
}
