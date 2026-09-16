import 'dart:io';
import '../core/export/subtitle_coverage.dart';
import '../core/export/composed_timeline.dart';
import '../core/models/renew_task.dart';
import '../core/models/semantic_unit.dart';
import '../core/replacement/replacement_plan.dart';

/// 任务的 JSON 视图——**给事实，不给结论**。
///
/// 每段多长、台词是什么、打了哪些标签、哪些镜头挑过素材，都如实摆出来；
/// 「该挑哪个」是调用方的判断（见 spec 第一节：软件提供事实与保护，
/// skill 提供方法论）。
///
/// `analyzed` 与 `units: null` 是两件事：还没分析完就是 null，**不能拿空数组
/// 冒充**「分析完了但没有单元」——调用方据此决定是等着还是往下走。
Map<String, dynamic> taskToJson(RenewTask task) {
  final units = task.units;
  // 整体替换的单元在成片里有多长——跟挑中的那条素材走。素材时长不知道的
  // 那些记下来，下面整块不报
  final unknown = <int>[];
  final wholeDurations = <int, int>{};
  final plans = units == null ? null : task.replacementsFor(units);
  if (plans != null && units != null) {
    final durationOf = {
      for (final m in task.pickedMaterials)
        if (m.durationMs != null) m.id: m.durationMs!,
    };
    for (var i = 0; i < units.length && i < plans.length; i++) {
      if (plans[i].mode != ReplacementMode.whole) continue;
      final pick = plans[i].wholePreviewId ??
          (plans[i].wholeCandidateIds.isEmpty
              ? null
              : plans[i].wholeCandidateIds.first);
      // **一条候选都没选 ≠ 素材时长未知**：那只是「还没挑」，这一段照旧
      // 用它自己的长度，成片位置算得出来。混为一谈的话，只要有一个单元切到
      // 整体替换还没挑素材，整条片子的成片位置就全都不报了
      if (pick == null) continue;
      final ms = durationOf[pick];
      if (ms == null) {
        unknown.add(i);
      } else {
        wholeDurations[i] = ms;
      }
    }
  }
  final composed = (units == null || unknown.isNotEmpty)
      ? null
      : ComposedTimeline.of(units: units, wholeDurations: wholeDurations);
  final composedBlockedBy = unknown.isEmpty
      ? null
      : '这几个单元是整体替换，但还不知道选中素材有多长，'
          '所以整条片子的成片位置都算不准：'
          '${unknown.map((i) => 'U${i + 1}').join('、')}。'
          '先把素材下下来（candidates fetch），再来看 composedStartMs';

  return {
    'id': task.id,
    // 人对 Agent 说的是「#12」这种短编号；回传出去，Agent 复述时才对得上
    'seq': task.seq,
    'name': task.name,
    'status': task.status.name,
    // 这条任务属于哪条线。**ui new-task 给了，这里也要给**——
    // 不然事后想确认只能看 sourcePath 是不是 null 反推，
    // 或者故意跑 script show 看它报不报错
    'kind': task.script != null
        ? 'script'
        : (task.sourcePath == null ? 'blank' : 'replace'),
    'sourcePath': task.sourcePath,
    'durationMs': task.videoInfo?.duration.inMilliseconds,
    'fps': task.videoInfo?.fps,
    // 精确帧率：29.97 是 30000/1001，转成 double 之后它和 30 在很多运算里
    // 就分不开了（round(1000/fps) 对两者都是 33ms）。判等、拼指纹用这个
    'fpsExact': task.videoInfo?.fpsExact.toString(),
    'analyzed': units != null,
    // 分析出错时把原因带出来：调用方要能分辨「还在跑」和「跑挂了」
    'analysisError': task.analysisError,
    // 替换分镜放哪一路声音的**全片打底**（镜头可以各自覆盖，见 shots）
    'materialAudio': task.materialAudio.toJson(),
    // 「原片这一镜的声音」的全片打底。**存了就要报**：Agent 查到的空
    // 看起来正好像「没问题」
    'sourceAudio': task.sourceAudio.toJson(),
    // 分离轨在不在盘上。选「人声」「背景声」之前得能查到——查不到就只能
    // 先设上再撞导出拦截，那是一次白跑（报的是有没有，不是路径：
    // 路径对调用方没用，还会把一堆机器噪音塞进这份 JSON）
    'stems': {
      'vocals': _onDisk(task.vocalsPath),
      'background': _onDisk(task.backgroundPath),
    },
    // **成片位置**：界面上显示的是这一套，Agent 也得拿同一套——它据此判断
    // 「这一镜够不够铺满这句话」「前后连不连得上」，基准错了判断就跟着错。
    //
    // 算不准就**整块不报**并点名（见 composedUnavailable）：整体替换那一段
    // 长度跟素材走，素材时长不知道时报一个差不多的数，Agent 会当真数用。
    if (composed == null) 'composedUnavailable': composedBlockedBy,
    if (composed != null) 'composedDurationMs': composed.totalMs,
    'units': units == null
        ? null
        : [
            for (var i = 0; i < units.length; i++)
              _unitToJson(units[i], composed, i)
          ],
    // 替换现状（主流程唯一真相）：apply plans 投影进来、审核剔除也落这里。
    // Agent 提交后靠它验证生效、审核后靠它看剔了什么——没有这块就只能盲跑
    // 对外照旧按 U1/U2 的顺序列——人和 Agent 都按位置说话
    'replacements': plans == null
        ? null
        : [
            for (var i = 0; i < plans.length; i++)
              _replacementToJson(i, plans[i]),
          ],
    // 已选素材的时长。**取段靠它**：20 秒的素材塞进 0.5 秒的坑位，
    // 得先知道它是 20 秒才算得出要放 40 倍。
    // 不报出来的话，Agent 没法确认取段到底生没生效，只能盲猜
    'pickedMaterials': {
      'count': task.pickedMaterials.length,
      // **「没查过」和「这个版本没这功能」长得一模一样**——都是键不存在。
      // 给个汇总才分得开：拿到一份没有 burnedText 的输出时，
      // 到底该不该信任它「画面干净」
      'frameChecked':
          task.pickedMaterials.where((m) => m.burnedTextChecked).length,
      'frameUnchecked':
          task.pickedMaterials.where((m) => !m.burnedTextChecked).length,
      'withDuration':
          task.pickedMaterials.where((m) => (m.durationMs ?? 0) > 0).length,
      'items': [
        for (final m in task.pickedMaterials)
          {
            'id': m.id,
            'name': m.name,
            // 这条素材原本在说什么 / 画面拍的是什么。Agent 要判断
            // 「这一条到底合不合适」，光有 id 和名字判不出来
            if (m.voiceover.isNotEmpty) 'voiceover': m.voiceover,
            if (m.sceneDescription.isNotEmpty)
              'sceneDescription': m.sceneDescription,
            'durationMs': m.durationMs,
            // 画面上烧着的字。**没查过时整个键不出现**——空数组会被读成
            // 「画面干净」，而那正是把一条会毁掉整片的素材静默放行
            if (m.burnedText != null) 'burnedText': m.burnedText,
            // 画面里露出的产品是谁家的。产品露出镜头不能跨品牌换
            if (m.productBrand != null) 'productBrand': m.productBrand,
            // 上面两条是看了几帧得出的。1 帧看不全产品露出，
            // 3 帧才算看全——Agent 据此判断这个结论有多硬
            if (m.framesSeen != null) 'framesSeen': m.framesSeen,
          },
      ],
    },
    // 成片里哪几段会有台词字幕。**两种替换模式在这件事上不一样**，
    // 而这个差别此前在界面上和命令行里都看不见：镜头替换会把字幕重渲上去，
    // 整体替换原样接上、和原坑位对不齐，那一段就没有台词字幕
    if (plans case final r? when r.isNotEmpty)
      'subtitleCoverage': {
        'unitsWith': subtitleCoverage(r).unitsWith,
        'unitsWithout': subtitleCoverage(r).unitsWithout,
        'note': ?subtitleGapNotice(r),
      },
    'exports': [
      for (final e in task.exports)
        {
          'at': e.at.toIso8601String(),
          'total': e.total,
          'succeeded': e.succeeded,
          'outputDir': e.outputDir,
        },
    ],
  };
}

Map<String, dynamic> _unitToJson(
        SemanticUnit unit, ComposedTimeline? composed, int at) =>
    {
      'index': unit.index,
      // **原片位置**。老名字留着（已有调用方还在用），同时给一份把基准写在
      // 名字里的——两个基准混着用正是 2026-09-08 那个「属性栏写 00:45.03、
      // 时间线画在 01:03」的来源
      'startMs': unit.startMs,
      'endMs': unit.endMs,
      'durationMs': unit.endMs - unit.startMs,
      'sourceStartMs': unit.startMs,
      'sourceEndMs': unit.endMs,
      // **成片位置**：列表顺序就是成片顺序，前面的长度一变这里全跟着挪
      if (composed != null) 'composedStartMs': composed.startOf(at),
      if (composed != null) 'composedDurationMs': composed.durationOf(at),
      'transcript': unit.transcript,
      // 原片上有没有这一段。**false = 用户手动加的**：它没有台词（模型无从
      // 打标，标签只能手填），也没有原片画面可放（不挑素材就导不出来）。
      // 不报的话你会以为它和别的单元一样，照着一个错的前提往下干
      'hasSource': unit.hasSource,
      // **这一段的底片被固定成哪条素材**（见 `unit segment`）。非空表示
      // 下面那些镜头是按它切出来的，画面取自它而不是原片——不报的话你会
      // 拿原片的时间线去理解这一段，而它早就不是原片了；也不知道这一段
      // 已经切过、每一镜都能单独挑素材
      if (unit.baseCandidateId != null)
        'baseCandidateId': unit.baseCandidateId,
      // 底片素材自己的转写转出来几句。**字幕从这一份取**（原片那份量的是
      // 原片、跟这段画面对不上）。不报的话你会以为字幕是从原片台词来的，
      // 也不知道这一段转没转成
      if (unit.baseSentences != null)
        'baseSentenceCount': unit.baseSentences!.length,
      'tags': unit.tags,
      // 人手改过的标签：重新打标会跳过它。不报的话你会以为打标漏了这个单元，
      // 跑一遍发现它纹丝不动，也不知道为什么
      if (unit.tagsHandpicked) 'tagsHandpicked': true,
      'shots': [
        for (var i = 0; i < unit.shots.length; i++)
          {
            'index': i,
            'startMs': unit.shots[i].startMs,
            'endMs': unit.shots[i].endMs,
            'durationMs': unit.shots[i].endMs - unit.shots[i].startMs,
            // 取自哪个文件的哪一段。底片固定过的单元，这两个数是**素材内的
            // 偏移**（镜头坐标减掉单元起点），不是原片位置——照原片去对
            // 会对到一段毫不相干的画面
            'sourceStartMs': unit.baseCandidateId == null
                ? unit.shots[i].startMs
                : unit.shots[i].startMs - unit.startMs,
            'sourceEndMs': unit.baseCandidateId == null
                ? unit.shots[i].endMs
                : unit.shots[i].endMs - unit.startMs,
            // 整体替换的单元这里是 null：那一段整个换成了另一条素材，
            // 原片的镜头切分在成片里已经不存在，编一个数出来是假精度
            'composedStartMs': ?composed?.composedShotStart(at, i),
            'composedEndMs': ?composed?.composedShotEnd(at, i),
            'description': unit.shots[i].description,
            // 这一镜露的是谁家产品——**「本片是什么品牌」的唯一可靠来源**。
            // 判断候选对不对得上本片，参照只能从这里来
            if (unit.shots[i].productBrand != null)
              'productBrand': unit.shots[i].productBrand,
            'tags': unit.shots[i].tags,
            if (unit.shots[i].tagsHandpicked) 'tagsHandpicked': true,
            // 这一镜单独设过「放素材的哪一路声音」。**不设就不报这两个字段**
            // ——「跟随全片」和「明确设成某一档」要分得开
            if (unit.shots[i].materialAudioMode != null)
              'materialAudioMode': unit.shots[i].materialAudioMode!.name,
            if (unit.shots[i].materialAudioVolume != null)
              'materialAudioVolume': unit.shots[i].materialAudioVolume,
            if (unit.shots[i].sourceAudioMode != null)
              'sourceAudioMode': unit.shots[i].sourceAudioMode!.name,
            if (unit.shots[i].sourceAudioVolume != null)
              'sourceAudioVolume': unit.shots[i].sourceAudioVolume,
          },
      ],
    };

Map<String, dynamic> _replacementToJson(int index, UnitReplacement r) => {
      'unit': index,
      'mode': r.mode.name,
      if (r.mode == ReplacementMode.whole) 'materials': r.wholeCandidateIds,
      if (r.mode == ReplacementMode.perShot)
        'shots': {
          for (final e in r.shotCandidateIds.entries) '${e.key}': e.value,
        },
    };

/// 这条分离轨在不在盘上。存了路径不等于文件还在——任务被清理过、
/// 换过机器都可能只剩一条记录
bool _onDisk(String? path) => path != null && File(path).existsSync();
