import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/features/export/default_export_directory.dart';

void main() {
  test('任务上次导出位置优先于全局默认位置', () {
    final chosen = initialExportDirectory(
      lastUsable: Directory(r'D:\客户甲\上一批'),
      configuredDefault: Directory(r'D:\Ishkafel\Media\Exports'),
      fallback: Directory(r'C:\Users\Mayn\Videos\ishkafel'),
    );
    expect(chosen.path, r'D:\客户甲\上一批');
  });

  test('任务没有历史时使用软件设置的默认导出位置', () {
    final chosen = initialExportDirectory(
      lastUsable: null,
      configuredDefault: Directory(r'D:\Ishkafel\Media\Exports'),
      fallback: Directory(r'C:\Users\Mayn\Videos\ishkafel'),
    );
    expect(chosen.path, r'D:\Ishkafel\Media\Exports');
  });

  test('没有任何设置时保留原有影片目录回退', () {
    final fallback = Directory(r'C:\Users\Mayn\Videos\ishkafel');
    expect(
      initialExportDirectory(
        lastUsable: null,
        configuredDefault: null,
        fallback: fallback,
      ),
      same(fallback),
    );
  });
}
