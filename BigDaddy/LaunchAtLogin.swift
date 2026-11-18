import AppKit
import ApplicationServices
import AudioToolbox
import CoreAudio
import CryptoKit
import Darwin
import Foundation
import IOKit.pwr_mgt
import Network
import ScreenCaptureKit
import Security
import ServiceManagement

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
/// 托管同一份用户级 LaunchAgent（RunAtLoad + KeepAlive），13+ 的 SMAppService 登录项
/// 由它保留作开机兜底。全项目对"开机自启"的启停/查询都应经过这里；连续性模式打开期间
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
                OSLevelStatusCache.invalidate()
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
                OSLevelStatusCache.invalidate()
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
    ///
    /// 走 OSLevelStatusCache：这个属性只被 sendHeartbeat 的 metadata 读，而下面那次探测
    /// 压着一回 plist 读盘 + 一个 `launchctl print` 子进程。缓存的取舍见该类型的注释。
    static var osLevelStatusDescription: String {
        OSLevelStatusCache.value(for: "launchAtLogin") { probeOSLevelStatus() }
    }

    /// 先看 agent 的 RunAtLoad，再回退到 SMAppService / 文件是否存在。agent 被「允许在后台」
    /// 关掉时它登录时不会被加载，开机自启实际只剩 SMAppService 登录项那一条，按后者报。
    private static func probeOSLevelStatus() -> String {
        if let plist = LaunchAgentInstaller.readInstalled(), LaunchAgentPlist.runAtLoad(from: plist),
           LaunchAgentInstaller.isAllowedInBackground {
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

    /// associatedBundleIdentifier 写进 AssociatedBundleIdentifiers：没有它，系统设置「登录项与
    /// 扩展 → 允许在后台」里这一项不叫 BigDaddy，而是挂在开发者名（Shanghai Jiamei Software
    /// Development Co., Ltd）下面——2026-11 家长按告警去找"BigDaddy"，翻遍了也找不到开关。
    /// launchd 本身不读这个键（man launchd.plist：给 Login Items 界面关联 App 用的）。
    static func make(
        executablePath: String,
        runAtLoad: Bool,
        crashRelaunch: Bool,
        associatedBundleIdentifier: String? = nil
    ) -> [String: Any] {
        var plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath],
            "RunAtLoad": runAtLoad,
            "EnvironmentVariables": [launchedByLaunchdEnvKey: "1"]
        ]
        if let associatedBundleIdentifier {
            plist["AssociatedBundleIdentifiers"] = [associatedBundleIdentifier]
        }
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

/// 心跳上报用的 OS 层状态缓存。
///
/// LaunchAtLoginController / ContinuityModeController 的 osLevelStatusDescription 都要先读
/// 一次 LaunchAgent plist、再 `launchctl print` 一把（后者在本进程不归 launchd 托管时还要
/// 多一次 jobPid()）。每次 Launchctl.run 都是一次 fork + exec + waitUntilExit，实测约 8ms
/// 挂在调用线程上。而这两个属性**只有一个调用点**——sendHeartbeat 的 metadata——心跳又由
/// 每次前台切换应用触发（startActivitySwitchTracking，2 秒防抖），连续性模式开着、孩子在
/// 密集 alt-tab 时，就是每 2 秒 fork 两三个进程、白等几十毫秒，只为了重复回答同一个答案。
///
/// 用 TTL 而不是永久缓存：这两个字段的意义恰恰是"察觉有人从系统设置里把自启/连续性关了"，
/// 那是外部变化，必须还看得见。60 秒与活跃态心跳间隔同量级，家长端拿到的新鲜度不变，只是
/// 把同一分钟内的重复探测合并掉。我们**自己**改状态的每条路径（装/卸 plist、SMAppService
/// 注册注销、launchctl bootstrap/bootout/kickstart）都会显式 invalidate()，所以自家操作的
/// 结果立刻可见，不必等 TTL 过期。
enum OSLevelStatusCache {
    private static let ttl: TimeInterval = 60
    private static let lock = NSLock()
    private static var cached: [String: (value: String, at: Date)] = [:]
    /// 每次 invalidate() 自增。compute() 跑在锁外（见下），一次真实的状态变更可能恰好
    /// 夹在"读到过期缓存"和"探测结果写回"之间——不夹这道校验的话，那次探测捞回来的
    /// 还是变更前的旧值，写回缓存时盖上新时间戳，等于把刚刚 invalidate() 掉的失效
    /// 悄悄撤销，让本该立刻可见的自家操作又被压回最长 60 秒的 TTL 里。
    private static var generation = 0

    static func value(for key: String, compute: () -> String) -> String {
        lock.lock()
        if let entry = cached[key], Date().timeIntervalSince(entry.at) < ttl {
            lock.unlock()
            return entry.value
        }
        let generationAtStart = generation
        lock.unlock()
        // 刻意不在锁里跑 compute：它会 fork launchctl 并同步等待，占着锁会让另一个字段
        // 的查询一起阻塞。代价是偶尔两个线程各探一次，两次结果相同，无害。
        let value = compute()
        lock.lock()
        // generation 没变 ⇒ compute() 跑的这段时间里没人 invalidate 过，写回去安全。
        // generation 变了 ⇒ 这次探测的结果可能已经是旧状态，不写回，把它让给下一次
        // 调用重新探测；返回给这一次调用方的 value 不受影响，只是不再持久化。
        if generation == generationAtStart {
            cached[key] = (value, Date())
        }
        lock.unlock()
        return value
    }

    static func invalidate() {
        lock.lock()
        cached.removeAll()
        generation += 1
        lock.unlock()
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

    /// 已加载 job 实际要拉起的可执行文件。App 被挪过位置后，launchd 手里的旧定义
    /// 仍指向旧路径，kickstart 会拉一个不存在的程序。
    static func jobProgram() -> String? {
        let result = run(["print", serviceTarget])
        guard result.status == 0,
              let line = result.output.split(separator: "\n").first(where: {
                  $0.trimmingCharacters(in: .whitespaces).hasPrefix("program = ")
              }) else {
            return nil
        }
        return String(line.trimmingCharacters(in: .whitespaces).dropFirst("program = ".count))
    }

    /// 系统设置「允许在后台」关掉，或 `launchctl disable` 过：job 无法加载，
    /// bootstrap 会失败，下次登录也不会启动。
    static func isDisabled() -> Bool {
        let output = run(["print-disabled", domain]).output
        return output.split(separator: "\n").contains {
            $0.contains("\"\(LaunchAgentPlist.label)\"") && ($0.contains("=> disabled") || $0.contains("=> true"))
        }
    }

    // 下面三条会改变 job 的加载状态，跑完必须作废 OSLevelStatusCache——否则家长端要等
    // 最多一个 TTL 才看得到我们自己刚做的改动。只读的 print（isLoaded/jobPid）不用管。
    static func bootout() {
        _ = run(["bootout", serviceTarget])
        OSLevelStatusCache.invalidate()
    }

    static func bootstrap(plistURL: URL) -> Bool {
        defer { OSLevelStatusCache.invalidate() }
        return run(["bootstrap", domain, plistURL.path]).status == 0
    }

    static func kickstart() {
        _ = run(["kickstart", "-k", serviceTarget])
        OSLevelStatusCache.invalidate()
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
            crashRelaunch: crashRelaunch,
            associatedBundleIdentifier: Bundle.main.bundleIdentifier
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
        OSLevelStatusCache.invalidate()
        AuditLog.record("LAUNCH_AGENT_INSTALLED path=\(executablePath) keepAlive=\(crashRelaunch) runAtLoad=\(runAtLoad)")
    }

    static func readInstalled() -> [String: Any]? {
        guard let data = try? Data(contentsOf: launchAgentURL) else { return nil }
        return LaunchAgentPlist.parse(data)
    }

    /// 系统设置「登录项与扩展 → 允许在后台」对这份 legacy agent 的开关。关掉后 BTM 把它
    /// 标成 disallowed：登录时 launchd 不再加载它，可 `launchctl print-disabled` 里看不到
    /// （Launchctl.isDisabled() 因此测不出来），运行时手动 bootstrap 也照样成功——平时一切
    /// 正常，到下次重启才暴露。statusForLegacyPlist 是苹果专门留给 legacy agent 查这件事的
    /// 接口，被关时返回 .requiresApproval；实测 RunAtLoad=true 却没被加载的几份 agent 都是它。
    static var isAllowedInBackground: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.statusForLegacyPlist(at: launchAgentURL) != .requiresApproval
        }
        return true
    }

    static func uninstall() {
        let url = launchAgentURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
        OSLevelStatusCache.invalidate()
        AuditLog.record("LAUNCH_AGENT_UNINSTALLED")
    }
}
