# Windows 允许的平台差异

本文件是 Windows 版本相对 Mac 主项目允许差异的唯一清单，来源为已批准的 Windows 设计与
`docs/windows-port/02-功能对齐清单.md` 附二。每次吸收 `upstream/main` 时必须逐项复核；
实现方式可以不同，产品能力、项目数据、导出结果和失败可见性不得缩水。

| 范围 | Windows 规则 | 验收重点 |
|---|---|---|
| 窗口外壳 | 使用 Windows 原生标题栏、右上角最小化/最大化/关闭按钮和暗色标题栏 | 深色内容区与标题栏连续，系统窗口操作完整 |
| 系统菜单 | 不照搬 macOS `MainMenu.xib`；剪切、复制、粘贴、全选、撤销、重做和全屏由 Flutter/Win32 明确实现 | 每个系统级行为逐个验证，不能因没有菜单栏而丢失 |
| 主修饰键 | `Ctrl` 替代 Command，统一通过平台修饰键抽象使用 | `Ctrl+C/V/X/A/Z`、重做和全局快捷键均可用 |
| 多选 | 使用 `Ctrl+点击`，不检查 `isMetaPressed` | 编导台、时间线和列表选择行为一致 |
| 文件定位 | 文案为“在资源管理器中显示”，调用 `explorer.exe /select,"<path>"` | 文件和目录均能被准确选中或打开 |
| 命令文案 | 面向 Windows 用户写“在 PowerShell 中运行”，命令必须是 PowerShell/Windows 版本 | 不出现 `brew`、`open`、`chmod`、`/bin/sh` 等不可执行配方 |
| 路径显示 | 显示完整 Windows 路径或 `%USERPROFILE%`，不以 `~` 作为主要用户文案 | 盘符、反斜杠、空格、中文和 OneDrive 重定向均正确 |
| 默认成片目录 | 使用 Windows Known Folder `Videos` 下的 `ishkafel`，不手拼 `~/Movies` | 尊重系统重定向后的真实 Videos 位置 |
| 等宽字体 | 使用 `Cascadia Mono` 或 `Consolas`，统一通过 `platformMonospaceFontFamily` | 路径、JSON、命令和 ID 保持等宽对齐 |
| 滚动条 | 使用覆盖式、自动隐藏的 `ScrollbarTheme`，避免占位挤压三栏 | 各 DPI 和窗口宽度下不改变内容布局 |
| 滚轮缩放 | 对 Windows 鼠标滚轮的离散 120 单位设置独立 scale | 一格滚轮不会产生过大跳变，触控板仍连续 |
| 安装和签名 | 开发产物为 `.exe`，正式分发使用 MSIX 与 Windows 代码签名 | 安装、卸载、升级、签名校验和回滚可验证 |
| 提权 | 默认无提权用户级安装，写入 `%LOCALAPPDATA%` 并更新用户 PATH | 普通用户可安装，系统目录不被静默修改 |
| 隐私与信誉 | Windows 没有 macOS TCC 流程；需处理 Defender/SmartScreen 与未签名提示 | 已签名包不出现未知发布者，失败提示可操作 |
| 日志 | GUI 无控制台时写入可轮转文件日志，stderr 仅作辅助 | 打包版错误可定位，日志不包含 `.secrets` |
| 预览体检 | 使用 `scripts/windows/preview_health.ps1` 驱动 Windows Release 真播；判据继续复用 `tool/preview_health.dart` | 和 Mac 一样检查画面重建、硬跳、规格、代理失败、音画偏差和时钟卡顿，不能只跑单元测试 |

## 同步时的判定

- 上游新增功能默认必须对齐；不能把“Windows 暂时没做”加入本表来规避实现。
- 涉及数据模型、Agent/CLI 能力、媒体时间线、字幕像素、音频轨或导出内容的差异不属于平台差异。
- 新增平台差异必须先修改书面设计和本表，并在同一个 PR 中加入 Windows 测试与真机证据。
- 同步 PR 不能自动合并；冲突要保留为可见 issue，适配完成后再走 Windows CI。

未列出的产品行为、数据与视觉差异均视为 bug。
