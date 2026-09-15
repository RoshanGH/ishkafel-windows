import 'dart:io';

String monospaceFontFamily([String? operatingSystem]) =>
    (operatingSystem ?? Platform.operatingSystem) == 'windows'
    ? 'Consolas'
    : 'Menlo';

String get platformMonospaceFontFamily => monospaceFontFamily();

/// 字号阶梯 token
///
/// 改造前全项目散落 10 / 10.5 / 11 / 11.5 / 12 / 12.5 / 13 / 15 共 8 种字号，
/// 相邻两级只差 0.5px——这种差别在视觉上读不出层级，只会让排版发糊。
/// 这里收敛成 5 级，每级之间有明确的语义分工与可辨的字号差。
///
/// 取值偏小是刻意的：本 app 是专业视频工具（对标剪映专业版 / Final Cut Pro），
/// 时间线与检查器需要高信息密度，而 macOS 系统字体（SF Pro / PingFang SC）
/// 在 10–13px 区间仍然清晰。
abstract final class AppFontSize {
  /// 10 — 密集标注：时间线刻度、镜头编号、轨道标签
  static const micro = 10.0;

  /// 11 — 次要信息：时间码、辅助说明、徽标文字
  static const caption = 11.0;

  /// 12 — 正文：列表台词、时间线块体标题、检查器字段
  static const body = 12.0;

  /// 13 — 强调正文：面板标题、顶栏任务名
  static const emphasis = 13.0;

  /// 15 — 页面标题
  static const title = 15.0;

  /// 24 — 首屏主标题。全应用只用在一处（欢迎页的产品名）：首屏要先回答
  /// 「这是什么」，用 15px 说这句话会被当成又一行说明文字。
  static const display = 24.0;

  /// 全部字号（供阶梯校验测试使用）
  static const all = <double>[micro, caption, body, emphasis, title, display];
}
