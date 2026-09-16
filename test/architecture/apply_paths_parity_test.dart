import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `apply plans` 有**两条路**：
///
/// - 直写：界面没开（或停在别的任务上），CLI 自己把方案落库
/// - 委派：界面正开着这条任务，请界面代为提交——**人不用挪开，
///   还能眼看着方案落进去**
///
/// 两条路做的事必须一样。直写那条会把用到的素材连同**时长**（取段全靠它）
/// 和**画面自查**（烧字、产品露出品牌）一起收下来；委派那条如果不收，
/// 就出现一个最难发现的组合：**人在旁边看着的时候，检查反而不做**——
/// 而那正是他最信任的一次。
///
/// 这是「同一个东西多处算」在这个项目里的第 N 次：取段栽过三次
/// （导出改了、剪映没改、预览没改），这次轮到 apply 的两条路。
void main() {
  final source = File('lib/cli/commands/apply_command.dart').readAsStringSync();

  /// 从源码里切出一个函数体：从它的**定义**那一行起（不是调用处），
  /// 到下一个顶层声明为止
  String bodyOf(String name) {
    // 定义在行首（调用点都有缩进），函数体到行首的 `}` 为止
    final start = source.indexOf(RegExp('^\\w[^\n]* $name\\(', multiLine: true));
    expect(start, greaterThan(0), reason: '$name 的定义没找到，测试该更新了');
    final end = source.indexOf('\n}\n', start);
    return end < 0 ? source.substring(start) : source.substring(start, end);
  }

  test('两条路都要收素材，而且走同一个入口', () {
    for (final name in ['_applyWithLock', '_applyPlansViaUi']) {
      expect(bodyOf(name), contains('gatherPickedMaterials'),
          reason: '$name 没收素材：取段会退回快进（20 秒素材塞进 0.5 秒坑位'
              '整条压缩），画面自查（烧字、产品露出品牌）一次都不跑。'
              '委派那条路恰恰是**人在旁边看着**时走的');
    }
  });

  test('那个入口本身要做画面自查——不然两条路一起漏', () {
    expect(bodyOf('gatherPickedMaterials'), contains('checkFrame'),
        reason: '收了素材却不做画面自查。烧着别家字幕、露着竞品的素材会'
            '静默进片子——那两样只有看图才发现得了');
  });

  test('收素材只有这一个入口——第二个实现迟早和第一个走散', () {
    // 底层的 collectPickedMaterials 只该在 gatherPickedMaterials 里出现一次
    expect(RegExp(r'collectPickedMaterials\(').allMatches(source).length, 1,
        reason: 'apply 里不止一处调底层的 collectPickedMaterials。'
            '两条路要共用 gatherPickedMaterials，'
            '否则改了一处忘了另一处——取段在这个项目里已经这样栽过三次');
    expect(bodyOf('gatherPickedMaterials'), contains('collectPickedMaterials'),
        reason: '那唯一一处应该在 gatherPickedMaterials 里');
  });

  test('改了替换方案就要当场推一次预览——不然人看到的还是原片', () {
    // 产品负责人 2026-09-16 真机：「选了底片，但是要切换下其他的台词语义
    // 单元才能显示出来正常的预览。」改字幕、改音轨档位、拖边界都记得推
    // 这一下，偏偏挑素材这个最主要的动作漏了。
    //
    // 删单元、调顺序那两处后面会经过 editor.replaceUnits*（进而
    // _onEditorChanged → _syncPreviewAudio）兜住；这里钉的是没有那条
    // 兜底的两处
    final page = File('lib/features/workbench/workbench_page.dart')
        .readAsStringSync();

    String bodyAfter(String marker, {int lines = 20}) {
      final at = page.indexOf(marker);
      expect(at, greaterThan(-1), reason: '$marker 挪了位置就把这条守卫一起改');
      return page.substring(at).split('\n').take(lines).join('\n');
    }

    expect(bodyAfter('Future<void> _onReplacementsChanged('),
        contains('_syncPreviewAudio()'),
        reason: '挑完素材预览要当场换上');
    expect(bodyAfter('setState(() => _replacements = replacements);', lines: 8),
        contains('_syncPreviewAudio()'),
        reason: 'Agent 把方案投影到时间线之后，预览也要跟着换');
  });
}
