import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ffmpeg/process_runner.dart';
import 'package:ishkafel/core/miaoa/miaoa_tag_service.dart';
import 'package:ishkafel/core/models/tag_group_ref.dart';
import 'package:ishkafel/features/tasks/new_task_wizard/new_task_wizard.dart';
import 'package:ishkafel/features/tasks/new_task_wizard/wizard_body.dart';
import 'package:ishkafel/features/tasks/new_task_wizard/wizard_providers.dart';
import 'package:ishkafel/core/miaoa/miaoa_gateway.dart';

/// 带 tags：标签组现在用 `--include-tags` 一次拉回，预览直接用这份数据，
/// 不再为每个组单独请求一次
const _groupsJson = '''
[
  {"id":1279,"groupName":"衣清.消毒液","materialType":"STORYBOARD","tagType":"TENANT",
   "tags":[{"id":1,"tagName":"痛点引入"},{"id":2,"tagName":"产品引入"},
           {"id":3,"tagName":"功效演示"}]},
  {"id":136,"groupName":"画面类型","materialType":"STORYBOARD","tagType":"AI",
   "tags":[{"id":4,"tagName":"真人口播"},{"id":5,"tagName":"产品特写"}]}
]
''';

const _tagsJson = '''
[
  {"id":1,"tagGroupId":1279,"tagName":"痛点引入"},
  {"id":2,"tagGroupId":1279,"tagName":"产品引入"},
  {"id":3,"tagGroupId":1279,"tagName":"功效演示"}
]
''';

/// 假 CLI：按子命令返回 fixture，绝不碰真实 miaoa
ProcessRunner fakeCli({
  String groups = _groupsJson,
  String tags = _tagsJson,
  int exitCode = 0,
  String stderr = '',
}) =>
    (_, args) async => ProcessResult(1, exitCode,
        args.contains('group') ? groups : tags, stderr);

/// 起不来的 CLI（未安装）
Future<ProcessResult> missingCli(String exe, List<String> args) async =>
    throw ProcessException(exe, args, 'No such file or directory', 2);

NewTaskWizardResult? lastResult;

Widget wrap({
  ProcessRunner? run,
  VideoFilePicker? picker,
  VoidCallback? cancelPicker,
}) {
  lastResult = null;
  return ProviderScope(
    overrides: [
      if (cancelPicker != null)
        videoFilePickerCancelProvider.overrideWithValue(cancelPicker),
      miaoaTagServiceProvider.overrideWithValue(
          MiaoaTagService(gateway: MiaoaGateway(run: run ?? fakeCli(), binary: 'miaoa'))),
      videoFilePickerProvider
          .overrideWithValue(picker ?? () async => '/videos/滴露_测试片.mp4'),
    ],
    child: MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async =>
                  lastResult = await showNewTaskWizard(context),
              child: const Text('打开向导'),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> openWizard(WidgetTester tester, Widget app) async {
  await tester.pumpWidget(app);
  await tester.tap(find.text('打开向导'));
  await tester.pumpAndSettle();
}

Future<void> pickGroup(WidgetTester tester, Key fieldKey, String name) async {
  // 向导正文是可滚动区，测试窗口较矮时第二个下拉会在视口外
  await tester.ensureVisible(find.byKey(fieldKey));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(fieldKey));
  await tester.pumpAndSettle();
  await tester.tap(find.text(name).last);
  await tester.pumpAndSettle();
  // 多选后勾选不再直接关闭，要按「确定」
  await tester.tap(find.byKey(const Key('tag-group-confirm')));
  await tester.pumpAndSettle();
}

void main() {
  _noAnalysisNote();
  _blankSourceTests();
  _scriptSourceTests();
  testWidgets('向导按设计稿分两步：选一条线 + 两个标签组', (tester) async {
    await openWizard(tester, wrap());

    expect(find.text('新建任务'), findsOneWidget);
    expect(find.textContaining('第 1 步'), findsOneWidget);
    expect(find.textContaining('第 2 步'), findsOneWidget);
    expect(find.text('台词语义单元标签组'), findsOneWidget);
    expect(find.text('视觉镜头标签组'), findsOneWidget);
  });

  testWidgets('miaoa 拉片通道本期不做，但如实说明而不是留个点不动的控件',
      (tester) async {
    await openWizard(tester, wrap());
    // 它是替换裂变的一种「有参考」来源，选完线才露出来
    await tester.tap(find.byKey(const Key('wizard-line-replace')));
    await tester.pumpAndSettle();

    expect(find.text('miaoa 成片库'), findsOneWidget);
    expect(find.textContaining('本期未开放'), findsOneWidget);
  });

  testWidgets('选择本地文件后显示文件名', (tester) async {
    await openWizard(tester, wrap());

    await tester.tap(find.byKey(const Key('wizard-line-replace')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('wizard-pick-local-file')));
    await tester.pumpAndSettle();

    expect(find.textContaining('滴露_测试片'), findsOneWidget);
  });

  testWidgets('选中标签组后展开显示组内标签预览，让用户确认选对了组',
      (tester) async {
    await openWizard(tester, wrap());

    await pickGroup(tester, const Key('wizard-unit-tag-group'), '衣清.消毒液');

    expect(find.text('痛点引入'), findsOneWidget);
    expect(find.text('功效演示'), findsOneWidget);
  });

  group('miaoa 不可用时给可执行的中文引导（不是只写日志）', () {
    testWidgets('CLI 未安装 → 引导先安装，并给「重试」', (tester) async {
      await openWizard(tester, wrap(run: missingCli));

      // 网关的统一文案：说清「装 miaoa 并登录」，不拿 PATH 这种黑话吓用户
      expect(find.textContaining('未找到 miaoa 命令行工具'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    });

    testWidgets('未登录（401）→ 引导 miaoa auth login，且不自动重试',
        (tester) async {
      var calls = 0;
      await openWizard(tester, wrap(run: (_, _) async {
        calls++;
        return ProcessResult(1, 1, '', '401 Unauthorized');
      }));

      expect(find.textContaining('miaoa auth login'), findsOneWidget);
      expect(calls, 1, reason: '401 必须由用户手动重试，不能自动重试');
    });

    testWidgets('网络失败 → 引导检查网络', (tester) async {
      await openWizard(tester, wrap(
          run: (_, _) async =>
              ProcessResult(1, 1, '', 'dial tcp: connection refused')));

      expect(find.textContaining('网络'), findsOneWidget);
    });

    testWidgets('点「重试」会重新拉取标签组', (tester) async {
      var calls = 0;
      await openWizard(tester, wrap(run: (_, args) async {
        calls++;
        return calls == 1
            ? ProcessResult(1, 1, '', 'connection refused')
            : ProcessResult(1, 0, _groupsJson, '');
      }));
      expect(find.text('重试'), findsOneWidget);

      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();

      expect(calls, greaterThan(1));
      expect(find.text('台词语义单元标签组'), findsOneWidget);
      expect(find.text('重试'), findsNothing);
    });

    testWidgets('标签组列表为空 → 说明后果与去哪儿建标签组', (tester) async {
      await openWizard(tester, wrap(run: fakeCli(groups: '[]')));

      expect(find.textContaining('没有可用的标签组'), findsOneWidget);
    });
  });

  group('「开始分析」的可用性与理由', () {
    testWidgets('没选文件、没选标签组时禁用，并说清为什么不能开始与不选的后果',
        (tester) async {
      await openWizard(tester, wrap());

      final button = tester.widget<FilledButton>(
          find.byKey(const Key('wizard-start-btn')));
      expect(button.onPressed, isNull);
      expect(find.textContaining('还需要'), findsOneWidget);
      expect(find.textContaining('候选素材'), findsOneWidget,
          reason: '要说清不选标签组的后果：阶段②检索不到候选素材');
    });

    testWidgets('只选了文件、标签组还没选齐时仍然禁用', (tester) async {
      await openWizard(tester, wrap());
      await tester.tap(find.byKey(const Key('wizard-line-replace')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('wizard-pick-local-file')));
      await tester.pumpAndSettle();
      await pickGroup(tester, const Key('wizard-unit-tag-group'), '衣清.消毒液');

      expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('wizard-start-btn')))
              .onPressed,
          isNull);
      expect(find.textContaining('视觉镜头标签组'), findsWidgets);
    });

    testWidgets('选齐后可开始，返回文件与两个标签组', (tester) async {
      final app = wrap();
      await openWizard(tester, app);

      await tester.tap(find.byKey(const Key('wizard-line-replace')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('wizard-pick-local-file')));
      await tester.pumpAndSettle();
      await pickGroup(tester, const Key('wizard-unit-tag-group'), '衣清.消毒液');
      await pickGroup(tester, const Key('wizard-shot-tag-group'), '画面类型');
      await tester.tap(find.byKey(const Key('wizard-start-btn')));
      await tester.pumpAndSettle();

      expect(lastResult, isNotNull);
      expect(lastResult!.filePath, '/videos/滴露_测试片.mp4');
      expect(lastResult!.unitTagGroups.single,
          const TagGroupRef(id: 1279, name: '衣清.消毒液'));
      expect(lastResult!.shotTagGroups.single, const TagGroupRef(id: 136, name: '画面类型'));
    });

    testWidgets('两层各自可以选多个标签组', (tester) async {
      await openWizard(tester, wrap());
      await tester.tap(find.byKey(const Key('wizard-line-replace')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('wizard-pick-local-file')));
      await tester.pumpAndSettle();

      // 视觉镜头层一次勾两个组
      await tester.ensureVisible(find.byKey(const Key('wizard-shot-tag-group')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('wizard-shot-tag-group')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('画面类型').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('衣清.消毒液').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tag-group-confirm')));
      await tester.pumpAndSettle();

      await pickGroup(tester, const Key('wizard-unit-tag-group'), '衣清.消毒液');
      await tester.tap(find.byKey(const Key('wizard-start-btn')));
      await tester.pumpAndSettle();

      expect(lastResult!.shotTagGroups.map((g) => g.id), [1279, 136],
          reason: '一个镜头本来就该同时有几个维度的标签');
    });

    testWidgets('选多个组时预览是它们标签的并集（打标用的就是这份合并词表）',
        (tester) async {
      await openWizard(tester, wrap());

      await tester.ensureVisible(find.byKey(const Key('wizard-shot-tag-group')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('wizard-shot-tag-group')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('画面类型').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('衣清.消毒液').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tag-group-confirm')));
      await tester.pumpAndSettle();

      // 两个组的标签都出现在预览里
      expect(find.text('痛点引入'), findsOneWidget);
      expect(find.text('真人口播'), findsOneWidget);
    });

    testWidgets('取消返回 null，不建任务', (tester) async {
      await openWizard(tester, wrap());

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(lastResult, isNull);
    });

    testWidgets('给出耗时预期；「取决于什么」放在停上去看得到的地方', (tester) async {
      await openWizard(tester, wrap());

      // 一行说完，详情进 tooltip——两行小字常驻会把上面的表单挤掉半个
      // 输入框（2026-09-09 设计走查真机）
      expect(find.textContaining('分钟'), findsOneWidget);
      expect(WizardFooter.durationDetail, contains('镜头'),
          reason: '耗时几乎全部取决于镜头数（画面打标是最慢的一步）。'
              '只给一个固定数字，用户按它安排时间必然落空');
      expect(WizardFooter.durationDetail, contains('切分确认'),
          reason: '还得说清分析完会去哪儿');
    });

    test('耗时预期不写一个已经不成立的实测值', () {
      expect('${WizardFooter.durationNote}${WizardFooter.durationDetail}',
          isNot(contains('1~2 分钟')),
          reason: '「1~2 分钟（96 秒素材实测）」是并发打标改造前的旧口径，'
              '实测同样长度要几分钟；界面上写一个做不到的数字，'
              '比不给预期更伤信任');
    });
  });
}

/// 「不用原片，从素材拼」这一路。
///
/// 空白任务不需要原片，也不需要镜头标签组（它不分镜头）；但分子标签组仍然
/// 必填——那是打标的受控词表，没有它后面挑素材时没有标签可用。
void _blankSourceTests() {
  testWidgets('选了替换裂变，才露出「不用原片」这个起点', (tester) async {
    await openWizard(tester, wrap());
    // 起点是线里面的事：没选线之前不该看见
    expect(find.text('不用原片，从素材拼'), findsNothing);

    await tester.tap(find.byKey(const Key('wizard-line-replace')));
    await tester.pumpAndSettle();

    expect(find.text('不用原片，从素材拼'), findsOneWidget);
    expect(find.textContaining('用标签搜素材拼片'), findsOneWidget);
  });

  testWidgets('选了它之后，缺的只剩分子标签组——不再要求选文件、也不要镜头标签组',
      (tester) async {
    await openWizard(tester, wrap());
    await tester.tap(find.byKey(const Key('wizard-line-replace')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('wizard-blank-source')));
    await tester.pumpAndSettle();

    expect(find.textContaining('选择本地成片文件'), findsNothing);
    expect(find.textContaining('视觉镜头标签组'), findsWidgets,
        reason: '标签组区域还在，只是不再是必填');
    expect(find.textContaining('还需要：'), findsWidgets);
  });

  testWidgets('只选分子标签组就能开始，交回来的 filePath 是 null', (tester) async {
    await openWizard(tester, wrap());
    await tester.tap(find.byKey(const Key('wizard-line-replace')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('wizard-blank-source')));
    await tester.pumpAndSettle();
    await pickGroup(tester, const Key('wizard-unit-tag-group'), '衣清.消毒液');
    await tester.ensureVisible(find.text('创建拼片任务'));
    await tester.tap(find.text('创建拼片任务'));
    await tester.pumpAndSettle();

    expect(lastResult, isNotNull);
    expect(lastResult!.filePath, isNull, reason: 'null 就是「没有原片」这件事本身');
    expect(lastResult!.unitTagGroups, isNotEmpty);
  });
}

/// 「脚本成片」这一路：写脚本，配音配镜长出成片（编导台）。
///
/// 与拼片同理：没有原片可导，也不分镜头，镜头标签组不必填；
/// 分子标签组仍必填——它是台词打标与后续检索的受控词表。
void _scriptSourceTests() {
  testWidgets('第 1 步就两张卡：替换裂变、脚本成片', (tester) async {
    await openWizard(tester, wrap());

    expect(find.text('替换裂变'), findsOneWidget);
    expect(find.text('脚本成片'), findsOneWidget);
    expect(find.textContaining('从台词造新片'), findsOneWidget);
  });

  testWidgets('选了它之后不再要求选文件；只选分子标签组就能开始', (tester) async {
    await openWizard(tester, wrap());
    await tester.tap(find.byKey(const Key('wizard-line-script')));
    await tester.pumpAndSettle();

    expect(find.textContaining('选择本地成片文件'), findsNothing);

    await pickGroup(tester, const Key('wizard-unit-tag-group'), '衣清.消毒液');
    await tester.ensureVisible(find.text('创建脚本成片'));
    await tester.tap(find.text('创建脚本成片'));
    await tester.pumpAndSettle();

    expect(lastResult, isNotNull);
    expect(lastResult!.script, isTrue);
    expect(lastResult!.filePath, isNull);
    expect(lastResult!.unitTagGroups, isNotEmpty);
  });

  testWidgets('脚本卡与拼片/本地文件互斥：后选的生效', (tester) async {
    await openWizard(tester, wrap());
    await tester.tap(find.byKey(const Key('wizard-line-script')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('wizard-line-replace')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('wizard-blank-source')));
    await tester.pumpAndSettle();

    await pickGroup(tester, const Key('wizard-unit-tag-group'), '衣清.消毒液');
    await tester.ensureVisible(find.text('创建拼片任务'));
    await tester.tap(find.text('创建拼片任务'));
    await tester.pumpAndSettle();

    expect(lastResult!.script, isFalse, reason: '改选拼片后脚本选择必须被清掉');
  });
}

/// **不跑分析的那两条线，别摆分析的耗时和额度。**
///
/// 2026-09-09 设计走查：选了「脚本成片」，按钮已经变成「创建脚本成片」，
/// 底下却还写着「预计耗时数分钟，消耗云端 API 额度」——这条线建出来直接
/// 进编导台，一次云端调用都没有，那句话凭空吓人一跳。
void _noAnalysisNote() {
  testWidgets('脚本成片：说「直接进工作台」，不说耗时和额度', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: WizardFooter(
          missing: const [],
          startLabel: '创建脚本成片',
          analyses: false,
          onCancel: () {},
          onStart: () {},
        ),
      ),
    ));

    expect(find.textContaining('不跑分析'), findsOneWidget);
    expect(find.textContaining('API 额度'), findsNothing,
        reason: '这条线一次云端调用都没有');
  });

  testWidgets('替换裂变照旧给耗时预期', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: WizardFooter(
          missing: const [],
          onCancel: () {},
          onStart: () {},
        ),
      ),
    ));

    expect(find.textContaining('API 额度'), findsOneWidget);
  });
}
