import '../../core/presentation/user_facing_exception.dart';

/// 导入失败（面向用户的中文提示 + 仅用于日志的原始异常）
///
/// 导入是系统边界：ffprobe 输出、文件内容都属于外部数据，出问题必须转成
/// 用户看得懂的一句话，而不是把 `FormatException`/`ProcessException` 原文
/// 摊到界面上。
class ImportException implements UserFacingException {
  /// 面向用户的中文提示（可直接展示）
  @override
  final String message;

  /// 原始异常，仅用于日志排查，不展示给用户
  final Object? cause;

  const ImportException(this.message, {this.cause});

  @override
  String toString() => 'ImportException: $message（原因：$cause）';
}
