import Foundation
import NetworkExtension

final class FilterDataProvider: NEFilterDataProvider {
    private struct TrackedSocketFlow {
        let flow: NEFilterSocketFlow
        let hostname: String
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
        guard let hostname = hostname(from: flow) else {
            return .allow()
        }
        policyLock.lock()
        let blocked = policy.blocks(hostname: hostname)
        let verdict: NEFilterNewFlowVerdict = blocked ? .drop() : .allow()
        if !blocked, let socketFlow = flow as? NEFilterSocketFlow {
            trackedSocketFlows.append(TrackedSocketFlow(flow: socketFlow, hostname: hostname))
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
        let flowsToDrop = trackedSocketFlows
            .filter { nextPolicy.blocks(hostname: $0.hostname) }
            .map(\.flow)
        trackedSocketFlows.removeAll { nextPolicy.blocks(hostname: $0.hostname) }
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
