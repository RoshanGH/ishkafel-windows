import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **界面上的字不许带 Markdown 记号。**
///
/// Flutter 的 `Text` 一个字不解析，`**要花钱**` 会原样显示成带星号的四个字。
/// 2026-09-15 真机走查当场看到：确认框里写着「然后**逐镜看图打标**」——
/// 一条本来是要提醒人「这一步花钱」的话，看上去像是没写完的排版。
///
/// 只管**给人看**的那些（Text / title / subtitle / description / content…）。
/// 给 Agent 的 CLI 输出、给模型的 prompt 里 Markdown 是有意义的，不在此列。
void main() {
  /// UI 参数名出现在这些位置，说明这串字是给人看的
  const uiKeys = [
    'Text(',
    'title:',
    'subtitle:',
    'description:',
    'content:',
    'label:',
    'hintText:',
    'tooltip:',
    'helperText:',
  ];

  /// 这几处的 Markdown 是**有意义的**，不在此列：
  /// - `lib/core/ai/`、`boundary_reviewer.dart`：给模型的 prompt
  /// - `lib/core/agent_skill/`：给 Agent 的手册，它读的就是 Markdown
  ///
  /// 加新的 prompt / 手册文件要加进来；**加界面文案不许往这儿加**——
  /// 那是在为了让守卫过而放行一个真问题
  bool isPromptOrDoc(String path) =>
      path.startsWith('lib/core/ai/') ||
      path.startsWith('lib/core/agent_skill/') ||
      path.endsWith('boundary_reviewer.dart');

  test('给人看的文案里没有 ** 记号', () {
    final bad = <String>[];
    // **两个目录一起扫**：只扫 features 的话，摆在界面上、算在 core 里的
    // 那几句就漏了——导出确认页那句「这 1 个单元用的是**整体替换**」在
    // subtitle_coverage.dart 里，守卫全绿而真机上星号明晃晃地显示着
    // （2026-09-16）
    for (final f in [
      ...Directory('lib/features').listSync(recursive: true),
      ...Directory('lib/core').listSync(recursive: true),
    ]
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .where((f) => !isPromptOrDoc(f.path))) {
      final lines = f.readAsStringSync().split('\n');
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        final t = line.trimLeft();
        // 注释里写 **强调** 是给读代码的人看的，不进界面
        if (t.startsWith('//') || t.startsWith('*')) continue;
        // **只看单个字符串字面量内部**，而且要含中文：
        // - 跨过引号去匹配的话，`'materials', // …**导出读这里**` 这种
        //   行尾注释会被算成文案
        // - 手机号脱敏 `138****1234` 里的星号本来就是要显示的内容
        final hasMarkdownText = RegExp(r"'([^']*)'")
            .allMatches(line)
            .map((m) => m.group(1) ?? '')
            .any((str) =>
                str.contains('**') && RegExp(r'[\u4e00-\u9fff]').hasMatch(str));
        if (!hasMarkdownText) continue;
        // 往上看几行：这串字是挂在某个 UI 参数上的吗
        final around = lines
            .sublist((i - 8).clamp(0, i), i + 1)
            .where((l) {
              final lt = l.trimLeft();
              return !lt.startsWith('//') && !lt.startsWith('*');
            })
            .join('\n');
        // features 下按「挂在 UI 参数上」判；core 下没有那些参数名，
        // 但它也不该有面向人的加粗——core 里合法的 Markdown 只有 prompt
        // 和 Agent 手册，那两类已经排除在外了
        final isCore = f.path.startsWith('lib/core/');
        if (isCore || uiKeys.any(around.contains)) {
          bad.add('${f.path}:${i + 1}  ${line.trim()}');
        }
      }
    }

    expect(bad, isEmpty,
        reason: 'Text 不解析 Markdown，这些地方会原样显示出星号：\n'
            '${bad.join('\n')}\n'
            '要强调就换句式，或者用「」，别指望加粗');
  });
}
