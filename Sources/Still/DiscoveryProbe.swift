import AppKit
import AVFoundation
import CoreAudio
import Foundation

/// Explicit regression probe using generated audio and one continuously running engine.
@MainActor
enum DiscoveryProbe {
    static func run(reportURL: URL) {
        _ = NSApplication.shared
        let engine = EngineService()
        var latest: EngineSnapshot?
        var snapshots = 0
        engine.onSnapshot = { snapshot in
            DispatchQueue.main.async {
                latest = snapshot
                snapshots += 1
            }
        }
        var report: [String: Any] = ["passed": false]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Still-discovery-\(UUID().uuidString)")
        let afplay = Process()
        let source = Process()
        let commands = Pipe()
        defer {
            for process in [afplay, source] where process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            engine.stop()
            do { try FileManager.default.removeItem(at: directory) }
            catch { HAL.log.error("Discovery probe cleanup failed: \(error.localizedDescription, privacy: .public)") }
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let toneURL = directory.appendingPathComponent("generated-tone.wav")
            try tone().write(to: toneURL)
            engine.start(enabled: false, preferences: [:])
            try wait("initial engine snapshot") { latest != nil }
            if let error = latest?.error { throw EngineError.message(error) }
            guard !(latest?.devices.isEmpty ?? true) else { throw EngineError.message("No output is connected.") }

            // A new player must appear after the initial snapshot without refresh/relaunch.
            afplay.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            afplay.arguments = ["-v", "0.01", toneURL.path]
            try afplay.run()
            try wait("new afplay process becomes active") {
                application(for: afplay.processIdentifier, in: latest)?.active == true
            }
            let afplayObjects = objects(for: afplay.processIdentifier, in: latest)
            report["newProcessAfterStartup"] = true
            afplay.terminate()
            afplay.waitUntilExit()
            try wait("terminated afplay process disappears") {
                !(latest?.applications.contains { !$0.processes.filter(afplayObjects.contains).isEmpty } ?? false)
            }
            report["processExit"] = true

            // Copy only the executable into an isolated helper bundle so its activity cannot
            // be combined with another app's audio through parent-process attribution.
            let helper = directory.appendingPathComponent("StillDiscoverySource.app/Contents")
            let executable = helper.appendingPathComponent("MacOS/StillDiscoverySource")
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]), to: executable)
            let identifier = "com.bibaskandel.Still.discovery.\(UUID().uuidString)"
            let plist: [String: Any] = ["CFBundleIdentifier": identifier,
                "CFBundleExecutable": "StillDiscoverySource", "CFBundleName": "Still discovery source",
                "CFBundlePackageType": "APPL", "LSUIElement": true]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: helper.appendingPathComponent("Info.plist"))
            source.executableURL = executable
            source.arguments = ["--discovery-source", toneURL.path]
            source.standardInput = commands
            try source.run()
            try wait("idle audio source registers") {
                application(for: source.processIdentifier, in: latest)?.active == false
            }
            report["initiallyIdleSource"] = true
            let sourceObjects = objects(for: source.processIdentifier, in: latest)
            guard !sourceObjects.isEmpty else { throw EngineError.message("The source registered no audio object.") }

            for (command, expected, key) in [("play", true, "playbackStart"), ("stop", false, "playbackStop"),
                                            ("play", true, "playbackResume"), ("stop", false, "playbackSecondStop")] {
                let before = snapshots
                try commands.fileHandleForWriting.write(contentsOf: Data("\(command)\n".utf8))
                try wait(key) {
                    snapshots > before && application(for: source.processIdentifier, in: latest)?.active == expected
                }
                guard objects(for: source.processIdentifier, in: latest) == sourceObjects else {
                    throw EngineError.message("The audio source changed process objects during \(key).")
                }
                report[key] = true
            }
            report["snapshots"] = snapshots
            report["passed"] = true
        } catch {
            report["error"] = error.localizedDescription
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: reportURL, options: .atomic)
        } catch {
            HAL.log.error("Couldn't write discovery probe report: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func runSource(toneURL: URL) {
        _ = NSApplication.shared
        // A regular helper has its own identity; no window is created or activated.
        NSApplication.shared.setActivationPolicy(.regular)
        do {
            let player = try AVAudioPlayer(contentsOf: toneURL)
            player.volume = 0.01
            player.numberOfLoops = -1
            guard player.prepareToPlay() else { throw EngineError.message("The discovery source could not prepare audio.") }
            let input = FileHandle.standardInput
            input.readabilityHandler = { handle in
                let data = handle.availableData
                DispatchQueue.main.async {
                    if data.isEmpty { exit(0) }
                    for command in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                        switch command {
                        case "play":
                            if !player.play() { exit(1) }
                        case "stop": player.stop()
                        default: exit(1)
                        }
                    }
                }
            }
            RunLoop.main.run()
            withExtendedLifetime(player) {}
        } catch {
            FileHandle.standardError.write(Data("Discovery source failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func application(for pid: pid_t, in snapshot: EngineSnapshot?) -> AudioApplication? {
        snapshot?.applications.first { application in
            application.processes.contains { (try? HAL.value($0, kAudioProcessPropertyPID, initial: pid_t(0))) == pid }
        }
    }

    private static func objects(for pid: pid_t, in snapshot: EngineSnapshot?) -> Set<AudioObjectID> {
        Set(snapshot?.applications.flatMap(\.processes).filter {
            (try? HAL.value($0, kAudioProcessPropertyPID, initial: pid_t(0))) == pid
        } ?? [])
    }

    private static func wait(_ condition: String, until satisfied: () -> Bool) throws {
        let deadline = Date(timeIntervalSinceNow: 8)
        while !satisfied(), Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
        guard satisfied() else { throw EngineError.message("Timed out waiting for \(condition).") }
    }

    private static func tone() -> Data {
        let rate = 48_000
        let count = rate * 2
        let byteCount = UInt32(count * 2)
        var data = Data()
        func word<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8); word(byteCount + 36)
        data.append(contentsOf: "WAVEfmt ".utf8); word(UInt32(16)); word(UInt16(1)); word(UInt16(1))
        word(UInt32(rate)); word(UInt32(rate * 2)); word(UInt16(2)); word(UInt16(16))
        data.append(contentsOf: "data".utf8); word(byteCount)
        for frame in 0..<count {
            word(Int16(sin(2 * .pi * 440 * Double(frame) / Double(rate)) * 100))
        }
        return data
    }
}
