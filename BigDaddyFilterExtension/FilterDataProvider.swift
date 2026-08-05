import Foundation
import NetworkExtension

final class FilterDataProvider: NEFilterDataProvider {
    private final class TrackedSocketFlow {
        weak var flow: NEFilterSocketFlow?
        let hostname: String

        init(flow: NEFilterSocketFlow, hostname: String) {
            self.flow = flow
            self.hostname = hostname
        }
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
        if !blocked, let socketFlow = flow as? NEFilterSocketFlow {
            trackedSocketFlows.append(TrackedSocketFlow(flow: socketFlow, hostname: hostname))
        }
        policyLock.unlock()
        return blocked ? .drop() : .allow()
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
        let flowsToDrop = trackedSocketFlows.compactMap { tracked -> NEFilterSocketFlow? in
            guard let flow = tracked.flow else { return nil }
            return nextPolicy.blocks(hostname: tracked.hostname) ? flow : nil
        }
        trackedSocketFlows.removeAll { $0.flow == nil }
        policyLock.unlock()

        for flow in flowsToDrop {
            update(flow, using: .drop(), for: .any)
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
