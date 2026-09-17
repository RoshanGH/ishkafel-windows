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
import 'package:cryptography/cryptography.dart';
import 'package:ishkafel/core/update/release_manifest.dart';
import 'package:ishkafel/core/update/tos_signer.dart';

Future<int> main(List<String> args) async {
  final packageDir = Directory(
    _valueAfter(args, '--package-dir') ?? 'build/dist',
  );
  final secretsDir = Directory(
    _valueAfter(args, '--secrets-dir') ?? '.secrets',
  );
  final dryRun = args.contains('--dry-run');
  final publishLegacyManifest = args.contains('--publish-legacy-manifest');
  final version = _appVersion();
  final archiveName = 'ishkafel-windows-$version-x64-portable.zip';
  final zip = File('${packageDir.path}${Platform.pathSeparator}$archiveName');
  if (!zip.existsSync()) {
    stderr.writeln('没有 ${zip.path}——先跑 scripts/windows/package_app.ps1');
    return 1;
  }

  final key = 'windows/releases/$archiveName';
  stdout.writeln('正在算指纹…');
  final sha = (await sha256.bind(zip.openRead()).first).toString();
  final size = zip.lengthSync();
  final unsigned = ReleaseManifest(
    version: version,
    objectKey: key,
    sha256: sha,
    sizeBytes: size,
    notes: _notesOf(version),
    signature: '',
  );
  final privateBase64 = _need(secretsDir, 'windows_update_signing_private_key');
  final publicBase64 = _need(secretsDir, 'windows_update_signing_public_key');
  if (privateBase64 == null || publicBase64 == null) return 1;
  final privateBytes = _decodeKey(privateBase64, 32, '发布私钥');
  final publicBytes = _decodeKey(publicBase64, 32, '发布公钥');
  if (privateBytes == null || publicBytes == null) return 1;
  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPairFromSeed(privateBytes);
  final derivedPublic = await keyPair.extractPublicKey();
  if (!_sameBytes(derivedPublic.bytes, publicBytes)) {
    stderr.writeln('发布公钥与私钥不匹配，拒绝生成清单。');
    return 1;
  }
  final signedBytes = await algorithm.sign(
    unsigned.signingPayload,
    keyPair: keyPair,
  );
  final release = ReleaseManifest(
    version: unsigned.version,
    objectKey: unsigned.objectKey,
    sha256: unsigned.sha256,
    sizeBytes: unsigned.sizeBytes,
    notes: unsigned.notes,
    signature: base64Encode(signedBytes.bytes),
  );
  if (!await release.verifySignature(publicBase64)) {
    stderr.writeln('本地回验发布清单失败，拒绝上传。');
    return 1;
  }
  final manifest = release.toTransportJson(indented: true);

  if (dryRun) {
    stdout.writeln(manifest);
    return 0;
  }

  final signer = _signerFromSecrets(secretsDir);
  if (signer == null) return 1;

  // **先传包，后传清单**：顺序反了的话，清单已经指向新版本而包还没上去，
  // 这中间任何人点更新都会下到 404
  stdout.writeln('正在上传 ${_mb(size)}…');
  final okZip = await _put(
    signer,
    key,
    zip.readAsBytesSync(),
    contentType: 'application/zip',
  );
  if (!okZip) return 1;

  final manifestKeys = <String>['windows/latest.json'];
  // 0.1.237 会拒绝没有 Authenticode 的包；只有发布了受信任代码签名包时，
  // 才能显式更新旧通道，避免旧版提示一个必然安装失败的更新。
  if (publishLegacyManifest) manifestKeys.add('latest-windows.json');
  for (final manifestKey in manifestKeys) {
    stdout.writeln('正在上传清单 $manifestKey…');
    final okManifest = await _put(
      signer,
      manifestKey,
      utf8.encode(manifest),
      contentType: 'application/json',
    );
    if (!okManifest) return 1;
  }

  stdout.writeln('\n发好了：$version');
  stdout.writeln('  包    $key  ${_mb(size)}');
  stdout.writeln('  指纹  $sha');
  stdout.writeln('  清单  ${manifestKeys.join('、')}');
  stdout.writeln('\n装了 0.1.238 以上版本的人，下次打开设置就会看到更新提示。');
  return 0;
}

String? _valueAfter(List<String> args, String option) {
  final index = args.indexOf(option);
  if (index < 0) return null;
  if (index + 1 >= args.length || args[index + 1].startsWith('--')) {
    throw ArgumentError('$option requires a value');
  }
  return args[index + 1];
}

List<int>? _decodeKey(String encoded, int length, String label) {
  try {
    final bytes = base64Decode(encoded);
    if (bytes.length == length) return bytes;
  } catch (_) {
    // 统一走下面的面向发布者错误。
  }
  stderr.writeln('$label格式不正确，应为 $length 字节的 Base64。');
  return null;
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a[i] ^ b[i];
  }
  return difference == 0;
}

String _appVersion() {
  final src = File('lib/core/app_version.dart').readAsStringSync();
  return RegExp(r"appVersion\s*=\s*'([^']+)'").firstMatch(src)!.group(1)!;
}

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

String? _readOptional(Directory secretsDir, String name) {
  final f = File('${secretsDir.path}${Platform.pathSeparator}$name');
  return f.existsSync() ? f.readAsStringSync().trim() : null;
}

String? _need(Directory secretsDir, String name) {
  final v = _readOptional(secretsDir, name);
  if (v == null || v.isEmpty) {
    stderr.writeln('缺少 ${secretsDir.path}${Platform.pathSeparator}$name');
    return null;
  }
  return v;
}

TosSigner? _signerFromSecrets(Directory secretsDir) {
  final region = _need(secretsDir, 'update_tos_region');
  final bucket = _need(secretsDir, 'update_tos_bucket');
  final endpoint = _need(secretsDir, 'update_tos_endpoint');
  final ak = _need(secretsDir, 'update_tos_ak_write');
  final sk = _need(secretsDir, 'update_tos_sk_write');
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
    endpoint: endpoint!,
  );
}

Future<bool> _put(
  TosSigner signer,
  String key,
  List<int> bytes, {
  required String contentType,
}) async {
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
