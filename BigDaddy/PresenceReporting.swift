import Foundation

extension EventType {
    var needsActivityDetails: Bool {
        switch self {
        case .heartbeat, .appSwitch, .configUpdated, .commandAck:
            return true
        default:
            return false
        }
    }

    static func currentPresence(isSleeping: Bool, isLocked: Bool, isIdle: Bool) -> EventType {
        if isSleeping { return .sleep }
        if isLocked { return .screenLock }
        return isIdle ? .idle : .resume
    }
}
