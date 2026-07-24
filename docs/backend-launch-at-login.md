# 开机自动启动 —— 后端对接说明

客户端新增"开机自动启动"本地开关（默认开启，孩子可在菜单栏关闭）。本文档只描述**后端需要感知的部分**：心跳接口新增的两个 metadata 字段，以及一个行为上需要知晓、但不需要改代码的复用点。

## 心跳接口新增字段

`POST /bigdaddy/client/heartbeat` 的请求体 `metadata` 中新增两个字段，与已有的 `screenRecordingGranted`/`accessibilityGranted` 并列，**每次心跳都会带上**：

| 字段 | 类型 | 含义 |
|---|---|---|
| `launchAtLoginEnabled` | boolean | 客户端本地偏好（意图）：孩子是否已把开机自启开关打开。 |
| `launchAtLoginOsStatus` | string | macOS 系统层的实际登录项状态。取值见下表。 |

`launchAtLoginOsStatus` 取值：

| 值 | 含义 | 出现场景 |
|---|---|---|
| `enabled` | 已注册且生效 | macOS 13+，正常状态 |
| `requiresApproval` | 已注册，等待用户在「系统设置 → 登录项」里批准 | macOS 13+，首次注册后常见，需要提醒家长/孩子去系统设置放行 |
| `notRegistered` | 未注册 | macOS 13+，偏好已关闭，或从未开启过 |
| `notFound` | 系统找不到该登录项记录 | macOS 13+，异常状态 |
| `unknown` | 未识别的新状态 | macOS 13+，系统返回了当前 SDK 未覆盖的新枚举值 |
| `plistPresent` / `plistAbsent` | LaunchAgent plist 文件是否存在 | macOS 12.x（无 SMAppService，用文件存在性近似表达状态） |

### 为什么两个字段都要留

`launchAtLoginEnabled` 是客户端的"意图"，`launchAtLoginOsStatus` 是系统的"实际状态"，二者**理论上应该一致，但可能不一致**：

- 二者一致（如 `true` + `enabled`）：一切正常。
- `launchAtLoginEnabled = true` 但 `launchAtLoginOsStatus` 是 `notRegistered`/`notFound`：意味着孩子绕过了客户端菜单里的验证码开关，直接在「系统设置 → 登录项」里手动把它关掉了——这是本地验证码机制拦不住的路径（客户端目前也无法阻止系统层面的关闭，只能感知并上报）。**建议后端/Dashboard 据此给家长一条告警**，而不是静默地相信 `launchAtLoginEnabled` 字段。
- `launchAtLoginOsStatus = requiresApproval`：不算异常，但用户体验上"看起来没生效"，建议 Dashboard 提示家长/孩子去系统设置放行一次。

### 建议的 Dashboard 展示

设备详情页加一行"开机自启"状态，逻辑大致：

```
if launchAtLoginOsStatus in [enabled, plistPresent]:
    显示"已开启"
elif launchAtLoginOsStatus == requiresApproval:
    显示"待批准"（提示去系统设置放行）
elif launchAtLoginEnabled == true and launchAtLoginOsStatus in [notRegistered, notFound, plistAbsent]:
    显示"⚠️ 已被手动关闭"（客户端意图是开，但系统层实际未生效）
else:
    显示"已关闭"
```

### 兼容性

两个字段都是纯增量，旧版本后端会直接忽略、不受影响，无需紧急升级。

## 行为说明：验证码复用（不需要后端改动，仅供知晓）

客户端菜单里关闭"开机自动启动"时，弹出的是与"安全退出"**完全相同**的 6 位验证码输入框，调用的也是同一个已有接口 `POST /bigdaddy/client/verify-exit`。也就是说：

- 家长在 Dashboard 生成的"退出验证码"，孩子既可以用它正常退出客户端，**也可以用它关闭开机自启**（两者是两个独立的敏感操作，共用同一次验证）。
- 如果 Dashboard 的验证码生成界面文案里明确写的是"退出验证码"，建议措辞上略作调整（比如改成"设备验证码"），避免家长误解这个码只能用于退出。
- 这一行为完全在客户端内实现，后端接口本身不需要任何改动。

## 其他行为备注

- 设备**绑定成功**的那一刻，客户端会强制把开机自启重新打开（即便孩子在绑定前手动关闭过）。这是为了保证"家长完成绑定 = 守护默认生效"，不需要后端配合，纯客户端行为。
