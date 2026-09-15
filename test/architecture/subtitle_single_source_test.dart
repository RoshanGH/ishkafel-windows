import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **一个坑位的字幕只能有一处说了算**（见 `slot_subtitles.dart`）。
///
/// 2026-09-08 真机，用户原话：「我改了字幕以后，烧录的字幕没有变化」「调整
/// 字幕的那个根本就不生效」。属性面板读了手改轨，预览的变速切片和导出各自
/// 直接按 ASR 现算——三条路各断在不同地方，而这类错不进任何日志，只有把片子
/// 导出来看一眼才发现。
///
/// 所以盯住调用点：谁想知道「这一镜烧哪几行字」，只能问 subtitleLinesForSlot。
void main() {
  /// 允许直接调底层 subtitleLinesInSlot 的地方
  const allowed = {
    // 它自己
    'lib/core/subtitle/subtitle_overlay.dart',
    // 唯一的出口
    'lib/core/subtitle/slot_subtitles.dart',
    // 脚本成片是另一条线：那边没有原片，也就没有「手改某一镜」这回事
    'lib/core/script/script_export.dart',
  };

  test('替换裂变这条线上，没人绕过 subtitleLinesForSlot 自己算字幕', () {
    final offenders = <String>[];
    for (final file
        in Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))) {
      final path = file.path.replaceAll(r'\', '/');
      if (allowed.contains(path)) continue;
      if (file.readAsStringSync().contains('subtitleLinesInSlot(')) {
        offenders.add(path);
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          '这些地方自己按 ASR 算字幕，用户手改的那一份到不了：\n'
          '${offenders.join('\n')}\n'
          '改成 subtitleLinesForSlot(track: ..., unitIndex: ..., shotIndex: ...)',
    );
  });

  test('导出对话框把手改字幕传给了导出器', () {
    final src = File(
      'lib/features/export/export_dialog.dart',
    ).readAsStringSync();

    expect(
      RegExp(r'subtitleTrack:').allMatches(src).length,
      greaterThanOrEqualTo(2),
      reason:
          '导出有「一条」和「多条组合」两个入口，只接一个的话，'
          '另一条路上人改的字幕就丢了',
    );
  });

  test('命令行导出也传——Agent 拧得到的旋钮不能比人少', () {
    expect(
      File('lib/cli/commands/export_command.dart').readAsStringSync(),
      contains('subtitleTrack:'),
    );
  });

  test('凡是接 ASR 句子的导出入口，必须同时接手改字幕轨', () {
    // exportAll 就是这么溜过去的：它转手调 exportCombinations，两边都接了
    // subtitleSentences，唯独中间这一手把 subtitleTrack 丢了——「导出全部」
    // 这条路上人改的字幕永远不生效，而另一条路是好的，更难想到。
    final src = File('lib/core/export/export_runner.dart').readAsStringSync();
    final entries = RegExp(r'\s(export\w+)\(\{').allMatches(src);

    expect(entries, isNotEmpty, reason: '没扫到导出入口，正则该更新了');

    var checked = 0;
    for (final m in entries) {
      final end = src.indexOf('}) async {', m.start);
      if (end < 0) continue;
      final body = src.substring(m.start, end);
      if (!body.contains('subtitleSentences')) continue;
      checked++;
      expect(
        body,
        contains('subtitleTrack'),
        reason:
            '${m.group(1)} 接了 ASR 句子却没接手改字幕轨——走这条路导出的'
            '片子，人改的字幕不生效',
      );
    }
    expect(
      checked,
      greaterThanOrEqualTo(2),
      reason: '至少 exportAll 和 exportCombinations 两条路要被查到',
    );
  });

  test('预览的字幕样式跟着任务走，不能停在默认那套', () {
    // 2026-09-08 真机：「这个参数调整的还是用不了，调整参数也没有变化」。
    // 导出一直用 _task.subtitle，而预览压根没接样式，永远是
    // SubtitleStyle.standard——两边对不上，人怎么调都看不到变化。
    //
    // 2026-09-09 起预览的字幕改成画面上现画的一层（字幕不再烧进变速切片，
    // 见 `preview_subtitle_at.dart`），所以盯的是这一层接没接上。
    final src = File(
      'lib/features/workbench/workbench_page.dart',
    ).readAsStringSync();

    expect(
      src,
      contains('subtitleStyle: _task.subtitle'),
      reason: '预览的字幕层没接任务的样式，调了参数只有导出能看到',
    );
    expect(
      src,
      contains('subtitleAt: _previewSubtitleAt'),
      reason: '预览没接字幕层，替换镜头上一个字都不会出',
    );
    expect(
      File('lib/core/subtitle/preview_subtitle_at.dart').readAsStringSync(),
      contains('subtitleLinesForSlot('),
      reason: '预览自己算字幕的话，人手改的那一份到不了画面上',
    );
    expect(
      src,
      contains('track: _task.subtitleTrack'),
      reason: '同理，手改过的字幕也要进预览',
    );
  });

  test('预览的切片上不能再烧字幕——烧了就要重渲、换源、弹回片头', () {
    // 2026-09-09 用户原话：「我调整字幕样式的时候应该实时显示，而不是每次
    // 都要有一个加载的动效，然后跳转到第一帧，这个跳转太煞笔了」。
    // 字幕一旦进了变速切片的渲染入参，每动一下滑杆就是一次 ffmpeg + 换源。
    final src = File(
      'lib/features/workbench/speed_fitter.dart',
    ).readAsStringSync();

    expect(
      src.contains('subtitleOverlays'),
      isFalse,
      reason: '变速切片又开始烧字幕了，调样式会退回「转圈 + 跳回片头」',
    );
    expect(src.contains('rasterize('), isFalse, reason: '同上：切片上不该有渲字这一步');
  });
}
