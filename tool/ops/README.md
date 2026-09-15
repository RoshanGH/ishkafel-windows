# 运维脚本：自动更新的落点是怎么建的

`volc.py` 是火山引擎 API 的最小签名客户端，**只给这里的一次性运维脚本用，
不进产物**。

## 已经建好的东西（2026-09-02）

| 资源 | 名字 | 干什么 |
|---|---|---|
| TOS 桶 | `ishkafel-release`（cn-beijing，**私有**） | Windows 包放在 `windows/releases/`，清单是 `windows/latest.json` |
| IAM 子用户 | `ishkafel-updater` | 它的 AK/SK 编进产物，供 app 读包 |
| IAM 策略 | `ishkafel-release-readonly` | 只允许 `tos:GetObject` 这一个桶 |

**为什么要单独一个子用户**：产物里 `--dart-define` 注入的凭据是明文躺在
二进制里的（`strings` 一抠就有）。给到最小权限，泄露的后果就只是
「别人能下载安装包」，而不是「别人能花你的钱」。

已验证：只读凭据 `GET` 通、`PUT` 被拒 403。

发布用的是**另一对可写凭据**（`.secrets/update_tos_*_write`，就是账号主
AK/SK），只留在打包这台机器上，不进产物。

## 不要了怎么删

```bash
# 1. 清空并删桶（先删对象，桶非空删不掉）
#    在控制台 → 对象存储 → ishkafel-release → 删除
# 2. 删子用户（要先解绑策略、删它的 AccessKey）
#    控制台 → 访问控制 → 用户 → ishkafel-updater
# 3. 删策略 ishkafel-release-readonly
```

删掉之后，`.secrets/update_tos_*` 一并删掉即可——app 里的更新入口会自动
消失（没配就整个不显示）。
