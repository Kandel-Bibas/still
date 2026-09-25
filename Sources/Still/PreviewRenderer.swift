import AppKit
import SwiftUI

@MainActor
enum PreviewRenderer {
    static func render(to directory: URL) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw RenderError.createDirectory(directory.path, error)
        }

        let devices = [
            OutputDevice(id: "preview-speakers", audioID: 0, name: "MacBook Pro Speakers", symbol: "laptopcomputer"),
            OutputDevice(id: "preview-headphones", audioID: 0, name: "Studio Headphones", symbol: "headphones")
        ]
        let apps = sampleApps()
        let singleApp = MixerApp(
            id: "preview.spotify", name: "Spotify",
            icon: appIcon(at: "/Applications/Spotify.app", fallback: "music.note"),
            bundleURL: nil, processes: [], isActive: true, volume: 1,
            isMuted: false, isPinned: false, outputUID: nil,
            outputName: nil, state: .direct
        )
        try renderPanel(
            store: MixerStore(previewApps: [singleApp], previewDevices: devices),
            appearance: .darkAqua, scheme: .dark, to: directory.appendingPathComponent("single.png")
        )
        let crowdedApps = (1...12).map { index in
            MixerApp(
                id: "preview.app.\(index)", name: "Audio app \(index)", icon: singleApp.icon,
                bundleURL: nil, processes: [], isActive: true, volume: 0.5,
                isMuted: false, isPinned: false, outputUID: nil,
                outputName: nil, state: .direct
            )
        }
        try renderPanel(
            store: MixerStore(previewApps: crowdedApps, previewDevices: devices),
            appearance: .darkAqua, scheme: .dark, to: directory.appendingPathComponent("crowded.png")
        )
        let sampleLevels: [String: Float] = ["preview.music": 0.7, "preview.safari": 0.35]
        try renderPanel(
            store: MixerStore(previewApps: apps, previewDevices: devices, previewLevels: sampleLevels),
            appearance: .aqua, scheme: .light, to: directory.appendingPathComponent("light.png")
        )
        try renderPanel(
            store: MixerStore(previewApps: apps, previewDevices: devices, previewLevels: sampleLevels),
            appearance: .darkAqua, scheme: .dark, to: directory.appendingPathComponent("dark.png")
        )
        try renderPanel(
            store: MixerStore(previewApps: [], previewDevices: devices, enabled: false),
            appearance: .aqua, scheme: .light, to: directory.appendingPathComponent("empty.png")
        )

        var waitingApps = apps
        waitingApps[0].outputUID = "preview-disconnected-headphones"
        waitingApps[0].outputName = "Studio Headphones"
        waitingApps[0].state = .waiting("Studio Headphones")
        waitingApps[2].state = .failed("Audio control could not start. Try again.")
        try renderPanel(
            store: MixerStore(previewApps: waitingApps, previewDevices: [devices[0]]),
            appearance: .aqua, scheme: .light, to: directory.appendingPathComponent("waiting.png")
        )
        try renderPanel(
            store: MixerStore(previewApps: waitingApps, previewDevices: [devices[0]]),
            appearance: .darkAqua, scheme: .dark, to: directory.appendingPathComponent("waiting-dark.png")
        )
    }

    private static func renderPanel(
        store: MixerStore,
        appearance name: NSAppearance.Name,
        scheme: ColorScheme,
        to destination: URL
    ) throws {
        guard let appearance = NSAppearance(named: name) else {
            throw RenderError.appearance(name.rawValue)
        }

        let size = NSSize(width: 400, height: 600)
        let root = MixerPanel(store: store)
            .fixedSize(horizontal: true, vertical: true)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)
            .environment(\.controlActiveState, .key)
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.appearance = appearance

        // A window supplies native control metrics without ordering any UI onscreen.
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = hostingView
        defer { window.close() }

        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
        hostingView.layoutSubtreeIfNeeded()
        let fittedSize = hostingView.fittingSize
        guard fittedSize.width.isFinite, fittedSize.height.isFinite,
              fittedSize.width > 0, fittedSize.height > 0, fittedSize.height <= 620 else {
            throw RenderError.layout(destination.lastPathComponent, fittedSize)
        }
        window.setContentSize(fittedSize)
        hostingView.frame = NSRect(origin: .zero, size: fittedSize)
        hostingView.layoutSubtreeIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw RenderError.bitmap(destination.lastPathComponent)
        }
        appearance.performAsCurrentDrawingAppearance {
            hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        }
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw RenderError.png(destination.lastPathComponent)
        }
        do {
            try png.write(to: destination, options: .atomic)
        } catch {
            throw RenderError.write(destination.path, error)
        }
    }

    private static func sampleApps() -> [MixerApp] {
        [
            MixerApp(
                id: "preview.music", name: "Music",
                icon: appIcon(at: "/System/Applications/Music.app", fallback: "music.note"),
                bundleURL: nil, processes: [], isActive: true, volume: 0.42,
                isMuted: false, isPinned: true, outputUID: "preview-headphones",
                outputName: "Studio Headphones", state: .managed
            ),
            MixerApp(
                id: "preview.safari", name: "Safari",
                icon: appIcon(at: "/Applications/Safari.app", fallback: "safari"),
                bundleURL: nil, processes: [], isActive: true, volume: 0.75,
                isMuted: false, isPinned: false, outputUID: nil,
                outputName: nil, state: .managed
            ),
            MixerApp(
                id: "preview.zoom", name: "Zoom",
                icon: NSImage(systemSymbolName: "video.fill", accessibilityDescription: nil),
                bundleURL: nil, processes: [], isActive: true, volume: 1,
                isMuted: false, isPinned: false, outputUID: nil,
                outputName: nil, state: .direct
            )
        ]
    }

    private static func appIcon(at path: String, fallback symbol: String) -> NSImage? {
        if FileManager.default.fileExists(atPath: path) {
            return NSWorkspace.shared.icon(forFile: path)
        }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    private enum RenderError: LocalizedError {
        case createDirectory(String, Error)
        case appearance(String)
        case layout(String, NSSize)
        case bitmap(String)
        case png(String)
        case write(String, Error)

        var errorDescription: String? {
            switch self {
            case .createDirectory(let path, let error):
                return "Could not create preview directory at \(path): \(error.localizedDescription)"
            case .appearance(let name):
                return "The native \(name) appearance is unavailable."
            case .layout(let name, let size):
                return "Invalid preview layout for \(name): \(size.width) × \(size.height) points."
            case .bitmap(let name):
                return "Could not allocate a bitmap for \(name)."
            case .png(let name):
                return "Could not encode \(name) as PNG."
            case .write(let path, let error):
                return "Could not save preview at \(path): \(error.localizedDescription)"
            }
        }
    }
}
