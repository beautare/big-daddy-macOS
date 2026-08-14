# 连续性模式（崩溃后自动恢复）—— 后端对接说明

客户端新增家长控制的"连续性模式"：打开后，孩子这台 Mac 上的守护进程在崩溃、强制退出（Activity Monitor Force Quit / SIGKILL）后由 **用户级 LaunchAgent** 拉起。这不是隐蔽持久化——菜单栏图标仍在、首次运行披露会写明、本机审计日志会记下开关与拉起。

`SMAppService.mainApp` 是登录项，**崩了不会拉**。KeepAlive 只在 **launchd 才是进程的管理者** 时生效。因此 macOS 13+ 打开连续性时会注销登录项，改用同一份用户级 plist（`~/Library/LaunchAgents/com.bigdaddy.client.plist`），避免登录时双启动。连续性打开期间这份 agent 的 `RunAtLoad` 强制为 true（否则 launchd 不会在当前会话把进程拉起来盯着）。孩子在菜单关掉"开机自启"不会拆掉这份 KeepAlive agent；意图与 OS 状态会分叉，心跳里能看出来。

缺省关闭。旧后端不下发该字段时，客户端视为 `false`，行为与今天完全一致。

## 配置接口新增字段

已有的 `GET /bigdaddy/client/config` 响应体（即客户端的 `ClientConfig`）新增：

| 字段 | 类型 | 缺省 | 含义 |
|---|---|---|---|
| `continuityMode` | boolean | `false` | 家长是否打开连续性模式。 |

- 只由家长在 Dashboard 改；客户端菜单**不能打开**它。
- 孩子可以在菜单里用与"安全退出"相同的临时验证码**关闭**（本机覆盖）。覆盖会挡住这份配置，直到家长在 Dashboard 把连续性**关掉再打开**（客户端看到 `false → true` 边沿时清掉覆盖）。
- 旧后端省略该字段：客户端 `decodeIfPresent` 得 `false`，不会误开。
- 旧客户端忽略未知字段，不受影响。

## 心跳接口新增字段

`POST /bigdaddy/client/heartbeat` 的请求体 `metadata` 中新增两个字段，与 `launchAtLoginEnabled` / `launchAtLoginOsStatus` 并列，**每次心跳都会带上**：

| 字段 | 类型 | 含义 |
|---|---|---|
| `continuityModeEnabled` | boolean | 家长配置的意图：`ClientConfig.continuityMode`。 |
| `continuityModeOsStatus` | string | 本机 launchd KeepAlive 的实际状态。取值见下表。 |

`continuityModeOsStatus` 取值：

| 值 | 含义 |
|---|---|
| `off` | plist 不存在，或存在但 KeepAlive 不是 `{ SuccessfulExit: false }`。 |
| `keepAliveLoaded` | KeepAlive plist 已加载，且当前进程就是 launchd 拉起的那一份。 |
| `keepAliveLoadedUnmanaged` | job 已加载，但当前进程不是 launchd 拉起的（交接中 / Sparkle 刚 relaunch）。 |
| `keepAlivePlistNotLoaded` | 磁盘上已是 KeepAlive plist，但用户域 job 未加载——当前会话崩了不会拉，下次登录才会。 |

### 为什么两个字段都要留

与开机自启同一套哲学：`continuityModeEnabled` 是意图，`continuityModeOsStatus` 是系统实际状态，二者可能分叉。

- `true` + `keepAliveLoaded`：正常。
- `true` + `off` / `keepAlivePlistNotLoaded`：家长以为开着，本机没盯上。常见原因：孩子用验证码在本机关闭、或在 `~/Library/LaunchAgents` 里删了 plist。**建议 Dashboard 告警**。
- `false` + 非 `off`：关闭尚未落到 OS，通常是交接瞬间，不必当故障。

### 建议的 Dashboard 展示

设备详情页加一行"崩溃后自动恢复"，逻辑大致：

```
if continuityModeEnabled and osStatus == keepAliveLoaded:
    显示"已开启"
elif continuityModeEnabled and osStatus == keepAlivePlistNotLoaded:
    显示"已配置，当前会话未生效"
elif continuityModeEnabled and osStatus == off:
    显示"⚠️ 已被本机关闭或卸载"
else:
    显示"已关闭"
```

文案必须是**双方同意的连续性**，不是隐身、不是防卸载、不是删了 App 还会回来。建议开关说明类似：

> 打开后，守护程序在崩溃或被强制退出后会自动再打开。刚打开这个开关时，孩子那台 Mac 上的客户端会自动重启一次交接（菜单栏图标会闪一下），这是正常的。孩子看得到菜单栏图标；关闭程序仍需要你生成的临时验证码。把 BigDaddy 从电脑上删除后，它不会自己装回来。

## 验证退出

`POST /bigdaddy/client/verify-exit` **不需要改**。客户端在验证通过后会：

1. 延迟 `launchctl bootout` 卸掉本会话 KeepAlive job（立刻 bootout 会把还在发 SHUTDOWN 的进程杀掉）。
2. 同步发一条 `SHUTDOWN` 心跳（与今天相同）。
3. `exit 0`。KeepAlive 为 `{ SuccessfulExit: false }`，正常退出不会被拉起。

下次登录：若开机自启仍开着且家长配置仍是 `continuityMode: true`，LaunchAgent 的 `RunAtLoad` 会再次拉起并继续盯着。

孩子在菜单关闭连续性，用的也是同一个验证码接口。

## Sparkle 更新

更新安装完成时客户端以 exit 0 结束，KeepAlive 不会抢着重启；由 Sparkle 自己 relaunch。新版本起来后再把进程交回 launchd。不要在更新流程里再 `restartApplication()` 一份。

## 删除限制（不会做、也不该做）

连续性模式 **不会** 在磁盘上藏第二份 `.app`，也没有特权 helper / SMJobBless / root。  
`ProgramArguments` 指向当前这份可执行文件。用户把 `BigDaddy.app` 删掉或移走之后，launchd 再拉只会失败，守护就此停下。这是产品约束，不是没做完的"误删恢复"。

Dashboard、营销文案不要写"删了也会自动回来"。

## 兼容性

字段都是纯增量。旧后端忽略即可，无需紧急升级。未上线该开关的家长端，客户端保持关闭。
