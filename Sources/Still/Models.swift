import AppKit
import CoreAudio
import MixerCore

struct OutputDevice: Identifiable, Equatable {
    var id: String
    var audioID: AudioObjectID
    var name: String
    var symbol: String
}

enum RouteState: Equatable {
    case inactive
    case direct
    case managed
    case waiting(String)
    case failed(String)

    var label: String {
        switch self {
        case .inactive: return "Ready when audio starts"
        case .direct: return "Original audio"
        case .managed: return "Controlled by Still"
        case .waiting(let name): return "Muted · Waiting for \(name)"
        case .failed(let message): return message
        }
    }
}

struct MixerApp: Identifiable {
    var id: String
    var name: String
    var icon: NSImage?
    var bundleURL: URL?
    var processes: [AudioObjectID]
    var isActive: Bool
    var volume: Double
    var isMuted: Bool
    var isPinned: Bool
    var outputUID: String?
    var outputName: String?
    var state: RouteState
}
