import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **「这一段画面从哪儿来」全仓只许问一次。**
///
/// 同一个问题原来在三个地方各答了一遍：预览（`TrackPlanBuilder`）、
/// 导出（`ExportPlan`）、音频（`AudioTrackBuilder`）。规则还不完全一致，
/// 而不一致的后果是画面和声音对同一个单元给出不同答案——一边有声一边黑屏，
/// 哪儿都不报错（2026-09-08 真机：「添加的台词语义单元不能正常播放」）。
///
/// 现在这三处一律走 `baseChoiceOf` / `baseOf`（见
/// `docs/superpowers/specs/2026-09-14-底片-design.md`）。这条守卫盯着：
/// 别再在它们里面直接按 `unit.hasSource` 或 `task.sourcePath` 自己判一遍。
void main() {
  /// 这三个文件回答的是同一个问题，所以必须走同一份规则
  const guarded = [
    'lib/core/playback/track_plan_builder.dart',
    'lib/core/export/export_plan.dart',
    'lib/core/audio/audio_track_builder.dart',
  ];

  /// 去掉注释和字符串字面量——文档里写 `hasSource` 是在解释，不是在判断
  String codeOnly(String src) {
    final out = StringBuffer();
    for (final line in src.split('\n')) {
      final t = line.trimLeft();
      if (t.startsWith('//') || t.startsWith('///') || t.startsWith('*')) {
        continue;
      }
      out.writeln(line.replaceAll(RegExp(r"'[^']*'"), "''"));
    }
    return out.toString();
  }

  for (final path in guarded) {
    test('$path 不自己判「有没有画面可放」，问 baseChoiceOf', () {
      final file = File(path);
      expect(file.existsSync(), isTrue, reason: '文件挪了位置就把这条守卫一起改');
      final code = codeOnly(file.readAsStringSync());

      expect(
        code,
        contains(RegExp(r'base(Choice)?Of\(')),
        reason: '这一处要回答「画面从哪儿来」，规则在 baseChoiceOf/baseOf 里',
      );
      expect(
        code.contains('.hasSource'),
        isFalse,
        reason:
            '直接读 hasSource 就是在旁边又写了一份规则；'
            '判据交给 baseChoiceOf，它已经把「任务有没有原片」和'
            '「这个单元有没有原片来源」分开了',
      );
    });
  }

  test('「镜头是不是按自己底片切的」也只有一份判据', () {
    // 这条判据决定了三件互相牵连的事：时间线画不画成一整块、预览与导出
    // 按不按镜头逐段取、声音从哪个文件剪。各写一份迟早对不上——画面按
    // 镜头拼、声音却整段取原片，人听到的和看到的是两条片子
    final dupes = <String>[];
    for (final f
        in Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))) {
      if (f.path
          .replaceAll(r'\', '/')
          .endsWith('core/replacement/unit_base.dart')) {
        continue;
      }
      final code = codeOnly(f.readAsStringSync());
      // 手写「baseCandidateId != null && shots.isNotEmpty」就是在旁边
      // 又抄了一份 hasOwnBaseShots
      if (RegExp(
        r'baseCandidateId\s*!=\s*null\s*&&[\s\S]{0,40}shots',
      ).hasMatch(code)) {
        dupes.add(f.path);
      }
    }

    expect(
      dupes,
      isEmpty,
      reason:
          '这几处自己拼了一份判据，改用 hasOwnBaseShots()：'
          '${dupes.join('、')}',
    );
  });

  test('「这条素材还有没有人用」也只有一份判据', () {
    // 少算一处，那条素材就会被当孤儿清掉。底片记在单元身上、不在方案里，
    // 正是最容易漏的那一处（2026-09-15 真机：切完分镜再挑一镜，
    // 底片被清掉，预览整段变黑而哪儿都不报错）
    final dupes = <String>[];
    for (final f
        in Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))) {
      if (f.path
          .replaceAll(r'\', '/')
          .endsWith('core/replacement/unit_base.dart')) {
        continue;
      }
      final code = codeOnly(f.readAsStringSync());
      // 手写「摊平 wholeCandidateIds + shotCandidateIds」就是在旁边
      // 又抄了一份 referencedCandidateIds
      if (RegExp(
        r'\.\.\.[a-zA-Z_.]*wholeCandidateIds[\s\S]{0,120}'
        r'shotCandidateIds\.values',
      ).hasMatch(code)) {
        dupes.add(f.path);
      }
    }

    expect(
      dupes,
      isEmpty,
      reason:
          '这几处自己摊平了一份引用集合，改用 referencedCandidateIds()：'
          '${dupes.join('、')}',
    );
  });

  test('底片的解析只有这一份实现', () {
    final impl = File('lib/core/replacement/unit_base.dart');
    expect(impl.existsSync(), isTrue);

    // 别处再定义一个同名函数就等于分叉了
    final dupes = <String>[];
    for (final f
        in Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))) {
      if (f.path
          .replaceAll(r'\', '/')
          .endsWith('core/replacement/unit_base.dart')) {
        continue;
      }
      final src = f.readAsStringSync();
      if (src.contains('BaseChoice baseChoiceOf(') ||
          src.contains('UnitBase? baseOf(')) {
        dupes.add(f.path);
      }
    }

    expect(dupes, isEmpty, reason: '底片规则出现了第二份实现：${dupes.join('、')}');
  });
}
