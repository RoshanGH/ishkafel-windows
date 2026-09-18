import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/diagnostics/system_snapshot.dart';

void main() {
  test('Windows 真机采集不能因 PowerShell 冷启动而丢失硬件信息', () async {
    final snapshot = await collectSystemSnapshot();
    expect(snapshot['hardware'], isA<Map>(), reason: '$snapshot');
    final hardware = snapshot['hardware'] as Map;
    expect(hardware['cpu'], isNotEmpty);
    expect(hardware['gpu'], isNotEmpty);
    expect(hardware['memory'], isA<Map>());
    expect(hardware['disks'], isNotEmpty);
  }, skip: !Platform.isWindows, timeout: const Timeout(Duration(seconds: 50)));
}
