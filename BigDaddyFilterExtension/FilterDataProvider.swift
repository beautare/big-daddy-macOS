import Foundation
import NetworkExtension

final class FilterDataProvider: NEFilterDataProvider {
    private let policyLock = NSLock()
    private var policy: WebFilterPolicySnapshot?
    private var providerStatus: WebFilterProviderStatus?
    private var nextPolicyReloadAt: TimeInterval = 0

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        reloadPolicy()
        completionHandler(nil)
    }

    override func stopFilter(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
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

        let now = ProcessInfo.processInfo.systemUptime
        if now >= nextPolicyReloadAt {
            reloadPolicyLocked()
            nextPolicyReloadAt = now + 1
        }
        return policy!
    }

    private func reloadPolicy() {
        policyLock.lock()
        reloadPolicyLocked()
        nextPolicyReloadAt = ProcessInfo.processInfo.systemUptime + 1
        policyLock.unlock()
    }

    private func reloadPolicyLocked() {
        let loadedPolicy = try? WebFilterSharedStore.loadPolicy()
        if policy == nil {
            policy = loadedPolicy ?? WebFilterPolicySnapshot(
                configuration: WebFilterConfiguration(),
                isDeviceBound: false,
                appliedAt: Date(timeIntervalSince1970: 0)
            )
        } else if let loadedPolicy {
            policy = loadedPolicy
        }

        let current = policy!
        let status = WebFilterProviderStatus(
            systemExtensionState: .approved,
            enforcementState: current.enabled ? .enforcing : .passThrough,
            appliedRevision: current.revision,
            ruleCount: current.blockedDomains.count,
            lastAppliedAt: Date()
        )
        guard providerStatus.map({ status.hasSamePolicyState(as: $0) }) != true else { return }
        do {
            try WebFilterSharedStore.saveStatus(status)
            providerStatus = status
        } catch {
            NSLog("BigDaddyWebFilter: provider status could not be stored: \(error.localizedDescription)")
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
