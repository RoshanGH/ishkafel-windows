import 'package:collection/collection.dart';
import '../audio/material_audio.dart';
import '../analysis/providers.dart' show AsrSentence;
import 'shot.dart';
import 'tag_trace.dart';
import 'unit_uid.dart';

/// 台词语义单元：以台词语义为准的切分单元，内部包含若干视觉镜头（不可变）
class SemanticUnit {
  /// **这个单元自己的身份**，永不变（见 [newUnitUid]）。
  ///
  /// 挂在单元上的东西——挑好的素材、音色、配乐、手改字幕、生成的配音文件
  /// ——全按它记，所以挪动顺序、删掉别的单元都不需要再搬任何东西。
  ///
  /// 空串 = 还没发过（老存档、或刚 new 出来的对象）。读档时补发
  /// （见 [ensureUnitUids]），编辑器收下单元时也补发一次——**进了编辑器
  /// 的单元一定有身份**，别的地方可以放心拿它当键。
  final String uid;

  /// 它在列表里排第几。**这是位置，不是身份**：人一拖就变。
  /// 界面上的 U1/U2/U3 说的是它
  final int index;
  final int startMs;
  final int endMs;
  final String transcript;
  final List<String> tags;

  /// 标签是否已经过期：这个单元被编辑过、标签还是编辑前打的。
  /// 不直接抹掉标签——重打是异步的，中间抹空会让用户以为标签丢了。
  final bool tagsStale;

  /// 这些标签是**人手改的**，不是模型打的。
  ///
  /// 重新打标时跳过它——人刚照着画面判断过，模型再打一遍等于把他的结论抹掉，
  /// 而且不问一声：他不会想到「我改的东西被一个后台步骤盖了」，
  /// 只会觉得改了没生效。想让模型重新接管，先把手改清掉。
  final bool tagsHandpicked;

  /// 这次打标的过程量（输入台词、词表、模型原样回复）
  final TagTrace? trace;
  final List<Shot> shots;

  /// 这个单元被**整体替换**时，放素材自己的哪一路声音。
  ///
  /// null = 原声（不分离、满音量），也就是这个功能出现之前的行为——
  /// 整体替换本来就是「画面和声音一起换掉」，那一段的口播来自素材。
  /// 手动加的单元尤其用得上改它：片头插一段素材，你多半只要画面，
  /// 里面别人说的话不该跟着播出来。
  ///
  /// **和镜头级那个不是一回事**：镜头替换只换画面、口播还是原片的，
  /// 素材声音是额外叠的一层，所以那边默认「不播放」。
  final MaterialAudioMode? wholeAudioMode;

  /// 整体替换时素材声音压到几成。null = 满音量（原来的行为）
  final double? wholeAudioVolume;

  /// 这个单元的 [shots] 是**按哪张底片切出来的**。
  ///
  /// null = 按原片切的（分析那一次），也就是这个功能出现之前的全部情况。
  /// 非 null = 用户对这一段点过「切分这一段」，底片是这条素材，
  /// [shots] 的坐标是 `startMs + 底片内偏移`。
  ///
  /// 它同时是**底片被固定下来**的标记：底片一固定，整体替换就只能选这一条
  /// ——第二条底片切出来的镜头数和切点都不一样，挂在第 3 镜上的选择无处安放
  /// （见 `docs/superpowers/specs/2026-09-14-底片-design.md`）。
  ///
  /// 为什么要记：不记的话用户改掉整体替换的候选，[shots] 就悄悄指向了
  /// 另一条素材的时间点，画面全错而哪儿都不报错。
  final int? baseCandidateId;

  /// **底片素材自己的转写**（时间戳是素材内毫秒，不是原片轴）。
  ///
  /// 底片换成一条素材之后，原片那份 ASR 跟这段画面毫无关系——拿它取词，
  /// 烧上去的台词和画面对不上。所以切分底片时顺手把这条素材也转写一遍，
  /// 字幕从这一份取（见 `docs/superpowers/specs/2026-09-14-底片-design.md`）。
  ///
  /// null = 还没转写过（老存档、或转写失败）。空列表 = 转过、这条素材没人说话
  final List<AsrSentence>? baseSentences;

  /// 这个单元在**原片上有没有对应的一段**。
  ///
  /// 默认 true——分析切出来的单元都取自原片。false 只出现在用户**手动加**
  /// 的单元上：原片里没有它，画面只能来自挑到的素材，[startMs]/[endMs]
  /// 这时只是它在时间线上占的位置，不指向原片的任何一段。
  ///
  /// 谁需要它：导出与预览要知道「这一段没有原片可放，没挑素材就是真的缺东西」
  /// （不许拿黑帧顶上）；原声重剪要跳过它；抽帧、烧字幕同理。
  final bool hasSource;

  const SemanticUnit({
    this.uid = '',
    required this.index,
    required this.startMs,
    required this.endMs,
    required this.transcript,
    this.tags = const [],
    this.tagsStale = false,
    this.tagsHandpicked = false,
    this.trace,
    this.shots = const [],
    this.baseCandidateId,
    this.baseSentences,
    this.hasSource = true,
    this.wholeAudioMode,
    this.wholeAudioVolume,
  });

  int get durationMs => endMs - startMs;

  /// 严格包含约束：所有镜头边界必须落在本单元范围内
  bool get shotsStrictlyNested =>
      shots.every((s) => s.startMs >= startMs && s.endMs <= endMs);

  SemanticUnit copyWith({
    String? uid,
    int? index,
    int? startMs,
    int? endMs,
    String? transcript,
    List<String>? tags,
    bool? tagsStale,
    bool? tagsHandpicked,
    TagTrace? trace,
    List<Shot>? shots,
    int? baseCandidateId,
    List<AsrSentence>? baseSentences,
    bool? hasSource,
    MaterialAudioMode? wholeAudioMode,
    double? wholeAudioVolume,
  }) =>
      SemanticUnit(
        uid: uid ?? this.uid,
        index: index ?? this.index,
        startMs: startMs ?? this.startMs,
        endMs: endMs ?? this.endMs,
        transcript: transcript ?? this.transcript,
        tags: tags ?? this.tags,
        tagsStale: tagsStale ?? this.tagsStale,
        tagsHandpicked: tagsHandpicked ?? this.tagsHandpicked,
        trace: trace ?? this.trace,
        shots: shots ?? this.shots,
        baseCandidateId: baseCandidateId ?? this.baseCandidateId,
        baseSentences: baseSentences ?? this.baseSentences,
        hasSource: hasSource ?? this.hasSource,
        wholeAudioMode: wholeAudioMode ?? this.wholeAudioMode,
        wholeAudioVolume: wholeAudioVolume ?? this.wholeAudioVolume,
      );

  Map<String, dynamic> toJson() => {
        // 空串不写：老存档里本来就没有，写个空串只会让人以为「发过但是空的」
        if (uid.isNotEmpty) 'uid': uid,
        'index': index,
        'startMs': startMs,
        'endMs': endMs,
        'transcript': transcript,
        'tags': tags,
        'tagsStale': tagsStale,
        if (tagsHandpicked) 'tagsHandpicked': true,
        'shots': shots.map((s) => s.toJson()).toList(),
        'trace': trace?.toJson(),
        'hasSource': hasSource,
        // 只在固定过底片时才写：null 和「按原片切的」是同一件事
        if (baseCandidateId != null) 'baseCandidateId': baseCandidateId,
        if (baseSentences != null)
          'baseSentences': [for (final s in baseSentences!) s.toJson()],
        // 只在设过时才写：没设过和「明确设成原声」在存档里要分得开
        if (wholeAudioMode != null) 'wholeAudioMode': wholeAudioMode!.name,
        if (wholeAudioVolume != null) 'wholeAudioVolume': wholeAudioVolume,
      };

  factory SemanticUnit.fromJson(Map<String, dynamic> json) => SemanticUnit(
        // 老存档没有这个字段，读出来是空串，由 [ensureUnitUids] 补发
        uid: json['uid'] is String ? json['uid'] as String : '',
        index: json['index'] as int,
        startMs: json['startMs'] as int,
        endMs: json['endMs'] as int,
        transcript: json['transcript'] as String,
        // 缺失/为 null 时兜底为空列表（与 Shot.tags 同款兼容）：
        // 硬转换会让整条任务在 findAll 里被跳过，用户看到的是「任务不见了」
        tags: (json['tags'] as List<dynamic>?)?.cast<String>() ?? const [],
        tagsStale: json['tagsStale'] == true,
        // 存量存档里没有这个字段——那时的标签都是模型打的
        tagsHandpicked: json['tagsHandpicked'] == true,
        shots: (json['shots'] as List<dynamic>?)
                ?.map((e) => Shot.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        trace: TagTrace.tryFromJson(json['trace']),
        // 存量存档里没有这个字段——那时的镜头都是按原片切的
        baseCandidateId: json['baseCandidateId'] as int?,
        baseSentences: (json['baseSentences'] as List<dynamic>?)
            ?.map((e) => AsrSentence.fromJson(e as Map<String, dynamic>))
            .toList(),
        // 存量存档里没有这个字段——它们的单元都是分析切出来的，都有原片来源。
        // 缺失时必须兜底为 true，兜成 false 会让老任务整条以为原片不见了
        hasSource: json['hasSource'] != false,
        wholeAudioMode:
            MaterialAudioMode.byName(json['wholeAudioMode'] as String?),
        wholeAudioVolume: (json['wholeAudioVolume'] as num?)?.toDouble(),
      );

  static const _listEq = ListEquality<Object>();

  @override
  bool operator ==(Object other) =>
      other is SemanticUnit &&
      other.index == index &&
      other.startMs == startMs &&
      other.endMs == endMs &&
      other.transcript == transcript &&
      _listEq.equals(other.tags, tags) &&
      other.tagsStale == tagsStale &&
      // 底片换了就是另一个单元：同样的 shots 按另一条素材切出来，
      // 画面完全不同。不比这一项，换底片后界面会判成「没变」而不刷新
      other.baseCandidateId == baseCandidateId &&
      _listEq.equals(other.shots, shots);

  @override
  int get hashCode => Object.hash(index, startMs, endMs, transcript,
      Object.hashAll(tags), tagsStale, baseCandidateId, Object.hashAll(shots));
}
