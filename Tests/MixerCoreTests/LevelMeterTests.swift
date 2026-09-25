import XCTest
@testable import MixerCore

final class LevelMeterTests: XCTestCase {
    func testFullScalePeakMapsToOne() {
        XCTAssertEqual(LevelMeter.display(peak: 1, previous: 0), 1, accuracy: 0.0001)
    }

    func testFloorPeakMapsToZero() {
        XCTAssertEqual(LevelMeter.display(peak: 0.001, previous: 0), 0)
    }

    func testMidScalePeakMapsProportionally() {
        XCTAssertEqual(LevelMeter.display(peak: 0.1, previous: 0), 0.6667, accuracy: 0.001)
    }

    func testNonFiniteOrNegativePeakIsTreatedAsSilence() {
        XCTAssertEqual(LevelMeter.display(peak: .nan, previous: 0), 0)
        XCTAssertEqual(LevelMeter.display(peak: -1, previous: 0), 0)
    }

    func testMeterFallsSmoothlyFromPreviousLevel() {
        XCTAssertEqual(LevelMeter.display(peak: 0, previous: 0.5), 0.4, accuracy: 0.0001)
    }

    func testTinyResultSnapsToZero() {
        XCTAssertEqual(LevelMeter.display(peak: 0, previous: 0.001), 0)
    }
}
