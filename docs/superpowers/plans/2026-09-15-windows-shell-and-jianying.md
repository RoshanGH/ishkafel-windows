# Windows Shell 与剪映接入实施计划

**目标：** 清除 GUI 中残留的 macOS `open`/访达假设，让导出目录、数据目录、剪映草稿目录和剪映启动在 Windows 上使用原生路径与资源管理器。

**架构：** 操作系统命令只进入 `core/platform/PlatformShell`，业务页面通过可注入异步接口调用；剪映的草稿目录与程序发现进入 `core/jianying`，页面不认识 `%LOCALAPPDATA%`、`explorer.exe` 或 `VideoFusion-macOS`。Mac 行为保持不变，Windows 以 `%LOCALAPPDATA%\JianyingPro\User Data\Projects\com.lveditor.draft` 为默认草稿根目录。

**技术栈：** Dart 3.13、Flutter 3.47、Windows `explorer.exe`、macOS `open`、Flutter test。

## Task 1：平台 Shell 打开与定位契约

- [x] 先写失败测试：Windows 打开目录、选中文件分别生成 `explorer.exe <path>` 与 `explorer.exe /select,<path>`；macOS 保持 `open <path>` 与 `open -R <path>`。
- [x] 给 `PlatformShell` 增加可注入的异步 runner、非零退出码错误和 `openPath`/`revealPath`。
- [x] 添加架构守卫，禁止已迁移页面再出现 `Process.run('open', ...)`。
- [x] 目标测试转绿并提交。

## Task 2：导出与设置页改用平台服务

- [x] 先扩展现有 Widget 测试，验证 Windows 文案显示“在文件资源管理器中显示”，点击仍走注入接口。
- [x] `export_dialog.dart` 的默认输出目录改用平台目录契约，不再读取 `HOME/Movies`；默认 reveal 改走 `PlatformShell`。
- [x] `about_section.dart` 改走平台服务，并按系统显示访达/文件资源管理器文案。
- [x] 目标测试与分析转绿并提交。

## Task 3：工作台与编导台剪映接入

- [ ] 先写失败测试：Windows 剪映草稿根目录来自 `LOCALAPPDATA`，Mac 仍来自 `HOME/Movies`；缺变量时给出可执行错误而不是写入相对目录。
- [ ] `JianyingWriter` 使用平台化草稿目录；Windows 程序发现检查显式环境覆盖、已知安装目录和注册表/系统解析结果。
- [ ] 工作台与编导台的“显示草稿”“打开剪映”改走可注入服务，按钮文案平台化，失败时向用户显示原因。
- [ ] 添加架构守卫，确保两个页面不再直接出现 macOS `open`。
- [ ] 目标测试转绿并提交。

## Task 4：回归、合并与远端验证

- [ ] `flutter analyze`、完整 `flutter test`、Windows Release 构建、字幕与媒体冒烟全部通过。
- [ ] 审查与 Mac 上游的共享代码差异，确认平台判断均收口且 Mac 测试未退化。
- [ ] 合并到 `main`、SSH 推送并守候 Windows CI 全绿。
