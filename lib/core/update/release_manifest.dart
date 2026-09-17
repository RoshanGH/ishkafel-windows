import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// 「最新版是哪一版」——放在对象存储上的一份小清单。
///
/// **它本身不带下载地址**：包是私有的，地址由 app 拿只读凭据现换预签名 URL
/// （见 `TosSigner`）。产物里 `--dart-define` 注入的 AI 凭据是明文躺在
/// 二进制里的（`strings` 一抠就有），包一旦公开读，谁都能提出来烧钱。
class ReleaseManifest {
  /// 最新版本号，如 `0.1.172`
  final String version;

  /// 包在 bucket 里的对象键，如 `releases/ishkafel-0.1.172.zip`
  final String objectKey;

  /// 整包的 sha256（小写十六进制）。**下载完必须核对**——
  /// 半截包解压出来是个坏 app，而人只会觉得「升级把软件搞坏了」
  final String sha256;

  /// 包有多大（字节）。进度条要它，也用来提前告诉人要下多少
  final int sizeBytes;

  /// 这一版改了什么——直接取 CHANGELOG 里那一节，给人看
  final String notes;

  /// 发布机对其余五个字段的 Ed25519 签名（Base64）。
  final String signature;

  const ReleaseManifest({
    required this.version,
    required this.objectKey,
    required this.sha256,
    required this.sizeBytes,
    this.notes = '',
    required this.signature,
  });

  Map<String, dynamic> get unsignedJson => {
    'version': version,
    'objectKey': objectKey,
    'sha256': sha256,
    'sizeBytes': sizeBytes,
    'notes': notes,
  };

  Map<String, dynamic> toJson() => {...unsignedJson, 'signature': signature};

  /// 签名正文只由这一处生成，避免发布端与客户端字段顺序不一致。
  List<int> get signingPayload => utf8.encode(jsonEncode(unsignedJson));

  Future<bool> verifySignature(String publicKeyBase64) async {
    try {
      final publicKeyBytes = base64Decode(publicKeyBase64);
      final signatureBytes = base64Decode(signature);
      if (publicKeyBytes.length != 32 || signatureBytes.length != 64) {
        return false;
      }
      return await Ed25519().verify(
        signingPayload,
        signature: Signature(
          signatureBytes,
          publicKey: SimplePublicKey(publicKeyBytes, type: KeyPairType.ed25519),
        ),
      );
    } catch (_) {
      return false;
    }
  }

  /// 宽松解析：**任何一处不对就返回 null**，由调用方当作「没查到新版本」。
  /// 清单读错比读不到危险得多——照着一份坏清单去下载、替换，
  /// 换上去的可能是个跑不起来的 app
  static ReleaseManifest? tryParse(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      final version = json['version'];
      final key = json['objectKey'];
      final sum = json['sha256'];
      final size = json['sizeBytes'];
      final signature = json['signature'];
      if (version is! String || !isVersion(version)) return null;
      if (key is! String ||
          !RegExp(r'^windows/releases/[A-Za-z0-9._-]+\.zip$').hasMatch(key)) {
        return null;
      }
      if (sum is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(sum)) {
        return null;
      }
      if (size is! int || size <= 0) return null;
      if (signature is! String) return null;
      try {
        if (base64Decode(signature).length != 64) return null;
      } catch (_) {
        return null;
      }
      return ReleaseManifest(
        version: version,
        objectKey: key,
        sha256: sum,
        sizeBytes: size,
        notes: json['notes'] is String ? json['notes'] as String : '',
        signature: signature,
      );
    } catch (_) {
      return null;
    }
  }

  static bool isVersion(String v) =>
      RegExp(r'^\d+\.\d+\.\d+$').hasMatch(v.trim());
}

/// `a` 比 `b` 新吗。
///
/// 只认 `主.次.修` 三段数字——版本号是排查问题时唯一的锚点，
/// 格式松一点就会出现「0.1.9 比 0.1.10 新」这种笑话（逐段比数值，不是比字符串）。
/// 任一边格式不对就返回 false：宁可不提示升级，也不能把人升到一个看不懂的版本上
bool isNewerVersion(String a, String b) {
  if (!ReleaseManifest.isVersion(a) || !ReleaseManifest.isVersion(b)) {
    return false;
  }
  final x = a.trim().split('.').map(int.parse).toList();
  final y = b.trim().split('.').map(int.parse).toList();
  for (var i = 0; i < 3; i++) {
    if (x[i] != y[i]) return x[i] > y[i];
  }
  return false;
}
