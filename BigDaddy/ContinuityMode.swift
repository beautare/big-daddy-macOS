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
/// 在崩溃 / 强制退出后拉起客户端。SMAppService.mainApp 是登录项，崩了不会拉，所以进程
/// 交给 launchd 托管；但登录项**保留**作开机兜底（见 registerLoginItemFallbackIfNeeded）。
/// 不隐藏第二份 .app，删除应用后 launchd 拉不起来——那是产品限制，不是没做完的恢复。
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

    /// 走 OSLevelStatusCache，同 LaunchAtLoginController.osLevelStatusDescription。这一个更贵：
    /// 未被 launchd 托管时 isLaunchdManaged 还要再 fork 一次 `launchctl print` 取 jobPid。
    static var osLevelStatusDescription: String {
        OSLevelStatusCache.value(for: "continuityMode") { probeOSLevelStatus() }
    }

    private static func probeOSLevelStatus() -> String {
        osStatus(
            keepAliveInstalled: LaunchAgentInstaller.readInstalled().map { LaunchAgentPlist.crashRelaunch(from: $0) } ?? false,
            disabled: Launchctl.isDisabled(),
            backgroundAllowed: LaunchAgentInstaller.isAllowedInBackground,
            loaded: Launchctl.isLoaded(),
            managed: isLaunchdManaged
        )
    }

    /// 心跳 continuityModeOsStatus 的取值，先后顺序就是严重程度。输入都是 autoclosure：
    /// 前面的条件一旦决定结果，后面那几次 launchctl / BTM 查询就不跑。
    ///
    /// keepAliveNotAllowed 排在"已加载"之前：「允许在后台」关掉后，眼下这份进程照样可能
    /// 被托管着（手动打开时客户端自己 bootstrap 进去的），但下次登录 launchd 不会加载它，
    /// 家长必须现在就知道，而不是等下一次重启后失联。
    static func osStatus(
        keepAliveInstalled: Bool,
        disabled: @autoclosure () -> Bool,
        backgroundAllowed: @autoclosure () -> Bool,
        loaded: @autoclosure () -> Bool,
        managed: @autoclosure () -> Bool
    ) -> String {
        guard keepAliveInstalled else { return "off" }
        if disabled() { return "keepAliveDisabled" }
        if !backgroundAllowed() { return "keepAliveNotAllowed" }
        guard loaded() else { return "keepAlivePlistNotLoaded" }
        return managed() ? "keepAliveLoaded" : "keepAliveLoadedUnmanaged"
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
        // kickstart -k 发的是 SIGTERM，先退休墓碑，信号处理器据此不报 FORCE_KILL。
        BigDaddyClient.notePlannedRelaunch()
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
        registerLoginItemFallbackIfNeeded()
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
            // 只有 launchd 手里的定义就是本份可执行文件时才直接 kickstart；App 挪过位置后
            // 旧定义指向不存在的路径，必须 bootout + bootstrap 换成磁盘上的新 plist。
            if Launchctl.jobPid() == nil && Launchctl.jobProgram() == Bundle.main.executablePath {
                let kicked = Launchctl.run(["kickstart", Launchctl.serviceTarget]).status == 0
                OSLevelStatusCache.invalidate()
                AuditLog.record("CONTINUITY_MODE_ENABLED via=kickstart-idle success=\(kicked)")
                if isLaunchdManaged { return }
                if kicked && launchdStartedSuccessor() {
                    handoverExit()
                }
            }
            Launchctl.bootout()
        }
        let bootstrapped = Launchctl.bootstrap(plistURL: LaunchAgentInstaller.launchAgentURL)
        AuditLog.record("CONTINUITY_MODE_ENABLED via=bootstrap success=\(bootstrapped) backgroundAllowed=\(LaunchAgentInstaller.isAllowedInBackground)")
        if bootstrapped && !isLaunchdManaged && launchdStartedSuccessor() {
            handoverExit()
        }
    }

    /// 交接前确认 launchd 真的拉起了一份新进程。拉不起来就不退出，守护留在本进程，
    /// 下一轮 sync 再试；否则新旧两份都没了。新进程会在 shouldExitAsDuplicate 里等本进程
    /// 最多 5 秒，这里的等待必须远短于它。
    private static func launchdStartedSuccessor() -> Bool {
        let own = ProcessInfo.processInfo.processIdentifier
        let deadline = Date().addingTimeInterval(2)
        repeat {
            if let pid = Launchctl.jobPid(), pid != own { return true }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        AuditLog.record("CONTINUITY_HANDOVER_ABORTED reason=successor-not-started")
        return false
    }

    /// 放行系统注销 / 关机时调用。注销可能被别的 App 取消，而本进程已经以 exit 0 退出，
    /// KeepAlive 不会拉。留一个脱离本进程的 kickstart：注销真的完成，它随会话一起没了
    /// 或找不到 job 静默失败；被取消，就在 60 秒后把守护拉回来。job 已在运行时不带 -k 的
    /// kickstart 什么也不做。
    static func scheduleKickstartIfSessionSurvives() {
        guard isActive else { return }
        spawnDetachedShell("""
        sleep 60
        /bin/launchctl kickstart \(Launchctl.serviceTarget)
        """)
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
            // bootout 本进程自己的 job 会收到 SIGTERM，这是计划内交接，不报 FORCE_KILL。
            BigDaddyClient.notePlannedRelaunch()
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

    /// 连续性打开时保留（必要时补注册）SMAppService 登录项，给 KeepAlive agent 当开机兜底。
    ///
    /// 以前这里是注销登录项、只靠 agent 的 RunAtLoad 开机自启，图的是登录时别起两份。
    /// 2026-11 孩子那台 Mac 上栽了：系统设置「允许在后台」把这份 legacy agent 关成了
    /// disallowed，登录时 launchd 根本不加载它，登录项又被我们自己注销了，于是从 10-25 起
    /// 每次重启守护都起不来，要人手动打开（launchctl print-disabled 看不到这种关法，见
    /// LaunchAgentInstaller.isAllowedInBackground）。
    ///
    /// 保留登录项后：agent 被拦，登录项照样把 App 打开，enableKeepAlive 走 bootstrap 把
    /// agent 加载回来（运行时 bootstrap 不受这个开关拦，那台 Mac 上 21:03 实测成功），
    /// KeepAlive 重新接管。agent 没被拦时两条都会在登录时拉 App：已有实例时 LaunchServices
    /// 通常不会再起一份；真起了，后来者在 shouldExitAsDuplicate / enableKeepAlive 的交接里收敛。
    /// .requiresApproval 是家长/孩子在系统设置里把登录项关了，不硬注册回去，靠心跳上报暴露。
    private static func registerLoginItemFallbackIfNeeded() {
        if #available(macOS 13.0, *) {
            let status = SMAppService.mainApp.status
            guard status == .notRegistered || status == .notFound else { return }
            do {
                try SMAppService.mainApp.register()
                OSLevelStatusCache.invalidate()
                AuditLog.record("LAUNCH_AT_LOGIN_REGISTERED via=SMAppService reason=continuity-fallback")
            } catch {
                NSLog("BigDaddy: SMAppService register for continuity fallback failed: \(error.localizedDescription)")
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
