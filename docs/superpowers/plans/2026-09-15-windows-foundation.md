# ishkafel Windows 基础立项实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在当前电脑上建立可验证的 Windows 开发环境、独立本地与 GitHub 仓库、Windows 构建基线、SSH 免密码认证、CI，以及持续吸收 Mac 主项目更新的同步 PR 机制。

**Architecture:** Windows 仓库保留与 `RoshanGH/ishkafel` 的共同 Git 历史，`origin` 指向独立 Windows 项目，`upstream` 指向 Mac 主项目。此计划不开始大规模平台移植；它先让原代码在真实 Windows 工具链上暴露基线问题，并把后续平台、媒体和交付改造放进可重复构建与上游同步的安全网。

**Tech Stack:** Flutter 3.47.4 stable、Dart 3.13.3、Visual Studio 2022 Desktop development with C++、PowerShell 7、Git/OpenSSH、GitHub CLI、GitHub Actions、Flutter Windows Win32 runner。

**Spec:** `docs/superpowers/specs/2026-09-15-ishkafel-windows-design.md`

## Global Constraints

- Windows 项目是独立仓库 `RoshanGH/ishkafel-windows`；Mac 仓库保持 `RoshanGH/ishkafel`，不把 Windows 版做成它的分支。
- Windows 仓库的 `main` 必须持续吸收 `upstream/main`，但同步 PR 永不自动合并。
- 首台基准机固定记录为 Windows 11、i5-12400F、32GB RAM、RTX 3060 12GB、NVMe SSD。
- Flutter 固定为官方 stable `3.47.4`，归档 SHA-256 固定为 `31173300481bd06e377fd55ee84214689648b1817563efd7b450b7b78bdf351a`；升级必须单独提交并重跑完整基线。
- GUI、领域模型、Agent 与 CLI 继续复用 Dart；不得为了“原生”改写成 Qt、WinUI、Electron 或 Tauri。
- CLI import 链不得依赖 Flutter；`dart build cli` 是每个里程碑的硬门槛。
- 构建、日志、Git 和 CI 不得输出 `.secrets` 内容；正式构建继续注入 3 个必需 AI 值与 5 个可选更新值。
- 平台错误不得静默降级；预览降级必须可见，成片数据缺失必须失败并点名。
- 此计划只建立基础设施和真实基线，不顺手修改 P0 业务代码；基线失败进入下一份“Windows 平台契约与 P0”计划处理。

---

## File Structure

本计划创建或修改以下文件：

- `.gitattributes`：固定跨平台文本行尾规则，避免 Mac/Windows 同步 PR 出现全文件噪音。
- `scripts/windows/build_app.ps1`：唯一的 Windows GUI 正式构建入口，读取八个 dart define 且不回显值。
- `scripts/windows/build_cli.ps1`：构建 Windows x64 CLI 并验证产物。
- `scripts/windows/check_environment.ps1`：输出不含密钥的工具链与硬件诊断。
- `scripts/windows/sync_upstream.ps1`：本地检查并创建 Mac 同步分支。
- `.github/workflows/windows-ci.yml`：Windows analyze/test/CLI/app 构建门槛。
- `.github/workflows/sync-upstream.yml`：每日或手动检测上游，创建同步 PR；冲突时创建可见 issue。
- `test/architecture/windows_foundation_test.dart`：静态守卫基础脚本、CI、远端与同步策略。
- `docs/windows-port/08-Windows基线.md`：记录本机工具链和未经平台修复的真实命令结果。
- `docs/platform-differences.md`：Windows 允许差异的唯一清单入口。
- `README.md`：说明 Windows 独立仓库身份、构建入口与 upstream 关系。
- `CLAUDE.md`：加入 Windows 实施与真机验收规则。

---

### Task 1: 安装并验证 Windows 开发工具链

**Files:**
- No repository files changed.

**Interfaces:**
- Consumes: Flutter 官方 Windows stable 归档；Windows Package Manager。
- Produces: 可从新 PowerShell 会话调用的 `flutter`、`dart`、`gh`、MSVC、CMake 与 Ninja。

- [ ] **Step 1: 记录安装前状态**

Run:

```powershell
Get-Command git, ssh, flutter, dart, gh, cmake, ninja -ErrorAction SilentlyContinue |
  Select-Object Name, Source, Version
& 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe' `
  -latest -products * -format json -property installationPath
```

Expected: Git、OpenSSH 和 CMake 已存在；Flutter、Dart、GitHub CLI 与 Visual Studio 尚不存在。

- [ ] **Step 2: 安装 Visual Studio 2022 C++ 桌面工作负载**

Run:

```powershell
$vsInstallArgs = '--wait --passive --norestart --add Microsoft.VisualStudio.Workload.NativeDesktop --includeRecommended'
winget install --id Microsoft.VisualStudio.2022.Community --exact --source winget `
  --accept-source-agreements --accept-package-agreements --override $vsInstallArgs
```

Expected: `winget` exit 0；`vswhere` 返回一个安装目录。若系统弹 UAC，只批准来自 Microsoft 且签名有效的安装器。

- [ ] **Step 3: 安装 GitHub CLI**

Run:

```powershell
winget install --id GitHub.cli --exact --source winget `
  --accept-source-agreements --accept-package-agreements
```

Expected: `gh --version` exit 0。

- [ ] **Step 4: 下载并校验 Flutter 3.47.4**

Run:

```powershell
$toolchainRoot = 'C:\Users\Mayn\Documents\Codex\toolchains'
$flutterZip = Join-Path $env:TEMP 'flutter_windows_3.47.4-stable.zip'
$flutterUri = 'https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_3.47.4-stable.zip'
New-Item -ItemType Directory -Force -Path $toolchainRoot | Out-Null
Invoke-WebRequest -Uri $flutterUri -OutFile $flutterZip -NoProxy
$actualSha = (Get-FileHash -Algorithm SHA256 $flutterZip).Hash.ToLowerInvariant()
if ($actualSha -ne '31173300481bd06e377fd55ee84214689648b1817563efd7b450b7b78bdf351a') {
  throw "Flutter 归档校验失败：$actualSha"
}
Expand-Archive -LiteralPath $flutterZip -DestinationPath $toolchainRoot
```

Expected: `C:\Users\Mayn\Documents\Codex\toolchains\flutter\bin\flutter.bat` 存在。若目录已经存在，只在 `flutter --version` 精确匹配 3.47.4 时复用；不覆盖未知工具链。

- [ ] **Step 5: 将 Flutter 加入用户 PATH**

Run:

```powershell
$flutterBin = 'C:\Users\Mayn\Documents\Codex\toolchains\flutter\bin'
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$entries = @($userPath -split ';' | Where-Object { $_ })
if ($entries -notcontains $flutterBin) {
  [Environment]::SetEnvironmentVariable('Path', (($entries + $flutterBin) -join ';'), 'User')
}
$env:Path = "$flutterBin;$env:Path"
flutter config --enable-windows-desktop
```

Expected: `flutter config` exit 0；不删除用户 PATH 中任何已有条目。

- [ ] **Step 6: 验证完整工具链**

Run:

```powershell
flutter --version
dart --version
flutter doctor -v
gh --version
```

Expected: Flutter 3.47.4、Dart 3.13.3；`flutter doctor -v` 的 Windows 和 Visual Studio 两项通过。若不通过，保留完整输出并按 `superpowers:systematic-debugging` 查清根因后再进入 Task 2。

---

### Task 2: 取得未经修复的 Windows 基线

**Files:**
- Create: `docs/windows-port/08-Windows基线.md`

**Interfaces:**
- Consumes: Task 1 的 Flutter/MSVC 工具链；现有 `pubspec.lock`。
- Produces: 可复现的 analyze、test、CLI 和 Windows build 基线，供 P0 计划逐项消红。

- [ ] **Step 1: 确认仓库起点干净**

Run:

```powershell
git status --short --branch
git rev-parse HEAD
git remote -v
```

Expected: 只有本实施计划提交导致相对 `upstream/main` ahead；没有未解释的工作区改动。

- [ ] **Step 2: 解析锁定依赖**

Run:

```powershell
flutter pub get
```

Expected: exit 0，`pubspec.lock` 不发生无意变化。若 lockfile 变化，先解释 Flutter/Dart 解析差异，不将变化和基线报告混为一个提交。

- [ ] **Step 3: 运行静态分析**

Run:

```powershell
New-Item -ItemType Directory -Force -Path build\baseline | Out-Null
flutter analyze 2>&1 | Tee-Object -FilePath build\baseline\flutter-analyze.txt
$analyzeExit = $LASTEXITCODE
```

Expected: 保存完整日志和退出码；不预设通过。若失败，报告按错误类别和文件归组。

- [ ] **Step 4: 运行完整测试**

Run:

```powershell
flutter test 2>&1 | Tee-Object -FilePath build\baseline\flutter-test.txt
$testExit = $LASTEXITCODE
```

Expected: 保存总用例数、通过数、失败数和 skip 数；不把部分测试通过表述为全量通过。

- [ ] **Step 5: 验证纯 Dart CLI 边界**

Run:

```powershell
dart build cli 2>&1 | Tee-Object -FilePath build\baseline\dart-build-cli.txt
$cliExit = $LASTEXITCODE
```

Expected: 若成功，记录 Windows x64 bundle 位置；若失败，记录第一处属于本项目的堆栈和完整日志路径。

- [ ] **Step 6: 构建未经适配的 Windows Debug app**

Run:

```powershell
flutter build windows --debug 2>&1 | Tee-Object -FilePath build\baseline\flutter-build-windows-debug.txt
$windowsBuildExit = $LASTEXITCODE
```

Expected: 取得真实基线。编译成功不代表功能可用；字幕、路径、工具、窗口与 CLI 运行时问题仍进入 P0 计划。

- [ ] **Step 7: 写入基线报告**

Create `docs/windows-port/08-Windows基线.md`，固定包含：

```markdown
# Windows 原始基线

## 基准机器

- Windows 11 10.0.22621
- Intel Core i5-12400F（6 核 12 线程）
- 32GB RAM
- NVIDIA GeForce RTX 3060 12GB，驱动 560.81
- KINGSTON SNV2S1000G NVMe SSD

## 固定工具链

- Flutter 3.47.4 stable
- Dart 3.13.3
- Visual Studio 2022 Desktop development with C++

## 命令结果

逐项记录 `flutter doctor -v`、`flutter analyze`、`flutter test`、
`dart build cli` 和 `flutter build windows --debug` 的执行时间、退出码、
通过/失败数量、第一处根因，以及 `build/baseline/` 下的日志文件名。

## 已知运行时 P0

列出 `docs/windows-port/05-平台耦合清单.md` 的 7 项 P0；编译通过不得把它们标为解决。
```

- [ ] **Step 8: 提交基线报告**

Run:

```powershell
git add docs/windows-port/08-Windows基线.md pubspec.lock
git diff --cached --check
git commit -m "docs: 记录 Windows 原始构建基线"
```

Expected: 提交只包含报告和有明确理由的 lockfile 变化；`build/baseline` 由 `.gitignore` 排除。

---

### Task 3: 建立可重复的 Windows 构建入口

**Files:**
- Create: `.gitattributes`
- Create: `scripts/windows/check_environment.ps1`
- Create: `scripts/windows/build_app.ps1`
- Create: `scripts/windows/build_cli.ps1`
- Create: `test/architecture/windows_foundation_test.dart`

**Interfaces:**
- Consumes: `.secrets/<name>`；`flutter` 与 `dart` 在 PATH。
- Produces: `scripts/windows/build_app.ps1 -Mode Debug|Release`、`scripts/windows/build_cli.ps1`、不含秘密的环境报告。

- [ ] **Step 1: 写基础设施守卫测试**

Create `test/architecture/windows_foundation_test.dart`:

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows 正式构建只能走注入八个配置的脚本', () {
    final script = File('scripts/windows/build_app.ps1').readAsStringSync();
    for (final name in const [
      'ARK_API_KEY',
      'SPEECH_APP_ID',
      'SPEECH_ACCESS_TOKEN',
      'UPDATE_TOS_REGION',
      'UPDATE_TOS_BUCKET',
      'UPDATE_TOS_ENDPOINT',
      'UPDATE_TOS_AK',
      'UPDATE_TOS_SK',
    ]) {
      expect(script, contains(name), reason: '$name 没有进入构建配置');
    }
    expect(script, contains(r'--dart-define=$($entry.Key)=$($entry.Value)'),
        reason: '八个配置没有转换成 flutter 的 dart define 参数');
    expect(script, isNot(contains('Write-Output $value')),
        reason: '构建日志不许回显 secret');
  });

  test('Windows CLI 有独立构建入口', () {
    final script = File('scripts/windows/build_cli.ps1').readAsStringSync();
    expect(script, contains('dart build cli'));
    expect(script, contains('ishkafel.exe'));
  });

  test('跨平台源码保持 LF，PowerShell 保持 CRLF', () {
    final attributes = File('.gitattributes').readAsStringSync();
    expect(attributes, contains('*.dart text eol=lf'));
    expect(attributes, contains('*.md text eol=lf'));
    expect(attributes, contains('*.ps1 text eol=crlf'));
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run:

```powershell
flutter test test/architecture/windows_foundation_test.dart
```

Expected: FAIL，因为 `.gitattributes` 和三个 Windows 脚本尚不存在。

- [ ] **Step 3: 创建行尾规则**

Create `.gitattributes`:

```gitattributes
* text=auto
*.dart text eol=lf
*.md text eol=lf
*.yaml text eol=lf
*.yml text eol=lf
*.json text eol=lf
*.sh text eol=lf
*.ps1 text eol=crlf
*.cmd text eol=crlf
*.cpp text eol=crlf
*.h text eol=crlf
*.rc text eol=crlf
```

- [ ] **Step 4: 创建环境检查脚本**

Create `scripts/windows/check_environment.ps1`。脚本必须设置 `$ErrorActionPreference = 'Stop'`，调用 `flutter --version`、`dart --version`、`flutter doctor -v`、`git --version`、`ssh -V`、`gh --version`、`nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader`，并明确不读取 `.secrets`。

```powershell
$ErrorActionPreference = 'Stop'
$commands = @('git', 'ssh', 'flutter', 'dart', 'gh', 'cmake')
foreach ($name in $commands) {
  $command = Get-Command $name -ErrorAction SilentlyContinue
  if ($null -eq $command) { throw "缺少开发工具：$name" }
  Write-Output "$name => $($command.Source)"
}
git --version
ssh -V
flutter --version
dart --version
gh --version
flutter doctor -v
if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
  nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader
}
```

- [ ] **Step 5: 创建 GUI 构建脚本**

Create `scripts/windows/build_app.ps1` with this interface and core logic:

```powershell
param([ValidateSet('Debug', 'Release')][string]$Mode = 'Debug')
$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$secretDir = Join-Path $projectRoot '.secrets'

function Read-Secret([string]$Name, [bool]$Required) {
  $path = Join-Path $secretDir $Name
  if (-not (Test-Path -LiteralPath $path)) {
    if ($Required) { throw "缺少 .secrets/$Name" }
    return ''
  }
  return (Get-Content -Raw -LiteralPath $path).Trim()
}

$values = [ordered]@{
  ARK_API_KEY = Read-Secret 'ark_api_key' $true
  SPEECH_APP_ID = Read-Secret 'speech_app_id' $true
  SPEECH_ACCESS_TOKEN = Read-Secret 'speech_access_token' $true
  UPDATE_TOS_REGION = Read-Secret 'update_tos_region' $false
  UPDATE_TOS_BUCKET = Read-Secret 'update_tos_bucket' $false
  UPDATE_TOS_ENDPOINT = Read-Secret 'update_tos_endpoint' $false
  UPDATE_TOS_AK = Read-Secret 'update_tos_ak' $false
  UPDATE_TOS_SK = Read-Secret 'update_tos_sk' $false
}

$arguments = @('build', 'windows', "--$($Mode.ToLowerInvariant())")
foreach ($entry in $values.GetEnumerator()) {
  $arguments += "--dart-define=$($entry.Key)=$($entry.Value)"
}
Push-Location $projectRoot
try { & flutter @arguments; if ($LASTEXITCODE -ne 0) { throw 'Windows 构建失败' } }
finally { Pop-Location }
```

脚本最后只输出 Debug/Release 产物路径，不输出 `$values`。

- [ ] **Step 6: 创建 CLI 构建脚本**

Create `scripts/windows/build_cli.ps1`。从项目根运行 `dart build cli`，递归寻找且只接受一个
`build\cli\windows_x64\bundle\bin\ishkafel.exe`；缺失或出现多个候选都失败。脚本把最终路径输出给打包阶段，但不复制到系统目录。

```powershell
$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Push-Location $projectRoot
try {
  & dart build cli
  if ($LASTEXITCODE -ne 0) { throw 'Windows CLI 构建失败' }
  $expected = Join-Path $projectRoot 'build\cli\windows_x64\bundle\bin\ishkafel.exe'
  if (-not (Test-Path -LiteralPath $expected)) { throw "没有找到 CLI 产物：$expected" }
  Write-Output $expected
} finally {
  Pop-Location
}
```

- [ ] **Step 7: 运行定向和相关架构测试**

Run:

```powershell
flutter test test/architecture/windows_foundation_test.dart
flutter test test/architecture/cli_no_flutter_test.dart
```

Expected: PASS；CLI import 守卫仍为空违规列表。

- [ ] **Step 8: 执行两个脚本的无秘密安全路径**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\check_environment.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\build_cli.ps1
```

Expected: 环境检查和 CLI 构建 exit 0。`build_app.ps1` 在缺少三个必需 secret 时应明确失败并只报缺少的文件名，不回显任何 secret。

- [ ] **Step 9: 提交构建基础设施**

Run:

```powershell
git add .gitattributes scripts/windows test/architecture/windows_foundation_test.dart
git diff --cached --check
git commit -m "build: 建立 Windows 构建入口"
```

Expected: 一个只包含基础构建入口和守卫测试的提交。

---

### Task 4: 配置 GitHub SSH 信任并创建独立远端

**Files:**
- External state: `C:\Users\Mayn\.ssh\known_hosts`
- External state: `C:\Users\Mayn\.ssh\id_ed25519_github_roshangh`
- External state: Windows `ssh-agent` service and Git global `core.sshCommand`
- External state: GitHub account SSH key and `RoshanGH/ishkafel-windows` repository

**Interfaces:**
- Consumes: GitHub 官方 Ed25519 主机指纹；Task 1 的 `gh`。
- Produces: `ssh -T git@github.com` 认证为 RoshanGH；独立 `origin`，可免账号密码 push。

- [ ] **Step 1: 验证 GitHub 主机指纹，不盲信首次连接**

Run:

```powershell
$scan = ssh-keyscan -t ed25519 github.com 2>$null
$scan | ssh-keygen -lf - -E sha256
```

Expected fingerprint: `SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU`。不匹配立即停止，不写 `known_hosts`。

- [ ] **Step 2: 在已验证指纹后建立主机信任**

Run:

```powershell
ssh -o StrictHostKeyChecking=accept-new -T git@github.com
```

Expected at this stage: 主机加入 `known_hosts`，随后因尚无账号密钥返回 `Permission denied (publickey)`；不得把这个认证失败误判为主机信任失败。

- [ ] **Step 3: 生成专用 Ed25519 密钥并加入 Windows ssh-agent**

Run in an interactive PowerShell terminal:

```powershell
$key = 'C:\Users\Mayn\.ssh\id_ed25519_github_roshangh'
ssh-keygen -t ed25519 -C '214620428@qq.com' -f $key
Get-Service ssh-agent | Set-Service -StartupType Automatic
Start-Service ssh-agent
ssh-add $key
git config --global core.sshCommand 'C:/Windows/System32/OpenSSH/ssh.exe'
```

Expected: 用户在 `ssh-keygen` 中自行输入密钥口令，口令不进入聊天、命令参数或日志；`ssh-add -l -E sha256` 显示一个 Ed25519 key。若设置服务需要 UAC，只对 Windows OpenSSH Authentication Agent 操作授权。

- [ ] **Step 4: 通过 GitHub CLI 浏览器授权并上传公钥**

Run:

```powershell
gh auth login --hostname github.com --git-protocol ssh --web
gh ssh-key add 'C:\Users\Mayn\.ssh\id_ed25519_github_roshangh.pub' `
  --type authentication --title 'Mayn Windows ishkafel'
```

Expected: 浏览器授权给当前 GitHub CLI；公钥出现在 RoshanGH 的 SSH keys。若 `gh auth status` 显示的不是 RoshanGH，立即停止，不创建仓库。

- [ ] **Step 5: 验证 SSH 账号**

Run:

```powershell
ssh -T git@github.com
```

Expected: 输出包含 `Hi RoshanGH! You've successfully authenticated`。GitHub SSH 测试正常退出码是 1，以消息和账号为验收依据。

- [ ] **Step 6: 创建公开 Windows 仓库并配置 origin**

Run:

```powershell
gh repo create RoshanGH/ishkafel-windows --public `
  --description 'ishkafel 的 Windows 原生桌面版本，持续同步 Mac 主项目' `
  --source . --remote origin
git remote set-url upstream git@github.com:RoshanGH/ishkafel.git
git remote -v
```

Expected: `origin` 为 `git@github.com:RoshanGH/ishkafel-windows.git`，`upstream` 为 Mac 仓库；此步骤不 push，等 CI 和同步文件提交后统一推送。

---

### Task 5: 建立 Windows CI 门槛

**Files:**
- Create: `.github/workflows/windows-ci.yml`
- Modify: `test/architecture/windows_foundation_test.dart`

**Interfaces:**
- Consumes: GitHub Actions Windows runner；Flutter 3.47.4。
- Produces: 每次 push/PR 的 analyze、test、CLI build 与 Windows Release app build 结果。

- [ ] **Step 1: 扩展失败守卫**

Append to `test/architecture/windows_foundation_test.dart`:

```dart
test('Windows CI 同时守住 analyze、test、CLI 和 app', () {
  final workflow = File('.github/workflows/windows-ci.yml').readAsStringSync();
  expect(workflow, contains("flutter-version: '3.47.4'"));
  expect(workflow, contains('flutter analyze'));
  expect(workflow, contains('flutter test'));
  expect(workflow, contains('dart build cli'));
  expect(workflow, contains('flutter build windows --release'));
});
```

- [ ] **Step 2: 运行测试确认失败**

Run:

```powershell
flutter test test/architecture/windows_foundation_test.dart
```

Expected: FAIL because `.github/workflows/windows-ci.yml` does not exist.

- [ ] **Step 3: 创建 Windows CI workflow**

Create `.github/workflows/windows-ci.yml` with:

```yaml
name: Windows CI

on:
  push:
    branches: [main, 'sync/**']
  pull_request:
    branches: [main]

permissions:
  contents: read

jobs:
  verify:
    runs-on: windows-latest
    timeout-minutes: 60
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: '3.47.4'
          channel: stable
          cache: true
      - name: Resolve dependencies
        run: flutter pub get
      - name: Analyze
        run: flutter analyze
      - name: Test
        run: flutter test
      - name: Build CLI
        run: dart build cli
      - name: Build Windows app
        run: flutter build windows --release
      - uses: actions/upload-artifact@v4
        with:
          name: ishkafel-windows-${{ github.sha }}
          path: build/windows/x64/runner/Release/
          if-no-files-found: error
          retention-days: 7
```

- [ ] **Step 4: 运行测试并检查 YAML**

Run:

```powershell
flutter test test/architecture/windows_foundation_test.dart
git diff --check
```

Expected: PASS and no whitespace errors.

- [ ] **Step 5: 提交 CI**

Run:

```powershell
git add .github/workflows/windows-ci.yml test/architecture/windows_foundation_test.dart
git diff --cached --check
git commit -m "ci: 建立 Windows 构建门槛"
```

Expected: CI and its architecture guard are one commit.

---

### Task 6: 建立 Mac 上游自动同步 PR

**Files:**
- Create: `scripts/windows/sync_upstream.ps1`
- Create: `.github/workflows/sync-upstream.yml`
- Modify: `test/architecture/windows_foundation_test.dart`

**Interfaces:**
- Consumes: `upstream/main` and a clean Windows `main`.
- Produces: local `sync/macos-<sha>` branch; GitHub `sync/macos-main` PR or a visible conflict issue.

- [ ] **Step 1: 写同步守卫测试**

Append:

```dart
test('Mac 同步只能开 PR，不能自动合并', () {
  final local = File('scripts/windows/sync_upstream.ps1').readAsStringSync();
  final workflow = File('.github/workflows/sync-upstream.yml').readAsStringSync();
  expect(local, contains('git fetch upstream main'));
  expect(local, contains('git merge --no-edit upstream/main'));
  expect(workflow, contains('schedule:'));
  expect(workflow, contains('workflow_dispatch:'));
  expect(workflow, contains('gh pr create'));
  expect(workflow, isNot(contains('gh pr merge')),
      reason: '上游更新必须通过 Windows CI 和人工复核');
});
```

- [ ] **Step 2: 运行测试确认失败**

Run:

```powershell
flutter test test/architecture/windows_foundation_test.dart
```

Expected: FAIL because sync script and workflow do not exist.

- [ ] **Step 3: 创建本地同步脚本**

Create `scripts/windows/sync_upstream.ps1`。它必须：

```powershell
param([switch]$Push)
$ErrorActionPreference = 'Stop'
if (git status --porcelain) { throw '工作区不干净，拒绝同步' }
git fetch upstream main
$upstreamSha = (git rev-parse upstream/main).Trim()
$mainSha = (git rev-parse main).Trim()
function Test-UpstreamIncluded {
  git merge-base --is-ancestor upstream/main main
  return $LASTEXITCODE -eq 0
}
if ($upstreamSha -eq $mainSha -or (Test-UpstreamIncluded)) {
  Write-Output '已经包含最新 Mac main'
  exit 0
}
$branch = "sync/macos-$($upstreamSha.Substring(0, 7))"
git switch main
git switch -C $branch
git merge --no-edit upstream/main
if ($LASTEXITCODE -ne 0) { git merge --abort; throw 'Mac 更新发生冲突，需要人工适配' }
if ($Push) { git push --force-with-lease origin $branch }
Write-Output $branch
```

- [ ] **Step 4: 创建每日同步 workflow**

Create `.github/workflows/sync-upstream.yml`。workflow 在每天 `01:00 UTC` 和手动触发时：

1. `actions/checkout@v4` checkout `main` with `fetch-depth: 0`。
2. 配置 bot 名称与 `github-actions[bot]@users.noreply.github.com`。
3. 添加 `https://github.com/RoshanGH/ishkafel.git` 为 upstream 并 fetch `main`。
4. 如果 Windows main 已包含 upstream main，正常退出。
5. 在固定分支 `sync/macos-main` merge upstream；成功后 push 并用 `gh pr create --base main --head sync/macos-main`，已有 PR 时更新正文。
6. merge 冲突时 abort，并用标签 `upstream-sync` 创建或更新题为“Mac 主项目更新需要人工适配”的 issue。
7. `permissions` 仅授予 `contents: write`、`pull-requests: write`、`issues: write`；workflow 中不存在 `gh pr merge` 或自动合并配置。

- [ ] **Step 5: 运行定向测试和本地 dry run**

Run:

```powershell
flutter test test/architecture/windows_foundation_test.dart
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\sync_upstream.ps1
```

Expected: test PASS；当前 Windows main 已包含 `upstream/main@96162c5`，脚本输出“已经包含最新 Mac main”且不切换分支。

- [ ] **Step 6: 提交同步机制**

Run:

```powershell
git add scripts/windows/sync_upstream.ps1 .github/workflows/sync-upstream.yml `
  test/architecture/windows_foundation_test.dart
git diff --cached --check
git commit -m "ci: 持续同步 Mac 主项目更新"
```

Expected: one commit, no auto-merge capability.

---

### Task 7: 固化项目身份与平台差异规则

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`
- Create: `docs/platform-differences.md`
- Modify: `test/architecture/windows_foundation_test.dart`

**Interfaces:**
- Consumes: approved design and existing `docs/windows-port/02-功能对齐清单.md` appendix 2.
- Produces: human and agent instructions that identify this repository as Windows and define allowed divergence.

- [ ] **Step 1: 写身份守卫测试**

Append:

```dart
test('Windows 仓库身份与差异清单有唯一入口', () {
  final readme = File('README.md').readAsStringSync();
  final agent = File('CLAUDE.md').readAsStringSync();
  final differences = File('docs/platform-differences.md').readAsStringSync();
  expect(readme, contains('RoshanGH/ishkafel-windows'));
  expect(readme, contains('upstream'));
  expect(agent, contains('scripts/windows/build_app.ps1'));
  expect(agent, contains('未登记的平台差异 = bug'));
  expect(differences, contains('Windows 原生标题栏'));
  expect(differences, contains('Ctrl'));
  expect(differences, contains('资源管理器'));
  expect(differences, contains('Videos'));
});
```

- [ ] **Step 2: 运行测试确认失败**

Run:

```powershell
flutter test test/architecture/windows_foundation_test.dart
```

Expected: FAIL because repository identity and canonical differences file are absent.

- [ ] **Step 3: 更新 README 与 CLAUDE**

At the top of `README.md`, add a Windows repository notice naming `RoshanGH/ishkafel-windows`, the Mac upstream URL, the daily sync PR policy, and the commands:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\windows\check_environment.ps1
powershell -ExecutionPolicy Bypass -File scripts\windows\build_app.ps1 -Mode Release
powershell -ExecutionPolicy Bypass -File scripts\windows\build_cli.ps1
```

Add to `CLAUDE.md`: Windows replies/comments/commits remain Chinese; official app builds only use `build_app.ps1`; every code wave ends with Windows tests, Release build and real app launch; `origin` is Windows, `upstream` is Mac; “未登记的平台差异 = bug”。

- [ ] **Step 4: 创建唯一平台差异清单**

Create `docs/platform-differences.md` by moving the approved differences from `docs/windows-port/02-功能对齐清单.md` appendix 2 into a maintained table. It must explicitly list title bar, system menu, Ctrl modifier, Ctrl multi-select, Explorer wording/command, PowerShell wording, full path display, Videos default, monospace font, overlay scrollbar, wheel scale, MSIX/signing, no-elevation user install, Windows privacy/SmartScreen, and file logging. Finish with: “未列出的产品行为、数据与视觉差异均视为 bug。”

- [ ] **Step 5: 运行测试并提交**

Run:

```powershell
flutter test test/architecture/windows_foundation_test.dart
git diff --check
git add README.md CLAUDE.md docs/platform-differences.md `
  test/architecture/windows_foundation_test.dart
git commit -m "docs: 固化 Windows 项目身份与差异边界"
```

Expected: PASS and one documentation/guard commit.

---

### Task 8: 完整验证、首次推送与远端核验

**Files:**
- No new files unless verification exposes a scoped defect.

**Interfaces:**
- Consumes: Tasks 1–7.
- Produces: GitHub 上可克隆的 Windows 独立仓库、可见 CI、可触发的 upstream sync。

- [ ] **Step 1: 运行环境和仓库检查**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\check_environment.ps1
git status --short --branch
git remote -v
gh auth status
ssh -T git@github.com
```

Expected: tools healthy, worktree clean, origin/upstream exact, GitHub account RoshanGH authenticated. Treat SSH exit 1 with success greeting as success.

- [ ] **Step 2: 运行完整本地门槛**

Run:

```powershell
flutter pub get
flutter analyze
flutter test
dart build cli
flutter build windows --release
```

Expected: each command's actual exit code is recorded. If the original code still fails because of known P0 platform defects, do not claim this milestone complete; immediately start the “Windows 平台契约与 P0” plan and return here after those defects are fixed.

- [ ] **Step 3: 核验提交内容与工作区**

Run:

```powershell
git log --oneline --decorate upstream/main..main
git diff --check upstream/main..main
git status --porcelain
```

Expected: only approved design, plan, baseline, scripts, workflows, docs and guards; no secret, build artifact or uncommitted file.

- [ ] **Step 4: 首次推送**

Run:

```powershell
git push --set-upstream origin main
```

Expected: no username/password prompt; push succeeds using SSH key.

- [ ] **Step 5: 验证远端与 commit 一致**

Run:

```powershell
$local = (git rev-parse HEAD).Trim()
$remote = (git ls-remote origin refs/heads/main).Split("`t")[0]
if ($local -ne $remote) { throw "远端不是本地 HEAD：$local != $remote" }
gh repo view RoshanGH/ishkafel-windows --json nameWithOwner,isPrivate,defaultBranchRef,url
gh run list --repo RoshanGH/ishkafel-windows --workflow 'Windows CI' --limit 3
```

Expected: remote SHA equals local SHA; repository is public and default branch is main; Windows CI run appears.

- [ ] **Step 6: 手动触发并核验同步 workflow**

Run:

```powershell
gh workflow run sync-upstream.yml --repo RoshanGH/ishkafel-windows
gh run list --repo RoshanGH/ishkafel-windows --workflow sync-upstream.yml --limit 1
```

Expected: with no newer upstream commit, workflow exits successfully and creates neither duplicate PR nor duplicate issue.

- [ ] **Step 7: 记录基础里程碑状态**

Update this plan's checkboxes and the thread plan from fresh command output. Do not发布安装包、GitHub Release 或应用自动更新；这些外部发布动作属于第四份交付计划并继续需要人工确认。

---

## Subsequent Plans

完成本计划后，按顺序创建和执行：

1. `Windows 平台契约与 P0`：路径、PATH、工具定位、filtergraph、UTF-8 CLI、窗口/DPI、系统 shell 与进程锁。
2. `Windows 媒体、字幕与性能`：统一媒体契约、代理、C++ 字幕辅助进程、字体、逐帧与 4K60 基准。
3. `Windows 剪映与交付`：剪映草稿实测、内置工具、MSIX、签名、自动更新、视觉与完整真机验收。
