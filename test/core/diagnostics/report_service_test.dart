import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/diagnostics/report_service.dart';
import 'package:ishkafel/core/diagnostics/report_redactor.dart';

void main() {
  test('JSON 和带引号的凭据字段也必须脱敏', () {
    final redactor = ReportRedactor(const []);
    for (final text in [
      '{"password":"unlisted-value","access_token": "other-value"}',
      "{'api_key': 'unlisted-value'}",
      'PASSWORD = unlisted-value',
      '{"password":"prefix,unlisted-value","authorization":"Basic other-value"}',
      r'''{"password":"prefix\"unlisted-value"}''',
      'Cookie: public=value; session=unlisted-value',
    ]) {
      final cleaned = redactor.clean(text);
      expect(cleaned, isNot(contains('unlisted-value')));
      expect(cleaned, isNot(contains('other-value')));
    }
  });
  late Directory root;
  setUp(() {
    root = Directory.systemTemp.createTempSync('report-test-');
  });
  tearDown(() {
    root.deleteSync(recursive: true);
  });

  test('自动采集日志且移除已知密钥、JWT和URL查询串', () async {
    final logs = Directory('${root.path}/logs')..createSync();
    File('${logs.path}/ishkafel.log').writeAsStringSync(
      'failed secret-value https://host/a?X-Tos-Signature=abc\n'
      'Authorization: Bearer very-private\n'
      'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.signature123',
    );
    final service = ReportService(
      directory: Directory('${root.path}/outbox'),
      logs: logs,
      version: 'test',
      secrets: ['secret-value'],
      probe: () async => {'os': 'windows'},
    );
    final file = await service.prepare();
    final raw = await file.readAsString();
    expect(raw, contains('failed'));
    for (final secret in [
      'secret-value',
      'very-private',
      'Signature=abc',
      'eyJhbGci',
    ]) {
      expect(raw, isNot(contains(secret)));
    }
    expect(jsonDecode(raw)['description'], '');
    expect(jsonDecode(raw)['screenshot'], isNull);
  });

  test('粘贴截图直接进入报告且不产生图片临时文件，拒绝超限数据', () async {
    final service = ReportService(
      directory: root,
      logs: root,
      version: 'test',
      probe: () async => {},
    );
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a9XkAAAAASUVORK5CYII=',
    );
    final file = await service.prepare(screenshotBytes: png);
    final report = jsonDecode(await file.readAsString());
    expect(report['screenshot']['type'], 'image/png');
    expect(base64Decode(report['screenshot']['data']), png);
    expect(root.listSync(), hasLength(1));
    await expectLater(
      service.prepare(screenshotBytes: List.filled(4 * 1024 * 1024 + 1, 0)),
      throwsA(isA<ReportFailure>()),
    );
    await expectLater(
      service.prepare(screenshotBytes: [1, 2, 3]),
      throwsA(isA<ReportFailure>()),
    );
  });

  test('上传失败保留原报告，成功重传后移除且编号不变', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var fail = true;
    final received = <String>[];
    server.listen((req) async {
      expect(req.headers.value('authorization'), 'Bearer submit-only');
      final data = jsonDecode(await utf8.decoder.bind(req).join());
      received.add(data['id']);
      req.response.statusCode = fail ? 503 : 201;
      req.response.write(jsonEncode({'id': data['id'], 'stored': true}));
      await req.response.close();
    });
    final service = ReportService(
      directory: Directory('${root.path}/outbox'),
      logs: Directory('${root.path}/logs'),
      version: 'test',
      endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
      token: 'submit-only',
      probe: () async => {'os': 'windows'},
    );
    final file = await service.prepare();
    await expectLater(service.send(file), throwsA(isA<ReportFailure>()));
    expect(file.existsSync(), isTrue);
    fail = false;
    final ids = await service.retryPending();
    expect(ids.single, received.first);
    expect(received.last, received.first);
    expect(file.existsSync(), isFalse);
  });

  test('拒绝远程明文HTTP与伪截图，队列满时不覆盖已有报告', () async {
    final service = ReportService(
      directory: Directory('${root.path}/outbox'),
      logs: Directory('${root.path}/logs'),
      version: 'test',
      endpoint: Uri.parse('http://example.com'),
      token: 'x',
      maxPending: 1,
      probe: () async => {},
    );
    final badImage = File('${root.path}/bad.png')
      ..writeAsStringSync('not image');
    await expectLater(
      service.prepare(screenshot: badImage),
      throwsA(isA<ReportFailure>()),
    );
    final file = await service.prepare();
    await expectLater(service.send(file), throwsA(isA<ReportFailure>()));
    await expectLater(service.prepare(), throwsA(isA<ReportFailure>()));
    expect(file.existsSync(), isTrue);
  });
}
