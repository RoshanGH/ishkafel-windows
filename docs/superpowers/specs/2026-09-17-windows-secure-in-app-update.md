# Windows 安全应用内更新设计

## 目标

为公司内部小范围使用的 Windows 便携版提供与 Mac 一致的应用内更新：员工安装引导版后无需配置 AI 或更新凭据，后续可在应用内检查、下载、验签、替换并自动重启。

## 凭据边界

- `ARK_API_KEY`、`SPEECH_APP_ID`、`SPEECH_ACCESS_TOKEN` 随 Release 构建内置，保证安装即用。
- TOS 只读 AK/SK 随 Release 构建内置，只允许读取更新清单和安装包。
- TOS 写入 AK/SK 只存在于发布机 `.secrets`，不得进入产物、日志或 Git。
- Ed25519 发布公钥随软件内置；对应私钥只存在于发布机 `.secrets`，不得进入产物、日志或 Git。
- 桌面客户端内置的 AI 凭据只能防止日常误见，不能抵御专业逆向；通过专用 Key、最小权限、额度、限流和可轮换降低风险。

## 更新协议

Windows 使用 Mac 同一个私有 TOS bucket，但对象命名空间独立：

- 稳定清单：`windows/latest.json`
- 旧版清单：`latest-windows.json`（默认不更新）
- 版本包：`windows/releases/ishkafel-windows-<version>-x64-portable.zip`

清单包含 `version`、`objectKey`、`sha256`、`sizeBytes`、`notes`、`signature`。签名输入是前五个字段按固定键序编码出的紧凑 JSON UTF-8 字节；签名算法为 Ed25519，签名和公钥使用 Base64。

客户端必须先验证清单签名，再比较版本和下载。下载后必须验证 SHA-256。Windows 允许以下任一发布身份验证通过：可信 Authenticode，或者已由有效 Ed25519 清单签名锁定 SHA-256 的便携包。没有有效清单签名时不得用后者降级。

## 发布与兼容

发布工具从 `build/dist` 读取便携 ZIP，以发布私钥生成签名。顺序固定为：上传版本包，再上传 `windows/latest.json`。`0.1.237` 不认识新验签机制且会拒绝未做 Authenticode 的包，所以默认不得改写 `latest-windows.json`；只有受信任 Authenticode 包才可用 `--publish-legacy-manifest` 显式更新旧通道。任一步失败返回非零，不创建占位资源。

当前 `0.1.237` 不认识 Ed25519 清单，因此 `0.1.238` 是一次性手动安装的引导版。从 `0.1.238` 开始，后续 Windows 版本走应用内更新。MSIX 仍用于手动安装；自更新目标是安装在用户可写目录中的便携版。

## 验证

- 单元测试覆盖合法签名、篡改字段、错误公钥、缺失签名和旧清单拒绝。
- 架构测试覆盖私钥不进入构建参数、Windows 独立对象键和旧通道显式开关。
- 发布前运行完整 Flutter 测试、静态分析、Release 构建、分发 smoke 和敏感信息泄漏扫描。
- 真机用测试通道完成旧版发现新版、下载、验签、替换、重启和任务数据保留验证，再提升到稳定通道。
