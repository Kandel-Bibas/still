import Foundation

public struct AppPreference: Codable, Equatable, Sendable {
    public var volume: Double
    public var muted: Bool
    public var pinned: Bool
    public var outputUID: String?
    public var outputName: String?
    public var appName: String?
    public var bundlePath: String?

    public init(volume: Double = 1, muted: Bool = false, pinned: Bool = false,
                outputUID: String? = nil, outputName: String? = nil,
                appName: String? = nil, bundlePath: String? = nil) {
        self.volume = Self.validVolume(volume)
        self.muted = muted
        self.pinned = pinned
        self.outputUID = outputUID
        self.outputName = outputName
        self.appName = appName
        self.bundlePath = bundlePath
    }

    public static func validVolume(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }

    /// The slider represents amplitude percentage; unity never boosts a source.
    public var gain: Float { muted ? 0 : Float(Self.validVolume(volume)) }
}

public enum RoutingDecision: Equatable, Sendable {
    case direct
    case waiting
    case render(String)
}

public enum RoutingPolicy {
    public static func decide(enabled: Bool, preference: AppPreference,
                              availableUIDs: Set<String>, defaultUID: String?) -> RoutingDecision {
        guard enabled else { return .direct }
        if let chosen = preference.outputUID {
            return availableUIDs.contains(chosen) ? .render(chosen) : .waiting
        }
        // An untouched application doesn't need a tap or extra audio I/O.
        if preference.gain == 1 { return .direct }
        guard let defaultUID, availableUIDs.contains(defaultUID) else { return .waiting }
        return .render(defaultUID)
    }
}

public struct SavedPreferences: Codable, Equatable {
    public var version: Int = 1
    public var enabled: Bool = false
    public var applications: [String: AppPreference] = [:]
    public init() {}

    public static func decode(_ data: Data) throws -> SavedPreferences {
        var value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1 else { throw PreferenceError.unsupportedVersion(value.version) }
        for key in value.applications.keys {
            guard let app = value.applications[key], app.volume.isFinite,
                  (0...1).contains(app.volume) else { throw PreferenceError.invalidVolume(key) }
            value.applications[key]?.volume = AppPreference.validVolume(app.volume)
        }
        return value
    }
}

public enum PreferenceError: LocalizedError {
    case unsupportedVersion(Int)
    case invalidVolume(String)
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): return "Settings version \(version) is not supported. Your settings were not overwritten."
        case .invalidVolume(let app): return "The saved volume for \(app) is invalid. Your settings were not overwritten."
        }
    }
}
