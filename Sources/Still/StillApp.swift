import AppKit
import CoreAudio
import SwiftUI

@main
enum StillLauncher {
    @MainActor static func main() {
        if let index = CommandLine.arguments.firstIndex(of: "--discovery-probe"),
           CommandLine.arguments.indices.contains(index + 1) {
            DiscoveryProbe.run(reportURL: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--discovery-source"),
           CommandLine.arguments.indices.contains(index + 1) {
            DiscoveryProbe.runSource(toneURL: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--audio-probe"),
           CommandLine.arguments.indices.contains(index + 1) {
            AudioProbe.run(reportURL: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-previews"),
           CommandLine.arguments.indices.contains(index + 1) {
            do { try PreviewRenderer.render(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
            catch {
                FileHandle.standardError.write(Data("Preview rendering failed: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
            return
        }
        if CommandLine.arguments.contains("--diagnose") {
            do {
                let devices = try HAL.outputDevices()
                let applications = try ProcessCatalog.scan().applications
                let defaultID = try HAL.value(HAL.system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(0))
                let result: [String: Any] = [
                    "outputs": devices.map { ["name": $0.name, "uid": $0.id, "audioID": $0.audioID, "default": $0.audioID == defaultID] as [String: Any] },
                    "applications": applications.map { ["id": $0.id, "name": $0.name, "processes": $0.processes, "active": $0.active] as [String: Any] }
                ]
                let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                FileHandle.standardOutput.write(data)
                print()
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                exit(1)
            }
            return
        }
        StillDelegate.run()
    }
}

@MainActor
final class StillDelegate: NSObject, NSApplicationDelegate {
    private var store: MixerStore?
    private var controller: StatusItemController?

    /// `NSApplication.delegate` is weak, so the delegate is held here for the
    /// lifetime of the process.
    private static var shared: StillDelegate?

    static func run() {
        let application = NSApplication.shared
        let delegate = StillDelegate()
        shared = delegate
        application.delegate = delegate
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let store = MixerStore()
        self.store = store
        controller = StatusItemController(store: store)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        store?.shutdown()
        return .terminateNow
    }

    /// Reopening from the Finder or Launchpad shows the panel instead of doing nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.openPanel()
        return true
    }
}
