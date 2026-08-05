import Foundation
import NetworkExtension

final class FilterDataProvider: NEFilterDataProvider {
    private let policyLock = NSLock()
    private var policy = WebFilterPolicySnapshot(
        configuration: WebFilterConfiguration(),
        isDeviceBound: false,
        appliedAt: Date(timeIntervalSince1970: 0)
    )
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
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        let currentPolicy = currentPolicy()
        guard let hostname = hostname(from: flow), currentPolicy.blocks(hostname: hostname) else {
            return .allow()
        }
        return .drop()
    }

    private func currentPolicy() -> WebFilterPolicySnapshot {
        policyLock.lock()
        defer { policyLock.unlock() }
        return policy
    }

    private func reloadPolicy() {
        policyLock.lock()
        policy = WebFilterPolicyTransport.policy(from: filterConfiguration.vendorConfiguration)
            ?? WebFilterPolicySnapshot(
                configuration: WebFilterConfiguration(),
                isDeviceBound: false,
                appliedAt: Date(timeIntervalSince1970: 0)
            )
        policyLock.unlock()
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
