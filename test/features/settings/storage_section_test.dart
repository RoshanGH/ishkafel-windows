import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/platform/storage_migration_service.dart';
import 'package:ishkafel/features/settings/sections/storage_section.dart';
import 'package:ishkafel/features/settings/settings_providers.dart';

void main() {
  testWidgets('数据复制校验成功后显示新位置并要求重启', (tester) async {
    Directory? selected;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dataDirProvider.overrideWithValue(Directory(r'C:\old\data')),
          storageRootProvider.overrideWith((_) => r'C:\old'),
          defaultExportDirectoryProvider.overrideWith(
            (_) => Directory(r'C:\old\exports'),
          ),
          storageRootPickerProvider.overrideWithValue(
            (_) async => r'D:\Ishkafel\UserData',
          ),
          storageMigrationActionProvider.overrideWithValue((target) async {
            selected = target;
            return const StorageMigrationReport(
              sourceDataDirectory: r'C:\old\data',
              destinationDataDirectory: r'D:\Ishkafel\UserData\data',
              fileCount: 8,
              totalBytes: 1024,
              sha256ByRelativePath: {},
            );
          }),
        ],
        child: const MaterialApp(home: Scaffold(body: StorageSection())),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-change-storage-root')));
    await tester.pumpAndSettle();

    expect(selected?.path, r'D:\Ishkafel\UserData');
    expect(find.textContaining(r'D:\Ishkafel\UserData'), findsWidgets);
    expect(find.textContaining('8 个文件'), findsOneWidget);
    expect(find.textContaining('重启'), findsOneWidget);
  });

  testWidgets('迁移失败时显示人话且不暴露原始异常', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dataDirProvider.overrideWithValue(Directory(r'C:\old\data')),
          storageRootPickerProvider.overrideWithValue(
            (_) async => r'D:\Ishkafel\UserData',
          ),
          storageMigrationActionProvider.overrideWithValue(
            (_) async => throw const FileSystemException('secret raw error'),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: StorageSection())),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-change-storage-root')));
    await tester.pumpAndSettle();

    expect(find.textContaining('迁移未完成'), findsOneWidget);
    expect(find.textContaining('secret raw error'), findsNothing);
  });

  testWidgets('默认导出位置保存后立即显示', (tester) async {
    String? saved;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dataDirProvider.overrideWithValue(Directory(r'C:\old\data')),
          defaultExportDirectoryProvider.overrideWith(
            (_) => Directory(r'C:\old\exports'),
          ),
          exportRootPickerProvider.overrideWithValue(
            (_) async => r'D:\Ishkafel\Media\Exports',
          ),
          exportRootWriterProvider.overrideWithValue((path) => saved = path),
        ],
        child: const MaterialApp(home: Scaffold(body: StorageSection())),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-change-export-root')));
    await tester.pumpAndSettle();

    expect(saved, r'D:\Ishkafel\Media\Exports');
    expect(find.textContaining(r'D:\Ishkafel\Media\Exports'), findsOneWidget);
    expect(find.textContaining('已保存'), findsOneWidget);
  });
}
