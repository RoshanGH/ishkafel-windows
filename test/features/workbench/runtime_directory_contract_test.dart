import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('工作台媒体缓存必须使用注入的数据目录', () {
    final source = File(
      'lib/features/workbench/workbench_page.dart',
    ).readAsStringSync();

    expect(source, isNot(contains('getApplicationSupportDirectory()')));
    expect(source, contains("p.join(dataDir.path, 'analysis_work')"));
  });
}
