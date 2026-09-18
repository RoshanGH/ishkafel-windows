import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/log/app_log.dart';

import 'new_task_wizard_test.dart' as fixtures;

void main() {
  testWidgets('选择中阻止重复打开，取消后恢复入口并记录完整生命周期', (tester) async {
    final pending = Completer<String?>();
    var calls = 0;
    final lines = <String>[];
    final previousSink = AppLog.sink;
    AppLog.sink = lines.add;
    addTearDown(() => AppLog.sink = previousSink);
    await fixtures.openWizard(
      tester,
      fixtures.wrap(
        cancelPicker: () => pending.complete(null),
        picker: () {
          calls++;
          return pending.future;
        },
      ),
    );
    await tester.tap(find.byKey(const Key('wizard-line-replace')));
    await tester.pumpAndSettle();
    final card = find.byKey(const Key('wizard-pick-local-file'));
    await tester.tap(card);
    await tester.pump();
    await tester.tap(card, warnIfMissed: false);
    await tester.pump();
    expect(calls, 1);
    expect(find.textContaining('请在系统窗口中选择或取消'), findsOneWidget);
    expect(find.text('取消文件选择'), findsOneWidget);
    await tester.tap(find.text('取消文件选择'));
    await tester.pumpAndSettle();
    expect(tester.widget<InkWell>(card).onTap, isNotNull);
    expect(
      lines.any((line) => line.contains('video_picker phase=start')),
      isTrue,
    );
    expect(
      lines.any(
        (line) =>
            line.contains('video_picker phase=cancel') &&
            line.contains('elapsedMs='),
      ),
      isTrue,
    );
  });

  testWidgets('关闭向导会取消尚未返回的独立选择', (tester) async {
    final pending = Completer<String?>();
    var cancellations = 0;
    await fixtures.openWizard(
      tester,
      fixtures.wrap(
        picker: () => pending.future,
        cancelPicker: () {
          cancellations++;
          pending.complete(null);
        },
      ),
    );
    await tester.tap(find.byKey(const Key('wizard-line-replace')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('wizard-pick-local-file')));
    await tester.pump();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(cancellations, 1);
    expect(find.text('打开向导'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('选择异常后可重试，成功才显示所选文件', (tester) async {
    var calls = 0;
    await fixtures.openWizard(
      tester,
      fixtures.wrap(
        picker: () async {
          if (++calls == 1) throw StateError('picker unavailable');
          return '/videos/retry.mp4';
        },
      ),
    );
    await tester.tap(find.byKey(const Key('wizard-line-replace')));
    await tester.pumpAndSettle();
    final card = find.byKey(const Key('wizard-pick-local-file'));
    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(find.text('打开文件选择框失败，请重试。'), findsOneWidget);
    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(find.textContaining('retry.mp4'), findsOneWidget);
  });
}
