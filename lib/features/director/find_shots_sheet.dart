import 'dart:async';
import 'dart:io';
import '../../core/ui/text_editing_keys.dart';

import 'package:flutter/material.dart';

import '../shared/scroll_fade.dart';
import '../shared/thumb_image.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/log/app_log.dart';
import '../../core/presentation/user_facing_error.dart';
import '../../core/miaoa/miaoa_content_service.dart';
import '../../core/models/renew_task.dart';
import '../../core/playback/media_kit_playback.dart';
import '../../core/script/line_tagger.dart';
import '../../core/miaoa/query_frame_uploader.dart';
import '../../core/script/script_doc.dart';
import '../picking/candidate_search_controller.dart';
import 'director_providers.dart';
import 'tag_picker.dart';

/// 检索维度。**有主次之分**，不是并列的四个入口：
/// 进这个面板的默认动作是「复刻参考片的这一镜」，所以主路径是拿参考镜头的
/// 画面描述/标签去找像的画面；[name] 是**兜底**——主路径筛不到时，人会说
/// 「我知道妙啊里有那条片子」，直接按文件名把它捞出来。
///
/// 标签与项目不是维度，是所有维度共用的外部约束
enum _SearchDim { voiceover, description, similar, name }

/// 给一行找镜头（M3）。
///
/// 标签是所有检索的**公共筛选层**（设计稿）：行标签自动预填成 chips、
/// 可勾选可增删；按标签搜或按画面描述搜。挑中的镜头按顺序落到行上。
/// 防撞车：同任务其他行已用的素材打上「第 N 行在用」角标——能选，但看得见。
/// 面板的产出：镜头序列 + （可能在面板里增删过的）行标签
class FindShotsResult {
  final List<LineShot> shots;
  final List<String> tags;
  const FindShotsResult({required this.shots, required this.tags});
}

Future<FindShotsResult?> showFindShotsSheet(
  BuildContext context, {
  required ShotSearchServices services,
  required LineTagger? tagger,
  required RenewTask task,
  required int lineIndex,
  required ScriptLine line,

  /// materialId → 用在第几行（0 起，含本行；本行的用于回显已选）
  required Map<int, int> usedBy,

  /// 参考分镜（原子）的首帧缩略图路径；null = 还没抽出来
  String? Function(int segIndex)? refThumbOf,

  /// 参考视频的本地路径（原子「直接用原片这段」要它）
  String? refVideoPath,

  /// 给某个参考视觉镜头按需打标（标签 + 画面描述），返回结果；
  /// null = 没配置 AI 或打标失败（面板据此说明原因，不静默）
  Future<RefShotMeta?> Function(int segIndex)? tagRefShot,

  /// 参考还没切过视觉镜头时，**在面板里**切一次并返回切好的行——
  /// 面板开着 loading 等它，而不是先展示旧数据、关掉重开才对
  Future<ScriptLine?> Function()? prepareRef,

  /// 把本地帧变成妙啊的查询帧（「画面相似」要它）
  QueryFrameUploader? queryFrames,
}) =>
    showDialog<FindShotsResult>(
      context: context,
      builder: (_) => _FindShotsSheet(
        services: services,
        tagger: tagger,
        task: task,
        lineIndex: lineIndex,
        line: line,
        usedBy: usedBy,
        refThumbOf: refThumbOf,
        refVideoPath: refVideoPath,
        tagRefShot: tagRefShot,
        prepareRef: prepareRef,
        queryFrames: queryFrames,
      ),
    );

class _FindShotsSheet extends StatefulWidget {
  final ShotSearchServices services;
  final LineTagger? tagger;
  final RenewTask task;
  final int lineIndex;
  final ScriptLine line;
  final Map<int, int> usedBy;
  final String? Function(int segIndex)? refThumbOf;
  final String? refVideoPath;
  final Future<RefShotMeta?> Function(int segIndex)? tagRefShot;
  final Future<ScriptLine?> Function()? prepareRef;

  /// 把本地帧变成妙啊的查询帧（以图搜视频只吃 OSS key）。
  /// null = 这台机器还没接上素材库
  final QueryFrameUploader? queryFrames;

  const _FindShotsSheet({
    required this.services,
    required this.tagger,
    required this.task,
    required this.lineIndex,
    required this.line,
    required this.usedBy,
    this.refThumbOf,
    this.refVideoPath,
    this.tagRefShot,
    this.prepareRef,
    this.queryFrames,
  });

  @override
  State<_FindShotsSheet> createState() => _FindShotsSheetState();
}

class _FindShotsSheetState extends State<_FindShotsSheet> {
  late final CandidateSearchController _search = CandidateSearchController(
    service: widget.services.content,
    probe: widget.services.probe,
    projectIds: [if (widget.task.project != null) widget.task.project!.id],
  );

  /// 台词维度的检索词（预填本行台词——参考片这一句在说什么）
  late final TextEditingController _voiceoverKw =
      TextEditingController(text: _line.text.trim());

  /// 画面描述维度的检索词（人来描述想要的画面）
  final TextEditingController _descKw = TextEditingController();

  /// 检索用的标签（预填行标签；勾选状态就在这里维护）。
  /// 标签不是一个独立维度，是**所有维度共用的外部约束**
  late final List<String> _tags = [..._line.tags];

  /// 按名称搜的关键词（兜底路子）
  final TextEditingController _nameKw = TextEditingController();

  /// 原位预览：同时只有一张卡在播，谁在播就把画面挂到谁身上。
  /// 挑镜头是「看一眼再决定」的活，为此弹一层播放窗、看完再关掉，
  /// 一条条看下来就是几十次开关（编导台的镜头卡早就是原位播了）
  MediaKitPlaybackController? _preview;
  Widget? _previewVideo;

  /// 谁在播：候选卡用 'c<素材id>'，参考镜用 'r<下标>'；null = 没在播
  String? _previewKey;

  /// 播这条候选；再点同一条 = 停。素材还没落地，播的是妙啊的预览地址
  Future<void> _togglePreview(CandidateMaterial m) async {
    final url = m.previewUrl;
    if (url == null || url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('这条素材没有可播的预览地址。')));
      return;
    }
    await _playAt('c${m.id}', url, what: '候选素材 ${m.id}');
  }

  /// 播参考片的某一镜（原片的一个区间）。参考镜和候选卡共用一个播放器，
  /// 所以同时只有一个在响
  Future<void> _toggleRefPreview(int k, (int, int) seg) async {
    final path = widget.refVideoPath;
    if (path == null || !File(path).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('参考视频不在原位了，播不了这一镜。')));
      return;
    }
    await _playAt('r$k', path,
        startMs: seg.$1, endMs: seg.$2, what: '参考第 ${k + 1} 镜');
  }

  /// 原位播一段。[startMs]/[endMs] 都给时只播这个区间（参考镜是原片里的
  /// 一段，不能从头播）
  Future<void> _playAt(String key, String source,
      {int? startMs, int? endMs, required String what}) async {
    if (_previewKey == key) {
      await _stopPreview();
      return;
    }
    final player = _preview ??= MediaKitPlaybackController();
    _previewVideo ??= player.buildVideoWidget();
    setState(() => _previewKey = key);
    try {
      await player.open(source);
      await player.waitUntilLoaded();
      if (!mounted || _previewKey != key) return;
      await player.setMuted(false);
      if (startMs != null && endMs != null && endMs > startMs) {
        final ok = await player.playRange(startMs, endMs, 30);
        if (!ok) {
          await player.seekMs(startMs);
          await player.play();
        }
      } else {
        await player.play();
      }
    } catch (e) {
      AppLog.warn('$what 预览播放失败：$e');
      if (!mounted) return;
      await _stopPreview();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('这一段播不了，可能地址已过期或文件已移动。')));
      }
    }
  }

  Future<void> _stopPreview() async {
    await _preview?.pause();
    if (mounted && _previewKey != null) setState(() => _previewKey = null);
  }

  /// 切到「按名称」之前勾着的标签——切回别的维度时原样还给用户
  Set<String>? _tagsBeforeName;

  /// 从「按名称」切回别的维度：把之前的标签约束还回去
  void _restoreTagsFromName() {
    final saved = _tagsBeforeName;
    if (_dim != _SearchDim.name || saved == null) return;
    _enabledTags
      ..clear()
      ..addAll(saved);
    _tagsBeforeName = null;
  }
  late final Set<String> _enabledTags = {..._line.tags};

  /// 标签名 → miaoa 标签 id。打开面板时按任务的分子标签组拉一次；
  /// 从标签选择器新加的标签会把解析好的 id 补进来
  Map<String, int>? _tagIds;
  String? _tagIdsError;

  /// 当前检索维度
  _SearchDim _dim = _SearchDim.voiceover;
  bool _tagging = false;

  /// 找相似的查询帧（候选卡「找相似」发起）；null = 还没有目标
  String? _similarToName;
  String? _similarFileKey;

  /// 当前选中的参考视觉镜头（下标）；null = 用台词语义单元的条件。
  ///
  /// **两层各有各的检索键**（用户定的模型）：选中某个参考视觉镜头 →
  /// 用**它的标签 + 它的画面描述**（这一层找的是画面）；一个都不选 →
  /// 用**这句的标签 + 脚本里的台词**。参考里的 ASR 只展示、不参与检索
  int? _refSeg;

  /// 参考镜头打标中（按需打，打完缓存）
  bool _refTagging = false;

  /// 已选镜头（保持加入顺序；预填本行已有的）
  late final List<LineShot> _picked = [...widget.line.shots];

  /// 面板内的行快照：参考切分/打标的结果直接更新它，界面立刻正确
  /// （此前结果只落在页面的 _doc 上，面板拿的是打开那一刻的旧快照——
  /// 必须关掉重开才看得到，真机反馈）
  late ScriptLine _line = widget.line;

  /// 正在切参考的视觉镜头
  bool _preparingRef = false;

  @override
  void initState() {
    super.initState();
    _search.addListener(_onSearch);
    _bootstrap();
  }

  void _onSearch() => setState(() {});

  Future<void> _bootstrap() async {
    // 参考还没切过视觉镜头：面板里 loading 等它切完，切完直接显示
    // 正确的一排镜头（不让人看旧数据）
    final ref0 = _line.reference;
    if (ref0 != null && ref0.cuts.isEmpty && !ref0.hasWholeShots) {
      if (widget.prepareRef != null) {
        setState(() => _preparingRef = true);
        try {
          final fresh = await widget.prepareRef!();
          if (mounted && fresh != null) setState(() => _line = fresh);
        } finally {
          if (mounted) setState(() => _preparingRef = false);
        }
      }
    }
    await _loadTagIds();
    if (!mounted) return;
    // 自动预搜（设计稿：默认全自动预填，人只做否决）：
    // 默认按台词搜——检索依据就是参考片这一句的 ASR 台词，行标签作约束
    await _runSearch();
  }

  Future<void> _loadTagIds() async {
    try {
      final groups = await widget.services.tags.listGroups();
      final wanted = {for (final g in widget.task.unitTagGroups) g.id};
      final ids = <String, int>{};
      for (final g in groups) {
        if (!wanted.contains(g.id)) continue;
        final infos = await widget.services.tags.listTags(g.id);
        for (final t in infos) {
          ids.putIfAbsent(t.name, () => t.id);
        }
      }
      if (mounted) setState(() => _tagIds = ids);
    } catch (e) {
      AppLog.warn('找镜头面板拉标签词表失败：$e');
      if (mounted) {
        setState(() => _tagIdsError = '标签词表拉取失败，按标签搜不可用（可用画面描述搜）');
      }
    }
  }

  List<int> get _enabledTagIds => [
        for (final name in _tags)
          if (_enabledTags.contains(name)) ?_tagIds?[name],
      ];

  /// 统一检索入口：当前维度 + 标签约束（约束贴在每一种维度上）。
  /// 维度输入为空而约束非空时，退化为纯标签筛
  Future<void> _runSearch() async {
    final ids = _enabledTagIds;
    switch (_dim) {
      case _SearchDim.voiceover:
        final kw = _voiceoverKw.text.trim();
        if (kw.isEmpty && ids.isEmpty) return;
        await (kw.isEmpty
            ? _search.searchByTags(tagIds: ids)
            : _search.searchByVoiceover(kw, tagIds: ids));
      case _SearchDim.description:
        final kw = _descKw.text.trim();
        if (kw.isEmpty && ids.isEmpty) return;
        await (kw.isEmpty
            ? _search.searchByTags(tagIds: ids)
            : _search.searchByDescription(kw, tagIds: ids));
      case _SearchDim.similar:
        final key = _similarFileKey;
        if (key == null) return;
        await _search.searchByImage(key, tagIds: ids);
      case _SearchDim.name:
        final kw = _nameKw.text.trim();
        if (kw.isEmpty) return;
        await _search.searchByName(kw, tagIds: ids);
    }
  }

  /// **拿一张本地图去妙啊搜像的画面**（参考镜的首帧走这条）。
  ///
  /// 妙啊的以图搜视频只吃 OSS key，本地图得先传上去。传过的按内容指纹
  /// 记着，同一张不重复传。
  Future<void> _searchSimilarByFrame(File frame, String label) async {
    final uploader = widget.queryFrames;
    if (uploader == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('这台机器还没接上素材库，搜不了相似画面。')));
      return;
    }
    setState(() {
      _dim = _SearchDim.similar;
      _similarToName = label;
      _similarFileKey = null;
    });
    try {
      // 上传要花几秒（一张几十 KB 的图 + 建记录），先说一声，
      // 别让人对着不动的面板猜
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            duration: Duration(seconds: 2),
            content: Text('正在把这一帧交给素材库做查询帧…')));
      }
      final key = await uploader.keyFor(frame);
      if (!mounted) return;
      setState(() => _similarFileKey = key);
      await _runSearch();
    } catch (e) {
      if (!mounted) return;
      // **不悄悄退回文字搜**：人点的是「画面相似」，给他一批按文字搜出来的
      // 东西，他不会知道自己看的根本不是相似画面
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(userFacingError(e,
              fallback: '拿这一帧搜索失败，请检查网络与素材库登录状态'))));
    }
  }

  /// 画面相似：拿一条候选的首帧当查询帧，切到「画面相似」维度
  Future<void> _searchSimilar(CandidateEntry entry) async {
    final fileKey = entry.material.fileKey;
    if (fileKey == null || fileKey.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('这条素材没有可用的查询帧，搜不了相似。')));
      return;
    }
    final m = entry.material;
    setState(() {
      _dim = _SearchDim.similar;
      _similarToName = m.voiceover.isNotEmpty ? m.voiceover : m.name;
      _similarFileKey = fileKey;
    });
    await _runSearch();
  }

  /// 打开标签选择器：从妙啊标签体系里搜索、点选、替换约束标签
  Future<void> _pickTags() async {
    final picked = await showTagPicker(
      context,
      tags: widget.services.tags,
      selected: [
        for (final t in _tags)
          if (_enabledTags.contains(t)) t,
      ],
      preferredGroupIds: {for (final g in widget.task.unitTagGroups) g.id},
    );
    if (picked == null || !mounted) return;
    setState(() {
      _tags
        ..clear()
        ..addAll(picked.map((t) => t.name));
      _enabledTags
        ..clear()
        ..addAll(picked.map((t) => t.name));
      for (final t in picked) {
        if (t.id != null) (_tagIds ??= {})[t.name] = t.id!;
      }
    });
    await _runSearch();
  }

  /// 自动打标：AI 从任务标签组的词表里给这行台词挑标签
  Future<void> _autoTag() async {
    final tagger = widget.tagger;
    if (tagger == null) return;
    setState(() => _tagging = true);
    try {
      final tags = await tagger.tag(
        text: _line.text,
        groups: widget.task.unitTagGroups,
        constraint: widget.task.unitTagPrompt,
      );
      if (!mounted) return;
      setState(() {
        for (final t in tags) {
          if (!_tags.contains(t)) _tags.add(t);
          _enabledTags.add(t);
        }
      });
      if (tags.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('这行台词没有匹配到词表里的标签。')));
      } else {
        await _runSearch();
      }
    } catch (e) {
      AppLog.warn('行自动打标失败：$e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('自动打标失败，请稍后重试。')));
      }
    } finally {
      if (mounted) setState(() => _tagging = false);
    }
  }

  @override
  void dispose() {
    _search.removeListener(_onSearch);
    _search.dispose();
    _voiceoverKw.dispose();
    _descKw.dispose();
    _nameKw.dispose();
    unawaited(_preview?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg)),
      // 一屏能看到多少候选，直接决定要翻几页（197 条曾经要翻 9 页）。
      // 按屏幕比例给，大屏受益；上下限夹住，小屏不溢出、超大屏不空旷
      insetPadding: const EdgeInsets.all(AppSpacing.lg),
      child: SizedBox(
        width: (MediaQuery.sizeOf(context).width * 0.88).clamp(920.0, 1680.0),
        height: (MediaQuery.sizeOf(context).height * 0.88).clamp(660.0, 1100.0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.xl, AppSpacing.lg, AppSpacing.xl, 0),
            child: Row(children: [
              Text('给第 ${widget.lineIndex + 1} 行找镜头',
                  style: const TextStyle(
                      fontSize: AppFontSize.title,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary)),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(_line.text.trim(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: AppFontSize.caption,
                        color: AppColors.textTertiary)),
              ),
            ]),
          ),
          const SizedBox(height: AppSpacing.md),
          if ((_line.reference?.segments.length ?? 0) > 0) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
              child: _refAtomBar(),
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
            child: _searchBar(),
          ),
          const SizedBox(height: AppSpacing.sm),
          const Divider(height: 1, color: AppColors.border),
          Expanded(child: _results()),
          const Divider(height: 1, color: AppColors.border),
          _footer(),
        ]),
      ),
    );
  }

  /// 参考原子条：这一句在原片里的各个参考分镜（原子）。
  /// 点选一个原子 → 检索词切成「这个原子时段说的话」，一个原子一个
  /// 原子地找替代品；再点一下取消回到整句。原子上还能「直接用原片」
  Widget _refAtomBar() {
    final ref = _line.reference!;
    if (_preparingRef) {
      return Row(children: [
        const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 1.6)),
        const SizedBox(width: AppSpacing.sm),
        Text('正在把这一句的参考切成视觉镜头…',
            style: const TextStyle(
                fontSize: AppFontSize.caption,
                color: AppColors.textSecondary)),
      ]);
    }
    final segments = ref.segments;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.only(top: 20),
        child: Text('参考',
            style: const TextStyle(
                fontSize: AppFontSize.caption,
                color: AppColors.textTertiary)),
      ),
      const SizedBox(width: AppSpacing.sm),
      Expanded(
        child: SizedBox(
          // 参考镜是这个面板的主线索（默认就拿它去找像的画面），
          // 给它更大的地方：看得清画面才知道要复刻什么
          height: 132,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: segments.length,
            separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.xs),
            itemBuilder: (context, k) => _refAtomCard(k, segments[k]),
          ),
        ),
      ),
    ]);
  }

  Widget _refAtomCard(int k, (int, int) seg) {
    final selected = _refSeg == k;
    final playing = _previewKey == 'r$k';
    final thumb = widget.refThumbOf?.call(k);
    final meta = _line.reference!.metaAt(seg.$1);
    // 卡上显示两样东西：这一镜的**画面属性**（打过标就是描述+标签，
    // 没打过提示点一下就打）与它的 ASR 台词（**只展示**，不参与检索）
    final asr = _line.reference!.segmentText(k, '');
    final text = meta != null
        ? [
            if (meta.description.isNotEmpty) meta.description,
            if (meta.tags.isNotEmpty) meta.tags.take(4).join(' · '),
          ].join('\n')
        : (selected && _refTagging ? '正在读这一镜的画面…' : '点一下用这一镜的画面找');
    return InkWell(
      key: ValueKey('shots-ref-atom-$k'),
      onTap: () => _selectRefShot(k),
      borderRadius: BorderRadius.circular(AppRadius.sm),
      hoverColor: AppColors.hover,
      child: Container(
        width: 232,
        padding: const EdgeInsets.all(5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(
              color: selected ? AppColors.accentBlue : AppColors.border,
              width: selected ? 1.4 : 1),
          color: selected
              ? AppColors.accentBlue.withValues(alpha: 0.08)
              : Colors.transparent,
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.xs),
            child: SizedBox(
              width: 78,
              child: Stack(fit: StackFit.expand, children: [
                // 正在播这一镜时，画面就顶在这张缩略图的位置上
                if (playing && _previewVideo != null)
                  _previewVideo!
                else if (thumb != null)
                  ThumbImage(path: thumb)
                else
                  Container(
                      color: Colors.black,
                      child: const Icon(Icons.hourglass_empty,
                          size: 11, color: AppColors.textTertiary)),
                // 点这里播这一镜；点卡片其余地方仍然是「用它的画面去找」
                Align(
                  alignment: Alignment.center,
                  child: InkWell(
                    key: ValueKey('shots-ref-play-$k'),
                    onTap: () => _toggleRefPreview(k, seg),
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.45),
                          shape: BoxShape.circle),
                      child: Icon(playing ? Icons.stop : Icons.play_arrow,
                          size: 14, color: Colors.white),
                    ),
                  ),
                ),
              ]),
            ),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('第 ${k + 1} 镜 · ${_fmtS(seg.$2 - seg.$1)}',
                      style: TextStyle(
                          fontSize: AppFontSize.micro,
                          fontWeight: FontWeight.w600,
                          color: selected
                              ? AppColors.accentBlueLight
                              : AppColors.textSecondary)),
                  const SizedBox(height: 2),
                  Expanded(
                    child: Text(text,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: AppFontSize.micro,
                            height: 1.35,
                            color: meta != null
                                ? AppColors.textSecondary
                                : AppColors.textTertiary)),
                  ),
                  if (asr.isNotEmpty)
                    Tooltip(
                      message: '参考里说的话（只展示，不参与检索；'
                          '要用它搜就复制到检索框）',
                      child: Text('“$asr”',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 9,
                              color: AppColors.textTertiary
                                  .withValues(alpha: 0.8))),
                    ),
                  Row(children: [
                    InkWell(
                      key: ValueKey('shots-use-ref-$k'),
                      onTap: widget.refVideoPath == null
                          ? null
                          : () => _useRefAtom(k, seg),
                      child: const Text('直接用原片这段',
                          style: TextStyle(
                              fontSize: AppFontSize.micro,
                              fontWeight: FontWeight.w600,
                              color: AppColors.accentBlueLight)),
                    ),
                    const Spacer(),
                    // **拿这一镜的首帧去妙啊搜像的画面。**
                    //
                    // 这是复刻场景最该走的一条路：要复刻的那张画面就在手上，
                    // 直接拿它去找同类，比让 AI 先写成一句话、再拿那句话去
                    // 匹配别人写的另一句话准得多——中间那层转译不稳，同一个
                    // 镜头两次写出来的措辞不一样，搜出来的东西就不一样。
                    //
                    // 此前这个入口只长在候选卡上：手里攥着要复刻的那一帧，
                    // 却得先用文字搜一轮、从结果里挑一条差不多的，再拿它找相似
                    Tooltip(
                      message: (meta?.framePath ?? '').isEmpty
                          ? '这一镜还没打标，没有首帧图可拿去搜——先点一下这张卡'
                          : '拿这一镜的首帧去妙啊找画面像的素材',
                      // **吃掉这一下点击**：整张参考镜卡本身也是可点的
                      // （点它=用这一镜的画面描述搜）。不拦住的话，点「画面
                      // 相似」会顺带触发卡片的点击，模式又被改回「按画面
                      // 描述」——搜是按图搜了，界面却显示成另一个模式，
                      // 底下还继续提示「去点画面相似」
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: (meta?.framePath ?? '').isEmpty
                            ? null
                            : () => _searchSimilarByFrame(
                                File(meta!.framePath!),
                                '参考第 ${k + 1} 镜'),
                        key: ValueKey('shots-ref-similar-$k'),
                        child: Text('画面相似',
                            style: TextStyle(
                                fontSize: AppFontSize.micro,
                                fontWeight: FontWeight.w600,
                                color: (meta?.framePath ?? '').isEmpty
                                    ? AppColors.textTertiary
                                    : AppColors.accentBlueLight)),
                      ),
                    ),
                  ]),
                ]),
          ),
        ]),
      ),
    );
  }

  /// 点选一个参考视觉镜头：用**它的视觉条件**去搜（标签 + 画面描述）。
  /// 没打过标就按需打一次（多帧 vision，打完缓存在行上，下次免费）；
  /// 再点一次取消，回到「这句的标签 + 脚本台词」
  Future<void> _selectRefShot(int k) async {
    if (_refSeg == k) {
      setState(() {
        _refSeg = null;
        _dim = _SearchDim.voiceover;
        _voiceoverKw.text = _line.text.trim();
        _enabledTags
          ..clear()
          ..addAll(_line.tags);
        _tags
          ..clear()
          ..addAll(_line.tags);
      });
      await _runSearch();
      return;
    }
    setState(() => _refSeg = k);
    var meta = _line.reference?.metaAt(
        _line.reference!.segments[k].$1);
    if (meta == null && widget.tagRefShot != null) {
      setState(() => _refTagging = true);
      try {
        meta = await widget.tagRefShot!(k);
      } finally {
        if (mounted) setState(() => _refTagging = false);
      }
      if (!mounted || _refSeg != k) return;
      if (meta != null && _line.reference != null) {
        setState(() =>
            _line = _line.withReference(_line.reference!.withShotMeta(meta!)));
      }
      if (meta == null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('这一镜没打上标（AI 服务不可用或画面读不出来），'
                '可以直接用画面描述搜。')));
      }
    }
    if (!mounted || _refSeg != k) return;
    // 检索键换成这一镜的视觉属性：标签作约束、画面描述作检索词
    setState(() {
      _dim = _SearchDim.description;
      _descKw.text = meta?.description ?? '';
      final refTags = meta?.tags ?? const <String>[];
      _tags
        ..clear()
        ..addAll(refTags);
      _enabledTags
        ..clear()
        ..addAll(refTags);
    });
    await _loadRefTagIds();
    await _runSearch();
  }

  /// 参考镜头的标签走**视觉镜头标签组**的词表（与单元层不同一套）
  Future<void> _loadRefTagIds() async {
    if (_tags.isEmpty) return;
    try {
      final groups = await widget.services.tags.listGroups();
      final wanted = {
        for (final g in widget.task.shotTagGroups) g.id,
        for (final g in widget.task.unitTagGroups) g.id,
      };
      final ids = <String, int>{..._tagIds ?? {}};
      for (final g in groups) {
        if (!wanted.contains(g.id)) continue;
        for (final t in await widget.services.tags.listTags(g.id)) {
          ids.putIfAbsent(t.name, () => t.id);
        }
      }
      if (mounted) setState(() => _tagIds = ids);
    } catch (e) {
      AppLog.warn('参考镜头标签词表拉取失败：$e');
    }
  }

  /// 原子「直接用原片这段」：本地源镜头加入已选序列（负数占位 id，
  /// 不参与下载与防撞车——与行带上的老「用它」同一套规矩）
  void _useRefAtom(int k, (int, int) seg) {
    final video = widget.refVideoPath!;
    if (_picked.any(
        (s) => s.localSource == video && s.trimStartMs == seg.$1)) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('这段原片画面已经在已选里了。')));
      return;
    }
    setState(() => _picked.add(LineShot(
          materialId: -(seg.$1 + 1),
          name: '参考画面',
          sceneDescription: '参考片 ${_fmtS(seg.$1)}~${_fmtS(seg.$2)} 处',
          durationMs: seg.$2 - seg.$1,
          localSource: video,
          trimStartMs: seg.$1,
        )));
  }

  static String _fmtS(int ms) => '${(ms / 1000).toStringAsFixed(1)}s';

  Widget _searchBar() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // 三个检索维度（可切）；标签在下面一行，是所有维度共用的约束
      Row(children: [
        _modePill('按台词', _dim == _SearchDim.voiceover, () {
          setState(() {
            _restoreTagsFromName();
            _dim = _SearchDim.voiceover;
          });
          _runSearch();
        }, key: const ValueKey('shots-dim-voiceover')),
        const SizedBox(width: AppSpacing.xs),
        _modePill('按画面描述', _dim == _SearchDim.description, () {
          setState(() {
            _restoreTagsFromName();
            _dim = _SearchDim.description;
          });
          if (_descKw.text.trim().isNotEmpty) _runSearch();
        }, key: const ValueKey('shots-dim-description')),
        const SizedBox(width: AppSpacing.xs),
        _modePill('画面相似', _dim == _SearchDim.similar, () {
          // 已经有查询帧了就直接切回这个模式重搜——
          // 不分青红皂白提示「去点画面相似」，人明明刚点过
          if ((_similarFileKey ?? '').isNotEmpty) {
            setState(() => _dim = _SearchDim.similar);
            unawaited(_runSearch());
            return;
          }
          if (_similarFileKey == null) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('点参考镜卡上的「画面相似」，'
                    '拿那一镜的首帧去搜；也可以在下面的候选卡上点，'
                    '拿那条素材的首帧去搜。')));
            return;
          }
          setState(() {
            _restoreTagsFromName();
            _dim = _SearchDim.similar;
          });
          _runSearch();
        }, key: const ValueKey('shots-dim-similar')),
        const SizedBox(width: AppSpacing.xs),
        // 兜底：标签和描述都筛不到时，按妙啊里的文件名直接捞。
        // 切过去顺手把标签约束摘掉——都到按名字找了，还挂着标签只会
        // 继续搜不到（切回别的维度会恢复）
        _modePill('按名称', _dim == _SearchDim.name, () {
          setState(() {
            _tagsBeforeName = {..._enabledTags};
            _enabledTags.clear();
            _dim = _SearchDim.name;
          });
          if (_nameKw.text.trim().isNotEmpty) _runSearch();
        }, key: const ValueKey('shots-dim-name')),
        const Spacer(),
        if (widget.tagger != null)
          TextButton.icon(
            key: const ValueKey('shots-auto-tag'),
            onPressed: _tagging ? null : _autoTag,
            icon: _tagging
                ? const SizedBox(
                    width: 11,
                    height: 11,
                    child: CircularProgressIndicator(strokeWidth: 1.5))
                : const Icon(Icons.auto_awesome, size: 13),
            label: Text(_tagging ? '打标中…' : '自动打标',
                style: const TextStyle(fontSize: AppFontSize.caption)),
          ),
      ]),
      const SizedBox(height: AppSpacing.sm),
      switch (_dim) {
        _SearchDim.voiceover => _keywordField(
            _voiceoverKw, '这一句台词说什么，就找说同类话的分镜',
            key: const ValueKey('shots-keyword-voiceover')),
        _SearchDim.description => _keywordField(
            _descKw, '描述想要的画面，例如「厨房喷洒清洁剂」',
            key: const ValueKey('shots-keyword-desc')),
        _SearchDim.similar => _similarBar(),
        _SearchDim.name => _keywordField(
            _nameKw, '输入妙啊里的文件名，例如「滴露_植源喷雾」',
            key: const ValueKey('shots-keyword-name')),
      },
      const SizedBox(height: AppSpacing.sm),
      _constraintChips(),
    ]);
  }

  /// 找相似维度的当前查询帧说明
  Widget _similarBar() => Row(children: [
        const Icon(Icons.image_search, size: 14, color: AppColors.textTertiary),
        const SizedBox(width: AppSpacing.xs),
        Expanded(
          child: Text('以「${_similarToName ?? ''}」的首帧找相似画面',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: AppFontSize.caption,
                  color: AppColors.textSecondary)),
        ),
      ]);

  /// 标签约束条：所有维度共用。点选启停；「+ 标签」打开词表选择器
  Widget _constraintChips() {
    final error = _tagIdsError;
    return Wrap(
        spacing: AppSpacing.xs,
        runSpacing: AppSpacing.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(_tags.isEmpty ? '标签约束：不限' : '标签约束：',
              style: const TextStyle(
                  fontSize: AppFontSize.caption, color: AppColors.textTertiary)),
          for (final tag in _tags)
            FilterChip(
              key: ValueKey('shot-tag-$tag'),
              label: Text(tag,
                  style: const TextStyle(fontSize: AppFontSize.caption)),
              selected: _enabledTags.contains(tag),
              visualDensity: VisualDensity.compact,
              onSelected: (on) {
                setState(
                    () => on ? _enabledTags.add(tag) : _enabledTags.remove(tag));
                _runSearch();
              },
            ),
          ActionChip(
            key: const ValueKey('shots-pick-tags'),
            avatar: const Icon(Icons.add, size: 13),
            label: const Text('标签',
                style: TextStyle(fontSize: AppFontSize.caption)),
            visualDensity: VisualDensity.compact,
            onPressed: _pickTags,
          ),
          // 筛窄了搜不到东西时，要能一下子把约束全松开重来
          if (_enabledTags.isNotEmpty)
            InkWell(
              key: const ValueKey('shots-clear-tags'),
              onTap: () {
                setState(_enabledTags.clear);
                _runSearch();
              },
              child: const Padding(
                padding: EdgeInsets.symmetric(
                    horizontal: AppSpacing.xs, vertical: 4),
                child: Text('清空筛选',
                    style: TextStyle(
                        fontSize: AppFontSize.caption,
                        color: AppColors.accentBlueLight)),
              ),
            ),
          if (error != null)
            Text(error,
                style: const TextStyle(
                    fontSize: AppFontSize.micro, color: AppColors.orange)),
        ]);
  }

  Widget _keywordField(TextEditingController controller, String hint,
          {Key? key}) =>
      Row(children: [
        Expanded(
          child: TextEditingKeys(
            // 搜关键词要打中文，空格归输入法
            child: TextField(
              key: key,
              controller: controller,
              style: const TextStyle(fontSize: AppFontSize.body),
              decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 15),
                  hintText: hint),
              onSubmitted: (_) => _runSearch(),
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        FilledButton(
            key: const ValueKey('shots-search'),
            onPressed: _runSearch,
            child: const Text('搜索')),
      ]);

  Widget _modePill(String label, bool selected, VoidCallback onTap,
          {Key? key}) =>
      InkWell(
        key: key,
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md, vertical: AppSpacing.xs),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.accentBlue.withValues(alpha: 0.16)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            border: Border.all(
                color: selected ? AppColors.accentBlue : AppColors.border),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: AppFontSize.caption,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected
                      ? AppColors.accentBlueLight
                      : AppColors.textSecondary)),
        ),
      );

  Widget _results() {
    switch (_search.status) {
      case CandidateSearchStatus.idle:
        return const Center(
            child: Text('选好标签或写好描述，候选会出现在这里',
                style: TextStyle(
                    fontSize: AppFontSize.body,
                    color: AppColors.textTertiary)));
      case CandidateSearchStatus.loading:
        return const Center(
            child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2)));
      case CandidateSearchStatus.failed:
        return Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_search.failureMessage ?? '检索失败',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: AppFontSize.body, color: AppColors.red)),
            const SizedBox(height: AppSpacing.sm),
            OutlinedButton(
                onPressed: _search.retry, child: const Text('重试')),
          ]),
        );
      case CandidateSearchStatus.ready:
        if (_search.entries.isEmpty) {
          return const Center(
              child: Text('没有搜到候选。换个标签组合或描述再试',
                  style: TextStyle(
                      fontSize: AppFontSize.body,
                      color: AppColors.textTertiary)));
        }
        return Column(children: [
          Expanded(
            // 一屏放不下 789 条里的头一页，而底下就是分页条——不给一层
            // 淡出，人不知道这一页还能往下滚（macOS 的滚动条不动鼠标
            // 不出现，2026-09-09 设计走查）
            child: ScrollFade(
              background: AppColors.surfaceRaised,
              child: GridView.builder(
              padding: const EdgeInsets.all(AppSpacing.lg),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 152,
                mainAxisSpacing: AppSpacing.md,
                crossAxisSpacing: AppSpacing.md,
                childAspectRatio: 0.66,
              ),
              itemCount: _search.entries.length,
              itemBuilder: (context, i) => _card(_search.entries[i]),
            ),
            ),
          ),
          _pager(),
        ]);
    }
  }

  Widget _pager() {
    if (_search.pageCount <= 1) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '上一页',
            onPressed: _search.hasPrevPage ? _search.prevPage : null,
            iconSize: 14,
            icon: const Icon(Icons.chevron_left)),
        Text('${_search.page} / ${_search.pageCount} 页 · 共 ${_search.total} 条',
            style: const TextStyle(
                fontSize: AppFontSize.caption, color: AppColors.textTertiary)),
        IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '下一页',
            onPressed: _search.hasNextPage ? _search.nextPage : null,
            iconSize: 14,
            icon: const Icon(Icons.chevron_right)),
      ]),
    );
  }

  Widget _card(CandidateEntry entry) {
    final m = entry.material;
    final pickedIndex = _picked.indexWhere((s) => s.materialId == m.id);
    final picked = pickedIndex >= 0;
    final usedByLine = widget.usedBy[m.id];
    final usedElsewhere = usedByLine != null && usedByLine != widget.lineIndex;
    return InkWell(
      key: ValueKey('shot-candidate-${m.id}'),
      onTap: () => _toggle(entry),
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
              color: picked ? AppColors.accentBlue : AppColors.border,
              width: picked ? 1.5 : 1),
          color: AppColors.surfaceRaised,
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: Stack(fit: StackFit.expand, children: [
              if (_previewKey == 'c${m.id}' && _previewVideo != null)
                _previewVideo!
              else if (m.thumbnailUrl == null)
                Container(
                    color: Colors.black,
                    child: const Icon(Icons.image_not_supported_outlined,
                        size: 18, color: AppColors.textTertiary))
              else
                Image.network(m.thumbnailUrl!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Container(
                        color: Colors.black,
                        child: const Icon(Icons.broken_image_outlined,
                            size: 18, color: AppColors.textTertiary))),
              // 就地预览：点一下在这张卡上播，再点停。
              // 放正中而不是角上——四个角分别被「第N行在用」「选中序号」
              // 「找相似」「时长」占着；而且常驻（不靠悬停才露），
              // 一眼就知道这张卡能播
              Align(
                alignment: Alignment.center,
                child: InkWell(
                  key: ValueKey('shot-preview-${m.id}'),
                  onTap: () => _togglePreview(m),
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  child: Container(
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.45),
                        shape: BoxShape.circle),
                    child: Icon(
                        _previewKey == 'c${m.id}'
                            ? Icons.stop
                            : Icons.play_arrow,
                        size: 16,
                        color: Colors.white),
                  ),
                ),
              ),
              if (entry.spec != null)
                Positioned(
                  right: 4,
                  bottom: 4,
                  child: _badge(
                      '${(entry.spec!.durationMs / 1000).toStringAsFixed(1)}s',
                      Colors.black.withValues(alpha: 0.65),
                      Colors.white),
                ),
              if (usedElsewhere)
                Positioned(
                  left: 4,
                  top: 4,
                  child: _badge('第 ${usedByLine + 1} 行在用',
                      AppColors.orange.withValues(alpha: 0.85), Colors.black),
                ),
              Positioned(
                left: 4,
                bottom: 4,
                child: Tooltip(
                  message: '画面相似：拿这条的首帧去找像的',
                  child: InkWell(
                    key: ValueKey('shot-similar-${m.id}'),
                    onTap: () => _searchSimilar(entry),
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.65),
                          borderRadius: BorderRadius.circular(AppRadius.xs)),
                      child: const Icon(Icons.image_search,
                          size: 12, color: Colors.white),
                    ),
                  ),
                ),
              ),
              if (picked)
                Positioned(
                  right: 4,
                  top: 4,
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: const BoxDecoration(
                        color: AppColors.accentBlue, shape: BoxShape.circle),
                    alignment: Alignment.center,
                    child: Text('${pickedIndex + 1}',
                        style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: Colors.white)),
                  ),
                ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.all(6),
            // 两样都没有时**说出来**：留一块纯空白，人分不清是「这条没台词
            // 也没画面描述」还是「加载没出来」（2026-09-09 设计走查：
            // 一排卡片里夹着两张下面什么都没有的）
            child: Builder(builder: (context) {
              final blurb = m.voiceover.isNotEmpty
                  ? m.voiceover
                  : m.sceneDescription;
              if (blurb.isEmpty) {
                return const Text('没有台词，也还没有画面描述',
                    maxLines: 2,
                    style: TextStyle(
                        fontSize: AppFontSize.micro,
                        color: AppColors.textTertiary,
                        fontStyle: FontStyle.italic,
                        height: 1.35));
              }
              return Text(blurb,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: AppFontSize.micro,
                      color: AppColors.textSecondary,
                      height: 1.35));
            }),
          ),
        ]),
      ),
    );
  }

  Widget _badge(String text, Color bg, Color fg) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
            color: bg, borderRadius: BorderRadius.circular(AppRadius.xs)),
        child: Text(text,
            style: TextStyle(
                fontSize: AppFontSize.micro, fontWeight: FontWeight.w600, color: fg)),
      );

  void _toggle(CandidateEntry entry) {
    final m = entry.material;
    setState(() {
      final i = _picked.indexWhere((s) => s.materialId == m.id);
      if (i >= 0) {
        _picked.removeAt(i);
      } else {
        _picked.add(LineShot(
          materialId: m.id,
          name: m.name,
          voiceover: m.voiceover,
          sceneDescription: m.sceneDescription,
          thumbnailUrl: m.thumbnailUrl,
          fileKey: m.fileKey,
          durationMs: entry.spec?.durationMs,
        ));
      }
    });
  }

  Widget _footer() => Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xl, vertical: AppSpacing.md),
        child: Row(children: [
          Text(
              _picked.isEmpty
                  ? '点候选卡片挑镜头，按点选顺序排'
                  : '已选 ${_picked.length} 个镜头（按点选顺序排）',
              style: const TextStyle(
                  fontSize: AppFontSize.caption,
                  color: AppColors.textSecondary)),
          const Spacer(),
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消')),
          const SizedBox(width: AppSpacing.sm),
          FilledButton(
            key: const ValueKey('shots-confirm'),
            onPressed: () => Navigator.of(context).pop(FindShotsResult(
                shots: List<LineShot>.from(_picked),
                tags: [
                  for (final t in _tags)
                    if (_enabledTags.contains(t)) t,
                ])),
            child: const Text('用这些镜头'),
          ),
        ]),
      );
}
