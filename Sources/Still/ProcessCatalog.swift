import AppKit
import CoreAudio
import Darwin
import MixerCore

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
                // Daemons such as systemsoundserverd have no application to show.
                guard let identity = owner(of: pid) else { continue }
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

    private typealias Identity = (id: String, name: String, url: URL)

    /// The application a process belongs to: first by walking its parents, then through
    /// the process macOS holds responsible for it. WebKit's shared GPU process, which plays
    /// Safari's and Raycast's audio, is parented by launchd and only the second finds its app.
    private static func owner(of pid: pid_t) -> Identity? {
        if let identity = ancestorApplication(of: pid) { return identity }
        guard let responsible = responsiblePID(pid), responsible != pid, responsible > 1,
              responsible != getpid() else { return nil }
        return ancestorApplication(of: responsible)
    }

    private static func ancestorApplication(of pid: pid_t) -> Identity? {
        var candidate = pid
        var visited: Set<pid_t> = []
        while candidate > 1, visited.insert(candidate).inserted, visited.count <= 12 {
            if let app = NSRunningApplication(processIdentifier: candidate), let url = app.bundleURL,
               let outerPath = AppBundle.outermost(url.path), AppBundle.isUserFacing(outerPath) {
                // A nested helper belongs to its enclosing app. Menu bar apps such as Raycast
                // count too; system components were excluded by their location above.
                let outer = URL(fileURLWithPath: outerPath)
                let bundle = Bundle(url: outer)
                let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? outer.deletingPathExtension().lastPathComponent
                return (bundle?.bundleIdentifier ?? outer.path, name, outer)
            }
            var info = proc_bsdshortinfo()
            let count = proc_pidinfo(candidate, PROC_PIDT_SHORTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info)))
            guard count == MemoryLayout.size(ofValue: info) else { break }
            candidate = pid_t(info.pbsi_ppid)
        }
        return nil
    }

    private typealias ResponsibleFunction = @convention(c) (pid_t) -> pid_t

    /// `responsibility_get_pid_responsible_for_pid` is private libsystem API, the same
    /// attribution macOS uses for privacy prompts. Looked up at runtime so its absence only
    /// loses helper attribution instead of failing to launch.
    private static let responsibleFunction: ResponsibleFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            HAL.log.error("responsibility_get_pid_responsible_for_pid is unavailable; WebKit audio can't be attributed.")
            return nil
        }
        return unsafeBitCast(symbol, to: ResponsibleFunction.self)
    }()

    private static func responsiblePID(_ pid: pid_t) -> pid_t? {
        guard let responsibleFunction else { return nil }
        let result = responsibleFunction(pid)
        return result > 0 ? result : nil
    }
}
