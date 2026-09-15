# ishkafel

> **Windows 独立项目：`RoshanGH/ishkafel-windows`**
> Mac 主项目为 [`RoshanGH/ishkafel`](https://github.com/RoshanGH/ishkafel)，在本仓库中记为
> `upstream`。每天的自动同步只创建 PR，必须经过 Windows CI 和人工复核，永不自动合并。

本仓库保留与 Mac 主项目的共同 Git 历史，但拥有独立的 Windows 实现、发布节奏和问题跟踪。
允许的平台差异只有 [`docs/platform-differences.md`](docs/platform-differences.md) 中登记的项目；
未登记的产品行为、数据与视觉差异都视为 bug。

## Windows 开发入口

在 PowerShell 中运行：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\windows\check_environment.ps1
powershell -ExecutionPolicy Bypass -File scripts\windows\build_app.ps1 -Mode Release
powershell -ExecutionPolicy Bypass -File scripts\windows\build_cli.ps1
```

正式 GUI 构建从项目根目录的 `.secrets/` 读取必需配置并在编译期注入；脚本不会回显密钥。
本地检查 Mac 更新可运行 `scripts\windows\sync_upstream.ps1`，需要推送同步分支时增加 `-Push`。

素材生产平台（替换裂变 / 脚本成片）：分析一条成片，按台词语义切分，从 miaoa 素材库检索
同标签素材替换画面，本地合成导出多条变体。

概念与流程见 [docs/术语表.md](docs/术语表.md) 与
[docs/2026-07-29-项目方向与架构设计.md](docs/2026-07-29-项目方向与架构设计.md)。

## 第一次在一台新机器上跑，要装什么

四样东西。装完**重启应用**——macOS 上由 Finder 启动的 GUI 进程继承的是
launchd 的空 PATH，应用只在启动时去那几个常见目录里找这些工具。

### 1. ffmpeg / ffprobe（必需）

抽帧、切片、合成成片都靠它。

```sh
brew install ffmpeg
```

### 2. miaoa CLI（必需）

素材库检索、标签体系、项目列表。装好后要登录一次：

```sh
miaoa auth login
```

登录失效时应用里会提示重新执行这条命令。

### 3. audio-separator（换配乐要用）

把原片音频拆成「纯人声口播」与「纯背景音」两条轨。**不装也能用**：分析照常
完成，只是替换配乐时新曲子会和原片自带的背景音叠在一起（应用里会说明）。

```sh
uv tool install "audio-separator[cpu]"
```

装完约 1GB（主要是 PyTorch）；首次分析时会再自动下载分离模型（64MB）。之后
每条 96 秒的片子分离约 15 秒，跑在分析流程里。

> 模型选型是拿音质换速度：同一条素材上，BS-Roformer 分得几乎只剩人声但要
> 81 秒、模型 610MB；当前这个 MDX 模型 15 秒、64MB，代价是人声里还留着一些
> 背景音乐。换模型只需改 `VocalSeparator.model` 一个常量。
>
> 另记一笔：这几个模型的差异**用指标测不出来**（RMS、频段能量、包络相关性
> 的差异全在 -30dB 以下），只能靠听。

### 4. AI 凭据（必需）

放在项目根目录的 `.secrets/`（已 gitignore），三个文件：

```
.secrets/ark_api_key           # 火山方舟：打标、语义切分、画面复核
.secrets/speech_app_id         # 语音技术：ASR、换音色合成
.secrets/speech_access_token
```

打包版从 `--dart-define` 注入，见 `scripts/build_macos.sh`；开发期从上面这个
目录读。凭据不全时应用照常启动，只是分析与打标不可用，并在界面上说明原因。

## 开发

```sh
flutter test          # 全量测试
flutter analyze
./scripts/build_macos.sh && open build/macos/Build/Products/Debug/ishkafel.app
```
