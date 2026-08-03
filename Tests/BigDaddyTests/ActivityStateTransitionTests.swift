import XCTest
@testable import BigDaddy

final class ActivityStateTransitionTests: XCTestCase {
    func testActiveInputStaysActive() {
        XCTAssertEqual(ActivityStateTransition.resolve(previouslyIdle: false, isIdle: false), .active)
    }

    func testIdleInputEntersIdle() {
        XCTAssertEqual(ActivityStateTransition.resolve(previouslyIdle: false, isIdle: true), .enteredIdle)
    }

    func testIdleToActiveIsAResumeTransition() {
        XCTAssertEqual(ActivityStateTransition.resolve(previouslyIdle: true, isIdle: false), .resumed)
    }

    func testIdleStaysIdle() {
        XCTAssertEqual(ActivityStateTransition.resolve(previouslyIdle: true, isIdle: true), .idle)
    }
}
