# Windows 可配置存储与 D 盘迁移实施计划

> For agentic workers: REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan.

**Goal:** 为 Windows 版增加注册表持久化的可配置数据/导出目录，并把本机 Ishkafel 项目物料安全迁移至 `D:\Ishkafel`，最后通过真实视频全链路验收。

**Architecture:** 在平台层增加 Windows 用户存储设置，运行时目录解析集中处理环境变量、注册表和默认值的优先级。设置页通过可注入的迁移服务完成复制与逐文件 SHA-256 校验，成功后切换注册表；导出流程从统一的默认导出目录提供者获取初始目录。Mac 与其他平台保持现有默认行为。

**Tech Stack:** Flutter/Dart、Riverpod、`file_selector`、Windows `reg.exe`、PowerShell、Flutter test。

---

### Task 1: Windows 存储设置与运行时路径解析

**Files:**
- Create: `lib/core/platform/windows_storage_preferences.dart`
- Modify: `lib/core/platform/runtime_directories.dart`
- Modify: `lib/core/platform/platform_paths.dart`
- Modify: `lib/cli/data_dir.dart`
- Create: `test/core/platform/windows_storage_preferences_test.dart`
- Modify: `test/core/platform/runtime_directories_test.dart`
- Modify: `test/cli/data_dir_test.dart`

**Steps:**
1. 写失败测试，覆盖环境变量优先级、注册表设置、未配置回退和 CLI/GUI 一致性。
2. 运行目标测试确认因缺少实现而失败。
3. 实现可注入的注册表读取/写入接口和集中路径解析，不影响非 Windows 平台。
4. 运行目标测试直至通过。
5. 提交原子提交。

### Task 2: 安全数据迁移服务

**Files:**
- Create: `lib/core/platform/storage_migration_service.dart`
- Create: `test/core/platform/storage_migration_service_test.dart`

**Steps:**
1. 写失败测试，覆盖复制并逐文件 SHA-256 校验、源目标相同、目标嵌套、复制/校验失败不切换配置。
2. 运行测试确认红灯。
3. 实现流式复制、相对路径清单和校验结果；不在服务内删除源目录。
4. 运行测试确认绿灯，并检查错误消息不泄漏文件内容或凭据。
5. 提交原子提交。

### Task 3: 设置页与默认导出目录

**Files:**
- Modify: `lib/features/settings/presentation/settings_page.dart`
- Modify: `lib/features/workbench/presentation/workbench_page.dart`
- Modify: `lib/main.dart`
- Modify/Create: 对应设置页、导出目录 Widget/Provider 测试。

**Steps:**
1. 写失败测试，验证“存储位置”区块、目录选择/保存、迁移失败反馈和默认导出目录优先级。
2. 运行目标测试确认红灯。
3. 增加 Provider/控制器和设置界面，调用 `getDirectoryPath`；数据目录迁移成功后保存并提示重启，导出目录即时保存。
4. 将工作台首次导出目录接入统一提供者，同时保留任务上次导出目录的最高业务优先级。
5. 运行目标测试、完整 `flutter test` 和 `flutter analyze`。
6. 提交原子提交。

### Task 4: 构建并迁移到 D 盘

**Files:**
- Modify/Create: `scripts/windows/migrate_to_data_drive.ps1`
- Create: `test/scripts/windows/migrate_to_data_drive_test.ps1`（或等价 Pester/脚本 dry-run 断言）
- Update: `docs/windows/` 中的用户操作和迁移说明。

**Steps:**
1. 以 dry-run 测试固定精确的源/目标映射和拒绝宽泛删除规则。
2. 编写幂等 PowerShell 脚本：关闭应用、建立 D 盘布局、复制、文件数量/字节/SHA-256 校验、写入 HKCU 设置、生成单一快捷方式。
3. 脚本先只复制不删除；从 D 盘运行 Release 应用并加载迁移后的真实任务。
4. 更新真实任务中指向源视频和导出物的绝对路径，验证播放、时间线和真实导出。
5. 通过验证后仅删除脚本记录且校验通过的精确 C 盘源目录，保留迁移清单和哈希报告。

### Task 5: 最终验证、推送与交付

**Files:**
- Create: `D:\Ishkafel\Deliverables\migration-report.json`
- Update: `docs/windows/REAL_MACHINE_ACCEPTANCE.md`

**Steps:**
1. 在 D 盘源码运行完整测试、静态分析和 Release 构建。
2. 用真实视频在 D 盘应用中打开任务、播放、检查素材并完成一次导出；用 `ffprobe` 和解码测试验证结果。
3. 检查桌面仅一个 Ishkafel 快捷方式且目标在 D 盘。
4. 检查 C 盘列明的项目大目录不存在，并记录不可避免的小型系统集成残留。
5. 检查 Git diff 无凭据，提交并推送到 `origin/main`；验证 GitHub 远程提交。
6. 将最终报告和必要交付物同步到 D 盘 Deliverables，并向用户报告启动入口和真实测试方法。

