import 'dart:io';

import '../core/ai/frame_check.dart';
import '../core/export/export_plan.dart';
import '../core/replacement/candidate_trim.dart';
import '../core/models/renew_task.dart';
import '../core/models/semantic_unit.dart';
import '../core/replacement/picked_material.dart';
import '../core/miaoa/miaoa_content_service.dart';
import '../core/replacement/replacement_plan.dart';
import '../core/replacement/unit_base.dart';

/// Agent 提交的一条**完整方案**：每个单元用什么，一次说清。
///
/// 为什么不是「每个位置挑几个候选，再做笛卡尔积」：产品要求是**产出的每一条
/// 都能用**，而笛卡尔积隐含「每个位置的每个候选都独立可用、任意搭配都成立」
/// ——这恰恰是「挑的时候要看前后是否顺畅」所否定的前提（spec 第四节）。
///
/// 一条方案是调用方整体设计过的，所以每一条都能用。
class SubmittedPlan {
  /// 给人看的名字，会出现在导出文件名里
  final String name;

  /// 单元下标 → 这个单元怎么处理
  final Map<int, PlanUnit> units;

  const SubmittedPlan({required this.name, required this.units});
}

/// 一个单元在某条方案里的处理方式
class PlanUnit {
  /// `keepOriginal` / `whole` / `perShot`
  final String mode;

  /// 整体替换用的候选 id
  final int? material;

  /// 镜头下标 → 候选 id
  final Map<int, int> shots;

  /// 镜头下标 → 从素材第几毫秒起用。不给就从 0 起，整条变速铺满坑位。
  ///
  /// 只用来跳过素材开头的转场/黑帧；跳过之后剩下的照旧整条铺满坑位，
  /// 不会只取坑位那么长
  final Map<int, int> trimStarts;

  const PlanUnit({
    required this.mode,
    this.material,
    this.shots = const {},
    this.trimStarts = const {},
  });
}

/// 校验结果。[errors] 非空即为不通过
class PlanValidation {
  final List<SubmittedPlan> plans;
  final List<String> errors;

  const PlanValidation({this.plans = const [], this.errors = const []});

  bool get ok => errors.isEmpty;
}

/// 解析并校验 Agent 提交的方案。
///
/// **外包出去的是「判断」，不是「数据结构的定义权」**（spec 第三节）。
/// 调用方可以说「这个镜头用 116719」，但不能凭空造一个不存在的单元下标、
/// 不能引用没检索到的素材、也不能给一个模式却不给对应的取值。
///
/// 不合格就**整批拒绝**并一次点全所有问题——让它改一个提交一次是在浪费
/// 双方的时间。
PlanValidation parsePlans(Object? raw, RenewTask task) {
  final units = task.units;
  if (units == null) {
    return const PlanValidation(errors: ['这个任务还没分析完，没有单元可编排']);
  }
  if (raw is! Map) return const PlanValidation(errors: ['提交的内容不是一个 JSON 对象']);
  final list = raw['plans'];
  if (list is! List || list.isEmpty) {
    return const PlanValidation(errors: ['plans 必须是一个非空数组']);
  }

  final errors = <String>[];
  final plans = <SubmittedPlan>[];
  final names = <String>{};

  for (var i = 0; i < list.length; i++) {
    final where = '第 ${i + 1} 条方案';
    final item = list[i];
    if (item is! Map) {
      errors.add('$where 不是一个对象');
      continue;
    }
    final name = '${item['name'] ?? ''}'.trim();
    if (name.isEmpty) {
      errors.add('$where 缺少 name——它会出现在导出文件名里');
      continue;
    }
    if (!names.add(name)) {
      // 重名会让导出文件互相覆盖，事后根本分不清哪条是哪条
      errors.add('$where 的名字「$name」和前面重复了');
    }

    final rawUnits = item['units'];
    if (rawUnits is! List || rawUnits.isEmpty) {
      errors.add('$where 的 units 必须是一个非空数组');
      continue;
    }

    final parsed = <int, PlanUnit>{};
    for (final u in rawUnits) {
      final problem = _parseUnit(u, units, parsed, where);
      if (problem != null) errors.add(problem);
    }
    // 同一条素材不能在一条成片里出现两次——同一个画面重复出现，一眼就能
    // 看出来。GUI 在挑的那一刻就拦；这里是 Agent 提交整条方案的对应关口
    final seen = <int, String>{};
    for (final e in parsed.entries) {
      final positions = <(int?, String)>[
        (e.value.material, 'U${e.key + 1}'),
        for (final shot in e.value.shots.entries)
          (shot.value, 'U${e.key + 1} 的 S${shot.key + 1}'),
      ];
      for (final (id, place) in positions) {
        if (id == null) continue;
        final before = seen[id];
        if (before != null) {
          errors.add('$where 里素材 $id 用了两次（$before 和 $place）'
              '——同一条素材不能在一条成片里出现两次');
        } else {
          seen[id] = place;
        }
      }
    }
    plans.add(SubmittedPlan(name: name, units: parsed));
  }

  // 同一个单元在不同方案里必须用同一种模式：whole 与 perShot 并存的话，
  // 投影到任务（审核页据以呈现）时两种粒度没法摆在同一个位置上
  final modeOf = <int, String>{};
  for (final plan in plans) {
    for (final entry in plan.units.entries) {
      final mode = entry.value.mode;
      if (mode == 'keepOriginal') continue;
      final seen = modeOf[entry.key];
      if (seen != null && seen != mode) {
        errors.add('U${entry.key + 1} 在不同方案里既有整体替换又有镜头替换——'
            '同一个单元请统一用一种方式');
      }
      modeOf[entry.key] = mode;
    }
  }

  return errors.isEmpty
      ? PlanValidation(plans: plans)
      : PlanValidation(errors: errors);
}

String? _parseUnit(
  Object? raw,
  List<SemanticUnit> units,
  Map<int, PlanUnit> into,
  String where,
) {
  if (raw is! Map) return '$where 里有一项不是对象';
  final index = raw['unit'];
  if (index is! int || index < 0 || index >= units.length) {
    return '$where 引用了不存在的单元 $index（共 ${units.length} 个）';
  }
  if (into.containsKey(index)) {
    return '$where 给 U${index + 1} 指定了两次';
  }

  final mode = '${raw['mode'] ?? ''}';
  switch (mode) {
    case 'keepOriginal':
      into[index] = const PlanUnit(mode: 'keepOriginal');
      return null;

    case 'whole':
      final material = raw['material'];
      if (material is! int) {
        return '$where 的 U${index + 1} 是整体替换，但没给 material';
      }
      into[index] = PlanUnit(mode: 'whole', material: material);
      return null;

    case 'perShot':
      final shots = raw['shots'];
      if (shots is! Map || shots.isEmpty) {
        return '$where 的 U${index + 1} 是镜头替换，但没给 shots';
      }
      final total = units[index].shots.length;
      final picked = <int, int>{};
      for (final entry in shots.entries) {
        final shotIndex = int.tryParse('${entry.key}');
        if (shotIndex == null || shotIndex < 0 || shotIndex >= total) {
          return '$where 的 U${index + 1} 引用了不存在的镜头 ${entry.key}'
              '（共 $total 个）';
        }
        if (entry.value is! int) {
          return '$where 的 U${index + 1}/S${shotIndex + 1} 的素材 id 不是整数';
        }
        picked[shotIndex] = entry.value as int;
      }
      // 可选：这一镜从素材的哪儿开始用（跳过开头的转场/黑帧）。
      // 不给就从头用
      final trims = <int, int>{};
      if (raw['trimStarts'] case final Map raw?) {
        for (final entry in raw.entries) {
          final shotIndex = int.tryParse('${entry.key}');
          if (shotIndex == null || !picked.containsKey(shotIndex)) {
            return '$where 的 U${index + 1} 的 trimStarts 指到了没换素材的'
                '镜头 ${entry.key}——只有换了素材的镜头才谈得上从哪儿截';
          }
          if (entry.value is! int || (entry.value as int) < 0) {
            return '$where 的 U${index + 1}/S${shotIndex + 1} 的 trimStarts '
                '不是非负整数（毫秒）';
          }
          trims[shotIndex] = entry.value as int;
        }
      }
      into[index] =
          PlanUnit(mode: 'perShot', shots: picked, trimStarts: trims);
      return null;

    default:
      return '$where 的 U${index + 1} 的 mode 只能是 '
          'keepOriginal / whole / perShot，收到的是「$mode」';
  }
}

/// 把一条方案翻译成导出用的组合。
///
/// 没在方案里提到的单元一律**保留原片**——不猜、不补默认值：调用方没说的
/// 事，我们不替它决定。
ExportCombination toCombination(SubmittedPlan plan, List<SemanticUnit> units,
    {required int index,

    /// 候选素材各有多长。**镜头层的倍速要靠它**——整条素材铺满坑位，
    /// 长多少倍就放多快
    Map<int, int> materialDurations = const {}}) {
  final segments = <ExportSegment>[];
  for (final unit in units) {
    final chosen = plan.units[unit.index];
    if (chosen == null || chosen.mode == 'keepOriginal') {
      segments.add(ExportSegment(
        unitIndex: unit.index,
        unitUid: unit.uid,
        startMs: unit.startMs,
        endMs: unit.endMs,
      ));
      continue;
    }
    // 底片固定过的单元：整段替换这一档已经由底片接管，照旧逐镜产段
    // （规则与 `ExportPlanner._segmentsFor` 同源，见 [hasOwnBaseShots]）
    if (chosen.mode == 'whole' && !hasOwnBaseShots(unit)) {
      segments.add(ExportSegment(
        unitIndex: unit.index,
        unitUid: unit.uid,
        startMs: unit.startMs,
        endMs: unit.endMs,
        candidateId: chosen.material,
      ));
      continue;
    }
    for (var s = 0; s < unit.shots.length; s++) {
      final shot = unit.shots[s];
      final id = chosen.shots[s];
      final materialMs = id == null ? 0 : (materialDurations[id] ?? 0);
      final cut = trimFor(
        materialMs: materialMs,
        slotMs: shot.endMs - shot.startMs,
        startMs: chosen.trimStarts[s],
      );
      segments.add(ExportSegment(
        unitIndex: unit.index,
        unitUid: unit.uid,
        shotIndex: s,
        startMs: shot.startMs,
        endMs: shot.endMs,
        candidateId: id,
        trimStartMs: materialMs > 0 && cut.startMs > 0 ? cut.startMs : null,
        // **没换素材的那一镜从这个单元的底片上剪**。不带这两项，导出会
        // 跑去原片同一个时间点剪（拼片任务干脆判成「还没挑素材」导不出去）
        baseCandidateId: id == null ? unit.baseCandidateId : null,
        // 单元级的那份字幕要用：换过素材的这一镜替代的正是底片的这一段
        unitBaseCandidateId: unit.baseCandidateId,
        baseStartMs: unit.baseCandidateId == null
            ? null
            : shot.startMs - unit.startMs,
      ));
    }
  }
  // 方案名带下去——它就是成片的文件名（手册一直是这么承诺的）
  return ExportCombination(
      index: index, segments: segments, name: plan.name);
}

/// 把提交的方案**投影**成任务的替换现状（主流程的唯一真相）。
///
/// 这一步是「人审核 → Agent 导出」能接通的关键：审核页读的是
/// `task.replacements`，投影落进去之后 `ishkafel review` 才有东西可审；
/// 人剔除后再导出，由 [plansBlockedByReview] 对照现状拦截。
///
/// 投影是**整体覆盖**：方案是完整设计（没提到的单元 = 保留原片），
/// 半新半旧的合并只会造出谁也没提交过的状态。
List<UnitReplacement> projectPlansToReplacements(
    List<SubmittedPlan> plans, List<SemanticUnit> units) {
  return [
    for (final unit in units)
      () {
        final whole = <int>[];
        final byShot = <int, List<int>>{};
        for (final plan in plans) {
          final chosen = plan.units[unit.index];
          if (chosen == null || chosen.mode == 'keepOriginal') continue;
          if (chosen.mode == 'whole') {
            if (!whole.contains(chosen.material)) whole.add(chosen.material!);
          } else {
            for (final e in chosen.shots.entries) {
              final list = byShot[e.key] ??= [];
              if (!list.contains(e.value)) list.add(e.value);
            }
          }
        }
        if (whole.isNotEmpty) {
          return UnitReplacement.whole(whole, previewId: whole.first);
        }
        if (byShot.isNotEmpty) {
          return UnitReplacement.perShot(byShot, previewIds: {
            for (final e in byShot.entries) e.key: e.value.first,
          });
        }
        return UnitReplacement.keepOriginal();
      }(),
  ];
}

/// 对照任务的替换现状（审核后的唯一真相）校验方案：方案里用到、但已不在
/// 现状里的素材，就是**人在审核里剔掉的**——那条方案必须拦下点名，
/// 静默导出被剔除的素材是成片才能发现的错。
///
/// [replacements] 为空表示这个任务从没进过审核/选材流程，不拦。
List<String> plansBlockedByReview(
    List<SubmittedPlan> plans, List<UnitReplacement>? replacements) {
  if (replacements == null || replacements.isEmpty) return const [];
  final problems = <String>[];
  for (final plan in plans) {
    for (final entry in plan.units.entries) {
      final unitIndex = entry.key;
      final chosen = entry.value;
      final current = unitIndex < replacements.length
          ? replacements[unitIndex]
          : UnitReplacement.keepOriginal();
      if (chosen.mode == 'whole') {
        if (!current.wholeCandidateIds.contains(chosen.material)) {
          problems.add('「${plan.name}」U${unitIndex + 1} 用的素材 '
              '${chosen.material} 已在审核中被剔除，请换素材后重新提交方案');
        }
      } else if (chosen.mode == 'perShot') {
        for (final shot in chosen.shots.entries) {
          final allowed = current.shotCandidateIds[shot.key] ?? const [];
          if (!allowed.contains(shot.value)) {
            problems.add('「${plan.name}」U${unitIndex + 1}/S${shot.key + 1} '
                '用的素材 ${shot.value} 已在审核中被剔除，请换素材后重新提交方案');
          }
        }
      }
    }
  }
  return problems;
}

/// 把方案里用到的素材连同**时长**一起收下来。
///
/// **倍速全靠这个数**：20 秒的素材塞进 0.5 秒的坑位，得先知道它是 20 秒，
/// 才知道要放 40 倍。而这个数只存在 `task.pickedMaterials` 里——界面挑素材
/// 时会写，Agent 提交方案时一直不写，于是 Agent 交出来的方案算不出倍速，
/// 导进剪映时那几段会被切掉超出坑位的部分。
///
/// 同时对每条素材做一次**画面自查**（[checkFrame]）：烧没烧字、露的是谁家
/// 产品。两样都是只有看图才知道、而且能毁掉整片的事，素材库给的画面描述里
/// 一个字都看不出来。界面挑素材时会看（`PickedMaterialStore`），Agent 这条
/// 路上不看就只做了一半——而 Agent 恰恰是那个一口气挑几十条、人来不及
/// 一张张看图的角色。
///
/// 已经存过的不重量：一条素材量一次就够，逐条 ffprobe 是要时间的。
Future<List<PickedMaterial>> collectPickedMaterials({
  required Set<int> candidateIds,
  required List<PickedMaterial> known,
  required Future<CandidateMaterial?> Function(int id) fetch,
  required Future<int> Function(int id) probeDurationMs,
  Future<FrameCheck> Function(int id)? checkFrame,
}) async {
  final byId = {for (final m in known) m.id: m};
  final out = <PickedMaterial>[];
  for (final id in candidateIds) {
    final hit = byId[id];
    if (hit != null && hit.durationMs != null) {
      // 时长齐了但画面还没看全：补看一次。「时长齐了」不代表这条素材
      // 没问题——两件事各查各的
      out.add(await _checked(hit, checkFrame));
      continue;
    }
    // **时长比名字要紧**：取段只认时长，名字和描述是给人看的。
    // 名字取不到（网断、地址过期）不该连时长一起丢——丢了取段就退回快进
    final material = await fetch(id);
    final ms = await probeDurationMs(id);
    // 两样都没有才真的没什么可留：留一条空记录只会让人以为它是好的
    if (material == null && ms <= 0) continue;
    out.add(await _checked(
      PickedMaterial(
        id: id,
        name: material?.name ?? '素材 $id',
        voiceover: material?.voiceover ?? '',
        sceneDescription: material?.sceneDescription ?? '',
        thumbPath: hit?.thumbPath,
        // 量不到就留空。存个 0 进去，取段会以为它是 0 秒——那比没有更糟
        durationMs: ms > 0 ? ms : null,
        burnedText: hit?.burnedText,
        productBrand: hit?.productBrand,
        framesSeen: hit?.framesSeen,
      ),
      checkFrame,
    ));
  }
  return List.unmodifiable(out);
}

/// 看一眼画面（烧字 + 产品露出品牌）。已经看过的不重看；没接检查器或看不成
/// 时保持「没查过」——**绝不冒充「画面没问题」**，那等于把一条会毁掉整片的
/// 素材静默放行。
Future<PickedMaterial> _checked(
    PickedMaterial m, Future<FrameCheck> Function(int id)? check) async {
  // 看过一帧不算看全：界面挑素材那一刻只有首帧图，一帧会漏报产品露出。
  // 这里素材已经在本地、能抽头中尾三帧，正是补看的时机
  if (check == null || m.frameCheckComplete) return m;
  try {
    return m.withFrameCheck(await check(m.id));
  } catch (e) {
    stderr.writeln('素材 ${m.id} 的画面没看成（$e）——'
        '这条会标成「未检查」，不会当成画面没问题');
    return m;
  }
}

/// 有素材画面上烧着字时，**点名是哪几条、烧的是什么**。都干净或都没查过时
/// 返回 null。笼统一句「有素材有问题」等于让人自己去一条条翻，那还不如不说。
String? burnedTextNotice(List<PickedMaterial> picked) {
  final bad = [
    for (final m in picked)
      if (m.hasBurnedText) '素材 ${m.id}：${m.burnedText!.join('、')}',
  ];
  if (bad.isEmpty) return null;
  return '有 ${bad.length} 条素材画面上本来就烧着字。'
      '换上它之后还要再烧一行台词字幕，成片会出现两层字——建议换掉：\n'
      '${bad.join('\n')}';
}

/// 有素材量不到时长时，说清后果。全都量到、或压根没有短坑位时返回 null。
///
/// **不静默降级**：视觉镜头替换靠素材时长算倍速（整条铺满坑位）。量不到
/// 的那几条，剪映工程里只能按 1.0 倍摆进去、超出坑位的部分被切掉——
/// 画面缺一截，而且哪儿都不报错。这是影响成片的降级，不能等人拿到片子
/// 才发现。
String? trimUnavailableNotice({
  required int total,
  required int withDuration,
  required int shortSlots,
}) {
  final missing = total - withDuration;
  if (missing <= 0 || shortSlots <= 0) return null;
  return '有 $missing 条素材量不出时长（可能已被删或地址失效）。'
      '这条片子有 $shortSlots 个不到 1.5 秒的坑位——'
      '这几条算不出该放多快，导进剪映时会被切掉超出坑位的部分。'
      '用 ishkafel task 看 pickedMaterials 里哪几条缺时长，换掉它们';
}
