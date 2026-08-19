import Foundation
// Network 与 NetworkExtension 各有一个叫 NWEndpoint 的类型（前者是 Swift 枚举，后者是
// 已废弃的类），isLikelyQUIC 里两个都要用到，所以那里一律写全限定名。
import Network
import NetworkExtension

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
/// 一条贯穿全文件的原则：**认不出来一律放行**。误拦会毫无征兆地掐断孩子电脑上任意一个
/// 程序的网络，代价远大于漏拦一次。唯一的例外是生效期间判不出主机名的 UDP 443（QUIC），
/// 见 handleNewFlow 里的说明。
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

        init(flow: NEFilterSocketFlow, hostname: String?, awaitingHostname: Bool, sequence: UInt64) {
            self.flow = flow
            self.hostname = hostname
            self.awaitingHostname = awaitingHostname
            self.sequence = sequence
        }
    }

    /// 一次向框架要多少出站字节来找 SNI。一个 ClientHello 通常 1~2 KiB（带上后量子
    /// 密钥交换会更大），4 KiB 一次基本能拿全，拿不全就再要一轮。
    private static let handshakePeekBytes = 4096
    /// 攒到这么多还认不出来就放弃识别，按放行处理。防止一条不是 TLS/HTTP 的长连接
    /// 让我们无限期地一直要数据。
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
    private var nextFlowSequence: UInt64 = 0
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
        policyLock.lock()
        trackedFlows.removeAll()
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

        // 快速路径：系统已经知道这条流要去哪儿（Safari、走 NSURLSession 的原生 App）。
        // 不用等握手，也不用解析任何东西。
        if let hostname = systemHostname(for: socketFlow) {
            if policy.blocks(hostname: hostname) {
                return .drop()
            }
            remember(socketFlow, hostname: hostname, awaitingHostname: false)
            return stayAttachedNewFlowVerdict()
        }

        // 系统不知道——Chromium 系浏览器的常态。让它把握手包给我们看，从 SNI 里读。
        remember(socketFlow, hostname: nil, awaitingHostname: true)
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
        tracked.handshake.append(readBytes)
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
        if policy.enabled, quic {
            forget(key)
            return .drop()
        }

        if handshake.count >= Self.maxHandshakeBytes {
            // 不是 TLS 也不是 HTTP，认不出来了。放弃识别，但保持挂载——万一它的
            // 主机名以后被系统补上（remoteHostname 可能晚于 handleNewFlow 才有值），
            // reloadPolicy 还有机会重新判定。
            policyLock.lock()
            trackedFlows[key]?.awaitingHostname = false
            trackedFlows[key]?.handshake = Data()
            policyLock.unlock()
            return passThroughVerdict()
        }

        // 再要一轮。这里把已经看过的字节放行而不是扣住（passBytes: 0 的语义在各版本上
        // 表现不一致，见 Apple 论坛上那些"全部流量被丢弃"的报告）：握手包先到服务器
        // 没关系，真判成拦截时整条流会被 drop，页面照样打不开。
        return NEFilterDataVerdict(passBytes: readBytes.count, peekBytes: Self.handshakePeekBytes)
    }

    /// 框架看完一个方向的全部数据之后的收尾。必须实现并给一个明确的放行，
    /// 否则处于数据过滤模式的流会卡在这里——表现为"网页转圈转到超时"。
    override func handleOutboundDataComplete(for flow: NEFilterFlow) -> NEFilterDataVerdict {
        .allow()
    }

    override func handleInboundDataComplete(for flow: NEFilterFlow) -> NEFilterDataVerdict {
        .allow()
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
            let shouldDrop = WebFilterFlowDisposition.shouldTerminate(
                hostname: hostname,
                isLikelyQUIC: quic,
                under: nextPolicy
            )
            if shouldDrop {
                flowsToDrop.append(tracked.flow)
                trackedFlows.removeValue(forKey: key)
            }
        }
        let trackedCount = trackedFlows.count
        policyLock.unlock()

        for flow in flowsToDrop {
            update(flow, using: .drop(), for: .any)
        }

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
        ipcListener?.publish(WebFilterProviderAcknowledgement(
            policy: nextPolicy, providerStartedAt: providerStartedAt))
    }

    // MARK: - 判定与记账

    private func resolve(
        _ flow: NEFilterSocketFlow,
        key: ObjectIdentifier,
        hostname: String,
        policy: WebFilterPolicySnapshot
    ) -> NEFilterDataVerdict {
        let blocked = policy.blocks(hostname: hostname)
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

    private func remember(_ flow: NEFilterSocketFlow, hostname: String?, awaitingHostname: Bool) {
        policyLock.lock()
        nextFlowSequence += 1
        trackedFlows[ObjectIdentifier(flow)] = TrackedFlow(
            flow: flow,
            hostname: hostname,
            awaitingHostname: awaitingHostname,
            sequence: nextFlowSequence
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
        if #available(macOS 15.0, *), let endpoint = flow.remoteFlowEndpoint {
            if case let .hostPort(_, port) = endpoint {
                return port.rawValue == 443
            }
        }
        if let endpoint = flow.remoteEndpoint as? NWHostEndpoint {
            return endpoint.port == "443"
        }
        return false
    }
}
