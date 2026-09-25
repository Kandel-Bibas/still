import XCTest
@testable import MixerCore

final class AppBundleTests: XCTestCase {
    func testNestedHelperResolvesToItsApp() {
        XCTAssertEqual(AppBundle.outermost(
            "/Applications/Brave Browser.app/Contents/Frameworks/B.framework/Helpers/Brave Browser Helper.app"),
            "/Applications/Brave Browser.app")
        XCTAssertEqual(AppBundle.outermost("/Applications/Music.app"), "/Applications/Music.app")
    }

    func testDaemonHasNoApp() {
        XCTAssertNil(AppBundle.outermost("/usr/sbin/systemsoundserverd"))
        XCTAssertNil(AppBundle.outermost(
            "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc"))
    }

    func testApplicationsFoldersAreUserFacing() {
        for path in ["/Applications/Safari.app", "/System/Applications/Music.app",
                     "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app",
                     "/Users/b/Applications/X.app"] {
            XCTAssertTrue(AppBundle.isUserFacing(path), path)
        }
    }

    func testSystemComponentsPackagedAsAppsAreNot() {
        for path in ["/System/Library/CoreServices/Siri.app", "/System/Library/CoreServices/PowerChime.app",
                     "/System/Volumes/Preboot/Cryptexes/OS/System/Library/CoreServices/X.app"] {
            XCTAssertFalse(AppBundle.isUserFacing(path), path)
        }
    }
}
