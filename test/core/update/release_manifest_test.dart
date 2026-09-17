import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/update/release_manifest.dart';

/// 自动更新的第一块：**最新版是哪一版**。
///
/// 清单读错比读不到危险得多——照着一份坏清单去下载、替换，换上去的可能是
/// 个跑不起来的 app，而人只会觉得「升级把软件搞坏了」。所以宁可当作
/// 「没查到新版本」，也不拿半信半疑的东西去动人家的软件。
void main() {
  String jsonOf(Map<String, dynamic> m) => jsonEncode(m);
  final good = {
    'version': '0.1.238',
    'objectKey': 'windows/releases/ishkafel-windows-0.1.238-x64-portable.zip',
    'sha256': 'a' * 64,
    'sizeBytes': 46000000,
    'notes': 'secure update',
    'signature':
        'mI1gftw+NbFwZxkHrU0EPdFtDtLi4h9/kP91pxL5EMTwZzFi7Q8wViyLXbGYMY0x'
        'dNO3Ng8++vs/ckeGv2xWDw==',
  };
  const publicKey = '11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=';

  test('正常的清单读得进来', () {
    final m = ReleaseManifest.tryParse(jsonOf(good))!;
    expect(m.version, '0.1.238');
    expect(m.sizeBytes, 46000000);
    expect(m.notes, 'secure update');
  });

  test('固定字段顺序形成唯一签名正文', () {
    final m = ReleaseManifest.tryParse(jsonOf(good))!;
    expect(
      utf8.decode(m.signingPayload),
      '{"version":"0.1.238",'
      '"objectKey":"windows/releases/ishkafel-windows-0.1.238-x64-portable.zip",'
      '"sha256":"${'a' * 64}",'
      '"sizeBytes":46000000,'
      '"notes":"secure update"}',
    );
  });

  test('发布公钥能验过真实 Ed25519 清单签名', () async {
    final m = ReleaseManifest.tryParse(jsonOf(good))!;
    expect(await m.verifySignature(publicKey), isTrue);
  });

  test('sha、说明或公钥任一被改动，签名都必须失败', () async {
    for (final changed in [
      {...good, 'sha256': 'b' * 64},
      {...good, 'notes': 'tampered'},
    ]) {
      final m = ReleaseManifest.tryParse(jsonOf(changed))!;
      expect(await m.verifySignature(publicKey), isFalse);
    }
    final m = ReleaseManifest.tryParse(jsonOf(good))!;
    expect(
      await m.verifySignature(base64Encode(List<int>.filled(32, 7))),
      isFalse,
    );
  });

  test('缺失或损坏的签名不算可用清单', () {
    final unsigned = {...good}..remove('signature');
    expect(ReleaseManifest.tryParse(jsonOf(unsigned)), isNull);
    expect(
      ReleaseManifest.tryParse(jsonOf({...good, 'signature': 'not-base64'})),
      isNull,
    );
  });

  test('Windows 清单不能把下载指向别的平台或目录穿越', () {
    for (final key in [
      'releases/mac.zip',
      'windows/releases/../mac.zip',
      r'windows\releases\evil.zip',
    ]) {
      expect(
        ReleaseManifest.tryParse(jsonOf({...good, 'objectKey': key})),
        isNull,
      );
    }
  });

  test('sha256 不对就整份作废——它是唯一能证明包没坏的东西', () {
    for (final bad in ['', 'xyz', 'A' * 64, 'a' * 63]) {
      expect(
        ReleaseManifest.tryParse(jsonOf({...good, 'sha256': bad})),
        isNull,
        reason: '「$bad」不是合法的 sha256',
      );
    }
  });

  test('版本号、对象键、大小缺一不可', () {
    expect(
      ReleaseManifest.tryParse(jsonOf({...good, 'version': '0.1'})),
      isNull,
    );
    expect(
      ReleaseManifest.tryParse(jsonOf({...good, 'objectKey': ''})),
      isNull,
    );
    expect(ReleaseManifest.tryParse(jsonOf({...good, 'sizeBytes': 0})), isNull);
  });

  test('根本不是 JSON 也不能炸', () {
    expect(ReleaseManifest.tryParse('<html>404</html>'), isNull);
    expect(ReleaseManifest.tryParse(''), isNull);
  });

  group('版本比较：逐段比数值', () {
    test('0.1.10 比 0.1.9 新——不能按字符串比', () {
      expect(isNewerVersion('0.1.10', '0.1.9'), isTrue);
      expect(isNewerVersion('0.1.9', '0.1.10'), isFalse);
    });

    test('同一版不算新，别反复提示人升级', () {
      expect(isNewerVersion('0.1.171', '0.1.171'), isFalse);
    });

    test('大版本压小版本', () {
      expect(isNewerVersion('1.0.0', '0.9.99'), isTrue);
      expect(isNewerVersion('0.2.0', '0.1.999'), isTrue);
    });

    test('格式不对一律不提示——宁可不升，也不能升到看不懂的版本上', () {
      expect(isNewerVersion('v0.1.172', '0.1.171'), isFalse);
      expect(isNewerVersion('0.1.172-beta', '0.1.171'), isFalse);
      expect(isNewerVersion('0.1.172', ''), isFalse);
    });
  });
}
