import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ui/text_editing_keys.dart';

/// **在输入框里打字时，页面级快捷键必须让路。**
///
/// 真机事故：编导台写脚本时**中文输入法打不出汉字，粘贴却可以**。
/// 根因是全页快捷键把空格绑成了「播放/暂停」——中文输入法在拼音阶段按空格
/// 是**选词上屏**，组合期间文本框并不「消费」这个空格（它没插入字符），
/// 于是被页面级快捷键抢走，拼音永远上不了屏。
void main() {
  testWidgets('输入框里按空格：进的是文本框，不是页面快捷键', (tester) async {
    var pageSpace = 0;
    final controller = TextEditingController();
    final focus = FocusNode();

    await tester.pumpWidget(MaterialApp(
      home: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.space): () => pageSpace++,
        },
        child: Scaffold(
          body: TextEditingKeys(
            child: TextField(controller: controller, focusNode: focus),
          ),
        ),
      ),
    ));

    focus.requestFocus();
    await tester.pump();
    await tester.enterText(find.byType(TextField), '你好');
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();

    expect(pageSpace, 0,
        reason: '空格被页面快捷键抢走的话，输入法的选词就永远上不了屏——'
            '人看到的是「中文根本打不出来，粘贴却可以」');
  });

  testWidgets('没有输入框时，页面快捷键照旧管用', (tester) async {
    var pageSpace = 0;
    await tester.pumpWidget(MaterialApp(
      home: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.space): () => pageSpace++,
        },
        child: const Focus(autofocus: true, child: Scaffold(body: SizedBox())),
      ),
    ));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();

    expect(pageSpace, 1, reason: '空格播放/暂停是视频工具的通行键位，不能因噎废食');
  });

  testWidgets('焦点在输入框里时 isEditableTextFocused 认得出来', (tester) async {
    final focus = FocusNode();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: TextField(focusNode: focus)),
    ));
    expect(isEditableTextFocused(), isFalse);

    focus.requestFocus();
    await tester.pump();
    expect(isEditableTextFocused(), isTrue,
        reason: '页面级快捷键靠它决定要不要让路');
  });

  test('放行表里每个键在输入框里都有自己的天职', () {
    // 空格＝选词/输入空格，←→＝光标与候选，Esc＝取消组合，
    // ⌘A/⌘Z 与 Ctrl+A/Ctrl+Z＝全选与撤销这段文字
    expect(textEditingPassthrough.keys, hasLength(10));
    expect(
        textEditingPassthrough[
            const SingleActivator(LogicalKeyboardKey.space)],
        isA<DoNothingAndStopPropagationIntent>());
    for (final activator in const [
      SingleActivator(LogicalKeyboardKey.keyA, control: true),
      SingleActivator(LogicalKeyboardKey.keyZ, control: true),
      SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true),
    ]) {
      expect(textEditingPassthrough[activator],
          isA<DoNothingAndStopPropagationIntent>(),
          reason: 'Windows 文本框必须接住 Ctrl+A/Ctrl+Z，不能冒泡成页面操作');
    }
  });
}
