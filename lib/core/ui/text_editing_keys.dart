import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;

/// **人正在输入框里打字吗。**
///
/// 页面级快捷键必须在这种情况下让路——不拦截空格/方向键，让它们走文本编辑
/// 流程，而不是被当成播放/暂停或逐帧指令。做法：从当前 `primaryFocus` 对应的
/// Element 往上找有没有 [EditableText] 祖先（`TextField` 内部由它承载编辑）。
bool isEditableTextFocused() {
  final element = FocusManager.instance.primaryFocus?.context;
  if (element == null) return false;
  return element.findAncestorWidgetOfExactType<EditableText>() != null;
}

/// **输入框上方的按键放行表：把这些键留给文本框自己。**
///
/// 真机事故：编导台写脚本时**中文输入法打不出汉字，粘贴却可以**。
/// 根因是全页快捷键把空格绑成了「播放/暂停」——而中文输入法在拼音阶段
/// 按空格是**选词上屏**。组合期间文本框并不「消费」这个空格（它没插入
/// 字符），于是被页面级快捷键抢走，拼音永远上不了屏。
///
/// [DoNothingAndStopPropagationIntent] 让这些键**停在输入框这一层**，
/// 由它自己按系统默认行为处理，不再冒泡到页面级。
///
/// 表里每一个键在输入框里都有自己的天职：
/// - 空格：输入空格；**输入法组合时是选词**
/// - ←/→：移动光标；组合时切换候选
/// - Esc：取消输入法的组合
/// - ⌘A / ⌘Z / ⇧⌘Z：全选、撤销、重做**这段文本**，不是整个文档
const Map<ShortcutActivator, Intent> textEditingPassthrough =
    <ShortcutActivator, Intent>{
  SingleActivator(LogicalKeyboardKey.space):
      DoNothingAndStopPropagationIntent(),
  SingleActivator(LogicalKeyboardKey.arrowLeft):
      DoNothingAndStopPropagationIntent(),
  SingleActivator(LogicalKeyboardKey.arrowRight):
      DoNothingAndStopPropagationIntent(),
  SingleActivator(LogicalKeyboardKey.escape):
      DoNothingAndStopPropagationIntent(),
  SingleActivator(LogicalKeyboardKey.keyA, meta: true):
      DoNothingAndStopPropagationIntent(),
  SingleActivator(LogicalKeyboardKey.keyZ, meta: true):
      DoNothingAndStopPropagationIntent(),
  SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true):
      DoNothingAndStopPropagationIntent(),
  SingleActivator(LogicalKeyboardKey.keyA, control: true):
      DoNothingAndStopPropagationIntent(),
  SingleActivator(LogicalKeyboardKey.keyZ, control: true):
      DoNothingAndStopPropagationIntent(),
  SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true):
      DoNothingAndStopPropagationIntent(),
};

/// **页面级快捷键的落脚点。**
///
/// 输入框交出焦点之后必须有人接住。只 `unfocus()` 的话焦点落空，Flutter
/// 不知道该把按键送到哪个 `Shortcuts` 上，**空格和方向键会一起哑掉**——
/// 比原来那个「空格被当成打空格」更糟，因为整套键位都没了。
/// 2026-09-09 真机实测：点一下台词框、再点时间线，空格和 ←→ 全部无反应，
/// 一直到手动点中一个能拿焦点的控件才恢复。
///
/// 把它摆在页面的 `Shortcuts` 里面、包住整块内容；输入框的 `onTapOutside`
/// 调 [KeyboardHome.take]，焦点就从输入框回到这里，按键照旧走页面快捷键。
class KeyboardHome extends StatefulWidget {
  final Widget child;
  const KeyboardHome({super.key, required this.child});

  /// 把焦点收回页面。找不到（不在 [KeyboardHome] 里）时退回单纯失焦——
  /// 至少别把焦点继续留在输入框里
  static void take(BuildContext context) {
    final node = context.findAncestorStateOfType<_KeyboardHomeState>()?._node;
    if (node == null) {
      FocusManager.instance.primaryFocus?.unfocus();
      return;
    }
    node.requestFocus();
  }

  @override
  State<KeyboardHome> createState() => _KeyboardHomeState();
}

class _KeyboardHomeState extends State<KeyboardHome> {
  final FocusNode _node = FocusNode(debugLabel: 'KeyboardHome');

  @override
  void initState() {
    super.initState();
    // **盯着焦点，落空就接回来。**
    //
    // 光在输入框的 onTapOutside 里 requestFocus 是不够的：那一下发生在
    // pointer down，紧接着时间线自己的手势处理又会把焦点清掉，结果照样落空
    // （2026-09-09 真机：点台词框→点时间线，空格和 ←→ 全哑）。
    //
    // 所以改成盯着 FocusManager：只要页面上没有任何具体控件拿着焦点
    // （null，或者只剩一个 FocusScopeNode），就把它接回自己身上。
    // 焦点在输入框/按钮上时一概不动——那是人家的。
    FocusManager.instance.addListener(_catchDroppedFocus);
  }

  void _catchDroppedFocus() {
    if (!mounted) return;
    final current = FocusManager.instance.primaryFocus;
    if (current != null && current is! FocusScopeNode) return;
    if (identical(current, _node)) return;
    // 不在当前路由上（被弹层/别的页面盖住）时不抢：抢了会把弹层里的
    // 输入框顶掉
    if (ModalRoute.of(context)?.isCurrent != true) return;
    if (!_node.hasFocus) _node.requestFocus();
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_catchDroppedFocus);
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
        focusNode: _node,
        autofocus: true,
        // 只做落脚点，不参与 Tab 遍历；按键照旧往上冒泡到页面的 Shortcuts
        skipTraversal: true,
        child: widget.child,
      );
}

/// 把一个输入框（或一片输入区）包起来，让上面那些键归它自己。
class TextEditingKeys extends StatelessWidget {
  final Widget child;
  const TextEditingKeys({super.key, required this.child});

  @override
  Widget build(BuildContext context) =>
      Shortcuts(shortcuts: textEditingPassthrough, child: child);
}
