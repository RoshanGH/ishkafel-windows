import 'dart:io';

/// 决定导出对话框第一次打开的位置。
///
/// 同一任务延续上一次交付目录最符合工作流；没有可用历史时才采用全局设置，
/// 两者都没有则保留旧版的“影片/ishkafel”位置。
Directory initialExportDirectory({
  required Directory? lastUsable,
  required Directory? configuredDefault,
  required Directory fallback,
}) => lastUsable ?? configuredDefault ?? fallback;
