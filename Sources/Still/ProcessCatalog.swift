import AppKit
import CoreAudio
import Darwin

struct AudioApplication {
    var id: String
    var name: String
    var bundleURL: URL?
    var processes: [AudioObjectID]
    var active: Bool
}

enum ProcessCatalog {
    struct Scan {
        var applications: [AudioApplication]
        var processObjects: Set<AudioObjectID>
    }

    static func scan() throws -> Scan {
        var result: [String: AudioApplication] = [:]
        let processIDs = try HAL.objects(HAL.system, kAudioHardwarePropertyProcessObjectList)
        for audioID in processIDs {
            do {
                let pid = try HAL.value(audioID, kAudioProcessPropertyPID, initial: pid_t(0))
                guard pid != getpid(), pid > 1 else { continue }
                let active = try HAL.value(audioID, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) != 0
                let identity = identity(pid: pid, audioID: audioID)
                guard active || identity.isApplication else { continue }
                if var existing = result[identity.id] {
                    existing.processes.append(audioID)
                    existing.active = existing.active || active
                    result[identity.id] = existing
                } else {
                    result[identity.id] = AudioApplication(id: identity.id, name: identity.name,
                        bundleURL: identity.url, processes: [audioID], active: active)
                }
            } catch {
                // Processes can exit between receiving the list and reading their properties.
                HAL.log.debug("Audio process disappeared or is unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }
        for running in NSWorkspace.shared.runningApplications where running.activationPolicy == .regular {
            guard running.processIdentifier != getpid(), let id = running.bundleIdentifier,
                  result[id] == nil else { continue }
            result[id] = AudioApplication(id: id, name: running.localizedName ?? id,
                bundleURL: running.bundleURL, processes: [], active: false)
        }
        let applications = result.values.map { app in
            var app = app
            app.processes.sort()
            return app
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return Scan(applications: applications, processObjects: Set(processIDs))
    }

    private static func identity(pid: pid_t, audioID: AudioObjectID) -> (id: String, name: String, url: URL?, isApplication: Bool) {
        var candidate = pid
        var visited: Set<pid_t> = []
        var fallbackApp: NSRunningApplication?
        while candidate > 1, visited.insert(candidate).inserted, visited.count <= 12 {
            if let app = NSRunningApplication(processIdentifier: candidate) {
                if fallbackApp == nil { fallbackApp = app }
                if let url = app.bundleURL, let outer = outerApplication(url) {
                    let bundle = Bundle(url: outer)
                    let id = bundle?.bundleIdentifier ?? outer.path
                    let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                        ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                        ?? outer.deletingPathExtension().lastPathComponent
                    // A nested helper belongs to its enclosing app. Shared system helpers don't.
                    if outer != url || app.activationPolicy == .regular {
                        return (id, name, outer, true)
                    }
                }
            }
            var info = proc_bsdshortinfo()
            let count = proc_pidinfo(candidate, PROC_PIDT_SHORTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info)))
            guard count == MemoryLayout.size(ofValue: info) else { break }
            candidate = pid_t(info.pbsi_ppid)
        }
        let bundleID: String?
        do { bundleID = try HAL.string(audioID, kAudioProcessPropertyBundleID) }
        catch { bundleID = fallbackApp?.bundleIdentifier }
        let name = fallbackApp?.localizedName ?? processName(pid)
        // Shared WebKit helpers can belong to different hosts. Their display names keep
        // them distinct until a parent/enclosing application can be established.
        let baseID = bundleID.flatMap { $0.isEmpty ? nil : $0 } ?? "process"
        let id = "\(baseID):\(name)"
        return (id, name, fallbackApp?.bundleURL, false)
    }

    private static func outerApplication(_ url: URL) -> URL? {
        let parts = url.pathComponents
        guard let index = parts.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(parts.prefix(index + 1))))
    }

    private static func processName(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 1024)
        let size = proc_name(pid, &buffer, UInt32(buffer.count))
        return size > 0 ? String(cString: buffer) : "Audio process \(pid)"
    }
}
