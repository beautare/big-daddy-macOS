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
}

struct DeviceIdentity {
    let fingerprint: String
    let secretHash: String
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
    /// 实时生成一次性验证码（见 verifyExitPassword），这里只用于 UI 展示"是否需要验证退出"。
    var hasExitPassword: Bool = false
    var heartbeatActiveSeconds: Int = 60
    var heartbeatIdleSeconds: Int = 900
    var idleThresholdSeconds: Int = 180
    var hasPendingCommand: Bool = false

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

final class BigDaddyClient {
    static var lastSharedInstance: BigDaddyClient?

    let baseURL = URL(string: Bundle.main.object(forInfoDictionaryKey: "BigDaddyAPIBaseURL") as? String ?? "http://localhost:8009/api/v1")!
    /// 家长仪表盘地址：正式 .app 由打包脚本写入 Info.plist（BigDaddyDashboardBaseURL），
    /// 裸二进制（swift run / Xcode 直接运行）退回本地 dashboard 开发端口。
    let dashboardBaseURL = URL(string: Bundle.main.object(forInfoDictionaryKey: "BigDaddyDashboardBaseURL") as? String ?? "http://localhost:4000")!
    let identity: DeviceIdentity
    var config: ClientConfig
    var lastHeartbeatDescription = "not sent"
    var bindToken: String?
    /// register 响应报告本机 secret 与后端存档不一致（设备已绑定、后端拒绝换钥）。
    /// 此状态下所有签名接口都会验签失败，必须在 UI 上明确警示，引导解绑后重新绑定。
    var credentialsInvalid = false
    private var previousCrashAt: Date?
    private let switchCounter = SwitchCounter()
    private var switchObserver: NSObjectProtocol?
    /// 切换 App 后"即时上报"的防抖任务：把快速连切合并成一次发送
    private var switchHeartbeatWork: DispatchWorkItem?

    init() {
        self.identity = IdentityStore.load()
        self.config = ConfigStore.load() ?? ClientConfig()
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

    var isIdle: Bool {
        // 之前只看 .mouseMoved，只打字不动鼠标会被误判为空闲。改用 kCGAnyInputEventType
        // （rawValue ~0，即 CGEventSourceSecondsSinceLastInputEvent 的语义）覆盖键盘/
        // 鼠标/触控板等全部输入类型。
        let anyInputEventType = CGEventType(rawValue: ~UInt32(0))!
        let idleSeconds = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInputEventType)
        return idleSeconds > Double(config.idleThresholdSeconds)
    }

    func prepareRuntime() {
        let lock = Self.lockFileURL
        if let data = try? Data(contentsOf: lock), let value = String(data: data, encoding: .utf8), let timestamp = TimeInterval(value) {
            previousCrashAt = Date(timeIntervalSince1970: timestamp)
        }
        try? FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "\(Date().timeIntervalSince1970)".data(using: .utf8)?.write(to: lock)
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

    /// 非破坏性读取：调用方据此判断"上次是否异常终止"，不清空状态。
    /// 清空由 clearPreviousCrash() 单独负责，必须在 previousCrashAt 已经通过
    /// sendHeartbeat 上报给后端之后才调用——此前的实现把"读取"和"清空"合并成一步，
    /// 导致上报心跳时 previousCrashAt 已经被清空，后端永远收不到崩溃时间戳。
    var detectedPreviousCrash: Date? { previousCrashAt }

    func clearPreviousCrash() {
        previousCrashAt = nil
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
            // register 不走设备签名，是验签通道失效时唯一可靠的绑定状态来源。只向
            // "未绑定"方向修正：后端说已解绑就立即翻转本地状态（旧后端无 bound 字段时
            // 退回用 boundAt 判断）；反向的"已绑定"要携带完整守护策略，交给签名的
            // refreshConfig 拉取权威配置，这里不能凭空置 true。
            let remoteBound = response.data.bound ?? (response.data.boundAt != nil)
            if config.bound && !remoteBound {
                config.bound = false
                config.hasPendingCommand = false
                ConfigStore.save(config)
            }
        }
    }

    @discardableResult
    func refreshConfig() async -> Bool {
        let data: Data
        do {
            data = try await request(path: "/bigdaddy/client/config", method: "GET", body: nil, signed: true)
        } catch let error as BigDaddyAPIError where error.isAuthFailure {
            markCredentialsInvalid()
            return false
        } catch {
            return false
        }
        guard let response = try? JSONDecoder.bigDaddy.decode(ApiResponse<ClientConfig>.self, from: data) else { return false }
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
        return config != previous
    }

    /// 记录最近一次截图时间，随心跟上报
    private var lastScreenshotAt: Date?

    // 客户端不再计算 appType：后端 AI 日报按 activeAppName 用自己更全的词表重新分类
    // （见 BigDaddyService.classifyAppCategory），客户端这份既没人消费、词表又窄，已移除。

    /// 发送心跳。返回是否成功送达后端，供强杀/退出等需要"确认上报后才清理本地状态"的调用方判断。
    @discardableResult
    func sendHeartbeat(event: EventType) async -> Bool {
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

        var body: [String: Any] = [
            "appVersion": version,
            "eventType": event.rawValue,
            "lastHeartbeatAt": ISO8601DateFormatter().string(from: Date()),
            "activeAppName": activeApp,
            "activeWindowTitle": windowTitle,
            "activeUrl": activeUrl,
            "switchCount": switchCount,
            "previousCrashAt": previousCrashAt.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
            "reportedAt": ISO8601DateFormatter().string(from: Date()),
            "metadata": [
                "screenRecordingGranted": hasScreenRecordingAccess(),
                "accessibilityGranted": AXIsProcessTrustedWithOptions(nil),
                // 开机自动启动的当前状态位：与权限位一样每次心跳都上报，家长端因此始终
                // 能在服务端看到本机是否仍会开机自启，不必依赖"关闭那一刻"的单次事件
                // 能否送达（那次事件可能因断网落进 PendingQueue 延迟补发）。
                // launchAtLoginEnabled 是本机"意图"（客户端偏好），launchAtLoginOsStatus 是
                // OS 层"实际"状态：两者不一致（如 enabled + notRegistered）即意味着有人在
                // 系统设置的登录项里手动关掉了自启——这是 App 内验证码开关拦不住的绕过，
                // 家长端应据此告警。
                "launchAtLoginEnabled": LaunchAtLoginPreference.isEnabled,
                "launchAtLoginOsStatus": LaunchAtLoginController.osLevelStatusDescription
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
            return true
        } catch let error as BigDaddyAPIError where error.isAuthFailure {
            // 服务器明确拒绝（设备已不存在/签名过不了），不是网络抖动，
            // 重试也不会成功——不进补发队列，改走 credentialsInvalid 恢复路径。
            NSLog("BigDaddy: heartbeat rejected (401): \(error.errorDescription ?? "")")
            markCredentialsInvalid()
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
    func startNetworkMonitoring() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = path.status == .satisfied
            if satisfied && !self.lastPathSatisfied {
                Task { await self.flushPendingQueue() }
            }
            self.lastPathSatisfied = satisfied
        }
        monitor.start(queue: DispatchQueue(label: "com.bigdaddy.pathmonitor"))
        pathMonitor = monitor
    }

    /// 补发断网期间积压的心跳；单条失败则重新入队，等待下一次网络恢复。
    func flushPendingQueue() async {
        let pending = PendingQueue.drainAll()
        guard !pending.isEmpty else { return }
        NSLog("BigDaddy: network recovered, flushing \(pending.count) queued heartbeat(s)")
        for body in pending {
            do {
                _ = try await request(path: "/bigdaddy/client/heartbeat", method: "POST", body: body, signed: true)
            } catch {
                PendingQueue.enqueue(body)
            }
        }
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
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await self.sendHeartbeat(event: .shutdown)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
        try? FileManager.default.removeItem(at: Self.lockFileURL)
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
                try? FileManager.default.removeItem(at: lockFileURL)
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

    // Chromium 系浏览器共用同一套 AppleScript 方言（active tab of first window），
    // 按应用名匹配即可复用；Safari 用 current tab；Firefox 无 AppleScript URL 接口，返回空
    // 由窗口标题兜底。注意：AppleScript 自动化是按目标应用逐个授权的 TCC 权限，且需要
    // Info.plist 里的 NSAppleEventsUsageDescription 才能弹出授权（打包版），否则静默失败。
    //
    // 顺序很重要：用 contains 做子串匹配时必须"长的排前面"，否则 "Google Chrome" 会
    // 抢先命中 "Google Chrome Canary"，导致对错误的应用发 AppleScript。
    private static let chromiumBrowserNames = [
        "Google Chrome Canary", "Google Chrome", "Chromium",
        "Microsoft Edge", "Brave Browser", "Vivaldi", "Opera"
    ]

    /// 标题和 URL 在同一个 AppleScript 往返里一起拿，中间用这个几乎不可能出现在真实
    /// 标题/URL 里的不可见字符拼接，回来后再拆开——避免对同一个浏览器发两次独立的
    /// Apple Event（各自都是一次完整的 tell-application 往返）。
    private static let browserFieldSeparator = "\u{2063}"

    /// 生成向指定浏览器一次性查询"当前标签页标题 + URL"的 AppleScript，非受支持的
    /// 浏览器返回 nil。属性名在不同浏览器里不同：Chromium 系是 `title`/`URL` of
    /// active tab，Safari 是 `name`/`URL` of current tab。
    private func browserTabCombinedScript(appName: String) -> String? {
        let sep = BigDaddyClient.browserFieldSeparator
        if let chromium = BigDaddyClient.chromiumBrowserNames.first(where: { appName.contains($0) }) {
            return """
            tell application "\(chromium)"
                if (count of windows) > 0 then
                    return (title of active tab of first window) & "\(sep)" & (URL of active tab of first window)
                end if
            end tell
            return ""
            """
        } else if appName == "Arc" {
            // "Arc" 是常见英文词/前缀（"Archive Utility""Arcade"等系统应用都包含它），
            // 子串匹配风险过高，单独用精确相等判断，不并入上面的 contains 名单。
            return """
            tell application "Arc"
                if (count of windows) > 0 then
                    return (title of active tab of first window) & "\(sep)" & (URL of active tab of first window)
                end if
            end tell
            return ""
            """
        } else if appName.contains("Safari") {
            return """
            tell application "Safari"
                if (count of windows) > 0 then
                    return (name of current tab of first window) & "\(sep)" & (URL of current tab of first window)
                end if
            end tell
            return ""
            """
        }
        // Firefox 等无脚本接口的浏览器：拿不到，交由窗口标题兜底
        return nil
    }

    private func runAppleScript(_ source: String) -> String {
        if let script = NSAppleScript(source: source) {
            var error: NSDictionary?
            let result = script.executeAndReturnError(&error)
            if error == nil {
                return result.stringValue ?? ""
            }
        }
        return ""
    }

    /// 浏览器场景下的标题 + URL，一次 AppleScript 往返拿全；非浏览器或脚本失败返回 nil，
    /// 交由调用方回退到 CGWindowList/Accessibility（那两条路只有标题，没有 URL）。
    private func browserTabInfo(appName: String) -> (title: String, url: String)? {
        guard let script = browserTabCombinedScript(appName: appName) else { return nil }
        let raw = runAppleScript(script)
        guard !raw.isEmpty else { return nil }
        let parts = raw.components(separatedBy: BigDaddyClient.browserFieldSeparator)
        guard parts.count == 2 else { return nil }
        return (title: parts[0], url: parts[1])
    }

    /// 一次心跳/截图需要的"活动窗口标题 + 浏览器 URL"。浏览器优先走上面的合并 AppleScript
    /// 查询：下面的 CGWindowList(kCGWindowName) 与 Accessibility 两条路都需要屏幕录制或
    /// 辅助功能授权，dev 构建签名不稳定时经常两者都拿不到，导致标题恒为空；而 AppleScript
    /// 自动化是另一套按目标应用逐个授权的 TCC 权限，用它能在缺屏幕录制权限时仍抓到主流
    /// 浏览器的当前页面标题（顺带把 URL 也拿到，不需要再发一次 Apple Event）。
    func activeWindowInfo() -> (title: String, url: String) {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return ("", "") }
        let appName = frontApp.localizedName ?? ""
        if let info = browserTabInfo(appName: appName) {
            return info
        }

        let pid = frontApp.processIdentifier
        // 非浏览器 / AppleScript 失败：首选 CGWindowList 的 kCGWindowName，但该字段自
        // macOS 10.15 起仅对持有屏幕录制权限的进程返回，未授权时恒为空——此时回落到
        // Accessibility API。这两条路都没有 URL。
        let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
        if let windowListInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] {
            for info in windowListInfo {
                if let windowOwnerPID = info[kCGWindowOwnerPID as String] as? Int, windowOwnerPID == pid,
                   let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                   let title = info[kCGWindowName as String] as? String, !title.isEmpty {
                    return (title, "")
                }
            }
        }
        return (accessibilityWindowTitle(pid: pid), "")
    }

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
            throw BigDaddyAPIError(statusCode: http.statusCode, serverMessage: envelope?.message)
        }
        return data
    }

    /// 截图实际发生时广播，供 UI 层给孩子端即时可见提示
    static let screenshotSentNotification = Notification.Name("BigDaddyScreenshotSent")
    /// 自动路径（定时/家长下发命令）因缺屏幕录制权限而静默放弃截图时广播。手动测试
    /// （关于面板里点"测试截图"）不广播这个——用户当时就看着"关于"面板，⚠️ 按钮本身
    /// 已经是最直接的提示，不需要再额外弹一条本机通知重复同一件事。
    static let screenshotMissingPermissionNotification = Notification.Name("BigDaddyScreenshotMissingPermission")

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
        guard config.bound else { return }
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
        // 执行"即时截图"前先同步一次最新配置：家长的典型操作就是"在仪表盘改完压缩质量/
        // 截图宽度，立刻点测试截图看效果"。若不在这里刷新，这次截图会用客户端手上（最长
        // 可能落后 60 秒配置轮询）的旧配置，家长对比时就会觉得"改了质量没区别/压缩没生效"。
        if !screenshotCommands.isEmpty {
            _ = await refreshConfig()
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
    }

    func verifyExitPassword(_ value: String) async -> Bool {
        // 未绑定设备没有家长账户可以生成退出验证码，允许直接退出。
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
            throw BigDaddyAPIError(statusCode: http.statusCode, serverMessage: envelope?.message)
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
    /// 上限保护，避免长期离线导致队列文件无限增长
    private static let maxEntries = 200

    static func enqueue(_ body: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let line = String(data: data, encoding: .utf8) else { return }
        var lines = readLines()
        lines.append(line)
        if lines.count > maxEntries {
            lines.removeFirst(lines.count - maxEntries)
        }
        write(lines)
    }

    /// 取出全部积压条目并清空队列文件；补发失败的条目由调用方重新 enqueue。
    static func drainAll() -> [[String: Any]] {
        let lines = readLines()
        write([])
        return lines.compactMap { line in
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return obj
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
/// 影响），12.x 回退到手写 LaunchAgent plist。全项目对"开机自启"的启停/查询都应经过
/// 这里，不要再直接调用 LaunchAgentInstaller（它退化为 12.x 的 plist 实现细节）。
enum LaunchAtLoginController {
    /// 按 LaunchAtLoginPreference（默认开启）同步 OS 层的自启状态，启动时调用一次。
    static func syncWithPreference() {
        if LaunchAtLoginPreference.isEnabled {
            enable()
        } else {
            disable()
        }
    }

    static func enable() {
        if #available(macOS 13.0, *) {
            // 迁移：老版本可能已用手写 plist 装过自启；13+ 改用 SMAppService 后必须把
            // 遗留 plist 删掉，否则登录时两条机制各拉起一次、进程被重复启动。
            LaunchAgentInstaller.uninstall()
            guard SMAppService.mainApp.status != .enabled else { return }
            do {
                try SMAppService.mainApp.register()
                AuditLog.record("LAUNCH_AT_LOGIN_REGISTERED via=SMAppService")
            } catch {
                // 常见于 DEBUG 裸二进制（非 .app bundle）或未签名场景；如实记录、不崩。
                NSLog("BigDaddy: SMAppService register failed: \(error.localizedDescription)")
            }
        } else {
            LaunchAgentInstaller.installIfNeeded()
        }
    }

    static func disable() {
        if #available(macOS 13.0, *) {
            LaunchAgentInstaller.uninstall() // 遗留 plist 一并清掉，双保险
            guard SMAppService.mainApp.status != .notRegistered else { return }
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
    /// notRegistered）这类客户端 App 内开关拦不住的绕过。13+ 返回 SMAppService 的四态；
    /// 12.x 无等价查询 API，用 plist 是否存在近似表达。
    static var osLevelStatusDescription: String {
        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled: return "enabled"
            case .requiresApproval: return "requiresApproval"
            case .notRegistered: return "notRegistered"
            case .notFound: return "notFound"
            @unknown default: return "unknown"
            }
        } else {
            return FileManager.default.fileExists(atPath: LaunchAgentInstaller.launchAgentURL.path)
                ? "plistPresent" : "plistAbsent"
        }
    }
}

/// 用户级 LaunchAgent（RunAtLoad，不使用特权 daemon）——macOS 12.x 的开机自启实现，
/// 13+ 已由 LaunchAtLoginController 改走 SMAppService。注：不设置 KeepAlive——"崩溃后
/// 自动拉起"这类连续性模式按设计需要家长在 Dashboard 显式开启，后端暂无此配置项，暂缓。
/// 对孩子在系统设置的登录项列表里始终可见，也可随时自行移除（本地关闭开关见
/// LaunchAtLoginPreference）。不要在业务代码里直接调用本类型，统一走 LaunchAtLoginController。
enum LaunchAgentInstaller {
    static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.bigdaddy.client.plist")
    }

    static func installIfNeeded() {
        guard let executablePath = Bundle.main.executablePath else { return }
        let plist: [String: Any] = [
            "Label": "com.bigdaddy.client",
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "KeepAlive": false
        ]
        let url = launchAgentURL
        // 已存在且内容一致就跳过，避免每次启动都重写文件
        if let existingData = try? Data(contentsOf: url),
           let existingPlist = try? PropertyListSerialization.propertyList(from: existingData, format: nil) as? NSDictionary,
           existingPlist == (plist as NSDictionary) {
            return
        }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        AuditLog.record("LAUNCH_AGENT_INSTALLED path=\(executablePath)")
    }

    /// 移除 LaunchAgent plist，让本机从下一次登录起不再自动启动。不调用
    /// launchctl unload——RunAtLoad 且未设 KeepAlive 的 agent 只在"登录时"读取一次
    /// 这份 plist，删除文件本身已经足够；当前已经在跑的进程不受影响，与"安全退出"
    /// 是两个独立动作一致（关闭自启动不等于立刻退出客户端）。
    static func uninstall() {
        let url = launchAgentURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
        AuditLog.record("LAUNCH_AGENT_UNINSTALLED")
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
            let encoder = JSONEncoder()
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
    var errorDescription: String? { serverMessage ?? "HTTP \(statusCode)" }
    /// 签名接口返回 401 只可能是 BigDaddyDeviceAuthService 里的认证失败
    /// （设备未注册/无 secret/签名不对/时间戳超窗），语义上等价于 register() 报告的
    /// credentialsValid=false，都意味着本机手上的凭据当下用不了。
    var isAuthFailure: Bool { statusCode == 401 }
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
