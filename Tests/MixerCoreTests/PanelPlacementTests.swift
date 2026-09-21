import CoreGraphics
import XCTest
@testable import MixerCore

final class PanelPlacementTests: XCTestCase {
    // The built-in display, and a 1920x1080 external sitting to its right.
    private let builtIn = Display(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 949))
    private let rightExternal = Display(
        frame: CGRect(x: 1512, y: -98, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 1512, y: -98, width: 1920, height: 1047))
    private let leftExternal = Display(
        frame: CGRect(x: -1920, y: -98, width: 1920, height: 1080),
        visibleFrame: CGRect(x: -1920, y: -98, width: 1920, height: 1047))
    private let size = CGSize(width: 320, height: 300)

    private var twoDisplays: [Display] { [builtIn, rightExternal] }

    // MARK: choosing the display

    func testTheClickedDisplayWinsOverEveryOtherOne() {
        let host = PanelPlacement.host(anchor: CGPoint(x: 2760, y: 943),
                                       displays: twoDisplays, preferred: rightExternal)
        XCTAssertEqual(host, rightExternal)
    }

    func testADisconnectedPreferenceFallsBackToTheDisplayUnderTheAnchor() {
        let host = PanelPlacement.host(anchor: CGPoint(x: 2760, y: 943),
                                       displays: twoDisplays, preferred: leftExternal)
        XCTAssertEqual(host, rightExternal)
    }

    func testAnAnchorOnNoDisplayHasNoHost() {
        XCTAssertNil(PanelPlacement.host(anchor: CGPoint(x: 9000, y: 9000),
                                         displays: twoDisplays, preferred: nil))
    }

    // MARK: placing the panel

    func testPanelHangsCentredUnderTheAnchor() {
        let frame = PanelPlacement.frame(anchor: CGPoint(x: 700, y: 943),
                                         size: size, visibleFrame: builtIn.visibleFrame)
        XCTAssertEqual(frame.midX, 700)
        XCTAssertEqual(frame.maxY, 943)
    }

    /// The regression: opening from the external display used to clamp against the
    /// built-in display and land the panel there.
    func testOpeningOnAnExternalDisplayKeepsThePanelOnIt() {
        let anchor = CGPoint(x: 2760, y: 976)
        guard let host = PanelPlacement.host(anchor: anchor, displays: twoDisplays,
                                             preferred: rightExternal) else {
            return XCTFail("the external display should host the panel")
        }
        let frame = PanelPlacement.frame(anchor: anchor, size: size, visibleFrame: host.visibleFrame)
        XCTAssertEqual(frame.midX, anchor.x)
        XCTAssertGreaterThanOrEqual(frame.minX, rightExternal.frame.minX)
        XCTAssertLessThanOrEqual(frame.maxX, rightExternal.frame.maxX)
    }

    func testPanelStaysOnAnExternalDisplayToTheLeft() {
        let frame = PanelPlacement.frame(anchor: CGPoint(x: -1800, y: 976),
                                         size: size, visibleFrame: leftExternal.visibleFrame)
        XCTAssertEqual(frame.minX, leftExternal.visibleFrame.minX + 8)
        XCTAssertLessThan(frame.maxX, 0)
    }

    func testAnAnchorNearADisplayEdgePullsThePanelBackInside() {
        let frame = PanelPlacement.frame(anchor: CGPoint(x: 3420, y: 976),
                                         size: size, visibleFrame: rightExternal.visibleFrame)
        XCTAssertEqual(frame.maxX, rightExternal.visibleFrame.maxX - 8)
    }

    func testPanelTallerThanTheDisplayIsPushedDownNoFurtherThanTheBottom() {
        let tall = CGSize(width: 320, height: 2000)
        let frame = PanelPlacement.frame(anchor: CGPoint(x: 700, y: 943),
                                         size: tall, visibleFrame: builtIn.visibleFrame)
        XCTAssertEqual(frame.minY, builtIn.visibleFrame.minY + 8)
    }

    func testPanelWiderThanTheDisplayIsCentredRatherThanInverted() {
        let narrow = CGRect(x: 0, y: 0, width: 200, height: 400)
        let frame = PanelPlacement.frame(anchor: CGPoint(x: 100, y: 400),
                                         size: size, visibleFrame: narrow)
        XCTAssertEqual(frame.midX, narrow.midX)
    }
}
