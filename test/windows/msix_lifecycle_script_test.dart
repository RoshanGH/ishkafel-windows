import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('MSIX 生命周期脚本覆盖开发安装、升级、启动、卸载与恢复', () {
    final script = File('scripts/windows/test_msix_lifecycle.ps1');
    expect(script.existsSync(), isTrue);
    final source = script.readAsStringSync();

    expect(source, contains('Add-AppxPackage'));
    expect(source, contains('Remove-AppxPackage'));
    expect(source, contains('makeappx'));
    expect(source, contains('AllowUnsigned'));
    expect(source, contains('OID.2.25.311729368913984317654407730594956997722=1'));
    expect(source, contains('productionSigningRequired'));
    expect(source, contains('WindowsBuiltInRole]::Administrator'));
    expect(source, contains('ISHKAFEL_DATA_DIR'));
    expect(source, contains('cli\\bin\\ishkafel.exe'));
    expect(source, contains('finally'));
    expect(source, contains('Refusing'));
  });
}
