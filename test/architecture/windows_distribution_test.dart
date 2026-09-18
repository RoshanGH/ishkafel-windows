import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String script;
  late String manifest;

  setUpAll(() {
    script = File('scripts/windows/package_app.ps1').readAsStringSync();
    manifest = File('packaging/windows/AppxManifest.xml.in').readAsStringSync();
  });

  test('Windows 分发只能从完整 Release 目录打包', () {
    expect(script, contains('build_app.ps1'));
    final buildScript = File(
      'scripts/windows/build_app.ps1',
    ).readAsStringSync();
    expect(
      buildScript,
      isNot(contains("'prepare_media_tools.ps1')\n    if (\$LASTEXITCODE")),
      reason: '调用 PowerShell 脚本不会可靠更新 LASTEXITCODE，成功也可能被误判为失败',
    );
    expect(buildScript, contains('UPDATE_TOS_MANIFEST_KEY'));
    expect(buildScript, contains('windows/latest.json'));
    for (final required in [
      'ishkafel.exe',
      'ishkafel_renderer.exe',
      r'cli\bin\ishkafel.exe',
      r'tools\ffmpeg.exe',
      r'tools\ffprobe.exe',
      r'licenses\ffmpeg\LICENSE.txt',
    ]) {
      expect(script, contains(required), reason: '安装包缺少 $required 不能放行');
    }
  });

  test('Windows 发布通道与 Mac 隔离，且发布的是可回滚便携包', () {
    final publisher = File('tool/publish_release.dart').readAsStringSync();
    final config = File(
      'lib/core/update/update_config.dart',
    ).readAsStringSync();
    expect(publisher, contains('windows/latest.json'));
    expect(publisher, contains('windows/releases/'));
    expect(publisher, contains('x64-portable.zip'));
    expect(
      publisher,
      isNot(contains("File('build/dist/ishkafel-\$version.zip')")),
    );
    expect(config, contains("defaultValue: 'windows/latest.json'"));
  });

  test('员工包只注入发布公钥，发布私钥只由发布工具读取', () {
    final build = File('scripts/windows/build_app.ps1').readAsStringSync();
    final publisher = File('tool/publish_release.dart').readAsStringSync();
    expect(build, contains('windows_update_signing_public_key'));
    expect(build, contains('UPDATE_SIGNING_PUBLIC_KEY'));
    expect(build, isNot(contains('windows_update_signing_private_key')));
    expect(publisher, contains('windows_update_signing_private_key'));
    expect(publisher, contains('Ed25519'));
    expect(publisher, contains('signature:'));
  });

  test('发布先传版本包再写稳定清单；旧版清单必须显式开启', () {
    final publisher = File('tool/publish_release.dart').readAsStringSync();
    expect(publisher, contains("'windows/latest.json'"));
    expect(publisher, contains("'latest-windows.json'"));
    expect(publisher, contains("args.contains('--publish-legacy-manifest')"));
    expect(publisher, contains('if (publishLegacyManifest)'));
    expect(publisher, contains('--package-dir'));
    expect(
      publisher.indexOf("contentType: 'application/zip'"),
      lessThan(publisher.indexOf("'windows/latest.json'")),
    );
  });

  test('离线签名密钥工具存在，且拒绝覆盖已有私钥', () {
    final file = File('tool/update_signing_key.dart');
    expect(file.existsSync(), isTrue);
    final source = file.readAsStringSync();
    expect(source, contains('windows_update_signing_private_key'));
    expect(source, contains('windows_update_signing_public_key'));
    expect(source, contains('Refusing to overwrite'));
  });

  test('安全更新引导版版本号在代码、pubspec 和变更记录中一致', () {
    final appVersion = File('lib/core/app_version.dart').readAsStringSync();
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final changelog = File('CHANGELOG.md').readAsStringSync();
    expect(appVersion, contains("appVersion = '0.1.245'"));
    expect(pubspec, contains('version: 0.1.245+245'));
    expect(changelog, startsWith('## 0.1.245'));
  });

  test('MSIX 工具来源固定且下载后先验 SHA-256', () {
    expect(
      File('third_party/windows_sdk/build_tools.json').existsSync(),
      isTrue,
    );
    expect(script, contains('archiveSha256'));
    expect(
      script.indexOf('Get-Sha256'),
      lessThan(script.indexOf('makeappx.exe')),
    );
    expect(script, contains('api.nuget.org'));
  });

  test('同时产出 MSIX、便携 ZIP 和可机器校验的指纹清单', () {
    expect(script, contains('Compress-Archive'));
    expect(script, contains('makeappx.exe'));
    expect(script, contains('.msix'));
    expect(script, contains('SHA256SUMS'));
    expect(script, contains('distribution.json'));
    expect(File('scripts/windows/test_distribution.ps1').existsSync(), isTrue);
    final workflow = File(
      '.github/workflows/windows-ci.yml',
    ).readAsStringSync();
    expect(workflow, contains('test_distribution.ps1'));
  });

  test('有证书才签名，要求签名时不允许静默降级', () {
    expect(script, contains('RequireSigning'));
    expect(script, contains('signtool.exe'));
    expect(script, contains('Get-AuthenticodeSignature'));
    expect(script, contains('未提供 Windows 代码签名证书'));
  });

  test('manifest 是最小权限 x64 桌面应用', () {
    expect(manifest, contains('ProcessorArchitecture="x64"'));
    expect(manifest, contains('Windows.FullTrustApplication'));
    expect(manifest, contains('runFullTrust'));
    expect(manifest, contains('MinVersion="10.0.17763.0"'));
    expect(manifest, isNot(contains('broadFileSystemAccess')));
  });
}
