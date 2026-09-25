import Foundation

public enum RouteState: Equatable, Sendable {
    case inactive
    case direct
    case managed
    case waiting(String)
    case failed(String)

    public var label: String {
        switch self {
        case .inactive: return "Ready when audio starts"
        case .direct: return "Original audio"
        case .managed: return "Controlled by Still"
        case .waiting(let name): return "Muted · Waiting for \(name)"
        case .failed(let message): return message
        }
    }
}

/// One application's audio processes, as the engine last scanned them.
public struct RouteSource: Equatable, Sendable {
    public var id: String
    public var name: String
    public var processes: [UInt32]
    public var active: Bool

    public init(id: String, name: String, processes: [UInt32], active: Bool) {
        self.id = id
        self.name = name
        self.processes = processes
        self.active = active
    }
}

/// An output device a route can render to. `handle` is the Core Audio object ID, which
/// changes when a device reconnects even though `uid` does not.
public struct RouteDevice: Equatable, Sendable {
    public var uid: String
    public var handle: UInt32
    public var name: String

    public init(uid: String, handle: UInt32, name: String) {
        self.uid = uid
        self.handle = handle
        self.name = name
    }
}

/// A process tap plus an optional running output. Creating one mutes the source app;
/// `hold` stops the output but keeps the tap, so the app stays muted.
public protocol ManagedRoute: AnyObject {
    var processes: [UInt32] { get }
    /// The device currently rendering, or nil while held.
    var deviceUID: String? { get }
    /// Set when a previous output could not be torn down; the route must not restart.
    var cleanupError: String? { get }
    var renderCount: UInt64 { get }
    var faultCount: UInt64 { get }
    var outputPeak: Float { get }
    func start(device: RouteDevice, gain: Float, invalidated: @escaping () -> Void) throws
    func hold()
    func setGain(_ gain: Float)
    func setMetering(_ enabled: Bool)
}

public protocol RouteFactory {
    func makeRoute(for source: RouteSource) throws -> ManagedRoute
}

/// Decides which apps get a tap and where each one renders. Not thread-safe: the owner
/// serialises every call, and `invalidated` callbacks must arrive on that same context.
public final class RouteReconciler {
    public var enabled = false
    public var suspended = false
    public var preferences: [String: AppPreference] = [:]
    public var sources: [RouteSource] = []
    public var devices: [RouteDevice] = []
    public var defaultUID: String?
    /// Called after a running route was invalidated by a device or format change.
    public var onInvalidated: (() -> Void)?
    public private(set) var states: [String: RouteState] = [:]

    /// How long a route keeps rendering after its app goes quiet. Rebuilding the output
    /// takes long enough that the start of the next sound would be lost behind the tap.
    public let idleGrace: TimeInterval
    public let stallTimeout: TimeInterval
    private let factory: RouteFactory
    private var routes: [String: ManagedRoute] = [:]
    private var errors: [String: String] = [:]
    private var failedKeys: [String: String] = [:]
    private var lastProgress: [String: (count: UInt64, time: Date)] = [:]
    private var idleSince: [String: Date] = [:]
    private var metering = false

    public init(factory: RouteFactory, idleGrace: TimeInterval = 10, stallTimeout: TimeInterval = 5) {
        self.factory = factory
        self.idleGrace = idleGrace
        self.stallTimeout = stallTimeout
    }

    public var hasRunningRoutes: Bool { routes.values.contains { $0.deviceUID != nil } }

    public func reconcile(now: Date) {
        let sourceIDs = Set(sources.map(\.id))
        for id in routes.keys where !sourceIDs.contains(id) { forget(id) }
        states.removeAll(keepingCapacity: true)
        let available = Set(devices.map(\.uid))
        for source in sources {
            let preference = preferences[source.id] ?? AppPreference()
            let decision = RoutingPolicy.decide(enabled: enabled, preference: preference,
                availableUIDs: available, defaultUID: defaultUID)
            if decision == .direct {
                forget(source.id)
                states[source.id] = source.active ? .direct : .inactive
                continue
            }
            guard !source.processes.isEmpty else {
                states[source.id] = .inactive
                continue
            }
            let target: RouteDevice?
            if case .render(let uid) = decision { target = devices.first { $0.uid == uid } }
            else { target = nil }
            let key = failureKey(source, deviceUID: target?.uid)
            if failedKeys[source.id] == key {
                states[source.id] = .failed(errors[source.id] ?? "Audio route failed. Retry to resume.")
                continue
            }
            if source.active { idleSince[source.id] = nil }
            else if idleSince[source.id] == nil { idleSince[source.id] = now }
            do {
                if routes[source.id]?.processes != source.processes {
                    routes[source.id] = try factory.makeRoute(for: source)
                }
                guard let route = routes[source.id] else { continue }
                if let target, !suspended, source.active || isWarm(source.id, route, target, now: now) {
                    if route.deviceUID != target.uid {
                        try route.start(device: target, gain: preference.gain,
                                        invalidated: invalidation(for: source.id, route))
                        route.setMetering(metering)
                        lastProgress[source.id] = (0, now)
                    } else { route.setGain(preference.gain) }
                    states[source.id] = source.active ? .managed : .inactive
                } else {
                    route.hold()
                    if let cleanupError = route.cleanupError { throw ReconcileError(message: cleanupError) }
                    states[source.id] = target == nil ? .waiting(preference.outputName ?? "an audio output") : .inactive
                }
                errors[source.id] = nil
                failedKeys[source.id] = nil
            } catch {
                routes[source.id]?.hold()
                errors[source.id] = error.localizedDescription
                failedKeys[source.id] = key
                states[source.id] = .failed(error.localizedDescription)
            }
        }
    }

    /// Periodic check while any route renders: releases routes whose idle grace ran out
    /// and fails routes that stalled or faulted. Returns true if any route changed.
    @discardableResult
    public func tick(now: Date) -> Bool {
        var changed = false
        for source in sources {
            guard let route = routes[source.id], let uid = route.deviceUID else { continue }
            if !source.active, let since = idleSince[source.id], now.timeIntervalSince(since) >= idleGrace {
                route.hold()
                changed = true
                continue
            }
            let count = route.renderCount
            let previous = lastProgress[source.id] ?? (count: count, time: now)
            if count != previous.count || !source.active { lastProgress[source.id] = (count, now) }
            let stalled = source.active && count == previous.count
                && now.timeIntervalSince(previous.time) > stallTimeout
            guard route.faultCount > 0 || stalled else { continue }
            let message = stalled
                ? "No audio callbacks arrived. Check System Audio Recording permission, then retry."
                : "The audio format changed unexpectedly. Audio is muted; retry to rebuild the route."
            route.hold()
            errors[source.id] = message
            failedKeys[source.id] = failureKey(source, deviceUID: uid)
            states[source.id] = .failed(message)
            changed = true
        }
        return changed
    }

    /// Clears a failure so the next reconcile rebuilds the route.
    public func retry(_ id: String) {
        errors[id] = nil
        failedKeys[id] = nil
        routes[id]?.hold()
    }

    /// Stops every output but keeps taps, so managed apps stay muted through sleep.
    public func suspend() {
        suspended = true
        routes.values.forEach { $0.hold() }
    }

    public func resume() {
        suspended = false
        errors.removeAll()
        failedKeys.removeAll()
    }

    /// Releases every tap, handing each app its original audio back.
    public func releaseAll() {
        for id in Array(routes.keys) { forget(id) }
        errors.removeAll()
        failedKeys.removeAll()
    }

    public func setMetering(_ enabled: Bool) {
        metering = enabled
        routes.values.forEach { $0.setMetering(enabled) }
    }

    /// Output peak (0...1) of each app whose route is rendering.
    public func outputPeaks() -> [String: Float] {
        routes.compactMapValues { $0.deviceUID == nil ? nil : $0.outputPeak }
    }

    private func isWarm(_ id: String, _ route: ManagedRoute, _ target: RouteDevice, now: Date) -> Bool {
        guard route.deviceUID == target.uid, let since = idleSince[id] else { return false }
        return now.timeIntervalSince(since) < idleGrace
    }

    private func invalidation(for id: String, _ route: ManagedRoute) -> () -> Void {
        { [weak self, weak route] in
            guard let self, let route, self.routes[id] === route else { return }
            route.hold()
            self.failedKeys[id] = nil
            self.onInvalidated?()
        }
    }

    private func failureKey(_ source: RouteSource, deviceUID: String?) -> String {
        let handle = devices.first { $0.uid == deviceUID }?.handle ?? 0
        return "\(source.processes)-\(deviceUID ?? "waiting")-\(handle)"
    }

    private func forget(_ id: String) {
        routes[id] = nil
        errors[id] = nil
        failedKeys[id] = nil
        lastProgress[id] = nil
        idleSince[id] = nil
    }
}

struct ReconcileError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
