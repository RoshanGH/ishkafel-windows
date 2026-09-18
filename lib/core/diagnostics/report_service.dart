import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:path/path.dart' as p;
import 'report_redactor.dart';
import 'system_snapshot.dart';

class ReportFailure implements Exception {
  final String message;
  const ReportFailure(this.message);
  @override
  String toString() => message;
}

/// 本地先保存，服务端确认相同编号后才删除；请求超时后重传仍使用同一编号。
class ReportService {
  final Directory directory;
  final Directory logs;
  final String version;
  final Uri? endpoint;
  final String token;
  final String trustedCertificateBase64;
  final int maxPending;
  final Future<Map<String, Object?>> Function() probe;
  final ReportRedactor redactor;
  bool _preparing = false;
  bool _sending = false;

  ReportService({
    required this.directory,
    required this.logs,
    required this.version,
    this.endpoint,
    this.token = '',
    this.trustedCertificateBase64 = '',
    this.maxPending = 20,
    Iterable<String> secrets = const [],
    Future<Map<String, Object?>> Function()? probe,
  }) : redactor = ReportRedactor([...secrets, token]),
       probe = probe ?? collectSystemSnapshot;

  bool get configured => endpoint != null && token.isNotEmpty;

  Future<List<File>> pending() async {
    if (!await directory.exists()) return [];
    final files = await directory
        .list(followLinks: false)
        .where(
          (e) =>
              e is File &&
              RegExp(r'^[a-f0-9]{32}\.json$').hasMatch(p.basename(e.path)),
        )
        .cast<File>()
        .toList();
    files.sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  Future<File> prepare({
    String description = '',
    File? screenshot,
    String kind = 'manual',
  }) async {
    if (_preparing) throw const ReportFailure('正在收集，请稍候。');
    _preparing = true;
    try {
      if (utf8.encode(description).length > 2000) {
        throw const ReportFailure('补充说明过长，请缩短后重试。');
      }
      if ((await pending()).length >= maxPending) {
        throw const ReportFailure('待发送报告已满，请先重传已有报告。');
      }
      Map<String, String>? attachment;
      if (screenshot != null) {
        if (await screenshot.length() > 4 * 1024 * 1024) {
          throw const ReportFailure('截图请控制在 4 MB 以内。');
        }
        final bytes = await screenshot.readAsBytes();
        final png =
            bytes.length >= 8 &&
            bytes.take(8).join(',') == '137,80,78,71,13,10,26,10';
        final jpeg =
            bytes.length >= 3 &&
            bytes[0] == 255 &&
            bytes[1] == 216 &&
            bytes[2] == 255;
        if (!png && !jpeg) throw const ReportFailure('请选择 PNG 或 JPEG 截图。');
        attachment = {
          'type': png ? 'image/png' : 'image/jpeg',
          'data': base64Encode(bytes),
        };
      }
      final random = Random.secure();
      final id = List.generate(
        16,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      final text = await _readLogs();
      Map<String, Object?> system;
      try {
        system = await probe().timeout(const Duration(seconds: 35));
      } catch (_) {
        system = {'os': Platform.operatingSystem, 'probe': 'unavailable'};
      }
      final report = {
        'schema': 1,
        'id': id,
        'version': version,
        'kind': kind,
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'system': _cleanValue(system),
        'logs': redactor.clean(text),
        'description': redactor.clean(description),
        'screenshot': attachment,
      };
      final encoded = utf8.encode(jsonEncode(report));
      if (encoded.length > 8 * 1024 * 1024) {
        throw const ReportFailure('报告过大，请移除截图重试。');
      }
      await directory.create(recursive: true);
      final temp = File(p.join(directory.path, '$id.tmp'));
      await temp.writeAsBytes(encoded, flush: true);
      return await temp.rename(p.join(directory.path, '$id.json'));
    } finally {
      _preparing = false;
    }
  }

  Object? _cleanValue(Object? value) {
    if (value is String) return redactor.clean(value);
    if (value is List) return value.map(_cleanValue).toList();
    if (value is Map) {
      return value.map((k, v) => MapEntry(k.toString(), _cleanValue(v)));
    }
    return value;
  }

  Future<String> _readLogs() async {
    final buffer = StringBuffer();
    // 精确允许列表，绝不递归收集任务、凭据或任意文件。
    for (final name in [
      'ishkafel.log.3',
      'ishkafel.log.2',
      'ishkafel.log.1',
      'ishkafel.log',
      'watchdog.json',
      'watchdog.previous.json',
    ]) {
      final file = File(p.join(logs.path, name));
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        continue;
      }
      try {
        final input = await file.open();
        try {
          final length = await input.length();
          await input.setPosition(max(0, length - 160 * 1024));
          final data = await input.read(160 * 1024);
          buffer.writeln('--- $name ---');
          buffer.writeln(utf8.decode(data, allowMalformed: true));
        } finally {
          await input.close();
        }
      } on FileSystemException {
        buffer.writeln('$name: unavailable');
      }
    }
    return buffer.toString();
  }

  Future<String> send(File file) async {
    if (_sending) throw const ReportFailure('报告正在发送，请稍候。');
    _sending = true;
    HttpClient? client;
    try {
      final context = trustedCertificateBase64.isEmpty
          ? null
          : (SecurityContext(withTrustedRoots: false)
              ..setTrustedCertificatesBytes(
                base64Decode(trustedCertificateBase64),
              ));
      client = HttpClient(context: context)
        ..connectionTimeout = const Duration(seconds: 10);
      final http = client;
      final base = endpoint;
      if (!configured || base == null) {
        throw const ReportFailure('报告已保存在本地，接收服务尚未配置。');
      }
      if (base.userInfo.isNotEmpty ||
          base.hasQuery ||
          base.hasFragment ||
          (base.scheme != 'https' &&
              !(base.scheme == 'http' &&
                  ['127.0.0.1', '::1'].contains(base.host)))) {
        throw const ReportFailure('报告接收地址不安全，已保留本地报告。');
      }
      final bytes = await file.readAsBytes();
      final id = (jsonDecode(utf8.decode(bytes)) as Map)['id'];
      final uri = base.replace(
        path: '${base.path.replaceFirst(RegExp(r'/$'), '')}/v1/reports',
      );
      return await (() async {
        final request = await http.postUrl(uri);
        request.followRedirects = false;
        request.headers.contentType = ContentType.json;
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        request.contentLength = bytes.length;
        request.add(bytes);
        final response = await request.close();
        if (response.statusCode != 200 && response.statusCode != 201) {
          throw ReportFailure('发送未成功（${response.statusCode}），报告已保留，可稍后重传。');
        }
        final body = <int>[];
        await for (final chunk in response) {
          body.addAll(chunk);
          if (body.length > 16384) throw const ReportFailure('服务响应异常，报告已保留。');
        }
        final receipt = jsonDecode(utf8.decode(body));
        if (receipt is! Map ||
            receipt['id'] != id ||
            receipt['stored'] != true) {
          throw const ReportFailure('服务未确认收件，报告已保留。');
        }
        await file.delete();
        return id as String;
      })().timeout(const Duration(seconds: 45));
    } on ReportFailure {
      rethrow;
    } catch (_) {
      throw const ReportFailure('发送失败，报告已保留，请检查网络后重传。');
    } finally {
      client?.close(force: true);
      _sending = false;
    }
  }

  Future<List<String>> retryPending() async {
    final result = <String>[];
    for (final file in await pending()) {
      result.add(await send(file));
    }
    return result;
  }
}
