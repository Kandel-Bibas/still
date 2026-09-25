import Foundation

/// The three things a `still://` URL can ask for.
public enum MuteState: Equatable, Sendable {
    case on
    case off
    case toggle
}

/// A parsed `still://` automation URL, ready to match against the running app's apps
/// and devices. Parsing and matching are pure so both are covered by unit tests without
/// touching `MixerStore` or Core Audio.
public enum AutomationCommand: Equatable, Sendable {
    case volume(app: String, percent: Double)
    case mute(app: String, state: MuteState)
    case output(app: String, device: String?)

    /// Parses a `still://volume|mute|output` URL. `app` matches a bundle id first, then
    /// a display name; that matching itself is `match(_:in:)`, not this parser.
    public static func parse(_ url: URL) throws -> AutomationCommand {
        guard let scheme = url.scheme, scheme.lowercased() == "still" else {
            throw AutomationCommandError.wrongScheme(url.scheme)
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let rawHost = components?.host ?? url.host
        let host = (rawHost?.isEmpty ?? true) ? nil : rawHost
        let command = (host ?? "").lowercased()
        let items = components?.queryItems ?? []
        func value(_ name: String) -> String? {
            let raw = items.first(where: { $0.name == name })?.value
            return (raw?.isEmpty ?? true) ? nil : raw
        }

        guard ["volume", "mute", "output"].contains(command) else {
            throw AutomationCommandError.unknownCommand(host)
        }
        guard let app = value("app") else {
            throw AutomationCommandError.missingApp
        }

        switch command {
        case "volume":
            guard let raw = value("value") else {
                throw AutomationCommandError.missingValue
            }
            guard let percent = Double(raw), percent.isFinite else {
                throw AutomationCommandError.invalidValue(raw)
            }
            guard (0...100).contains(percent) else {
                throw AutomationCommandError.valueOutOfRange(raw)
            }
            return .volume(app: app, percent: percent)

        case "mute":
            let raw = value("state") ?? "toggle"
            switch raw.lowercased() {
            case "on": return .mute(app: app, state: .on)
            case "off": return .mute(app: app, state: .off)
            case "toggle": return .mute(app: app, state: .toggle)
            default: throw AutomationCommandError.unknownMuteState(raw)
            }

        case "output":
            guard let raw = value("device") else {
                throw AutomationCommandError.missingDevice
            }
            return .output(app: app, device: raw.lowercased() == "system" ? nil : raw)

        default:
            throw AutomationCommandError.unknownCommand(command)
        }
    }

    public enum Target: String, Sendable {
        case app
        case device
    }

    /// Resolves `query` to a candidate's id: an exact id match wins, otherwise a
    /// case-insensitive name match. Used for both apps (id + display name) and output
    /// devices (id + device name).
    public static func match(_ query: String, in candidates: [(id: String, name: String)],
                             target: Target = .app) throws -> String {
        if let exact = candidates.first(where: { $0.id == query }) {
            return exact.id
        }
        let byName = candidates.filter { $0.name.caseInsensitiveCompare(query) == .orderedSame }
        guard let first = byName.first else {
            throw AutomationCommandError.notFound(query, target)
        }
        guard byName.count == 1 else {
            throw AutomationCommandError.ambiguous(query, byName.map(\.id), target)
        }
        return first.id
    }
}

public enum AutomationCommandError: LocalizedError, Equatable {
    case wrongScheme(String?)
    case unknownCommand(String?)
    case missingApp
    case missingValue
    case invalidValue(String)
    case valueOutOfRange(String)
    case unknownMuteState(String)
    case missingDevice
    case notFound(String, AutomationCommand.Target)
    case ambiguous(String, [String], AutomationCommand.Target)

    public var errorDescription: String? {
        switch self {
        case .wrongScheme(let scheme):
            return "Still only understands still:// URLs, not \(scheme.map { "\($0)://" } ?? "this one")."
        case .unknownCommand(let command):
            guard let command, !command.isEmpty else {
                return "Missing command. Use still://volume, still://mute, or still://output."
            }
            return "Unknown command '\(command)'. Use volume, mute, or output."
        case .missingApp:
            return "Missing 'app' in the still:// URL."
        case .missingValue:
            return "Missing 'value' in the still:// URL."
        case .invalidValue(let value):
            return "'\(value)' is not a number."
        case .valueOutOfRange(let value):
            return "Volume must be between 0 and 100, got \(value)."
        case .unknownMuteState(let state):
            return "Unknown mute state '\(state)'. Use on, off, or toggle."
        case .missingDevice:
            return "Missing 'device' in the still:// URL."
        case .notFound(let name, let target):
            return "No \(target == .app ? "app" : "output device") named \"\(name)\"."
        case .ambiguous(let name, let ids, let target):
            return "\"\(name)\" matches more than one \(target == .app ? "app" : "output device") (\(ids.joined(separator: ", "))). Use its \(target == .app ? "bundle id" : "device UID") instead."
        }
    }
}
