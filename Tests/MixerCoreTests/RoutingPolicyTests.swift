import XCTest
@testable import MixerCore

final class RoutingPolicyTests: XCTestCase {
    func testUntouchedAppBypassesEngine() {
        XCTAssertEqual(decide(AppPreference()), .direct)
    }

    func testAttenuationAndMuteUseDefaultDevice() {
        XCTAssertEqual(decide(AppPreference(volume: 0.4)), .render("speakers"))
        XCTAssertEqual(decide(AppPreference(muted: true)), .render("speakers"))
    }

    func testExplicitOutputIsRoutedAtFullVolume() {
        XCTAssertEqual(decide(AppPreference(outputUID: "headphones")), .render("headphones"))
    }

    func testMissingHeadphonesNeverFallBackToSpeakers() {
        let preference = AppPreference(volume: 0.5, outputUID: "missing")
        XCTAssertEqual(decide(preference), .waiting)
        XCTAssertEqual(RoutingPolicy.decide(enabled: true, preference: preference,
            availableUIDs: ["speakers", "missing"], defaultUID: "speakers"), .render("missing"))
    }

    func testNoDefaultDeviceWaitsForAttenuatedApp() {
        XCTAssertEqual(RoutingPolicy.decide(enabled: true, preference: AppPreference(volume: 0.2),
            availableUIDs: [], defaultUID: nil), .waiting)
    }

    func testDisablingReleasesEvenMissingRoutes() {
        XCTAssertEqual(RoutingPolicy.decide(enabled: false,
            preference: AppPreference(muted: true, outputUID: "missing"),
            availableUIDs: [], defaultUID: nil), .direct)
    }

    func testMutePreservesSavedVolume() {
        var preference = AppPreference(volume: 0.37)
        preference.muted = true
        XCTAssertEqual(preference.gain, 0)
        preference.muted = false
        XCTAssertEqual(preference.gain, 0.37, accuracy: 0.00001)
    }

    func testInvalidExternalGainCannotAmplify() {
        XCTAssertEqual(AppPreference(volume: .nan).gain, 0)
        XCTAssertEqual(AppPreference(volume: -.infinity).gain, 0)
        XCTAssertEqual(AppPreference(volume: 2).gain, 1)
        XCTAssertEqual(AppPreference(volume: -1).gain, 0)
    }

    func testSettingsRoundTripKeepsRouteAndFavorite() throws {
        var preferences = SavedPreferences()
        preferences.enabled = true
        preferences.applications["example"] = AppPreference(volume: 0.3, pinned: true,
            outputUID: "headphones", outputName: "Headphones")
        XCTAssertEqual(try SavedPreferences.decode(JSONEncoder().encode(preferences)), preferences)
    }

    func testUnsupportedOrInvalidSettingsAreRejected() {
        XCTAssertThrowsError(try SavedPreferences.decode(Data("{\"version\":2,\"enabled\":true,\"applications\":{}}".utf8)))
        XCTAssertThrowsError(try SavedPreferences.decode(Data("{\"version\":1,\"enabled\":true,\"applications\":{\"x\":{\"volume\":2,\"muted\":false,\"pinned\":false}}}".utf8)))
    }

    private func decide(_ preference: AppPreference) -> RoutingDecision {
        RoutingPolicy.decide(enabled: true, preference: preference,
            availableUIDs: ["speakers", "headphones"], defaultUID: "speakers")
    }
}
