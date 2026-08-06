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

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        configurationObservation = observe(\.filterConfiguration, options: [.initial, .new]) { [weak self] _, _ in
            self?.reloadPolicy()
        }
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

        policyLock.lock()
        defer { policyLock.unlock() }
        guard policy == nextPolicy else { return }
        do {
            try WebFilterProviderAcknowledgementStore.save(
                WebFilterProviderAcknowledgement(policy: nextPolicy)
            )
        } catch {
            NSLog("BigDaddyWebFilter: provider acknowledgement could not be stored: \(error.localizedDescription)")
        }
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
