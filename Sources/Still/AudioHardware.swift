import CoreAudio
import Foundation
import OSLog

struct AudioFailure: LocalizedError {
    let operation: String
    let status: OSStatus
    var errorDescription: String? {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: UInt32(bitPattern: status) >> $0) }
        let code = bytes.allSatisfy { (32...126).contains($0) } ? String(bytes: bytes, encoding: .ascii) ?? "" : ""
        return "\(operation) failed (\(status)\(code.isEmpty ? "" : ", \(code)"))."
    }
}

enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let log = Logger(subsystem: "com.bibaskandel.Still", category: "Audio")

    static func check(_ status: OSStatus, _ operation: String) throws {
        if status != noErr { throw AudioFailure(operation: operation, status: status) }
    }

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func value<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         initial: T, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
        var property = address(selector, scope: scope)
        var result = initial
        var size = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(object, &property, 0, nil, &size, &result), "Read audio property \(selector)")
        guard size == MemoryLayout<T>.size else { throw EngineError.message("An audio property returned an unexpected size.") }
        return result
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var property = address(selector)
        var result: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(object, &property, 0, nil, &size, &result), "Read audio device name")
        guard let result else { throw EngineError.message("The audio system returned an empty identifier.") }
        return result.takeRetainedValue() as String
    }

    static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [AudioObjectID] {
        var property = address(selector, scope: scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size), "Read audio list size")
        guard size > 0 else { return [] }
        guard size % 4 == 0 else { throw EngineError.message("The audio system returned an invalid object list.") }
        var result = [AudioObjectID](repeating: 0, count: Int(size) / 4)
        try result.withUnsafeMutableBytes { bytes in
            try check(AudioObjectGetPropertyData(object, &property, 0, nil, &size, bytes.baseAddress!), "Read audio list")
        }
        return Array(result.prefix(Int(size) / 4))
    }

    static func channelLayout(_ device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [UInt32] {
        var property = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size), "Read stream layout size")
        guard size >= MemoryLayout<UInt32>.size else { return [] }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        try check(AudioObjectGetPropertyData(device, &property, 0, nil, &size, storage), "Read stream layout")
        let list = storage.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(list).map(\.mNumberChannels)
    }

    static func outputDevices() throws -> [OutputDevice] {
        let devices = try objects(system, kAudioHardwarePropertyDevices)
        return devices.compactMap { id in
            do {
                guard try value(id, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0)) != 0,
                      try channelLayout(id, scope: kAudioDevicePropertyScopeOutput).reduce(0, +) > 0 else { return nil }
                let uid = try string(id, kAudioDevicePropertyDeviceUID)
                guard !uid.hasPrefix("com.bibaskandel.Still.route.") else { return nil }
                let name = try string(id, kAudioObjectPropertyName)
                let transport = try value(id, kAudioDevicePropertyTransportType, initial: UInt32(0))
                let symbol: String
                switch transport {
                case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: symbol = "headphones"
                case kAudioDeviceTransportTypeAirPlay: symbol = "airplay.audio"
                case kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI: symbol = "display"
                default: symbol = name.localizedCaseInsensitiveContains("headphone") ? "headphones" : "speaker.wave.2"
                }
                return OutputDevice(id: uid, audioID: id, name: name, symbol: symbol)
            } catch {
                log.notice("Skipping unavailable audio device: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

enum EngineError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

final class AudioListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock

    init(object: AudioObjectID, selector: AudioObjectPropertySelector,
         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
         queue: DispatchQueue, changed: @escaping () -> Void) throws {
        self.object = object
        self.address = HAL.address(selector, scope: scope)
        self.queue = queue
        self.block = { _, _ in changed() }
        try HAL.check(AudioObjectAddPropertyListenerBlock(object, &address, queue, block), "Watch audio changes")
    }

    deinit {
        let result = AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
        if result != noErr { HAL.log.debug("Listener removal returned \(result)") }
    }
}
