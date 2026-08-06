import Foundation
import NetworkExtension

final class FilterDataProvider: NEFilterDataProvider {
    /// 只存 flow 本体，不缓存创建那一刻读到的主机名。
    ///
    /// 早期版本在这里连主机名一起缓存，`reloadPolicy` 拿策略变化后的新黑名单去比对
    /// 的是这份"出生时"的快照。绝大多数情况下没问题，但 `NEFilterSocketFlow.remoteHostname`
    /// 由系统的 DNS 关联填充，这个关联可能比 `handleNewFlow` 回调本身慢半拍——如果慢了，
    /// 当时读到的是 nil，这条流从此对策略变化"隐形"：家长后来才打开的网站限制永远追不上
    /// 它，孩子那个标签页/刷新/同源新标签会一直复用这条早就放行、且再也不会被重新判定
    /// 的连接。见 hostname(from:) 每次都重新读一次的原因。
    private struct TrackedSocketFlow {
        let flow: NEFilterSocketFlow
    }

    private let policyLock = NSLock()
    private var policy = WebFilterPolicySnapshot(
        configuration: WebFilterConfiguration(),
        isDeviceBound: false,
        appliedAt: Date(timeIntervalSince1970: 0)
    )
    private var trackedSocketFlows: [TrackedSocketFlow] = []
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
        trackedSocketFlows.removeAll()
        policyLock.unlock()
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        // 只有 NEFilterSocketFlow 能事后用 update(_:using:for:) 改判——这也是唯一会被
        // trackedSocketFlows 记住、日后可能被 reloadPolicy 追认拦截的流的类型。本项目
        // 只开了 filterSockets（没开 filterBrowsers），正常不会走到别的 flow 子类；
        // 真遇到就放行，没有更安全的默认动作。
        guard let socketFlow = flow as? NEFilterSocketFlow else {
            return .allow()
        }
        // 此刻拿不到主机名（DNS 关联可能还没追上）不等于"允许判定"——只是意味着现在
        // 判不了。照样放行（没有主机名时拦，等于把系统还没归类的流量全部拦掉，代价
        // 太大），但仍然要 track 它：主机名很可能在几百毫秒后才被系统填上，届时家长
        // 一旦改策略，reloadPolicy 会重新读一次这条流当下的 remoteHostname，还有机会
        // 追认拦截。不 track 的话，这条流对之后任何一次策略变化都是隐形的。
        let hostname = hostname(from: socketFlow)
        policyLock.lock()
        let blocked = hostname.map { policy.blocks(hostname: $0) } ?? false
        let verdict: NEFilterNewFlowVerdict = blocked ? .drop() : .allow()
        if !blocked {
            trackedSocketFlows.append(TrackedSocketFlow(flow: socketFlow))
            verdict.shouldReport = true
        }
        policyLock.unlock()
        return verdict
    }

    override func handle(_ report: NEFilterReport) {
        guard report.event == .flowClosed, let flow = report.flow else { return }
        policyLock.lock()
        trackedSocketFlows.removeAll { $0.flow === flow }
        policyLock.unlock()
    }

    private func reloadPolicy() {
        let nextPolicy = WebFilterPolicyTransport.policy(from: filterConfiguration.vendorConfiguration)
            ?? WebFilterPolicySnapshot(
                configuration: WebFilterConfiguration(),
                isDeviceBound: false,
                appliedAt: Date(timeIntervalSince1970: 0)
            )

        policyLock.lock()
        policy = nextPolicy
        // 判定用的主机名当场重读，不用 track 时缓存的旧值——见 TrackedSocketFlow 的注释：
        // 早期版本缓存的是"出生那一刻"读到的主机名，如果那一刻系统的 DNS 关联还没追上，
        // 缓存下来的就是 nil，这条流对所有后续的策略变化永远都判不出"该不该拦"。当场重读
        // 能让"当时没读到、现在已经有了"的流赶上这一次策略变化——这正是本次要修的场景：
        // 家长开启限制之前就已建立、此刻仍开着的浏览器连接，理应在开启限制的这一刻被追认拦截。
        let (toDrop, toKeep) = trackedSocketFlows.reduce(
            into: (drop: [TrackedSocketFlow](), keep: [TrackedSocketFlow]())
        ) { partition, entry in
            if let hostname = hostname(from: entry.flow), nextPolicy.blocks(hostname: hostname) {
                partition.drop.append(entry)
            } else {
                partition.keep.append(entry)
            }
        }
        trackedSocketFlows = toKeep
        let flowsToDrop = toDrop.map(\.flow)
        policyLock.unlock()

        for flow in flowsToDrop {
            update(flow, using: .drop(), for: .any)
        }

        // 回执只在"这份策略确实是当前生效的那份"时才发：期间又来了一次更新的话，
        // 由那一轮 reloadPolicy 负责发它自己的回执，这一轮闭嘴，免得把已经被顶掉的
        // 旧 revision 报成"已应用"。
        policyLock.lock()
        let isStillCurrent = policy == nextPolicy
        policyLock.unlock()
        guard isStillCurrent else { return }
        ipcListener?.publish(WebFilterProviderAcknowledgement(policy: nextPolicy))
    }

    private func hostname(from flow: NEFilterFlow) -> String? {
        if let hostname = flow.url?.host {
            return hostname
        }
        guard let socketFlow = flow as? NEFilterSocketFlow else {
            return nil
        }
        if let hostname = socketFlow.remoteHostname {
            return hostname
        }
        return (socketFlow.remoteEndpoint as? NWHostEndpoint)?.hostname
    }
}
