import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_selector/file_selector.dart';

import '../../core/diagnostics/environment_report.dart';
import '../../core/diagnostics/tool_installer.dart';
import '../../core/diagnostics/tool_probe_cache.dart';
import '../../core/miaoa/miaoa_account_service.dart';
import '../../core/miaoa/miaoa_auth_service.dart';
import '../../core/storage/cache_usage.dart';
import '../../core/storage/task_repository.dart';
import '../../core/platform/storage_migration_service.dart';
import '../tasks/environment_banner.dart';
import '../tasks/task_list_controller.dart';

// 版本号搬到了 core/app_version.dart（CLI 也要用，不能拖进 Flutter），
// 这里转出去，原来 import 这个文件拿 appVersion 的地方不用改
export '../../core/app_version.dart' show appVersion;

/// 终端登录命令：三处（未登录提示、复制按钮、失败引导）共用一份，
/// 免得改了一处另两处还在教用户敲旧命令
const String miaoaLoginCommand = 'miaoa auth login';

// ── 注入点 ────────────────────────────────────────────────
// 默认值都是「不可用」而非可用的真实实现：单测里不会有任何一条命令被真的
// 执行，也不会有任何目录被真的扫描。真实实现由 main.dart override。

final miaoaAccountServiceProvider =
    Provider<MiaoaAccountService?>((ref) => null);

/// 登录/登出。null 表示本次运行没接入——设置页那时退回「去终端登录」的引导，
/// 而不是给一个点了没反应的按钮
final miaoaAuthServiceProvider = Provider<MiaoaAuthService?>((ref) => null);

/// 一键安装外部依赖。null 表示本次运行没接入——那时设置页退回「请在终端
/// 执行……」的引导，而不是给一个点了没反应的按钮
final toolInstallerProvider = Provider<ToolInstaller?>((ref) => null);

final cacheScannerProvider = Provider<CacheScanner?>((ref) => null);

final environmentProbeProvider = Provider<EnvironmentProbe?>((ref) => null);

/// 重新体检：**先忘掉「没找到」，再让读探测结果的 provider 重算**。
///
/// 顺序不能反：先 invalidate 的话，重算时读到的还是旧缓存，等于没刷新。
///
/// 只 invalidate 采集器是不够的（2026-09-06 真机 bug）——工具路径缓存在下面
/// 三个定位器里，不清掉的话「重新检测」点多少次都还是「未安装」。
/// 装完工具、点重新检测都走这里，别各自去 invalidate。
void refreshToolProbes(WidgetRef ref) {
  forgetToolProbeMisses();
  ref.invalidate(mediaToolsStatusProvider);
  ref.invalidate(environmentReportProvider);
}

final dataDirProvider = Provider<Directory?>((ref) => null);

typedef SettingsDirectoryPicker = Future<String?> Function(String? initialDirectory);
typedef StorageMigrationAction = Future<StorageMigrationReport> Function(
    Directory targetStorageRoot);
typedef ExportRootWriter = void Function(String path);

/// 当前 Windows 用户配置的存储根目录；null 表示沿用平台默认位置。
final storageRootProvider = StateProvider<String?>((ref) => null);

/// 新任务/无历史任务的默认导出目录。
final defaultExportDirectoryProvider = StateProvider<Directory?>((ref) => null);

final storageRootPickerProvider = Provider<SettingsDirectoryPicker>((ref) =>
    (initialDirectory) => getDirectoryPath(
        initialDirectory: initialDirectory, confirmButtonText: '选择数据位置'));

final exportRootPickerProvider = Provider<SettingsDirectoryPicker>((ref) =>
    (initialDirectory) => getDirectoryPath(
        initialDirectory: initialDirectory, confirmButtonText: '选择导出位置'));

/// null 只用于未接真实文件系统的测试装配。
final storageMigrationActionProvider =
    Provider<StorageMigrationAction?>((ref) => null);

/// null 只用于未接 Windows 用户设置的测试装配。
final exportRootWriterProvider = Provider<ExportRootWriter?>((ref) => null);

/// 执行清理并返回实际释放的字节数（抽成 provider 是为了让页面测试无需真实文件系统）
typedef CachePurge = Future<int> Function();

final cachePurgeProvider = Provider<CachePurge>((ref) {
  final scanner = ref.watch(cacheScannerProvider);
  final repository = ref.watch(taskRepositoryProvider);
  return () async {
    if (scanner == null) return 0;
    final tasks = await repository.findAll();
    return scanner.purgeOrphans(
      knownTaskIds: {for (final t in tasks) t.id},
      // 现存任务还引用着的素材：人声分离产物按素材归档，靠这份引用集
      // 反推孤儿。宁可多保护（并集取宽），不误删在用的
      referencedStems: {
        for (final t in tasks) ...[
          for (final m in t.pickedMaterials) '${m.id}',
          for (final r in t.replacementsByUid.values) ...[
            for (final id in r.wholeCandidateIds) '$id',
            for (final ids in r.shotCandidateIds.values) ...[
              for (final id in ids) '$id',
            ],
          ],
        ],
      },
    );
  };
});

// ── 读取 ────────────────────────────────────────────────

/// null 表示本次运行没有接入账号服务（只会发生在测试环境）。
/// 不拿「未登录」冒充它——那会在 main.dart 漏接线时，让已登录的用户
/// 永远看到一份登录引导，而没有任何线索指向真正的原因。
final miaoaAccountProvider = FutureProvider<MiaoaAccountStatus?>(
    (ref) => ref.watch(miaoaAccountServiceProvider)?.fetch());

/// 缓存占用。孤儿判定要拿现存任务 id，因此依赖任务仓库；
/// 删除任务后 invalidate 本 provider 即可让占用数字跟上。
final cacheUsageProvider = FutureProvider<CacheUsage>((ref) async {
  final scanner = ref.watch(cacheScannerProvider);
  if (scanner == null) return CacheUsage.empty;
  return scanner.scan(
      knownTaskIds: await _knownTaskIds(ref.watch(taskRepositoryProvider)));
});

final environmentReportProvider = FutureProvider<EnvironmentReport?>((ref) {
  final probe = ref.watch(environmentProbeProvider);
  return probe?.collect();
});

Future<Set<String>> _knownTaskIds(TaskRepository repository) async =>
    {for (final task in await repository.findAll()) task.id};
