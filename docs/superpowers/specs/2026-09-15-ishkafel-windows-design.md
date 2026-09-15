# ishkafel Windows 独立项目设计

日期：2026-09-15
状态：书面评审版
基线：`RoshanGH/ishkafel` `main@96162c5`（0.1.228）

## 1. 决策摘要

Windows 版是一个独立项目和独立 GitHub 仓库：
`RoshanGH/ishkafel-windows`。它不是 Mac 仓库里的 Windows 分支，也不是一次性复制后
各自演化的分叉。两个仓库保留共同 Git 历史，Windows 仓库持续把
`RoshanGH/ishkafel` 的 `main` 当作产品与共享业务代码的上游。

技术栈采用“Flutter 工作台 + 原生媒体底座”：

- Flutter/Dart 继续承载现有界面、时间线、领域模型、Agent 能力和绝大多数测试。
- `media_kit` / libmpv 承载交互预览，在 Windows 上使用 GPU 加速渲染和安全的硬件解码。
- 固定版本的 FFmpeg/ffprobe 承载视频分析、切片、变速、拼接、音频处理和最终导出。
- C++17、Win32、D3D11 和 Dart FFI/辅助进程只用于平台接入与已经由基准证明的性能热点，
  不为了“原生”重写 8.9 万行 Flutter/Dart。
- PowerShell 承载开发、构建、同步和发布脚本；MSIX 是正式安装包格式。

“Windows 原生”在本项目中的定义是：生成真正的 Win32 桌面程序，使用 Windows
标题栏、快捷键、文件对话框、Known Folders、资源管理器、控制台编码、DPI、单实例、
安装、签名和更新机制；它不等于把产品 UI 改写成 WinUI 或 Qt。

## 2. 产品边界

### 2.1 必须保持一致

- 两条生产线：替换裂变与脚本成片。
- 两层切分、底片、候选检索、画面复核、多轨预览、两层声音、矩阵导出和剪映草稿。
- 全量 CLI、Agent 技能手册、可视化执行和 GUI/CLI 写锁让位机制。
- 领域模型、任务文件格式、缓存指纹规则、导出规格和“不静默降级”原则。
- 产品布局、间距、配色、字号、轨道尺寸、交互规则与中文文案。
- 相同任务、方案、字体、FFmpeg 版本与导出参数得到可比对的成片。

### 2.2 允许使用 Windows 行为

- Windows 原生标题栏与右上角窗口按钮，标题栏保持暗色。
- `Ctrl` 替代 `Command`，Windows 右键菜单和滚轮手感。
- “在资源管理器中显示”、PowerShell 文案、完整 Windows 路径和 Videos 目录。
- Windows 文件选择器、DPI、滚动条、UAC、日志、安装、签名和更新机制。
- Windows CLI 使用 UTF-8，安装到用户目录，不依赖管理员权限。

### 2.3 本轮不做

- 不把 ishkafel 扩展成拥有任意轨道、实时调色、粒子特效和插件生态的完整 NLE。
- 不照搬无法验证的剪映私有实现。
- 不以 Qt、WinUI、Electron 或 Tauri 重写已经稳定的业务与 UI。
- 不默认启用会破坏跨平台成片一致性的硬件编码器。

## 3. 仓库拓扑与持续跟随 Mac

Windows 本地仓库保留两个远端：

```text
origin    git@github.com:RoshanGH/ishkafel-windows.git
upstream  git@github.com:RoshanGH/ishkafel.git
```

`main` 始终是可构建、可测试的 Windows 产品线。同步机制如下：

1. GitHub Actions 每天检查一次 `upstream/main`，也支持手动触发。
2. 上游有新提交时，创建或更新 `sync/macos-<上游短 SHA>` 分支和同步 PR。
3. 同步采用 Git merge，保留共同历史；不把上游提交复制成无法追溯的散落 cherry-pick。
4. 同步 PR 跑 Windows 分析、测试、构建、平台契约和性能冒烟测试。
5. 同步永不自动合并。路径、外部命令、字体、字幕、更新、剪映集成等平台敏感改动由
   Codex 或维护者复核并解决冲突后合并。
6. 平台无关的修复和抽象优先反向提交到 Mac 上游，使两个仓库的共享代码重新收敛。
7. `docs/platform-differences.md` 是允许差异的唯一清单；未登记的差异视为缺陷。

同步 PR 记录“上次已吸收的 upstream SHA”。连续多次上游更新只维护一个开放同步 PR，
避免每天产生重复 PR。

## 4. 总体架构

```text
Flutter / Dart 产品层
  UI、时间线、领域模型、Agent、CLI 命令语义
                 │
                 ▼
稳定契约层
  PlatformPaths / PlatformShell / PlatformTools / PlatformUpdater
  PreviewEngine / RenderEngine / SubtitleRenderer / AudioEngine
                 │
        ┌────────┴────────┐
        ▼                 ▼
Windows 平台层        原生媒体层
Win32 / COM / FFI      libmpv / D3D11
PowerShell / MSIX      FFmpeg / 字幕辅助进程
```

业务代码不得直接散落 `Platform.isWindows`。平台判断只允许出现在装配点和平台实现中。
每个接口有一组共享契约测试；Windows 实现可以在普通单测中通过注入环境、文件系统和
进程执行器验证。

## 5. 媒体架构

### 5.1 时间表示

编辑模型以“时间基 + 整数帧号”作为帧级操作的权威表示，毫秒只用于 UI 展示和外部
接口。导入时保存源文件 time base、平均帧率、真实帧率与 VFR/CFR 信息。随机定位先到
关键帧，再顺序解码到目标帧；暂停后的最终画面必须落在目标帧，不能用近似毫秒代替。

### 5.2 导入与分析

1. ffprobe 读取编码、分辨率、帧率、时长、色彩和音频信息。
2. 计算源文件内容指纹，决定分析、代理、缩略图、波形和中间产物能否复用。
3. 1080p 常规素材直接预览；4K、高码率、解码不稳或长 GOP 素材后台生成代理。
4. 场景信号、批量抽帧和音频 PCM 由 FFmpeg 原生进程完成，Dart 不搬运像素帧。
5. `LocalWorkGate` 控制本地重活并发，避免多个 FFmpeg 进程把 CPU、磁盘和显存同时打满。

### 5.3 预览

`PreviewEngine` 初始实现继续使用 `media_kit`/libmpv。Windows 优先使用 D3D11 相关
GPU 路径和经过白名单验证的硬件解码；失败时允许预览退回软件解码，但必须在诊断信息中
可见。Flutter 只绘制工作台、时间线、选区、播放头和实时字幕，不接收原始视频帧。

代理只服务预览。逐帧边界、最终导出和交付物始终引用原始素材。代理与原片通过内容
指纹、时间基和帧映射绑定，代理失效不会污染成片。

### 5.4 音频

- FFmpeg 负责抽取、裁切、重采样、变速、拼接、混音、响度和过载检测。
- `audio-separator` 作为隔离的后台工具运行；输入、模型和参数进入缓存指纹。
- Windows 可使用 CUDA 加速人声分离，但 CPU 路径仍是可验证的兼容基线。
- 预览与导出共用 `AudioTrackBuilder` 语义，避免“听到的”和“导出的”走两套规则。
- 任何缺失的人声、背景、配音或配乐都是明确失败，不允许静默少一轨。

### 5.5 导出

- 正式导出读取原始素材，按内容指纹复用未变化的片段和音轨。
- FFmpeg 进程并发按机器能力自适应，初始上限沿用已验证的 3；每个 FFmpeg 本身已多线程，
  不盲目增加进程数。
- 默认使用固定参数的 libx264 软件编码，Mac 和 Windows 使用同一 FFmpeg 构建、字体和
  滤镜参数。
- NVENC 可以在后续作为明确标注的“极速导出”模式增加，但不得成为默认值，也不得宣称
  与确定性模式逐像素一致。
- 临时产物先写 `.part`，成功后原子替换；取消、超时和崩溃不会留下可被误认成缓存的半成品。

## 6. 字幕渲染决策

交接包建议用 `dart:ui` 重写字幕，但独立 CLI 通过 `dart compile exe` 构建，且架构守卫
禁止 CLI 依赖 Flutter。直接把 `dart:ui` 放进共享导出链会让 CLI 无法编译，因此不采用。

建立跨平台 `ishkafel_renderer` 辅助进程：

- C++17 实现，绑定固定版本的 Skia、HarfBuzz/FreeType 与随包开源字体。
- GUI 与 CLI 都通过同一份 JSON 输入调用它，输出透明 PNG 和文本框布局数据。
- 字体、字号千分比、折行、描边、字芯、圆角底条与坐标规则进入版本化协议和缓存指纹。
- 辅助进程隔离字体/渲染崩溃；stderr 和结构化错误返回给 Dart，不会拖垮 GUI。
- Windows 与 Mac 从同一源码构建，并以现有 AppKit/JXA 样张做视觉回归。
- 在新渲染器通过人工叠图验收前，Mac 上游不移除原实现。

这样既满足 CLI 边界，也给两个平台一个真正相同的字幕实现。Qt 不进入字幕或媒体核心。

## 7. Windows 平台实现

- `PlatformPaths` 使用 `SHGetKnownFolderPath` 获取 Roaming AppData、Local AppData、
  Desktop、Videos 和 Temp，正确处理 OneDrive 重定向。
- `PlatformShell` 负责 `where.exe`、资源管理器打开/选中、进程存活、单实例唤醒、
  `CreateHardLinkW` 及复制回退。
- `PlatformTools` 先寻找安装目录内置工具，再检查用户 PATH；处理 `.exe/.cmd/.bat`
  和分号分隔。
- CLI 启动即设置 UTF-8 输入输出，中文 JSON 在 PowerShell、重定向和 Agent 调用中保持一致。
- Win32 runner 实现 1440×900 默认窗口、1100×880 最小窗口、DPI 换算、居中、暗色标题栏、
  单实例和激活已有窗口。
- 文件名统一过滤 Windows 非法字符、保留设备名以及末尾点和空格。
- 应用日志写入 Local AppData，滚动并限制总量；日志绝不包含密钥和访问令牌。

## 8. 工具、安装和更新

- 安装包内置相同固定版本的 LGPL FFmpeg/ffprobe，不依赖 winget、Chocolatey 或用户 PATH。
- CLI 与字幕辅助进程随应用安装，并在用户目录创建 `.cmd` shim；不要求管理员权限。
- 正式分发使用 MSIX。开发阶段使用本机测试证书，公共分发采用 Microsoft Store 签名或
  受信任的代码签名证书，避免把自签名证书当作正式方案。
- 更新包校验 SHA-256 和发布签名后再安装。更新失败保留现有版本并给出可操作错误。
- 构建脚本统一读取 `.secrets` 并传入所需 dart defines；裸 `flutter build windows`
  只允许做无凭据编译检查，不作为交付物。
- 凭据文件放入用户数据目录并收紧 Windows ACL；构建、日志、崩溃信息和 Git 均不得收集密钥。

## 9. 性能目标

首台基准机：Windows 11、Intel i5-12400F、32GB RAM、RTX 3060 12GB、NVMe SSD。
它超过 CapCut 官方推荐的 i5/Ryzen 5、8–16GB RAM、4GB 以上独显与 SSD 配置。

兼容目标是导入和导出最高 4K 60fps。交互目标区分原片和代理：

- 1080p60 H.264 常规素材可用原片连续预览。
- 4K60、高码率、HEVC 或长 GOP 素材允许自动使用 1080p 代理连续预览。
- 暂停后逐帧定位误差为 0 帧；随机定位 p95 不超过 250ms，向后跨 GOP 定位 p95
  不超过 500ms。
- 稳态预览掉帧率低于 1%；Flutter UI 在 60Hz 下保持响应，不出现超过 100ms 的主线程停顿。
- 4K 项目正常编辑期间应用及媒体辅助进程合计内存目标低于 6GB。
- 第一份可运行构建记录分析、代理和导出基线；相同样本、配置和机器上的后续版本不得
  无解释地退化超过 10%。确定性导出以正确和一致为先，不承诺 4K60 实时编码。

达不到目标时先用时间线、CPU、GPU、磁盘和 FFmpeg 日志定位瓶颈。只有证据表明
Flutter/Dart 边界是瓶颈时，才把对应模块下沉到 C++/D3D11；不以整体重写代替测量。

## 10. 错误处理与恢复

- 平台能力在启动和设置页显式自检：工具、GPU 解码、数据目录、素材库登录和凭据分别报告。
- 错误采用稳定代码、中文说明、底层诊断和可执行恢复动作四部分。
- 预览可以在告知用户后降级；分析缺数据、字幕失败、音轨缺失、成片少段等交付错误必须中止。
- 所有长任务支持进度、取消和超时。退出后通过指纹缓存断点续跑，不把失败缓存当成功。
- 任务文件使用临时文件加原子替换，GUI/CLI 继续通过现有任务锁保证单写入者。
- 外部工具崩溃不带崩 GUI；辅助进程退出码、stderr 尾部和日志路径一并展示。

## 11. 测试与验收

### 11.1 自动化

- 现有 `flutter analyze` 与完整单元测试全部在 Windows 通过。
- 平台路径、shell、工具、更新和字幕接口运行共享契约测试。
- 架构测试禁止业务层散落平台判断，禁止 CLI import Flutter，守住现有领域边界。
- Windows 路径测试覆盖中文、空格、盘符、UNC、OneDrive、保留名和跨卷复制。
- FFmpeg 命令测试覆盖盘符冒号、反斜杠、VFR、音轨缺失和进程取消。
- 字幕以固定字体和固定参数生成 golden PNG，并同时做 Mac/Windows 人工叠图。
- 1440×900 逐页面截图与现有 28 张基准图对比；允许差异只来自平台差异清单。
- 真实小样本端到端覆盖导入、分析、预览、逐帧、替换、音频、矩阵导出、剪映草稿和 CLI。
- 性能基准保存机器、媒体指纹、工具版本和测量结果，CI 运行低成本冒烟，正式里程碑跑完整基准。

### 11.2 完成标准

Windows 独立项目只有同时满足以下条件才算立项与首版移植完成：

1. 本地 `ishkafel-windows` 有独立 `origin`、Mac `upstream` 和干净提交历史。
2. GitHub SSH 主机指纹经过官方值校验，Ed25519 密钥通过 `ssh-agent` 免密使用，
   `ssh -T git@github.com` 返回正确账号。
3. `RoshanGH/ishkafel-windows` 远端存在，初始代码、规范和 CI 已推送。
4. Windows 开发工具链通过 `flutter doctor -v`，分析、测试和 Release 构建成功。
5. Windows 真机完成一条小样本的完整产品流程，且没有静默功能缺失。
6. UI 基准、字幕样张、成片、剪映草稿和性能基准均有可复核证据。
7. 上游同步工作流能检测 Mac 新提交、创建同步 PR，并由 Windows CI 阻止不兼容合并。

## 12. 实施顺序约束

实施计划必须先建立干净基线，再处理 P0 平台契约、字幕与字体，随后处理系统集成、
工具分发、剪映、安装更新，最后完成视觉和性能验收。移植期间不同时重构
`director_page.dart`、`workbench_page.dart` 等超大业务文件；平台边界稳定、测试全绿后
再另立重构任务，避免把移植回归与结构调整混在一起。
