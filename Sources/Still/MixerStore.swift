import AppKit
import Foundation
import MixerCore
import Observation
import ServiceManagement

@MainActor @Observable
final class MixerStore {
    private(set) var apps: [MixerApp] = []
    private(set) var devices: [OutputDevice] = []
    private(set) var isEnabled = false
    private(set) var isLoading = true
    private(set) var errorMessage: String?
    private(set) var defaultOutputName = "No output connected"
    private(set) var launchAtLogin = false
    var showAllApps = false
    @ObservationIgnored private let engine = EngineService()
    @ObservationIgnored private var saved = SavedPreferences()
    @ObservationIgnored private var canSave = true
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var lastSnapshot: EngineSnapshot?
    @ObservationIgnored private var lastSeen: [String: Date] = [:]
    @ObservationIgnored private var icons: [String: NSImage] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let settingsURL: URL

    init(previewApps: [MixerApp], previewDevices: [OutputDevice], enabled: Bool = true) {
        settingsURL = FileManager.default.temporaryDirectory.appendingPathComponent("Still-preview-unused.json")
        canSave = false
        apps = previewApps
        devices = previewDevices
        isEnabled = enabled
        isLoading = false
        defaultOutputName = previewDevices.first?.name ?? "No output connected"
    }

    init() {
        settingsURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Still/preferences.json")
        do {
            if FileManager.default.fileExists(atPath: settingsURL.path) {
                saved = try SavedPreferences.decode(Data(contentsOf: settingsURL))
            }
        } catch {
            canSave = false
            errorMessage = "Couldn't load settings: \(error.localizedDescription)"
        }
        isEnabled = saved.enabled
        launchAtLogin = SMAppService.mainApp.status == .enabled
        engine.onSnapshot = { [weak self] snapshot in
            Task { @MainActor [weak self] in self?.receive(snapshot) }
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.engine.sleep()
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.engine.wake()
        })
        engine.start(enabled: isEnabled, preferences: saved.applications)
    }

    func setVolume(_ id: String, _ volume: Double) { edit(id) { $0.volume = AppPreference.validVolume(volume) } }
    func toggleMute(_ id: String) { edit(id) { $0.muted.toggle() } }
    func togglePin(_ id: String) { edit(id) { $0.pinned.toggle() } }
    func setOutput(_ id: String, _ device: OutputDevice?) {
        edit(id) { $0.outputUID = device?.id; $0.outputName = device?.name }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        saved.enabled = enabled
        engine.update(enabled: enabled, preferences: saved.applications)
        scheduleSave()
    }

    func retry(_ id: String) { engine.retry(id) }
    func refresh() { engine.refresh() }
    func dismissError() { errorMessage = nil }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if enabled && !launchAtLogin { errorMessage = "Approve Still in System Settings → General → Login Items." }
        } catch { errorMessage = "Couldn't change launch at login: \(error.localizedDescription)" }
    }

    func shutdown() {
        saveTask?.cancel()
        persist()
        engine.stop()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
    }

    private func edit(_ id: String, _ update: (inout AppPreference) -> Void) {
        var preference = saved.applications[id] ?? AppPreference()
        if let app = apps.first(where: { $0.id == id }) {
            preference.appName = app.name
            preference.bundlePath = app.bundleURL?.path
        }
        update(&preference)
        saved.applications[id] = preference
        if let snapshot = lastSnapshot { receive(snapshot) }
        engine.update(enabled: isEnabled, preferences: saved.applications)
        scheduleSave()
    }

    private func receive(_ snapshot: EngineSnapshot) {
        lastSnapshot = snapshot
        devices = snapshot.devices
        defaultOutputName = devices.first(where: { $0.id == snapshot.defaultUID })?.name ?? "No output connected"
        if let error = snapshot.error { errorMessage = error }
        let now = Date()
        var rows: [MixerApp] = snapshot.applications.map { source in
            if source.active { lastSeen[source.id] = now }
            let preference = saved.applications[source.id] ?? AppPreference()
            if icons[source.id] == nil, let url = source.bundleURL {
                icons[source.id] = NSWorkspace.shared.icon(forFile: url.path)
            }
            return MixerApp(id: source.id, name: source.name, icon: icons[source.id], bundleURL: source.bundleURL,
                processes: source.processes,
                isActive: source.active || now.timeIntervalSince(lastSeen[source.id] ?? .distantPast) < 15,
                volume: preference.volume, isMuted: preference.muted, isPinned: preference.pinned,
                outputUID: preference.outputUID, outputName: preference.outputName,
                state: snapshot.states[source.id] ?? .inactive)
        }
        let present = Set(rows.map(\.id))
        for (id, preference) in saved.applications where preference.pinned && !present.contains(id) {
            let url = preference.bundlePath.map { URL(fileURLWithPath: $0) }
            if icons[id] == nil, let url { icons[id] = NSWorkspace.shared.icon(forFile: url.path) }
            rows.append(MixerApp(id: id, name: preference.appName ?? id, icon: icons[id], bundleURL: url,
                processes: [], isActive: false, volume: preference.volume, isMuted: preference.muted,
                isPinned: true, outputUID: preference.outputUID, outputName: preference.outputName, state: .inactive))
        }
        apps = rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        isLoading = false
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) }
            catch { return }
            self?.persist()
        }
    }

    private func persist() {
        guard canSave else { return }
        do {
            try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(saved).write(to: settingsURL, options: .atomic)
        } catch { errorMessage = "Couldn't save settings: \(error.localizedDescription)" }
    }
}
