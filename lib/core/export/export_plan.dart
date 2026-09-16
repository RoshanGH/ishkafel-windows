import '../models/semantic_unit.dart';
import '../replacement/candidate_trim.dart';
import '../replacement/replacement_plan.dart';
import '../replacement/unit_base.dart';
import 'balanced_sample.dart';

/// 成片里的一段。要么用原片这一段，要么用一条候选素材顶上去。
class ExportSegment {
  /// 这一段在原片里的位置（毫秒）。用候选素材顶替时，它同时是「这一段该占
  /// 多长」——候选比它长就裁、短就补，时长必须对齐，否则后面所有段都错位。
  final int startMs;
  final int endMs;

  /// 顶上来的候选素材 id；null 表示用原片
  final int? candidateId;

  /// 这一段来自哪个台词语义单元 / 哪个视觉镜头（镜头层替换时才有）。
  /// 导出失败时要能指着说「U3 的 S2 那一段没合成成功」。
  final int unitIndex;
  final int? shotIndex;

  /// 那个单元的**身份**（[SemanticUnit.uid]）。手改的字幕按它取——
  /// 按位置取的话，人挪过单元之后烧上去的就是别人的字幕
  final String unitUid;

  /// **整体替换**时这一段在成片里真正占多长。
  ///
  /// 整体替换是「原样接上」——时长跟候选走，不裁不补（见四种替换的导出
  /// 规格）。而 [startMs]~[endMs] 记的是原片那一段的位置，两者不再相等。
  /// 不区分的话，确认页会按原片长度报「每条约 96.2s」，而实际导出来的是
  /// 97.2s——用户当场就能看出对不上。
  ///
  /// 为 null 表示与原片同长（保留原片、镜头替换都属于这一类：镜头替换是
  /// 变速对齐原坑位，时长不变）。
  final int? composedMs;

  /// 从候选素材的第几毫秒开始用。null = 从头用。
  ///
  /// 只用来跳过开头的转场/黑帧。跳过之后剩下的整条变速铺满坑位——
  /// 视觉镜头替换不自动截断（见 [trimFor]）
  final int? trimStartMs;

  /// **这一镜没换素材时，画面从哪张底片上剪。**
  ///
  /// null = 任务原片（分析切出来的单元，绝大多数情况）。非 null = 这个单元
  /// 的底片被固定成了那条素材，镜头也是按它切的，所以「没换的那一镜」要从
  /// 素材上剪，不是从原片上剪。不带这个字段的话，导出会跑去原片的同一个
  /// 时间点剪一段毫不相干的画面，而哪儿都不报错
  final int? baseCandidateId;

  /// 这一段落在底片的第几毫秒（配合 [baseCandidateId] 用）。
  /// 不给就是 [startMs]——底片是原片时两者本来就相同
  /// **这个单元的底片是哪条素材**——和 [baseCandidateId] 不是一回事。
  ///
  /// 后者说的是「这一段画面从哪儿剪」，换过素材的那一镜就是 null；而字幕
  /// 要看的是**这个单元**有没有底片：那一镜替代的正是底片的这一段，台词
  /// 该从底片的转写里取。拿前者当判据的话，换过素材的镜头一律取不到字幕
  /// （2026-09-15 真机导出一条才发现：预览里有字、导出来没有）
  final int? unitBaseCandidateId;

  /// 不给就是 [startMs]——用 [baseStartMs] 读，别直接读这个
  final int? baseStartMsOrNull;

  int get baseStartMs => baseStartMsOrNull ?? startMs;

  const ExportSegment({
    required this.startMs,
    required this.endMs,
    required this.unitIndex,
    this.unitUid = '',
    this.shotIndex,
    this.candidateId,
    this.composedMs,
    this.trimStartMs,
    this.baseCandidateId,
    this.unitBaseCandidateId,
    int? baseStartMs,
  }) : baseStartMsOrNull = baseStartMs;


  /// 这一段在**成片**里占多长
  int get durationMs => composedMs ?? (endMs - startMs);

  /// 这一段在**原片**里的跨度（切原片时用）
  int get sourceDurationMs => endMs - startMs;
  bool get isOriginal => candidateId == null;

  @override
  bool operator ==(Object other) =>
      other is ExportSegment &&
      other.startMs == startMs &&
      other.endMs == endMs &&
      other.candidateId == candidateId &&
      other.unitIndex == unitIndex &&
      other.shotIndex == shotIndex &&
      other.composedMs == composedMs &&
      // 底片换了就是另一段画面：不比这一项，换底片重导会命中上一张底片
      // 留下的切片缓存，人看到的是「改了没反应」
      other.baseCandidateId == baseCandidateId &&
      other.unitBaseCandidateId == unitBaseCandidateId &&
      other.baseStartMs == baseStartMs;

  @override
  int get hashCode => Object.hash(startMs, endMs, candidateId, unitIndex,
      shotIndex, composedMs, baseCandidateId, unitBaseCandidateId,
      baseStartMs);

  @override
  String toString() => 'ExportSegment(U${unitIndex + 1}'
      '${shotIndex == null ? '' : '/S${shotIndex! + 1}'} '
      '$startMs~$endMs${candidateId == null ? ' 原片' : ' →$candidateId'})';
}

/// 一条要导出的成片：按时间顺序排好的若干段
class ExportCombination {
  /// 第几条（从 1 开始），用于文件名与进度显示
  final int index;
  final List<ExportSegment> segments;

  /// 这条方案叫什么——**它就是文件名**。
  /// 界面上枚举出来的组合没有名字（null），走「变体N」
  final String? name;

  ExportCombination(
      {required this.index,
      required List<ExportSegment> segments,
      this.name})
      : segments = List.unmodifiable(segments);

  /// 这一条里有几段是换过的。全是原片的那一条要能被认出来——
  /// 用户往往想把它排除掉（导出来跟原片一模一样）。
  int get replacedCount => segments.where((s) => !s.isOriginal).length;

  int get durationMs =>
      segments.fold<int>(0, (sum, s) => sum + s.durationMs);
}

/// 把「替换方案」摊平成「要导出哪几条、每条由哪些段拼成」。
///
/// 枚举顺序是**里程表式**：最后一个单元变化最快，第一个单元变化最慢。这样
/// 前几条成片之间只有片尾不同，用户对着导出目录一眼就能看出规律；随机顺序
/// 会让「这一批到底覆盖了什么」变得没法核对。
/// 哪些单元**根本没有底片**：原片上没有它（用户手动加的），又一条候选素材
/// 都没挑。
///
/// 为什么必须单独拦一道：导出那边「没挑素材」一律走「用原片这一段」，
/// 而这些单元的 `startMs`~`endMs` 根本不指向原片的任何位置——真让它跑下去，
/// 出来的是一段空白或者直接崩在 ffmpeg 里，而人要等片子导完才发现。
///
/// 返回单元下标，调用方**必须指着说是哪几个**（「U3 还没挑素材」），
/// 不许拿黑帧顶上、也不许悄悄跳过这一段。
List<int> unitsWithNothingToShow(
  List<SemanticUnit> units,
  List<UnitReplacement> replacements,
) =>
    [
      for (var i = 0; i < units.length; i++)
        // 「有没有底片」走同一份规则；`_hasAnyCandidate` 是额外的一层宽容
        // ——镜头级挑过素材的也算有东西可放（手加的单元本不该走到镜头级，
        // 但存档里残留过这种数据，拦死会让人导不出去且不知道为什么）
        if (baseChoiceOf(
                  unit: units[i],
                  replacement:
                      _planAt(replacements, i) ?? UnitReplacement.keepOriginal(),
                ) is NoBase &&
            !_hasAnyCandidate(_planAt(replacements, i)))
          i,
    ];

UnitReplacement? _planAt(List<UnitReplacement> plans, int i) =>
    i < plans.length ? plans[i] : null;

bool _hasAnyCandidate(UnitReplacement? plan) {
  if (plan == null) return false;
  if (plan.wholeCandidateIds.isNotEmpty) return true;
  return plan.shotCandidateIds.values.any((ids) => ids.isNotEmpty);
}

class ExportPlanner {
  ExportPlanner._();
  /// 枚举要导出的组合，最多 [limit] 条（产品已定 100 条）。
  ///
  /// ## 全排下来装得下：里程表顺序，一条不漏
  ///
  /// 进位顺序是**候选最多的位当最低位**（变化最快）。里程表默认从最后一位
  /// 开始进位，而候选最多的那个位往往夹在中间——那样导出来的一百条里它
  /// 一动不动，等于白挑。
  ///
  /// ## 装不下：按位均衡取样，而不是掐前 N 条
  ///
  /// 掐前 N 条等于「最低位转个不停，别的位一动不动」。真机上就是这个结果：
  /// 一个镜头挑了 5 条素材，导出来的十条全用其中同一条，另外四条一次都没
  /// 露过面（2026-09-10 用户原话：「一个镜头选了5个替换，但是导出10条全是
  /// 选用的其中同一个镜头……既然我选择了挑差异最大的，那最终产生成片时，
  /// 重复度肯定越小越好。任何一个替换的位置都尽量不重复」）。
  ///
  /// 所以超出名额时改走 [balancedVectors]：每一位上的候选轮着来，各自出现
  /// 的次数最多差一次，位与位之间也不齐步走。
  ///
  /// ## 位是**镜头**级的，不是单元级的
  ///
  /// 原来先把一个单元内各镜头的候选做成完整笛卡尔积、再拿单元当一位。
  /// 那样有两个后果：一是 13 个镜头各挑几条就是天文数字，还没开始挑名额
  /// 就先把内存吃了；二是均衡取样想管到「某一镜」也管不着。现在每个挑了
  /// 候选的镜头各算一位，全程按需生成，不铺开。
  static List<ExportCombination> enumerate({
    required List<SemanticUnit> units,
    required List<UnitReplacement> replacements,
    int limit = ReplacementPlan.maxCombinations,

    /// 候选素材各有多长（候选 id → 毫秒）。**整体替换的段落靠它算成片时长**
    /// ——那一层是原样接上，时长跟候选走。取不到的按原单元长度算，
    /// 宁可报得保守，也不拿 0 顶
    Map<int, int> materialDurations = const {},
  }) {
    if (units.isEmpty || limit <= 0) return const [];

    final slots = _slotsOf(units, replacements);
    final counts = [for (final slot in slots) slot.options.length];
    final total = _productCapped(counts, limit);

    final vectors = total <= limit
        ? _odometerVectors(slots, units.length, counts)
        // 装不下就按位均衡取样。多要一些：同一条素材在一条成片里出现两次的
        // 组合会被滤掉，滤掉的不能占名额
        : balancedVectors(counts, limit * 4 + 20);

    final out = <ExportCombination>[];
    final seen = <String>{};
    for (final vector in vectors) {
      if (out.length >= limit) break;
      // 取样是按位独立轮转的，同一个组合可能被抽到两次
      if (!seen.add(vector.join(','))) continue;
      final segments =
          _segmentsFor(units, replacements, slots, vector, materialDurations);
      // 同一条素材在一条成片里出现两次，一眼就能看出来——那不是用户想要的。
      // 笛卡尔积会自然产出这种组合（U1 选 [A,B]、U2 选 [A,C] 里就有 A+A），
      // 在这儿滤掉，编号按**留下来的**顺延，不在编号上留洞
      if (_hasDuplicateMaterial(segments)) continue;
      out.add(ExportCombination(index: out.length + 1, segments: segments));
    }
    return List.unmodifiable(out);
  }

  /// 全排装得下时的顺序：里程表，候选最多的位变化最快
  static List<List<int>> _odometerVectors(
      List<_Slot> slots, int unitCount, List<int> counts) {
    if (slots.isEmpty) return const [[]];
    final order = _carryOrder(slots, unitCount);
    final cursor = List<int>.filled(slots.length, 0);
    final out = <List<int>>[];
    while (true) {
      out.add(List<int>.unmodifiable(cursor));
      var k = 0;
      while (k < order.length) {
        final j = order[k];
        cursor[j]++;
        if (cursor[j] < counts[j]) break;
        cursor[j] = 0;
        k++;
      }
      if (k >= order.length) break; // 全部进位完毕 = 枚举结束
    }
    return out;
  }

  /// 进位顺序（最快的位排在前）：先按单元的排法总数从多到少，
  /// 同一个单元内靠后的镜头更快。
  ///
  /// 排法数相同时保持「后面的单元先变」——那是原本的里程表顺序，
  /// 用户对着导出目录看到的规律（前几条只有片尾不同）不该无缘无故改掉
  static List<int> _carryOrder(List<_Slot> slots, int unitCount) {
    final perUnit = List<int>.filled(unitCount, 1);
    for (final slot in slots) {
      final grown = perUnit[slot.unitIndex] * slot.options.length;
      // 乘积只用来排序，封顶就够，别让它溢出
      perUnit[slot.unitIndex] = grown > _sortCeiling ? _sortCeiling : grown;
    }
    final unitOrder = [for (var i = 0; i < unitCount; i++) i]
      ..sort((a, b) {
        final byCount = perUnit[b].compareTo(perUnit[a]);
        return byCount != 0 ? byCount : b.compareTo(a);
      });
    return [
      for (final u in unitOrder)
        ...[
          for (var j = 0; j < slots.length; j++)
            if (slots[j].unitIndex == u) j,
        ].reversed,
    ];
  }

  static const int _sortCeiling = 1 << 40;

  /// 各位乘积，超过 [limit] 就不再往下乘（只需要知道「装不装得下」）
  static int _productCapped(List<int> counts, int limit) {
    var total = 1;
    for (final n in counts) {
      total *= n;
      if (total > limit) return limit + 1;
    }
    return total;
  }

  /// 哪些位置可选：整体替换按单元算一位，镜头替换按**每个挑了候选的镜头**
  /// 各算一位。没挑候选的镜头恒用原画面，不占位
  static List<_Slot> _slotsOf(
      List<SemanticUnit> units, List<UnitReplacement> replacements) {
    final slots = <_Slot>[];
    for (var i = 0; i < units.length; i++) {
      final replacement = i < replacements.length ? replacements[i] : null;
      if (replacement == null) continue;
      switch (replacement.mode) {
        case ReplacementMode.keepOriginal:
          break;
        case ReplacementMode.whole:
          if (replacement.wholeCandidateIds.isNotEmpty) {
            slots.add(_Slot(i, null, [...replacement.wholeCandidateIds]));
          }
        case ReplacementMode.perShot:
          for (var s = 0; s < units[i].shots.length; s++) {
            final ids = replacement.shotCandidateIds[s];
            if (ids != null && ids.isNotEmpty) {
              slots.add(_Slot(i, s, [...ids]));
            }
          }
      }
    }
    return slots;
  }

  /// 把「每一位选了第几个候选」摊成这一条成片的全部段落
  static List<ExportSegment> _segmentsFor(
    List<SemanticUnit> units,
    List<UnitReplacement> replacements,
    List<_Slot> slots,
    List<int> vector,
    Map<int, int> materialDurations,
  ) {
    final whole = <int, int>{}; // 单元 → 整体替换选中的候选
    final perShot = <int, Map<int, int>>{}; // 单元 → 镜头 → 选中的候选
    for (var j = 0; j < slots.length; j++) {
      final slot = slots[j];
      final id = slot.options[vector[j]];
      if (slot.shotIndex == null) {
        whole[slot.unitIndex] = id;
      } else {
        (perShot[slot.unitIndex] ??= {})[slot.shotIndex!] = id;
      }
    }

    final out = <ExportSegment>[];
    for (var i = 0; i < units.length; i++) {
      final unit = units[i];
      final replacement = i < replacements.length ? replacements[i] : null;
      // 「这一段的底片是谁」跟预览走同一份规则（见 [baseChoiceOf]）。
      // **这里问的只是底片**：底片是原片时还要再看要不要按镜头分段，
      // 那是底片之上的一层。
      //
      // `hasOriginal: true`——导出侧「这条任务到底有没有原片」由前置检查
      // 负责点名（见 [emptyInsertedUnits] / `_blankBlocker`），不在排段落
      // 这一步默默把它变成别的东西
      final choice = baseChoiceOf(
        unit: unit,
        replacement: replacement ?? UnitReplacement.keepOriginal(),
        wholeCandidateId: whole[i],
      );
      // 底片是素材、镜头又不是按它切的：整段原样接上。
      // 按它切过的往下走「按镜头逐段」那条路
      if (choice case MaterialBase(:final candidateId)
          when !hasOwnBaseShots(unit)) {
        // 整体替换：整个单元换成这一条候选，原样接上，成片时长跟候选走。
        // 探不出来就按原单元算——报得保守好过拿 0 顶（那会把总时长算成一团）
        out.add(ExportSegment(
          startMs: unit.startMs,
          endMs: unit.endMs,
          unitIndex: unit.index,
          unitUid: unit.uid,
          candidateId: candidateId,
          composedMs: materialDurations[candidateId],
        ));
        continue;
      }
      // 底片自己的镜头一律逐镜产段——那一段的画面就是一格格拼出来的，
      // 哪怕一镜都没换（没换的从底片上剪）
      if (hasOwnBaseShots(unit) ||
          (replacement?.mode == ReplacementMode.perShot &&
              unit.shots.isNotEmpty)) {
        for (var s = 0; s < unit.shots.length; s++) {
          out.add(_shotSegment(
            unit: unit,
            shotIndex: s,
            candidateId: perShot[i]?[s],
            replacement: replacement ?? UnitReplacement.keepOriginal(),
            materialDurations: materialDurations,
          ));
        }
        continue;
      }
      out.add(ExportSegment(
        startMs: unit.startMs,
        endMs: unit.endMs,
        unitIndex: unit.index,
        unitUid: unit.uid,
      ));
    }
    return out;
  }

  /// 哪几条素材被挑在了**多个位置**上——一条成片都排不出来时的元凶。
  ///
  /// 同一条素材在一条成片里出现两次，[_hasDuplicateMaterial] 会把那种组合
  /// 丢掉；两个位置都只挑了同一条时，**每一种**排法都会被丢掉，结果就是
  /// 「共 0 条成片」，而界面上一个字都不说（2026-09-09 设计走查真机：
  /// U1·S7 和 U3·S1 都用了素材 116719，导出对话框显示 0 条、导出按钮灰着，
  /// 没有任何原因）。
  ///
  /// 返回 素材 id → 它占了哪几个位置（`U1·S7` 这种人话标签）。
  static Map<int, List<String>> materialsUsedTwice(
      List<UnitReplacement> replacements) {
    final places = <int, List<String>>{};
    void note(int id, String label) => (places[id] ??= []).add(label);

    for (var u = 0; u < replacements.length; u++) {
      final replacement = replacements[u];
      switch (replacement.mode) {
        case ReplacementMode.keepOriginal:
          break;
        case ReplacementMode.whole:
          for (final id in replacement.wholeCandidateIds) {
            note(id, 'U${u + 1}');
          }
        case ReplacementMode.perShot:
          for (final entry in replacement.shotCandidateIds.entries) {
            for (final id in entry.value) {
              note(id, 'U${u + 1}·S${entry.key + 1}');
            }
          }
      }
    }
    places.removeWhere((_, where) => where.length < 2);
    return places;
  }

  /// **每一种排法都躲不开的撞车**：某条素材是至少两个位置的**唯一**候选。
  ///
  /// 那种情况下笛卡尔积里每一条都含这条素材两次，会被
  /// [_hasDuplicateMaterial] 全部丢掉，结果是一条都排不出来。
  /// 界面据此在**入口**就拦下来（见 `exportBlockedReason`），
  /// 而不是让人点进导出对话框、看着一个「共 0 条」发愣
  /// （2026-09-10 真机走查：底部状态栏说 2 条、对话框说 0 条、
  /// 按钮照样可以点，三个地方各说各的）。
  ///
  /// 位置上还有别的候选时不算——那就换一个，躲得开。
  /// 更绕的必撞（三个位置共用两条素材那种鸽笼）不在这儿判，
  /// 留给对话框里的 [materialsUsedTwice] 兜底。
  static Map<int, List<String>> unavoidableClashes(
      List<UnitReplacement> replacements) {
    final soleOwner = <int, List<String>>{};
    void note(int id, String label) => (soleOwner[id] ??= []).add(label);

    for (var u = 0; u < replacements.length; u++) {
      final replacement = replacements[u];
      switch (replacement.mode) {
        case ReplacementMode.keepOriginal:
          break;
        case ReplacementMode.whole:
          if (replacement.wholeCandidateIds.length == 1) {
            note(replacement.wholeCandidateIds.single, 'U${u + 1}');
          }
        case ReplacementMode.perShot:
          for (final entry in replacement.shotCandidateIds.entries) {
            if (entry.value.length == 1) {
              note(entry.value.single, 'U${u + 1}·S${entry.key + 1}');
            }
          }
      }
    }
    soleOwner.removeWhere((_, where) => where.length < 2);
    return soleOwner;
  }

  /// 一条成片里同一条素材出现了两次
  static bool _hasDuplicateMaterial(List<ExportSegment> segments) {
    final seen = <int>{};
    for (final segment in segments) {
      final id = segment.candidateId;
      if (id != null && !seen.add(id)) return true;
    }
    return false;
  }




  /// 造一个镜头位的段，**顺手算好起点**。
  ///
  /// 视觉镜头替换一律「整条变速铺满原镜头时长」（见 [trimFor]）：没人调过
  /// 起点就是从 0 起整条用，调过就跳过开头那一截、剩下的照旧铺满。
  static ExportSegment _shotSegment({
    required SemanticUnit unit,
    required int shotIndex,
    required int? candidateId,
    required UnitReplacement replacement,
    required Map<int, int> materialDurations,
  }) {
    final shot = unit.shots[shotIndex];
    if (candidateId == null) {
      // 没换素材的这一镜：从**这个单元的底片**上剪。底片是原片时
      // baseStartMs 就等于 shot.startMs（原坐标），底片是素材时是
      // 「素材内偏移」——一个式子管两种，见 [hasOwnBaseShots]
      return ExportSegment(
        startMs: shot.startMs,
        endMs: shot.endMs,
        unitIndex: unit.index,
        unitUid: unit.uid,
        shotIndex: shotIndex,
        baseCandidateId: unit.baseCandidateId,
        unitBaseCandidateId: unit.baseCandidateId,
        baseStartMs: unit.baseCandidateId == null
            ? shot.startMs
            : shot.startMs - unit.startMs,
      );
    }
    final materialMs = materialDurations[candidateId] ?? 0;
    final cut = trimFor(
      materialMs: materialMs,
      slotMs: shot.endMs - shot.startMs,
      startMs:
          replacement.trimStartOf(shotIndex: shotIndex, candidateId: candidateId),
    );
    return ExportSegment(
      startMs: shot.startMs,
      endMs: shot.endMs,
      unitIndex: unit.index,
      unitUid: unit.uid,
      shotIndex: shotIndex,
      candidateId: candidateId,
      // 起点 0 就不写：写成 0 和不写是同一件事，而 null 让下游的命令里
      // 干脆不出现 -ss
      trimStartMs: materialMs > 0 && cut.startMs > 0 ? cut.startMs : null,
      // 换过素材的这一镜替代的正是底片的这一段——字幕从底片的转写里取，
      // 坑位也是素材内偏移（画面用的 baseCandidateId 这里当然是 null）
      unitBaseCandidateId: unit.baseCandidateId,
      baseStartMs: unit.baseCandidateId == null
          ? null
          : shot.startMs - unit.startMs,
    );
  }
}

/// 一个「可变位」：某个单元（整体替换）或某个视觉镜头（镜头替换）上，
/// 用户挑出来的那几条候选。挑差异最大的、均衡取样，管的都是这个粒度
class _Slot {
  final int unitIndex;

  /// null = 整体替换（整个单元一段）
  final int? shotIndex;
  final List<int> options;

  const _Slot(this.unitIndex, this.shotIndex, this.options);
}
