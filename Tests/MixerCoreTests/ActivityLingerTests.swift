import XCTest
@testable import MixerCore

final class ActivityLingerTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)

    func testStoppedAppLingersForTheWindowThenExpires() {
        var linger = ActivityLinger(window: 15)
        XCTAssertTrue(linger.observe("music", active: true, now: start))
        XCTAssertTrue(linger.observe("music", active: false, now: start + 14.9))
        XCTAssertFalse(linger.observe("music", active: false, now: start + 15))
    }

    func testNextExpiryIsWhenTheLingeringAppDropsOut() {
        var linger = ActivityLinger(window: 15)
        _ = linger.observe("music", active: true, now: start)
        _ = linger.observe("call", active: true, now: start + 4)
        XCTAssertEqual(linger.nextExpiry(after: start + 1), start + 15)
        XCTAssertEqual(linger.nextExpiry(after: start + 15), start + 19)
        XCTAssertNil(linger.nextExpiry(after: start + 19))
    }

    func testAppNeverSeenPlayingIsInactive() {
        var linger = ActivityLinger(window: 15)
        XCTAssertFalse(linger.observe("idle", active: false, now: start))
        XCTAssertNil(linger.nextExpiry(after: start))
    }
}
