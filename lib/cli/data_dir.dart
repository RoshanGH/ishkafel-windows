import 'dart:io';

import '../core/platform/platform_paths.dart';

/// app 的 bundle id。数据目录是按它分的，两边必须写同一个值
const String bundleId = ishkafelBundleId;

/// CLI 用的数据目录，**必须与 GUI 完全一致**。
///
/// GUI 走 `path_provider` 的 `getApplicationSupportDirectory()`，在 macOS 上
/// 就是 `~/Library/Application Support/<bundle id>`。CLI 没有 Flutter
/// binding，只能按同样规则自己拼。
///
/// 两边一旦不一致，症状是最难查的那一类：Agent 建的任务在 app 里看不见、
/// app 里改的东西 Agent 读不到，而**谁都没有报错**。所以这条规则有测试钉着。
///
/// [override] 与 `ISHKAFEL_DATA_DIR` 供测试和多环境用；显式参数优先。
Directory resolveDataDir({
  Map<String, String>? env,
  String? override,
  String? operatingSystem,
}) {
  final e = env ?? Platform.environment;
  final explicit = override ?? e['ISHKAFEL_DATA_DIR'];
  if (explicit != null && explicit.trim().isNotEmpty) {
    return Directory(explicit.trim());
  }
  return Directory(PlatformPaths(
    operatingSystem: operatingSystem,
    environment: e,
  ).dataDir);
}
