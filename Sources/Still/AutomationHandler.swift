import Foundation
import MixerCore
import OSLog

/// Handles `still://` URLs from Shortcuts or scripts by parsing them with
/// `AutomationCommand` and driving the existing `MixerStore` API. Holds no audio state
/// of its own.
@MainActor
final class AutomationHandler {
    private let store: MixerStore
    private let logger = Logger(subsystem: "com.bibaskandel.Still", category: "Automation")
    private var pending: [URL] = []
    private var isDraining = false

    init(store: MixerStore) {
        self.store = store
    }

    /// Entry point for `application(_:open:)`. If the engine hasn't produced its first
    /// snapshot yet (a URL that arrived at launch), the URL is queued and replayed once
    /// loading finishes.
    func handle(_ url: URL) {
        guard !store.isLoading else {
            pending.append(url)
            drainWhenReady()
            return
        }
        process(url)
    }

    private func drainWhenReady() {
        guard !isDraining else { return }
        isDraining = true
        Task { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(5)
            while self.store.isLoading {
                if Date() >= deadline {
                    self.logger.error("Timed out waiting for Still to finish loading before running a still:// URL.")
                    self.store.reportError("Still is still starting up. Try the Shortcut again in a moment.")
                    self.pending.removeAll()
                    self.isDraining = false
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            let queued = self.pending
            self.pending.removeAll()
            self.isDraining = false
            for url in queued { self.process(url) }
        }
    }

    private func process(_ url: URL) {
        do {
            let command = try AutomationCommand.parse(url)
            guard store.isEnabled else {
                report("Turn Still on to control apps from Shortcuts.")
                return
            }
            try apply(command)
        } catch {
            report(error.localizedDescription)
        }
    }

    private func apply(_ command: AutomationCommand) throws {
        switch command {
        case .volume(let app, let percent):
            let id = try AutomationCommand.match(app, in: appCandidates())
            store.setVolume(id, percent / 100)

        case .mute(let app, let state):
            let id = try AutomationCommand.match(app, in: appCandidates())
            guard let target = store.apps.first(where: { $0.id == id }) else { return }
            switch state {
            case .toggle: store.toggleMute(id)
            case .on: if !target.isMuted { store.toggleMute(id) }
            case .off: if target.isMuted { store.toggleMute(id) }
            }

        case .output(let app, let deviceName):
            let id = try AutomationCommand.match(app, in: appCandidates())
            guard let deviceName else {
                store.setOutput(id, nil)
                return
            }
            let deviceID = try AutomationCommand.match(deviceName, in: deviceCandidates(), target: .device)
            guard let device = store.devices.first(where: { $0.id == deviceID }) else { return }
            store.setOutput(id, device)
        }
    }

    private func appCandidates() -> [(id: String, name: String)] {
        store.apps.map { ($0.id, $0.name) }
    }

    private func deviceCandidates() -> [(id: String, name: String)] {
        store.devices.map { ($0.id, $0.name) }
    }

    private func report(_ message: String) {
        logger.error("\(message, privacy: .public)")
        store.reportError(message)
    }
}
