import AppKit
import CoreAudio
import Foundation

/// Developer-only, explicit command-line probe. It measures a generated tone, never user audio.
@MainActor
enum AudioProbe {
    static func run(reportURL: URL) {
        _ = NSApplication.shared
        var report: [String: Any] = ["passed": false]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Still-probe-\(UUID().uuidString)")
        let player = Process()
        let secondPlayer = Process()
        defer {
            if player.isRunning { player.terminate(); player.waitUntilExit() }
            if secondPlayer.isRunning { secondPlayer.terminate(); secondPlayer.waitUntilExit() }
            do { try FileManager.default.removeItem(at: directory) }
            catch { HAL.log.error("Probe cleanup failed: \(error.localizedDescription, privacy: .public)") }
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let toneURL = directory.appendingPathComponent("generated-tone.wav")
            try tone().write(to: toneURL)
            player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            player.arguments = ["-v", "0.1", toneURL.path]
            try player.run()
            secondPlayer.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            secondPlayer.arguments = ["-v", "0.1", toneURL.path]
            try secondPlayer.run()
            let source = try processObject(pid: player.processIdentifier)
            let secondSource = try processObject(pid: secondPlayer.processIdentifier)
            let defaultID = try HAL.value(HAL.system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(0))
            guard let device = try HAL.outputDevices().first(where: { $0.audioID == defaultID }) else {
                throw EngineError.message("No default output is connected.")
            }
            report["output"] = device.name
            let route = try AudioRoute(app: AudioApplication(id: "Still.generated-tone", name: "Still test tone",
                bundleURL: nil, processes: [source], active: true))
            let control = DispatchQueue(label: "com.bibaskandel.Still.probe")
            let secondRoute = try AudioRoute(app: AudioApplication(id: "Still.second-generated-tone", name: "Still second tone",
                bundleURL: nil, processes: [secondSource], active: true))
            try secondRoute.start(device: device, gain: 0.6, queue: control, invalidated: {})
            secondRoute.enableDiagnosticMetering()
            try route.start(device: device, gain: 0.25, queue: control, invalidated: {})
            route.enableDiagnosticMetering()
            let deadline = Date(timeIntervalSinceNow: 25)
            while route.inputPeak == 0 && Date() < deadline && player.isRunning { runLoop(seconds: 0.1) }
            runLoop(seconds: 0.15)
            let input = route.inputPeak
            let quarterOutput = route.outputPeak
            guard input > 0.00001 else {
                throw EngineError.message("The tap delivered no non-silent audio. Grant Still System Audio Recording access, then rerun the probe.")
            }
            route.setGain(0)
            runLoop(seconds: 0.3)
            let mutedOutput = route.outputPeak
            let independentInput = secondRoute.inputPeak
            let independentOutput = secondRoute.outputPeak
            route.setGain(0.75)
            runLoop(seconds: 0.3)
            let higherInput = route.inputPeak
            let higherOutput = route.outputPeak
            let quarterRatio = quarterOutput / input
            let higherRatio = higherInput > 0 ? higherOutput / higherInput : -1
            let independentRatio = independentInput > 0 ? independentOutput / independentInput : -1
            report["quarterGainRatio"] = quarterRatio
            report["mutedOutputPeak"] = mutedOutput
            report["threeQuarterGainRatio"] = higherRatio
            report["independentStreamGainWhileFirstMuted"] = independentRatio
            report["validCallbacks"] = route.renderCount
            report["faults"] = route.faultCount + secondRoute.faultCount
            let gainsPassed = abs(quarterRatio - 0.25) < 0.02 && mutedOutput == 0
                && abs(higherRatio - 0.75) < 0.02 && abs(independentRatio - 0.6) < 0.02
                && route.faultCount == 0 && secondRoute.faultCount == 0
            route.hold()
            if let cleanupError = route.cleanupError { throw EngineError.message(cleanupError) }
            runLoop(seconds: 0.2)
            try route.start(device: device, gain: 0.5, queue: control, invalidated: {})
            route.enableDiagnosticMetering()
            runLoop(seconds: 0.4)
            let resumedRatio = route.inputPeak > 0 ? route.outputPeak / route.inputPeak : -1
            report["gainAfterRouteRebuild"] = resumedRatio
            report["passed"] = gainsPassed && abs(resumedRatio - 0.5) < 0.02 && route.faultCount == 0
            route.hold()
            if let cleanupError = route.cleanupError { throw EngineError.message(cleanupError) }
            secondRoute.hold()
            if let cleanupError = secondRoute.cleanupError { throw EngineError.message(cleanupError) }
        } catch { report["error"] = error.localizedDescription; report["passed"] = false }
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: reportURL, options: .atomic)
        } catch {
            HAL.log.error("Couldn't write audio probe report: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func processObject(pid: pid_t) throws -> AudioObjectID {
        var pid = pid
        var address = HAL.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        for _ in 0..<100 {
            var object: AudioObjectID = 0
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            let result = AudioObjectGetPropertyData(HAL.system, &address,
                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
            if result == noErr && object != 0 { return object }
            runLoop(seconds: 0.02)
        }
        throw EngineError.message("The generated-tone player did not register an audio process.")
    }

    private static func runLoop(seconds: Double) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }

    private static func tone() -> Data {
        let rate = 48_000
        let count = rate * 35
        let byteCount = UInt32(count * 4)
        var data = Data()
        func word<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8); word(byteCount + 36)
        data.append(contentsOf: "WAVEfmt ".utf8); word(UInt32(16)); word(UInt16(1)); word(UInt16(2))
        word(UInt32(rate)); word(UInt32(rate * 4)); word(UInt16(4)); word(UInt16(16))
        data.append(contentsOf: "data".utf8); word(byteCount)
        for frame in 0..<count {
            let fade = min(1, Double(frame) / 480)
            let sample = Int16(sin(2 * .pi * 440 * Double(frame) / Double(rate)) * 32767 * 0.02 * fade)
            word(sample); word(sample)
        }
        return data
    }
}
