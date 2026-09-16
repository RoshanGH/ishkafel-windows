/// 应用版本号。`pubspec.yaml` 的值不能在运行时读到（打包后没有这个文件），
/// 又不值得为一行字引入 package_info_plus——因此在这里写一份，用测试盯住
/// 它和 pubspec 不漂移。
///
/// **单独一个文件、且不依赖 Flutter**：CLI 也要用它（`ishkafel skill` 写进
/// 说明书里做版本判断）。放在 settings_providers.dart 里的话，CLI 的依赖树
/// 会被拖进整个 Flutter——`dart build cli` 会在 FFI 那一层直接崩掉。
const String appVersion = '0.1.233';
