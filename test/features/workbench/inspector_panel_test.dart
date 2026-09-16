import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/editing/segmentation_editor_controller.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/features/workbench/inspector_panel.dart';

const _fps = 30.0;

List<SemanticUnit> _fixtureUnits() => [
      SemanticUnit(
        index: 0,
        startMs: 0,
        endMs: 2000,
        transcript: '第一句台词',
        tags: const ['痛点引入'],
        shots: const [
          Shot(startMs: 0, endMs: 1000, tags: ['特写']),
          Shot(startMs: 1000, endMs: 2000, tags: ['全景']),
        ],
      ),
      SemanticUnit(
        index: 1,
        startMs: 2000,
        endMs: 4000,
        transcript: '第二句台词',
        tags: const ['产品引入'],
        shots: const [
          Shot(startMs: 2000, endMs: 4000, tags: ['产品特写']),
        ],
      ),
    ];

SegmentationEditorController _fixtureController({EditorSelection? selection}) {
  final controller = SegmentationEditorController(
    initialUnits: _fixtureUnits(),
    durationMs: 4000,
    fps: _fps,
    sentences: const [],
  );
  if (selection != null) controller.select(selection);
  return controller;
}

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(home: Material(child: child)));
}

void main() {
  _pinnedActions();
  _baseOriginLine();
  _blankOverview();
  group('formatTimecode', () {
    test('formatTimecode(70033, 30) == 01:10.01', () {
      expect(formatTimecode(70033, 30), '01:10.01');
    });

    test('formatTimecode(0, 30) == 00:00.00', () {
      expect(formatTimecode(0, 30), '00:00.00');
    });
  });

  group('InspectorPanel', () {
    // 2026-09-09 设计走查：这里原来只有一句「未选中任何单元或镜头」，
    // 480px 宽的一整栏空着，而人真正想知道的几个数挤在窗口最下面那行
    // 10px 的灰字里。空状态不是「没东西可说」，是「还没聚焦到某一处」。
    testWidgets('无选中时这一栏说整片：多长、几个单元、几个镜头', (tester) async {
      final controller = _fixtureController();
      await _pump(tester, InspectorPanel(controller: controller, fps: _fps));

      expect(find.text('整片'), findsOneWidget);
      expect(find.text('时长'), findsOneWidget);
      expect(find.text('台词语义单元'), findsOneWidget);
      expect(find.text('视觉镜头'), findsOneWidget);
    });

    testWidgets('无选中时也说「翻新到哪一步了」——换了几个镜头、改了几处字幕', (tester) async {
      final controller = _fixtureController();
      await _pump(
          tester,
          InspectorPanel(
            controller: controller,
            fps: _fps,
            shotReplaced: (u, s) => u == 0 && s == 0,
            subtitleEdited: (u, s) => u == 0 && s == 0,
          ));

      expect(find.text('换过画面的镜头'), findsOneWidget);
      expect(find.text('手改过的字幕'), findsOneWidget);
      expect(find.text('1'), findsWidgets, reason: '改过一处字幕就该显示 1');
    });

    testWidgets('还没有单元时不硬凑数字，直说没有', (tester) async {
      final controller = SegmentationEditorController(
        initialUnits: const [],
        durationMs: 0,
        fps: _fps,
        sentences: const [],
      );
      await _pump(tester, InspectorPanel(controller: controller, fps: _fps));

      expect(find.text('还没有台词语义单元'), findsOneWidget);
    });

    testWidgets('选中单元时显示标题、时间码与台词', (tester) async {
      final controller =
          _fixtureController(selection: const EditorSelection.unit(0));
      await _pump(tester, InspectorPanel(controller: controller, fps: _fps));

      expect(find.textContaining('U1'), findsWidgets);
      expect(find.text(formatTimecode(0, _fps)), findsOneWidget);
      expect(find.text(formatTimecode(2000, _fps)), findsOneWidget);

      final field = tester.widget<TextField>(
          find.byKey(const Key('inspector-transcript-field')));
      expect(field.controller?.text, '第一句台词');
    });

    testWidgets('点击结束边界「＋」步进后 controller.units 对应边界 +1 帧', (tester) async {
      final controller =
          _fixtureController(selection: const EditorSelection.unit(0));
      await _pump(tester, InspectorPanel(controller: controller, fps: _fps));

      final beforeEnd = controller.units[0].endMs;
      await tester.tap(find.byKey(const Key('inspector-end-plus')));
      await tester.pump();

      final frameMs = (1000 / _fps).round();
      expect(controller.units[0].endMs, beforeEnd + frameMs);
    });

    testWidgets('台词编辑通过 TextField onChanged 回写 controller', (tester) async {
      final controller =
          _fixtureController(selection: const EditorSelection.unit(1));
      await _pump(tester, InspectorPanel(controller: controller, fps: _fps));

      await tester.enterText(
          find.byKey(const Key('inspector-transcript-field')), '改后的台词');
      await tester.pump();

      expect(controller.units[1].transcript, '改后的台词');
    });

    testWidgets('选中镜头时显示所属单元与镜头信息', (tester) async {
      final controller = _fixtureController(
          selection: const EditorSelection.shot(0, 1));
      await _pump(tester, InspectorPanel(controller: controller, fps: _fps));

      expect(find.textContaining('U1'), findsWidgets);
      expect(find.textContaining('S2'), findsWidgets);
      expect(find.textContaining('全景'), findsOneWidget);
    });

    testWidgets('「✂ 在游标处拆分」触发 onSplitAtPlayhead 回调', (tester) async {
      final controller =
          _fixtureController(selection: const EditorSelection.unit(0));
      var splitCalled = false;
      await _pump(
        tester,
        InspectorPanel(
          controller: controller,
          fps: _fps,
          onSplitAtPlayhead: () => splitCalled = true,
        ),
      );

      await tester.tap(find.byKey(const Key('inspector-split-btn')));
      await tester.pump();

      expect(splitCalled, isTrue);
    });

    testWidgets('「⇧ 并入上一单元」调用 controller.mergeSelectedWithPrevious', (tester) async {
      final controller =
          _fixtureController(selection: const EditorSelection.unit(1));
      await _pump(tester, InspectorPanel(controller: controller, fps: _fps));

      await tester.tap(find.byKey(const Key('inspector-merge-btn')));
      await tester.pump();

      expect(controller.units.length, 1);
      expect(controller.units[0].transcript, contains('第一句台词'));
    });

    group('readOnly（评审 Important 1：回看模式不可编辑）', () {
      testWidgets('单元步进按钮均禁用', (tester) async {
        final controller =
            _fixtureController(selection: const EditorSelection.unit(1));
        await _pump(
          tester,
          InspectorPanel(controller: controller, fps: _fps, readOnly: true),
        );

        final startMinus = tester.widget<GestureDetector>(
            find.byKey(const Key('inspector-start-minus')));
        final startPlus = tester.widget<GestureDetector>(
            find.byKey(const Key('inspector-start-plus')));
        expect(startMinus.onTapDown, isNull);
        expect(startPlus.onTapDown, isNull);
      });

      testWidgets('台词 TextField 禁用', (tester) async {
        final controller =
            _fixtureController(selection: const EditorSelection.unit(0));
        await _pump(
          tester,
          InspectorPanel(controller: controller, fps: _fps, readOnly: true),
        );

        final field = tester.widget<TextField>(
            find.byKey(const Key('inspector-transcript-field')));
        expect(field.enabled, isFalse);
      });

      testWidgets('台词标题标注为「只读」而不是「可编辑」（真机验收发现）', (tester) async {
        final controller =
            _fixtureController(selection: const EditorSelection.unit(0));
        await _pump(
          tester,
          InspectorPanel(controller: controller, fps: _fps, readOnly: true),
        );

        expect(find.text('单元台词（可编辑）'), findsNothing,
            reason: '回看模式下台词实际不可编辑，标题不应继续声称可编辑');
        expect(find.text('单元台词（只读）'), findsOneWidget);
      });

      testWidgets('拆分/并入按钮禁用', (tester) async {
        final controller =
            _fixtureController(selection: const EditorSelection.unit(1));
        await _pump(
          tester,
          InspectorPanel(controller: controller, fps: _fps, readOnly: true),
        );

        final splitBtn = tester
            .widget<InkWell>(find.byKey(const Key('inspector-split-btn')));
        final mergeBtn = tester
            .widget<InkWell>(find.byKey(const Key('inspector-merge-btn')));
        expect(splitBtn.onTap, isNull);
        expect(mergeBtn.onTap, isNull);
      });

      testWidgets('镜头步进按钮同理禁用', (tester) async {
        final controller = _fixtureController(
            selection: const EditorSelection.shot(0, 1));
        await _pump(
          tester,
          InspectorPanel(controller: controller, fps: _fps, readOnly: true),
        );

        final endPlus = tester.widget<GestureDetector>(
            find.byKey(const Key('inspector-end-plus')));
        expect(endPlus.onTapDown, isNull);
      });
    });

    group('台词编辑会话（评审 Important 3：逐击键入不应逐条入 undo 栈）', () {
      testWidgets('聚焦期间连续多次输入合并为一条 undo 记录，失焦后一次 undo 回到编辑前原文',
          (tester) async {
        final controller =
            _fixtureController(selection: const EditorSelection.unit(0));
        await _pump(tester, InspectorPanel(controller: controller, fps: _fps));

        await tester
            .tap(find.byKey(const Key('inspector-transcript-field')));
        await tester.pump();
        await tester.enterText(
            find.byKey(const Key('inspector-transcript-field')), '第一');
        await tester.pump();
        await tester.enterText(
            find.byKey(const Key('inspector-transcript-field')), '第一句');
        await tester.pump();
        await tester.enterText(
            find.byKey(const Key('inspector-transcript-field')), '第一句话');
        await tester.pump();

        expect(controller.canUndo, isFalse, reason: '聚焦会话进行中不应提前入栈');

        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();

        expect(controller.canUndo, isTrue);
        controller.undo();
        expect(controller.units[0].transcript, '第一句台词',
            reason: '一次 undo 应直接回到聚焦编辑前的原文，而非逐字符回退');
      });

      testWidgets('失焦后再次聚焦输入产生独立的一条 undo 记录', (tester) async {
        final controller =
            _fixtureController(selection: const EditorSelection.unit(0));
        await _pump(tester, InspectorPanel(controller: controller, fps: _fps));

        await tester.enterText(
            find.byKey(const Key('inspector-transcript-field')), '第一版');
        await tester.pump();
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();
        expect(controller.canUndo, isTrue);

        await tester
            .tap(find.byKey(const Key('inspector-transcript-field')));
        await tester.pump();
        await tester.enterText(
            find.byKey(const Key('inspector-transcript-field')), '第二版');
        await tester.pump();
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();

        expect(controller.units[0].transcript, '第二版');
        controller.undo();
        expect(controller.units[0].transcript, '第一版',
            reason: '两次聚焦分属两条独立记录，第一次 undo 应只回退到上一条记录点');
        controller.undo();
        expect(controller.units[0].transcript, '第一句台词');
      });
    });
  });
}

/// **拆分 / 并入必须永远看得见。**
///
/// 2026-09-09 设计走查真机：属性栏里时间、锁定说明、标签、音色、台词框
/// 加起来早就超过一屏，而「拆分 / 并入」排在最后——跟着滚就永远落在
/// 可视区外，人根本不知道有这两个按钮。现在把它们钉在面板底部。
/// 「取自」这一行回答的是**这一段的画面从哪儿来**。
///
/// 真机（拼片任务 U1，2026-09-16）：这个分子 hasSource 为真——它是从别的
/// 任务搬过来的一段——同时固定了底片。这条任务根本没有原片文件，画面早就
/// 是底片那条素材了，面板上却写着「取自原片 00:00.00–00:10.00」，
/// 一条并不存在的原片上的坐标。
void _baseOriginLine() {
  Future<void> pumpUnit(WidgetTester tester, SemanticUnit unit) async {
    final controller = SegmentationEditorController(
      initialUnits: [unit],
      durationMs: 10000,
      fps: _fps,
      sentences: const [],
    );
    controller.select(const EditorSelection.unit(0));
    await tester.pumpWidget(MaterialApp(
        home: Material(child: InspectorPanel(controller: controller, fps: _fps))));
    await tester.pumpAndSettle();
  }

  const pinned = SemanticUnit(
    uid: 'u0',
    index: 0,
    startMs: 0,
    endMs: 10000,
    transcript: '主卖点解决方案',
    baseCandidateId: 114799,
    shots: [
      Shot(startMs: 0, endMs: 5000),
      Shot(startMs: 5000, endMs: 10000),
    ],
  );

  testWidgets('固定过底片：写「取自底片」，不写那条并不存在的原片', (tester) async {
    await pumpUnit(tester, pinned);

    expect(find.text('取自底片'), findsOneWidget);
    expect(find.text('取自原片'), findsNothing);
  });

  testWidgets('时长按底片那几镜算，别和上面的「成片 0~16.09」打架', (tester) async {
    // 16.09s 的底片挂在一个 10s 的原片坑位上：unit.durationMs 还是 10s
    await pumpUnit(
        tester,
        const SemanticUnit(
          uid: 'u0',
          index: 0,
          startMs: 0,
          endMs: 10000,
          transcript: '主卖点解决方案',
          baseCandidateId: 114799,
          shots: [
            Shot(startMs: 0, endMs: 8000),
            Shot(startMs: 8000, endMs: 16090),
          ],
        ));

    expect(find.text('16.09s'), findsOneWidget);
    expect(find.text('10.00s'), findsNothing);
  });

  testWidgets('没固定底片的照旧写「取自原片」', (tester) async {
    // copyWith 清不掉 baseCandidateId（null 是「不改」），重建一个
    await pumpUnit(
        tester,
        const SemanticUnit(
          uid: 'u0',
          index: 0,
          startMs: 0,
          endMs: 10000,
          transcript: '主卖点解决方案',
          shots: [
            Shot(startMs: 0, endMs: 5000),
            Shot(startMs: 5000, endMs: 10000),
          ],
        ));

    expect(find.text('取自原片'), findsOneWidget);
    expect(find.text('取自底片'), findsNothing);
  });
}

void _pinnedActions() {
  testWidgets('面板矮到装不下时，拆分/并入还在屏幕上', (tester) async {
    final controller = SegmentationEditorController(
      initialUnits: [
        SemanticUnit(
          uid: 'u0',
          index: 0,
          startMs: 0,
          endMs: 16010,
          transcript: '早就跟你们说了，我长痘就是全家衣服混洗有细菌，你们总说开水烫烫就好了',
          tags: const ['促单', '实拍', '口播', '细菌清洁', '品类PK'],
          shots: [
            for (var i = 0; i < 13; i++)
              Shot(startMs: i * 1231, endMs: (i + 1) * 1231),
          ],
        ),
      ],
      durationMs: 16010,
      fps: _fps,
      sentences: const [],
    );
    controller.select(const EditorSelection.unit(0));

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 480,
            // 真机上属性栏就这么高
            height: 385,
            child: InspectorPanel(controller: controller, fps: _fps),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final split = find.textContaining('拆分单元');
    expect(split, findsOneWidget);

    // 真的画在可视区里，不是「存在但被裁掉了」
    final panel = tester.getRect(find.byType(InspectorPanel));
    final rect = tester.getRect(split);
    expect(rect.bottom, lessThanOrEqualTo(panel.bottom + 0.5),
        reason: '按钮被挤出了可视区，人根本看不到它');
    expect(rect.top, greaterThanOrEqualTo(panel.top - 0.5));
  });
}

/// 拼片（空白任务）没有镜头层：一个「分子」整段挑一条素材。
///
/// 2026-09-09 设计走查真机：拼片任务的整片概览里写着「换过画面的镜头 0 / 0」
/// ——一行没有意义的数。它该说的是「几个分子填上了」。
void _blankOverview() {
  testWidgets('拼片的整片概览说分子进度，不说镜头', (tester) async {
    final controller = SegmentationEditorController(
      initialUnits: const [
        SemanticUnit(
            uid: 'b0',
            index: 0,
            startMs: 0,
            endMs: 10000,
            transcript: '',
            hasSource: false,
            shots: []),
        SemanticUnit(
            uid: 'b1',
            index: 1,
            startMs: 10000,
            endMs: 20000,
            transcript: '',
            hasSource: false,
            shots: []),
      ],
      durationMs: 20000,
      fps: _fps,
      sentences: const [],
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 480,
          height: 600,
          child: InspectorPanel(
            controller: controller,
            fps: _fps,
            blankTask: true,
            // 第一个分子挑到了素材（有成片时长）
            composedDurationOf: (i) => i == 0 ? 8000 : null,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('整片（拼片）'), findsOneWidget);
    expect(find.text('分子'), findsOneWidget);
    expect(find.text('换过画面的镜头'), findsNothing,
        reason: '拼片没有镜头层，这一行永远是 0 / 0');
    expect(find.text('已挑到素材的分子'), findsOneWidget);
    expect(find.text('1 / 2'), findsOneWidget);
  });
}
