import 'package:flutter/material.dart';
import '../../core/ui/text_editing_keys.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/subtitle/subtitle_edit.dart';
import '../../core/time/timecode.dart';
import '../../core/subtitle/subtitle_overlay.dart';
import 'inspector_widgets.dart';

/// 这一镜要烧上去的字幕，可以手改。
///
/// **只有换过素材的镜头才有**：没换的那些字幕烧在原片像素里，我们既读不出
/// 也不重渲，摆个编辑框只会让人以为改得动。
///
/// 为什么需要手改：字幕默认按 ASR 的**词级时间戳**切给各镜，而「哪里断句
/// 好看」是编导的判断，规则算不对——真机上「了」这个字的声音落在下一镜，
/// 于是那一镜的字幕就以一个孤零零的「了」开头。ASR 没错、切点也没错，
/// 只是没人能替编导决定这个字归哪句。
///
/// **字幕是字幕，台词是台词**：改这里不动单元的台词，打标、检索、换音色
/// 照旧用台词。
class SubtitleEditorCard extends StatefulWidget {
  /// 这一镜换过素材没有
  final bool replaced;

  /// 当前这一镜的字幕（手改过就是手改的，否则是按 ASR 算出来的那份）
  final List<SubtitleLine> lines;

  /// 是不是手改过（改过才给「改回自动」，并标出来）
  final bool edited;

  /// 这一镜的字幕**取自底片素材自己的转写**（不是原片那份 ASR）。
  ///
  /// 文案要按**实际取到没取到**说话，不能只看来源：这一镜取到了就照常
  /// 说明来源，取不到才说「没转出话来」。按来源一刀切的话，明明有字幕
  /// 却写着「没有」（2026-09-15 真机撞到）
  final bool onMaterialBase;

  /// 这一镜有多长（毫秒）。字幕的时间**存的是相对这一镜开头**的，
  /// 改时间时要靠它夹住上界——字幕不许拖出这一镜
  final int slotDurationMs;

  /// 这一镜在**成片时间轴**上的起点。
  ///
  /// 存的是相对时间，**摆给人看的是成片时间码**（`00:17.10`）——
  /// 2026-09-11 用户改的主意：「字幕时间用完整的时序帧……问了下同事
  /// 还是这个更符合使用习惯」。单元一挪位置，这两个数自己就跟着重算，
  /// 因为它是由这个起点现算出来的
  final int slotStartMs;

  /// 数帧用的帧率（原片帧率）。`00:17.10` 里的 `.10` 是第 10 帧
  final double fps;

  final ValueChanged<List<SubtitleLine>> onChanged;

  /// 清掉手改，回到按 ASR 自动算
  final VoidCallback onResetToAuto;

  const SubtitleEditorCard({
    super.key,
    required this.replaced,
    this.onMaterialBase = false,
    required this.lines,
    required this.edited,
    required this.slotDurationMs,
    required this.slotStartMs,
    required this.fps,
    required this.onChanged,
    required this.onResetToAuto,
  });

  @override
  State<SubtitleEditorCard> createState() => _SubtitleEditorCardState();
}

class _SubtitleEditorCardState extends State<SubtitleEditorCard> {
  /// 每一行一个**长期持有**的 controller。
  ///
  /// 曾经在 build 里现造（`TextEditingController(text: ...)`），中文就此打不
  /// 进去：输入法要先把拼音摆在候选区（composing）、选好字才上屏，而每敲一个
  /// 字母都会 onChanged → 父层重建 → 新 controller，候选区当场被清掉。粘贴是
  /// 一次性整段塞进来、不经过候选区，所以只有粘贴是好的——用户就是这么描述的。
  final List<TextEditingController> _controllers = [];

  /// 每一行一个焦点节点：**离开这一格才提交**。
  ///
  /// 敲字的过程中提交，等于每敲一个字重烧一次字幕——一句十来个字就是十来次
  /// ffmpeg，横幅一直在闪，而中间那些半截状态（「李」「李斯」「李斯特」…）
  /// 没有任何意义。用户原话：「我每键入一下，它都会提示那个正在烧录。
  /// 这个东西我觉得可以在我修改完光标离开的时候，你再去进行烧录会好一点。」
  final List<FocusNode> _focus = [];

  /// 每一行两个时间输入框（起、止），同样长期持有：在 build 里现造的话
  /// 打第二个字符时光标会被推到末尾
  final List<TextEditingController> _startControllers = [];
  final List<TextEditingController> _endControllers = [];
  final List<FocusNode> _startFocus = [];
  final List<FocusNode> _endFocus = [];

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(SubtitleEditorCard old) {
    super.didUpdateWidget(old);
    _sync();
  }

  /// 让 controller 的条数与内容跟上外面那份数据。
  ///
  /// **文字相同就一个字都不碰**：碰了就会把光标推到末尾、把候选区清掉。
  /// 人正在敲的那一行，走的正是「相同」这条路——他敲的字已经通过 onChanged
  /// 传出去又传回来了。
  void _sync() {
    final lines = widget.lines;
    while (_controllers.length < lines.length) {
      final i = _controllers.length;
      _controllers.add(TextEditingController());
      _focus.add(FocusNode()..addListener(() => _commitIfLeft(i)));
      _startControllers.add(TextEditingController());
      _endControllers.add(TextEditingController());
      _startFocus.add(FocusNode()..addListener(() => _commitTimeIfLeft(i, true)));
      _endFocus.add(FocusNode()..addListener(() => _commitTimeIfLeft(i, false)));
    }
    while (_controllers.length > lines.length) {
      _controllers.removeLast().dispose();
      _focus.removeLast().dispose();
      _startControllers.removeLast().dispose();
      _endControllers.removeLast().dispose();
      _startFocus.removeLast().dispose();
      _endFocus.removeLast().dispose();
    }
    for (var i = 0; i < lines.length; i++) {
      if (_controllers[i].text != lines[i].text) {
        _controllers[i].value = TextEditingValue(
          text: lines[i].text,
          selection: TextSelection.collapsed(offset: lines[i].text.length),
        );
      }
      // 时间框同理：人正在里面敲的时候不许覆盖他，只有值真的变了才刷
      _syncTime(_startControllers[i], _startFocus[i], lines[i].startMs);
      _syncTime(_endControllers[i], _endFocus[i], lines[i].endMs);
    }
  }

  /// 时间框的值跟上外面那份数据。**有焦点就不碰**——人正在这一格里敲。
  /// [ms] 是相对这一镜的，摆出去要换成成片时间码
  void _syncTime(
      TextEditingController controller, FocusNode focus, int ms) {
    if (focus.hasFocus) return;
    final text = formatTimecode(widget.slotStartMs + ms, widget.fps);
    if (controller.text == text) return;
    controller.text = text;
  }

  /// 焦点离开第 [i] 格：把框里的文字交出去。没改过就不交——白交一次等于
  /// 白烧一次
  void _commitIfLeft(int i) {
    if (i >= _focus.length || _focus[i].hasFocus) return;
    if (i >= widget.lines.length || i >= _controllers.length) return;
    final text = _controllers[i].text;
    if (text == widget.lines[i].text) return;
    widget.onChanged([
      for (var j = 0; j < widget.lines.length; j++)
        if (j == i)
          SubtitleLine(
              startMs: widget.lines[j].startMs,
              endMs: widget.lines[j].endMs,
              text: text)
        else
          widget.lines[j],
    ]);
  }

  /// 焦点离开时间格：解析、夹回合法范围、交出去。
  ///
  /// **夹的规则和时间线上拖是同一套**（见 [setSubtitleStart]）：不重叠、
  /// 可以挨着、不许出这一镜。两处各写一份的话，输出来的和拖出来的
  /// 迟早不一样
  void _commitTimeIfLeft(int i, bool isStart) {
    final focus = isStart ? _startFocus : _endFocus;
    final controllers = isStart ? _startControllers : _endControllers;
    if (i >= focus.length || focus[i].hasFocus) return;
    if (i >= widget.lines.length) return;
    // 人输的是**成片时间码**，存的是相对这一镜的毫秒，这里换算一次
    final absolute = parseTimecode(controllers[i].text, widget.fps);
    if (absolute == null) {
      // 输了个看不懂的：把原值放回去，不猜也不报错框
      _sync();
      setState(() {});
      return;
    }
    final ms = absolute - widget.slotStartMs;
    final next = isStart
        ? setSubtitleStart(widget.lines, i, ms,
            slotDurationMs: widget.slotDurationMs)
        : setSubtitleEnd(widget.lines, i, ms,
            slotDurationMs: widget.slotDurationMs);
    if (next[i] == widget.lines[i]) {
      // 夹回去之后没变（或者本来就没改）：把框里的字也纠回来，
      // 不然人看到的是他输的那个越界的数，而实际没生效
      _sync();
      setState(() {});
      return;
    }
    widget.onChanged(next);
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    for (final f in _focus) {
      f.dispose();
    }
    for (final c in [..._startControllers, ..._endControllers]) {
      c.dispose();
    }
    for (final f in [..._startFocus, ..._endFocus]) {
      f.dispose();
    }
    super.dispose();
  }

  List<SubtitleLine> get lines => widget.lines;
  bool get edited => widget.edited;
  ValueChanged<List<SubtitleLine>> get onChanged => widget.onChanged;
  VoidCallback get onResetToAuto => widget.onResetToAuto;

  @override
  Widget build(BuildContext context) {
    if (!widget.replaced) return const SizedBox.shrink();
    return inspectorCard([
      Row(children: [
        inspectorLabel('这一镜的字幕'),
        const Spacer(),
        if (edited)
          const Text('手改过',
              style: TextStyle(
                  fontSize: AppFontSize.micro, color: AppColors.accentBlue)),
      ]),
      const SizedBox(height: 4),
      Text(
          !widget.onMaterialBase
              ? '换过素材的镜头，原片的字跟着旧画面一起没了，这里的字会重新'
                  '烧上去。左边两个数是这句话在成片里的起止位置，可以直接改'
              : lines.isEmpty
                  ? '这一段的字幕取自底片素材自己的转写，而这一镜里没转出话来'
                      '（可能本来就没人说，也可能转写没成）——要字幕就在这儿'
                      '自己加，左边两个数是它在成片里的起止位置'
                  : '这一段的字幕取自底片素材自己的转写（原片那份跟这段画面'
                      '对不上）。左边两个数是这句话在成片里的起止位置，'
                      '可以直接改',
          style: const TextStyle(
              fontSize: AppFontSize.caption,
              height: 1.5,
              color: AppColors.textTertiary)),
      const SizedBox(height: AppSpacing.sm),
      for (var i = 0; i < lines.length; i++) _row(i),
      // 和属性面板别处同一句说明：`.10` 是帧号不是小数
      inspectorTimecodeLegend(widget.fps),
      const SizedBox(height: AppSpacing.xs),
      Row(children: [
        TextButton(
          key: const ValueKey('subtitle-add'),
          onPressed: _add,
          style: _compact,
          child: const Text('＋ 加一段',
              style: TextStyle(fontSize: AppFontSize.caption)),
        ),
        const Spacer(),
        // 没改过就不摆——本来就是自动的，点了没意义
        if (edited)
          TextButton(
            key: const ValueKey('subtitle-reset'),
            onPressed: onResetToAuto,
            style: _compact,
            child: const Text('改回自动',
                style: TextStyle(fontSize: AppFontSize.caption)),
          ),
      ]),
    ]);
  }

  static final _compact = TextButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
      minimumSize: Size.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap);

  Widget _row(int i) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.xs),
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          SizedBox(
            width: 148,
            child: Row(children: [
              _timeField(i, isStart: true),
              const Text('→',
                  style: TextStyle(
                      fontSize: AppFontSize.micro,
                      color: AppColors.textTertiary)),
              _timeField(i, isStart: false),
            ]),
          ),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: TextField(
              key: ValueKey('subtitle-text-$i'),
              // 长期持有的那一个，见 [_sync]。绝不在 build 里现造
              controller: _controllers[i],
              focusNode: _focus[i],
              style: const TextStyle(fontSize: AppFontSize.caption),
              decoration: const InputDecoration(
                isDense: true,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                border: OutlineInputBorder(),
              ),
              // **不在这里提交**：敲字的过程中每次提交都要重烧一遍字幕。
              // 光标离开这一格时才交（见 [_commitIfLeft]）；回车也算改完
              onSubmitted: (_) => _commitIfLeft(i),
              // 点到别处就交出焦点：既把这一格提交掉，也把空格还给播放/暂停
              onTapOutside: (_) => KeyboardHome.take(context),
            ),
          ),
          IconButton(
            key: ValueKey('subtitle-remove-$i'),
            onPressed: () => onChanged([
              for (var j = 0; j < lines.length; j++)
                if (j != i) lines[j],
            ]),
            icon: const Icon(Icons.close, size: 14),
            color: AppColors.textTertiary,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
            tooltip: '删掉这一段',
          ),
        ]),
      );

  /// 一个时间格。**成片时间码**（`分:秒.帧`），和属性面板别处、
  /// 播放器下面那个读数是同一套——人照着哪儿都能对上
  /// （2026-09-11 用户改的主意，理由是同事的使用习惯）
  Widget _timeField(int i, {required bool isStart}) => Expanded(
        child: TextField(
          key: ValueKey('subtitle-${isStart ? 'start' : 'end'}-$i'),
          controller:
              isStart ? _startControllers[i] : _endControllers[i],
          focusNode: isStart ? _startFocus[i] : _endFocus[i],
          textAlign: TextAlign.center,
          keyboardType: TextInputType.text,
          style: const TextStyle(
              fontSize: AppFontSize.micro, color: AppColors.textSecondary),
          decoration: const InputDecoration(
            isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 2, vertical: 6),
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) => _commitTimeIfLeft(i, isStart),
          onTapOutside: (_) => KeyboardHome.take(context),
        ),
      );

  /// 加一段：接在最后一段后面，长度给 1 秒。时间可以在时间线上再调
  void _add() {
    final start = lines.isEmpty ? 0 : lines.last.endMs;
    onChanged([
      ...lines,
      SubtitleLine(startMs: start, endMs: start + 1000, text: ''),
    ]);
  }


}
