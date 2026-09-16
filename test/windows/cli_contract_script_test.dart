import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows CLI 真机合同脚本覆盖全部 28 条顶层命令', () {
    final script = File('scripts/windows/test_cli_contract.ps1');
    expect(script.existsSync(), isTrue);

    final source = script.readAsStringSync();
    const commands = [
      'analyze',
      'apply',
      'bgm',
      'blank',
      'candidates',
      'clean',
      'doctor',
      'export',
      'import',
      'jianying',
      'open',
      'peek',
      'review',
      'script',
      'skill',
      'status',
      'subtitle',
      'tag-groups',
      'task',
      'task-copy',
      'task-delete',
      'task-rename',
      'tasks',
      'todo',
      'unit',
      'ui',
      'voice',
      'voices',
    ];
    for (final command in commands) {
      expect(source, contains("'$command'"), reason: '缺少 $command 真机探测');
    }
    expect(source, contains('WaitForExit'));
    expect(source, contains('未知命令'));
    expect(source, contains('中文 数据'));
    expect(source, contains('ConvertFrom-Json'));
  });
}
