import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/data_dir.dart';

/// CLI 必须和 GUI 读同一个数据目录，否则「Agent 建的任务在 app 里看不见」。
///
/// GUI 走 path_provider（`getApplicationSupportDirectory`），CLI 没有 Flutter
/// binding，只能按同样的规则自己拼——两边一旦不一致，出来的症状是最难查的
/// 那一类：两边各说各话，谁也没报错。所以这条规则在这里钉死。
void main() {
  test('macOS 默认落在 GUI 用的那个目录', () {
    final dir = resolveDataDir(
      env: {'HOME': '/Users/someone'},
      operatingSystem: 'macos',
    );
    expect(
      dir.path,
      '/Users/someone/Library/Application Support/com.jichuang.ishkafel/ishkafel_data',
    );
  });

  test('Windows 默认与 path_provider 的 CompanyName/ProductName 规则一致', () {
    final dir = resolveDataDir(
      env: {'APPDATA': r'C:\Users\小明\AppData\Roaming'},
      operatingSystem: 'windows',
    );
    expect(
      dir.path,
      r'C:\Users\小明\AppData\Roaming\com.jichuang\ishkafel\ishkafel_data',
    );
  });

  test('允许显式覆盖——测试与多环境要用', () {
    final dir = resolveDataDir(
      env: {'HOME': '/Users/someone'},
      override: '/tmp/x',
      operatingSystem: 'macos',
    );
    expect(dir.path, '/tmp/x');
  });

  test('环境变量也能覆盖', () {
    final dir = resolveDataDir(
        env: {'HOME': '/Users/someone', 'ISHKAFEL_DATA_DIR': '/tmp/y'},
        operatingSystem: 'macos');
    expect(dir.path, '/tmp/y');
  });

  test('显式参数优先于环境变量', () {
    final dir = resolveDataDir(
        env: {'HOME': '/h', 'ISHKAFEL_DATA_DIR': '/tmp/y'},
        override: '/tmp/z',
        operatingSystem: 'macos');
    expect(dir.path, '/tmp/z');
  });

  test('读不到 HOME 时明确失败，而不是拼出一个错的路径', () {
    expect(
      () => resolveDataDir(env: const {}, operatingSystem: 'windows'),
      throwsA(isA<StateError>()),
    );
  });

  test('空白的覆盖值当作没给', () {
    final dir = resolveDataDir(
      env: {'HOME': '/h'},
      override: '   ',
      operatingSystem: 'macos',
    );
    expect(dir.path, endsWith('ishkafel_data'));
  });
}
