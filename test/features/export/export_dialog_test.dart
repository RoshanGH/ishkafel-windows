import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/export_record.dart';
import 'package:ishkafel/core/export/export_runner.dart';
import 'package:ishkafel/core/subtitle/subtitle_style.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';
import 'package:ishkafel/core/replacement/picked_material.dart';
import 'package:ishkafel/features/export/export_dialog.dart';

/// 假 ffmpeg：不起进程，按需失败
class _Ffmpeg {
  final String? failOn;
  _Ffmpeg({this.failOn});

  Future<ProcessResult> call(String bin, List<String> args) async {
    if (failOn != null && args.join(' ').contains(failOn!)) {
      return ProcessResult(1, 1, '', '素材读不出来');
    }
    File(args.last).writeAsStringSync('x');
    return ProcessResult(1, 0, '', '');
  }
}

List<SemanticUnit> _units() => const [
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

/// 这一轮里对话框往外报了什么
final _recorded = <ExportRecord>[];
final _revealed = <String>[];

Future<void> _open(
  WidgetTester tester, {
  required List<UnitReplacement> replacements,
  ExportRunnerFactory? factory,
  bool withFactory = true,
  String? pickedDir,
  Future<void> Function(String)? reveal,
  List<ExportRecord> exports = const [],
  List<PickedMaterial> pickedMaterials = const [],
  List<SemanticUnit>? units,
  double sourceFps = 0,
}) async {
  _recorded.clear();
  _revealed.clear();
  final work = Directory.systemTemp.createTempSync('ishkafel_ed_work_');
  final out = Directory.systemTemp.createTempSync('ishkafel_ed_out_');
  addTearDown(() {
    // 导出跑完会自己把工作目录清掉
    if (work.existsSync()) work.deleteSync(recursive: true);
    out.deleteSync(recursive: true);
  });

  final resolved = factory ??
      (String taskId, SubtitleStyle _) => ExportRunner(
            run: _Ffmpeg().call,
            workDir: work,
            fetchMaterial: (id) async {
              final f = File('${work.path}/m$id.mp4')..writeAsStringSync('m');
              return f.path;
            },
          );

  await tester.pumpWidget(ProviderScope(
    overrides: [
      exportRunnerFactoryProvider
          .overrideWithValue(withFactory ? resolved : null),
    ],
    child: MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              key: const Key('open'),
              onPressed: () => showExportDialog(
                context,
                taskId: 't1',
                taskName: '滴露',
                sourcePath: '/v/a.mp4',
                units: units ?? _units(),
                replacements: replacements,
                outputDir: out,
                pickDirectory: () async => pickedDir,
                revealDirectory: reveal ?? (path) async => _revealed.add(path),
                onExported: (r) async => _recorded.add(r),
                now: () => DateTime.utc(2026, 8, 9, 10, 30),
                exports: exports,
                pickedMaterials: pickedMaterials,
                sourceFps: sourceFps,
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.byKey(const Key('open')));
  await tester.pumpAndSettle();
}

void main() {
  _elapsedShown();
  _subtitleGapTests();
  _brandConflictTests();
  _burnedTextTests();
  _dedupBreakdownTests();
  _breakdownTests();
  testWidgets('先说清要导出几条、每条多长、导到哪儿', (tester) async {
    await _open(tester, replacements: [
      UnitReplacement.whole(const [11, 12]),
      UnitReplacement.keepOriginal(),
    ]);

    expect(find.textContaining('共 2 条成片'), findsOneWidget);
    expect(find.textContaining('5.0s'), findsOneWidget);
    expect(find.textContaining('导出到：'), findsOneWidget);
  });

  testWidgets('跟原片一样的那几条要点出来——用户按条数付出的是等待时间',
      (tester) async {
    await _open(tester, replacements: [
      UnitReplacement.keepOriginal(),
      UnitReplacement.keepOriginal(),
    ]);

    expect(find.textContaining('1 条与原片画面相同'), findsOneWidget);
  });

  testWidgets('导出跑完给出结果', (tester) async {
    await _open(tester, replacements: [
      UnitReplacement.whole(const [11, 12]),
      UnitReplacement.keepOriginal(),
    ]);

    await tester.tap(find.byKey(const Key('export-start')));
    await tester.pumpAndSettle();

    expect(find.text('2 条全部导出完成'), findsOneWidget);
    expect(find.byKey(const Key('export-start')), findsNothing,
        reason: '跑完了就没有「再开始一次」这回事，避免重复导出');
  });

  testWidgets('导出帧率默认跟着原片走——时间线就是按它数帧的', (tester) async {
    await _open(
      tester,
      sourceFps: 60,
      replacements: [
        UnitReplacement.whole(const [11, 12]),
        UnitReplacement.keepOriginal(),
      ],
    );

    expect(find.text('60fps'), findsOneWidget);
    // 和原片一致时不该有那句提示——没什么要提醒的
    expect(find.byKey(const Key('export-fps-note')), findsNothing);
  });

  testWidgets('手动把帧率选到比原片低：不拦，但要当场说清楚在丢帧',
      (tester) async {
    await _open(
      tester,
      sourceFps: 60,
      replacements: [
        UnitReplacement.whole(const [11, 12]),
        UnitReplacement.keepOriginal(),
      ],
    );

    await tester.tap(find.byKey(const Key('export-fps')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('30fps').last);
    await tester.pumpAndSettle();

    final note =
        tester.widget<Text>(find.byKey(const Key('export-fps-note'))).data!;
    expect(note, contains('60fps'));
    expect(note, contains('每2.0 帧取一'));
  });

  testWidgets('空白任务没有原片：不提帧率对不上这回事', (tester) async {
    await _open(tester, replacements: [
      UnitReplacement.whole(const [11, 12]),
      UnitReplacement.keepOriginal(),
    ]);
    expect(find.byKey(const Key('export-fps-note')), findsNothing);
  });

  testWidgets('组合少到一个档位都放不下时，不摆空的「挑 ▢ 条」', (tester) async {
    // 2 条组合：3/5/10/20 一个都放不下，原来会摆出一行空档位
    await _open(tester, replacements: [
      UnitReplacement.whole(const [11, 12]),
      UnitReplacement.keepOriginal(),
    ]);

    expect(find.byKey(const Key('export-mode-all-only')), findsOneWidget);
    expect(find.byKey(const Key('export-mode-pick')), findsNothing);
  });

  testWidgets('挑差异最大的：导出之前就摆出这几条各用什么', (tester) async {
    await _open(
      tester,
      replacements: [
        UnitReplacement.whole(const [11, 12, 13]),
        UnitReplacement.whole(const [21, 22]),
      ],
      pickedMaterials: const [
        PickedMaterial(id: 11, name: 'A线_001'),
        PickedMaterial(id: 12, name: 'A线_002'),
        PickedMaterial(id: 13, name: 'A线_003'),
        PickedMaterial(id: 21, name: 'B线_001'),
        PickedMaterial(id: 22, name: 'B线_002'),
      ],
    );

    // 没挑之前不摆——全部导出时逐条列没有意义
    expect(find.byKey(const Key('export-pick-breakdown')), findsNothing);

    await tester.tap(find.byKey(const Key('export-mode-pick')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('export-pick-3')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('export-pick-breakdown')), findsOneWidget,
        reason: '挑得对不对只有人能判断，得在点导出之前看得到');
    expect(find.textContaining('第 1 条 · '), findsOneWidget);
  });

  testWidgets('导完把文件名摆出来——同名不覆盖会改名，人要照着这个去目录里找',
      (tester) async {
    await _open(tester, replacements: [
      UnitReplacement.whole(const [11, 12]),
      UnitReplacement.keepOriginal(),
    ]);

    await tester.tap(find.byKey(const Key('export-start')));
    await tester.pumpAndSettle();

    expect(
        tester
            .widget<Text>(find.byKey(const Key('export-result-files')))
            .data,
        '变体1.mp4、变体2.mp4');
  });

  testWidgets('失败的逐条点名带原因，不让用户自己找', (tester) async {
    final work = Directory.systemTemp.createTempSync('ishkafel_ed_fail_');
    addTearDown(() {
      if (work.existsSync()) work.deleteSync(recursive: true);
    });

    await _open(
      tester,
      replacements: [
        UnitReplacement.whole(const [11, 12]),
        UnitReplacement.keepOriginal(),
      ],
      factory: (taskId, _) => ExportRunner(
        run: _Ffmpeg(failOn: 'm12.mp4').call,
        workDir: work,
        fetchMaterial: (id) async {
          final f = File('${work.path}/m$id.mp4')..writeAsStringSync('m');
          return f.path;
        },
      ),
    );

    await tester.tap(find.byKey(const Key('export-start')));
    await tester.pumpAndSettle();

    expect(find.textContaining('成功 1 条，失败 1 条'), findsOneWidget);
    expect(find.textContaining('第 2 条：'), findsOneWidget);
    expect(find.textContaining('素材读不出来'), findsOneWidget);
  });

  testWidgets('没有 ffmpeg 时说清楚，而不是点了没反应', (tester) async {
    await _open(
      tester,
      replacements: [UnitReplacement.keepOriginal()],
      withFactory: false,
    );

    await tester.tap(find.byKey(const Key('export-start')));
    await tester.pumpAndSettle();

    expect(find.textContaining('未检测到 ffmpeg'), findsOneWidget);
  });

  group('导完要知道片子在哪', () {
    /// 用户原话：「导出以后能让我直接知道在哪个地方，能让我看到它。现在导出
    /// 以后我点关闭，我就不知道在哪了。」
    testWidgets('开始之前能换导出位置', (tester) async {
      final elsewhere =
          Directory.systemTemp.createTempSync('ishkafel_ed_pick_');
      addTearDown(() => elsewhere.deleteSync(recursive: true));

      await _open(tester,
          replacements: [UnitReplacement.whole(const [11])],
          pickedDir: elsewhere.path);

      await tester.tap(find.byKey(const Key('export-pick-dir')));
      await tester.pumpAndSettle();

      expect(find.textContaining(shortenPath(elsewhere.path)), findsOneWidget);
    });

    testWidgets('选择框里取消就保持原样，不要把已填好的位置清掉', (tester) async {
      await _open(tester,
          replacements: [UnitReplacement.whole(const [11])],
          pickedDir: null);
      final before = tester
          .widget<Text>(find.byKey(const Key('export-output-dir')))
          .data;

      await tester.tap(find.byKey(const Key('export-pick-dir')));
      await tester.pumpAndSettle();

      expect(
          tester
              .widget<Text>(find.byKey(const Key('export-output-dir')))
              .data,
          before);
    });

    testWidgets('跑完给「在访达中显示」，点了就打开那个目录', (tester) async {
      await _open(tester, replacements: [UnitReplacement.whole(const [11])]);
      expect(find.byKey(const Key('export-reveal')), findsNothing,
          reason: '还没导就摆一个「打开目录」是空指望');

      await tester.tap(find.byKey(const Key('export-start')));
      await tester.pumpAndSettle();
      expect(
        find.text(Platform.isWindows ? '在文件资源管理器中显示' : '在访达中显示'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('export-reveal')));
      await tester.pumpAndSettle();

      expect(_revealed, hasLength(1));
    });

    testWidgets('打不开时说清楚，而不是点了没反应', (tester) async {
      await _open(tester,
          replacements: [UnitReplacement.whole(const [11])],
          reveal: (_) async => throw StateError('没这个目录'));

      await tester.tap(find.byKey(const Key('export-start')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('export-reveal')));
      await tester.pumpAndSettle();

      expect(find.textContaining('打不开这个目录'), findsOneWidget);
    });
  });

  group('每一次导出都记进项目', () {
    /// 项目没有终态——原片放在那儿，明天换一批素材还能再导。有始有终的是
    /// 每一次导出：哪天、导了几条、成了几条、在哪个目录。
    testWidgets('跑完就报一条记录', (tester) async {
      await _open(tester, replacements: [
        UnitReplacement.whole(const [11, 12]),
        UnitReplacement.keepOriginal(),
      ]);

      await tester.tap(find.byKey(const Key('export-start')));
      await tester.pumpAndSettle();

      expect(_recorded, hasLength(1));
      expect(_recorded.single.at, DateTime.utc(2026, 8, 9, 10, 30));
      expect(_recorded.single.total, 2);
      expect(_recorded.single.succeeded, 2);
      expect(_recorded.single.outputDir, isNotEmpty);
    });

    testWidgets('有失败的照样记，成功数如实报', (tester) async {
      final work = Directory.systemTemp.createTempSync('ishkafel_ed_rec_');
      addTearDown(() {
        if (work.existsSync()) work.deleteSync(recursive: true);
      });
      await _open(
        tester,
        replacements: [
          UnitReplacement.whole(const [11, 12]),
          UnitReplacement.keepOriginal(),
        ],
        factory: (taskId, _) => ExportRunner(
          run: (binary, args) async {
            // 第二条的素材取不到
            await File(args.last).writeAsString('out');
            return ProcessResult(1, 0, '', '');
          },
          workDir: work,
          fetchMaterial: (id) async {
            if (id == 12) throw StateError('素材读不出来');
            final f = File('${work.path}/m$id.mp4')..writeAsStringSync('m');
            return f.path;
          },
        ),
      );

      await tester.tap(find.byKey(const Key('export-start')));
      await tester.pumpAndSettle();

      expect(_recorded, hasLength(1));
      expect(_recorded.single.succeeded, lessThan(_recorded.single.total));
      expect(_recorded.single.allSucceeded, isFalse);
    });
  });

  group('确认页上摆出这个项目的导出历史', () {
    /// 用户原话：「每一个项目点导出的时候，它不是最后还要确认一下吗？
    /// 你可以在那个页面里展示出这个项目之前导出的这个历史。」——正要导之前
    /// 先看一眼上次导到哪儿、导了几条，比另开一个界面顺手。
    ExportRecord rec(int day, int succeeded, int total, String dir) =>
        ExportRecord(
            at: DateTime.utc(2026, 8, day, 20, 15),
            total: total,
            succeeded: succeeded,
            outputDir: dir);

    testWidgets('没导过就不摆这一段，不留一个空标题', (tester) async {
      await _open(tester, replacements: [UnitReplacement.whole(const [11])]);

      expect(find.byKey(const Key('export-history-title')), findsNothing);
    });

    testWidgets('导过就列出来：时间、几条、导到哪儿', (tester) async {
      await _open(
        tester,
        replacements: [UnitReplacement.whole(const [11])],
        exports: [rec(8, 6, 6, '/Users/me/Movies/滴露')],
      );

      expect(find.textContaining('导出过 1 次'), findsOneWidget);
      expect(find.textContaining('8月8日'), findsOneWidget);
      expect(find.textContaining('6 条'), findsOneWidget);
      expect(find.textContaining('Movies/滴露'), findsOneWidget);
    });

    testWidgets('有失败的那次要点出来', (tester) async {
      await _open(
        tester,
        replacements: [UnitReplacement.whole(const [11])],
        exports: [rec(8, 4, 6, '/out')],
      );

      expect(find.textContaining('2 条失败'), findsOneWidget);
    });

    testWidgets('最近的排在最前——用户找的多半是刚导的那批', (tester) async {
      await _open(
        tester,
        replacements: [UnitReplacement.whole(const [11])],
        exports: [rec(7, 1, 1, '/older'), rec(9, 2, 2, '/newer')],
      );

      final rows = tester
          .widgetList<Text>(find.textContaining('月'))
          .map((t) => t.data!)
          .where((d) => d.contains('日'))
          .toList();
      expect(rows.first, contains('9日'));
    });

    testWidgets('每一条都能直接打开——历史的用处就是回去找那批片子', (tester) async {
      final at = DateTime.utc(2026, 8, 8, 20, 15);
      await _open(
        tester,
        replacements: [UnitReplacement.whole(const [11])],
        exports: [rec(8, 6, 6, '/Users/me/Movies/滴露')],
      );

      // 选项面板加进来之后确认页变长，历史条目会在视口外
      await tester.ensureVisible(
          find.byKey(Key('export-history-open-${at.toIso8601String()}')));
      await tester.tap(find
          .byKey(Key('export-history-open-${at.toIso8601String()}')));
      await tester.pumpAndSettle();

      expect(_revealed, ['/Users/me/Movies/滴露']);
    });

    testWidgets('导过很多次时只列最近五次，其余写个条数', (tester) async {
      await _open(
        tester,
        replacements: [UnitReplacement.whole(const [11])],
        exports: [for (var d = 1; d <= 8; d++) rec(d, 1, 1, '/out$d')],
      );

      expect(find.textContaining('导出过 8 次'), findsOneWidget);
      expect(find.textContaining('另有 3 次更早的导出'), findsOneWidget,
          reason: '全列出来会把确认页撑长，反而看不清这一次要导什么');
    });

    testWidgets('刚导完的这一次立刻出现在历史里', (tester) async {
      await _open(tester, replacements: [UnitReplacement.whole(const [11])]);
      expect(find.byKey(const Key('export-history-title')), findsNothing);

      await tester.tap(find.byKey(const Key('export-start')));
      await tester.pumpAndSettle();

      expect(find.textContaining('导出过 1 次'), findsOneWidget);
      expect(find.textContaining('8月9日'), findsOneWidget);
    });
  });

  group('路径写法', () {
    test('家目录缩成 ~——导出路径很长，全写出来会把那一行挤没', () {
      final home = Platform.environment['HOME'];
      if (home == null || home.isEmpty) return;

      expect(shortenPath('$home/Movies/滴露'), '~/Movies/滴露');
      expect(shortenPath('/Volumes/外置盘/片子'), '/Volumes/外置盘/片子',
          reason: '不在家目录下的原样显示');
    });
  });
}

/// 24 条不是一个让人猜的数：算式和「谁挑了几条」写在总数底下。
void _breakdownTests() {
  testWidgets('多因子时把乘法算式写出来', (tester) async {
    await _open(tester, replacements: [
      UnitReplacement.whole(const [11, 12]),
      UnitReplacement.whole(const [21, 22, 23]),
    ]);
    final text = tester
        .widget<Text>(find.byKey(const Key('export-combo-breakdown')))
        .data!;
    expect(text, contains('2 × 3 = 6'));
    expect(text, contains('U1 挑了 2 条'));
    expect(text, contains('U2 挑了 3 条'));
  });

  testWidgets('单因子不写算式——2 = 2 是废话', (tester) async {
    await _open(tester, replacements: [
      UnitReplacement.whole(const [11, 12]),
    ]);
    expect(find.byKey(const Key('export-combo-breakdown')), findsNothing);
  });
}

/// 去重让实际条数少于乘积时，算式必须如实写两步——等号两边对不上是欺骗。
void _dedupBreakdownTests() {
  testWidgets('位置之间挑了相同素材时，写清乘积、去掉几条、剩几条', (tester) async {
    // U1 与 U2 都挑了素材 11：2×2=4，去掉 11+11 那 1 条，剩 3
    await _open(tester, replacements: [
      UnitReplacement.whole(const [11, 12]),
      UnitReplacement.whole(const [11, 13]),
    ]);
    final text = tester
        .widget<Text>(find.byKey(const Key('export-combo-breakdown')))
        .data!;
    expect(text, contains('2 × 2 = 4'));
    expect(text, contains('去掉同一条素材出现两次的 1 条'));
    expect(text, contains('剩 3 条'));
  });
}

/// 素材画面上本来就烧着字：换上去之后我们还要再烧一行台词字幕，两层字
/// 叠在一起，片子直接废。这一条要在**按下导出之前**说清是哪几条，
/// 不能等成片出来了让人自己看。
void _burnedTextTests() {
  testWidgets('确认页点名画面上烧着字的那几条', (tester) async {
    await _open(
      tester,
      replacements: [
        UnitReplacement.whole(const [11]),
        UnitReplacement.whole(const [12]),
      ],
      pickedMaterials: const [
        PickedMaterial(id: 11, name: 'a', burnedText: ['冰冰凉凉的好舒服呀']),
        PickedMaterial(id: 12, name: 'b', burnedText: []),
      ],
    );
    final warn = find.byKey(const Key('export-burned-text'));
    expect(warn, findsOneWidget);
    final text = tester.widget<Text>(warn).data!;
    expect(text, contains('冰冰凉凉的好舒服呀'));
    expect(text, contains('U1'));
    expect(text, isNot(contains('U2')));
  });

  testWidgets('都干净就不打扰', (tester) async {
    await _open(
      tester,
      replacements: [UnitReplacement.whole(const [11])],
      pickedMaterials: const [PickedMaterial(id: 11, name: 'a', burnedText: [])],
    );
    expect(find.byKey(const Key('export-burned-text')), findsNothing);
  });
}

/// 产品露出镜头**不能跨品牌换**：台词说「滴露新款消毒液」而画面是若也
/// 洗发水直播间。真机上交付过这样一条成片——导出前必须点名。
void _brandConflictTests() {
  testWidgets('挑的素材里有两个牌子：确认页点名', (tester) async {
    await _open(
      tester,
      replacements: [
        UnitReplacement.whole(const [11]),
        UnitReplacement.whole(const [12]),
      ],
      pickedMaterials: const [
        PickedMaterial(id: 11, name: 'a', burnedText: [], productBrand: '滴露'),
        PickedMaterial(
            id: 12, name: 'b', burnedText: [], productBrand: '若也 Rove'),
      ],
    );
    final warn = find.byKey(const Key('export-brand-conflict'));
    expect(warn, findsOneWidget);
    final text = tester.widget<Text>(warn).data!;
    expect(text, contains('滴露'));
    expect(text, contains('若也 Rove'));
  });

  /// 「候选之间打架」漏得掉的那一半：候选**全**是别家的，彼此毫无冲突，
  /// 可整条片子都跑到别家去了。这只有拿原片当参照才看得出来。
  testWidgets('候选全是别家的：候选之间不打架，也要报', (tester) async {
    await _open(
      tester,
      replacements: [UnitReplacement.whole(const [11])],
      units: const [
        SemanticUnit(
          index: 0,
          startMs: 0,
          endMs: 2000,
          transcript: 'U1',
          shots: [Shot(startMs: 0, endMs: 2000, productBrand: '滴露')],
        ),
      ],
      pickedMaterials: const [
        PickedMaterial(
            id: 11, name: 'a', burnedText: [], productBrand: '若也 Rove'),
      ],
    );
    final warn = find.byKey(const Key('export-brand-conflict'));
    expect(warn, findsOneWidget);
    final text = tester.widget<Text>(warn).data!;
    expect(text, contains('滴露'), reason: '要说清原片是什么牌子');
    expect(text, contains('若也 Rove'));
  });

  testWidgets('都是一个牌子就不打扰', (tester) async {
    await _open(
      tester,
      replacements: [UnitReplacement.whole(const [11])],
      pickedMaterials: const [
        PickedMaterial(id: 11, name: 'a', burnedText: [], productBrand: '滴露'),
      ],
    );
    expect(find.byKey(const Key('export-brand-conflict')), findsNothing);
  });
}

/// 整体替换的段落不烧台词字幕——成片里那几段没字。
/// 这件事此前**界面上也看不见**：人点导出的时候不知道自己要拿到一条
/// 字幕断断续续的片子。
void _subtitleGapTests() {
  testWidgets('用了整体替换：确认页要说清哪几段没有字幕', (tester) async {
    await _open(tester, replacements: [
      UnitReplacement.whole(const [11]),
      UnitReplacement.perShot(const {0: [12]}),
    ]);
    final gap = find.byKey(const Key('export-subtitle-gap'));
    expect(gap, findsOneWidget);
    final text = tester.widget<Text>(gap).data!;
    expect(text, contains('U1'));
    expect(text, isNot(contains('U2')));
  });

  testWidgets('全是镜头替换就不提——那几段字幕都会重渲上去', (tester) async {
    await _open(tester, replacements: [
      UnitReplacement.perShot(const {0: [11]}),
      UnitReplacement.keepOriginal(),
    ]);
    expect(find.byKey(const Key('export-subtitle-gap')), findsNothing);
  });
}

/// **合成一条要二十几秒，进度不能只在「条」这个粒度跳。**
///
/// 2026-09-10 真机走查：导 2 条 75 秒的片子用了 45 秒，而屏幕上
/// 「0/2 · 第 1 条」二十几秒纹丝不动——人分不清是在跑还是卡死了。
/// ffmpeg 的逐帧进度要改子进程执行器才拿得到，而「这条跑了多久 /
/// 上一条跑了多久」零成本就能说。
void _elapsedShown() {
  testWidgets('导出中显示这一条已经跑了多久', (tester) async {
    final src = File('lib/features/export/export_dialog.dart').readAsStringSync();

    // 这条用例守的是「界面把用时说出来」这件事本身：真跑一次导出要
    // 拉起 ffmpeg，不适合放进单测
    expect(src, contains('已用 \$secs 秒'),
        reason: '进度只报「第几条」，人看不出它在动');
    expect(src, contains('上一条用了'),
        reason: '第二条起该给得出预期——上一条花了多久');
    expect(src, contains('Timer.periodic'),
        reason: '不定时重绘的话，「已用 N 秒」会一直停在 0 秒');
  });

  group('停止导出', () {
    /// 产品负责人 2026-09-16：「导出一次好几十条，甚至 100 条，让导出可以
    /// 取消，已经导出的就留着当导出成功的物料。」
    ///
    /// 一批一百条要跑很久。没有出口的话人只能关掉整个 app，那一批已经导好
    /// 的片子也跟着说不清楚了。
    testWidgets('跑起来之后按钮就是「停止导出」，按下去说清在等什么', (tester) async {
      final work = Directory.systemTemp.createTempSync('ishkafel_stop_');
      addTearDown(() {
        if (work.existsSync()) work.deleteSync(recursive: true);
      });
      // 卡在第一次 ffmpeg 上，好让「导出中」这个状态停住给我们看
      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });

      await _open(
        tester,
        replacements: [
          UnitReplacement.perShot(const {
            0: [11, 12, 13]
          }),
          UnitReplacement.keepOriginal(),
        ],
        factory: (String taskId, SubtitleStyle _) => ExportRunner(
          run: (bin, args) async {
            await gate.future;
            File(args.last).writeAsStringSync('x');
            return ProcessResult(1, 0, '', '');
          },
          workDir: work,
          fetchMaterial: (id) async {
            final f = File('${work.path}/m$id.mp4')..writeAsStringSync('m');
            return f.path;
          },
        ),
      );

      await tester.tap(find.byKey(const Key('export-start')));
      await tester.pump();

      expect(find.byKey(const Key('export-stop')), findsOneWidget,
          reason: '跑起来之后这个位置就该是出口');
      expect(find.byKey(const Key('export-start')), findsNothing);

      await tester.tap(find.byKey(const Key('export-stop')));
      await tester.pump();

      // **等的是什么要说出来**：按下之后当前这个 ffmpeg 还要跑完，
      // 不说的话人以为按了没反应，会去点第二次、第三次
      expect(find.text('正在停下——等当前这一步跑完，已经导完的都留着'),
          findsOneWidget);
      expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('export-stop')))
              .onPressed,
          isNull,
          reason: '按过一次就不该再按——停就是停，没有「更停一点」');

      gate.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('停下来之后如实说：已停止、导完几条，并且记进历史', (tester) async {
      final work = Directory.systemTemp.createTempSync('ishkafel_stop2_');
      addTearDown(() {
        if (work.existsSync()) work.deleteSync(recursive: true);
      });
      // 闸门：第一次拉 ffmpeg 就停住，好让「导出中」这个状态留给我们操作
      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });

      await _open(
        tester,
        replacements: [
          UnitReplacement.perShot(const {
            0: [11, 12, 13]
          }),
          UnitReplacement.keepOriginal(),
        ],
        factory: (String taskId, SubtitleStyle _) => ExportRunner(
          run: (bin, args) async {
            await gate.future;
            File(args.last).writeAsStringSync('x');
            return ProcessResult(1, 0, '', '');
          },
          workDir: work,
          fetchMaterial: (id) async {
            final f = File('${work.path}/m$id.mp4')..writeAsStringSync('m');
            return f.path;
          },
        ),
      );

      await tester.tap(find.byKey(const Key('export-start')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('export-stop')));
      await tester.pump();
      gate.complete();
      await tester.pumpAndSettle();

      // 一条都没导完时不能说「都在输出目录里」——那儿空空如也
      // （2026-09-16 真机：停在人声分离那一步，输出目录是空的）
      expect(find.text('已停止——3 条一条都还没导完'), findsOneWidget);
      // 停止不是失败：别把它算进失败数让人去查原因
      expect(find.textContaining('条失败'), findsNothing);

      expect(_recorded, hasLength(1),
          reason: '停下来的那一批照样记进历史——不记的话，已经导完的那几条'
              '人回头找不到是哪一次导的');
      expect(_recorded.single.cancelled, isTrue);
    });
  });
}

