import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/diagnostics/report_service.dart';
import 'package:ishkafel/features/settings/diagnostic_report_button.dart';

void main() {
  testWidgets('Ctrl+V 在输入框显示截图预览，允许删除且不需要上传按钮', (tester) async {
    final root = Directory.systemTemp.createTempSync('report-paste-');
    addTearDown(() => root.deleteSync(recursive: true));
    const channel = MethodChannel('ishkafel/clipboard');
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a9XkAAAAASUVORK5CYII=',
    );
    final reading = Completer<List<int>>();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => reading.future,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          reportServiceProvider.overrideWithValue(
            ReportService(directory: root, logs: root, version: 'test'),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: DiagnosticReportButton()),
        ),
      ),
    );
    await tester.tap(find.text('提交诊断报告'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TextField));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '提交报告'))
          .onPressed,
      isNull,
    );
    reading.complete(png);
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('附加截图（选填）'), findsNothing);
    await tester.tap(find.byTooltip('移除截图'));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNothing);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => null,
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async =>
          call.method == 'Clipboard.getData' ? {'text': '普通文字'} : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '普通文字',
    );
  });

  testWidgets('无需描述截图即可提交，收件后显示编号', (tester) async {
    final previous = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() {
      HttpOverrides.global = previous;
    });
    final root = Directory.systemTemp.createTempSync('report-ui-');
    final server = (await tester.runAsync(
      () => HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    ))!;
    addTearDown(() async {
      await server.close(force: true);
      root.deleteSync(recursive: true);
    });
    String? id;
    Map? received;
    await tester.runAsync(() async {
      server.listen((req) async {
        final data = jsonDecode(await utf8.decoder.bind(req).join());
        received = data;
        id = data['id'];
        req.response.statusCode = 201;
        req.response.write(jsonEncode({'id': id, 'stored': true}));
        await req.response.close();
      });
    });
    final service = ReportService(
      directory: root,
      logs: Directory('${root.path}/logs'),
      version: 'test',
      endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
      token: 'test-submit',
      probe: () async => {},
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [reportServiceProvider.overrideWithValue(service)],
        child: const MaterialApp(
          home: Scaffold(body: DiagnosticReportButton()),
        ),
      ),
    );
    await tester.tap(find.text('提交诊断报告'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('提交报告'));
      for (var i = 0; i < 100 && id == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(id, isNotNull);
    expect(received?['description'], '');
    expect(received?['screenshot'], isNull);
    expect(find.textContaining('报告已提交'), findsOneWidget);
  });
}
