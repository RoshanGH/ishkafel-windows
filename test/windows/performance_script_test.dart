import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows 性能脚本覆盖 1080p、4K、音画规格与进程峰值内存', () {
    final script = File('scripts/windows/benchmark_media_pipeline.ps1');
    expect(script.existsSync(), isTrue);
    final source = script.readAsStringSync();

    expect(source, contains("Name = '1080p'"));
    expect(source, contains("Name = '4K'"));
    expect(source, contains('PeakWorkingSet64'));
    expect(
      RegExp(r'\$peak = \[Math\]::Max\(\$peak, \$process\.PeakWorkingSet64\)')
          .allMatches(source)
          .length,
      greaterThanOrEqualTo(3),
      reason: '短任务可能在第一次 200ms 轮询前结束，启动后必须立即采样一次',
    );
    expect(source, contains('sample_rate'));
    expect(source, contains('nb_read_frames'));
    expect(source, contains('windows-media-baseline.json'));
    expect(source, contains('libx264'));
    expect(source, contains('0x4E2D'));
    expect(source, contains('0x6587'));
  });

  test('Windows 应用稳定性脚本使用隔离数据目录并检查存活与内存', () {
    final script = File('scripts/windows/test_app_stability.ps1');
    expect(script.existsSync(), isTrue);
    final source = script.readAsStringSync();

    expect(source, contains("EnvironmentVariables['APPDATA']"));
    expect(source, contains('PeakWorkingSet64'));
    expect(source, contains('HasExited'));
    expect(source, contains('windows-app-stability.json'));
    expect(source, contains('finally'));
  });

  test('Windows 真机脚本不使用 PowerShell 7 专属的进程 API', () {
    final sources = [
      'scripts/windows/benchmark_media_pipeline.ps1',
      'scripts/windows/test_cli_contract.ps1',
      'scripts/windows/test_app_stability.ps1',
    ].map((path) => File(path).readAsStringSync()).join('\n');

    expect(sources, isNot(contains('.ArgumentList')));
    expect(sources, isNot(contains('.Environment[')));
    expect(sources, isNot(contains(r'.Kill($true)')));
    expect(sources, contains('.Arguments'));
    expect(sources, contains('.EnvironmentVariables['));
    expect(File('scripts/windows/process_compat.ps1').existsSync(), isTrue);
  });
}
