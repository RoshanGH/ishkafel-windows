import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **底片切出来的镜头是一等公民**，和原片切出来的一样齐全。
///
/// 产品负责人的原话：「正常的参考视频的台词语义单元里面的 S1、S2、S3
/// 要干嘛，你这边也是要干嘛的，都要走一遍。」
///
/// 这条守卫盯的是**两条路容易只补一边**：全片分析那条线加了什么，底片切分
/// 这条线也得有。它查不了语义，只能把「必须成对出现」的几件事钉住，
/// 加新东西时逼人回来看一眼这份清单。
void main() {
  String read(String path) {
    final f = File(path);
    expect(f.existsSync(), isTrue, reason: '$path 挪了位置就把这条守卫一起改');
    return f.readAsStringSync();
  }

  test('切点的判定依据：两条路都要贴到镜头上', () {
    // 全片：AnalysisPipeline._withBoundaryTrace
    expect(read('lib/core/analysis/analysis_pipeline.dart'),
        contains('BoundaryTrace('));
    // 底片：UnitSegmenter._withBoundaryTrace
    expect(read('lib/core/analysis/unit_segmenter.dart'),
        contains('BoundaryTrace('),
        reason: '不贴的话，同样是一刀，原片切的能回看依据、底片切的点开是空的');
  });

  test('打标：切完底片要接着打，不能让人拿着没标签的镜头去搜素材', () {
    final page = read('lib/features/workbench/workbench_page.dart');

    // 切分那条路走完要接上打标
    expect(page, contains('_retagBaseUnit'),
        reason: '底片镜头不打标，按画面/标签搜素材一条都搜不出来');
    final segmentAt = page.indexOf('Future<void> _segmentUnitBase');
    expect(segmentAt, greaterThan(-1));
    final segmentBody = page.substring(
        segmentAt, page.indexOf('Future<void> _unpinUnitBase'));
    expect(segmentBody, contains('_retagBaseUnit('),
        reason: '切分流程里要接着打标——原片那条线是分析时顺带打好的');
  });

  test('打标要认底片：抽帧不能跑去原片同一个时间点', () {
    expect(read('lib/core/analysis/tagging_service.dart'),
        contains('baseVideoPaths'),
        reason: '不认底片的话抽到的是另一段画面，标签张冠李戴而哪儿都不报错');
  });

  test('花钱的动作点之前要说清楚', () {
    final dialog = read('lib/features/workbench/base_pin_dialogs.dart');

    expect(dialog, contains('打标'), reason: '确认框要说这一下还会打标');
    expect(dialog, contains('花钱'), reason: '要花钱必须写出来');
  });

  test('字幕：底片素材要自己转写一遍，词级时间戳只能从这儿来', () {
    // 产品负责人在「按时长摊字数」和「真转写」之间选了后者：
    // 这条产品线的字幕是要交付的，摊出来的时间点在成片里一看就飘
    expect(read('lib/core/analysis/base_transcriber.dart'),
        contains('transcribe'));
    expect(read('lib/features/workbench/workbench_page.dart'),
        contains('baseTranscriberProvider'),
        reason: '切分那条路要顺手把这条素材转写一遍');
    expect(read('lib/core/models/semantic_unit.dart'),
        contains('baseSentences'),
        reason: '转写结果要记在单元上，字幕从它取');
    for (final caller in _subtitleCallers()) {
      expect(read(caller), contains('baseSentences'),
          reason: '$caller 没用底片自己的转写，字幕就还是空的（或是原片那句）');
    }
  });

  test('字幕：底片是素材时不拿原片那份 ASR 硬凑', () {
    // 时间戳量的是原片，画面却换成了另一条片子——取出来的台词跟画面
    // 毫不相干，而它会被结结实实烧进成片
    expect(read('lib/core/subtitle/slot_subtitles.dart'),
        contains('onMaterialBase'),
        reason: '这是全 app 唯一说了算的地方，判据要在这儿');

    final callers = _subtitleCallers();
    expect(callers, hasLength(greaterThanOrEqualTo(3)),
        reason: '至少有预览、导出、时间线三处在取字幕；扫不到说明扫描写错了');

    for (final caller in callers) {
      expect(read(caller), contains('onMaterialBase:'),
          reason: '$caller 没把底片这件事告诉 subtitleLinesForSlot，'
              '预览、导出、时间线就会各看到一份不一样的字幕');
    }
  });

  test('「整段替换」和「固定了底片」是两回事，别拿 isReplaced 当一块判', () {
    // 固定过底片的单元 isReplaced 也为真（画面确实不是原片了），但它有
    // 自己的镜头切分，每一镜都能单独换素材。拿 isReplaced 去跳过整段，
    // 预览画面上一个字都不出，而时间线的字幕轨照画——「轨上有、画面上没有」
    final preview = read('lib/core/subtitle/preview_subtitle_at.dart');

    expect(preview, contains('isSolidBlock'),
        reason: '要跳过的是「一整块」的那种，不是所有画面换过的');
    expect(preview.contains('timeline.isReplaced('), isFalse,
        reason: '这个判据会把底片单元整个吞掉');
  });

  test('声音：底片是素材时分的是那条素材，不是原片', () {
    final audio = read('lib/core/audio/audio_track_builder.dart');

    expect(audio, contains('separateMaterialStems'),
        reason: '选了人声/背景声那两档，要分的是这一段的底片');
    // 前置检查不该拿原片的分离轨去判底片单元——原片有就放行、没有就叫人
    // 「去重新分离原片」，两种都不对
    expect(read('lib/core/export/export_runner.dart'),
        contains('units[u].baseCandidateId != null'),
        reason: '门口那道检查要把固定过底片的单元排除掉');
  });

  test('审核页的「本来的样子」要读底片，不是原片同一个时间点', () {
    final review = read('lib/features/review/review_page.dart');

    expect(review, contains('originCandidateId'),
        reason: '这张卡是拿来跟候选比对的参照物。读错文件，人就是照着'
            '一段毫不相干的画面在做取舍');
    expect(review, contains('hasOwnBaseShots'),
        reason: '判据要走那一份，别在这儿自己拼');
  });

  test('Agent 看得见底片——看不见的能力等于不存在', () {
    expect(read('lib/cli/task_view.dart'), contains('baseCandidateId'),
        reason: '存了却不报，Agent 会拿原片的时间线去理解这一段，'
            '也不知道它已经切过、每一镜都能单独挑素材');
  });

  test('命令行那条导出路不许自己抄一份组段落的逻辑', () {
    // plan_submission 里有第二份「把方案摊成段落」——它一度不带底片，
    // 于是 Agent 导出来的片子：拼片任务直接判成「还没挑素材」导不出去，
    // 能导的也没有字幕（2026-09-15 端到端导一条才发现）
    final cli = read('lib/cli/plan_submission.dart');

    expect(cli, contains('unitBaseCandidateId'),
        reason: '字幕要靠它——换过素材的那一镜替代的正是底片的那一段');
    expect(cli, contains('hasOwnBaseShots'),
        reason: '固定过底片的单元照旧逐镜产段，规则和 ExportPlanner 同源');
  });

  test('空白任务的「还没挑素材」不许把底片那几镜算进去', () {
    expect(read('lib/core/export/export_runner.dart'),
        contains('segment.isOriginal && segment.baseCandidateId == null'),
        reason: '它们没挑替换素材，但画面取自底片，不是「没东西可放」');
  });

  test('两条切分路做的事必须一样多——界面切完打标，命令行也得打', () {
    // 少一步，Agent 切出来的镜头就没有标签也没有画面描述，
    // `candidates --shot` 按标签/画面一条都搜不出来，而它会以为
    // 素材库里真的没有（2026-09-15 核查 Agent 侧时发现）
    final cli = read('lib/cli/commands/unit_command.dart');

    expect(cli, contains('BaseTranscriber'), reason: '命令行也要转写');
    expect(cli, contains('tagging.tag('), reason: '命令行也要打标');
    expect(cli, contains('baseVideoPaths'),
        reason: '打标抽帧要从底片上抽，不是原片同一个时间点');
  });

  test('Agent 看得见「切了但还没打标」——不然它会以为素材库里没东西', () {
    expect(read('lib/cli/commands/unit_command.dart'),
        contains('shotsTagged'));
    expect(read('docs/AGENT_SKILL.md'), contains('shotsTagged'));
  });
}
/// 全仓扫一遍：谁在调 [subtitleLinesForSlot]，谁就在这份名单上。
///
/// 这里原先是手写的两个路径，结果时间线那处（`_subtitleLinesOf`）在名单外
/// 躺了一整轮——界面上的字幕块按原片时间戳画，位置和镜头轨对不上，而守卫
/// 全绿（2026-09-16 真机）。所以改成扫描：**新增第四个调用点会自动被管到**，
/// 不用记得回来改名单。
List<String> _subtitleCallers() {
  final out = <String>[];
  for (final e in Directory('lib').listSync(recursive: true)) {
    if (e is! File || !e.path.endsWith('.dart')) continue;
    // 定义它的那个文件本身不算调用方
    if (e.path.endsWith('slot_subtitles.dart')) continue;
    if (e.readAsStringSync().contains('subtitleLinesForSlot(')) {
      out.add(e.path);
    }
  }
  out.sort();
  return out;
}
