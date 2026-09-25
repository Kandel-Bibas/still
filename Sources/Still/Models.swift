import AppKit
import CoreAudio
import MixerCore

struct OutputDevice: Identifiable, Equatable {
    var id: String
    var audioID: AudioObjectID
    var name: String
    var symbol: String
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
