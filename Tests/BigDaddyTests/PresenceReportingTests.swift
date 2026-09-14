import XCTest
@testable import BigDaddy

final class PresenceReportingTests: XCTestCase {
    func testLifecycleEventsNeverWaitForBrowser() {
        for event: EventType in [.start, .idle, .resume, .screenLock, .screenUnlock,
                                 .sleep, .wake, .shutdown, .systemShutdown, .forceKill] {
            XCTAssertFalse(event.needsActivityDetails)
        }
        XCTAssertTrue(EventType.heartbeat.needsActivityDetails)
        XCTAssertTrue(EventType.appSwitch.needsActivityDetails)
    }

    func testRecoveryDoesNotReportLockedOrSleepingMacAsActive() {
        XCTAssertEqual(EventType.currentPresence(isSleeping: true, isLocked: true, isIdle: false), .sleep)
        XCTAssertEqual(EventType.currentPresence(isSleeping: false, isLocked: true, isIdle: false), .screenLock)
        XCTAssertEqual(EventType.currentPresence(isSleeping: false, isLocked: false, isIdle: true), .idle)
        XCTAssertEqual(EventType.currentPresence(isSleeping: false, isLocked: false, isIdle: false), .resume)
    }
}
