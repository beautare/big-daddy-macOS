import Foundation
// Network 与 NetworkExtension 各有一个叫 NWEndpoint 的类型（前者是 Swift 枚举，后者是
// 已废弃的类），isLikelyQUIC 里两个都要用到，所以那里一律写全限定名。
import Network
import NetworkExtension
import Security

/// 域名级内容过滤。
///
/// **这个文件为什么长这样——两条都是踩出来的。**
///
/// 1. 判域名不能只靠 `NEFilterSocketFlow.remoteHostname`。Apple 的文档写得很清楚：
///    它"只有当这条流是用 Network.framework 或 NSURLSession 创建的时候才非 nil"。
///    Safari 走这条路，所以拦得住；Chrome / Arc / Firefox 自己做 DNS 解析、直接
///    connect 到 IP，这个字段是 nil，域名黑名单对它们完全失效。所以拿不到系统给的
///    主机名时，要从出站握手包里自己读 SNI（见 HandshakeHostname）。
///
/// 2. 放行不能返回终局 `.allow()`。一旦对一条流给出 allow 或 drop，系统就把它从
///    过滤器上摘掉，之后 `update(_:using:for:)` 对它是空操作。表现就是"先开着浏览器
///    访问 youtube，再打开限制开关，那个浏览器一直能访问"。所以放行走
///    `dataVerdict(passBytes:peekBytes:)` 保持挂载——代价是每 passThroughChunkBytes
///    字节回来打个招呼，换来的是家长改策略时能把已经建立的连接精确掐断。
///
/// 第 2 条只有在"限制打开之前这个 provider 就已经在跑"时才兑现得了：系统只把**启动之后
/// 新建**的流送进来，已经存在的 socket 对我们完全不可见，也没有 API 能事后枚举或掐断。
/// 所以主 App 从设备绑定那一刻就让内容过滤一直开着，限制关闭期间本 provider 以透传模式
/// 运行——照常识别主机名、照常保持挂载，只是 `policy.blocks()` 恒为 false。这期间攒下的
/// 跟踪表，正是限制打开那一秒能立刻掐断 YouTube 的全部依仗（见
/// WebFilterController.shouldRunContentFilter）。
///
/// 3. 域名黑名单对 HTTP/3 天然无效——QUIC 的 ClientHello 整个是加密的，SNI 读不出来。
///    抓手是把认出来的 QUIC 流掐掉，逼浏览器回落到握手明文的 TCP+TLS。这个"认出来"
///    本来完全押在系统的远端端点 API 上（isLikelyQUIC），那个 API 静默失效过两次
///    （macOS 15 废弃 remoteEndpoint，换成 remoteFlowEndpoint 之后依然会取不到值），
///    没有任何报错，只会表现成"有的网站拦得住、有的怎么都拦不住"——实测正是这样：
///    bilibili（TCP）秒拦，youtube（HTTP/3）想看多久看多久。所以现在主判据换成了
///    QUICPacket.looksLikeQUIC，直接读 QUIC 长包头的字节特征，不问系统；isLikelyQUIC
///    降级成兜底信号。见 QUICPacket 和 isLikelyQUIC 各自的注释。
///
/// 黑名单模式认不出主机名时放行；白名单模式保持握手数据不外发，达到上限仍认不出时阻断。
/// 两种模式都会阻断生效期间无法识别主机名的 QUIC。
final class FilterDataProvider: NEFilterDataProvider {

    /// 一条正在跟踪的连接。放行之后仍然留着，好在策略变严时把它掐断。
    private final class TrackedFlow {
        let flow: NEFilterSocketFlow
        /// 已经确定的主机名；nil = 至今没认出来
        var hostname: String?
        /// 是否还在等握手包来认主机名
        var awaitingHostname: Bool
        /// 握手字节的暂存。ClientHello 可能被拆成几段送来，攒够了才解析得出。
        var handshake = Data()
        /// 记账序号，越大越新。只用来在跟踪表满了的时候挑最老的淘汰，别的地方不该看它。
        let sequence: UInt64
        /// 从这条流的出站字节里认出过 QUIC。必须记下来：识别只在攒握手包那一小段窗口里
        /// 发生，而"策略变严时该不该掐掉它"是日后才问的问题，那时原始字节早清掉了。
        var sawQUIC = false
        /// 发起这条连接的程序。策略变化时要带着它重新判定——家长把正在运行的游戏设成
        /// 不能联网，它已经建立的连接要像网站规则一样当场掐断。
        let identity: AppIdentity?
        /// 建立时软件规则判定为"随时可以联网"（或约定期间的 AGREEMENT 软件）：不扣住握手
        /// 等主机名、不掐 QUIC、认不出主机名也放行。约定到点时 reloadPolicy 会重新判定，
        /// AGREEMENT 软件的流在那时被掐断。
        let bypassesDefault: Bool

        init(flow: NEFilterSocketFlow, hostname: String?, awaitingHostname: Bool, sequence: UInt64,
             identity: AppIdentity?, bypassesDefault: Bool) {
            self.flow = flow
            self.hostname = hostname
            self.awaitingHostname = awaitingHostname
            self.sequence = sequence
            self.identity = identity
            self.bypassesDefault = bypassesDefault
        }
    }

    /// 一次向框架要多少出站字节来找 SNI。一个 ClientHello 通常 1~2 KiB（带上后量子
    /// 密钥交换会更大），4 KiB 一次基本能拿全，拿不全就再要一轮。
    private static let handshakePeekBytes = 4096
    /// 攒到这么多还认不出来就放弃识别：黑名单放行，白名单阻断。
    private static let maxHandshakeBytes = 16 * 1024
    /// 判定放行之后，每放过这么多字节回来打一次招呼。只是为了**保持挂载**（这样日后
    /// 还能掐断它），不做任何检查。取 4 MiB：一个 4K 视频流大概每秒一次回调，开销
    /// 可以忽略；取太小会把扩展塞进热路径，取太大则没有意义——反正只是保持挂载。
    private static let passThroughChunkBytes = 4 * 1024 * 1024
    /// 跟踪表的上限，以及触顶后要削到的水位。
    ///
    /// 清账本来只靠 `flowClosed` 回执（handle(_:)）。那在"只有限网期间才跑"的时代够用，
    /// 现在 provider 从绑定起就一直开着，一台机器上所有程序的连接都从这里过——回执万一
    /// 漏掉一条，就永久占着一个条目和最多 maxHandshakeBytes 的握手缓冲，几天下来会积成
    /// 一笔看不见的账。所以加一道硬上限。
    ///
    /// 被淘汰的流只是失去"日后被掐断"的资格（等同于当初给了终局 allow），不会因此漏过
    /// **新**连接——所以宁可淘汰最老的：越老的流越可能其实早就关了，只是回执没到。
    private static let maxTrackedFlows = 2048
    private static let trackedFlowLowWaterMark = 1536
    /// 白名单请求只保留最近 20 个域名。它们是给家长确认的候选项，不是审计全量日志。
    private static let maxAccessRequests = 20
    /// 联网软件清单的上限与统计窗口（app_network_rules_spec.md §3）
    private static let maxAppActivity = 100
    private static let appActivityWindow: TimeInterval = 7 * 24 * 3600
    /// 联网软件清单变化后，最快多久把它刷进回执。回执是主 App 来拉的快照，每条连接都刷
    /// 一次没有意义，也会把热路径变重。
    private static let appActivityPublishInterval: TimeInterval = 60

    /// 本 provider 进程的启动时刻，构造时取一次、此后不变。主 App 靠它回答"这个扩展在那段
    /// 空窗期里有没有重启过"（见 WebFilterController.extensionSurvivedGap）——**不能**用
    /// 回执里的 appliedAt 代替，那个每次重新应用策略都会刷新，详见
    /// WebFilterProviderAcknowledgement.providerStartedAt 的注释。
    private let providerStartedAt = Date()
    private let policyLock = NSLock()

    /// "什么都不拦"的初始/复位策略。revision 0、appliedAt 取纪元，任何真实策略都能盖过它。
    private static let emptyPolicy = WebFilterPolicySnapshot(
        configuration: WebFilterConfiguration(),
        isDeviceBound: false,
        appliedAt: Date(timeIntervalSince1970: 0)
    )

    private var policy = FilterDataProvider.emptyPolicy
    private var trackedFlows: [ObjectIdentifier: TrackedFlow] = [:]
    private var accessRequests: [String: WebFilterAccessRequest] = [:]
    /// 键为"团队 ID/签名标识符"，辅助进程按 AppNetworkRule 同样的前缀规则不单独成行
    private var appActivity: [String: AppNetworkActivity] = [:]
    private var lastAppActivityPublish = Date.distantPast
    private let identityResolver = AppIdentityResolver()
    private var nextFlowSequence: UInt64 = 0
    private var boundaryWork: DispatchWorkItem?
    private var configurationObservation: NSKeyValueObservation?
    /// 回执服务端。主 App 靠它知道"provider 到底应用了哪个 revision"，家长端的
    /// "实际版本 / 已生效"整列信息都来自这里。取不到 mach 服务名（Info.plist 没写
    /// NEMachServiceName）时为 nil：过滤照常工作，只是家长端会一直显示"状态未知"。
    private let ipcListener: WebFilterProviderIPCListener? = {
        guard let machServiceName = WebFilterIPC.providerMachServiceName() else {
            NSLog("BigDaddyWebFilter: no mach service name in Info.plist, acknowledgement channel disabled")
            return nil
        }
        return WebFilterProviderIPCListener(
            machServiceName: machServiceName,
            codeSigningRequirement: WebFilterIPC.codeSigningRequirement()
        )
    }()

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        ipcListener?.start()
        configurationObservation = observe(\.filterConfiguration, options: [.new]) { [weak self] _, _ in
            self?.reloadPolicy()
        }
        reloadPolicy()
        completionHandler(nil)
    }

    override func stopFilter(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        configurationObservation = nil
        boundaryWork?.cancel()
        boundaryWork = nil
        policyLock.lock()
        trackedFlows.removeAll()
        accessRequests.removeAll()
        appActivity.removeAll()
        // 策略一并清回默认值：被叫停之后就不该再留着一份"要拦什么"的记忆。provider 进程
        // 未必随过滤停止而退出，而"停掉再开"之间这台机器可能已经换了家庭（解绑会让后端删掉
        // 设备行、级联重建配置）。下次 startFilter 会走 reloadPolicy 重新读，不依赖这里留下
        // 的任何东西。
        policy = Self.emptyPolicy
        policyLock.unlock()
        completionHandler()
    }

    // MARK: - 新连接

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        // 只有 socket flow 能被事后改判，也只有它会被我们记住。本项目只开了
        // filterSockets，正常不会出现别的子类；真出现了就放行，没有更安全的默认动作。
        guard let socketFlow = flow as? NEFilterSocketFlow else {
            return .allow()
        }

        policyLock.lock()
        let policy = self.policy
        policyLock.unlock()

        // 软件规则不需要主机名，第一时间就能下结论：游戏的裸 IP、自定义 UDP 连接都在这里拦下，
        // 不用等握手包。身份解析有缓存，同一个进程只解析一次。
        let identity = identityResolver.identity(of: socketFlow.sourceAppAuditToken)
        let appVerdict = policy.appVerdict(for: identity)
        recordAppActivity(identity, blocked: appVerdict == .block)
        if appVerdict == .block {
            return .drop()
        }
        let bypassesDefault = appVerdict == .bypass

        // 快速路径：系统已经知道这条流要去哪儿（Safari、走 NSURLSession 的原生 App）。
        // 不用等握手，也不用解析任何东西。
        if let hostname = systemHostname(for: socketFlow) {
            if policy.blocks(hostname: hostname, identity: identity)
                && !permitsManagementConnection(socketFlow, hostname: hostname, policy: policy) {
                recordAccessRequestIfNeeded(hostname)
                return .drop()
            }
            remember(socketFlow, hostname: hostname, awaitingHostname: false,
                     identity: identity, bypassesDefault: bypassesDefault)
            return stayAttachedNewFlowVerdict()
        }

        // 系统不知道——Chromium 系浏览器的常态。让它把握手包给我们看，从 SNI 里读。
        remember(socketFlow, hostname: nil, awaitingHostname: true,
                 identity: identity, bypassesDefault: bypassesDefault)
        return inspectHandshakeVerdict()
    }

    // MARK: - 出站数据

    override func handleOutboundData(
        from flow: NEFilterFlow,
        readBytesStartOffset offset: Int,
        readBytes: Data
    ) -> NEFilterDataVerdict {
        guard let socketFlow = flow as? NEFilterSocketFlow else {
            return .allow()
        }
        let key = ObjectIdentifier(socketFlow)

        policyLock.lock()
        let policy = self.policy
        guard let tracked = trackedFlows[key], tracked.awaitingHostname else {
            policyLock.unlock()
            // 早就判过了，这次回调只是"保持挂载"的例行招呼
            return passThroughVerdict()
        }
        // "随时可以联网"的软件不受"名单之外都打不开"约束，也就不必扣住握手等主机名；
        // 读主机名只是为了执行「任何时候都不行」的网站。
        let holdsForHostname = policy.requiresKnownHostname && !tracked.bypassesDefault
        if holdsForHostname && offset == 0 {
            tracked.handshake = readBytes
        } else {
            tracked.handshake.append(readBytes)
        }
        let handshake = tracked.handshake
        policyLock.unlock()

        if let hostname = HandshakeHostname.host(in: handshake) {
            return resolve(socketFlow, key: key, hostname: hostname, policy: policy)
        }

        // 还认不出来。QUIC 的 ClientHello 是加密的，永远也认不出来——生效期间直接掐掉，
        // 浏览器会自动回落到 TCP+TLS，那条路的握手是明文的，我们读得到。
        //
        // 这一条是全文件唯一主动放弃"认不出就放行"的地方，因为不掐掉它就等于给
        // Chrome / Arc / Firefox 留了一条完全绕过限制的通道——实测正是这条通道让
        // "已生效，正在阻断"变成了一句空话。代价是这台 Mac 上其它程序的 QUIC 也会被
        // 掐，绝大多数会静默回落到 TCP。只在策略真正启用时才这么做。
        //
        // 判据以**包内容**为准（QUICPacket），系统给的 UDP/443 只当补充信号：那套端点
        // API 已经静默失效过两次，不能再让整条 HTTP/3 防线单独押在它上面。
        let quic = QUICPacket.looksLikeQUIC(handshake) || isLikelyQUIC(socketFlow)
        if quic {
            policyLock.lock()
            trackedFlows[key]?.sawQUIC = true
            policyLock.unlock()
        }
        // 随时可以联网的软件不掐 QUIC：家长的意思是"这个软件联网别管"。代价是它经 QUIC
        // 访问「任何时候都不行」的网站时认不出主机名、拦不住——这类软件通常是网课工具，可以接受。
        if policy.enabled, quic, !tracked.bypassesDefault {
            forget(key)
            return .drop()
        }

        if handshake.count >= Self.maxHandshakeBytes {
            if holdsForHostname {
                forget(key)
                return .drop()
            }
            // 不是 TLS 也不是 HTTP，认不出来了。放弃识别，但保持挂载——万一它的
            // 主机名以后被系统补上（remoteHostname 可能晚于 handleNewFlow 才有值），
            // reloadPolicy 还有机会重新判定。
            policyLock.lock()
            trackedFlows[key]?.awaitingHostname = false
            trackedFlows[key]?.handshake = Data()
            policyLock.unlock()
            return passThroughVerdict()
        }

        // 白名单要在识别出域名前扣住握手数据；黑名单沿用已经验证过的边读边放行行为。
        // passBytes: 0 的实际系统表现仍需在签名安装后的 Mac 上验证。
        if holdsForHostname {
            return NEFilterDataVerdict(passBytes: 0, peekBytes: min(Self.maxHandshakeBytes, handshake.count + Self.handshakePeekBytes))
        }
        return NEFilterDataVerdict(passBytes: readBytes.count, peekBytes: Self.handshakePeekBytes)
    }

    /// 框架看完一个方向的全部数据之后的收尾。必须实现并给一个明确的放行，
    /// 否则处于数据过滤模式的流会卡在这里——表现为"网页转圈转到超时"。
    override func handleOutboundDataComplete(for flow: NEFilterFlow) -> NEFilterDataVerdict {
        unresolvedFlowVerdict(for: flow)
    }

    override func handleInboundDataComplete(for flow: NEFilterFlow) -> NEFilterDataVerdict {
        unresolvedFlowVerdict(for: flow)
    }

    private func unresolvedFlowVerdict(for flow: NEFilterFlow) -> NEFilterDataVerdict {
        policyLock.lock()
        let tracked = trackedFlows[ObjectIdentifier(flow)]
        let unresolved = policy.requiresKnownHostname
            && tracked?.awaitingHostname == true
            && tracked?.bypassesDefault == false
        policyLock.unlock()
        return unresolved ? .drop() : .allow()
    }

    override func handle(_ report: NEFilterReport) {
        guard report.event == .flowClosed, let flow = report.flow else { return }
        forget(ObjectIdentifier(flow))
    }

    // MARK: - 策略

    /// 从系统的 vendorConfiguration 里重读策略并落地：filterConfiguration 的 KVO 触发的那条
    /// 路，也是 startFilter 里的初次加载。这是策略进入 provider 的**唯一**入口。
    ///
    /// 曾经并行存在过一条"主 App 经 XPC 直接推策略"的加速通道，理由是"系统这条分发管线要
    /// 一两分钟"。那个判断后来被证伪了——真正让限制迟迟不生效的是 HTTP/3 绕过（见
    /// isLikelyQUIC），跟策略送达速度无关。加速通道因此连同它带来的一整套东西（可写的 XPC
    /// 端点、新旧策略守卫、来源区分）一起撤掉了：没有实测支撑的复杂度，在监护类产品里是负资产。
    /// 真要再引入，先拿下面那行日志量出系统这条路的实际延迟，用数据说话。
    private func reloadPolicy() {
        let nextPolicy = WebFilterPolicyTransport.policy(from: filterConfiguration.vendorConfiguration)
            ?? Self.emptyPolicy

        policyLock.lock()
        policy = nextPolicy
        var flowsToDrop: [NEFilterSocketFlow] = []
        var hostsNeedingApproval: [String] = []
        if !nextPolicy.requiresKnownHostname {
            accessRequests.removeAll()
        }
        // udp / quic 这两个计数是给 isLikelyQUIC 用的体检指标，不是凑热闹：它依赖的远端
        // 端点 API 在新系统上可能拿不到值，而那会静默地让 HTTP/3 完全绕过限制。跟踪表里
        // 明明有 UDP 流、认出来的 QUIC 却是 0，就是那个故障的确诊信号。
        var udpCount = 0
        var quicCount = 0
        for (key, tracked) in trackedFlows {
            // 主机名优先用已经认出来的那个；没有就再问一次系统——remoteHostname 可能
            // 在 handleNewFlow 之后才被填上，当场重读能让这类流赶上这次策略变化。
            let hostname = tracked.hostname ?? systemHostname(for: tracked.flow)
            // sawQUIC 优先：那是从字节里认出来的、板上钉钉的结论，而 isLikelyQUIC 依赖的
            // 系统端点 API 随时可能取不到值（已经发生过两次）。
            let quic = tracked.sawQUIC || isLikelyQUIC(tracked.flow)
            if tracked.flow.socketProtocol == IPPROTO_UDP { udpCount += 1 }
            if quic { quicCount += 1 }
            let isManagementFlow = hostname.map { host in
                nextPolicy.managementHost.map { DomainName.normalize($0) == DomainName.normalize(host) } ?? false
            } ?? false
            let shouldDrop = WebFilterFlowDisposition.shouldTerminate(
                hostname: hostname,
                isLikelyQUIC: quic,
                isManagementApp: isManagementFlow && isManagementApp(tracked.flow, policy: nextPolicy),
                identity: tracked.identity,
                under: nextPolicy
            )
            if shouldDrop {
                flowsToDrop.append(tracked.flow)
                trackedFlows.removeValue(forKey: key)
                if let hostname, nextPolicy.needsParentApproval(hostname: hostname) {
                    hostsNeedingApproval.append(hostname)
                }
            }
        }
        let trackedCount = trackedFlows.count
        policyLock.unlock()

        for flow in flowsToDrop {
            update(flow, using: .drop(), for: .any)
        }
        hostsNeedingApproval.forEach(recordAccessRequestIfNeeded)

        // 这一行是这个功能唯一的量尺，别当成噪音删掉——它每一个字段都是拿故障换来的：
        //   · 与家长操作的时间差 ⇒ 系统配置分发到底慢不慢（曾经靠猜，猜错过一次）；
        //   · dropped=0 而浏览器照常能上 ⇒ 那些连接压根没在跟踪表里，问题在覆盖面
        //     （装新版会重启扩展并清空跟踪表，头一次测总会撞上）；
        //   · dropped>0 但浏览器照常能上 ⇒ 掐断动作没能拆掉已建立的 socket，
        //     病在 update(_:using:.drop()) 那一层；
        //   · udp>0 而 quic=0 ⇒ isLikelyQUIC 瞎了，HTTP/3 正在完全绕过黑名单。
        //     这正是"bilibili 秒拦、youtube 怎么都拦不住"那次故障的确诊信号。
        NSLog("""
            BigDaddyWebFilter: applied policy revision=\(nextPolicy.revision) \
            enforcing=\(nextPolicy.enabled) rules=\(nextPolicy.blockedDomains.count) \
            appRules=\(nextPolicy.appRules.count) \
            dropped=\(flowsToDrop.count) tracked=\(trackedCount) \
            udp=\(udpCount) quic=\(quicCount)
            """)

        // 回执只在"这份策略确实是当前生效的那份"时才发：期间又来了一次更新的话，
        // 由那一轮 reloadPolicy 负责发它自己的回执，这一轮闭嘴，免得把已经被顶掉的
        // 旧 revision 报成"已应用"。
        policyLock.lock()
        let isStillCurrent = policy == nextPolicy
        policyLock.unlock()
        guard isStillCurrent else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.policyLock.lock()
            let current = self.policy == nextPolicy
            self.policyLock.unlock()
            guard current else { return }
            self.boundaryWork?.cancel()
            self.boundaryWork = nil
            let now = Date()
            if let boundary = nextPolicy.nextReevaluation(after: now) {
                let work = DispatchWorkItem { [weak self] in self?.reloadPolicy() }
                self.boundaryWork = work
                DispatchQueue.main.asyncAfter(wallDeadline: .now() + boundary.timeIntervalSince(now), execute: work)
            }
        }
        publishAcknowledgement(for: nextPolicy)
    }

    // MARK: - 判定与记账

    private func resolve(
        _ flow: NEFilterSocketFlow,
        key: ObjectIdentifier,
        hostname: String,
        policy: WebFilterPolicySnapshot
    ) -> NEFilterDataVerdict {
        policyLock.lock()
        let identity = trackedFlows[key]?.identity
        policyLock.unlock()
        let blocked = policy.blocks(hostname: hostname, identity: identity)
            && !permitsManagementConnection(flow, hostname: hostname, policy: policy)
        if blocked {
            recordAccessRequestIfNeeded(hostname)
        }
        policyLock.lock()
        if blocked {
            trackedFlows.removeValue(forKey: key)
        } else {
            trackedFlows[key]?.hostname = hostname
            trackedFlows[key]?.awaitingHostname = false
            trackedFlows[key]?.handshake = Data()
        }
        policyLock.unlock()
        return blocked ? .drop() : passThroughVerdict()
    }

    private func recordAccessRequestIfNeeded(_ hostname: String) {
        let normalized = DomainName.normalize(hostname)
        guard !normalized.isEmpty else { return }

        policyLock.lock()
        guard policy.needsParentApproval(hostname: normalized) else {
            policyLock.unlock()
            return
        }
        let now = Date()
        if let existing = accessRequests[normalized] {
            accessRequests[normalized] = WebFilterAccessRequest(
                domain: normalized,
                lastBlockedAt: now,
                count: existing.count + 1
            )
        } else {
            accessRequests[normalized] = WebFilterAccessRequest(
                domain: normalized,
                lastBlockedAt: now,
                count: 1
            )
        }
        if accessRequests.count > Self.maxAccessRequests,
           let oldest = accessRequests.min(by: { $0.value.lastBlockedAt < $1.value.lastBlockedAt })?.key {
            accessRequests.removeValue(forKey: oldest)
        }
        let currentPolicy = policy
        policyLock.unlock()
        publishAcknowledgement(for: currentPolicy)
    }

    /// 统计联网软件清单。系统程序不进清单（家长也不能管它们）。
    private func recordAppActivity(_ identity: AppIdentity?, blocked: Bool) {
        guard let identity, !identity.isPlatformBinary else { return }
        let now = Date()
        policyLock.lock()
        let key = appActivityKey(for: identity)
        var entry = appActivity[key] ?? AppNetworkActivity(
            signingIdentifier: key.split(separator: "/", maxSplits: 1).last.map(String.init) ?? identity.signingIdentifier,
            teamIdentifier: identity.teamIdentifier,
            bundlePath: identityResolver.bundlePath(of: identity),
            lastSeenAt: now,
            connectionCount: 0,
            blockedCount: 0
        )
        entry.lastSeenAt = now
        entry.connectionCount += 1
        if blocked { entry.blockedCount += 1 }
        appActivity[key] = entry
        if appActivity.count > Self.maxAppActivity,
           let oldest = appActivity.min(by: { $0.value.lastSeenAt < $1.value.lastSeenAt })?.key {
            appActivity.removeValue(forKey: oldest)
        }
        let shouldPublish = now.timeIntervalSince(lastAppActivityPublish) >= Self.appActivityPublishInterval
        if shouldPublish { lastAppActivityPublish = now }
        let currentPolicy = policy
        policyLock.unlock()
        if shouldPublish {
            publishAcknowledgement(for: currentPolicy)
        }
    }

    /// 辅助进程归到已经出现过的主程序名下（同团队、标识符以"主程序标识符."开头），
    /// 与 AppNetworkRule.matches 的前缀规则一致，家长在清单里看到的就是能管住它的那一行。
    /// 调用方必须已经持有 policyLock。
    private func appActivityKey(for identity: AppIdentity) -> String {
        let team = identity.teamIdentifier ?? ""
        let parent = appActivity.values.first { entry in
            entry.teamIdentifier == identity.teamIdentifier
                && identity.signingIdentifier.hasPrefix(entry.signingIdentifier + ".")
        }
        return "\(team)/\(parent?.signingIdentifier ?? identity.signingIdentifier)"
    }

    /// 调用方必须已经持有 policyLock。
    private func currentAppActivity() -> [AppNetworkActivity] {
        let cutoff = Date().addingTimeInterval(-Self.appActivityWindow)
        appActivity = appActivity.filter { $0.value.lastSeenAt >= cutoff }
        return appActivity.values.sorted { $0.lastSeenAt > $1.lastSeenAt }
    }

    private func sortedAccessRequests() -> [WebFilterAccessRequest] {
        accessRequests.values.sorted { lhs, rhs in
            lhs.lastBlockedAt == rhs.lastBlockedAt
                ? lhs.domain < rhs.domain
                : lhs.lastBlockedAt > rhs.lastBlockedAt
        }
    }

    private func publishAcknowledgement(for policy: WebFilterPolicySnapshot) {
        policyLock.lock()
        let accessRequests = sortedAccessRequests()
        let activity = currentAppActivity()
        policyLock.unlock()
        ipcListener?.publish(WebFilterProviderAcknowledgement(
            policy: policy,
            accessRequests: accessRequests,
            appActivity: activity,
            providerStartedAt: providerStartedAt
        ))
    }

    private func permitsManagementConnection(
        _ flow: NEFilterSocketFlow, hostname: String, policy: WebFilterPolicySnapshot
    ) -> Bool {
        guard let managementHost = policy.managementHost,
              DomainName.normalize(hostname) == DomainName.normalize(managementHost) else { return false }
        return policy.permitsManagementConnection(
            hostname: hostname, isManagementApp: isManagementApp(flow, policy: policy))
    }

    private func isManagementApp(_ flow: NEFilterSocketFlow, policy: WebFilterPolicySnapshot) -> Bool {
        guard policy.mode == .allowSelected,
              let identifier = policy.managementAppIdentifier,
              let token = flow.sourceAppAuditToken,
              let teamRequirement = WebFilterIPC.codeSigningRequirement() else { return false }
        let requirementText = "identifier \"\(identifier)\" and \(teamRequirement)"
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit as String: token] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    private func remember(
        _ flow: NEFilterSocketFlow, hostname: String?, awaitingHostname: Bool,
        identity: AppIdentity?, bypassesDefault: Bool
    ) {
        policyLock.lock()
        nextFlowSequence += 1
        trackedFlows[ObjectIdentifier(flow)] = TrackedFlow(
            flow: flow,
            hostname: hostname,
            awaitingHostname: awaitingHostname,
            sequence: nextFlowSequence,
            identity: identity,
            bypassesDefault: bypassesDefault
        )
        evictOldestTrackedFlowsIfNeeded()
        policyLock.unlock()
    }

    /// 调用方必须已经持有 policyLock。
    private func evictOldestTrackedFlowsIfNeeded() {
        guard trackedFlows.count > Self.maxTrackedFlows else { return }
        let survivors = trackedFlows
            .sorted { $0.value.sequence > $1.value.sequence }
            .prefix(Self.trackedFlowLowWaterMark)
        trackedFlows = Dictionary(uniqueKeysWithValues: survivors.map { ($0.key, $0.value) })
        NSLog("BigDaddyWebFilter: tracked flow table trimmed to \(trackedFlows.count)")
    }

    private func forget(_ key: ObjectIdentifier) {
        policyLock.lock()
        trackedFlows.removeValue(forKey: key)
        policyLock.unlock()
    }

    // MARK: - 判决工厂

    /// 放行，但**留在过滤器上**。shouldReport 让我们能在流关闭时收到通知去清账。
    private func stayAttachedNewFlowVerdict() -> NEFilterNewFlowVerdict {
        let verdict = NEFilterNewFlowVerdict.filterDataVerdict(
            withFilterInbound: false,
            peekInboundBytes: 0,
            filterOutbound: true,
            peekOutboundBytes: 1
        )
        verdict.shouldReport = true
        return verdict
    }

    /// 先别放行，把握手包给我看。
    private func inspectHandshakeVerdict() -> NEFilterNewFlowVerdict {
        let verdict = NEFilterNewFlowVerdict.filterDataVerdict(
            withFilterInbound: false,
            peekInboundBytes: 0,
            filterOutbound: true,
            peekOutboundBytes: Self.handshakePeekBytes
        )
        verdict.shouldReport = true
        return verdict
    }

    /// 放过一大段，然后回来打个招呼。peekBytes 取 1 而不是 0：0 在部分系统版本上会
    /// 被当成"不再需要看数据"从而把流摘掉，那正好破坏我们保持挂载的目的。
    private func passThroughVerdict() -> NEFilterDataVerdict {
        NEFilterDataVerdict(passBytes: Self.passThroughChunkBytes, peekBytes: 1)
    }

    // MARK: - 流的属性

    /// 系统告诉我们的主机名。拿得到就不用解析握手包。
    private func systemHostname(for flow: NEFilterSocketFlow) -> String? {
        if let hostname = flow.url?.host {
            return hostname
        }
        if let hostname = flow.remoteHostname {
            return hostname
        }
        // remoteEndpoint 在没有域名时给的是 IP 字面量，拿它去匹配域名永远匹配不上，
        // 所以这里**不**把它当主机名用——那正是老实现"看起来读到了、其实是个 IP"
        // 的来源。真的只有 IP 时，交给握手包解析去认。
        return nil
    }

    /// 像不像 QUIC：UDP + 远端 443。**只是补充信号，不是主判据。**
    ///
    /// 曾经这是全项目唯一拦得住 HTTP/3 的地方，代价是把整条防线押在系统的远端端点 API 上——
    /// 而这个 API 已经静默失效过两次：`remoteEndpoint` 在 macOS 15 被废弃后换成了
    /// `remoteFlowEndpoint`，换完之后实测**依然**会取不到值，且没有任何报错或降级提示。
    /// 两次失效的共同后果：youtube 这类默认走 HTTP/3 的站点完全绕过限制，bilibili 这类走
    /// TCP 的照常被拦，表现成"有的域名秒拦、有的怎么都拦不住"，查起来极难定位到这里。
    ///
    /// 所以主判据换成了 QUICPacket.looksLikeQUIC——直接读 QUIC 长包头的固定位模式和版本号，
    /// 不问系统。本方法降级为 `||` 的另一侧：只在字节判据因为握手包还没攒够而暂时给不出
    /// 结论时，多一次机会。调用点见 handleOutboundData 和 reloadPolicy 里 `quic =` 那两行。
    ///
    /// remoteEndpoint 在部署目标 12.4 上还用得到，所以两条路都留着：新系统优先用没废弃的
    /// remoteFlowEndpoint，老系统回落到 remoteEndpoint。两者都可能在 handleNewFlow 时还是
    /// nil（Apple 文档明确说了远端信息要等收到网络数据后才填上），这也是它只能当补充信号、
    /// 不能独立扛下这条防线的另一个原因——它连"什么时候能读"都不能保证。
    private func isLikelyQUIC(_ flow: NEFilterSocketFlow) -> Bool {
        guard flow.socketProtocol == IPPROTO_UDP else { return false }
        // remoteFlowEndpoint 这个符号本身要 macOS 15 SDK（Xcode 16+）才存在于头文件里，
        // #available 只挡运行时、挡不住编译期缺符号——用老 Xcode 编译时，没有
        // compiler(>=6.0) 这道闸门就直接编译失败，跟能不能跑到 macOS 15 没关系。
        //
        // 注意这道闸门是有代价的：它一旦为假，整段 macOS 15 的路径**从二进制里消失**，
        // 而剩下的 remoteEndpoint 恰恰是在 macOS 15 上取不到值的那个（见上面的注释）。
        // 也就是说用老 Xcode 构建出的包，在 macOS 15 上 isLikelyQUIC 近乎恒假——一次
        // 无声的降级，正是本文件反复警告的那类故障。所以 CI 显式钉了 Xcode 版本
        // （见 release.yml 的 "Select Xcode" 一步），这里再加一条编译期告警兜底：
        // 万一有人在老工具链上出包，日志里至少能看见。
        #if compiler(>=6.0)
        if #available(macOS 15.0, *), let endpoint = flow.remoteFlowEndpoint {
            if case let .hostPort(_, port) = endpoint {
                return port.rawValue == 443
            }
        }
        #else
        #warning("Swift < 6.0：macOS 15 的 remoteFlowEndpoint 路径已被编译掉，isLikelyQUIC 在 macOS 15+ 上近乎恒假（HTTP/3 兜底信号失效）。请用 Xcode 16+ 构建发布包。")
        #endif
        if let endpoint = flow.remoteEndpoint as? NWHostEndpoint {
            return endpoint.port == "443"
        }
        return false
    }
}

/// 从审计令牌解析发起连接的程序的代码签名身份。
///
/// 必须缓存：handleNewFlow 是全项目唯一调用频率没有上限的路径，每条连接都走一遍
/// Security 框架（读磁盘上的签名、校验 anchor apple）不可接受。键直接用审计令牌本身——
/// 它含 pid 与 pidversion，pid 被复用时令牌也不同，不会把新进程认成旧进程。
private final class AppIdentityResolver {
    private static let maxCachedProcesses = 512

    private let lock = NSLock()
    private var identities: [Data: AppIdentity?] = [:]
    private var bundlePaths: [AppIdentity: String] = [:]
    private let appleAnchor: SecRequirement? = {
        var requirement: SecRequirement?
        SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement)
        return requirement
    }()

    func identity(of auditToken: Data?) -> AppIdentity? {
        guard let auditToken else { return nil }
        lock.lock()
        if let cached = identities[auditToken] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved = resolve(auditToken)

        lock.lock()
        if identities.count >= Self.maxCachedProcesses {
            identities.removeAll(keepingCapacity: true)
        }
        identities[auditToken] = .some(resolved?.identity)
        if let resolved, let path = resolved.bundlePath {
            bundlePaths[resolved.identity] = path
        }
        lock.unlock()
        return resolved?.identity
    }

    func bundlePath(of identity: AppIdentity) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return bundlePaths[identity]
    }

    /// 解析失败（进程已退出、签名无效）返回 nil：软件规则不命中，按网站规则处理。
    private func resolve(_ auditToken: Data) -> (identity: AppIdentity, bundlePath: String?)? {
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit as String: auditToken] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any],
              let signingIdentifier = info[kSecCodeInfoIdentifier as String] as? String else { return nil }
        let isPlatformBinary = appleAnchor.map { SecCodeCheckValidity(code, [], $0) == errSecSuccess } ?? false
        var url: CFURL?
        let bundlePath = SecCodeCopyPath(staticCode, [], &url) == errSecSuccess ? (url as URL?)?.path : nil
        return (
            AppIdentity(
                signingIdentifier: signingIdentifier,
                teamIdentifier: info[kSecCodeInfoTeamIdentifier as String] as? String,
                isPlatformBinary: isPlatformBinary
            ),
            bundlePath
        )
    }
}
