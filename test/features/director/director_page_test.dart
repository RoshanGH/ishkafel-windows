import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/audio_extractor.dart';
import 'package:ishkafel/core/analysis/providers.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/script/script_doc.dart';
import 'package:ishkafel/core/audio/tts_client.dart';
import 'package:ishkafel/core/audio/voice_catalog.dart';
import 'package:ishkafel/core/script/line_voice_service.dart';
import 'package:ishkafel/core/miaoa/candidate_probe.dart';
import 'package:ishkafel/core/miaoa/miaoa_content_service.dart';
import 'package:ishkafel/core/miaoa/miaoa_gateway.dart';
import 'package:ishkafel/core/miaoa/miaoa_tag_service.dart';
import 'package:ishkafel/core/script/script_transcriber.dart';
import 'package:ishkafel/core/storage/task_repository.dart';
import 'package:ishkafel/features/director/director_page.dart';
import 'package:ishkafel/features/director/director_providers.dart';
import 'package:ishkafel/features/tasks/new_task_wizard/wizard_providers.dart';
import 'package:ishkafel/features/tasks/task_list_controller.dart';

/// 编导台 M1：左栏脚本编辑 + 自动落盘 + 空态起步引导 + 从视频提取脚本。
/// 验收口径（实现分期）：建任务 → 写十行脚本 → 关掉重开不丢 → 行操作全可用。
class _MemoryRepo implements TaskRepository {
  final _store = <String, RenewTask>{};
  @override
  Future<List<RenewTask>> findAll() async => _store.values.toList();
  @override
  Future<RenewTask?> findById(String id) async => _store[id];
  @override
  Future<void> save(RenewTask task) async => _store[task.id] = task;
  @override
  Future<void> delete(String id) async => _store.remove(id);
}

/// 假 ASR / 假断句：不碰任何真实服务
class _FakeAsr implements AsrProvider {
  final List<AsrSentence> sentences;
  _FakeAsr(this.sentences);
  @override
  Future<List<AsrSentence>> transcribe(String pcmPath) async => sentences;
}

/// 纯内存 stub：widget 测试跑在 fake-async 区，真实文件 IO 的 future
/// 永远不会完成（pumpAndSettle 会挂死），所以 extract 整个换掉。
/// 真实的抽音频→ASR→断句编排逻辑在 test/core/script/ 的普通单测里覆盖
class _StubTranscriber extends ScriptTranscriber {
  final List<String>? lines;
  final String? failWith;
  _StubTranscriber({this.lines, this.failWith})
      : super(
          audio: AudioExtractor(run: (_, _) async => ProcessResult(1, 0, '', '')),
          asr: _FakeAsr(const []),
          workDir: Directory.systemTemp,
        );

  @override
  Future<List<ScriptLine>> extract(String videoPath,
      {void Function(ScriptTranscribeStage stage)? onStage}) async {
    onStage?.call(ScriptTranscribeStage.transcribing);
    if (failWith != null) throw ScriptTranscribeException(failWith!);
    return [
      for (final text in lines ?? const ['第一句台词', '第二句台词'])
        ScriptLine.create(text: text),
    ];
  }
}

/// 纯内存配音服务：不碰 TTS 与文件系统
class _StubVoiceService extends LineVoiceService {
  final bool fail;

  /// 生成的配音带不带逐字时间（老服务端不带——那是「补不上」的场景）
  final bool withWords;
  _StubVoiceService({this.fail = false, this.withWords = false})
      : super(
          tts: const TtsClient(appId: 't', accessToken: 't'),
          outputDir: Directory.systemTemp,
          measureMs: (_) async => 0,
        );

  @override
  Future<LineVoiceover> generate({
    required String lineId,
    required String text,
    required String voiceId,
    int speechRate = 0,
    String? instruction,
  }) async {
    if (fail) throw const TtsException('连接语音合成服务超时，请检查网络后重试');
    final t = text.trim();
    return LineVoiceover(
      audioPath: '/tmp/fake.mp3',
      durationMs: 3200,
      sourceText: t,
      voiceId: voiceId,
      speechRate: speechRate,
      words: [
        if (withWords)
          for (var i = 0; i < t.length; i++)
            VoiceWord(
                text: t[i],
                startMs: (i * 3200 / t.length).round(),
                endMs: (i * 3200 / t.length).round() + 120),
      ],
    );
  }

  @override
  void deleteStale(LineVoiceover old) {}
}

RenewTask scriptTask({ScriptDoc? doc}) => RenewTask(
      id: 't1',
      seq: 7,
      name: '测试脚本',
      sourcePath: null,
      script: doc ?? ScriptDoc.empty(),
      status: RenewTaskStatus.ready,
      createdAt: DateTime.utc(2026, 8, 19),
      updatedAt: DateTime.utc(2026, 8, 19),
    );

ScriptDoc docWith(List<String> texts) {
  var doc = ScriptDoc.empty().updateText(0, texts.first);
  for (var i = 1; i < texts.length; i++) {
    doc = doc.insertAfter(i - 1, text: texts[i]);
  }
  return doc;
}

Widget wrap(TaskRepository repo, RenewTask task,
        {List<Override> overrides = const []}) =>
    ProviderScope(
      overrides: [
        taskRepositoryProvider.overrideWithValue(repo),
        videoFilePickerProvider.overrideWithValue(() async => null),
        ...overrides,
      ],
      // 播放器注入空工厂：单测不碰 libmpv，中栏保持占位态
      child: MaterialApp(
          home: DirectorPage(task: task, playbackFactory: () => null)),
    );

/// hover 到某行上（拖柄/删除按钮都藏在 hover 里）
Future<TestGesture> hoverLine(WidgetTester tester, int index) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  await gesture.moveTo(
      tester.getCenter(find.byKey(ValueKey('script-line-$index'))));
  await tester.pumpAndSettle();
  return gesture;
}

/// 编导台是全屏工作页，默认测试窗口 800x600 连三栏都摆不下。
/// 统一用桌面全屏尺寸跑，跟真实使用一致
Future<void> pumpDirector(WidgetTester tester, Widget widget) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(widget);
}


/// 草片自动配镜用的假 miaoa（检索/词表/探测全假）
class _DraftFakeCli {
  final calls = <List<String>>[];

  /// 每次检索发一条新素材：同一条会被防撞车（已占用）过滤掉，
  /// 第二句就配不上镜头了——真实素材库不会两句搜出同一条 Top1
  var _nextId = 500;

  Future<ProcessResult> call(String exe, List<String> args) async {
    calls.add(args);
    if (args.contains('search')) {
      final id = ++_nextId;
      return ProcessResult(
          1,
          0,
          '{"total":1,"records":[{"id":$id,"name":"自动镜头$id",'
              '"sceneDescription":"画面","voiceover":"词",'
              '"mediaFile":{"thumbnailUrl":"https://e.com/$id.jpg",'
              '"previewUrl":"https://e.com/$id.mp4","fileKey":"oss/$id.mp4"}}]}',
          '');
    }
    if (args.contains('group')) {
      return ProcessResult(
          1,
          0,
          '[{"id":10,"groupName":"话术结构","materialType":"STORYBOARD",'
              '"tagType":"PUBLIC","tags":[{"tagName":"促单"}]}]',
          '');
    }
    if (args.contains('tag')) {
      return ProcessResult(1, 0, '[{"id":101,"tagName":"促单"}]', '');
    }
    return ProcessResult(1, 0, '[]', '');
  }
}

ShotSearchServices _draftFakeServices(_DraftFakeCli cli) {
  final gateway = MiaoaGateway(run: cli.call, binary: 'miaoa');
  return ShotSearchServices(
    content: MiaoaContentService(gateway: gateway),
    probe: CandidateProbe(
        run: (_, _) async => ProcessResult(
            1, 0, 'width=1080\nheight=1920\nduration=5.0\n', '')),
    tags: MiaoaTagService(gateway: gateway),
  );
}

void main() {
  testWidgets('空脚本先回答「从哪里开始」：提取脚本与直接写两条路', (tester) async {
    await pumpDirector(tester, wrap(_MemoryRepo(), scriptTask()));
    await tester.pumpAndSettle();

    expect(find.textContaining('写下脚本'), findsOneWidget);
    expect(find.byKey(const ValueKey('director-guide-extract')), findsOneWidget);
    expect(find.byKey(const ValueKey('director-guide-write')), findsOneWidget);
    // 未配置 AI 服务时提取那条路禁用并说明原因，绝不是点了没反应
    expect(find.textContaining('需要先配置 AI 服务'), findsOneWidget);
    expect(find.text('推荐'), findsNothing,
        reason: '不可用的路径不该还挂着「推荐」');
    expect(find.text('画面行'), findsNothing,
        reason: '引导激活时右栏行工作台收敛，两套话语不打架');
  });

  testWidgets('点「直接开始写」后引导让位给预览舞台', (tester) async {
    await pumpDirector(tester, wrap(_MemoryRepo(), scriptTask()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('director-guide-write')));
    await tester.pumpAndSettle();

    expect(find.textContaining('在这里试片'), findsOneWidget,
        reason: '占位不许是一块死区域，要说明这里将来是什么');
    expect(find.text('00:00 / 00:00'), findsOneWidget,
        reason: '传输条骨架预告播放器的形状');
  });

  testWidgets('非空脚本直接进写作台：三栏 + 顶栏身份与自动保存说明', (tester) async {
    await pumpDirector(
        tester, wrap(_MemoryRepo(), scriptTask(doc: docWith(['开场白']))));
    await tester.pumpAndSettle();

    expect(find.text('脚本'), findsOneWidget);
    expect(find.textContaining('在这里试片'), findsOneWidget);
    expect(find.text('#7'), findsOneWidget, reason: '顶栏要带短编号');
    expect(find.text('编导台'), findsOneWidget);
    expect(find.textContaining('自动保存'), findsOneWidget,
        reason: '自动保存要说出来，用户才不会找「保存」按钮');
    // 行带式：右板的块与左栏台词一一对应、全部铺开（不随选中切换）
    expect(find.byKey(const ValueKey('band-generate-0')), findsOneWidget,
        reason: '配音行的块自带生成入口');
    expect(find.byKey(const ValueKey('band-find-shots-0')), findsOneWidget,
        reason: '每块自带找镜头入口');
  });

  testWidgets('行带板：所有行的块同时铺开，不随选中切换', (tester) async {
    await pumpDirector(tester,
        wrap(_MemoryRepo(), scriptTask(doc: docWith(['第一句', '第二句', '第三句']))));
    await tester.pumpAndSettle();

    for (var i = 0; i < 3; i++) {
      expect(find.byKey(ValueKey('band-find-shots-$i')), findsOneWidget,
          reason: '视频是序列，人从上往下扫——块不许藏在选中背后');
    }
    expect(find.text('第一句'), findsNWidgets(2),
        reason: '左栏可编辑 + 右板块头只读，各一份');
  });

  testWidgets('写字自动变配音行，右板块跟着变', (tester) async {
    await pumpDirector(tester, wrap(_MemoryRepo(), scriptTask()));
    await tester.pumpAndSettle();
    // 空脚本先是引导态，选「直接写」进入写作台
    await tester.tap(find.byKey(const ValueKey('director-guide-write')));
    await tester.pumpAndSettle();

    expect(find.textContaining('画面行（无台词'), findsWidgets);
    await tester.enterText(find.byType(TextField).first, '世界上只有两种人');
    // 打字期间不写文档（不然中文输入法的组合会被打断），停手才落盘
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('band-generate-0')), findsOneWidget,
        reason: '有字了就是配音行，块底出现配音行控件');
  });

  testWidgets('回车在当前行后插入新行，选中跳到新行', (tester) async {
    await pumpDirector(tester, wrap(_MemoryRepo(), scriptTask()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '第一句');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('script-line-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('band-find-shots-1')), findsOneWidget,
        reason: '新行的工作块立刻出现在右板');
  });

  testWidgets('改动自动落盘（防抖后），不存在「保存」按钮', (tester) async {
    final repo = _MemoryRepo();
    await pumpDirector(tester, wrap(repo, scriptTask()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '要落盘的一句');
    // 停手 1.2 秒才写文档，再加上文档自身的落盘防抖
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));

    final saved = await repo.findById('t1');
    expect(saved?.script?.lines.first.text, '要落盘的一句');
    expect(find.text('保存'), findsNothing);
  });

  testWidgets('重开不丢：带已有脚本的任务进来，内容原样呈现', (tester) async {
    await pumpDirector(tester, wrap(
        _MemoryRepo(), scriptTask(doc: docWith(['上次写的', '还有这句']))));
    await tester.pumpAndSettle();

    expect(find.text('上次写的'), findsNWidgets(2),
        reason: '左栏可编辑一份 + 右板块头只读一份');
    expect(find.text('还有这句'), findsNWidgets(2));
  });

  testWidgets('删除藏在 hover 里；最后一行不许删', (tester) async {
    final repo = _MemoryRepo();
    await pumpDirector(
        tester, wrap(repo, scriptTask(doc: docWith(['A', 'B']))));
    await tester.pumpAndSettle();

    // 未悬停时不该有一排叉常驻
    expect(find.byKey(const ValueKey('script-line-remove-1')), findsNothing);

    final gesture = await hoverLine(tester, 1);
    await tester.tap(find.byKey(const ValueKey('script-line-remove-1')));
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('B'), findsNothing);

    // 只剩一行时 hover 也不给删除入口——脚本至少留一行可写
    await gesture
        .moveTo(tester.getCenter(find.byKey(const ValueKey('script-line-0'))));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('script-line-remove-0')), findsNothing);
  });

  testWidgets('画面行可手填时长，落到 manualMs（块内直填，无需选中）', (tester) async {
    final repo = _MemoryRepo();
    await pumpDirector(
        tester, wrap(repo, scriptTask(doc: docWith(['台词', '']))));
    await tester.pumpAndSettle();

    final field = find.byWidgetPredicate((w) =>
        w is TextFormField && w.key.toString().contains('band-manual-ms'));
    expect(field, findsOneWidget, reason: '画面行的块自带手填时长入口');
    await tester.enterText(field, '3.5');
    await tester.pump(const Duration(seconds: 1));

    final saved = await repo.findById('t1');
    expect(saved?.script?.lines[1].manualMs, 3500);
  });

  testWidgets('从视频提取脚本：起步卡一路走通，行整体填充并落盘', (tester) async {
    final repo = _MemoryRepo();
    await pumpDirector(tester, wrap(repo, scriptTask(), overrides: [
      scriptTranscriberProvider
          .overrideWithValue(_StubTranscriber(lines: ['你好呀', '再见啦'])),
      videoFilePickerProvider.overrideWithValue(() async => '/v/参考片.mp4'),
    ]));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('director-guide-extract')));
    await tester.pumpAndSettle();

    expect(find.text('你好呀'), findsNWidgets(2));
    expect(find.text('再见啦'), findsNWidgets(2));
    final saved = await repo.findById('t1');
    expect(saved?.script?.lines.map((l) => l.text), ['你好呀', '再见啦'],
        reason: '提取结果要立刻落盘');
  });

  testWidgets('脚本非空时顶栏没有提取入口——覆盖式提取只属于空态起步',
      (tester) async {
    final repo = _MemoryRepo();
    await pumpDirector(
        tester, wrap(repo, scriptTask(doc: docWith(['辛苦写的'])), overrides: [
      scriptTranscriberProvider.overrideWithValue(_StubTranscriber()),
      videoFilePickerProvider.overrideWithValue(() async => '/v/参考片.mp4'),
    ]));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('director-extract-script')), findsNothing,
        reason: '提取会把整份脚本连同配音/镜头/字幕一起作废——'
            '这种一次性破坏动作不该常驻顶栏');
    expect(find.byKey(const ValueKey('director-subtitle')), findsNothing,
        reason: '字幕样式由预览下方的工具条接管，一个功能只留一个入口');
    expect(find.text('辛苦写的'), findsNWidgets(2));
  });

  testWidgets('提取失败给原因和重试入口，不静默', (tester) async {
    final repo = _MemoryRepo();
    await pumpDirector(tester, wrap(repo, scriptTask(), overrides: [
      scriptTranscriberProvider.overrideWithValue(_StubTranscriber(
          failWith: '这条视频里没有识别到任何台词——请确认它有人声口播。')),
      videoFilePickerProvider.overrideWithValue(() async => '/v/参考片.mp4'),
    ]));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('director-guide-extract')));
    await tester.pumpAndSettle();

    expect(find.textContaining('没有识别到任何台词'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });
  group('配音节（M2）', () {
    testWidgets('未配置语音服务时按钮禁用；配置后选音色→生成→试听条与绿点',
        (tester) async {
      final repo = _MemoryRepo();
      await pumpDirector(
          tester, wrap(repo, scriptTask(doc: docWith(['你好呀']))));
      await tester.pumpAndSettle();

      // 未接语音服务时点生成会得到明确提示（handlers 在页面层拦截）
      await tester.tap(find.byKey(const ValueKey('band-generate-0')));
      await tester.pumpAndSettle();
      expect(find.textContaining('尚未配置 AI 服务'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('生成一路走通：先弹音色选择，选完直接生成，状态点变绿',
        (tester) async {
      final repo = _MemoryRepo();
      await pumpDirector(
          tester,
          wrap(repo, scriptTask(doc: docWith(['你好呀'])), overrides: [
            lineVoiceFactoryProvider
                .overrideWithValue((_) => _StubVoiceService()),
          ]));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('band-generate-0')));
      await tester.pumpAndSettle();
      // 没选过音色：先弹选择器
      expect(find.text('选择音色'), findsWidgets);
      await tester.tap(find
          .byKey(const ValueKey('voice-option-zh_female_vv_uranus_bigtts')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('就用这个'));
      await tester.pumpAndSettle();

      expect(find.text('3.2s'), findsOneWidget, reason: '块底显示实际时长');
      final saved = await repo.findById('t1');
      expect(saved?.script?.lines.first.voiceover?.durationMs, 3200,
          reason: '配音产物要落盘');
    });

    testWidgets('改台词后状态变黄、旧配音仍可听、按钮变「重新生成」', (tester) async {
      final repo = _MemoryRepo();
      var doc = docWith(['你好呀']);
      doc = doc.setVoiceId(0, 'zh_female_vv_uranus_bigtts');
      doc = doc.setVoiceoverById(
          doc.lines.first.id,
          LineVoiceover(
              audioPath: '/tmp/old.mp3',
              durationMs: 2000,
              sourceText: '你好呀',
              voiceId: 'zh_female_vv_uranus_bigtts',
              speechRate: 0));
      await pumpDirector(
          tester,
          wrap(repo, scriptTask(doc: doc), overrides: [
            lineVoiceFactoryProvider
                .overrideWithValue((_) => _StubVoiceService()),
          ]));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, '你好呀改了');
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      expect(find.textContaining('配音是旧的'), findsOneWidget);
      expect(find.text('重新生成'), findsOneWidget);
      expect(find.text('2.0s'), findsOneWidget, reason: '旧配音仍可试听');
    });

    testWidgets('生成失败给中文原因，不静默', (tester) async {
      final repo = _MemoryRepo();
      var doc = docWith(['你好呀']);
      doc = doc.setVoiceId(0, 'zh_female_vv_uranus_bigtts');
      await pumpDirector(
          tester,
          wrap(repo, scriptTask(doc: doc), overrides: [
            lineVoiceFactoryProvider
                .overrideWithValue((_) => _StubVoiceService(fail: true)),
          ]));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('band-generate-0')));
      await tester.pumpAndSettle();

      expect(find.textContaining('配音生成失败'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5)); // 等 SnackBar 收场
    });
  });
  group('行带板（2026-08-20 布局重构）', () {
    testWidgets('提取的行带参考段：参考卡在块内、可「用它」一键作首镜',
        (tester) async {
      final repo = _MemoryRepo();
      var doc = ScriptDoc(
        [
          ScriptLine.create(
              text: '再不买就恢复',
              reference: LineRef(startMs: 1000, endMs: 4200)),
        ],
        refVideoPath: '/v/参考片.mp4',
      );
      doc = doc.setVoiceoverById(
          doc.lines.first.id,
          LineVoiceover(
              audioPath: '/vo.mp3',
              durationMs: 3200,
              sourceText: '再不买就恢复',
              voiceId: 'v',
              speechRate: 0));
      final cli = _DraftFakeCli();
      await pumpDirector(
          tester,
          wrap(repo, scriptTask(doc: doc), overrides: [
            shotSearchServicesProvider
                .overrideWithValue(_draftFakeServices(cli)),
          ]));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('band-ref-0-0')), findsOneWidget,
          reason: '块级只保留分子粒度：一张整段参考卡（点击播放对照）');
      expect(find.text('参考'), findsOneWidget,
          reason: '左侧参考卡的身份角标');
      expect(find.text('3.2s'), findsWidgets, reason: '参考时长在卡底衬条');

      // 原子在找镜头面板里：点开面板 → 原子条 → 「直接用原片这段」
      await tester.tap(find.byKey(const ValueKey('band-find-shots-0')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('shots-ref-atom-0')), findsOneWidget,
          reason: '参考原子（分镜）在搜索界面里当检索条件');
      await tester.tap(find.byKey(const ValueKey('shots-use-ref-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('用这些镜头'));
      await tester.pump(const Duration(seconds: 1));

      final saved = await repo.findById('t1');
      final shot = saved!.script!.lines.first.shots.first;
      expect(shot.localSource, '/v/参考片.mp4',
          reason: '参考段一键作镜头：本地源直接引用原片');
      expect(shot.trimStartMs, 1000);
      expect(shot.allocMs, 3200, reason: '按行根（配音时长）分配');
    });

    testWidgets('字幕屏：详情里一屏一行，改字落盘、并屏、这屏不出字',
        (tester) async {
      final repo = _MemoryRepo();
      const text = '家人们你好呀这是我们今年最新的爆款产品真的很好用';
      var doc = docWith([text]);
      doc = doc.setVoiceoverById(
          doc.lines.first.id,
          LineVoiceover(
            audioPath: '/vo.mp3',
            durationMs: 6000,
            sourceText: text,
            voiceId: 'v',
            speechRate: 0,
            // 逐字时间戳：屏的切点跟语言走，靠它算
            words: [
              for (var i = 0; i < text.length; i++)
                VoiceWord(
                    text: text[i],
                    startMs: (i * 6000 / text.length).round(),
                    endMs: (i * 6000 / text.length).round() + 200),
            ],
          ));
      doc = doc.setShotsById(doc.lines.first.id, const [
        LineShot(materialId: 1, name: 'a', durationMs: 8000, allocMs: 6000),
      ]);
      await pumpDirector(tester, wrap(repo, scriptTask(doc: doc)));
      await tester.pumpAndSettle();

      // 一个长镜头下的长台词自动切成好几屏——不许堆在画面上
      final screens = doc.lines.first.subtitleScreensAt();
      expect(screens.length, greaterThan(1));

      await tester.tap(find.byKey(const ValueKey('band-shot-0-0')));
      await tester.pumpAndSettle();
      expect(find.text('字幕 · ${screens.length} 屏'), findsOneWidget,
          reason: '详情里说清这一镜下有几屏字');

      // 改第一屏的字：只改这一屏
      await tester.enterText(
          find.byKey(ValueKey(
              'band-screen-0-0-${screens.first.text.hashCode}')),
          '家人们好');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pumpAndSettle();
      var saved = await repo.findById('t1');
      var line = saved!.script!.lines.first;
      expect(line.subtitleScreensAt().first.text, '家人们好');
      expect(line.subtitleScreensAt().length, screens.length,
          reason: '改字不改切点');

      // 拆屏：从中间再切一刀
      final n0 = line.subtitleScreensAt().length;
      await tester.tap(find.byKey(const ValueKey('band-screen-split-0-0')));
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pumpAndSettle();
      saved = await repo.findById('t1');
      line = saved!.script!.lines.first;
      expect(line.subtitleScreensAt().length, n0 + 1,
          reason: '拆屏：不用播放也能手工切一刀');

      // 第 2 屏并回上一屏
      final before = line.subtitleScreensAt().length;
      await tester.tap(find.byKey(const ValueKey('band-screen-merge-0-1')));
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pumpAndSettle();
      saved = await repo.findById('t1');
      line = saved!.script!.lines.first;
      expect(line.subtitleScreensAt().length, before - 1);

      // 这屏不出字
      final n = line.subtitleScreensAt().length;
      await tester.tap(find.byKey(const ValueKey('band-screen-hide-0-0')));
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pumpAndSettle();
      saved = await repo.findById('t1');
      expect(saved!.script!.lines.first.subtitleScreensAt().length, n - 1);
    });

    testWidgets('老配音没逐字时间：给出「补上」的路，补完能手工分屏',
        (tester) async {
      final repo = _MemoryRepo();
      const text = '它虽然真的贵但是厨房厨垫上的油渍污垢也是真的怕它';
      var doc = docWith([text]);
      doc = doc.setVoiceId(0, 'zh_female_vv_uranus_bigtts');
      // 早期生成的配音：有音频、没逐字时间
      doc = doc.setVoiceoverById(
          doc.lines.first.id,
          LineVoiceover(
              audioPath: '/tmp/old.mp3',
              durationMs: 5200,
              sourceText: text,
              voiceId: 'zh_female_vv_uranus_bigtts',
              speechRate: 0));
      doc = doc.setShotsById(doc.lines.first.id, const [
        LineShot(materialId: 1, name: 'a', durationMs: 16000, allocMs: 5200),
      ]);
      await pumpDirector(
          tester,
          wrap(repo, scriptTask(doc: doc), overrides: [
            lineVoiceFactoryProvider
                .overrideWithValue((_) => _StubVoiceService(withWords: true)),
          ]));
      await tester.pumpAndSettle();

      // 没逐字时间也照样分屏（不堆字），但说明白是怎么摊的
      expect(doc.lines.first.subtitleScreensAt().length, greaterThan(1));
      await tester.tap(find.byKey(const ValueKey('band-shot-0-0')));
      await tester.pumpAndSettle();
      expect(find.text('按字数均分'), findsOneWidget);
      expect(find.byKey(const ValueKey('band-screen-split-0-0')), findsNothing,
          reason: '改不了的行不摆一排灰图标——那看着像坏了');

      // 出路：补上逐字时间（先说清代价，再动手）
      await tester.tap(find.byKey(const ValueKey('band-fix-timing-0')));
      await tester.pumpAndSettle();
      expect(find.textContaining('重配一次'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('fix-timing-confirm')));
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pumpAndSettle();

      final saved = await repo.findById('t1');
      expect(saved!.script!.lines.first.voiceover!.words, isNotEmpty,
          reason: '补完就有逐字时间了');
      expect(find.textContaining('可以手工分屏'), findsOneWidget);
    });

    testWidgets('补逐字时间没补上要点名，不许装成功', (tester) async {
      final repo = _MemoryRepo();
      var doc = docWith(['它虽然真的贵但是厨房厨垫上的油渍污垢也是真的怕它']);
      doc = doc.setVoiceId(0, 'zh_female_vv_uranus_bigtts');
      doc = doc.setVoiceoverById(
          doc.lines.first.id,
          LineVoiceover(
              audioPath: '/tmp/old.mp3',
              durationMs: 5200,
              sourceText: '它虽然真的贵但是厨房厨垫上的油渍污垢也是真的怕它',
              voiceId: 'zh_female_vv_uranus_bigtts',
              speechRate: 0));
      doc = doc.setShotsById(doc.lines.first.id, const [
        LineShot(materialId: 1, name: 'a', durationMs: 16000, allocMs: 5200),
      ]);
      await pumpDirector(
          tester,
          wrap(repo, scriptTask(doc: doc), overrides: [
            // 服务端照旧不给逐字时间
            lineVoiceFactoryProvider
                .overrideWithValue((_) => _StubVoiceService()),
          ]));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('band-shot-0-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('band-fix-timing-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('fix-timing-confirm')));
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pumpAndSettle();

      expect(find.textContaining('没补上'), findsOneWidget,
          reason: '补不上就点名，不能提示「补好了」');
    });

    testWidgets('躺在方案里的坏配音要在行上标出来，不等人听到才发现',
        (tester) async {
      final repo = _MemoryRepo();
      const text = '不然里面的食物只会越放越脏';
      var doc = docWith([text]);
      doc = doc.setVoiceId(0, 'zh_female_vv_uranus_bigtts');
      // 结尾卡住反复念的那种（大模型 TTS 抽风）
      const heard = '不然里面的食物只会越放越脏越放越脏越放越脏越放越脏';
      doc = doc.setVoiceoverById(
          doc.lines.first.id,
          LineVoiceover(
            audioPath: '/tmp/bad.mp3',
            durationMs: 5000,
            sourceText: text,
            voiceId: 'zh_female_vv_uranus_bigtts',
            speechRate: 0,
            words: [
              for (var i = 0; i < heard.length; i++)
                VoiceWord(
                    text: heard[i],
                    startMs: (i * 5000 / heard.length).round(),
                    endMs: (i * 5000 / heard.length).round() + 100),
            ],
          ));
      await pumpDirector(tester, wrap(repo, scriptTask(doc: doc)));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('band-voice-defect-0')), findsOneWidget);
      expect(find.text('这句念岔了'), findsOneWidget);
    });

    testWidgets('镜头详情在块内展开/收起（内容切换只发生在块内）', (tester) async {
      var doc = docWith(['台词']);
      doc = doc.setVoiceoverById(
          doc.lines.first.id,
          LineVoiceover(
              audioPath: '/vo.mp3',
              durationMs: 4000,
              sourceText: '台词',
              voiceId: 'v',
              speechRate: 0));
      doc = doc.setShotsById(doc.lines.first.id, [
        const LineShot(
            materialId: 9, name: 's', durationMs: 8000, allocMs: 4000),
      ]);
      await pumpDirector(tester, wrap(_MemoryRepo(), scriptTask(doc: doc)));
      await tester.pumpAndSettle();

      expect(find.text('第 1 镜'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('band-shot-0-0')));
      await tester.pumpAndSettle();
      expect(find.text('第 1 镜'), findsOneWidget, reason: '详情在块内展开');
      expect(find.byKey(const ValueKey('band-speed-0-0-1.25')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('band-shot-0-0')));
      await tester.pumpAndSettle();
      expect(find.text('第 1 镜'), findsNothing, reason: '再点收起');
    });
  });
  group('草片流水线（双8分 Loop 第 1 轮）', () {
    testWidgets('「自动铺一版」照着参考片这一镜的画面找镜头，不是拿台词搜',
        (tester) async {
      final repo = _MemoryRepo();
      final cli = _DraftFakeCli();
      var doc = docWith(['再不买就恢复69.9一瓶了']);
      // 这一行有参考片，而且参考镜已经看懂了（画面描述 + 画面标签）
      doc = doc.setReferenceById(
          doc.lines.first.id,
          LineRef(startMs: 0, endMs: 3000, shotMeta: [
            RefShotMeta(
                startMs: 0,
                description: '一只手在厨房台面上举着喷雾瓶，背景虚化',
                tags: ['产品特写']),
          ]));
      await pumpDirector(
          tester,
          wrap(repo, scriptTask(doc: doc), overrides: [
            lineVoiceFactoryProvider
                .overrideWithValue((_) => _StubVoiceService()),
            shotSearchServicesProvider
                .overrideWithValue(_draftFakeServices(cli)),
          ]));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('director-draft')));
      await tester.pumpAndSettle();
      // 本片音色还没定过：先卡住让人选，别拿目录第一个撞运气配 27 句
      expect(find.byKey(const ValueKey('voice-option-'
          '${'zh_female_vv_uranus_bigtts'}')), findsWidgets,
          reason: '铺之前要先定本片音色，否则不对就白烧一轮 TTS');
      await tester.tap(find.text('就用这个'));
      await tester.pumpAndSettle();
      expect(find.textContaining('照着参考片'), findsOneWidget,
          reason: '要说清依据的是什么，不然人读不出这跟参考片有什么关系');
      await tester.tap(find.byKey(const ValueKey('draft-confirm')));
      await tester.pumpAndSettle();

      final search = cli.calls.firstWhere((a) => a.contains('search'));
      expect(search, containsAllInOrder(['--by', 'content']));
      expect(
          search.any((a) => a.contains('一只手在厨房台面上举着喷雾瓶')), isTrue,
          reason: '拿的是参考镜的画面描述');
      expect(search.any((a) => a.contains('再不买就恢复')), isFalse,
          reason: '台词是一句话、画面描述是一幅画，用台词搜画面是错配');

      final saved = await repo.findById('t1');
      expect(saved!.script!.lines.first.shots, isNotEmpty);
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pumpAndSettle();
    });

    testWidgets('手写脚本没有参考片：只配音、不铺镜头，并说清为什么',
        (tester) async {
      final repo = _MemoryRepo();
      final cli = _DraftFakeCli();
      await pumpDirector(
          tester,
          wrap(repo, scriptTask(doc: docWith(['第一句台词', '第二句台词'])),
              overrides: [
                lineVoiceFactoryProvider
                    .overrideWithValue((_) => _StubVoiceService()),
                shotSearchServicesProvider
                    .overrideWithValue(_draftFakeServices(cli)),
              ]));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('director-draft')));
      await tester.pumpAndSettle();
      // 同上：本片音色未定，先卡住选一次
      await tester.tap(find.text('就用这个'));
      await tester.pumpAndSettle();
      expect(find.textContaining('没有参考片可依据'), findsOneWidget,
          reason: '不铺就要说清为什么、下一步去哪儿做');
      await tester.tap(find.byKey(const ValueKey('draft-confirm')));
      await tester.pumpAndSettle();

      expect(cli.calls.where((a) => a.contains('search')), isEmpty,
          reason: '没有参考镜就不去素材库瞎捞——空着一眼看得出还没做');
      final saved = await repo.findById('t1');
      for (final line in saved!.script!.lines) {
        expect(line.voiceover, isNotNull, reason: '配音照配');
        expect(line.shots, isEmpty, reason: '镜头留给人自己挑');
      }
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pumpAndSettle();
    });

    testWidgets('素材偏短没充满：警告旁给「放慢充满」，一点缺口清零',
        (tester) async {
      final repo = _MemoryRepo();
      var doc = docWith(['台词']);
      doc = doc.setVoiceoverById(
          doc.lines.first.id,
          LineVoiceover(
              audioPath: '/vo.mp3',
              durationMs: 6000,
              sourceText: '台词',
              voiceId: 'v',
              speechRate: 0));
      doc = doc.setShotsById(doc.lines.first.id, [
        const LineShot(
            materialId: 9, name: 's', durationMs: 4000, allocMs: 4000),
      ]);
      await pumpDirector(tester, wrap(repo, scriptTask(doc: doc)));
      await tester.pumpAndSettle();

      expect(find.textContaining('没分出去'), findsOneWidget,
          reason: '4s 素材配 6s 配音，缺口要如实说');
      await tester.tap(find.byKey(const ValueKey('band-slowfill-0')));
      await tester.pump(const Duration(milliseconds: 900)); // 过 800ms 自动保存
      await tester.pumpAndSettle();

      final saved = await repo.findById('t1');
      final shot = saved!.script!.lines.first.shots.single;
      expect(shot.speed, lessThan(1.0), reason: '放慢吃掉缺口');
      expect(shot.allocMs, 6000);
      expect(find.textContaining('没分出去'), findsNothing);
    });

    testWidgets('行块标签可点开改：从词表选择器替换后落盘', (tester) async {
      final repo = _MemoryRepo();
      final cli = _DraftFakeCli();
      await pumpDirector(
          tester,
          wrap(repo, scriptTask(doc: docWith(['台词'])), overrides: [
            shotSearchServicesProvider
                .overrideWithValue(_draftFakeServices(cli)),
          ]));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('band-tags-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('促单'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('tag-picker-ok')));
      await tester.pump(const Duration(milliseconds: 900)); // 过自动保存
      await tester.pumpAndSettle();

      final saved = await repo.findById('t1');
      expect(saved!.script!.lines.first.tags, ['促单']);
    });

    testWidgets('⌘Z 撤销、⇧⌘Z 重做：删镜头一撤就回来', (tester) async {
      final repo = _MemoryRepo();
      var doc = docWith(['台词']);
      doc = doc.setShotsById(doc.lines.first.id, [
        const LineShot(
            materialId: 9, name: 's', durationMs: 8000, allocMs: 3000),
      ]);
      await pumpDirector(tester, wrap(repo, scriptTask(doc: doc)));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('band-remove-shot-0-0')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('band-shot-0-0')), findsNothing,
          reason: '镜头删掉了');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('band-shot-0-0')), findsOneWidget,
          reason: '⌘Z 把删掉的镜头撤回来');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('band-shot-0-0')), findsNothing,
          reason: '⇧⌘Z 重做刚才的删除');

      final saved = await repo.findById('t1');
      expect(saved!.script!.lines.first.shots, isEmpty,
          reason: '重做后的状态落盘');
    });

    testWidgets('换音色可一键应用到整片：句句换新声、旧配音标黄', (tester) async {
      final repo = _MemoryRepo();
      var doc = docWith(['第一句', '第二句', '第三句']);
      doc = doc.setVoiceId(0, 'zh_female_vv_uranus_bigtts');
      await pumpDirector(tester, wrap(repo, scriptTask(doc: doc)));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('band-voice-menu-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('更换音色'));
      await tester.pumpAndSettle();
      await tester.tap(find
          .byKey(ValueKey('voice-option-${VoiceCatalog.all.first.ref.id}')));
      await tester.tap(find.byKey(const ValueKey('voice-apply-all')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('就用这个'));
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pumpAndSettle();

      final saved = await repo.findById('t1');
      final doc2 = saved!.script!;
      // 「应用到整片」定的是**本片基调**，不是逐行写死：之后新加的行
      // 也跟着走，不会留在旧音色上
      expect(doc2.defaultVoiceId, VoiceCatalog.all.first.ref.id);
      expect(doc2.lines.every((l) => l.voiceId == null), isTrue,
          reason: '各行单独设过的一并清掉，全片才是真的统一');
      final ids = doc2.lines.map(doc2.voiceIdOf).toSet();
      expect(ids, {VoiceCatalog.all.first.ref.id},
          reason: '勾了「应用到整片」，三句有效音色一致');
    });

    testWidgets('改本片音色时，已经生成的那几句要被问一句——不问就会音色分裂',
        (tester) async {
      final repo = _MemoryRepo();
      var doc = docWith(['第一句', '第二句']);
      doc = doc.withDefaultVoiceId('zh_female_vv_uranus_bigtts');
      doc = doc.setVoiceoverById(
          doc.lines.first.id,
          LineVoiceover(
            audioPath: '/v/a.mp3',
            durationMs: 3000,
            sourceText: '第一句',
            voiceId: 'zh_female_vv_uranus_bigtts',
            speechRate: 0,
          ));
      await pumpDirector(tester, wrap(repo, scriptTask(doc: doc)));
      await tester.pumpAndSettle();

      // 从顶栏改本片基调
      await tester.tap(find.byKey(const Key('director-voice-baseline')));
      await tester.pumpAndSettle();
      final other = VoiceCatalog.all
          .firstWhere((v) => v.ref.id != 'zh_female_vv_uranus_bigtts');
      await tester.tap(find.byKey(ValueKey('voice-option-${other.ref.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('就用这个'));
      await tester.pumpAndSettle();

      // 已经生成的那一句现在是旧音色——必须问，不能默默留着
      expect(find.textContaining('还是旧音色'), findsOneWidget);
      expect(find.textContaining('前后会是两个人的声音'), findsOneWidget);
      expect(find.byKey(const Key('voice-unify-redo')), findsOneWidget);

      // 选「先留着」也要如实落盘基调
      await tester.tap(find.text('先留着'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pumpAndSettle();
      final saved = await repo.findById('t1');
      expect(saved!.script!.defaultVoiceId, other.ref.id);
    });

    testWidgets('平台原生修饰键加选两行 → 操作条出现，说清选了几行', (tester) async {
      final repo = _MemoryRepo();
      final doc = docWith(['一', '二', '三']);
      await pumpDirector(tester, wrap(repo, scriptTask(doc: doc)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('multi-voice')), findsNothing,
          reason: '只选一行时不该有操作条——那是「批量模式」的味道');

      final additiveKey = Platform.isWindows
          ? LogicalKeyboardKey.control
          : LogicalKeyboardKey.meta;
      await tester.sendKeyDownEvent(additiveKey);
      await tester.tap(find.byKey(ValueKey('band-${doc.lines[1].id}')));
      await tester.pumpAndSettle();
      await tester.sendKeyUpEvent(additiveKey);
      await tester.pumpAndSettle();

      expect(find.textContaining('已选 2 行'), findsOneWidget);
      expect(find.byKey(const Key('multi-voice')), findsOneWidget);
    });

    testWidgets('Shift 选一段：中间的行也在内', (tester) async {
      final repo = _MemoryRepo();
      final doc = docWith(['一', '二', '三', '四']);
      await pumpDirector(tester, wrap(repo, scriptTask(doc: doc)));
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
      await tester.tap(find.byKey(ValueKey('band-${doc.lines[2].id}')));
      await tester.pumpAndSettle();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
      await tester.pumpAndSettle();

      expect(find.textContaining('已选 3 行'), findsOneWidget,
          reason: '从当前行选到点的那一行，中间的都算上');
    });

    testWidgets('批量删除要说清删掉的是什么——已配好音的那几句', (tester) async {
      final repo = _MemoryRepo();
      var doc = docWith(['一', '二', '三']);
      doc = doc.setVoiceoverById(
          doc.lines.first.id,
          LineVoiceover(
            audioPath: '/v/a.mp3',
            durationMs: 3000,
            sourceText: '一',
            voiceId: 'v',
            speechRate: 0,
          ));
      await pumpDirector(tester, wrap(repo, scriptTask(doc: doc)));
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
      await tester.tap(find.byKey(ValueKey('band-${doc.lines[1].id}')));
      await tester.pumpAndSettle();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('multi-delete')));
      await tester.pumpAndSettle();
      expect(find.textContaining('1 句已经配好音'), findsOneWidget,
          reason: '只说「删除 2 行」等于没交代——配音删掉就真没了');

      await tester.tap(find.byKey(const Key('multi-delete-confirm')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pumpAndSettle();
      final saved = await repo.findById('t1');
      expect(saved!.script!.lines, hasLength(1));
      expect(saved.script!.lines.single.text, '三');
    });

    testWidgets('全部就绪时不再花钱，直接提示看草片', (tester) async {
      final repo = _MemoryRepo();
      var doc = docWith(['台词']);
      doc = doc.setVoiceoverById(
          doc.lines.first.id,
          LineVoiceover(
              audioPath: '/vo.mp3',
              durationMs: 3000,
              sourceText: '台词',
              voiceId: 'v',
              speechRate: 0));
      doc = doc.setShotsById(doc.lines.first.id,
          [const LineShot(materialId: 9, name: 's', durationMs: 8000, allocMs: 3000)]);
      await pumpDirector(
          tester,
          wrap(repo, scriptTask(doc: doc), overrides: [
            lineVoiceFactoryProvider
                .overrideWithValue((_) => _StubVoiceService()),
          ]));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('director-draft')));
      await tester.pumpAndSettle();
      expect(find.textContaining('直接按播放'), findsOneWidget);
    });
  });
}
