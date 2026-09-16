import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/audio/bgm_library.dart';
import '../../core/audio/bgm_plan.dart';
import '../../core/ffmpeg/process_runner.dart';
import '../../core/log/app_log.dart';
import '../../core/miaoa/miaoa_exception.dart';
import 'bgm_audition.dart';

/// 音频库检索入口（缺省走真实 miaoa CLI；测试注入假实现）
final bgmLibraryProvider = Provider<BgmLibrary>((ref) => BgmLibrary());

/// 把一首配乐取到**这个任务名下**，返回本地路径。
///
/// 带 taskId 的理由同 [materialFetcherProvider]：物料按项目存，
/// 删任务时一起走。为 null 表示这台机器上没接（测试环境）。
final bgmFetcherProvider =
    Provider<Future<String> Function(String taskId, BgmMaterial)?>(
        (ref) => null);

/// 用户在配乐选择面板里的决定
sealed class BgmChoice {
  const BgmChoice();
}

/// 用这几首（**互为备选**，导出时轮流用），音量压到 [volume]
class BgmPicked extends BgmChoice {
  final List<BgmMaterial> materials;

  /// 这一段管第几句到第几句（0 起，闭区间）。null = 范围不变。
  /// 只有编导台会用：整片被若干刀切成连续段，想把中间几句换首曲子，
  /// 与其「切一刀、再切一刀、再选曲」，不如直接把范围改掉
  final (int, int)? range;

  /// 预览播的是第几首。预览只能放一个，导出会把备选都用上
  final int previewIndex;
  final double volume;

  const BgmPicked(
    this.materials, {
    this.range,
    this.previewIndex = 0,
    this.volume = BgmSegment.defaultVolume,
  });
}

/// 曲子不换，只改音量
class BgmVolumeChanged extends BgmChoice {
  final double volume;
  const BgmVolumeChanged(this.volume);
}

/// 这一段不要配乐了
class BgmCleared extends BgmChoice {
  const BgmCleared();
}

/// 给一段镜头挑配乐。
///
/// [rangeMs] 是这段镜头的总时长——列表里每条都要当场算出「会裁掉多少/ 要
/// 循环几遍」，用户才不必自己拿计算器比对时长。
Future<BgmChoice?> showBgmPicker(
  BuildContext context, {
  required int rangeMs,
  required String rangeLabel,
  bool canClear = false,
  List<int> projectIds = const [],
  double initialVolume = BgmSegment.defaultVolume,
  List<BgmMaterial> initialMaterials = const [],
  int initialPreviewIndex = 0,

  /// 这一段当前管第几句到第几句（0 起，闭区间）。给了就在面板顶部
  /// 摆出范围调整——改完连同选曲一起返回
  (int, int)? range,

  /// 整片共几句（范围调整的上界）
  int lineCount = 0,

  /// 只能选一首。
  ///
  /// 替换裂变那条线一个任务要导出好几条片子、每条配不同的曲子，所以那边
  /// 是多选（选中的都会用上）。**编导台是一条片子**，一段配乐就只有一首，
  /// 多选出来的其余几首根本不会被用到——摆出来只会让人以为都生效了
  bool singleSelect = false,
}) =>
    showDialog<BgmChoice>(
      context: context,
      builder: (_) => _BgmPickerDialog(
        rangeMs: rangeMs,
        rangeLabel: rangeLabel,
        canClear: canClear,
        singleSelect: singleSelect,
        range: range,
        lineCount: lineCount,
        projectIds: projectIds,
        initialVolume: initialVolume,
        initialMaterials: initialMaterials,
        initialPreviewIndex: initialPreviewIndex,
      ),
    );

class _BgmPickerDialog extends ConsumerStatefulWidget {
  final int rangeMs;
  final String rangeLabel;

  /// 检索限定在哪些项目内；空表示不限项目
  final List<int> projectIds;
  final bool canClear;

  /// 只能选一首（编导台是一条片子，一段配乐就一首曲子）
  final bool singleSelect;

  /// 这一段管第几句到第几句；null = 不给改
  final (int, int)? range;
  final int lineCount;

  /// 这一段当前的音量。改这一段时带进来，用户看到的是现在的值而不是默认值
  final double initialVolume;

  /// 这一段已经选了哪几首、预览的是第几首
  final List<BgmMaterial> initialMaterials;
  final int initialPreviewIndex;

  const _BgmPickerDialog({
    required this.rangeMs,
    required this.rangeLabel,
    required this.initialVolume,
    this.initialMaterials = const [],
    this.initialPreviewIndex = 0,
    required this.canClear,
    this.singleSelect = false,
    this.range,
    this.lineCount = 0,
    this.projectIds = const [],
  });

  @override
  ConsumerState<_BgmPickerDialog> createState() => _BgmPickerDialogState();
}

class _BgmPickerDialogState extends ConsumerState<_BgmPickerDialog> {
  final _keyword = TextEditingController();
  BgmSearchPage? _page;
  String? _error;
  // 在 initState 里就建好：`late final` 会拖到第一次用才初始化，而搜索出错
  // 或库里为空时压根不会走到列表，等 dispose 再去 ref.read 已经太晚了
  late final BgmAudition _audition;
  late double _volume = widget.initialVolume;

  /// 已选的备选（有序——导出时按这个顺序轮流用）
  late final List<BgmMaterial> _picked =
      List<BgmMaterial>.from(widget.initialMaterials);
  late int _previewIndex = widget.initialPreviewIndex;

  /// 这一段管第几句到第几句（0 起，闭区间）
  late (int, int)? _range = widget.range;

  /// 「这段配乐管第几句到第几句」——想把中间几句换首曲子，直接在这里
  /// 把范围改掉就行，不用先切两刀再选曲
  Widget _rangeRow() {
    final (start, end) = _range!;
    final total = widget.lineCount;
    Widget picker(String label, int value, void Function(int) onPick) =>
        Row(mainAxisSize: MainAxisSize.min, children: [
          Text(label,
              style: const TextStyle(
                  fontSize: AppFontSize.caption,
                  color: AppColors.textSecondary)),
          const SizedBox(width: 4),
          DropdownButton<int>(
            key: Key('bgm-range-$label'),
            value: value,
            isDense: true,
            underline: const SizedBox.shrink(),
            style: const TextStyle(
                fontSize: AppFontSize.caption, color: AppColors.textPrimary),
            dropdownColor: AppColors.surfaceCard,
            items: [
              for (var i = 0; i < total; i++)
                DropdownMenuItem(value: i, child: Text('第 ${i + 1} 句')),
            ],
            onChanged: (v) => v == null ? null : setState(() => onPick(v)),
          ),
        ]);
    return Row(children: [
      picker('从', start, (v) {
        _range = (v, v > end ? v : end);
      }),
      const SizedBox(width: AppSpacing.sm),
      picker('到', end, (v) {
        _range = (v < start ? v : start, v);
      }),
      const SizedBox(width: AppSpacing.sm),
      const Expanded(
        child: Text('改了范围，相邻几段会跟着让位',
            style: TextStyle(
                fontSize: AppFontSize.micro, color: AppColors.textTertiary)),
      ),
    ]);
  }

  void _toggle(BgmMaterial m) {
    setState(() {
      final at = _picked.indexWhere((x) => x.id == m.id);
      if (at >= 0) {
        _picked.removeAt(at);
        // 删掉的正好是预览那首、或排在它前面：预览下标要跟着挪
        if (_previewIndex >= _picked.length) {
          _previewIndex = 0;
        } else if (at < _previewIndex) {
          _previewIndex--;
        }
      } else if (widget.singleSelect) {
        // 单选：换一首就是换掉，不做备选队列
        _picked
          ..clear()
          ..add(m);
        _previewIndex = 0;
      } else {
        _picked.add(m);
      }
    });
  }

  /// 每次检索领一个代次号：用户敲得快时慢到的旧结果不能覆盖新的
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _audition = BgmAudition(createPlayer: ref.read(auditionPlayerFactoryProvider));
    _search();
  }

  @override
  void dispose() {
    // 先收播放器再拆自己：反过来的话浮层已经关了，那条歌还在响
    unawaited(_audition.shutdown());
    _audition.dispose();
    _keyword.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final generation = ++_generation;
    setState(() {
      _page = null;
      _error = null;
    });
    try {
      final page =
          await ref.read(bgmLibraryProvider)
              .search(keyword: _keyword.text, projectIds: widget.projectIds);
      if (!mounted || generation != _generation) return;
      setState(() => _page = page);
    } catch (e) {
      if (!mounted || generation != _generation) return;
      AppLog.warn('音频库检索失败：$e');
      setState(() => _error = switch (e) {
            MediaToolMissingException(:final message) => message,
            MiaoaException(:final message) => message,
            _ => '音频库检索失败，请稍后重试；若反复出现，请把日志提供给维护者。',
          });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        backgroundColor: AppColors.surfaceRaised,
        title: Text('为 ${widget.rangeLabel} 选配乐'),
        content: SizedBox(
          width: 560,
          height: 460,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('这一段共 ${_seconds(widget.rangeMs)}',
                  style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: AppFontSize.caption)),
              if (_range != null) ...[
                const SizedBox(height: AppSpacing.sm),
                _rangeRow(),
              ],
              const SizedBox(height: AppSpacing.sm),
              TextField(
                key: const Key('bgm-search'),
                controller: _keyword,
                onSubmitted: (_) => _search(),
                style: const TextStyle(
                    color: AppColors.textPrimary, fontSize: AppFontSize.body),
                decoration: const InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: AppColors.surface,
                  border: OutlineInputBorder(),
                  hintText: '搜音频库（留空列出全部），回车检索',
                  hintStyle: TextStyle(
                      color: AppColors.textTertiary,
                      fontSize: AppFontSize.caption),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              _multiHint(),
              _pickedStrip(),
              Expanded(child: _body()),
              _VolumeRow(
                value: _volume,
                onChanged: (v) => setState(() => _volume = v),
              ),
            ],
          ),
        ),
        actions: [
          // 曲子不换、只把音量改了的情形要有出口，否则用户被迫重选一遍
          if (widget.canClear &&
              _volume != widget.initialVolume &&
              _picked.isEmpty)
            TextButton(
              key: const Key('bgm-apply-volume'),
              onPressed: () =>
                  Navigator.of(context).pop(BgmVolumeChanged(_volume)),
              child: const Text('应用音量'),
            ),
          if (widget.canClear)
            TextButton(
              key: const Key('bgm-clear'),
              onPressed: () =>
                  Navigator.of(context).pop(const BgmCleared()),
              child: const Text('移除这段配乐'),
            ),
          TextButton(
            key: const Key('bgm-cancel'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          // 多选之后要有确认出口：点一首只是勾上，不再直接关掉浮层
          FilledButton(
            key: const Key('bgm-confirm'),
            onPressed: _picked.isEmpty
                ? null
                : () => Navigator.of(context).pop(BgmPicked(
                      List.unmodifiable(_picked),
                      range: _range,
                      previewIndex: _previewIndex,
                      volume: _volume,
                    )),
            // 没选时写「至少选一首」而不是「选一首」——后者读起来像
            // 「只能选一首」，而这条线本来就是多选的
            child: Text(widget.singleSelect
                ? (_picked.isEmpty ? '先选一首' : '用这一首')
                : _picked.isEmpty
                ? '至少选一首'
                : '用这 ${_picked.length} 首'),
          ),
        ],
      );

  /// 「这一段可以选好几首」——**常驻**在列表上面，不是等选到第二首才说。
  ///
  /// 人是在选第二首**之前**需要知道这件事的。2026-09-14 真机：用户以为
  /// 「现在只能选一个」，而多选一直是通的——他只是没有任何地方被告知。
  /// 单选那条线（编导台）不出现这句。
  Widget _multiHint() {
    if (widget.singleSelect) return const SizedBox.shrink();
    return Padding(
      key: const Key('bgm-multi-hint'),
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Text(
        _picked.isEmpty
            ? '可以选好几首互为备选：导出多条时按次序轮流用，标 ★ 的那首用于预览'
            : '还可以再选：导出多条时按次序轮流用，标 ★ 的那首用于预览',
        style: const TextStyle(
            color: AppColors.textTertiary,
            fontSize: AppFontSize.micro,
            height: 1.5),
      ),
    );
  }

  /// 「已选」条：选了哪几首一直摆在列表上面。
  ///
  /// 和候选素材那边是同一个问题——列表一长就得往下滚，改个关键词整页结果
  /// 还会换掉，选过的那几首立刻看不见了。用户原话：「BGM 如果数量多的话，
  /// 比如说我选的是两三页以后的东西，我还是不知道」。
  Widget _pickedStrip() {
    if (_picked.isEmpty) return const SizedBox.shrink();
    return Padding(
      key: const Key('bgm-picked-strip'),
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            // 只报数：「轮流用」那句解释在上面那条常驻提示里，
            // 两处都说等于把同一句话摆两遍
            '已选 ${_picked.length} 首',
            style: const TextStyle(
                color: AppColors.textTertiary, fontSize: AppFontSize.micro),
          ),
          const SizedBox(height: AppSpacing.xs),
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: [
              for (var i = 0; i < _picked.length; i++) _pickedChip(i),
            ],
          ),
        ],
      ),
    );
  }

  Widget _pickedChip(int index) {
    final material = _picked[index];
    final isPreview = index == _previewIndex;
    return Container(
      key: Key('bgm-picked-${material.id}'),
      constraints: const BoxConstraints(maxWidth: 260),
      padding: const EdgeInsets.only(left: AppSpacing.xs),
      decoration: BoxDecoration(
        color: AppColors.accentBlue.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.accentBlue.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${index + 1}',
              style: const TextStyle(
                  color: AppColors.accentBlue,
                  fontSize: AppFontSize.micro,
                  fontWeight: FontWeight.w700)),
          const SizedBox(width: AppSpacing.xs),
          Flexible(
            child: Text(material.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: AppFontSize.micro)),
          ),
          IconButton(
            key: Key('bgm-picked-preview-${material.id}'),
            onPressed: () => setState(() => _previewIndex = index),
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.all(3),
            constraints: const BoxConstraints(),
            tooltip: isPreview ? '预览播的就是这一首' : '设为预览版',
            icon: Icon(isPreview ? Icons.star : Icons.star_border,
                size: 13,
                color: isPreview ? AppColors.orange : AppColors.textSecondary),
          ),
          IconButton(
            key: Key('bgm-picked-remove-${material.id}'),
            onPressed: () => _toggle(material),
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.all(3),
            constraints: const BoxConstraints(),
            tooltip: '取消选择',
            icon: const Icon(Icons.close,
                size: 13, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_error case final e?) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(e,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: AppColors.red, fontSize: AppFontSize.body)),
            const SizedBox(height: AppSpacing.sm),
            TextButton(
                key: const Key('bgm-retry'),
                onPressed: _search,
                child: const Text('重试')),
          ],
        ),
      );
    }
    final page = _page;
    if (page == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final items = page.items;
    if (items.isEmpty) {
      return const Center(
        child: Text('音频库里没有匹配的内容',
            style: TextStyle(
                color: AppColors.textTertiary, fontSize: AppFontSize.body)),
      );
    }
    final list = ListView.separated(
      itemCount: items.length,
      separatorBuilder: (_, _) =>
          const Divider(height: 1, color: AppColors.border),
      itemBuilder: (_, i) {
        final at = _picked.indexWhere((x) => x.id == items[i].id);
        return _Row(
          material: items[i],
          rangeMs: widget.rangeMs,
          audition: _audition,
          // 选中的显示排号（1、2、3…）——那就是导出时轮流用的次序
          pickedOrder: at < 0 ? null : at + 1,
          isPreview: at >= 0 && at == _previewIndex,
          onTap: () => _toggle(items[i]),
          onSetPreview:
              at < 0 ? null : () => setState(() => _previewIndex = at),
          singleSelect: widget.singleSelect,
        );
      },
    );
    if (!page.widenedFromProject) return list;
    // 不说明的话，用户会把这些曲子当成本项目的
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          key: Key('bgm-widened'),
          padding: EdgeInsets.only(bottom: AppSpacing.xs),
          child: Text('本项目下没有音频素材，已展开到全部音频库',
              style: TextStyle(
                  color: AppColors.textTertiary,
                  fontSize: AppFontSize.caption)),
        ),
        Expanded(child: list),
      ],
    );
  }
}

/// 配乐音量：**每段独立**。用户在不同段铺不同曲子，有的本来就响、有的很闷，
/// 一个全局值必然有一段不合适。
class _VolumeRow extends StatelessWidget {
  final double value;
  final ValueChanged<double> onChanged;

  const _VolumeRow({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: AppSpacing.sm),
        child: Row(
          children: [
            const Icon(Icons.volume_up_outlined,
                size: 14, color: AppColors.textSecondary),
            const SizedBox(width: AppSpacing.xs),
            const Text('配乐音量',
                style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: AppFontSize.caption)),
            Expanded(
              child: Slider(
                key: const Key('bgm-volume'),
                value: value,
                // 上限就是原始音量：垫乐压过口播是最常见的翻车方式，
                // 给到 200% 只会让人更容易做错
                max: 1,
                divisions: 20,
                activeColor: AppColors.accentBlue,
                onChanged: onChanged,
              ),
            ),
            SizedBox(
              width: 40,
              child: Text('${(value * 100).round()}%',
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: AppFontSize.caption)),
            ),
          ],
        ),
      );
}

class _Row extends StatelessWidget {
  final BgmMaterial material;
  final int rangeMs;
  final BgmAudition audition;

  /// 已选中时是第几个（1 起）。这个次序就是导出时轮流用的次序
  final int? pickedOrder;

  /// 是不是这一段的预览版——预览只能放一首
  final bool isPreview;

  final VoidCallback onTap;

  /// 把这一首设为预览版；未选中时为 null
  final VoidCallback? onSetPreview;

  /// 这一段只能选一首（编导台）。决定行首画圆点还是方框
  final bool singleSelect;

  const _Row(
      {required this.material,
      required this.rangeMs,
      required this.audition,
      required this.onTap,
      this.pickedOrder,
      this.isPreview = false,
      this.onSetPreview,
      this.singleSelect = false});

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: audition,
        builder: (context, _) => _row(context),
      );

  Widget _row(BuildContext context) {
    final fit = BgmPlan.fitFor(
        materialDurationMs: material.durationMs, rangeMs: rangeMs);
    final playing = audition.playingId == material.id;
    final picked = pickedOrder != null;
    return InkWell(
      key: Key('bgm-item-${material.id}'),
      onTap: onTap,
      child: Container(
        color: picked
            ? AppColors.accentBlue.withValues(alpha: 0.10)
            : Colors.transparent,
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm, vertical: AppSpacing.sm),
        child: Row(
          children: [
            // 选中的显示排号——那就是导出时轮流用的次序
            SizedBox(
              width: 20,
              child: picked
                  ? Text('$pickedOrder',
                      key: Key('bgm-order-${material.id}'),
                      style: const TextStyle(
                          color: AppColors.accentBlue,
                          fontSize: AppFontSize.caption,
                          fontWeight: FontWeight.w600))
                  // **多选用方框、单选才用圆点**：空心圆是 radio 的语言，
                  // 人一看就以为只能选一首（2026-09-14 真机：用户以为
                  // 「现在只能选一个」，其实多选一直是通的）
                  : Icon(
                      singleSelect
                          ? Icons.radio_button_unchecked
                          : Icons.check_box_outline_blank,
                      size: 14,
                      color: AppColors.textTertiary),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(material.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: AppFontSize.body)),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(
                          material.durationMs == 0
                              ? '时长未知'
                              : _seconds(material.durationMs),
                          style: const TextStyle(
                              color: AppColors.textTertiary,
                              fontSize: AppFontSize.caption)),
                      const SizedBox(width: AppSpacing.sm),
                      Text(fit.label,
                          style: TextStyle(
                              color: fit == BgmFit.exact
                                  ? AppColors.green
                                  : AppColors.textSecondary,
                              fontSize: AppFontSize.caption)),
                      // 带解说的音频压在成片下面会和原片口播直接打架，
                      // 必须在选之前就说清楚，不能让用户听一遍才发现
                      if (material.hasSpeech) ...[
                        const SizedBox(width: AppSpacing.sm),
                        Container(
                          key: Key('bgm-speech-${material.id}'),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: AppColors.orange.withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(AppRadius.xs),
                          ),
                          child: const Text('含人声',
                              style: TextStyle(
                                  color: AppColors.orange,
                                  fontSize: AppFontSize.micro)),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            // 光看名字和时长挑不出配乐：轻快到什么程度、压在口播下面吵不吵，
            // 只能听
            // 预览只能放一首：选中之后才谈得上「哪一首用来预览」
            if (picked)
              IconButton(
                key: Key('bgm-preview-${material.id}'),
                tooltip: isPreview ? '预览播的就是这一首' : '设为预览版',
                onPressed: onSetPreview,
                icon: Icon(isPreview ? Icons.star : Icons.star_border,
                    size: 18),
                color:
                    isPreview ? AppColors.orange : AppColors.textTertiary,
              ),
            IconButton(
              key: Key('bgm-play-${material.id}'),
              tooltip: playing ? '停止试听' : '试听',
              onPressed: () => audition.toggle(material),
              icon: Icon(
                  playing ? Icons.stop_circle_outlined : Icons.play_circle_outline,
                  size: 22),
              color: playing ? AppColors.accentBlue : AppColors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}

String _seconds(int ms) => '${(ms / 1000).toStringAsFixed(1)}s';
