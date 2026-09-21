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
    private var preferences: [String: AppPreference] = [:]
    private var enabled = false
    private var suspended = false
    private var stopped = false
    private var applications: [AudioApplication] = []
    private var devices: [OutputDevice] = []
    private var defaultUID: String?
    private var routes: [String: AudioRoute] = [:]
    private var errors: [String: String] = [:]
    private var failedKeys: [String: String] = [:]
    private var states: [String: RouteState] = [:]
    private var listeners: [AudioListener] = []
    private var processListeners: [AudioObjectID: [AudioListener]] = [:]
    private var refreshPending = false
    private var healthTimer: DispatchSourceTimer?
    private var lastProgress: [String: (count: UInt64, time: Date)] = [:]
    var onSnapshot: ((EngineSnapshot) -> Void)?

    func start(enabled: Bool, preferences: [String: AppPreference]) {
        queue.async { [self] in
            self.enabled = enabled
            self.preferences = preferences
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
            self.enabled = enabled
            self.preferences = preferences
            if !enabled { routes.removeAll(); errors.removeAll(); failedKeys.removeAll() }
            reconcile()
            publish()
        }
    }

    func refresh() { queue.async { [weak self] in self?.refreshNow() } }

    func retry(_ id: String) {
        queue.async { [self] in
            errors[id] = nil
            failedKeys[id] = nil
            routes[id]?.hold()
            refreshNow()
        }
    }

    func sleep() {
        queue.async { [self] in
            suspended = true
            routes.values.forEach { $0.hold() }
            updateHealthTimer()
        }
    }

    func wake() {
        queue.async { [self] in
            suspended = false
            failedKeys.removeAll()
            errors.removeAll()
            refreshNow()
        }
    }

    func stop() {
        queue.sync {
            stopped = true
            listeners.removeAll()
            processListeners.removeAll()
            healthTimer?.cancel()
            healthTimer = nil
            routes.removeAll()
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
        let appIDs = Set(applications.map(\.id))
        for id in routes.keys where !appIDs.contains(id) {
            routes[id] = nil
            failedKeys[id] = nil
            errors[id] = nil
            lastProgress[id] = nil
        }
        states.removeAll(keepingCapacity: true)
        let available = Set(devices.map(\.id))
        for app in applications {
            let preference = preferences[app.id] ?? AppPreference()
            let decision = RoutingPolicy.decide(enabled: enabled, preference: preference,
                availableUIDs: available, defaultUID: defaultUID)
            if decision == .direct {
                routes[app.id] = nil
                errors[app.id] = nil
                failedKeys[app.id] = nil
                states[app.id] = app.active ? .direct : .inactive
                continue
            }
            guard !app.processes.isEmpty else {
                states[app.id] = .inactive
                continue
            }
            let target: OutputDevice?
            if case .render(let uid) = decision { target = devices.first { $0.id == uid } }
            else { target = nil }
            let key = "\(app.processes)-\(target?.id ?? "waiting")-\(target?.audioID ?? 0)"
            if failedKeys[app.id] == key {
                states[app.id] = .failed(errors[app.id] ?? "Audio route failed. Retry to resume.")
                continue
            }
            do {
                if routes[app.id]?.processes != app.processes {
                    let newRoute = try AudioRoute(app: app)
                    routes[app.id] = newRoute
                }
                guard let route = routes[app.id] else { continue }
                if suspended || target == nil || !app.active {
                    route.hold()
                    if let cleanupError = route.cleanupError { throw EngineError.message(cleanupError) }
                    states[app.id] = target == nil ? .waiting(preference.outputName ?? "an audio output") : .inactive
                } else if let target {
                    if route.deviceUID != target.id {
                        try route.start(device: target, gain: preference.gain, queue: queue) { [weak self, weak route] in
                            guard let self, let route, self.routes[app.id] === route else { return }
                            route.hold()
                            self.failedKeys[app.id] = nil
                            self.scheduleRefresh()
                        }
                        lastProgress[app.id] = (0, Date())
                    } else { route.setGain(preference.gain) }
                    states[app.id] = .managed
                }
                errors[app.id] = nil
                failedKeys[app.id] = nil
            } catch {
                routes[app.id]?.hold()
                let message = error.localizedDescription
                errors[app.id] = message
                failedKeys[app.id] = key
                states[app.id] = .failed(message)
                HAL.log.error("Route failed: \(message, privacy: .public)")
            }
        }
        updateHealthTimer()
    }

    private func updateHealthTimer() {
        let running = routes.values.contains { $0.deviceUID != nil }
        guard running, !suspended else {
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
        var changed = false
        for app in applications {
            guard let route = routes[app.id], route.deviceUID != nil else { continue }
            let now = Date()
            let count = route.renderCount
            let previous = lastProgress[app.id] ?? (count: 0, time: now)
            if count != previous.count || !app.active { lastProgress[app.id] = (count, now) }
            let stalled = app.active && count == previous.count && now.timeIntervalSince(previous.time) > 5
            guard route.faultCount > 0 || stalled else { continue }
            let uid = route.deviceUID ?? "waiting"
            let target = devices.first { $0.id == uid }
            let key = "\(app.processes)-\(uid)-\(target?.audioID ?? 0)"
            let message = stalled
                ? "No audio callbacks arrived. Check System Audio Recording permission, then retry."
                : "The audio format changed unexpectedly. Audio is muted; retry to rebuild the route."
            route.hold()
            errors[app.id] = message
            failedKeys[app.id] = key
            states[app.id] = .failed(message)
            HAL.log.error("\(message, privacy: .public)")
            changed = true
        }
        if changed { updateHealthTimer(); publish() }
    }

    private func publish(error: String? = nil) {
        onSnapshot?(EngineSnapshot(applications: applications, devices: devices,
            defaultUID: defaultUID, states: states, error: error))
    }
}
