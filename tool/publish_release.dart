// 把打好的包发上去，让所有人能一键升级。
//
//   dart run tool/publish_release.dart
//
// 做三件事：算指纹 → 传包 → 传清单。**不依赖 tosutil 之类的外部工具**：
// 用预签名 URL 直接 PUT，本机装没装命令行工具都能发。
//
// 凭据从 .secrets/ 读（和 build_macos.sh 同一套），这里用的是**可写**的那对：
//   update_tos_ak_write / update_tos_sk_write
// app 里编进去的是**只读**那对——拿它签出来的 PUT 会被服务端拒掉，
// 这正是我们要的。
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ishkafel/core/update/tos_signer.dart';

Future<int> main(List<String> args) async {
  final version = _appVersion();
  final archiveName = 'ishkafel-windows-$version-x64-portable.zip';
  final zip = File('build/dist/$archiveName');
  if (!zip.existsSync()) {
    stderr.writeln('没有 ${zip.path}——先跑 scripts/windows/package_app.ps1');
    return 1;
  }

  final signer = _signerFromSecrets();
  if (signer == null) return 1;

  final key = 'windows/releases/$archiveName';
  stdout.writeln('正在算指纹…');
  final sha = (await sha256.bind(zip.openRead()).first).toString();
  final size = zip.lengthSync();

  final manifest = const JsonEncoder.withIndent('  ').convert({
    'version': version,
    'objectKey': key,
    'sha256': sha,
    'sizeBytes': size,
    'notes': _notesOf(version),
  });

  // **先传包，后传清单**：顺序反了的话，清单已经指向新版本而包还没上去，
  // 这中间任何人点更新都会下到 404
  stdout.writeln('正在上传 ${_mb(size)}…');
  final okZip = await _put(signer, key, zip.readAsBytesSync(),
      contentType: 'application/zip');
  if (!okZip) return 1;

  stdout.writeln('正在上传清单…');
  final okManifest = await _put(
      signer, _manifestKey(), utf8.encode(manifest),
      contentType: 'application/json');
  if (!okManifest) return 1;

  stdout.writeln('\n发好了：$version');
  stdout.writeln('  包    $key  ${_mb(size)}');
  stdout.writeln('  指纹  $sha');
  stdout.writeln('  清单  ${_manifestKey()}');
  stdout.writeln('\n装了 0.1.172 以上版本的人，下次打开设置就会看到更新提示。');
  return 0;
}

String _appVersion() {
  final src = File('lib/core/app_version.dart').readAsStringSync();
  return RegExp(r"appVersion\s*=\s*'([^']+)'").firstMatch(src)!.group(1)!;
}

String _manifestKey() =>
    _readOptional('update_tos_manifest_key') ?? 'windows/latest.json';

/// 更新说明：**从 CHANGELOG 取最近若干版，不是只取这一版**。
///
/// 拿到包的人手上可能是十几版之前的——只给他看最新那一节，他看到的就是
/// 「加了诊断日志」这种末梢改动，而中间那些真正重要的（中文输入打不出来、
/// 打标丢了、自动铺一版按分镜铺）一条都看不到。人点「更新」之前要看得到
/// 的是**他跨过的全部**。
String _notesOf(String version, {int keep = 8}) {
  final lines = File('CHANGELOG.md').readAsLinesSync();
  final sections = <String, List<String>>{};
  final order = <String>[];
  String? current;
  for (final line in lines) {
    final head = RegExp(r'^## (\d+\.\d+\.\d+)\s*$').firstMatch(line.trim());
    if (head != null) {
      current = head.group(1);
      order.add(current!);
      sections[current] = [];
      continue;
    }
    if (current != null) sections[current]!.add(line);
  }
  // 从当前版本往回数 keep 版
  final from = order.indexOf(version);
  final take = from < 0 ? order.take(keep) : order.skip(from).take(keep);
  final out = <String>[];
  for (final v in take) {
    out.add('## $v');
    out.add(sections[v]!.join('\n').trim());
    out.add('');
  }
  return out.join('\n').trim();
}

String? _readOptional(String name) {
  final f = File('.secrets/$name');
  return f.existsSync() ? f.readAsStringSync().trim() : null;
}

String? _need(String name) {
  final v = _readOptional(name);
  if (v == null || v.isEmpty) {
    stderr.writeln('缺少 .secrets/$name');
    return null;
  }
  return v;
}

TosSigner? _signerFromSecrets() {
  final region = _need('update_tos_region');
  final bucket = _need('update_tos_bucket');
  final endpoint = _need('update_tos_endpoint');
  final ak = _need('update_tos_ak_write');
  final sk = _need('update_tos_sk_write');
  if ([region, bucket, endpoint, ak, sk].any((v) => v == null)) {
    stderr.writeln('\n发布需要这几个文件（可写凭据和 app 里那对只读的分开）：');
    stderr.writeln('  update_tos_region     如 cn-beijing');
    stderr.writeln('  update_tos_bucket     bucket 名');
    stderr.writeln('  update_tos_endpoint   如 tos-cn-beijing.volces.com');
    stderr.writeln('  update_tos_ak_write   可写凭据（只发布用，不进产物）');
    stderr.writeln('  update_tos_sk_write');
    return null;
  }
  return TosSigner(
      accessKey: ak!,
      secretKey: sk!,
      region: region!,
      bucket: bucket!,
      endpoint: endpoint!);
}

Future<bool> _put(TosSigner signer, String key, List<int> bytes,
    {required String contentType}) async {
  final client = HttpClient();
  try {
    final url = signer.presignPut(key, ttl: const Duration(minutes: 30));
    final req = await client.putUrl(Uri.parse(url));
    req.headers.set(HttpHeaders.contentTypeHeader, contentType);
    req.headers.set(HttpHeaders.contentLengthHeader, '${bytes.length}');
    req.add(bytes);
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode ~/ 100 != 2) {
      // 不静默：传不上去要说清是哪一步、服务端说了什么
      stderr.writeln('上传 $key 失败（HTTP ${res.statusCode}）：$body');
      return false;
    }
    return true;
  } catch (e) {
    stderr.writeln('上传 $key 失败：$e');
    return false;
  } finally {
    client.close(force: true);
  }
}

String _mb(int bytes) => '${(bytes / 1024 / 1024).toStringAsFixed(0)} MB';
