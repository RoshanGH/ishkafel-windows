import '../presentation/user_facing_exception.dart';
import 'miaoa_failure.dart';

/// miaoa 调用失败（子进程起不来、非零退出码、返回内容非法）。
///
/// [kind] 是失败成因的分类——UI 靠它决定给用户什么**动作**：
/// 登录失效给「重新登录」按钮，网络问题给「重试」，没装 CLI 给安装引导。
/// [message] 永远是可照做的中文，原始报文只进日志。
class MiaoaException implements UserFacingException {
  @override
  final String message;
  final MiaoaFailureKind kind;

  const MiaoaException(this.message, {this.kind = MiaoaFailureKind.unknown});

  @override
  String toString() => 'MiaoaException: $message';
}
