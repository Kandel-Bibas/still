import CoreAudio
import Foundation
import MixerCore

struct EngineSnapshot {
    var applications: [AudioApplication]
    var devices: [OutputDevice]
    var defaultUID: String?
    var states: [String: RouteState]
    var error: String?
}

final class EngineService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.bibaskandel.Still.audio-control", qos: .userInitiated)
    private let reconciler: RouteReconciler
    private var stopped = false
    private var applications: [AudioApplication] = []
    private var devices: [OutputDevice] = []
    private var defaultUID: String?
    private var listeners: [AudioListener] = []
    private var processListeners: [AudioObjectID: [AudioListener]] = [:]
    private var refreshPending = false
    private var healthTimer: DispatchSourceTimer?
    var onSnapshot: ((EngineSnapshot) -> Void)?

    init() {
        reconciler = RouteReconciler(factory: HALRouteFactory(queue: queue))
        reconciler.onInvalidated = { [weak self] in self?.scheduleRefresh() }
    }

    func start(enabled: Bool, preferences: [String: AppPreference]) {
        queue.async { [self] in
            reconciler.enabled = enabled
            reconciler.preferences = preferences
            do {
                for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice,
                                 kAudioHardwarePropertyProcessObjectList] {
                    listeners.append(try AudioListener(object: HAL.system, selector: selector, queue: queue) { [weak self] in
                        self?.scheduleRefresh()
                    })
                }
                refreshNow()
            } catch { publish(error: error.localizedDescription) }
        }
    }

    func update(enabled: Bool, preferences: [String: AppPreference]) {
        queue.async { [self] in
            reconciler.enabled = enabled
            reconciler.preferences = preferences
            if !enabled { reconciler.releaseAll() }
            reconcile()
            publish()
        }
    }

    func refresh() { queue.async { [weak self] in self?.refreshNow() } }

    func retry(_ id: String) {
        queue.async { [self] in
            reconciler.retry(id)
            refreshNow()
        }
    }

    func sleep() {
        queue.async { [self] in
            reconciler.suspend()
            updateHealthTimer()
        }
    }

    func wake() {
        queue.async { [self] in
            reconciler.resume()
            refreshNow()
        }
    }

    /// Output levels are only measured while something shows them.
    func setMetering(_ enabled: Bool) {
        queue.async { [self] in reconciler.setMetering(enabled) }
    }

    /// Reads the latest output peak of every rendering app on the control queue, where
    /// routes are torn down, and delivers them to `completion` on the main queue.
    func readLevels(_ completion: @escaping @Sendable ([String: Float]) -> Void) {
        queue.async { [self] in
            let peaks = reconciler.outputPeaks()
            DispatchQueue.main.async { completion(peaks) }
        }
    }

    func stop() {
        queue.sync {
            stopped = true
            listeners.removeAll()
            processListeners.removeAll()
            healthTimer?.cancel()
            healthTimer = nil
            reconciler.releaseAll()
        }
    }

    private func scheduleRefresh() {
        guard !refreshPending, !stopped else { return }
        refreshPending = true
        queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.refreshPending = false
            self.refreshNow()
        }
    }

    private func refreshNow() {
        guard !stopped else { return }
        do {
            devices = try HAL.outputDevices()
            let defaultID = try HAL.value(HAL.system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(0))
            defaultUID = devices.first(where: { $0.audioID == defaultID })?.id
            let scan = try ProcessCatalog.scan()
            var discovered = scan.applications
            let accounted = Set(discovered.flatMap(\.processes))
            for previous in applications {
                let uncertain = previous.processes.filter { scan.processObjects.contains($0) && !accounted.contains($0) }
                guard !uncertain.isEmpty else { continue }
                if let index = discovered.firstIndex(where: { $0.id == previous.id }) {
                    discovered[index].processes += uncertain
                    discovered[index].processes.sort()
                    discovered[index].active = discovered[index].active || previous.active
                } else {
                    var retained = previous
                    retained.processes = uncertain
                    discovered.append(retained)
                }
            }
            applications = discovered
            let ids = scan.processObjects
            for id in processListeners.keys where !ids.contains(id) { processListeners[id] = nil }
            for id in ids where processListeners[id] == nil {
                do {
                    // CoreAudio can change IsRunningOutput while notifying only IsRunning.
                    // Keep both notifications; the scan still reads output activity specifically.
                    processListeners[id] = try [kAudioProcessPropertyIsRunning, kAudioProcessPropertyIsRunningOutput].map { selector in
                        try AudioListener(object: id, selector: selector, queue: queue) { [weak self] in
                            self?.scheduleRefresh()
                        }
                    }
                } catch {
                    HAL.log.notice("Unable to watch a process: \(error.localizedDescription, privacy: .public)")
                }
            }
            reconcile()
            publish()
        } catch { publish(error: error.localizedDescription) }
    }

    private func reconcile() {
        guard !stopped else { return }
        reconciler.sources = applications.map {
            RouteSource(id: $0.id, name: $0.name, processes: $0.processes, active: $0.active)
        }
        reconciler.devices = devices.map { RouteDevice(uid: $0.id, handle: $0.audioID, name: $0.name) }
        reconciler.defaultUID = defaultUID
        let before = reconciler.states
        reconciler.reconcile(now: Date())
        logNewFailures(since: before)
        updateHealthTimer()
    }

    private func updateHealthTimer() {
        guard reconciler.hasRunningRoutes, !reconciler.suspended else {
            healthTimer?.cancel()
            healthTimer = nil
            return
        }
        guard healthTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.checkHealth() }
        healthTimer = timer
        timer.resume()
    }

    private func checkHealth() {
        let before = reconciler.states
        guard reconciler.tick(now: Date()) else { return }
        logNewFailures(since: before)
        updateHealthTimer()
        publish()
    }

    private func logNewFailures(since before: [String: RouteState]) {
        for (id, state) in reconciler.states where before[id] != state {
            if case .failed(let message) = state {
                HAL.log.error("Route for \(id, privacy: .public) failed: \(message, privacy: .public)")
            }
        }
    }

    private func publish(error: String? = nil) {
        onSnapshot?(EngineSnapshot(applications: applications, devices: devices,
            defaultUID: defaultUID, states: reconciler.states, error: error))
    }
}

private struct HALRouteFactory: RouteFactory {
    let queue: DispatchQueue

    func makeRoute(for source: RouteSource) throws -> ManagedRoute {
        HALRoute(route: try AudioRoute(app: AudioApplication(id: source.id, name: source.name,
            bundleURL: nil, processes: source.processes, active: source.active)), queue: queue)
    }
}

/// Adapts AudioRoute to the reconciler; invalidation callbacks arrive on the control queue.
private final class HALRoute: ManagedRoute {
    private let route: AudioRoute
    private let queue: DispatchQueue

    init(route: AudioRoute, queue: DispatchQueue) {
        self.route = route
        self.queue = queue
    }

    var processes: [UInt32] { route.processes }
    var deviceUID: String? { route.deviceUID }
    var cleanupError: String? { route.cleanupError }
    var renderCount: UInt64 { route.renderCount }
    var faultCount: UInt64 { route.faultCount }
    var outputPeak: Float { route.outputPeak }

    func start(device: RouteDevice, gain: Float, invalidated: @escaping () -> Void) throws {
        try route.start(device: OutputDevice(id: device.uid, audioID: device.handle, name: device.name, symbol: ""),
                        gain: gain, queue: queue, invalidated: invalidated)
    }

    func hold() { route.hold() }
    func setGain(_ gain: Float) { route.setGain(gain) }
    func setMetering(_ enabled: Bool) { route.setMetering(enabled) }
}
