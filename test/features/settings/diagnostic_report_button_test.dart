import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/diagnostics/report_service.dart';
import 'package:ishkafel/features/settings/diagnostic_report_button.dart';

void main() {
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
