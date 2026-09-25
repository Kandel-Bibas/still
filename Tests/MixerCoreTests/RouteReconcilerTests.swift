import XCTest
@testable import MixerCore

final class RouteReconcilerTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)
    private let speakers = RouteDevice(uid: "speakers", handle: 40, name: "Speakers")
    private let headphones = RouteDevice(uid: "headphones", handle: 41, name: "Headphones")
    private var factory = FakeFactory()
    private var reconciler: RouteReconciler!

    override func setUp() {
        factory = FakeFactory()
        reconciler = RouteReconciler(factory: factory, idleGrace: 10, stallTimeout: 5)
        reconciler.enabled = true
        reconciler.devices = [speakers, headphones]
        reconciler.defaultUID = "speakers"
    }

    // MARK: Idle grace

    func testRouteSurvivesAShortPauseWithoutRebuilding() throws {
        play("music", volume: 0.5)
        let route = try XCTUnwrap(factory.routes.first)
        XCTAssertEqual(route.deviceUID, "speakers")

        setActive("music", false, at: start)
        XCTAssertEqual(route.deviceUID, "speakers")
        XCTAssertEqual(reconciler.states["music"], .inactive)

        setActive("music", true, at: start + 3)
        XCTAssertEqual(route.starts, 1)
        XCTAssertEqual(route.holds, 0)
        XCTAssertEqual(reconciler.states["music"], .managed)
    }

    func testIdleRouteIsReleasedWhenGraceRunsOut() throws {
        play("music", volume: 0.5)
        let route = try XCTUnwrap(factory.routes.first)
        setActive("music", false, at: start)

        XCTAssertFalse(reconciler.tick(now: start + 9.9))
        XCTAssertEqual(route.deviceUID, "speakers")
        XCTAssertTrue(reconciler.tick(now: start + 10))
        XCTAssertNil(route.deviceUID)
        XCTAssertFalse(reconciler.hasRunningRoutes)
    }

    func testGraceDoesNotStartAnOutputForAnAppThatWasNeverPlaying() {
        reconciler.preferences = ["music": AppPreference(volume: 0.5)]
        reconciler.sources = [source("music", active: false)]
        reconciler.reconcile(now: start)
        XCTAssertEqual(factory.routes.count, 1)
        XCTAssertNil(factory.routes[0].deviceUID)
        XCTAssertEqual(factory.routes[0].starts, 0)
    }

    func testSleepHoldsIdleRoutesImmediately() throws {
        play("music", volume: 0.5)
        let route = try XCTUnwrap(factory.routes.first)
        setActive("music", false, at: start)
        reconciler.suspend()
        reconciler.reconcile(now: start + 1)
        XCTAssertNil(route.deviceUID)
    }

    // MARK: Existing behaviour

    func testUntouchedAppGetsNoTap() {
        reconciler.sources = [source("music", active: true)]
        reconciler.reconcile(now: start)
        XCTAssertTrue(factory.routes.isEmpty)
        XCTAssertEqual(reconciler.states["music"], .direct)
    }

    func testMissingDeviceKeepsTheTapButNoOutput() {
        reconciler.preferences = ["music": AppPreference(outputUID: "usb", outputName: "Headphones")]
        reconciler.sources = [source("music", active: true)]
        reconciler.reconcile(now: start)
        XCTAssertEqual(factory.routes.count, 1)
        XCTAssertNil(factory.routes[0].deviceUID)
        XCTAssertEqual(reconciler.states["music"], .waiting("Headphones"))
    }

    func testExplicitOutputRendersThere() {
        reconciler.preferences = ["music": AppPreference(outputUID: "headphones")]
        reconciler.sources = [source("music", active: true)]
        reconciler.reconcile(now: start)
        XCTAssertEqual(factory.routes[0].deviceUID, "headphones")
        XCTAssertEqual(factory.routes[0].gain, 1)
    }

    func testVolumeChangeAdjustsGainWithoutRestarting() {
        play("music", volume: 0.5)
        reconciler.preferences = ["music": AppPreference(volume: 0.2)]
        reconciler.reconcile(now: start + 1)
        XCTAssertEqual(factory.routes[0].starts, 1)
        XCTAssertEqual(factory.routes[0].gain, 0.2, accuracy: 0.0001)
    }

    func testFailedRouteIsNotRetriedUntilAsked() {
        factory.failure = "Create audio tap failed."
        reconciler.preferences = ["music": AppPreference(volume: 0.5)]
        reconciler.sources = [source("music", active: true)]
        reconciler.reconcile(now: start)
        XCTAssertEqual(reconciler.states["music"], .failed("Create audio tap failed."))
        XCTAssertEqual(factory.attempts, 1)

        reconciler.reconcile(now: start + 1)
        XCTAssertEqual(factory.attempts, 1)

        factory.failure = nil
        reconciler.retry("music")
        reconciler.reconcile(now: start + 2)
        XCTAssertEqual(factory.attempts, 2)
        XCTAssertEqual(reconciler.states["music"], .managed)
    }

    func testDisablingReleasesEveryTap() {
        play("music", volume: 0.5)
        weak var released = factory.routes.first
        factory.routes.removeAll()
        reconciler.enabled = false
        reconciler.reconcile(now: start + 1)
        XCTAssertNil(released)
        XCTAssertEqual(reconciler.states["music"], .direct)
    }

    func testAppThatQuitLosesItsTap() {
        play("music", volume: 0.5)
        weak var released = factory.routes.first
        factory.routes.removeAll()
        reconciler.sources = []
        reconciler.reconcile(now: start + 1)
        XCTAssertNil(released)
    }

    func testStalledCallbacksFailTheRoute() {
        play("music", volume: 0.5)
        XCTAssertFalse(reconciler.tick(now: start + 5))
        XCTAssertTrue(reconciler.tick(now: start + 5.1))
        XCTAssertNil(factory.routes[0].deviceUID)
        guard case .failed = reconciler.states["music"] else { return XCTFail("expected failure") }
    }

    func testRenderingRouteIsNotStalled() {
        play("music", volume: 0.5)
        factory.routes[0].renderCount = 100
        XCTAssertFalse(reconciler.tick(now: start + 6))
        XCTAssertEqual(factory.routes[0].deviceUID, "speakers")
    }

    func testInvalidationHoldsAndAsksForRefresh() {
        var refreshes = 0
        reconciler.onInvalidated = { refreshes += 1 }
        play("music", volume: 0.5)
        factory.routes[0].invalidated?()
        XCTAssertNil(factory.routes[0].deviceUID)
        XCTAssertEqual(refreshes, 1)
    }

    func testInvalidationFromAReplacedRouteIsIgnored() {
        var refreshes = 0
        reconciler.onInvalidated = { refreshes += 1 }
        play("music", volume: 0.5)
        let stale = factory.routes[0].invalidated
        reconciler.sources = [RouteSource(id: "music", name: "music", processes: [7, 8], active: true)]
        reconciler.reconcile(now: start + 1)
        XCTAssertEqual(factory.routes.count, 2)
        stale?()
        XCTAssertEqual(refreshes, 0)
        XCTAssertEqual(factory.routes[1].deviceUID, "speakers")
    }

    func testMeteringAppliesToRoutesStartedLater() {
        reconciler.setMetering(true)
        play("music", volume: 0.5)
        XCTAssertTrue(factory.routes[0].metering)
        factory.routes[0].outputPeak = 0.3
        XCTAssertEqual(reconciler.outputPeaks(), ["music": 0.3])
    }

    // MARK: Helpers

    private func source(_ id: String, active: Bool) -> RouteSource {
        RouteSource(id: id, name: id, processes: [7], active: active)
    }

    private func play(_ id: String, volume: Double) {
        reconciler.preferences = [id: AppPreference(volume: volume)]
        reconciler.sources = [source(id, active: true)]
        reconciler.reconcile(now: start)
    }

    private func setActive(_ id: String, _ active: Bool, at now: Date) {
        reconciler.sources = [source(id, active: active)]
        reconciler.reconcile(now: now)
    }
}

private final class FakeRoute: ManagedRoute {
    let processes: [UInt32]
    var deviceUID: String?
    var cleanupError: String?
    var renderCount: UInt64 = 0
    var faultCount: UInt64 = 0
    var outputPeak: Float = 0
    var gain: Float = -1
    var metering = false
    var starts = 0
    var holds = 0
    var invalidated: (() -> Void)?

    init(processes: [UInt32]) { self.processes = processes }

    func start(device: RouteDevice, gain: Float, invalidated: @escaping () -> Void) throws {
        starts += 1
        deviceUID = device.uid
        self.gain = gain
        self.invalidated = invalidated
    }

    func hold() {
        if deviceUID != nil { holds += 1 }
        deviceUID = nil
    }

    func setGain(_ gain: Float) { self.gain = gain }
    func setMetering(_ enabled: Bool) { metering = enabled }
}

private final class FakeFactory: RouteFactory {
    var routes: [FakeRoute] = []
    var failure: String?
    var attempts = 0

    func makeRoute(for source: RouteSource) throws -> ManagedRoute {
        attempts += 1
        if let failure { throw ReconcileError(message: failure) }
        let route = FakeRoute(processes: source.processes)
        routes.append(route)
        return route
    }
}
