# Windows 原始基线

记录日期：2026-09-15（Asia/Shanghai）
代码起点：`upstream/main@96162c5`，另含 Windows 设计与实施计划提交。

## 基准机器

- Microsoft Windows 11 家庭中文版 10.0.22621（build 22621，64 位）
- Intel Core i5-12400F（6 核 12 线程）
- 31.8 GiB RAM（标称 32GB）
- NVIDIA GeForce RTX 3060 12GB，驱动 560.81
- KINGSTON SNV2S1000G NVMe SSD（931.5 GiB 可见容量）

## 固定工具链

- Flutter 3.47.4 stable，framework revision `9584c6713b`
- Dart 3.13.3 stable（windows_x64）
- Visual Studio Community 2022 17.14.40
- MSVC x64 与 Windows SDK 10.0.22621.0
- CMake 4.0.0-rc2
- Ninja 1.12.1（Visual Studio 随附）
- Git 2.55.0.windows.4、OpenSSH_for_Windows 8.6p1
- GitHub CLI 2.100.0

`flutter doctor -v` 的 Flutter、Windows、Visual Studio、浏览器、设备和网络项通过；
唯一警告为 Android SDK 未安装，与本仓库的 Windows 桌面构建无关。

## 首次环境准备结果

首次 `flutter pub get` 已完成依赖解析，但因 Windows 未启用开发人员模式、插件不能创建符号链接而以 1 退出。
启用 `AllowDevelopmentWithoutDevLicense=1` 后重跑成功，耗时 6.70 秒。

Flutter 3.47.4 同时执行了两项可复现迁移：

- 将 `analysis_options.yaml` 的 `build/**`、`windows/**`、`macos/**` 排除项补齐；
- 将 Dart SDK 约束内的 `matcher`、`meta`、`test_api`、`vector_math` 锁定到 Dart 3.13.3 解析出的版本。

这些不是业务依赖升级；其变化随本基线提交保存，避免每次执行 Flutter 命令都重复迁移。

## 命令结果

| 命令 | 耗时 | 退出码 | 结果 | 完整日志 |
|---|---:|---:|---|---|
| `flutter doctor -v` | 8.64 秒 | 0 | Windows 与 Visual Studio 项通过；仅缺无关的 Android SDK | 终端记录 |
| `flutter analyze` | 17.55 秒 | 0 | `No issues found` | `build/baseline/flutter-analyze.txt` |
| `flutter test` | 131.57 秒 | 1 | 4343 通过、62 失败、14 跳过 | `build/baseline/flutter-test.txt` |
| `dart build cli` | 5.92 秒 | 0 | 生成 `build/cli/windows_x64/bundle/bin/ishkafel.exe` | `build/baseline/dart-build-cli.txt` |
| `flutter build windows --debug` | 22.15 秒 | 1 | MSBuild 路径超过 260 字符 | `build/baseline/flutter-build-windows-debug.txt` |

### 测试失败基线

共 62 个失败，分布在 32 个测试文件。第一处失败来自
`test/architecture/export_carries_audio_settings_test.dart`，它发现
`export_runner.dart` 的调用点未完整传递声音设置；这属于上游当前代码基线，而非 Windows 工具链安装失败。

Windows 特有失败集中于：

- 测试或实现硬编码 `/`，而 `package:path` 在 Windows 返回 `\`；
- 测试直接调用 `chmod` 等 Unix 命令；
- CLI 安装、剪映草稿路径、任务产物路径与更新替换脚本仍假设 macOS；
- 32 个失败文件中有 11 个架构守卫失败记录，后续须区分上游既有红灯与平台契约红灯。

### Windows Debug 构建第一处根因

`media_kit_libs_windows_video` 的 MSBuild 中间文件在当前深层 Codex 工作目录下超过 Windows 传统
260 字符限制。后续验证会使用短路径工作入口复测；第一次失败仍保留，因为它证明 Windows 构建与 CI
必须避免过深 checkout 路径或显式启用长路径策略。编译能否通过不代表运行时 P0 已解决。

## 已知运行时 P0

以下 7 项来自 `docs/windows-port/05-平台耦合清单.md`，本轮只建立基线，不把它们标为解决：

1. CLI 依赖 `HOME`，并手工拼接 macOS Application Support，导致 Windows GUI/CLI 数据目录分裂。
2. 媒体工具定位把 PATH 固定按 `:` 分割，破坏 `C:\...` 路径。
3. 媒体工具定位硬编码 Homebrew、无 `.exe` 后缀及 `/usr/bin/which`。
4. 字幕栅格化依赖 JXA + AppKit，Windows 完全不可用。
5. CLI 中文输出未建立 Windows UTF-8 控制台契约。
6. Windows runner 默认 1280×720 且没有最小窗口尺寸，时间线轨道显示不全。
7. 文件路径直接进入 FFmpeg filtergraph，Windows 盘符冒号会被解释为过滤器语法。
