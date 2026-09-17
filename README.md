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

## Windows 使用与依赖

正式包已经内置固定版本的 `ffmpeg.exe` / `ffprobe.exe`、字幕渲染器和 CLI，用户不需要
安装 Homebrew、winget 或单独配置 FFmpeg。素材库检索仍需要 miaoa 提供 Windows CLI；
在它可用之前，对应诊断会明确报缺失，不会静默假装完成。

`audio-separator` 只在换配乐并分离人声时需要，可用 Windows 版 `uv` 安装：

```powershell
uv tool install "audio-separator[cpu]"
```

### AI 凭据（正式内部构建必需）

放在项目根目录的 `.secrets/`（已 gitignore），三个文件：

```
.secrets/ark_api_key           # 火山方舟：打标、语义切分、画面复核
.secrets/speech_app_id         # 语音技术：ASR、换音色合成
.secrets/speech_access_token
.secrets/windows_update_signing_public_key  # 更新清单验签公钥，可内置
```

正式包由 `scripts\windows\build_app.ps1` 在编译期注入。凭据不全时应用可以做无凭据
编译验证，但分析与打标不可用，因此这种构建不能作为正式交付物。

## Windows 开发与分发

```powershell
flutter test
flutter analyze
powershell -ExecutionPolicy Bypass -File scripts\windows\build_app.ps1 -Mode Release
powershell -ExecutionPolicy Bypass -File scripts\windows\package_app.ps1 -SkipBuild
powershell -ExecutionPolicy Bypass -File scripts\windows\capture_app.ps1
```

分发脚本同时生成版本化 MSIX、便携 ZIP、`distribution.json` 和 SHA-256 清单。若
`.secrets\windows_signing.pfx` 与 `.secrets\windows_signing_password` 存在，会签名
EXE/DLL 和 MSIX 并验证；公开发布必须增加 `-RequireSigning`，没有受信任证书就失败。
未签名 MSIX 只用于验证包结构，便携 ZIP 只用于内部真机测试。

Windows SDK Build Tools 从 Microsoft 官方 NuGet 固定版本下载并校验哈希；版本、地址、
哈希和许可入口记录在 `third_party\windows_sdk\build_tools.json`。

Windows 自动更新发布便携 ZIP，并固定使用 `windows/latest.json` 与
`windows/releases/`；即使 Mac 与 Windows 共用同一个私有 TOS bucket，也不会互相覆盖更新清单。
清单使用 Ed25519 签名：`dart run tool/update_signing_key.dart` 只需初始化一次；私钥
仅由发布工具读取，员工软件只内置公钥。`0.1.238` 是一次性手动安装的引导版，之后
可在 App 内完成下载、验签、替换和重启。
