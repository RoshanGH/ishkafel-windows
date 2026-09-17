/// 自动更新的落点配置。**编译期注入**，和 AI 凭据同一条路
/// （`scripts/build_macos.sh` 从 `.secrets/` 读）。
///
/// 没配就整个功能关掉：`enabled` 为 false 时界面上不出现任何更新入口——
/// 不能让人看到一个「检查更新」按钮，点下去永远说「网络不通」。
class UpdateConfig {
  /// 清单在 bucket 里的对象键。**它也是私有的**——app 本来就带着只读凭据，
  /// 用同一把钥匙去读清单，就不用再维护一个公开地址、也不用操心 ACL
  static const manifestKey = String.fromEnvironment(
    'UPDATE_TOS_MANIFEST_KEY',
    defaultValue: 'windows/latest.json',
  );

  static const region = String.fromEnvironment('UPDATE_TOS_REGION');
  static const bucket = String.fromEnvironment('UPDATE_TOS_BUCKET');
  static const endpoint = String.fromEnvironment('UPDATE_TOS_ENDPOINT');

  /// **只读**凭据：只该有这一个 bucket 的 GetObject 权限。
  ///
  /// 它和别的凭据一样明文躺在二进制里（`strings` 一抠就有）——这正是包不能
  /// 公开读的原因。给它最小权限，泄露的后果就只是「别人能下载安装包」，
  /// 而不是「别人能花你的钱」
  static const accessKey = String.fromEnvironment('UPDATE_TOS_AK');
  static const secretKey = String.fromEnvironment('UPDATE_TOS_SK');

  /// 发布签名公钥可以公开，内置在客户端用于证明清单确实来自发布机。
  /// 对应私钥绝不能通过 dart-define 进入产物。
  static const signingPublicKey = String.fromEnvironment(
    'UPDATE_SIGNING_PUBLIC_KEY',
  );

  static bool get enabled =>
      region.isNotEmpty &&
      bucket.isNotEmpty &&
      endpoint.isNotEmpty &&
      accessKey.isNotEmpty &&
      secretKey.isNotEmpty &&
      signingPublicKey.isNotEmpty;

  /// 没配全时说清缺哪一项——排查时不用去翻构建脚本
  static String get missingHint {
    final missing = [
      if (region.isEmpty) 'UPDATE_TOS_REGION',
      if (bucket.isEmpty) 'UPDATE_TOS_BUCKET',
      if (endpoint.isEmpty) 'UPDATE_TOS_ENDPOINT',
      if (accessKey.isEmpty) 'UPDATE_TOS_AK',
      if (secretKey.isEmpty) 'UPDATE_TOS_SK',
      if (signingPublicKey.isEmpty) 'UPDATE_SIGNING_PUBLIC_KEY',
    ];
    return missing.isEmpty ? '' : '缺少：${missing.join('、')}';
  }
}
