import AppKit
import ApplicationServices
import CryptoKit
import Darwin
import Foundation
import Network
import ScreenCaptureKit
import Security
import ServiceManagement

enum EventType: String, Codable {
    case start = "START"
    case heartbeat = "HEARTBEAT"
    case idle = "IDLE"
    case resume = "RESUME"
    case shutdown = "SHUTDOWN"
    case forceKill = "FORCE_KILL"
    case configUpdated = "CONFIG_UPDATED"
    case commandAck = "COMMAND_ACK"
    case appSwitch = "APP_SWITCH"
    /// 系统即将休眠（合盖、菜单里选睡眠、电源策略自动睡）。在 NSWorkspace.willSleep 的
    /// 同步窗口里抢发——不发这一条的话，"孩子合上了 MacBook"在家长端与"断网了""关机了"
    /// "客户端被强杀了"完全同形，而这几种情况该做的事完全不同。
    case sleep = "SLEEP"
    /// 系统已唤醒。除了补上时间线，它还是"结束睡眠状态"的唯一信号。
    case wake = "WAKE"
    /// 锁屏（机器仍在运行）。与 IDLE 的区别是它由系统事件确定，不靠"多久没输入"推断。
    case screenLock = "SCREEN_LOCK"
    case screenUnlock = "SCREEN_UNLOCK"
}

struct DeviceIdentity {
    let fingerprint: String
    let secretHash: String
}

enum ConfigRefreshResult: Equatable {
    case successChanged
    case successUnchanged
    case failed

    var succeeded: Bool {
        self != .failed
    }

    var changed: Bool {
        self == .successChanged
    }
}

/// 时间约定：家长在仪表盘给孩子设定的一段可用时长，权威状态随 ConfigResponse.timeSession
/// 下发（nil = 当前没有进行中的约定）。只做墙钟模式——remainingSeconds 是**服务端在响应
/// 那一刻**算出的剩余秒数，客户端把它加到本机单调时钟（ProcessInfo.systemUptime）上得出
/// 本地截止点，孩子改系统时间不影响倒计时。客户端不上报任何计时事件，"到点"完全由服务端
/// 判定；这里只负责按快照在本地把旗帜渲染出来。
struct TimeSession: Codable {
    let sessionId: String
    let grantedSeconds: Int
    let remainingSeconds: Int
    let note: String?
}

extension TimeSession: Equatable {
    /// 只比 sessionId：remainingSeconds 每次配置轮询都在变，若参与相等性比较，
    /// ClientConfig 的 `config != previous` 在约定进行期间会永远判定"有变化"，让
    /// pollConfigForChildVisibility 里"只在真正变化时才做的事"（rebuildMenu、发
    /// CONFIG_UPDATED 心跳等）在每一次 60 秒轮询都被误触发。
    static func == (lhs: TimeSession, rhs: TimeSession) -> Bool {
        lhs.sessionId == rhs.sessionId
    }
}

/// 应用版本的单一来源：正式 .app 读打包时由 CI/package.sh 写入的 CFBundleShortVersionString；
/// 裸二进制（swift run / Xcode 直接运行）没有 Info.plist，统一返回 "dev"——
/// 菜单栏和上报后端必须用同一个值，此前分别兜底成 "?" 和假版本号 "1.0.0"，造成三处版本各说各话。
enum AppVersion {
    static let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
}

/// 通知渠道配置（后端转发截图，不存储图片）
struct NotificationChannels: Codable, Equatable {
    var email: String?
    // 独立于"是否已配置"的第二道开关：地址/凭据决定渠道有没有可用目标，这两个
    // 字段决定当前要不要真的用它。缺省（nil）按已启用处理，语义与后端一致。
    var emailEnabled: Bool?
    var telegramBotToken: String?
    var telegramChatId: String?
    var telegramEnabled: Bool?
    var whatsappPhone: String?
}

struct ClientConfig: Codable, Equatable {
    var bound: Bool = false
    var configVersion: Int = 1
    var screenshotIntervalMins: Int = 5
    /// 是否启用定时截图（默认 false，由家长在后端配置开启）
    var screenshotEnabled: Bool = false
    /// 通知渠道（用于截图转发，后端不持久化图片）
    var notificationChannels: NotificationChannels = NotificationChannels()
    var compressQuality: Double = 0.6
    var compressMaxWidth: Int = 1280
    var aiEnabled: Bool = false
    var allowScreenshotAiProcessing: Bool = false
    /// 已绑定设备恒为 true：退出验证不是持久化开关，而是家长每次都要在 Dashboard
    /// 实时生成临时验证码（见 verifyExitPassword），这里只用于 UI 展示"是否需要验证退出"。
    var hasExitPassword: Bool = false
    var heartbeatActiveSeconds: Int = 60
    var heartbeatIdleSeconds: Int = 900
    var idleThresholdSeconds: Int = 180
    var hasPendingCommand: Bool = false
    var webFilter: WebFilterConfiguration = WebFilterConfiguration()
    /// 当前活跃的时间约定（nil = 没有）。这是客户端获取会话状态的**唯一权威来源**：
    /// SYNC_TIME_SESSION 命令只是门铃，冷启动、断网恢复、睡眠唤醒全部走这条路恢复。
    var timeSession: TimeSession? = nil
    /// 家长在 Dashboard 打开的"连续性模式"：崩溃 / 强制退出后由用户级 LaunchAgent
    /// KeepAlive 拉起。缺省 false；旧后端不下发此字段时保持关闭，行为与今天一致。
    var continuityMode: Bool = false
    /// continuityMode 最近一次被家长实际改变（真的翻转过，不是每次保存表单）的时间。
    /// 旧后端不下发时为 nil，refreshConfig() 退回纯 false→true 边沿判断，行为与今天一致。
    ///
    /// 刻意保留**后端下发的原始字符串**而不解析成 Date：客户端要回答的问题是"这个值
    /// 跟我上次记下的相比变了没有"，是等值判断，不是时间先后判断。而后端下发的是不带
    /// 时区的 LocalDateTime，客户端按 `.current` 时区解释——同一个字符串在夏令时切换
    /// 前后会解析出相差一小时的绝对时刻，一旦拿去做 `>` 比较，一个从没变过的时间戳会
    /// 在入冬后凭空显得"更新了"，把孩子的本地覆盖无端清掉。存原文比就没有这个问题，
    /// 也顺带不依赖后端时钟单调（NTP 回拨同样会破坏先后比较）。
    var continuityModeUpdatedAt: String? = nil

    init() {
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bound = try container.decodeIfPresent(Bool.self, forKey: .bound) ?? false
        configVersion = try container.decodeIfPresent(Int.self, forKey: .configVersion) ?? 1
        screenshotIntervalMins = try container.decodeIfPresent(Int.self, forKey: .screenshotIntervalMins) ?? 5
        screenshotEnabled = try container.decodeIfPresent(Bool.self, forKey: .screenshotEnabled) ?? false
        notificationChannels = try container.decodeIfPresent(NotificationChannels.self, forKey: .notificationChannels) ?? NotificationChannels()
        compressQuality = try container.decodeIfPresent(Double.self, forKey: .compressQuality) ?? 0.6
        compressMaxWidth = try container.decodeIfPresent(Int.self, forKey: .compressMaxWidth) ?? 1280
        aiEnabled = try container.decodeIfPresent(Bool.self, forKey: .aiEnabled) ?? false
        allowScreenshotAiProcessing = try container.decodeIfPresent(Bool.self, forKey: .allowScreenshotAiProcessing) ?? false
        hasExitPassword = try container.decodeIfPresent(Bool.self, forKey: .hasExitPassword) ?? false
        heartbeatActiveSeconds = try container.decodeIfPresent(Int.self, forKey: .heartbeatActiveSeconds) ?? 60
        heartbeatIdleSeconds = try container.decodeIfPresent(Int.self, forKey: .heartbeatIdleSeconds) ?? 900
        idleThresholdSeconds = try container.decodeIfPresent(Int.self, forKey: .idleThresholdSeconds) ?? 180
        hasPendingCommand = try container.decodeIfPresent(Bool.self, forKey: .hasPendingCommand) ?? false
        webFilter = try container.decodeIfPresent(WebFilterConfiguration.self, forKey: .webFilter) ?? WebFilterConfiguration()
        timeSession = try container.decodeIfPresent(TimeSession.self, forKey: .timeSession)
        continuityMode = try container.decodeIfPresent(Bool.self, forKey: .continuityMode) ?? false
        continuityModeUpdatedAt = try container.decodeIfPresent(String.self, forKey: .continuityModeUpdatedAt)
    }
}

/// 两次心跳之间的应用切换次数计数器：NSWorkspace 的切换通知在主线程回调递增，
/// sendHeartbeat 在（可能是后台的）Task 里读取并清零，用锁避免读写竞争。
final class SwitchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    /// 取走当前计数并清零，计数从这一刻起重新累积到下一次心跳
    func takeAndReset() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let value = count
        count = 0
        return value
    }
}

final class BigDaddyClient: @unchecked Sendable {
    static var lastSharedInstance: BigDaddyClient?
    static let webFilterConfigChangedNotification = Notification.Name("BigDaddyWebFilterConfigChanged")

    let baseURL = URL(string: Bundle.main.object(forInfoDictionaryKey: "BigDaddyAPIBaseURL") as? String ?? "http://localhost:8009/api/v1")!
    /// 家长仪表盘地址：正式 .app 由打包脚本写入 Info.plist（BigDaddyDashboardBaseURL），
    /// 裸二进制（swift run / Xcode 直接运行）退回本地 dashboard 开发端口。
    let dashboardBaseURL = URL(string: Bundle.main.object(forInfoDictionaryKey: "BigDaddyDashboardBaseURL") as? String ?? "http://localhost:4000")!
    let identity: DeviceIdentity
    var config: ClientConfig
    var lastHeartbeatDescription = Localization.string(zh: "尚未发送", en: "Not sent")
    var bindToken: String?
    /// register 响应报告本机 secret 与后端存档不一致（设备已绑定、后端拒绝换钥）。
    /// 此状态下所有签名接口都会验签失败，必须在 UI 上明确警示，引导解绑后重新绑定。
    var credentialsInvalid = false
    /// 当前是否有浏览器处于"自动化权限被拒"状态，随心跳上报（见 sendHeartbeat 的 metadata）。
    /// 那份被拒 bundle id 的集合归 AppDelegate 管（探测、重置、菜单入口都在那边），
    /// 这里只留一个被同步过来的布尔值——心跳在这个类里组装，总得有个地方读到它。
    var automationBlocked = false
    /// 上一次运行留下的墓碑时间戳（"上次运行没有正常结束"），由 prepareRuntime 在启动时读入。
    /// prepareRuntime 在主线程写、sendHeartbeat 在（可能是后台的）Task 里取走，与 SwitchCounter
    /// 是同一类读写竞争，一律经 previousCrashLock 访问。
    private var previousCrashAt: Date?
    private let previousCrashLock = NSLock()
    private let switchCounter = SwitchCounter()
    private var switchObserver: NSObjectProtocol?
    /// 切换 App 后"即时上报"的防抖任务：把快速连切合并成一次发送
    private var switchHeartbeatWork: DispatchWorkItem?

    init() {
        self.identity = IdentityStore.load()
        var restored = ConfigStore.load() ?? ClientConfig()
        // 磁盘上存下来的 timeSession 一律作废。
        //
        // ConfigStore 持久化的是整个 ClientConfig，timeSession 会连着它那个"服务端在响应
        // 那一刻算出的" remainingSeconds 一起落盘，而这个数字**只在落盘那一瞬间成立**。
        // 从落盘到下次冷启动之间会流逝任意长的墙钟时间（关机一整晚很常见），复用它就等于
        // 凭空复活一个早已到点的约定：家长昨晚 20:00 设了 30 分钟，孩子 20:10 合盖关机
        // （落盘 remainingSeconds=1200），次日早上 7:00 开机、Wi-Fi 还没连上导致
        // refreshConfig() 失败——若不清掉，客户端会拿着这份隔夜快照下拉旗帜、显示"剩余
        // 20:00"并开始倒数，而服务端早在昨晚就把它判成 EXPIRED 了。
        //
        // 只清磁盘这一条路径，不动内存：进程运行期间 refreshConfig() 失败时保留内存里的
        // 上一份 timeSession 是**正确**的（墙钟语义下时间照流，断网不该让倒计时暂停），
        // 有问题的只是磁盘往返跨越的那段不可知时长。
        restored.timeSession = nil
        self.config = restored
        BigDaddyClient.lastSharedInstance = self
    }

    var configFilePath: String {
        ConfigStore.configFileURL.path
    }

    /// 是否有可用通知渠道（决定是否单独发送截图）
    var hasScreenshotDestination: Bool {
        config.screenshotEnabled
    }

    /// 屏幕录制权限的唯一判定入口，只信 `CGPreflightScreenCaptureAccess()`。
    /// 曾经在这里（以及绑定流程的权限自检里）用"CGDisplayCreateImage 1x1 截屏是否
    /// 非空"做兜底，但实测该调用在没有权限的进程里也返回非空——10.15 起无权限时
    /// 系统只是把窗口内容替换成壁纸合成图，并不失败（该 API 在 macOS 15 已被废除，
    /// 仅因部署目标是 macOS 12 才还能编译）。兜底恒真等于永远报"有权限"，反而掩盖
    /// 真实缺权：菜单栏的缺权警示永远不亮、心跳里的 screenRecordingGranted 恒为 true。
    func hasScreenRecordingAccess() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// "从这一刻起重新开始计算空闲"的时间下限。唤醒/解锁时被推到当下（见 noteActivityFloor）。
    ///
    /// 为什么需要它：`CGEventSource.secondsSinceLastEventType` 返回的是**墙钟**意义上
    /// "距上次输入过了多久"，睡眠时间也照算。合盖一夜再打开，这个值是 10 小时，于是唤醒后
    /// 立刻触发的那次心跳会判定 IDLE 并把下一次心跳排到 15 分钟后——孩子这时候已经在用
    /// 电脑了，家长端却显示"空闲"，而且要等最长 15 分钟才纠正。这正是产品设计文档里
    /// "一旦检测到用户输入，立刻恢复常规节奏"承诺过、但此前并未实现的那一段。
    ///
    /// 初值必须是 `.distantPast` 而不是 `Date()`：这个下限只该在"刚发生过一次唤醒/解锁"
    /// 时才生效。如果初始化成"此刻"，会让**任何一次进程启动**（不只是睡眠唤醒——崩溃后
    /// 自动重启、Sparkle 更新后重开、单纯的开机自启）在最初 idleThresholdSeconds 内把
    /// `isIdle` 恒判定为 false：哪怕孩子已经离开了一整夜、进程是凌晨自动重启的，`sinceFloor`
    /// （刚启动，几乎是 0）会在 min() 里压过真实的 `sinceLastInput`，让"分明空闲"的这段
    /// 时间被误报成"活跃"。用 `.distantPast` 做哨兵值，`sinceFloor` 在从未唤醒过的整个
    /// 进程生命周期里恒为一个天文数字，min() 永远退化成单纯的 `sinceLastInput`——直到
    /// 真的发生一次 noteActivityFloor() 调用，这个下限才第一次有意义。
    private var activityFloor = Date.distantPast

    /// 把"空闲计时"的起点重置到当下。唤醒、解锁这类系统事件意味着有人回到了机器前，
    /// 即便此刻还没有产生第一个键鼠事件，也不该继续沿用睡眠期间累积的空闲时长。
    func noteActivityFloor() {
        activityFloor = Date()
    }

    var isIdle: Bool {
        // 之前只看 .mouseMoved，只打字不动鼠标会被误判为空闲。改用 kCGAnyInputEventType
        // （rawValue ~0，即 CGEventSourceSecondsSinceLastInputEvent 的语义）覆盖键盘/
        // 鼠标/触控板等全部输入类型。
        let anyInputEventType = CGEventType(rawValue: ~UInt32(0))!
        let sinceLastInput = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInputEventType)
        // 取两者较小值：睡眠/锁屏期间累积的"无输入"时长不该在唤醒后立刻算成空闲，
        // 但唤醒后如果确实一直没人动，过了 idleThresholdSeconds 依然会正常转入空闲。
        let sinceFloor = Date().timeIntervalSince(activityFloor)
        let idleSeconds = min(sinceLastInput, sinceFloor)
        return idleSeconds > Double(config.idleThresholdSeconds)
    }

    func prepareRuntime() {
        // 墓碑还在 ⇒ 上一次运行没走到"退休墓碑"那一步（正常退出和已确认上报的强杀都会退休它），
        // 也就是没有正常结束。文件里的时间戳是上次运行最后一次刷新的时刻（见 touchRuntimeLock），
        // 即"最后一次确认在线"，据此向后端补报。
        if let data = try? Data(contentsOf: Self.lockFileURL),
           let value = String(data: data, encoding: .utf8),
           let timestamp = TimeInterval(value) {
            previousCrashLock.lock()
            previousCrashAt = Date(timeIntervalSince1970: timestamp)
            previousCrashLock.unlock()
        }
        Self.touchRuntimeLock()
        startActivitySwitchTracking()
    }

    /// 前台应用切换跟踪：每次切到另一个 App 时 ① 计数（喂给 dashboard「简报」的切换
    /// 频率图）② 安排一次即时上报，让本次切换近实时在家长端出现一条记录。只跟踪"切到
    /// 另一个 App"，不涉及同一 App 内切窗口/切标签页（那需要给每个运行中的 App 挂
    /// AXObserver，覆盖面还不完整，暂不做）。
    private func startActivitySwitchTracking() {
        guard switchObserver == nil else { return }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        switchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            // 弹任何 NSAlert（绑定码/关于/凭据失效/退出密码……）都要求 BigDaddy 自己短暂
            // 变成 active app（key window 的前提），不过滤的话孩子每次跟客户端自身界面
            // 交互都会被误记成"切换到了 BigDaddy"，污染 switchCount 和审计日志。
            if let activated = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               activated.processIdentifier == ownPID {
                return
            }
            self.switchCounter.increment()
            self.scheduleSwitchHeartbeat()
        }
    }

    /// 切换 App 触发的即时上报，带一个防抖窗口：快速 alt-tab 连切时只在切换停下来后
    /// 发一次，把一串连切合并成一条上报（该次心跳的 switchCount 会如实带上这串的次数）。
    /// 既让"切换后近实时出现记录"成立，又不至于每激活一次就打一个请求造成请求风暴。
    private func scheduleSwitchHeartbeat() {
        switchHeartbeatWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // 用 APP_SWITCH 事件而非 HEARTBEAT，让家长在审计日志里能把"切换应用"与
            // 周期性心跳区分开；后端 deriveStatus 仍把它当活跃信号（→ ONLINE）。
            Task { await self.sendHeartbeat(event: .appSwitch) }
        }
        switchHeartbeatWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    /// 非破坏性读取：调用方据此判断"上次是否异常终止"（例如写一条本机审计日志），不改变状态。
    /// 注意不要用它去组装上报字段——那要走 takePreviousCrashForReporting()。
    var detectedPreviousCrash: Date? {
        previousCrashLock.lock()
        defer { previousCrashLock.unlock() }
        return previousCrashAt
    }

    /// 取走墓碑时间戳，交给这一次心跳携带。
    ///
    /// 是"取走"而不是"读取"：同一时刻可能有好几条心跳在飞（启动那一刻的 START、周期心跳、
    /// 切换应用的即时上报），谁都读得到的话同一次异常终止会被上报好几遍，库里堆出一串
    /// previous_crash_at 相同的记录。取走之后只有这一条心跳带着它。
    ///
    /// 清空的时机也随之定死在 sendHeartbeat 内部：**送达后端或写入补发队列都算已经持久
    /// 记录**（PendingQueue 是落盘的加密队列，见其注释），只有被后端明确拒绝、既没落库
    /// 也没进队列时才放回去重试（见 restorePreviousCrash）。此前是由调用方"仅在心跳成功
    /// 时清空"，离线启动时这个时间戳会一直留在内存里，被本次会话往后的每一条心跳反复带上。
    private func takePreviousCrashForReporting() -> Date? {
        previousCrashLock.lock()
        defer { previousCrashLock.unlock() }
        let value = previousCrashAt
        previousCrashAt = nil
        return value
    }

    /// 这条心跳被后端明确拒绝（401），既没落库也没进补发队列——把墓碑时间戳放回去，交给
    /// 下一条心跳重试，否则这次异常终止就被无声丢弃了（它只存在于内存里：启动时读出后，
    /// 磁盘上的墓碑已经被本次运行的时间戳覆盖）。
    private func restorePreviousCrash(_ crashedAt: Date) {
        previousCrashLock.lock()
        defer { previousCrashLock.unlock() }
        // 正常情况下一次运行只会有一个墓碑时间戳；万一期间已经写进了别的值，以新值为准。
        if previousCrashAt == nil {
            previousCrashAt = crashedAt
        }
    }

    /// 签名接口（心跳/config/commands/verify-exit/screenshot）收到 401 时调用：说明本机
    /// 手上的指纹+secret 当下已经过不了 BigDaddyDeviceAuthService 的认证（设备被解绑后又
    /// 整条数据库记录被删掉就是这种情况），和 register() 报告 credentialsValid=false 是
    /// 同一件事——把它标成失效，下一轮 pollConfigForChildVisibility 就会自动改走 register()
    /// 去问权威状态，而不是让签名请求继续静默失败、本地 bound 状态永远卡在旧值上。
    private func markCredentialsInvalid() {
        let wasInvalid = credentialsInvalid
        credentialsInvalid = true
        if !wasInvalid {
            NSLog("BigDaddy: signed request rejected as unauthorized (401); marking credentials invalid, will retry via register()")
        }
    }

    func register() async {
        let body: [String: Any] = [
            "deviceFingerprint": identity.fingerprint,
            "deviceSecretHash": identity.secretHash,
            "appVersion": AppVersion.current,
            "hostname": Host.current().localizedName ?? "Mac",
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString
        ]
        if let data = try? await request(path: "/bigdaddy/client/register", method: "POST", body: body, signed: false),
           let response = try? JSONDecoder.bigDaddy.decode(ApiResponse<DeviceResponse>.self, from: data) {
            self.bindToken = response.data.bindToken
            let wasInvalid = self.credentialsInvalid
            self.credentialsInvalid = response.data.credentialsValid == false
            if self.credentialsInvalid && !wasInvalid {
                NSLog("BigDaddy: device secret rejected by backend (device is bound); signed requests will fail until re-bind")
            }
            // register 不走设备签名，是验签通道失效时唯一可靠的绑定状态来源。
            // 向两个方向同步：后端确认已解绑就立即翻转本地状态；后端确认已绑定但
            // 本地认为未绑定时（本地凭据文件丢失后的常见情形）也立即修正。config.bound
            // 本身不携带守护策略，完整配置等凭据恢复后由 refreshConfig 补全。
            let remoteBound = response.data.bound ?? (response.data.boundAt != nil)
            if config.bound != remoteBound {
                config.bound = remoteBound
                if !remoteBound {
                    config.hasPendingCommand = false
                }
                ConfigStore.save(config)
                NotificationCenter.default.post(
                    name: Self.webFilterConfigChangedNotification,
                    object: self
                )
            }
        }
    }

    @discardableResult
    func refreshConfig() async -> ConfigRefreshResult {
        let data: Data
        do {
            data = try await request(path: "/bigdaddy/client/config", method: "GET", body: nil, signed: true)
        } catch let error as BigDaddyAPIError where error.isAuthFailure {
            markCredentialsInvalid()
            return .failed
        } catch {
            return .failed
        }
        guard let response = try? JSONDecoder.bigDaddy.decode(ApiResponse<ClientConfig>.self, from: data) else {
            return .failed
        }
        let previous = config
        let remote = response.data
        if remote.bound {
            // 已绑定：后端配置是权威策略，完整应用并持久化
            config = remote
            ConfigStore.save(config)
        } else {
            // 未绑定只是连接性/绑定状态信号，不是权威策略——不能用它整体覆盖本地
            // 配置（哪怕是"曾经绑定、现在被解绑"这种状态转换），只更新 bound 相关
            // 字段。此前的实现在这个转换时会执行 config = ClientConfig()，把整份
            // 本地配置重置为默认值，是对规格明确要求的违反。
            config.bound = false
            config.hasPendingCommand = false
            ConfigStore.save(config)
        }
        if config.webFilter != previous.webFilter || config.bound != previous.bound {
            NotificationCenter.default.post(
                name: Self.webFilterConfigChangedNotification,
                object: self
            )
        }
        // 清掉孩子在本机用验证码打下的关闭覆盖，让家长策略重新生效。只在覆盖确实生效时
        // 才判断——isEnabled 已经是 true 时这个决定毫无意义，没必要跑。
        if !ContinuityModePreference.isEnabled,
           ContinuityModeController.shouldClearOverride(
               remoteContinuityMode: config.continuityMode,
               previousContinuityMode: previous.continuityMode,
               remoteUpdatedAt: config.continuityModeUpdatedAt,
               overrideBaseline: ContinuityModePreference.overrideBaseline
           ) {
            ContinuityModePreference.isEnabled = true
            ContinuityModePreference.overrideBaseline = nil
        }
        ContinuityModeController.sync(enabled: config.continuityMode && ContinuityModePreference.isEnabled)
        return config != previous ? .successChanged : .successUnchanged
    }

    func reportWebFilterStatus(_ report: WebFilterStatusReport) async {
        guard config.bound, !credentialsInvalid else { return }
        var body: [String: Any] = [
            "systemExtensionState": report.systemExtensionState.rawValue,
            "enforcementState": report.enforcementState.rawValue,
            "requestedRevision": report.requestedRevision,
            "appliedRevision": report.appliedRevision,
            "ruleCount": report.ruleCount
        ]
        if let lastAppliedAt = report.lastAppliedAt {
            body["lastAppliedAt"] = ISO8601DateFormatter().string(from: lastAppliedAt)
        }
        if let error = report.error {
            body["error"] = error
        }
        do {
            _ = try await request(
                path: "/bigdaddy/client/web-filter/status",
                method: "POST",
                body: body,
                signed: true
            )
        } catch let error as BigDaddyAPIError where error.isAuthFailure {
            markCredentialsInvalid()
        } catch {
            NSLog("BigDaddy: web filter status report failed: \(error.localizedDescription)")
        }
    }

    /// 记录最近一次截图时间，随心跟上报
    private var lastScreenshotAt: Date?

    // 客户端不再计算 appType：后端 AI 日报按 activeAppName 用自己更全的词表重新分类
    // （见 BigDaddyService.classifyAppCategory），客户端这份既没人消费、词表又窄，已移除。

    /// 发送心跳。返回是否成功送达后端，供强杀/退出等需要"确认上报后才清理本地状态"的调用方判断。
    ///
    /// - Parameter filterExtensionSurvivedGap: 仅在补报"上次运行没有正常结束"的那次 START
    ///   心跳上才有意义，其余调用方一律留 nil。见 WebFilterController.extensionSurvivedGap
    ///   的注释——这是内容过滤系统扩展能否证明"本机在那段空窗期里其实一直通电在线"的
    ///   事后取证信号，nil 表示问不出来（不代表"否"）。
    @discardableResult
    func sendHeartbeat(event: EventType, filterExtensionSurvivedGap: Bool? = nil) async -> Bool {
        // 墓碑刷成"此刻仍然在线"。放在函数最前面（第一个 await 之前）是刻意的：正常退出/
        // 强杀路径会在发完这条心跳后退休墓碑，刷新必须发生在退休之前，不能被下面那些
        // 可能很慢的采集调用推到退休之后（真会推过去时由退休标记兜底，见 touchRuntimeLock）。
        Self.touchRuntimeLock()
        // 凭据已知失效（register() 报过 credentialsValid=false）时，签名请求注定会被
        // BigDaddyDeviceAuthService 拒绝——不再徒劳重试，等下一轮 register() 恢复。
        guard !credentialsInvalid else { return false }
        let version = AppVersion.current
        let activeApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        // activeWindowInfo 浏览器场景下靠 NSAppleScript 给目标浏览器发 Apple Event 并同步
        // 等回复，没有超时保护；目标浏览器卡顿/无响应时能一直等下去。这个调用之前直接摆在
        // sendHeartbeat 开头、第一个 await 之前——而 sendHeartbeat 的调用方全部是
        // Task { @MainActor in ... } 或主队列的信号处理器，函数体在第一次挂起前跟调用方
        // 同线程执行，等于每次心跳都可能拿主线程去顶浏览器的 Apple Event 超时，
        // 表现为整个客户端（含菜单栏图标）间歇性卡住。挪进 Task.detached 让它跑在
        // 后台线程，主线程不再被这个不受控的阻塞调用拖住。
        let (windowTitle, activeUrl) = await Task.detached(priority: .utility) { [self] in
            self.activeWindowInfo()
        }.value
        // 先取走计数并清零，即便这次心跳发送失败被塞进 PendingQueue 重试，这个区间的
        // 切换次数也已经落进这份 body 里，不会因为重试而重复计数或者丢失。
        let switchCount = switchCounter.takeAndReset()
        // 同理取走墓碑时间戳：这条心跳是它唯一的携带者（见 takePreviousCrashForReporting）
        let reportedCrashAt = takePreviousCrashForReporting()

        var body: [String: Any] = [
            "appVersion": version,
            "eventType": event.rawValue,
            "lastHeartbeatAt": ISO8601DateFormatter().string(from: Date()),
            "activeAppName": activeApp,
            "activeWindowTitle": windowTitle,
            "activeUrl": activeUrl,
            "switchCount": switchCount,
            "previousCrashAt": reportedCrashAt.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
            "reportedAt": ISO8601DateFormatter().string(from: Date()),
            "metadata": [
                "screenRecordingGranted": hasScreenRecordingAccess(),
                "accessibilityGranted": AXIsProcessTrustedWithOptions(nil),
                // 浏览器 URL 这次为什么没拿到（NOT_APPLICABLE 表示前台不是浏览器、一切正常）。
                // 与上面两个权限位同样每次心跳都带，家长端才能在"这条日志没有链接"的当下
                // 立刻说清是缺授权还是浏览器没开窗口，而不是只看到一段没有链接的纯文本。
                "urlUnavailableReason": lastUrlUnavailableReason.rawValue,
                "browserBundleId": lastBrowserBundleID as Any? ?? NSNull(),
                // 是否有浏览器确实被拒过自动化授权。上面两个字段说的是"这一条记录为什么
                // 没有网址"，这个说的是"这台机器现在有没有一项待修的授权"——家长端的
                // 开通引导要靠它给「在孩子的 Mac 上完成授权」那一步打勾，那一步只能由
                // 坐在孩子电脑前的人完成，家长自己看不到任何进度。
                //
                // 注意它是 blocked 不是 granted：客户端只有在真的尝试读取并被系统拒绝时
                // 才知道这件事，孩子一次浏览器都没开的话无从证明"已授权"。false 的含义
                // 是"目前没有发现问题"。
                "automationBlocked": automationBlocked,
                // 开机自动启动的当前状态位：与权限位一样每次心跳都上报，家长端因此始终
                // 能在服务端看到本机是否仍会开机自启，不必依赖"关闭那一刻"的单次事件
                // 能否送达（那次事件可能因断网落进 PendingQueue 延迟补发）。
                // launchAtLoginEnabled 是本机"意图"（客户端偏好），launchAtLoginOsStatus 是
                // OS 层"实际"状态：两者不一致（如 enabled + notRegistered）即意味着有人在
                // 系统设置的登录项里手动关掉了自启——这是 App 内验证码开关拦不住的绕过，
                // 家长端应据此告警。
                "launchAtLoginEnabled": LaunchAtLoginPreference.isEnabled,
                "launchAtLoginOsStatus": LaunchAtLoginController.osLevelStatusDescription,
                // 连续性模式：continuityModeEnabled 是家长配置的意图（config.continuityMode），
                // continuityModeOsStatus 是本机 launchd KeepAlive 的实际状态。孩子用验证码
                // 在本机关闭后，两者会分叉，家长端应据此告警。
                "continuityModeEnabled": config.continuityMode,
                "continuityModeOsStatus": ContinuityModeController.osLevelStatusDescription,
                // 还有多少条断网期间的记录尚未补传。家长端据此显示"正在补传 N 条"——
                // 限速补发要花几十分钟，没有这个数字的话家长只会看到时间线在自己眼前
                // 不断长出新内容，读起来像系统在乱跳。
                "pendingQueueDepth": PendingQueue.depth,
                // 只在补报上次异常终止的那条 START 心跳上才非 nil，见本函数参数文档。
                "filterExtensionSurvivedGap": filterExtensionSurvivedGap as Any? ?? NSNull()
            ]
        ]
        // 如果有截图记录，一并上报
        if let lastShot = lastScreenshotAt {
            body["lastScreenshotAt"] = ISO8601DateFormatter().string(from: lastShot)
        } else {
            body["lastScreenshotAt"] = NSNull()
        }
        do {
            let data = try await request(path: "/bigdaddy/client/heartbeat", method: "POST", body: body, signed: true)
            if let response = try? JSONDecoder.bigDaddy.decode(ApiResponse<HeartbeatResponse>.self, from: data),
               let pending = response.data.hasPendingCommand {
                config.hasPendingCommand = pending
            }
            lastHeartbeatDescription = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            // 实时心跳刚刚成功 ⇒ 通往后端的整条链路此刻是通的。这是补发最可靠的触发点：
            // 强制门户、DNS 黑洞、后端 5xx 这些"网络路径始终 satisfied"的故障恢复时，
            // NWPathMonitor 不会给出任何信号，只有这里能发现"可以开始补了"。
            // 补发是独立任务，不阻塞本次心跳返回。
            if event != .sleep && PendingQueue.depth > 0 {
                Task { await self.startBackfillIfNeeded() }
            }
            return true
        } catch let error as BigDaddyAPIError where error.isAuthFailure {
            // 服务器明确拒绝（设备已不存在/签名过不了），不是网络抖动，
            // 重试也不会成功——不进补发队列，改走 credentialsInvalid 恢复路径。
            NSLog("BigDaddy: heartbeat rejected (401): \(error.errorDescription ?? "")")
            markCredentialsInvalid()
            // 这条 body 被丢弃了，墓碑时间戳还没有任何持久记录：放回去交给下一条心跳
            if let reportedCrashAt { restorePreviousCrash(reportedCrashAt) }
            return false
        } catch let error as BigDaddyAPIError where error.isRateLimited {
            // 被限流：这条事件照样要进队列（不能丢），但要顺带让补发一起退避——
            // 实时上报的优先级高于补发历史，撞到 429 说明当下额度已经吃紧了。
            NSLog("BigDaddy: heartbeat rate limited, queuing for backfill: \(error.errorDescription ?? "")")
            noteRateLimited(retryAfter: error.retryAfterSeconds)
            PendingQueue.enqueue(body)
            return false
        } catch {
            NSLog("BigDaddy: heartbeat failed, queuing for retry: \(error.localizedDescription)")
            PendingQueue.enqueue(body)
            return false
        }
    }

    private var pathMonitor: NWPathMonitor?
    private var lastPathSatisfied = false

    /// 用 NWPathMonitor 监听网络恢复：一旦从"不可达"变为"可达"，尝试补发积压的心跳。
    ///
    /// 注意这**不是**唯一的触发点，而只是最快的那个。"网络不畅"里最常见的几种场景恰好
    /// 不改变 path.status（酒店/学校的强制门户、DNS 黑洞、后端 5xx、被限流），此时 Wi-Fi
    /// 始终是 .satisfied，路径永远不翻转。所以补发还有另外两个触发点：每次实时心跳成功后
    /// （见 sendHeartbeat），以及 60 秒配置轮询的兜底（见 AppDelegate）。
    func startNetworkMonitoring() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = path.status == .satisfied
            if satisfied && !self.lastPathSatisfied {
                Task { await self.startBackfillIfNeeded() }
            }
            self.lastPathSatisfied = satisfied
        }
        monitor.start(queue: DispatchQueue(label: "com.bigdaddy.pathmonitor"))
        pathMonitor = monitor
    }

    // MARK: - 限速补发

    private let backfillLock = NSLock()
    private var backfillRunning = false
    /// 被服务端限流后，不早于这个时刻再发补发请求。实时心跳撞到 429 时也会写这个值，
    /// 让补发一起退避——实时上报的优先级高于补发历史，不能让补发把当下的心跳挤掉。
    private var rateLimitedUntil: Date?

    /// 两条补发之间的间隔。约合 15 次/分钟，与后端给每台设备的 60 次/分钟额度之间
    /// 刻意留出大片余量：同一分钟里还要容纳 1 次周期心跳和最多约 20 次 APP_SWITCH
    /// 即时上报（防抖窗口 2 秒）。宁可补得慢一点，也不要让补发把实时上报挤成 429。
    /// 真实节奏由服务端的 Retry-After 兜底校正，这个常量只是起步值。
    private let backfillInterval: TimeInterval = 4.0
    /// 同一条记录连续被限流这么多次就收手，把机会让给下一个触发点，避免在长时间限流下
    /// 空转（每次循环都要等一个退避窗口，虽不是忙等，但也没有继续下去的意义）。
    private let maxConsecutiveRateLimits = 5

    /// 启动限速补发（幂等）：已经在补的时候直接返回，队列空时什么都不做。
    ///
    /// 之所以是"限速"而不是一股脑发完：后端按设备限流，一次长时间断网可能积压上千条，
    /// 全速灌进去只会让前几十条成功、其余全部 429——而 429 在客户端和网络故障走同一条
    /// 路径（重新入队），结果就是补发在最需要它的时候原地失效。
    /// 抢占"补发进行中"标记。拿到返回 true，已有补发在跑返回 false。
    ///
    /// 刻意做成同步方法而不是在 async 函数里直接持锁：NSLock 在异步上下文里加解锁
    /// 会跨越潜在的挂起点（Swift 6 里直接是错误），而这里加锁与解锁之间没有任何 await，
    /// 封成同步调用既正确又能消掉那条诊断。
    private func beginBackfill() -> Bool {
        backfillLock.lock()
        defer { backfillLock.unlock() }
        if backfillRunning { return false }
        backfillRunning = true
        return true
    }

    private func endBackfill() {
        backfillLock.lock()
        defer { backfillLock.unlock() }
        backfillRunning = false
    }

    func startBackfillIfNeeded() async {
        guard beginBackfill() else { return }
        defer { endBackfill() }

        let depth = PendingQueue.depth
        guard depth > 0 else { return }
        NSLog("BigDaddy: starting paced backfill of \(depth) queued heartbeat(s)")
        await drainPendingQueue()
    }

    private func drainPendingQueue() async {
        var sent = 0
        var consecutiveRateLimits = 0

        while true {
            if Task.isCancelled { return }

            // 退避窗口内先睡够，再取队首——睡醒之后队列可能已经被实时心跳追加了新条目，
            // 但队首（最老的那条）不会变，取的顺序依然是从旧到新。
            if let until = rateLimitedUntil, until > Date() {
                let seconds = until.timeIntervalSinceNow
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            }

            guard let body = PendingQueue.peekOldest(limit: 1).first else { break }

            do {
                _ = try await request(path: "/bigdaddy/client/heartbeat", method: "POST", body: body, signed: true)
                PendingQueue.removeFirst(1)
                sent += 1
                consecutiveRateLimits = 0
            } catch let error as BigDaddyAPIError where error.isRateLimited {
                consecutiveRateLimits += 1
                noteRateLimited(retryAfter: error.retryAfterSeconds)
                if consecutiveRateLimits >= maxConsecutiveRateLimits {
                    NSLog("BigDaddy: backfill paused after \(consecutiveRateLimits) rate limits, \(PendingQueue.depth) left")
                    return
                }
                continue    // 不摘除队首，退避结束后重试同一条
            } catch let error as BigDaddyAPIError where error.isAuthFailure {
                // 凭据失效：整个补发都过不了验签，继续下去毫无意义
                NSLog("BigDaddy: backfill aborted, credentials rejected (401)")
                markCredentialsInvalid()
                return
            } catch let error as BigDaddyAPIError where (400..<500).contains(error.statusCode) {
                // 4xx（非 401/429）说明**这一条**的内容被服务端明确拒绝，重试多少次都一样。
                // 必须丢掉它，否则这条"毒丸"会永远卡在队首，把它后面所有正常记录一起堵死
                // （典型来源：旧版客户端写下的、字段已经不兼容的队列条目）。
                NSLog("BigDaddy: dropping unacceptable queued entry (HTTP \(error.statusCode)): \(error.errorDescription ?? "")")
                PendingQueue.removeFirst(1)
                continue
            } catch {
                // 网络又断了：队列原样保留，等下一个触发点
                NSLog("BigDaddy: backfill interrupted (\(error.localizedDescription)), \(PendingQueue.depth) left")
                return
            }

            try? await Task.sleep(nanoseconds: UInt64(backfillInterval * 1_000_000_000))
        }

        if sent > 0 {
            NSLog("BigDaddy: backfill complete, \(sent) heartbeat(s) delivered")
            AuditLog.record("BACKFILL_COMPLETED count=\(sent)")
        }
    }

    /// 记下限流退避截止时刻。服务端带了 Retry-After 就听它的，没带则保守退避一分钟
    /// （限流桶是整分钟一次性补满的，等满一分钟一定拿得到令牌）。
    private func noteRateLimited(retryAfter: Int?) {
        let seconds = TimeInterval(retryAfter ?? 60)
        let until = Date().addingTimeInterval(seconds)
        if let current = rateLimitedUntil, current > until { return }
        rateLimitedUntil = until
    }

    /// 正常退出（已通过远程验证码确认）：同步阻塞发送 SHUTDOWN 心跳，确保 HTTP 请求
    /// 在进程真正退出前已经从本机发出，再清除墓碑文件。此前用 Task.detached 异步发起
    /// 后立即返回，调用方紧接着 NSApp.terminate() 可能在请求真正发出前就把进程杀掉，
    /// 导致家长端收不到孩子正常退出的记录。这里用信号量把异步请求桥接成同步阻塞，
    /// 并设置较短的超时（默认 2.5 秒）防止网络异常时卡死退出流程——不强求等到服务端
    /// 响应，只保证请求已经发出或已经写入补发队列。
    /// 注意：全局只应在这一处（quitWithPassword 校验通过后）调用一次；
    /// applicationWillTerminate 不再重复调用，避免 SHUTDOWN 被重复上报两次。
    func sendShutdownSync(timeout: TimeInterval = 2.5) {
        sendEventSync(event: .shutdown, timeout: timeout)
        Self.retireRuntimeLock()
    }

    /// 同步阻塞发送一条事件，用于"进程/系统马上就要停下来，必须先把请求发出去"的场合
    /// （正常退出、系统休眠）。用信号量把异步请求桥接成同步，并设较短超时防止网络异常时
    /// 卡死调用方——不强求等到服务端响应，只保证请求已经发出或已经写入补发队列。
    ///
    /// 休眠场景尤其依赖这个同步语义：macOS 在 willSleep 通知里只给应用几秒钟，
    /// 异步发起后立刻返回的话，进程往往在请求真正上路之前就被冻结了。
    func sendEventSync(event: EventType, timeout: TimeInterval = 2.5) {
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await self.sendHeartbeat(event: event)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
    }

    /// 限时上报，用于信号处理场景：绝不无限等待网络，避免拖着进程迟迟无法退出。
    /// 返回是否确认送达（超时或请求失败都算未确认）。
    private func sendForceKillHeartbeatWithTimeout(seconds: UInt64 = 2) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await self.sendHeartbeat(event: .forceKill) }
            group.addTask {
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    /// 收到 SIGTERM/SIGINT/SIGHUP 时调用：这些信号意味着进程被外部终止，而不是
    /// 孩子通过菜单走验证码确认的正常退出，因此上报事件类型是 FORCE_KILL 而不是
    /// SHUTDOWN，让家长知道守护进程是被意外/强制关闭的。只有确认上报成功才清除
    /// 墓碑文件；上报失败或超时（例如进程正被系统强制拖走）则保留墓碑，交给下次
    /// 启动时的兜底检测补报，避免这次事件被无声丢弃。
    static func sharedForceKillPing(completion: @escaping () -> Void) {
        guard let instance = lastSharedInstance else {
            completion()
            return
        }
        Task {
            let reported = await instance.sendForceKillHeartbeatWithTimeout()
            if reported {
                retireRuntimeLock()
            }
            completion()
        }
    }

    private var lastImagePixels: [UInt8]?

    func isImageSimilarToLast(cgImage: CGImage) -> Bool {
        let width = 8
        let height = 8
        var pixels = [UInt8](repeating: 0, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return false
        }
        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        guard let lastPixels = lastImagePixels else {
            lastImagePixels = pixels
            return false
        }
        lastImagePixels = pixels
        
        var diffSum: Int = 0
        for i in 0..<pixels.count {
            diffSum += abs(Int(pixels[i]) - Int(lastPixels[i]))
        }
        let averageDiff = Double(diffSum) / Double(pixels.count)
        NSLog("BigDaddy: Screenshot similarity diff score = \(averageDiff)")
        return averageDiff < 8.0
    }

    // 受支持的浏览器按 **bundle identifier** 匹配，不再按 localizedName 做子串匹配：
    // 应用名会随系统语言变化（中文系统下 Safari 的 localizedName 是"Safari浏览器"）、
    // 会被用户改名，而且子串匹配本身就脆——"Google Chrome" 会抢先命中
    // "Google Chrome Canary"，"Arc" 会命中 "Archive Utility"，都得靠排序和特例去绕。
    // bundle id 是稳定且唯一的，一次匹配到底。
    //
    // 注意：AppleScript 自动化是按"发起方 App × 目标 App"逐对授权的 TCC 权限
    // （kTCCServiceAppleEvents），与辅助功能、屏幕录制完全独立，且需要 Info.plist 里的
    // NSAppleEventsUsageDescription 才能弹出授权框，否则静默失败。
    enum BrowserDialect {
        /// Chromium 系：`title`/`URL` of active tab
        case chromium
        /// Safari 系：`name`/`URL` of current tab
        case safari
    }

    static let supportedBrowsers: [String: BrowserDialect] = [
        "com.google.Chrome": .chromium,
        "com.google.Chrome.canary": .chromium,
        "com.google.Chrome.beta": .chromium,
        "com.google.Chrome.dev": .chromium,
        "org.chromium.Chromium": .chromium,
        "com.microsoft.edgemac": .chromium,
        "com.microsoft.edgemac.Beta": .chromium,
        "com.brave.Browser": .chromium,
        "com.brave.Browser.beta": .chromium,
        "com.vivaldi.Vivaldi": .chromium,
        "com.operasoftware.Opera": .chromium,
        "company.thebrowser.Browser": .chromium,   // Arc
        "company.thebrowser.dia": .chromium,       // Dia
        "com.apple.Safari": .safari,
        "com.apple.SafariTechnologyPreview": .safari
    ]

    /// 前台是浏览器却拿不到 URL 时，究竟卡在哪一步。之前这些情况全部收敛成同一个空
    /// 字符串，客户端、后端、家长三方都无从判断"这台设备为什么没有网址记录"——
    /// 是权限没给（需要引导授权），还是浏览器压根没开窗口（正常，不该打扰用户），
    /// 又或者用的是 Firefox（能力边界，永远拿不到）。原因码随心跳上报，家长端据此提示。
    enum UrlUnavailableReason: String {
        /// 前台不是浏览器，本来就没有 URL 可言
        case notApplicable = "NOT_APPLICABLE"
        /// Firefox 等没有 AppleScript URL 接口的浏览器，且辅助功能这条路也没读出地址栏
        case unsupportedBrowser = "UNSUPPORTED_BROWSER"
        /// Firefox 系浏览器的地址栏只能走辅助功能读，而本机还没给辅助功能授权。
        /// 与 unsupportedBrowser 必须分开：那个是"这辈子都拿不到，别催了"，这个是
        /// "去系统设置勾一下就有了"，家长看到的提示完全不同。
        case accessibilityDenied = "ACCESSIBILITY_DENIED"
        /// 自动化权限被拒（-1743），需要引导家长去系统设置打开
        case notPermitted = "NOT_PERMITTED"
        /// 还没弹过授权框（-1744），可以主动触发一次系统授权
        case notDetermined = "NOT_DETERMINED"
        /// 浏览器在跑但没有可脚本窗口（-1719 / count 为 0），属正常状态
        case noWindow = "NO_WINDOW"
        /// 其他脚本错误，具体错误码见 NSLog
        case scriptFailed = "SCRIPT_FAILED"
    }

    /// 自动化权限的三态。用 AEDeterminePermissionToAutomateTarget 查询，
    /// askUserIfNeeded 为 false 时**不弹窗、不打扰**，可以每次心跳顺手查一次。
    /// 这是唯一能在进程内确定 BigDaddy 自己（而非 Terminal）授权状态的途径——
    /// TCC 按发起进程的代码签名身份记账，命令行里怎么试都测不到本 App 的状态。
    enum AutomationPermission: Equatable {
        case granted
        /// 用户点过"不允许"，之后不会再弹窗，只能去系统设置手动打开
        case denied
        /// 还没问过，可以弹一次系统授权框
        case notDetermined
        /// 目标浏览器没在运行，本次无法判定
        case targetNotRunning
        case unknown(OSStatus)
    }

    /// errAEEventWouldRequireUserConsent，部分 SDK 版本没有导出这个常量，用字面量兜底
    private static let errAEEventWouldRequireUserConsentCode: OSStatus = -1744

    /// 查询本进程对指定 bundle id 的自动化授权状态。
    /// - Parameter promptIfNeeded: true 时在"尚未询问"状态下会**同步阻塞并弹出**系统
    ///   授权框，因此只能在后台线程调用，且必须由明确的引导流程触发，不能挂在心跳上。
    static func automationPermission(forBundleID bundleID: String, promptIfNeeded: Bool) -> AutomationPermission {
        var target = AEAddressDesc()
        let bytes = Array(bundleID.utf8)
        // AECreateDesc 返回的是 OSErr(Int16)，AEDeterminePermissionToAutomateTarget 返回
        // 的是 OSStatus(Int32)，统一成后者再对外暴露
        let createStatus = OSStatus(AECreateDesc(typeApplicationBundleID, bytes, bytes.count, &target))
        guard createStatus == noErr else { return .unknown(createStatus) }
        defer { AEDisposeDesc(&target) }

        let status = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, promptIfNeeded)
        switch status {
        case noErr:
            return .granted
        case OSStatus(errAEEventNotPermitted):
            return .denied
        case errAEEventWouldRequireUserConsentCode:
            return .notDetermined
        case OSStatus(procNotFound):
            return .targetNotRunning
        default:
            return .unknown(status)
        }
    }

    /// 标题和 URL 在同一个 AppleScript 往返里一起拿，中间用这个几乎不可能出现在真实
    /// 标题/URL 里的不可见字符拼接，回来后再拆开——避免对同一个浏览器发两次独立的
    /// Apple Event（各自都是一次完整的 tell-application 往返）。
    private static let browserFieldSeparator = "\u{2063}"

    /// 生成向指定浏览器一次性查询"当前标签页标题 + URL"的 AppleScript。
    ///
    /// 脚本自带 try/on error 分支并返回 "OK"/"ERR" 前缀的结构化结果：浏览器侧的错误
    /// （典型的是 -1719 没有窗口）必须能和"权限被拒"区分开。
    ///
    /// 关键：权限类错误（-1743/-1744）**两条路都可能走**——脚本里的 try 会捕获它们并
    /// 变成一个"成功"的 ERR 字符串结果，逃不掉的那部分才落进 NSAppleScript 错误字典的
    /// NSAppleScriptErrorNumber。所以调用方必须两层都解析，少一层就会把"被系统回绝"
    /// 误读成"已授权"（probeAutomation 早先就栽在这里，见其注释）。
    ///
    /// 用 `application id` 而不是应用名，与 supportedBrowsers 的匹配键保持一致。
    private func browserTabCombinedScript(bundleID: String, dialect: BrowserDialect) -> String {
        let sep = BigDaddyClient.browserFieldSeparator
        let tabExpr = dialect == .chromium
            ? (title: "title of active tab of front window", url: "URL of active tab of front window")
            : (title: "name of current tab of front window", url: "URL of current tab of front window")
        return """
        tell application id "\(bundleID)"
            try
                if (count of windows) is 0 then return "ERR\(sep)NO_WINDOW"
                return "OK\(sep)" & (\(tabExpr.title)) & "\(sep)" & (\(tabExpr.url))
            on error errMsg number errNum
                return "ERR\(sep)" & errNum
            end try
        end tell
        """
    }

    /// 执行 AppleScript，成功返回字符串结果，失败返回 NSAppleScript 报的错误码。
    /// 之前这里把错误整个吞掉、一律返回 ""，导致权限被拒和"浏览器没开窗口"在上层
    /// 完全无法区分，也没有任何日志——这正是"有的设备有链接、有的没有"查不下去的原因。
    /// OSStatus 是 Int32，不符合 Error，用不了 Result；这里用一个专门的两态枚举
    enum AppleScriptOutcome {
        case success(String)
        case failure(OSStatus)
    }

    private func runAppleScript(_ source: String) -> AppleScriptOutcome {
        guard let script = NSAppleScript(source: source) else { return .failure(OSStatus(errOSAScriptError)) }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? NSNumber)?.int32Value ?? OSStatus(errOSAScriptError)
            return .failure(code)
        }
        return .success(result.stringValue ?? "")
    }

    /// AppleScript 层面的错误码 → 原因码。
    private func reason(forScriptError code: OSStatus) -> UrlUnavailableReason {
        switch code {
        case OSStatus(errAEEventNotPermitted):
            return .notPermitted
        case BigDaddyClient.errAEEventWouldRequireUserConsentCode:
            return .notDetermined
        case OSStatus(errAEIllegalIndex), OSStatus(errAENoSuchObject):
            return .noWindow
        default:
            return .scriptFailed
        }
    }

    /// AppleScript 层面的错误码 → 自动化授权状态。
    ///
    /// 与上面的 reason(forScriptError:) 是同一批错误码的两种读法，故意分开：心跳关心的是
    /// "这条记录为什么没有链接"，授权引导关心的是"用户还需不需要做什么"，同一个 -1719
    /// 在前者是"没有窗口"、在后者却是**权限正常**的证据（事件能被浏览器亲自回绝，说明它
    /// 已经送达了）。合并成一个枚举只会逼调用方在两种语义之间来回翻译。
    private func permission(forScriptError code: OSStatus) -> AutomationPermission {
        switch code {
        case OSStatus(errAEEventNotPermitted):
            return .denied
        case BigDaddyClient.errAEEventWouldRequireUserConsentCode:
            return .notDetermined
        case OSStatus(errAEIllegalIndex), OSStatus(errAENoSuchObject):
            // 浏览器亲自回的错 → 事件送达了 → 权限没问题
            return .granted
        case OSStatus(procNotFound):
            return .targetNotRunning
        default:
            return .unknown(code)
        }
    }

    /// 一次浏览器脚本往返的归一化结果。
    ///
    /// 存在的意义是把"错误码从哪一层冒出来"这件事在这里一次性抹平：脚本里的 try 会把
    /// 权限错误捕获成一个**成功返回**的 ERR 字符串，逃得掉的那部分才落进 NSAppleScript
    /// 的错误字典。两处调用方（心跳取 URL、引导查权限）都必须同时处理这两层，各写一遍
    /// 就必然有一处写漏——此前 probeAutomationByRealEvent 只看 NSAppleScript 那一层，
    /// 一见 .success 就判 granted，于是把"被系统回绝"的 ERR␣-1743 当成了授权成功，
    /// 对着一台完全没有权限的机器弹出"网址记录已生效"。
    private enum BrowserQueryOutcome {
        case tab(title: String, url: String)
        /// 浏览器在跑但没有可脚本窗口，或当前标签页尚未导航到任何地址
        case noWindow
        /// 归一化后的错误码，无论它来自脚本内的 on error 还是 NSAppleScript 错误字典
        case error(OSStatus)
        /// 脚本返回了预期之外的内容
        case malformed(String)
    }

    private func queryBrowserTab(bundleID: String, dialect: BrowserDialect) -> BrowserQueryOutcome {
        let script = browserTabCombinedScript(bundleID: bundleID, dialect: dialect)
        switch runAppleScript(script) {
        case .failure(let code):
            return .error(code)
        case .success(let raw):
            let parts = raw.components(separatedBy: BigDaddyClient.browserFieldSeparator)
            if parts.first == "OK", parts.count == 3 {
                // 极少数情况下浏览器会回一个空 URL（如刚打开、尚未导航的标签页），
                // 这不算失败，但也没有链接可展示，按"没有窗口内容"归类。
                guard !parts[2].isEmpty else { return .noWindow }
                return .tab(title: parts[1], url: parts[2])
            }
            if parts.first == "ERR", parts.count == 2 {
                if parts[1] == "NO_WINDOW" { return .noWindow }
                return .error(OSStatus(parts[1]) ?? OSStatus(errOSAScriptError))
            }
            return .malformed(raw)
        }
    }

    /// 浏览器场景下的标题 + URL，一次 AppleScript 往返拿全。
    /// 拿不到时返回具体原因，交由调用方回退到 CGWindowList/Accessibility（那两条路只有
    /// 标题，没有 URL），并把原因随心跳上报。
    private func browserTabInfo(bundleID: String, dialect: BrowserDialect)
        -> (info: (title: String, url: String)?, reason: UrlUnavailableReason?) {
        switch queryBrowserTab(bundleID: bundleID, dialect: dialect) {
        case .tab(let title, let url):
            return ((title: title, url: url), nil)
        case .noWindow:
            return (nil, .noWindow)
        case .error(let code):
            let reason = reason(forScriptError: code)
            NSLog("BigDaddy: browser query to \(bundleID) failed, OSStatus=\(code), reason=\(reason.rawValue)")
            return (nil, reason)
        case .malformed(let raw):
            NSLog("BigDaddy: unexpected AppleScript payload from \(bundleID): \(raw.prefix(120))")
            return (nil, .scriptFailed)
        }
    }

    /// 一次授权探测的结果：状态 + 顺带读到的当前网址。
    ///
    /// 带上 url 是为了让引导流程能拿**事实**而不是断言去回复用户——"现在读到的是
    /// https://…" 比"网址记录已生效"强得多，而且顺手堵死了误判：读不出真实网址就不
    /// 允许宣称成功。url 为 nil 只说明这一刻没有可读的地址（浏览器没开窗口等），
    /// 不代表权限有问题，两者由 permission 分别表达。
    struct AutomationProbe {
        let permission: AutomationPermission
        let url: String?
    }

    /// 用**真实的 Apple Event** 探测某个浏览器的自动化授权状态。
    ///
    /// 为什么不只用 AEDeterminePermissionToAutomateTarget：那个 API 传 typeWildCard 时
    /// 系统拿不到具体事件类别，实测存在"不弹询问、直接回否定结果"的情况——于是既没有
    /// 创建 TCC 记录（系统设置的自动化面板里因此看不到 BigDaddy），又让调用方误以为
    /// 用户拒绝过。而真正能可靠让系统弹出询问、并在 TCC 里落下记录的，就是老老实实发
    /// 一个真实事件（正是每次心跳在做的事）。
    ///
    /// 注意 notDetermined 状态下本调用会**同步阻塞到用户点选为止**（系统授权框），
    /// 因此只能在后台线程调用。
    func probeAutomation(bundleID: String) -> AutomationProbe {
        guard let dialect = BigDaddyClient.supportedBrowsers[bundleID] else {
            return AutomationProbe(permission: .unknown(OSStatus(errOSAScriptError)), url: nil)
        }
        switch queryBrowserTab(bundleID: bundleID, dialect: dialect) {
        case .tab(_, let url):
            return AutomationProbe(permission: .granted, url: url)
        case .noWindow:
            // 事件送达了浏览器、只是这一刻没有地址可读 → 权限是通的
            return AutomationProbe(permission: .granted, url: nil)
        case .error(let code):
            let permission = permission(forScriptError: code)
            if case .unknown = permission {
                NSLog("BigDaddy: automation probe to \(bundleID) got OSStatus=\(code)")
            }
            return AutomationProbe(permission: permission, url: nil)
        case .malformed(let raw):
            NSLog("BigDaddy: unexpected probe payload from \(bundleID): \(raw.prefix(120))")
            return AutomationProbe(permission: .unknown(OSStatus(errOSAScriptError)), url: nil)
        }
    }

    /// 本机已安装、且 BigDaddy 能读出网址的浏览器（bundle id）。
    ///
    /// 正在运行的排在前面：授权引导只对运行中的浏览器有意义（自动化授权框需要目标 App
    /// 在跑），而"已安装但没在跑"的仍要出现在自检清单里——孩子下次打开它就会用到，
    /// 家长在绑定那一刻把四个浏览器一次性看全，好过日后被四次零散提醒逐个打断。
    static func installedSupportedBrowsers() -> [String] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return supportedBrowsers.keys
            .filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
            .sorted { lhs, rhs in
                let lRunning = running.contains(lhs), rRunning = running.contains(rhs)
                // 运行中的优先；同组内按 bundle id 排序，保证每次渲染的顺序稳定
                // （supportedBrowsers 是字典，keys 的遍历顺序本身没有保证）。
                return lRunning == rRunning ? lhs < rhs : lRunning
            }
    }

    /// 给"只能拿标题"的浏览器发一次真实的标题查询，把系统的自动化授权询问问出来。
    ///
    /// 不能复用 probeAutomation：那个函数第一步就要在 supportedBrowsers 里查方言，
    /// Firefox 查不到、直接返回 .unknown，调用方会把它当成"被拒"记进
    /// automationDeniedBundleIDs，于是菜单里冒出一条针对 Firefox 的「浏览器网址未授权」——
    /// 一个 Firefox 永远不可能满足的诉求。
    ///
    /// 与 probeAutomation 一样会**同步阻塞到用户点选为止**，只能在后台线程调用。
    func warmTitleAutomation(bundleID: String) {
        _ = runAppleScript(windowNameScript(bundleID: bundleID))
    }

    /// 已安装的"只能拿标题、拿不到网址"的浏览器（Firefox 系）。
    ///
    /// 与 installedSupportedBrowsers 分开是刻意的：那个列表驱动着菜单里的
    /// 「⚠️ 浏览器网址未授权 · 点此修复」和授权自检面板，都在谈**网址**读取；
    /// 把 Firefox 混进去，等于让家长对着一个根本不存在的网址开关反复折腾。
    /// 这个列表只有一个用途——绑定时顺带把自动化授权问出来，好让窗口标题这条路
    /// 从孩子第一次打开 Firefox 起就是通的。
    static func installedTitleOnlyBrowsers() -> [String] {
        knownUnscriptableBrowsers
            .filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
            .sorted()
    }

    /// 已经记过一笔的前台应用 bundle id，避免每次心跳都刷同一行日志
    private var loggedUnsupportedBundleIDs: Set<String> = []

    /// 前台应用没有命中 supportedBrowsers 时记一行（每个 bundle id 只记一次）。
    ///
    /// 为什么非记不可：其余所有诊断日志都写在 browserTabInfo 内部，而那个函数**只有
    /// 命中白名单才会被调用**。于是"浏览器没被识别"这种情况下一行日志都不会有，排查时
    /// 看到的是一片空白，和"客户端没在跑""日志没落盘"完全无法区分——实测就因此绕了一圈。
    /// 记下 bundle id 之后，往白名单里补一行就能解决的问题不必再猜。
    private func logUnsupportedFrontAppOnce(bundleID: String, appName: String?, known: Bool) {
        guard !bundleID.isEmpty, !loggedUnsupportedBundleIDs.contains(bundleID) else { return }
        loggedUnsupportedBundleIDs.insert(bundleID)
        NSLog("BigDaddy: front app not URL-capable, bundleID=\(bundleID), name=\(appName ?? "?"), knownBrowser=\(known)")
    }

    /// 最近一次取活动窗口时，浏览器 URL 为什么没拿到。随心跳上报给后端，
    /// 家长端据此把"没有链接"从一个哑状态变成一句可行动的提示。
    private(set) var lastUrlUnavailableReason: UrlUnavailableReason = .notApplicable
    /// 最近一次遇到的浏览器 bundle id，配合上面的原因码定位是哪个浏览器没授权
    private(set) var lastBrowserBundleID: String?

    /// 一次心跳/截图需要的"活动窗口标题 + 浏览器 URL"。浏览器优先走上面的合并 AppleScript
    /// 查询：下面的 CGWindowList(kCGWindowName) 与 Accessibility 两条路都需要屏幕录制或
    /// 辅助功能授权，dev 构建签名不稳定时经常两者都拿不到，导致标题恒为空；而 AppleScript
    /// 自动化是另一套按目标应用逐个授权的 TCC 权限，用它能在缺屏幕录制权限时仍抓到主流
    /// 浏览器的当前页面标题（顺带把 URL 也拿到，不需要再发一次 Apple Event）。
    func activeWindowInfo() -> (title: String, url: String) {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            lastUrlUnavailableReason = .notApplicable
            lastBrowserBundleID = nil
            return ("", "")
        }
        let bundleID = frontApp.bundleIdentifier ?? ""

        if let dialect = BigDaddyClient.supportedBrowsers[bundleID] {
            lastBrowserBundleID = bundleID
            let (info, reason) = browserTabInfo(bundleID: bundleID, dialect: dialect)
            if let info {
                lastUrlUnavailableReason = .notApplicable
                return info
            }
            lastUrlUnavailableReason = reason ?? .scriptFailed
            // 权限类失败广播出去，由 AppDelegate 决定要不要引导用户（带节流）
            if lastUrlUnavailableReason == .notPermitted || lastUrlUnavailableReason == .notDetermined {
                NotificationCenter.default.post(
                    name: BigDaddyClient.browserAutomationBlockedNotification,
                    object: nil,
                    userInfo: ["bundleID": bundleID, "reason": lastUrlUnavailableReason.rawValue]
                )
            }
        } else if BigDaddyClient.knownUnscriptableBrowsers.contains(bundleID) {
            lastBrowserBundleID = bundleID
            // 标题优先走 AppleScript 的**标准套件**（`name of front window`）。
            //
            // Firefox 没有浏览器套件（拿不到标签页 URL），但它的 Info.plist 里
            // NSAppleScriptEnabled 是 true，窗口的 name 属性照常可读——而窗口标题本身
            // 就是"页面标题 — Mozilla Firefox"，家长要的那半句信息全在里面。
            //
            // 这一步很关键：此前 Firefox 的标题只能走 CGWindowList(kCGWindowName) 或
            // 辅助功能，两条路各自要屏幕录制/辅助功能授权，两者都缺时家长端看到的是
            // 一条**既没有标题也没有链接**的空记录——换个浏览器就整条记录消失，看起来
            // 像客户端坏了。AppleScript 用的是另一套（且已经为 Chrome/Safari 引导过的）
            // 自动化授权，缺屏幕录制时也照样拿得到。
            let title = windowTitle(pid: frontApp.processIdentifier, bundleID: bundleID)
            // 地址栏只能从辅助功能树里读（见 addressBarURLViaAccessibility 的注释）。
            if let url = addressBarURLViaAccessibility(pid: frontApp.processIdentifier) {
                lastUrlUnavailableReason = .notApplicable
                return (title, url)
            }
            // 没读到地址栏时要分清是"缺授权"还是"这浏览器就这样"，家长能做的事不同。
            lastUrlUnavailableReason = AXIsProcessTrusted() ? .unsupportedBrowser : .accessibilityDenied
            logUnsupportedFrontAppOnce(bundleID: bundleID, appName: frontApp.localizedName, known: true)
            return (title, "")
        } else {
            lastBrowserBundleID = nil
            lastUrlUnavailableReason = .notApplicable
            logUnsupportedFrontAppOnce(bundleID: bundleID, appName: frontApp.localizedName, known: false)
        }

        return (windowTitle(pid: frontApp.processIdentifier), "")
    }

    /// 前台窗口标题。三条路依次尝试，因为它们各自依赖一套**互不相干**的授权：
    /// 1. `bundleID` 非空时先走 AppleScript 的标准套件（`name of front window`）——
    ///    依赖自动化授权，这是 Firefox 唯一还站得住的那条路（见 activeWindowInfo 里
    ///    knownUnscriptableBrowsers 分支的注释）；
    /// 2. CGWindowList 的 kCGWindowName——该字段自 macOS 10.15 起仅对持有**屏幕录制**
    ///    权限的进程返回，未授权时恒为空；
    /// 3. Accessibility 的 AXTitle——依赖**辅助功能**授权。
    private func windowTitle(pid: pid_t, bundleID: String? = nil) -> String {
        if let bundleID, case let .success(raw) = runAppleScript(windowNameScript(bundleID: bundleID)) {
            let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }
        let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
        if let windowListInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] {
            for info in windowListInfo {
                if let windowOwnerPID = info[kCGWindowOwnerPID as String] as? Int, windowOwnerPID == pid,
                   let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                   let title = info[kCGWindowName as String] as? String, !title.isEmpty {
                    return title
                }
            }
        }
        return accessibilityWindowTitle(pid: pid)
    }

    /// 只问窗口标题的 AppleScript。用**标准套件**的 `name of front window`，任何
    /// NSAppleScriptEnabled 的应用都答得上来，不需要浏览器套件——这正是它对 Firefox
    /// 有效而 browserTabCombinedScript 无效的原因。
    ///
    /// 出错分支返回空串而不是错误码：调用方只需要"拿没拿到标题"，拿不到自会往下走
    /// CGWindowList / 辅助功能两条兜底路；把权限码往上传在这里没有任何消费者。
    private func windowNameScript(bundleID: String) -> String {
        """
        tell application id "\(bundleID)"
            try
                if (count of windows) is 0 then return ""
                return name of front window
            on error
                return ""
            end try
        end tell
        """
    }

    /// Firefox 内部给地址栏输入框的元素 id。与界面语言无关（AXDescription 那一路是
    /// 本地化的，中文版 Firefox 上是"使用 Google 搜索，或者输入网址"，拿它做匹配换个
    /// 语言就失效），实测在 Firefox 上稳定返回 "urlbar-input"。
    private static let firefoxURLBarDOMIdentifier = "urlbar-input"

    /// 网页内容区在辅助功能树里的角色。地址栏一定不在它里面，而它下面挂的是整棵 DOM
    /// （轻松上万个节点），必须整棵跳过——否则广度优先遍历会先被网页内容填满预算。
    private static let webContentAXRole = "AXWebArea"

    /// 从辅助功能树里读 Firefox 系浏览器的地址栏。
    ///
    /// **只对没有 AppleScript 网址接口的浏览器使用**（knownUnscriptableBrowsers）。
    /// Firefox 从来就没有提供过一个可供用户拒绝的自动化开关，所以这里不存在绕过任何
    /// 用户决定的问题，用的是家庭已经知情并授予的辅助功能权限。
    ///
    /// 反过来，**绝不能**把这条路当作 Chromium 系浏览器的兜底：那边用户如果在系统
    /// 授权框上点了"不允许"，那是一次明确的拒绝，换一条通道去取同样的数据就是在
    /// 规避用户刚刚做出的安全决定——那已经不是守护，是欺骗。
    private func addressBarURLViaAccessibility(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let axApp = AXUIElementCreateApplication(pid)
        // 从**焦点窗口**起步，而不是从应用根节点：应用根下面还挂着菜单栏和其他窗口，
        // 从它开始等于先把预算花在孩子此刻并没有在看的东西上。
        guard let focused = axAttribute(axApp, kAXFocusedWindowAttribute as String),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }

        // 广度优先，深度和访问节点数都卡死：地址栏固定在窗口 → 工具栏这几层里
        // （实测 depth 6），不设上限的话每分钟一次心跳都要空跑一遍整棵界面树。
        //
        // 两处修正，正是"Firefox 有时读得到地址栏、有时读不到"的成因：
        // ① 遇到 AXWebArea 整棵跳过。网页内容的辅助功能树轻松上万个节点，而它和地址栏
        //    在同一层的兄弟位置上——广度优先会把这上万个节点排在地址栏所在的深层之前，
        //    预算在到达地址栏之前就被网页内容吃光了，页面越复杂越容易读不到。
        // ② 预算耗尽时 break 而不是 continue。continue 只是不再展开这个节点，循环还要
        //    把队列里剩下的（可能成千上万个）节点一个个弹完才结束，白白空转。
        var queue: [(element: AXUIElement, depth: Int)] = [(focused as! AXUIElement, 0)]
        var visited = 0
        while !queue.isEmpty {
            let (element, depth) = queue.removeFirst()
            visited += 1
            if depth > 10 || visited > 1200 { break }
            if axAttribute(element, "AXDOMIdentifier") as? String == Self.firefoxURLBarDOMIdentifier {
                guard let raw = axAttribute(element, kAXValueAttribute as String) as? String else { return nil }
                return normalizedAddressBarURL(raw)
            }
            if axAttribute(element, kAXRoleAttribute as String) as? String == Self.webContentAXRole { continue }
            if let children = axAttribute(element, kAXChildrenAttribute as String) as? [AXUIElement] {
                for child in children { queue.append((child, depth + 1)) }
            }
        }
        return nil
    }

    private func axAttribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
    }

    /// 地址栏里显示的文本 → 可以当链接用的 URL；判断不了就返回 nil。
    ///
    /// 两件事必须处理，否则家长端会渲染出点不开的假链接：
    /// 1. Firefox 显示时会把 `https://` 前缀藏起来，读出来的是 `zh.wikipedia.org/...`，
    ///    要把 scheme 补回去（补 https，今天绝大多数站点如此；补错也只是链接跳一次转）；
    /// 2. 用户正在地址栏里打字时，这里读到的是半截搜索词而不是网址——带空格、或者
    ///    既没有点号也没有 scheme 的，一律当作"还不是网址"丢弃。
    private func normalizedAddressBarURL(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        // about:/file:/view-source: 这类本身就是完整位置，原样保留
        if let scheme = text.range(of: "://")?.lowerBound, text.distance(from: text.startIndex, to: scheme) > 0 {
            return text
        }
        if text.hasPrefix("about:") || text.hasPrefix("file:") || text.hasPrefix("view-source:") {
            return text
        }
        guard text.contains(".") else { return nil }   // 没有点号 → 多半是正在输入的搜索词
        return "https://" + text
    }

    /// 有 AppleScript 字典但没有 URL 接口的浏览器：明确归类成"能力边界"而不是
    /// "未授权"，避免家长端对着 Firefox 反复提示去授权一个根本不存在的开关。
    static let knownUnscriptableBrowsers: Set<String> = [
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
        "org.torproject.torbrowser",
        "com.apple.SafariViewService"
    ]

    /// 前台浏览器因自动化权限缺失而拿不到 URL 时广播，由 AppDelegate 节流后引导用户授权
    static let browserAutomationBlockedNotification = Notification.Name("BigDaddyBrowserAutomationBlocked")

    /// Accessibility 兜底：读焦点窗口的 AXTitle。需要辅助功能授权（同样受 dev 构建
    /// 签名不稳定影响），但在已授权时能在屏幕录制权限缺失的情况下仍拿到标题。
    private func accessibilityWindowTitle(pid: pid_t) -> String {
        guard AXIsProcessTrusted() else { return "" }
        let appElement = AXUIElementCreateApplication(pid)
        var focusedWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
              let window = focusedWindow, CFGetTypeID(window) == AXUIElementGetTypeID() else { return "" }
        // 按 API 契约这里恒为 AXUIElement，但这是无人值守的后台进程，每次心跳都会
        // 走到这里——用 guard + 运行时类型校验而非强制转换，任何异常都优雅返回空，
        // 不能因为一次意外的返回类型让整个客户端崩溃。
        let axWindow = window as! AXUIElement
        var titleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleValue) == .success,
              let title = titleValue as? String else { return "" }
        return title
    }

    func uploadScreenshot(imageData: Data, activeApp: String, windowTitle: String, activeUrl: String) async throws -> Data {
        let method = "POST"
        let boundary = "BigDaddy-Upload-\(UUID().uuidString)"
        var components = URLComponents(url: baseURL.appendingPathComponent("/bigdaddy/client/screenshot"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "activeAppName", value: activeApp),
            URLQueryItem(name: "activeWindowTitle", value: windowTitle.isEmpty ? nil : windowTitle),
            URLQueryItem(name: "activeUrl", value: activeUrl.isEmpty ? nil : activeUrl)
        ]
        
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(identity.fingerprint, forHTTPHeaderField: "X-Device-Fingerprint")
        
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let nonce = UUID().uuidString
        let pathWithQuery = url.path + (url.query.map { "?\($0)" } ?? "")
        let emptyHash = SHA256.hash(data: Data()).hex
        let canonical = "\(method)\n\(pathWithQuery)\n\(emptyHash)\n\(timestamp)\n\(nonce)"
        
        let key = SymmetricKey(data: identity.secretHash.data(using: .utf8)!)
        let signature = HMAC<SHA256>.authenticationCode(for: canonical.data(using: .utf8)!, using: key).data.base64URLEncodedString()
        
        request.setValue(timestamp, forHTTPHeaderField: "X-Device-Timestamp")
        request.setValue(nonce, forHTTPHeaderField: "X-Device-Nonce")
        request.setValue(signature, forHTTPHeaderField: "X-Device-Signature")
        
        var body = Data()
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"screenshot.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let envelope = try? JSONDecoder.bigDaddy.decode(ApiEnvelope.self, from: data)
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0) }
            throw BigDaddyAPIError(
                statusCode: http.statusCode, serverMessage: envelope?.message, retryAfterSeconds: retryAfter)
        }
        return data
    }

    /// 截图实际发生时广播，供 UI 层给孩子端即时可见提示
    static let screenshotSentNotification = Notification.Name("BigDaddyScreenshotSent")
    /// 自动路径（定时/家长下发命令）因缺屏幕录制权限而静默放弃截图时广播。手动测试
    /// （关于面板里点"测试截图"）不广播这个——用户当时就看着"关于"面板，⚠️ 按钮本身
    /// 已经是最直接的提示，不需要再额外弹一条本机通知重复同一件事。
    static let screenshotMissingPermissionNotification = Notification.Name("BigDaddyScreenshotMissingPermission")
    /// 时间约定状态已随一次 SYNC_TIME_SESSION 门铃刷新（config.timeSession 可能变了），
    /// 供 AppDelegate 立即重新计算旗帜/菜单，不必等到下一次 60 秒配置轮询的对比。
    static let timeSessionSyncedNotification = Notification.Name("BigDaddyTimeSessionSynced")

    /// 把截图按"最大宽度"等比缩小到严格的目标像素尺寸，只缩不放。
    ///
    /// 之前用 `NSImage(size:).lockFocus()` 缩放：lockFocus 会按主屏 backing scale 建后备
    /// 存储，Retina（2x）上一张 640 点宽的 NSImage 导出后其实是 1280 像素——家长把
    /// "截图最大宽度"设成 640，实际收到的截图却是 1280，压缩质量也因为像素翻倍、体积
    /// 常年顶到 300KB 上限而被 compressToTargetSize 反复强压、家长设的挡位形同虚设。
    /// 这里改成直接建一张"精确像素尺寸"的 CGBitmapContext 把源图画进去，输出宽度严格
    /// 等于 targetWidth，与屏幕是不是 Retina 无关。
    private func resizeToMaxWidth(_ image: CGImage, maxWidth: Int) -> NSBitmapImageRep? {
        let srcWidth = image.width
        let srcHeight = image.height
        guard srcWidth > 0, srcHeight > 0 else { return nil }
        // 只缩不放：源图本来就比目标窄时保持原尺寸
        let targetWidth = min(max(1, maxWidth), srcWidth)
        let targetHeight = max(1, Int((Double(srcHeight) * Double(targetWidth) / Double(srcWidth)).rounded()))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let scaled = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled)
    }

    /// 按家长在仪表盘选的压缩质量档位（30/40/50/65/80%）直接编码，不再事后偷偷改档。
    ///
    /// 这里原来有一个"目标字节数"上限（300KB），超出就一路把 quality 往下砍到满足为止。
    /// 问题是：真实截图（代码编辑器、文字密集的界面）远比纯色测试图复杂，在"截图最大
    /// 宽度"960px 时，65%/80% 档位编出来的 JPEG 常年就是 300~460KB 左右，稳定超过这个
    /// 上限——于是 65% 被偷偷砍到约 55%，80% 被一路砍到约 50%，跟直接选 50% 编出来的
    /// 效果几乎一样。家长选的档位形同虚设，65%/80% 永远看不到自己选的画质，这正是
    /// "调质量肉眼看不出区别、80% 也不像该有的清晰度"的根因。
    ///
    /// 现在改成：直接按选定档位编码，不做任何隐藏降级。"压缩质量"和"截图最大宽度"是
    /// 两个独立、彼此正交的档位选择，文件大小已经由二者的固定挡位表共同界定上限——
    /// 用最宽 1280px + 最高 80% 质量、即便是完全随机噪声这种 JPEG 最坏情况也只有约
    /// 1MB，远低于 Telegram Bot API（10MB）、邮件附件、后端 100MB 上传上限里的任何一个，
    /// 没有必要为了凑一个 300KB 的软上限而牺牲用户的实际选择。
    /// 只保留一个远高于正常挡位组合上限、几乎不会触发的兜底：真出现异常导致体积
    /// 离谱地大，也不至于把一张截图挂到几十 MB 拖垮上传/转发。
    private func compressToTargetSize(_ rep: NSBitmapImageRep, startQuality: Double) -> Data {
        let hardCapBytes = 8 * 1024 * 1024
        let data = rep.representation(using: .jpeg, properties: [.compressionFactor: startQuality]) ?? Data()
        guard data.count > hardCapBytes else { return data }
        // 只有真撞到这个远高于正常情况的兜底时才降级，且尽量少降：每次减 0.1，
        // 到 0.1 为止；正常挡位组合下这段代码路径不会被执行到。
        var quality = startQuality
        var fallback = data
        while fallback.count > hardCapBytes && quality > 0.1 {
            quality = max(0.1, quality - 0.1)
            if let smaller = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) {
                fallback = smaller
            } else {
                break
            }
        }
        return fallback
    }

    /// 抓取主显示器一帧画面。macOS 14+ 走 ScreenCaptureKit（`CGDisplayCreateImage`
    /// 已在 macOS 15 被废除，目前仅靠向后兼容仍能运行，随时可能被移除）；更早的系统
    /// 保留旧路径——SCK 的单帧截图 API `SCScreenshotManager` 本身要求 macOS 14。
    ///
    /// 关键：`SCDisplay.width/height` 的单位是"点"，而 `SCStreamConfiguration.width/height`
    /// 的单位是"像素"。之前直接把点数赋给像素数，等于在 Retina（2x）屏上按 1x 半分辨率
    /// 抓取——文字/界面的次像素抗锯齿细节整帧丢失，图像发虚。这种"发虚/模糊"是分辨率
    /// 损失造成的，跟 JPEG 压缩质量无关，所以家长把质量从 40% 调到 80% 也几乎看不出区别
    /// （源图本来就没多少细节可供 JPEG 保留或丢弃）。改成按显示器原生像素分辨率抓取，
    /// 再交给下游 resizeToMaxWidth 做高质量降采样到 compressMaxWidth——同样的目标宽度下，
    /// "先原生抓取、再降采样"远比"直接 1x 抓取"清晰（等效于超采样抗锯齿）。
    private func captureMainDisplayImage() async -> CGImage? {
        if #available(macOS 14.0, *) {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                        ?? content.displays.first else {
                    NSLog("BigDaddy: ScreenCaptureKit returned no displays.")
                    return nil
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let configuration = SCStreamConfiguration()
                // 用 CGDisplayMode 拿当前显示模式的原生像素尺寸；拿不到就回退到点数（退化为
                // 旧的 1x 行为，至少不崩）。宽高都按原生像素设，保持长宽比、避免拉伸/加黑边。
                let (pixelWidth, pixelHeight) = nativePixelSize(displayID: display.displayID,
                                                                fallbackWidth: display.width,
                                                                fallbackHeight: display.height)
                configuration.width = pixelWidth
                configuration.height = pixelHeight
                configuration.showsCursor = false
                return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            } catch {
                NSLog("BigDaddy: ScreenCaptureKit capture failed: \(error.localizedDescription)")
                return nil
            }
        } else {
            // CGDisplayCreateImage 本身就返回原生像素，旧系统路径不受上述点/像素问题影响。
            return CGDisplayCreateImage(CGMainDisplayID())
        }
    }

    /// 返回指定显示器当前显示模式的原生像素尺寸；无法获取时回退到传入的点数尺寸。
    private func nativePixelSize(displayID: CGDirectDisplayID, fallbackWidth: Int, fallbackHeight: Int) -> (Int, Int) {
        if let mode = CGDisplayCopyDisplayMode(displayID) {
            let w = mode.pixelWidth
            let h = mode.pixelHeight
            if w > 0 && h > 0 { return (w, h) }
        }
        return (fallbackWidth, fallbackHeight)
    }

    /// 返回是否真正完成了一次截图上传尝试（用于命令回执：截图被禁用/无权限/上传失败
    /// 都不应该回执 SUCCEEDED，此前命令通道无条件回执成功，是一种"假成功"）。
    @discardableResult
    func captureAndSendScreenshot(reason: String) async -> Bool {
        // 未绑定设备只做最基础登记、不采集行为明细——这是给孩子看的明确承诺（见「守护
        // 说明」弹窗）。screenshotEnabled 单独判断不够：解绑时 refreshConfig() 只翻转
        // bound、刻意保留 screenshotEnabled 原值（不能用"未绑定"信号覆盖整份本地配置），
        // 所以"曾经绑定且开过截图的设备被解绑后"，光看 screenshotEnabled 这一个字段
        // 会认为截图仍应该继续——实际发生过：这个函数在 pollCommands（已有 config.bound
        // 门禁）之外还有定时和手动两条路径，此前都没有独立的 bound 检查，真的会在未绑定
        // 状态下截屏（哪怕上传大概率被后端拒收，本机截屏动作本身已经发生）。
        guard config.bound else {
            NSLog("BigDaddy: device not bound, ignoring capture request (reason: \(reason)).")
            return false
        }
        // screenshotEnabled 由后端配置控制，默认关闭。
        // 任何路径（定时/手动/命令）都必须在开启后才允许截屏，命令通道不再绕过此开关。
        guard config.screenshotEnabled else {
            NSLog("BigDaddy: screenshot disabled, ignoring capture request (reason: \(reason)).")
            return false
        }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            // 手动测试（关于面板里点"测试截图"）时用户本来就正看着"关于"窗口，⚠️ 按钮
            // 已经是最直接的提示，不用再广播；只有自动路径（定时/命令）静默失败时才广播，
            // 让 UI 层决定要不要用一条节流过的本机通知主动提醒用户（见 AppDelegate）。
            if reason != "manual" {
                await MainActor.run {
                    NotificationCenter.default.post(name: BigDaddyClient.screenshotMissingPermissionNotification, object: nil)
                }
            }
            return false
        }
        guard let image = await captureMainDisplayImage() else { return false }

        // 相似度去重只对"定时截图"有意义——静态屏幕下每隔几分钟发一张几乎一样的图纯属
        // 噪音。手动测试（manual）和家长下发的命令（command）都是一次明确的"现在就给我
        // 一张"的请求，必须无条件发送：之前 manual 也走去重，导致静态屏幕下点"测试截图"
        // 悄无声息、什么都没发，被误判成功能坏了。
        if reason == "scheduled" && isImageSimilarToLast(cgImage: image) {
            NSLog("BigDaddy: Screenshot is similar to the last one, skip sending.")
            return false
        }

        guard let rep = resizeToMaxWidth(image, maxWidth: config.compressMaxWidth) else { return false }
        let jpeg = compressToTargetSize(rep, startQuality: config.compressQuality)

        let activeApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        // 同 sendHeartbeat：把可能阻塞的 AppleScript/AX 调用放进 Task.detached，
        // 不依赖"这里执行时已经离开主线程"这种由 ScreenCaptureKit 内部调度决定、
        // 未来系统版本随时可能变化的隐式假设。
        let (windowTitle, activeUrl) = await Task.detached(priority: .utility) { [self] in
            self.activeWindowInfo()
        }.value

        do {
            let responseData = try await uploadScreenshot(imageData: jpeg, activeApp: activeApp, windowTitle: windowTitle, activeUrl: activeUrl)
            // 成功发送后更新截图时间
            lastScreenshotAt = Date()
            // 知情透明：把本次截图动作写入本机可查看/可导出的守护记录
            AuditLog.record("SCREENSHOT_SENT reason=\(reason) app=\(activeApp) window=\(windowTitle)")
            // 后端会明确告知是否真的转发成功（而不是只确认"收到了文件"），
            // 未送达时也要如实记录，避免家长/孩子都以为已经发出去了。
            if let decoded = try? JSONDecoder.bigDaddy.decode(ApiResponse<ScreenshotUploadResponse>.self, from: responseData),
               decoded.data.delivered == false {
                let email = decoded.data.emailStatus ?? "UNKNOWN"
                let telegram = decoded.data.telegramStatus ?? "UNKNOWN"
                AuditLog.record("SCREENSHOT_NOT_DELIVERED reason=\(decoded.data.reason ?? "UNKNOWN") emailStatus=\(email) telegramStatus=\(telegram)")
                NSLog("BigDaddy: Screenshot uploaded but not delivered to any channel: \(decoded.data.reason ?? "unknown") (email=\(email), telegram=\(telegram))")
            }
            // 即时可见：广播截图事件，UI 层据此闪烁菜单栏图标并弹出本机通知
            await MainActor.run {
                NotificationCenter.default.post(name: BigDaddyClient.screenshotSentNotification, object: nil)
            }
            NSLog("BigDaddy: Screenshot uploaded (reason: \(reason)).")
            return true
        } catch let error as BigDaddyAPIError where error.isAuthFailure {
            NSLog("BigDaddy: Screenshot upload rejected (401): \(error.errorDescription ?? "")")
            markCredentialsInvalid()
            return false
        } catch {
            NSLog("BigDaddy: Screenshot upload failed: \(error.localizedDescription)")
            return false
        }
    }

    func pollCommands() async {
        guard config.bound, !credentialsInvalid else { return }
        let data: Data
        do {
            data = try await request(path: "/bigdaddy/client/commands?limit=10", method: "GET", body: nil, signed: true)
        } catch let error as BigDaddyAPIError where error.isAuthFailure {
            markCredentialsInvalid()
            return
        } catch {
            return
        }
        guard let response = try? JSONDecoder.bigDaddy.decode(ApiResponse<[Command]>.self, from: data) else { return }
        let screenshotCommands = response.data.filter { $0.type == "TAKE_SCREENSHOT_NOW" }
        // SYNC_TIME_SESSION 是"门铃"，不携带会话状态本身——不解析 payload，收到就统一
        // 去刷新配置，权威状态在 ConfigResponse.timeSession 里（见 TimeSession 注释）。
        // 一次 poll 可能同时取回多条这样的门铃（家长连续操作了几次"改约/中断"），
        // 逐条 ack 但只需要刷新一次配置，不必每条各刷一次。
        let timeSessionCommands = response.data.filter { $0.type == "SYNC_TIME_SESSION" }
        let configCommands = response.data.filter { $0.type == "SYNC_CONFIG" }
        // 执行"即时截图"前先同步一次最新配置：家长的典型操作就是"在仪表盘改完压缩质量/
        // 截图宽度，立刻点测试截图看效果"。若不在这里刷新，这次截图会用客户端手上（最长
        // 可能落后 60 秒配置轮询）的旧配置，家长对比时就会觉得"改了质量没区别/压缩没生效"。
        let refreshResult: ConfigRefreshResult?
        if !screenshotCommands.isEmpty || !timeSessionCommands.isEmpty || !configCommands.isEmpty {
            refreshResult = await refreshConfig()
        } else {
            refreshResult = nil
        }
        for command in screenshotCommands {
            // 之前无条件回执 SUCCEEDED，哪怕截图因为未开启/无权限/上传失败而根本没发生，
            // 家长在 Dashboard 看到的命令状态是假的。现在按实际结果回执。
            let succeeded = await captureAndSendScreenshot(reason: "command")
            await ack(
                commandId: command.commandId,
                status: succeeded ? "SUCCEEDED" : "FAILED",
                message: succeeded ? "Screenshot command processed" : "Screenshot not captured (disabled, missing permission, or upload failed)"
            )
        }
        if !timeSessionCommands.isEmpty {
            let succeeded = refreshResult?.succeeded == true
            for command in timeSessionCommands {
                await ack(
                    commandId: command.commandId,
                    status: succeeded ? "SUCCEEDED" : "FAILED",
                    message: succeeded ? "Time session synced" : "Time session configuration refresh failed"
                )
            }
            if succeeded {
                NotificationCenter.default.post(name: Self.timeSessionSyncedNotification, object: nil)
            }
        }
        let configSynced = refreshResult?.succeeded == true
        for command in configCommands {
            await ack(
                commandId: command.commandId,
                status: configSynced ? "SUCCEEDED" : "FAILED",
                message: configSynced ? "Configuration synced" : "Configuration refresh failed"
            )
        }
    }

    /// 旗帜首次在孩子屏幕上下拉展示后的回执，供家长在仪表盘确认"孩子真的看到了"
    /// （三步走的第三步）。刻意 fire-and-forget：不解析响应、失败也不重试——旗帜每次
    /// 下拉都会打一发（见 AppDelegate 的里程碑排程），单次没送达不影响后续里程碑
    /// 继续尝试，且后端只记第一次，多打几次并无副作用。
    func reportTimeSessionShown(_ sessionId: String) async {
        let body: [String: Any] = ["sessionId": sessionId]
        _ = try? await request(path: "/bigdaddy/client/time-session/shown", method: "POST", body: body, signed: true)
    }

    /// 孩子在到点提醒上点了「我知道了」。与 shown 的回执是两件事：shown 只说明旗帜
    /// 显示过（电脑前可能没人），这一条说明孩子本人此刻就在、并且亲手关掉了提醒。
    /// 后端据此写一条 TIMER_ACKNOWLEDGED 审计，家长在仪表盘能看到。
    ///
    /// 同样 fire-and-forget：孩子已经点过按钮、面板也已经收回，这是既成事实；为了一条
    /// 回执把界面卡住或弹错误提示，只会让孩子觉得"这个按钮点了没用"。真丢了就丢了，
    /// 到点本身仍由服务端判定并通知家长，不依赖这条。
    func reportTimeSessionAcknowledged(_ sessionId: String) async {
        let body: [String: Any] = ["sessionId": sessionId]
        _ = try? await request(path: "/bigdaddy/client/time-session/acknowledged", method: "POST", body: body, signed: true)
    }

    func verifyExitPassword(_ value: String) async -> Bool {
        // 未绑定设备没有家长账户可以生成临时验证码，允许直接退出。
        // 已绑定设备必须始终远程校验——不能因为本地状态判断就跳过，
        // 否则任意 6 位数字都能绕过退出确认（曾经的漏洞：旧代码在
        // config.exitPasswordHash == nil 时直接放行，而该字段现在恒为空）。
        guard config.bound else {
            return true
        }
        let body: [String: Any] = [
            "exitPassword": value
        ]
        do {
            let data = try await request(path: "/bigdaddy/client/verify-exit", method: "POST", body: body, signed: true)
            if let response = try? JSONDecoder.bigDaddy.decode(ApiResponse<Bool>.self, from: data) {
                return response.data
            }
        } catch let error as BigDaddyAPIError where error.isAuthFailure {
            // 密码校验本身仍然失败关闭（不能因为凭据失效就放行退出），但顺带标记失效，
            // 让后台轮询下一轮走 register() 发现"设备已解绑"，而不是让这个弹窗卡死用户。
            NSLog("BigDaddy: verifyExitPassword rejected (401): \(error.errorDescription ?? "")")
            markCredentialsInvalid()
        } catch {
            NSLog("BigDaddy: verifyExitPassword request failed: \(error.localizedDescription)")
        }
        return false
    }

    private func ack(commandId: String, status: String, message: String) async {
        let body: [String: Any] = [
            "status": status,
            "message": message,
            "completedAt": ISO8601DateFormatter().string(from: Date())
        ]
        _ = try? await request(path: "/bigdaddy/client/commands/\(commandId)/ack", method: "POST", body: body, signed: true)
    }

    private func request(path: String, method: String, body: [String: Any]?, signed: Bool) async throws -> Data {
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        guard let url = URL(string: baseURL.absoluteString + normalizedPath) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var bodyData = Data()
        if let body {
            bodyData = try JSONSerialization.data(withJSONObject: body)
            request.httpBody = bodyData
        }
        request.setValue(identity.fingerprint, forHTTPHeaderField: "X-Device-Fingerprint")
        if signed {
            let timestamp = String(Int(Date().timeIntervalSince1970))
            let nonce = UUID().uuidString
            let canonical = "\(method)\n\(url.path)\(url.query.map { "?\($0)" } ?? "")\n\(SHA256.hash(data: bodyData).hex)\n\(timestamp)\n\(nonce)"
            let key = SymmetricKey(data: identity.secretHash.data(using: .utf8)!)
            let signature = HMAC<SHA256>.authenticationCode(for: canonical.data(using: .utf8)!, using: key).data.base64URLEncodedString()
            request.setValue(timestamp, forHTTPHeaderField: "X-Device-Timestamp")
            request.setValue(nonce, forHTTPHeaderField: "X-Device-Nonce")
            request.setValue(signature, forHTTPHeaderField: "X-Device-Signature")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let envelope = try? JSONDecoder.bigDaddy.decode(ApiEnvelope.self, from: data)
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0) }
            throw BigDaddyAPIError(
                statusCode: http.statusCode, serverMessage: envelope?.message, retryAfterSeconds: retryAfter)
        }
        return data
    }

    /// 本机浏览器直达的 dashboard 绑定页：带上指纹与当前绑定码，/bind 页会自动预填，
    /// 家长在孩子电脑上登录后直接确认即可，不需要在两台电脑之间来回跑。
    func dashboardBindURL() -> URL {
        var components = URLComponents(
            url: dashboardBaseURL.appendingPathComponent("bind"), resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "fingerprint", value: identity.fingerprint),
            URLQueryItem(name: "token", value: bindToken ?? "")
        ]
        return components.url ?? dashboardBaseURL
    }

    func bindWithCode(_ code: String) async throws -> Bool {
        let body: [String: Any] = [
            "bindCode": code,
            "deviceFingerprint": identity.fingerprint
        ]
        let data = try await request(path: "/bigdaddy/client/bind-with-code", method: "POST", body: body, signed: false)
        // 只按信封里的业务码判定成败，不解析完整 DeviceResponse——那些字段客户端用不到，
        // 而它一旦解析失败会把已在后端提交成功的绑定误报成失败（传输错误由上面的 try 单独抛出）
        guard let envelope = try? JSONDecoder.bigDaddy.decode(ApiEnvelope.self, from: data) else {
            throw BigDaddyServerError(message: Localization.string(
                zh: "服务器响应无法解析，请稍后在仪表盘确认绑定状态",
                en: "Unable to parse server response. Please check binding status on the dashboard."
            ))
        }
        if envelope.code == 200 {
            AuditLog.record("DEVICE_BOUND 本设备已在设备端确认后与家长账户建立守护关系")
            return true
        }
        if !envelope.message.isEmpty {
            throw BigDaddyServerError(message: envelope.message)
        }
        return false
    }

    private static var lockFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BigDaddy/runtime.lock")
    }

    /// 墓碑文件的串行化锁，以及"已退休"标记：进程走到正常结束（或强杀已确认上报）之后，
    /// 任何迟到的心跳都不许再把墓碑写回来——否则进程已经退出、磁盘上却留着一个活墓碑，
    /// 下次启动会凭空补报一次并不存在的异常终止。这不是假想的顺序：sendEventSync 只等
    /// 2.5 秒就返回去删墓碑，超时后那条心跳仍在后台跑着。
    private static let runtimeLockGuard = NSLock()
    private static var runtimeLockRetired = false

    /// 把墓碑刷成"此刻仍然在线"。
    ///
    /// 每次心跳都刷，于是文件里记的是**上次运行最后一次还活着的时刻**，而不是上次运行的
    /// 启动时刻。只在启动时写一次的话，一台连开三天的机器被强杀后，补报上去的
    /// previousCrashAt 会指向三天前——家长端会看到"上次异常终止发生在三天前"，可那三天里
    /// 明明有连续的正常记录，自相矛盾，等于把这个信号变成噪音。
    ///
    /// 除了心跳，AppDelegate 里还有一个独立的 30 秒定时器专门刷它（见 refreshTombstone），
    /// 与心跳节奏解耦：空闲态心跳间隔长达 15 分钟，若只靠心跳刷新，被强杀时"最后确认在线"
    /// 的误差最长可能是 15 分钟；独立定时器把这个误差压到 30 秒左右，代价只是一次几十字节
    /// 的本地文件写入，不发任何网络请求。
    private static func touchRuntimeLock() {
        runtimeLockGuard.lock()
        defer { runtimeLockGuard.unlock() }
        guard !runtimeLockRetired else { return }
        let lock = lockFileURL
        try? FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "\(Date().timeIntervalSince1970)".data(using: .utf8)?.write(to: lock)
    }

    /// 供 AppDelegate 里独立的墓碑刷新定时器调用（每 30 秒一次），把"最后确认在线"的
    /// 误差从心跳间隔（空闲态最长 15 分钟）压到这个定时器自己的周期。是 touchRuntimeLock
    /// 唯一的非 private 入口——心跳节奏之外还需要刷新墓碑的场景只有这一个。
    static func refreshTombstone() {
        touchRuntimeLock()
    }

    /// 移除墓碑，并从此不再刷新它：本次运行已经如实报告过自己的结束（SHUTDOWN，或已确认
    /// 送达的 FORCE_KILL），下次启动不该再补报一次异常终止。
    private static func retireRuntimeLock() {
        runtimeLockGuard.lock()
        defer { runtimeLockGuard.unlock() }
        runtimeLockRetired = true
        try? FileManager.default.removeItem(at: lockFileURL)
    }

    /// Sparkle 装好新版本、即将结束本进程并重启本 App（见 AppDelegate 的
    /// updaterWillRelaunchApplication）。这次终止是我们自己促成的正常重启，退休墓碑，
    /// 免得下次启动被 prepareRuntime() 当成"上次异常终止"补报给家长。
    ///
    /// 只清墓碑、不发心跳：更新重启既不是走验证码的正常退出（SHUTDOWN），也不是被强制
    /// 关闭（FORCE_KILL），套用哪一个都是谎报。
    static func noteUpdateRestart() {
        notePlannedRelaunch()
    }

    /// 计划内重启（Sparkle、连续性模式把进程交给 launchd 托管）退休墓碑，避免下次
    /// 启动被当成异常终止补报。
    static func notePlannedRelaunch() {
        retireRuntimeLock()
    }
}

/// 本机守护记录（知情透明）：把每一次实际发生的采集/上报动作追加到本地明文日志，
/// 孩子和家长都可以在设备上直接查看或导出，用于印证"采集了什么、什么时候采集"。
/// 这是"可导出审计留痕"的落地，不是隐蔽后台行为。
enum AuditLog {
    static var auditFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BigDaddy/guardian-audit.log")
    }

    static func record(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = "\(stamp)\t\(line)\n"
        let url = auditFileURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let data = entry.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try data.write(to: url, options: .atomic)
            }
        } catch {
            NSLog("BigDaddy: audit log write failed: \(error.localizedDescription)")
        }
    }
}

/// 断网容错：心跳/事件发送失败时，把请求体缓存到本地文件（内存中每行一条 JSON），
/// 绝不缓存截图字节。心跳里包含活动窗口标题、浏览器 URL 等隐私字段，落盘前用
/// AES-GCM 加密（见 PendingQueueCrypto），磁盘上不会出现明文。网络恢复后由
/// BigDaddyClient 的 NWPathMonitor 触发补发，重新签名（HMAC 时间戳必须是发送时刻的
/// 新值，不能复用失败时的旧签名）后清空。
enum PendingQueue {
    static var queueFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BigDaddy/pending-heartbeats.jsonl")
    }

    /// 队列的保留窗口：**按时长**而不是按条数裁剪。
    ///
    /// 此前是"最多 200 条，超了丢最老的"。200 条在中度使用下只够 30 多分钟——一次晚饭时间
    /// 的断网就开始静默丢数据，而且丢的是最早那批（最该保留的断网起点）。限速补发把排水
    /// 速度控制住了，但水池太小的话再优雅的排水也没有意义，所以这里必须一起改。
    ///
    /// 24 小时覆盖了"周末外出一天""家里宽带故障一晚"这类真实场景；再长的断网（如寒假旅行）
    /// 补回来的价值已经很低，而且补发本身要占用当下的额度。
    private static let maxAge: TimeInterval = 24 * 60 * 60
    /// 文件体积的硬上限，防止极端高频事件在 24 小时里堆出一个巨大的文件。
    /// 按"1 分钟心跳 + 密集应用切换"估算，正常一天远到不了这个量级。
    private static let maxEntries = 5000

    /// 队列文件的串行化锁：补发循环在后台任务里读写，实时心跳失败时会从别的线程追加，
    /// 两者都是"整份读出→改→整份写回"，不加锁会互相覆盖（丢事件或写出坏行）。
    private static let lock = NSLock()

    static func enqueue(_ body: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let line = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        var lines = prunedLines()
        lines.append(line)
        if lines.count > maxEntries {
            lines.removeFirst(lines.count - maxEntries)
        }
        write(lines)
    }

    /// 当前积压条数。随心跳上报给后端（metadata.pendingQueueDepth），家长端据此显示
    /// "正在补传 N 条"——补发要花几十分钟，没有这个数字的话家长只会看到时间线在自己
    /// 眼前不断长出新内容，读起来像系统不可靠。
    static var depth: Int {
        lock.lock()
        defer { lock.unlock() }
        return prunedLines().count
    }

    /// 读取**最老的** limit 条但不移除。补发成功后由调用方调 removeFirst 摘掉。
    ///
    /// 不用"全取出→失败再塞回"的老写法：那样一旦补发中途失败（限流、网络再断），
    /// 塞回去的顺序和原始顺序就不一致了，而家长端的连续折叠依赖时间有序。
    /// 保持"读→确认成功→再摘除"的顺序，失败时队列原样不动。
    static func peekOldest(limit: Int) -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return prunedLines().prefix(limit).compactMap(decode)
    }

    /// 摘掉队首 count 条（已确认送达的）。
    static func removeFirst(_ count: Int) {
        guard count > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        var lines = prunedLines()
        lines.removeFirst(min(count, lines.count))
        write(lines)
    }

    private static func decode(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    /// 读盘并丢掉超出保留窗口的条目。按 body 里的 reportedAt 判龄——那是事件真正发生的
    /// 时刻，也正是补发上去之后家长在时间线上看到的时刻；用文件写入时间无法区分同一个
    /// 文件里新旧混杂的条目。解析不出 reportedAt 的条目保留（宁可多补一条，不要静默丢）。
    private static func prunedLines() -> [String] {
        let cutoff = Date().addingTimeInterval(-maxAge)
        let formatter = ISO8601DateFormatter()
        return readLines().filter { line in
            guard let obj = decode(line),
                  let stamp = obj["reportedAt"] as? String,
                  let reportedAt = formatter.date(from: stamp) else { return true }
            return reportedAt > cutoff
        }
    }

    /// 先按新的 AES-GCM 加密格式解密；如果失败（多半是磁盘上还留着升级前的旧版本
    /// 明文 JSONL 文件），一次性按明文兼容读取。读到的内容会在下一次 write()（无论是
    /// enqueue 追加新条目，还是 drainAll 清空队列）时按新格式重新落盘，之后就不再
    /// 需要兼容分支。
    private static func readLines() -> [String] {
        guard let data = try? Data(contentsOf: queueFileURL) else { return [] }
        if let text = decrypt(data) {
            return text.split(separator: "\n").map(String.init)
        }
        if let text = String(data: data, encoding: .utf8) {
            NSLog("BigDaddy: pending queue file is legacy plaintext format, will re-encrypt on next write")
            return text.split(separator: "\n").map(String.init)
        }
        return []
    }

    private static func write(_ lines: [String]) {
        let url = queueFileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = lines.joined(separator: "\n")
        guard let sealed = encrypt(text) else { return }
        try? sealed.write(to: url, options: .atomic)
    }

    private static func encrypt(_ text: String) -> Data? {
        guard let plaintext = text.data(using: .utf8) else { return nil }
        let key = PendingQueueCrypto.loadOrCreateKey()
        guard let sealedBox = try? AES.GCM.seal(plaintext, using: key) else { return nil }
        return sealedBox.combined
    }

    private static func decrypt(_ data: Data) -> String? {
        let key = PendingQueueCrypto.loadOrCreateKey()
        guard let sealedBox = try? AES.GCM.SealedBox(combined: data),
              let plaintext = try? AES.GCM.open(sealedBox, using: key) else { return nil }
        return String(data: plaintext, encoding: .utf8)
    }
}

/// 补发队列的加密密钥：与设备身份的 deviceSecret 分开、单独存一份文件，
/// 首次使用时生成一个真正随机的 256-bit 对称密钥并持久化，之后每次启动直接复用同一把
/// 密钥，保证之前落盘的队列文件在下次读取时依然能解密。不走 Keychain：这把密钥只保护
/// 本地暂存、尚未补发的队列数据，不涉及跟后端的身份验签，文件持久化即可。
enum PendingQueueCrypto {
    private static var keyFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BigDaddy/pending-queue-key")
    }

    static func loadOrCreateKey() -> SymmetricKey {
        if let data = try? Data(contentsOf: keyFileURL), data.count == 32 {
            return SymmetricKey(data: data)
        }
        let newKey = SymmetricKey(size: .bits256)
        let data = newKey.withUnsafeBytes { Data($0) }
        try? FileManager.default.createDirectory(
            at: keyFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: keyFileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFileURL.path)
        return newKey
    }
}

/// 开机自动启动的本地开关：默认开启（首次运行未写过值时视为 true），孩子可在客户端
/// 菜单里手动关闭。关闭是敏感操作（会让监控从下次登录起失效），需要家长验证码
/// 才能生效，见 AppDelegate.disableLaunchAtLoginWithVerification；开启则不设防护，
/// 因为开启只会增加监控覆盖面，不构成绕过风险。
enum LaunchAtLoginPreference {
    private static let key = "LaunchAtLoginEnabled"

    static var isEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: key) != nil else { return true }
            return UserDefaults.standard.bool(forKey: key)
        }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// 开机自启的统一入口：macOS 13+ 用官方 SMAppService（能查询 OS 级实际状态、从而
/// 察觉用户在「系统设置 → 登录项」里的手动关闭，且用 bundle 身份、不受 .app 被移动
/// 影响），12.x 回退到手写 LaunchAgent plist。连续性模式打开时改由 ContinuityModeController
/// 托管同一份用户级 LaunchAgent（RunAtLoad + KeepAlive），13+ 会先注销 SMAppService，
/// 避免登录时双启动。全项目对"开机自启"的启停/查询都应经过这里；连续性模式打开期间
/// enable/disable 直接 return，避免把 KeepAlive agent 拆掉。
enum LaunchAtLoginController {
    /// 按 LaunchAtLoginPreference（默认开启）同步 OS 层的自启状态。连续性关闭时由
    /// ContinuityModeController.sync(false) 调用；启动路径也走那一次 sync。
    static func syncWithPreference() {
        if ContinuityModeController.isActive { return }
        if LaunchAtLoginPreference.isEnabled {
            enable()
        } else {
            disable()
        }
    }

    static func enable() {
        if ContinuityModeController.isActive { return }
        if #available(macOS 13.0, *) {
            // 迁移：老版本可能已用手写 plist 装过自启；13+ 改用 SMAppService 后必须把
            // 遗留 plist 删掉，否则登录时两条机制各拉起一次、进程被重复启动。
            // 连续性模式打开时不会走到这里（isActive 已 return），KeepAlive agent 由
            // ContinuityModeController 持有。
            LaunchAgentInstaller.uninstall()
            // .enabled 已经生效、.requiresApproval 已经注册只是在等家长去系统设置批准——
            // 这两种状态下都不用再调 register()。syncWithPreference() 每次启动都会跑
            // 到这里，如果只排除 .enabled，会导致 requiresApproval 期间每次启动都重复
            // 调用 register()（且很可能每次都以"已注册"报错收场，纯粹的日志噪音）。
            let status = SMAppService.mainApp.status
            guard status != .enabled && status != .requiresApproval else { return }
            do {
                try SMAppService.mainApp.register()
                AuditLog.record("LAUNCH_AT_LOGIN_REGISTERED via=SMAppService")
            } catch {
                // 常见于 DEBUG 裸二进制（非 .app bundle）或未签名场景；如实记录、不崩。
                NSLog("BigDaddy: SMAppService register failed: \(error.localizedDescription)")
            }
        } else {
            LaunchAgentInstaller.installIfNeeded(crashRelaunch: false, runAtLoad: true)
        }
    }

    static func disable() {
        if ContinuityModeController.isActive { return }
        if #available(macOS 13.0, *) {
            LaunchAgentInstaller.uninstall() // 遗留 plist 一并清掉，双保险
            // 只有确实处于"已注册"的某种状态（enabled / requiresApproval）时才需要
            // unregister()；notRegistered / notFound 下调用只会换来一次可预期的报错。
            let status = SMAppService.mainApp.status
            guard status == .enabled || status == .requiresApproval else { return }
            do {
                try SMAppService.mainApp.unregister()
                AuditLog.record("LAUNCH_AT_LOGIN_UNREGISTERED via=SMAppService")
            } catch {
                NSLog("BigDaddy: SMAppService unregister failed: \(error.localizedDescription)")
            }
        } else {
            LaunchAgentInstaller.uninstall()
        }
    }

    /// OS 层实际状态字符串，供心跳上报。它与本地偏好 LaunchAtLoginPreference 可能不一致：
    /// 家长端据此能看出"孩子在系统设置里手动关掉了自启"（偏好还是 enabled，但这里变成
    /// notRegistered）这类客户端 App 内开关拦不住的绕过。
    /// 连续性模式打开时 13+ 会注销 SMAppService、改用 LaunchAgent RunAtLoad，所以这里
    /// 先看 agent 的 RunAtLoad，再回退到 SMAppService / 文件是否存在。
    static var osLevelStatusDescription: String {
        if let plist = LaunchAgentInstaller.readInstalled(), LaunchAgentPlist.runAtLoad(from: plist) {
            return Launchctl.isLoaded() ? "enabled" : "plistPresent"
        }
        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled: return "enabled"
            case .requiresApproval: return "requiresApproval"
            case .notRegistered: return "notRegistered"
            case .notFound: return "notFound"
            @unknown default: return "unknown"
            }
        } else {
            return "plistAbsent"
        }
    }
}

/// 用户级 LaunchAgent plist 的纯数据形状，便于单测断言 KeepAlive 结构，不碰磁盘、不调 launchctl。
enum LaunchAgentPlist {
    static let label = "com.bigdaddy.client"
    static let launchedByLaunchdEnvKey = "BIGDADDY_LAUNCHED_BY_LAUNCHD"

    static func make(executablePath: String, runAtLoad: Bool, crashRelaunch: Bool) -> [String: Any] {
        var plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath],
            "RunAtLoad": runAtLoad,
            "EnvironmentVariables": [launchedByLaunchdEnvKey: "1"]
        ]
        if crashRelaunch {
            // exit 0（验证退出、Sparkle 正常结束）不拉起；非 0 / 崩溃 / SIGKILL 拉起。
            plist["KeepAlive"] = ["SuccessfulExit": false]
        } else {
            plist["KeepAlive"] = false
        }
        return plist
    }

    static func parse(_ data: Data) -> [String: Any]? {
        try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    static func data(from plist: [String: Any]) -> Data? {
        try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    static func plistBool(_ value: Any?) -> Bool? {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    static func crashRelaunch(from plist: [String: Any]) -> Bool {
        if let dict = plist["KeepAlive"] as? [String: Any] {
            return plistBool(dict["SuccessfulExit"]) == false
        }
        return false
    }

    static func runAtLoad(from plist: [String: Any]) -> Bool {
        plistBool(plist["RunAtLoad"]) ?? false
    }
}

enum Launchctl {
    static var uid: uid_t { getuid() }
    static var domain: String { "gui/\(uid)" }
    static var serviceTarget: String { "\(domain)/\(LaunchAgentPlist.label)" }

    @discardableResult
    static func run(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return (1, "")
        }
        process.waitUntilExit()
        let combined = out.fileHandleForReading.readDataToEndOfFile()
            + err.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: combined, encoding: .utf8) ?? "")
    }

    static func isLoaded() -> Bool {
        run(["print", serviceTarget]).status == 0
    }

    static func jobPid() -> pid_t? {
        let result = run(["print", serviceTarget])
        guard result.status == 0 else { return nil }
        guard let match = result.output.range(of: #"pid\s*=\s*(\d+)"#, options: .regularExpression) else {
            return nil
        }
        let digits = result.output[match].filter(\.isNumber)
        return pid_t(digits)
    }

    static func bootout() {
        _ = run(["bootout", serviceTarget])
    }

    static func bootstrap(plistURL: URL) -> Bool {
        run(["bootstrap", domain, plistURL.path]).status == 0
    }

    static func kickstart() {
        _ = run(["kickstart", "-k", serviceTarget])
    }
}

/// 用户级 LaunchAgent（不使用特权 daemon / SMJobBless）。macOS 12.x 开机自启、以及
/// 连续性模式的 KeepAlive，都写 `~/Library/LaunchAgents/com.bigdaddy.client.plist`。
/// 对孩子在系统设置的登录项 / LaunchAgents 列表里始终可见。
///
/// KeepAlive 一旦打开，当前会话要生效就必须 `launchctl bootstrap/bootout`：只改 plist
/// 而不加载 job，launchd 不会盯着正在跑的进程。反过来，对本进程自己的 job 做 bootout
/// 会把本进程杀掉，所以 bootout 时机由 ContinuityModeController 决定，uninstall()
/// 只删文件。
enum LaunchAgentInstaller {
    static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.bigdaddy.client.plist")
    }

    static func installIfNeeded(crashRelaunch: Bool = false, runAtLoad: Bool = true) {
        guard let executablePath = Bundle.main.executablePath else { return }
        let plist = LaunchAgentPlist.make(
            executablePath: executablePath,
            runAtLoad: runAtLoad,
            crashRelaunch: crashRelaunch
        )
        let url = launchAgentURL
        if let existingData = try? Data(contentsOf: url),
           let existingPlist = LaunchAgentPlist.parse(existingData),
           (existingPlist as NSDictionary) == (plist as NSDictionary) {
            return
        }
        guard let data = LaunchAgentPlist.data(from: plist) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        AuditLog.record("LAUNCH_AGENT_INSTALLED path=\(executablePath) keepAlive=\(crashRelaunch) runAtLoad=\(runAtLoad)")
    }

    static func readInstalled() -> [String: Any]? {
        guard let data = try? Data(contentsOf: launchAgentURL) else { return nil }
        return LaunchAgentPlist.parse(data)
    }

    static func uninstall() {
        let url = launchAgentURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
        AuditLog.record("LAUNCH_AGENT_UNINSTALLED")
    }
}

/// 孩子用验证码在本机关闭连续性之后为 false。默认 true（不拦截家长配置）。
/// 家长在 Dashboard 把 continuityMode 从关拨到开时会清掉这份覆盖。
enum ContinuityModePreference {
    private static let key = "ContinuityModeLocallyEnabled"
    private static let overrideBaselineKey = "ContinuityModeOverrideBaselineToken"

    static var isEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: key) != nil else { return true }
            return UserDefaults.standard.bool(forKey: key)
        }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// 本地覆盖生效那一刻，服务端 config.continuityModeUpdatedAt 的快照（存原始字符串，
    /// 理由见 ClientConfig.continuityModeUpdatedAt）。refreshConfig() 拿它跟服务端最新值
    /// 做**等值**比较，判断"家长是否在本地覆盖之后又重新动过这个开关"，不再要求恰好
    /// 观察到一次 false→true 边沿（旧办法在轮询节奏不巧漏过中间的 false 时，覆盖永远
    /// 清不掉）。isEnabled 变回 true 时必须同步清掉，避免下次覆盖复用一份过期快照。
    static var overrideBaseline: String? {
        get { UserDefaults.standard.object(forKey: overrideBaselineKey) as? String }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: overrideBaselineKey)
            } else {
                UserDefaults.standard.removeObject(forKey: overrideBaselineKey)
            }
        }
    }
}

/// 连续性模式：家长打开后，用用户级 LaunchAgent 的 KeepAlive `{ SuccessfulExit: false }`
/// 在崩溃 / 强制退出后拉起客户端。SMAppService.mainApp 是登录项，崩了不会拉，所以
/// 13+ 打开连续性时注销登录项、改由 launchd 托管。不隐藏第二份 .app，删除应用后
/// launchd 拉不起来——那是产品限制，不是没做完的恢复。
enum ContinuityModeController {
    /// 最近一次 sync 的目标状态。LaunchAtLoginController 用它避免拆掉 KeepAlive agent。
    private(set) static var isActive = false

    /// refreshConfig() 里"要不要清掉孩子用验证码打下的本地覆盖"这个判断，抽成纯函数
    /// 单独测试——调用方已经用 `!ContinuityModePreference.isEnabled` 保证只在覆盖确实
    /// 生效时才调用这里，这个前提不在函数内部重复判断。
    ///
    /// 两种信号任一命中都清：
    /// 1) 边沿：这次轮询看到 continuityMode 从 false 变 true。轮询节奏凑巧时才会
    ///    观察到，但胜在不依赖后端有没有下发时间戳，旧后端也能用。
    /// 2) 时间戳变了：remoteUpdatedAt 跟创建覆盖那一刻记下的 overrideBaseline **不相等**，
    ///    说明家长确实在覆盖生效之后又重新动过这个开关——不管中间有没有一次轮询真的
    ///    落在"已经变回 false"的那一拍。这是给 1) 补的洞：家长把开关关了又立刻打开，
    ///    两次保存之间如果没轮询到，光看边沿会永远漏判，覆盖清不掉。
    ///
    /// 用等值而不是先后比较，是因为要回答的问题本来就是"这个值变了没有"。先后比较需要
    /// 把不带时区的 LocalDateTime 解析成绝对时刻，夏令时切换会让一个从没变过的时间戳
    /// 凭空显得更新（详见 ClientConfig.continuityModeUpdatedAt 的说明）。
    ///
    /// nil 的两种含义都能正确落地：
    /// - 两边都 nil（旧后端从不下发）→ 相等 → 只剩边沿判断，行为退回改动前，不会更差。
    /// - baseline 为 nil、remote 有值 → 不等 → 清。这正是**老部署**的主场景：升级前就
    ///   已经打开连续性的设备，新列是 NULL，孩子建立覆盖时快照只能是 nil；此后家长任何
    ///   一次真正的开关翻转都会写出时间戳，从 nil 变成有值本身就是"家长动过"的证据。
    static func shouldClearOverride(
        remoteContinuityMode: Bool,
        previousContinuityMode: Bool,
        remoteUpdatedAt: String?,
        overrideBaseline: String?
    ) -> Bool {
        guard remoteContinuityMode else { return false }
        let sawEdge = !previousContinuityMode
        let tokenChanged = remoteUpdatedAt != overrideBaseline
        return sawEdge || tokenChanged
    }

    static var isLaunchdManaged: Bool {
        if ProcessInfo.processInfo.environment[LaunchAgentPlist.launchedByLaunchdEnvKey] == "1" {
            return true
        }
        return Launchctl.jobPid() == ProcessInfo.processInfo.processIdentifier
    }

    /// "本进程主动拉起一份继任者、然后自己退出"这套交接，有两个调用点：
    /// disableKeepAlive()（关闭连续性时从 launchd 手里接管）和 AppDelegate.restartApplication()
    /// （非 launchd 托管时的重启）。两者都先 spawn 再让自己死，于是继任者启动那一刻旧进程
    /// 通常还活着。没有这个标记时，shouldExitAsDuplicate() 会把继任者当成"非 launchd 的
    /// 后来者"——检测到"已有实例在跑"就直接把自己也退出，跟随后死掉的旧进程一起两个全灭
    /// （用户看到的"点关闭崩溃后自动恢复，整个 App 退出了"）。带上标记后，
    /// shouldExitAsDuplicate() 对它按 isLaunchdManaged 同等处理：等旧实例真正退出，而不是自杀。
    private static let handoverSuccessorEnvKey = "BIGDADDY_HANDOVER_SUCCESSOR"

    private static var isHandoverSuccessor: Bool {
        ProcessInfo.processInfo.environment[handoverSuccessorEnvKey] == "1"
    }

    /// 交接用继任进程的环境：摘掉 launchd 注入的标记（继任者本就不归 launchd 管），
    /// 打上交接标记。两个 spawn 点共用，避免其中一个漏标又退化成"两个全灭"。
    static func successorEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: LaunchAgentPlist.launchedByLaunchdEnvKey)
        env[handoverSuccessorEnvKey] = "1"
        return env
    }

    static var osLevelStatusDescription: String {
        guard let plist = LaunchAgentInstaller.readInstalled(),
              LaunchAgentPlist.crashRelaunch(from: plist) else {
            return "off"
        }
        guard Launchctl.isLoaded() else { return "keepAlivePlistNotLoaded" }
        return isLaunchdManaged ? "keepAliveLoaded" : "keepAliveLoadedUnmanaged"
    }

    static func sync(enabled: Bool) {
        if enabled {
            enableKeepAlive()
        } else {
            disableKeepAlive()
        }
    }

    /// 验证退出 / Sparkle：先安排延迟 bootout，再让本进程把 SHUTDOWN / 更新收尾做完。
    /// 对本进程自己的 job 立刻 bootout 会直接杀掉还在跑的退出流程。
    /// SuccessfulExit=false 下 exit 0 本身不会被立刻拉起；延迟 bootout 是卸掉本会话的 job。
    static func prepareForPlannedExit() {
        let keepAlive = LaunchAgentInstaller.readInstalled().map { LaunchAgentPlist.crashRelaunch(from: $0) } ?? false
        guard isActive || keepAlive else { return }
        scheduleDelayedBootout()
        AuditLog.record("CONTINUITY_KEEPALIVE_BOOTED_OUT reason=planned-exit")
    }

    /// 屏幕录制授权后的重启：已经在 launchd 手里时 kickstart -k，不要再 Process() 拉一份。
    static func restartViaLaunchdIfManaged() -> Bool {
        guard isLaunchdManaged, Launchctl.isLoaded() else { return false }
        AuditLog.record("CONTINUITY_KEEPALIVE_KICKSTART")
        Launchctl.kickstart()
        return true
    }

    /// 启动最开头调用：已有实例时，非 launchd 的后来者直接退出；launchd 拉起的新实例，
    /// 或者本进程主动交接出来的继任者（successorEnvironment 打的标记，来自
    /// disableKeepAlive() 与 restartApplication()），等旧实例把进程交出来再接管。
    static func shouldExitAsDuplicate() -> Bool {
        guard let bundleId = Bundle.main.bundleIdentifier else { return false }
        let own = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .filter { $0.processIdentifier != own }
        guard !others.isEmpty else { return false }
        if isLaunchdManaged || isHandoverSuccessor {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                let remaining = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
                    .filter { $0.processIdentifier != own }
                if remaining.isEmpty { return false }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        return true
    }

    private static func enableKeepAlive() {
        // launchd 必须在加载 job 时把进程拉起来，KeepAlive 才能盯着。连续性打开期间
        // 因此强制 RunAtLoad：否则 bootstrap 后交接 exit(0)，job 停着没人拉，守护直接没了。
        LaunchAgentInstaller.installIfNeeded(crashRelaunch: true, runAtLoad: true)
        unregisterLoginItemIfNeeded()
        isActive = true

        let keepAliveInstalled = LaunchAgentInstaller.readInstalled().map { LaunchAgentPlist.crashRelaunch(from: $0) } ?? false
        let launchedWithKeepAliveEnv = ProcessInfo.processInfo.environment[LaunchAgentPlist.launchedByLaunchdEnvKey] == "1"
        // 磁盘上已是 KeepAlive plist 还不够：12.x 登录进来的旧 job 定义可能仍是 KeepAlive=false，
        // 必须看到 launchd 注入的环境变量，才说明当前这份进程真的被 KeepAlive 盯着。
        if isLaunchdManaged && Launchctl.isLoaded() && keepAliveInstalled && launchedWithKeepAliveEnv {
            return
        }

        if Launchctl.isLoaded() && isLaunchdManaged {
            AuditLog.record("CONTINUITY_MODE_ENABLED via=reload-job")
            scheduleReloadAfterExit()
            handoverExit()
            return
        }

        if Launchctl.isLoaded() {
            if Launchctl.jobPid() == nil {
                _ = Launchctl.run(["kickstart", Launchctl.serviceTarget])
                AuditLog.record("CONTINUITY_MODE_ENABLED via=kickstart-idle")
                if !isLaunchdManaged {
                    handoverExit()
                }
                return
            }
            Launchctl.bootout()
        }
        let bootstrapped = Launchctl.bootstrap(plistURL: LaunchAgentInstaller.launchAgentURL)
        AuditLog.record("CONTINUITY_MODE_ENABLED via=bootstrap success=\(bootstrapped)")
        if bootstrapped && !isLaunchdManaged {
            handoverExit()
        }
    }

    private static func disableKeepAlive() {
        let hadKeepAlive = LaunchAgentInstaller.readInstalled().map { LaunchAgentPlist.crashRelaunch(from: $0) } ?? false
        isActive = false
        guard hadKeepAlive else {
            LaunchAtLoginController.syncWithPreference()
            return
        }
        AuditLog.record("CONTINUITY_MODE_DISABLED")
        if isLaunchdManaged && Launchctl.isLoaded() {
            restorePlistForLaunchAtLoginWithoutKeepAlive()
            spawnUnmanagedSuccessor()
            Launchctl.bootout()
            return
        }
        Launchctl.bootout()
        restorePlistForLaunchAtLoginWithoutKeepAlive()
        LaunchAtLoginController.syncWithPreference()
    }

    private static func restorePlistForLaunchAtLoginWithoutKeepAlive() {
        if #available(macOS 13.0, *) {
            LaunchAgentInstaller.uninstall()
        } else {
            LaunchAgentInstaller.installIfNeeded(
                crashRelaunch: false,
                runAtLoad: LaunchAtLoginPreference.isEnabled
            )
        }
    }

    private static func unregisterLoginItemIfNeeded() {
        if #available(macOS 13.0, *) {
            let status = SMAppService.mainApp.status
            guard status == .enabled || status == .requiresApproval else { return }
            do {
                try SMAppService.mainApp.unregister()
                AuditLog.record("LAUNCH_AT_LOGIN_UNREGISTERED via=SMAppService reason=continuity")
            } catch {
                NSLog("BigDaddy: SMAppService unregister for continuity failed: \(error.localizedDescription)")
            }
        }
    }

    private static func handoverExit() {
        AuditLog.record("CONTINUITY_HANDOVER_TO_LAUNCHD")
        BigDaddyClient.notePlannedRelaunch()
        exit(0)
    }

    private static func spawnUnmanagedSuccessor() {
        guard let executablePath = Bundle.main.executablePath else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.environment = successorEnvironment()
        try? process.run()
        Thread.sleep(forTimeInterval: 0.4)
    }

    private static func scheduleReloadAfterExit() {
        let plistPath = LaunchAgentInstaller.launchAgentURL.path
        let script = """
        sleep 0.5
        /bin/launchctl bootout \(Launchctl.serviceTarget)
        /bin/launchctl bootstrap \(Launchctl.domain) '\(plistPath)'
        """
        spawnDetachedShell(script)
    }

    private static func scheduleDelayedBootout() {
        spawnDetachedShell("""
        sleep 1
        /bin/launchctl bootout \(Launchctl.serviceTarget)
        """)
    }

    private static func spawnDetachedShell(_ script: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}

enum ConfigStore {
    static var configFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BigDaddy/config.json")
    }

    static func load() -> ClientConfig? {
        guard let data = try? Data(contentsOf: configFileURL) else { return nil }
        return try? JSONDecoder.bigDaddy.decode(ClientConfig.self, from: data)
    }

    static func save(_ config: ClientConfig) {
        do {
            try FileManager.default.createDirectory(at: configFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder.bigDaddy
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: configFileURL, options: .atomic)
        } catch {
            NSLog("BigDaddy failed to save config: \(error.localizedDescription)")
        }
    }
}

struct ApiResponse<T: Codable>: Codable {
    let code: Int
    let message: String
    let data: T
}

/// 只含业务码和消息的响应信封：错误响应的 data 为 null，无法按 ApiResponse<T> 解析
struct ApiEnvelope: Codable {
    let code: Int
    let message: String
}

/// HTTP 状态码非 2xx 时 request() 抛出的错误：区分"服务器明确拒绝"和"网络传输失败"，
/// 前者（尤其 401）不该被调用方当成可重试的临时故障静默吞掉。
struct BigDaddyAPIError: LocalizedError {
    let statusCode: Int
    let serverMessage: String?
    /// 服务端 Retry-After 响应头（秒）。限流过滤器在 429 时会带上它，补发循环据此
    /// 自适应节奏，而不是靠客户端写死的常量猜服务端还剩多少额度。
    let retryAfterSeconds: Int?

    init(statusCode: Int, serverMessage: String?, retryAfterSeconds: Int? = nil) {
        self.statusCode = statusCode
        self.serverMessage = serverMessage
        self.retryAfterSeconds = retryAfterSeconds
    }

    var errorDescription: String? { serverMessage ?? "HTTP \(statusCode)" }
    /// 签名接口返回 401 只可能是 BigDaddyDeviceAuthService 里的认证失败
    /// （设备未注册/无 secret/签名不对/时间戳超窗），语义上等价于 register() 报告的
    /// credentialsValid=false，都意味着本机手上的凭据当下用不了。
    var isAuthFailure: Bool { statusCode == 401 }
    /// 被限流。与网络故障的处理必须分开：事件照样要进补发队列（不能丢），但重试节奏
    /// 得听服务端的，而且不该像网络恢复那样立刻重试。
    var isRateLimited: Bool { statusCode == 429 }
}

/// 携带后端 message 的业务错误，让弹窗能直接展示真实原因而不是笼统的"绑定码无效"
struct BigDaddyServerError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct DeviceResponse: Codable {
    let deviceFingerprint: String
    let deviceName: String?
    let status: String
    let latestEvent: String?
    let appVersion: String?
    let lastHeartbeatAt: Date?
    let lastScreenshotAt: Date?
    let boundAt: Date?
    let bindToken: String?
    let credentialsValid: Bool?
    let bound: Bool?
}

struct Command: Codable {
    let commandId: String
    let type: String
}

struct HeartbeatResponse: Codable {
    let configVersion: Int?
    let configChanged: Bool?
    let hasPendingCommand: Bool?
}

struct ScreenshotUploadResponse: Codable {
    let delivered: Bool?
    let emailStatus: String?
    let telegramStatus: String?
    let reason: String?
}

enum IdentityStore {
    static func load() -> DeviceIdentity {
        print("BigDaddy: IdentityStore.load started")
        // 不再依赖 Keychain 持久化：开发构建每次 swift build / Xcode 运行的代码签名都不同，
        // 读不到上一个构建创建的 Keychain 条目会静默重造 secret；设备一旦绑定，重造即永久
        // 验签失败（后端拒绝已绑定设备换钥）。改用 Application Support 下 0600 权限的文件
        // 持久化，跨构建、跨签名都稳定。
        let secret: String
        if let fromFile = fileSecret() {
            secret = fromFile
        } else {
            secret = generateSecret()
            saveFileSecret(secret)
        }
        print("BigDaddy: deviceSecret ready")
        let platform = IOPlatformUUID.read() ?? Host.current().localizedName ?? "BigDaddyMac"
        print("BigDaddy: platform UUID read complete")
        let fingerprint = SHA256.hash(data: platform.data(using: .utf8)!).hex
        let secretHash = SHA256.hash(data: secret.data(using: .utf8)!).hex
        print("BigDaddy: IdentityStore.load completed, fingerprint: \(fingerprint)")
        return DeviceIdentity(fingerprint: fingerprint, secretHash: secretHash)
    }

    /// 生成密码学安全的 32 字节随机 deviceSecret（用 SecRandomCopyBytes，而不是拼接
    /// 两个 UUID 字符串这种可预测格式），十六进制编码后作为 String 存入文件，
    /// 与现有消费方（SHA256 取 secretHash、HMAC 签名）完全兼容，无需改动下游逻辑。
    private static func generateSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            // 极罕见的降级路径：系统随机数生成失败时退回旧格式，保证指纹生成流程
            // 不会因此崩溃或阻塞设备绑定。
            return UUID().uuidString + UUID().uuidString
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static var secretFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BigDaddy/device-secret")
    }

    private static func fileSecret() -> String? {
        guard let raw = try? String(contentsOf: secretFileURL, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func saveFileSecret(_ secret: String) {
        try? FileManager.default.createDirectory(
            at: secretFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? secret.data(using: .utf8)?.write(to: secretFileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secretFileURL.path)
    }
}

enum IOPlatformUUID {
    static func read() -> String? {
        print("BigDaddy: IOPlatformUUID.read started")
        let task = Process()
        task.launchPath = "/usr/sbin/ioreg"
        task.arguments = ["-rd1", "-c", "IOPlatformExpertDevice"]
        let pipe = Pipe()
        task.standardOutput = pipe
        do {
            try task.run()
            print("BigDaddy: ioreg task launched successfully")
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            let uuid = output.split(separator: "\n").first { $0.contains("IOPlatformUUID") }?
                .split(separator: "\"").dropFirst(3).first.map(String.init)
            print("BigDaddy: ioreg task read completed, uuid is nil: \(uuid == nil)")
            return uuid
        } catch {
            print("BigDaddy Error: Failed to run ioreg task: \(error.localizedDescription)")
            return nil
        }
    }
}

extension JSONDecoder {
    /// 后端 Jackson 序列化 LocalDateTime 输出 "2026-07-16T23:01:02.123456"——无时区、带小数秒，
    /// 而 Foundation 的 .iso8601 策略要求带时区、不带小数秒，解析必然失败。曾导致 bind-with-code
    /// 的成功响应（boundAt 非空）解析失败被吞掉，误报"绑定失败"。这里两类格式都接受。
    static var bigDaddy: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = BigDaddyDateParser.parse(raw) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognized date: \(raw)")
        }
        return decoder
    }
}

extension JSONEncoder {
    /// 与 JSONDecoder.bigDaddy 配对，给 ConfigStore 把 ClientConfig 存盘再读回来用。
    ///
    /// 这是**预防性**的：ClientConfig 目前一个 Date 字段都没有（continuityModeUpdatedAt
    /// 存的是后端原文字符串），所以换不换编码器眼下没有任何行为差别。留着是因为
    /// save() 和 load() 之间存在一处很容易踩、且踩了没有任何报错的不对称——普通
    /// JSONEncoder() 默认把 Date 编成距 2001 参考日的秒数（Double），而
    /// JSONDecoder.bigDaddy 的自定义策略无条件按字符串解析。将来只要有人往
    /// ClientConfig 里加一个 Date 字段，存盘再读回来就会在那个字段上解码失败，
    /// 而 load() 是 `try?`，失败的后果不是这一个字段丢了，是**整份本地配置**
    /// 静默退回默认值。这里让编码端输出 BigDaddyDateParser 认得的 ISO 8601 字符串，
    /// 把这个陷阱一次性堵死。
    static var bigDaddy: JSONEncoder {
        let encoder = JSONEncoder()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }
}

enum BigDaddyDateParser {
    private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let iso8601 = ISO8601DateFormatter()
    /// LocalDateTime 不携带时区，按本机时区解释
    private static let localDateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    static func parse(_ raw: String) -> Date? {
        if let date = iso8601Fractional.date(from: raw) ?? iso8601.date(from: raw) {
            return date
        }
        // Jackson LocalDateTime 的小数秒位数不定（0–9 位），截掉后按秒级精度解析
        let withoutFraction = raw.split(separator: ".").first.map(String.init) ?? raw
        return localDateTime.date(from: withoutFraction)
    }
}

extension SHA256.Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

extension HMAC<SHA256>.MAC {
    var data: Data { Data(self) }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    mutating func appendMultipartField(name: String, value: String, boundary: String) {
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
    }
}
