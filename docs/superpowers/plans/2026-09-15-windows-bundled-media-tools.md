# Windows Bundled Media Tools Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Windows Release 内置固定、可校验的 FFmpeg/ffprobe，并用真实小视频证明抽帧、音频、拼接与探测链路可运行。

**Architecture:** 发布元数据集中在 `third_party/ffmpeg/windows/manifest.json`。PowerShell 准备脚本下载或接收本地归档，先校验 SHA-256，再把两个可执行文件与许可材料暂存到 `build/vendor/ffmpeg/tools`；CMake 只打包这份已验证目录。Dart 运行时继续通过现有 `MediaToolsLocator` 的“应用目录 tools 优先、PATH 回退”契约解析，不把第三方二进制提交进 Git。

**Tech Stack:** Flutter 3.47.4、Dart 3.13.3、PowerShell 7/Windows PowerShell、CMake、FFmpeg 9.0.1 Essentials x64 GPLv3。

**Spec:** `docs/superpowers/specs/2026-09-15-ishkafel-windows-design.md`

## Global Constraints

- Windows 是独立仓库，但共享业务代码必须能持续合并 Mac 上游。
- FFmpeg 固定为 9.0.1 Essentials x64，发布 ZIP SHA-256 为 `fec81ae03971d9dd4be3ebe02e263bd2ec1d789483f931bdba5f5715e65da2e9`。
- 使用 `libx264` 的该构建按 GPLv3 分发，必须附许可、构建来源和源码对应提交。
- 下载或校验失败必须使构建失败，不允许回退到机器 PATH 后静默产出残缺安装包。
- 最终编码继续使用 libx264 软件编码；硬件编解码不得成为默认导出路径。
- 所有新行为按红—绿—重构执行；完整测试和 Windows Release 构建是合并门槛。

---

### Task 1: 固化第三方工具供应链

**Files:**
- Create: `third_party/ffmpeg/windows/manifest.json`
- Create: `third_party/ffmpeg/windows/NOTICE.md`
- Create: `scripts/windows/prepare_media_tools.ps1`
- Test: `test/windows/media_tools_bundle_script_test.dart`

**Interfaces:**
- Consumes: Gyan FFmpeg 9.0.1 Essentials ZIP 或测试提供的本地 ZIP。
- Produces: `prepare_media_tools.ps1 -ArchivePath <zip> -ExpectedSha256 <sha> -OutputDirectory <dir>`，成功时输出含 `tools/ffmpeg.exe`、`tools/ffprobe.exe`、`LICENSE.txt`、`NOTICE.md` 的暂存目录。

- [ ] **Step 1: 写失败测试**：测试创建带假 `bin/ffmpeg.exe`、`bin/ffprobe.exe`、`LICENSE`、`README.txt` 的 ZIP；断言脚本校验后完整暂存，并断言错误哈希退出非零且不留下 tools。
- [ ] **Step 2: 运行 `flutter test test/windows/media_tools_bundle_script_test.dart`**，确认因脚本不存在而失败。
- [ ] **Step 3: 写最小实现**：读取 manifest，下载或使用本地归档，SHA-256 不一致立即失败，解压到临时目录并唯一定位两个 exe，原子替换输出目录。
- [ ] **Step 4: 重跑测试**，确认正确归档通过、错误哈希失败。
- [ ] **Step 5: 用真实 9.0.1 ZIP 运行准备脚本**，确认 `ffmpeg -version`、`ffprobe -version` 与 manifest 一致。
- [ ] **Step 6: 提交 `build: 固化 Windows FFmpeg 供应链`**。

### Task 2: 接入 Windows Release 打包

**Files:**
- Modify: `windows/CMakeLists.txt`
- Modify: `scripts/windows/build_app.ps1`
- Modify: `.github/workflows/windows-ci.yml`
- Test: `test/windows/media_tools_bundle_script_test.dart`

**Interfaces:**
- Consumes: Task 1 的 `build/vendor/ffmpeg`。
- Produces: `build/windows/x64/runner/Release/tools/ffmpeg.exe` 与 `ffprobe.exe`；CI 每次从空环境重新校验供应链。

- [ ] **Step 1: 扩展失败测试**：在未准备工具时验证打包前置检查失败；准备后验证预期文件布局。
- [ ] **Step 2: 运行测试确认红灯**。
- [ ] **Step 3: CMake 安装已暂存的 `tools/` 与许可材料；`build_app.ps1` 在 CLI 与 Flutter 构建前调用准备脚本；CI 显式准备并缓存归档。**
- [ ] **Step 4: 运行脚本测试与 `flutter build windows --release`，检查 Release tools 目录。**
- [ ] **Step 5: 提交 `build: 将固定 FFmpeg 内置到 Windows Release`**。

### Task 3: 统一运行时探测与 Windows 错误语义

**Files:**
- Modify: `lib/cli/commands/doctor_command.dart`
- Modify: `lib/core/ffmpeg/process_runner.dart`
- Modify: `test/cli/doctor_command_test.dart`
- Modify: `test/core/ffmpeg/missing_tool_message_test.dart`

**Interfaces:**
- Consumes: `systemProcessRunner` 与 `MediaToolsLocator`。
- Produces: doctor 使用同一定位器验证内置 ffmpeg；Windows 安装损坏时提示重新安装，不再要求执行 Homebrew。

- [ ] **Step 1: 写失败测试**：doctor 默认探针经注入 runner 调用 `ffmpeg -version`；`missingToolMessage('ffmpeg', operatingSystem: 'windows')` 不含 brew 且说明安装包损坏。
- [ ] **Step 2: 运行两个目标测试确认红灯原因正确。**
- [ ] **Step 3: 最小修改 doctor 与错误消息，Mac 提示保持原样。**
- [ ] **Step 4: 目标测试转绿并运行全部 `test/core/ffmpeg` 与 `test/cli`。**
- [ ] **Step 5: 提交 `fix: 统一 Windows 内置媒体工具探测`**。

### Task 4: 真实媒体链路冒烟验证

**Files:**
- Create: `scripts/windows/test_media_pipeline.ps1`
- Modify: `.github/workflows/windows-ci.yml`
- Modify: `docs/windows-port/08-Windows基线.md`

**Interfaces:**
- Consumes: Release bundle 的内置 ffmpeg/ffprobe。
- Produces: 2 秒 320×568/30fps H.264+A​​AC 样片、PNG 抽帧、PCM WAV、拼接输出及 ffprobe JSON 断言。

- [ ] **Step 1: 编写冒烟脚本并先对缺少 tools 的空目录运行，确认明确失败。**
- [ ] **Step 2: 对 Release tools 运行：合成两段测试源、抽帧、提取音频、拼接并验证流数量、尺寸、帧率与时长。**
- [ ] **Step 3: 将冒烟脚本放在 Release 构建后、产物上传前执行。**
- [ ] **Step 4: 运行 `flutter analyze`、完整 `flutter test`、Release 构建、字幕冒烟与媒体冒烟。**
- [ ] **Step 5: 更新基线证据并提交 `test: 验证 Windows 真实媒体链路`**。

### Task 5: 合并与远端复验

**Files:**
- No source changes.

**Interfaces:**
- Consumes: 已验证的 `feature/windows-bundled-tools`。
- Produces: 更新后的 `main`、GitHub Actions 绿色运行与可下载 Release artifact。

- [ ] **Step 1: 检查分支 diff、提交历史、第三方许可文件和工作树。**
- [ ] **Step 2: 合并到 `main` 并通过仓库级 SSH 推送。**
- [ ] **Step 3: 守候 Windows CI，失败则读取日志、修复、重新验证。**
- [ ] **Step 4: CI 全绿后继续下一批 P1/P2，不把本批次误报为整个 Windows 项目完成。**
