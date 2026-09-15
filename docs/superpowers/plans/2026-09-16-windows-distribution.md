# Windows 分发与安全更新实施计划

日期：2026-09-16
依据：`docs/superpowers/specs/2026-09-15-ishkafel-windows-design.md`

## 目标

把已经能构建的 Windows Release 目录变成两种可复核产物：正式方向的 MSIX 和用于
内部验证的便携 ZIP。两种产物都必须包含 GUI、字幕渲染器、CLI、固定版本
FFmpeg/ffprobe 及许可文件。签名材料存在时签名所有可执行文件和 MSIX；不存在时明确
标记为未签名开发产物，不把自签名伪装成公开发布方案。

同时补齐 Windows 自动更新契约：Windows 只替换应用目录，不向上跳错目录；替换脚本
等待旧进程退出，失败恢复旧版本；签名校验发生在替换前；PowerShell 后台启动不弹控制台。

## 实施步骤

1. 先写分发契约测试，锁定 Release 构建入口、随包文件、固定 SDK 工具、哈希校验、
   MSIX manifest、可选签名和版本化 SHA-256 清单。
2. 增加固定版本 Windows SDK Build Tools 清单，只从 Microsoft 官方 NuGet 地址下载并
   校验 SHA-256，再使用其中的 `makeappx.exe` / `signtool.exe`。
3. 增加 `packaging/windows/AppxManifest.xml.in`，声明 x64 packaged classic desktop app、
   `runFullTrust`、Windows 10 1809 最低版本和最小能力集合。
4. 增加 `scripts/windows/package_app.ps1`：可调用正式 `build_app.ps1`，验证 Release 目录，
   生成应用图块，原子生成便携 ZIP、MSIX、SHA-256 清单和分发说明。
5. 有 PFX 时从证书读取 Publisher，先签 EXE/DLL 再签 MSIX，并逐一验证；无 PFX 时保留
   未签名标识，脚本成功但禁止 `-RequireSigning`。
6. 为 Windows 更新路径补平台测试和真 PowerShell 替换测试；修复后台 handoff、权限文案、
   工作目录残留等差异。
7. 全量测试、静态检查、Release 构建、渲染器与媒体烟测、打包烟测；合并推送后等待
   GitHub Windows CI，并下载云端产物复核。

## 不在本批擅自完成的外部动作

- 不购买或申请公开代码签名证书。
- 不把自签名根证书静默装进用户信任库。
- 不把含 AI 凭据的包公开发布，也不触发线上 TOS 更新清单。
- Windows 剪映真实启动/导入必须在安装了剪映且有真实项目数据的机器上做，自动测试只守契约。
