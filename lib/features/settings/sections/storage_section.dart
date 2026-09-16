import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../core/log/app_log.dart';
import '../settings_providers.dart';
import '../settings_widgets.dart';

class StorageSection extends ConsumerStatefulWidget {
  const StorageSection({super.key});

  @override
  ConsumerState<StorageSection> createState() => _StorageSectionState();
}

class _StorageSectionState extends ConsumerState<StorageSection> {
  bool _migrating = false;
  String? _storageMessage;
  String? _exportMessage;

  @override
  Widget build(BuildContext context) {
    final dataDir = ref.watch(dataDirProvider);
    final storageRoot = ref.watch(storageRootProvider);
    final exportRoot = ref.watch(defaultExportDirectoryProvider);
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.xl),
      children: [
        SettingsCard(
          title: '数据与素材',
          children: [
            SettingsRow(
              label: '当前位置',
              value: storageRoot ?? dataDir?.path ?? '未接入',
            ),
            const Divider(height: 1, color: AppColors.border),
            const SettingsNote(
              '任务、下载素材、模型产物和日志都跟随这个位置。'
              '更改时会先复制并逐文件校验，原目录不会自动删除。',
            ),
            if (_storageMessage != null)
              SettingsNote(_storageMessage!, color: AppColors.green),
            const SizedBox(height: AppSpacing.md),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(
                key: const Key('settings-change-storage-root'),
                onPressed: _migrating || dataDir == null
                    ? null
                    : () => _changeStorage(dataDir),
                child: Text(_migrating ? '复制并校验中…' : '更改数据位置'),
              ),
            ),
          ],
        ),
        SettingsCard(
          title: '默认导出',
          children: [
            SettingsRow(label: '当前位置', value: exportRoot?.path ?? '沿用系统影片目录'),
            const Divider(height: 1, color: AppColors.border),
            const SettingsNote(
              '任务有自己的上次导出位置时仍优先使用；'
              '这里是新任务和首次导出的默认位置。',
            ),
            if (_exportMessage != null)
              SettingsNote(_exportMessage!, color: AppColors.green),
            const SizedBox(height: AppSpacing.md),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                key: const Key('settings-change-export-root'),
                onPressed: _changeExport,
                child: const Text('更改导出位置'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _changeStorage(Directory sourceDataDirectory) async {
    final picker = ref.read(storageRootPickerProvider);
    final current =
        ref.read(storageRootProvider) ?? sourceDataDirectory.parent.path;
    final selected = await picker(current);
    if (selected == null || selected.trim().isEmpty || !mounted) return;
    final migrate = ref.read(storageMigrationActionProvider);
    if (migrate == null) {
      _toast('本次运行未接入数据迁移服务。');
      return;
    }
    setState(() {
      _migrating = true;
      _storageMessage = null;
    });
    try {
      final report = await migrate(Directory(selected));
      ref.read(storageRootProvider.notifier).state = selected;
      if (mounted) {
        setState(
          () => _storageMessage =
              '已复制并校验 ${report.fileCount} 个文件。请重启 Ishkafel 使用新位置；旧目录仍保留。',
        );
      }
    } catch (error) {
      AppLog.warn('迁移数据目录失败：$error');
      _toast('迁移未完成，原位置和原数据均未改动。请检查目标磁盘空间后重试。');
    } finally {
      if (mounted) setState(() => _migrating = false);
    }
  }

  Future<void> _changeExport() async {
    final current = ref.read(defaultExportDirectoryProvider)?.path;
    final selected = await ref.read(exportRootPickerProvider)(current);
    if (selected == null || selected.trim().isEmpty || !mounted) return;
    final write = ref.read(exportRootWriterProvider);
    if (write == null) {
      _toast('本次运行未接入导出位置设置。');
      return;
    }
    try {
      write(selected);
      ref.read(defaultExportDirectoryProvider.notifier).state = Directory(
        selected,
      );
      setState(() => _exportMessage = '已保存，新任务和首次导出会使用这个位置。');
    } catch (error) {
      AppLog.warn('保存默认导出位置失败：$error');
      _toast('保存未完成，请确认该目录可写后重试。');
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}
