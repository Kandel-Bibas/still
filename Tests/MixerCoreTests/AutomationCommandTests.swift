import XCTest
@testable import MixerCore

final class AutomationCommandTests: XCTestCase {

    // MARK: Volume

    func testVolumeParsesIntegerPercent() throws {
        let command = try AutomationCommand.parse(url("still://volume?app=Music&value=30"))
        XCTAssertEqual(command, .volume(app: "Music", percent: 30))
    }

    func testVolumeParsesDecimalPercent() throws {
        let command = try AutomationCommand.parse(url("still://volume?app=Music&value=12.5"))
        XCTAssertEqual(command, .volume(app: "Music", percent: 12.5))
    }

    func testVolumeAcceptsTheBoundaries() throws {
        XCTAssertEqual(try AutomationCommand.parse(url("still://volume?app=Music&value=0")), .volume(app: "Music", percent: 0))
        XCTAssertEqual(try AutomationCommand.parse(url("still://volume?app=Music&value=100")), .volume(app: "Music", percent: 100))
    }

    func testVolumeMissingValueIsAnError() {
        assertThrows(url("still://volume?app=Music"), .missingValue)
    }

    func testVolumeNonNumericValueIsAnError() {
        assertThrows(url("still://volume?app=Music&value=loud"), .invalidValue("loud"))
    }

    func testVolumeOutOfRangeIsAnErrorNotAClamp() {
        assertThrows(url("still://volume?app=Music&value=101"), .valueOutOfRange("101"))
        assertThrows(url("still://volume?app=Music&value=-1"), .valueOutOfRange("-1"))
    }

    func testVolumeRejectsNaN() {
        assertThrows(url("still://volume?app=Music&value=nan"), .invalidValue("nan"))
    }

    func testVolumeRejectsInfinity() {
        assertThrows(url("still://volume?app=Music&value=infinity"), .invalidValue("infinity"))
    }

    // MARK: Mute

    func testMuteDefaultsToToggle() throws {
        let command = try AutomationCommand.parse(url("still://mute?app=Music"))
        XCTAssertEqual(command, .mute(app: "Music", state: .toggle))
    }

    func testMuteParsesOnOffToggle() throws {
        XCTAssertEqual(try AutomationCommand.parse(url("still://mute?app=Music&state=on")), .mute(app: "Music", state: .on))
        XCTAssertEqual(try AutomationCommand.parse(url("still://mute?app=Music&state=off")), .mute(app: "Music", state: .off))
        XCTAssertEqual(try AutomationCommand.parse(url("still://mute?app=Music&state=toggle")), .mute(app: "Music", state: .toggle))
    }

    func testMuteStateIsCaseInsensitive() throws {
        XCTAssertEqual(try AutomationCommand.parse(url("still://mute?app=Music&state=ON")), .mute(app: "Music", state: .on))
    }

    func testMuteUnknownStateIsAnError() {
        assertThrows(url("still://mute?app=Music&state=maybe"), .unknownMuteState("maybe"))
    }

    // MARK: Output

    func testOutputParsesADeviceName() throws {
        let command = try AutomationCommand.parse(url("still://output?app=Music&device=Headphones"))
        XCTAssertEqual(command, .output(app: "Music", device: "Headphones"))
    }

    func testOutputSystemMeansNilDevice() throws {
        let command = try AutomationCommand.parse(url("still://output?app=Music&device=system"))
        XCTAssertEqual(command, .output(app: "Music", device: nil))
    }

    func testOutputSystemIsCaseInsensitive() throws {
        let command = try AutomationCommand.parse(url("still://output?app=Music&device=SYSTEM"))
        XCTAssertEqual(command, .output(app: "Music", device: nil))
    }

    func testOutputMissingDeviceIsAnError() {
        assertThrows(url("still://output?app=Music"), .missingDevice)
    }

    // MARK: Command and scheme

    func testWrongSchemeIsAnError() {
        assertThrows(url("shortcuts://volume?app=Music&value=30"), .wrongScheme("shortcuts"))
    }

    func testMissingCommandIsAnError() {
        assertThrows(url("still://?app=Music&value=30"), .unknownCommand(nil))
    }

    func testUnknownCommandIsAnError() {
        assertThrows(url("still://pause?app=Music"), .unknownCommand("pause"))
    }

    // MARK: App

    func testMissingAppIsAnError() {
        assertThrows(url("still://volume?value=30"), .missingApp)
    }

    func testEmptyAppIsAnError() {
        assertThrows(url("still://volume?app=&value=30"), .missingApp)
    }

    func testPercentEncodedAppNameIsDecoded() throws {
        let command = try AutomationCommand.parse(url("still://volume?app=Google%20Chrome&value=50"))
        XCTAssertEqual(command, .volume(app: "Google Chrome", percent: 50))
    }

    // MARK: Error messages are user-readable

    func testErrorDescriptionsAreSpecific() {
        XCTAssertEqual(AutomationCommandError.wrongScheme("shortcuts").errorDescription,
            "Still only understands still:// URLs, not shortcuts://.")
        XCTAssertEqual(AutomationCommandError.unknownCommand("pause").errorDescription,
            "Unknown command 'pause'. Use volume, mute, or output.")
        XCTAssertEqual(AutomationCommandError.missingApp.errorDescription,
            "Missing 'app' in the still:// URL.")
        XCTAssertEqual(AutomationCommandError.missingValue.errorDescription,
            "Missing 'value' in the still:// URL.")
        XCTAssertEqual(AutomationCommandError.invalidValue("loud").errorDescription,
            "'loud' is not a number.")
        XCTAssertEqual(AutomationCommandError.valueOutOfRange("101").errorDescription,
            "Volume must be between 0 and 100, got 101.")
        XCTAssertEqual(AutomationCommandError.unknownMuteState("maybe").errorDescription,
            "Unknown mute state 'maybe'. Use on, off, or toggle.")
        XCTAssertEqual(AutomationCommandError.missingDevice.errorDescription,
            "Missing 'device' in the still:// URL.")
    }

    // MARK: Matching

    func testMatchPrefersAnExactIDOverAnyName() throws {
        let candidates: [(id: String, name: String)] = [
            ("com.apple.Music", "Music"), ("com.spotify.client", "com.apple.Music")
        ]
        XCTAssertEqual(try AutomationCommand.match("com.apple.Music", in: candidates), "com.apple.Music")
    }

    func testMatchFallsBackToACaseInsensitiveName() throws {
        let candidates: [(id: String, name: String)] = [("com.apple.Music", "Music")]
        XCTAssertEqual(try AutomationCommand.match("MUSIC", in: candidates), "com.apple.Music")
    }

    func testMatchWithZeroResultsReportsNoAppNamed() {
        let candidates: [(id: String, name: String)] = [("com.apple.Music", "Music")]
        XCTAssertThrowsError(try AutomationCommand.match("Spotify", in: candidates)) { error in
            XCTAssertEqual((error as? AutomationCommandError)?.errorDescription, "No app named \"Spotify\".")
        }
    }

    func testMatchWithMultipleNameResultsReportsAmbiguity() {
        let candidates: [(id: String, name: String)] = [
            ("com.example.chrome.a", "Chrome"), ("com.example.chrome.b", "Chrome")
        ]
        XCTAssertThrowsError(try AutomationCommand.match("chrome", in: candidates)) { error in
            guard case .ambiguous(let name, let ids, .app) = error as? AutomationCommandError else {
                return XCTFail("expected .ambiguous")
            }
            XCTAssertEqual(name, "chrome")
            XCTAssertEqual(Set(ids), Set(["com.example.chrome.a", "com.example.chrome.b"]))
            XCTAssertTrue((error as? AutomationCommandError)?.errorDescription?.contains("bundle id") == true)
        }
    }

    func testUnknownDeviceIsReportedAsADevice() {
        let candidates: [(id: String, name: String)] = [("BuiltInSpeakerDevice", "MacBook Pro Speakers")]
        XCTAssertThrowsError(try AutomationCommand.match("AirPods", in: candidates, target: .device)) { error in
            XCTAssertEqual((error as? AutomationCommandError)?.errorDescription, "No output device named \"AirPods\".")
        }
    }

    func testMatchWithNoCandidatesReportsNoAppNamed() {
        XCTAssertThrowsError(try AutomationCommand.match("Anything", in: [])) { error in
            XCTAssertEqual((error as? AutomationCommandError)?.errorDescription, "No app named \"Anything\".")
        }
    }

    // MARK: Helpers

    private func url(_ string: String) -> URL {
        guard let value = URL(string: string) else {
            XCTFail("bad test URL literal: \(string)")
            return URL(fileURLWithPath: "/dev/null")
        }
        return value
    }

    private func assertThrows(_ url: URL, _ expected: AutomationCommandError, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try AutomationCommand.parse(url), file: file, line: line) { error in
            XCTAssertEqual(error as? AutomationCommandError, expected, file: file, line: line)
        }
    }
}
