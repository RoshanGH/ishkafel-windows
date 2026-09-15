# Windows 平台契约与 P0 实施计划

> **执行要求：** 按 `superpowers:executing-plans` 分批实施；每项功能先写失败测试，再写最小实现，完成后运行目标测试、分析和 Windows Release 构建。

**目标：** 清除首轮基线发现的 7 个 Windows 运行时 P0，使 GUI 与 CLI 共用同一数据、媒体工具和字幕产物协议，并让 Windows 原生窗口达到已批准的尺寸契约。

**架构：** 业务层继续保持 Flutter/Dart；所有操作系统差异收口到 `core/platform`。媒体执行继续使用绝对路径和现有 `ProcessRunner`。字幕由 GUI/CLI 共用的版本化 JSON 协议调用独立 `ishkafel_renderer`，Windows 先建立可构建、可诊断的原生入口，固定 Skia/HarfBuzz/FreeType 与字体接入作为同一工作流后续提交，绝不回退为 System.Drawing。

**技术栈：** Dart 3.13、Flutter 3.47、Win32/C++17、CMake、FFmpeg、Skia/HarfBuzz/FreeType（固定版本）、Flutter test、CTest。

---

## 任务 1：统一 GUI/CLI 数据目录契约

**文件：**
- 新建：`lib/core/platform/platform_paths.dart`
- 修改：`lib/cli/data_dir.dart`
- 修改：`test/cli/data_dir_test.dart`
- 新建：`test/core/platform/platform_paths_test.dart`

1. 先增加 Windows Roaming AppData、macOS Application Support、显式覆盖和缺失环境变量测试。
2. 运行目标测试确认 Windows 用例失败。
3. 实现可注入的 `PlatformPaths`，Windows 与 runner 版本信息对齐到 `%APPDATA%\\com.jichuang\\ishkafel\\ishkafel_data`。
4. 让 CLI 只委托平台路径契约，运行测试并提交。

## 任务 2：统一 PATH、可执行文件与进程存活契约

**文件：**
- 新建：`lib/core/platform/platform_shell.dart`
- 修改：`lib/core/ffmpeg/media_tools_locator.dart`
- 修改：`lib/core/storage/task_lock.dart`
- 修改：`test/core/ffmpeg/child_process_path_test.dart`
- 修改：`test/core/ffmpeg/media_tools_locator_test.dart`
- 修改：`test/core/storage/task_lock_test.dart`

1. 增加分号 PATH、盘符、`.exe`、`where.exe` 和 Windows 进程查询测试。
2. 实现 `PlatformShell`，把 PATH 分隔符、工具后缀、查找命令和进程存活收口。
3. 媒体工具按“安装目录内置 → 平台默认目录 → PATH”解析并保持缓存语义。
4. 运行目标测试并提交。

## 任务 3：转义 Windows FFmpeg filtergraph 路径

**文件：**
- 新建：`lib/core/ffmpeg/filtergraph_escape.dart`
- 修改：`lib/core/analysis/frame_signal_extractor.dart`
- 修改：`test/core/analysis/frame_signal_extractor_test.dart`
- 新建：`test/core/ffmpeg/filtergraph_escape_test.dart`

1. 增加盘符、反斜杠、单引号和空格覆盖测试。
2. 实现仅针对 FFmpeg filter option value 的转义函数，避免把命令行 shell 转义与 filtergraph 转义混淆。
3. 场景元数据输出路径统一通过该函数。
4. 运行目标测试并提交。

## 任务 4：建立 Windows CLI UTF-8 契约

**文件：**
- 新建：`lib/cli/console_encoding.dart`
- 修改：`bin/ishkafel.dart`
- 新建：`test/cli/console_encoding_test.dart`
- 修改：`scripts/windows/build_cli.ps1`

1. 增加入口静态守卫和真实编译后中文 JSON 重定向测试。
2. Windows 入口通过 Win32 控制台代码页设置 UTF-8，Dart stdout/stderr 保持 UTF-8 字节输出；非 Windows 无副作用。
3. `.cmd` shim 设置 `chcp 65001` 且不污染输出。
4. 运行测试、编译 CLI、验证重定向字节并提交。

## 任务 5：落实 Win32 窗口尺寸与 DPI 契约

**文件：**
- 修改：`windows/runner/main.cpp`
- 修改：`windows/runner/win32_window.h`
- 修改：`windows/runner/win32_window.cpp`
- 新建：`test/architecture/windows_runner_contract_test.dart`

1. 用架构测试锁定 1440×900 默认值、1100×880 最小客户区和居中。
2. runner 使用工作区居中；`WM_GETMINMAXINFO` 按当前 DPI 计算最小跟踪尺寸。
3. 运行测试和 Windows Release 构建并提交。

## 任务 6：建立跨平台字幕渲染器协议与 Windows 原生进程

**文件：**
- 新建：`lib/core/subtitle/subtitle_renderer_protocol.dart`
- 修改：`lib/core/subtitle/subtitle_rasterizer.dart`
- 新建：`test/core/subtitle/subtitle_renderer_protocol_test.dart`
- 新建：`windows/renderer/CMakeLists.txt`
- 新建：`windows/renderer/main.cpp`
- 修改：`windows/CMakeLists.txt`

1. 以现有 JXA spec 固化版本化 JSON 输入、输出和错误协议测试。
2. Dart rasterizer 按平台选择：macOS 暂保留 JXA，Windows 只调用同协议 `ishkafel_renderer.exe`；找不到或输出不全时明确中止。
3. 建立 C++17 原生进程、严格参数/UTF-8/退出码/原子输出骨架，并纳入 Windows bundle。
4. 接入固定版本 Skia/HarfBuzz/FreeType 和随包字体前，绝不把骨架标记为字幕完成；该依赖接入、PNG golden 和 Mac/Windows 叠图作为本任务的验收后半段。
5. 运行 Dart 协议测试、CTest、Release 构建并提交。

## 任务 7：全量回归与基线更新

**文件：**
- 修改：`docs/windows-port/08-Windows基线.md`
- 修改：`docs/platform-differences.md`（仅在发现新差异时）

1. 运行 `flutter analyze`、目标 P0 测试、全量 `flutter test`、CLI 构建和 Windows Release 构建。
2. 区分上游既有失败、Windows 测试可移植性失败和本轮回归；禁止用 skip 掩盖产品路径。
3. 记录命令、退出码、产物与剩余问题，不提前宣称 Windows 首版完成。

