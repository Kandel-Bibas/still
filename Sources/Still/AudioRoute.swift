import AudioDSP
import CoreAudio
import Foundation

/// All lifecycle operations run on EngineService's serial queue; only DSP runs on the audio thread.
final class AudioRoute {
    let appID: String
    let processes: [AudioObjectID]
    private(set) var deviceUID: String?
    private(set) var tap: AudioObjectID = 0
    private var aggregate: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var dsp: OpaquePointer?
    private let description: CATapDescription
    private var listeners: [AudioListener] = []
    private(set) var cleanupError: String?

    var renderCount: UInt64 { dsp.map(StillDSPGetRenderCount) ?? 0 }
    var faultCount: UInt64 { dsp.map(StillDSPGetFaultCount) ?? 0 }
    var inputPeak: Float { dsp.map(StillDSPGetInputPeak) ?? 0 }
    var outputPeak: Float { dsp.map(StillDSPGetOutputPeak) ?? 0 }
    func enableDiagnosticMetering() { if let dsp { StillDSPSetMetering(dsp, true) } }

    init(app: AudioApplication) throws {
        self.appID = app.id
        self.processes = app.processes
        self.description = CATapDescription(stereoMixdownOfProcesses: app.processes)
        description.name = "Still · \(app.name)"
        description.isPrivate = true
        // Keep the original suppressed throughout output changes and missing-device waits.
        description.muteBehavior = .muted
        try HAL.check(AudioHardwareCreateProcessTap(description, &tap), "Create audio tap for \(app.name)")
    }

    func setGain(_ gain: Float) {
        if let dsp { StillDSPSetGain(dsp, gain) }
    }

    func hold() {
        stopOutput()
        deviceUID = nil
    }

    func start(device: OutputDevice, gain: Float, queue: DispatchQueue, invalidated: @escaping () -> Void) throws {
        stopOutput()
        deviceUID = nil
        if let cleanupError { throw EngineError.message(cleanupError) }
        do {
            let specification: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Still · \(device.name)",
                kAudioAggregateDeviceUIDKey: "com.bibaskandel.Still.route.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceMainSubDeviceKey: device.id,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: device.id]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]]
            ]
            try HAL.check(AudioHardwareCreateAggregateDevice(specification as CFDictionary, &aggregate), "Create output route")
            let inputStreams = try HAL.objects(aggregate, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput)
            let physicalInputs = try HAL.objects(device.audioID, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput)
            let outputStreams = try HAL.objects(aggregate, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
            guard let tapStream = inputStreams.dropFirst(physicalInputs.count).first,
                  inputStreams.count == physicalInputs.count + 1,
                  outputStreams.count == 1, let outputStream = outputStreams.first else {
                throw EngineError.message("This device's stream layout isn't supported yet. Audio remains muted; choose another output.")
            }
            let inputFormat = try HAL.value(tapStream, kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription())
            let outputFormat = try HAL.value(outputStream, kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription())
            try validate(inputFormat, name: "Tap")
            try validate(outputFormat, name: "Output")
            guard inputFormat.mChannelsPerFrame == 2,
                  abs(inputFormat.mSampleRate - outputFormat.mSampleRate) < 0.5 else {
                throw EngineError.message("The tap and output formats don't match. Audio remains muted; retry or choose another output.")
            }
            let physicalLayout = try HAL.channelLayout(device.audioID, scope: kAudioDevicePropertyScopeInput)
            let inputLayout = try HAL.channelLayout(aggregate, scope: kAudioDevicePropertyScopeInput)
            let outputLayout = try HAL.channelLayout(aggregate, scope: kAudioDevicePropertyScopeOutput)
            guard inputLayout == physicalLayout + bufferChannels(for: inputFormat),
                  outputLayout == bufferChannels(for: outputFormat),
                  UInt32(exactly: physicalLayout.count) != nil else {
                throw EngineError.message("The aggregate audio buffers don't match the device streams. Audio remains muted; choose another output.")
            }
            guard let context = StillDSPCreate(outputFormat.mSampleRate, UInt32(physicalLayout.count),
                2, inputFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
                outputFormat.mChannelsPerFrame, outputFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0) else {
                throw EngineError.message("Couldn't allocate the audio processing buffers.")
            }
            dsp = context
            StillDSPSetGain(context, gain)
            try HAL.check(AudioDeviceCreateIOProcID(aggregate, StillDSPIOProc, UnsafeMutableRawPointer(context), &ioProc), "Create audio callback")
            try disablePhysicalInputs(streamCount: inputStreams.count, physicalCount: physicalInputs.count)
            try HAL.check(AudioDeviceStart(aggregate, ioProc), "Start audio output. Check Still's System Audio Recording permission")
            deviceUID = device.id
            for (object, selector) in [(device.audioID, kAudioDevicePropertyDeviceIsAlive),
                                       (device.audioID, kAudioDevicePropertyNominalSampleRate),
                                       (tapStream, kAudioStreamPropertyVirtualFormat),
                                       (outputStream, kAudioStreamPropertyVirtualFormat)] {
                listeners.append(try AudioListener(object: object, selector: selector, queue: queue, changed: invalidated))
            }
        } catch {
            stopOutput()
            throw error
        }
    }

    private func bufferChannels(for format: AudioStreamBasicDescription) -> [UInt32] {
        if format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 {
            return Array(repeating: 1, count: Int(format.mChannelsPerFrame))
        }
        return [format.mChannelsPerFrame]
    }

    private func validate(_ format: AudioStreamBasicDescription, name: String) throws {
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              format.mBitsPerChannel == 32,
              format.mSampleRate.isFinite, format.mSampleRate > 0,
              format.mChannelsPerFrame > 0, format.mChannelsPerFrame <= 32 else {
            throw EngineError.message("\(name) must provide native 32-bit float PCM. This format is not supported yet.")
        }
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        guard format.mBytesPerFrame == 4 * (interleaved ? format.mChannelsPerFrame : 1) else {
            throw EngineError.message("\(name) uses an unsupported PCM frame layout.")
        }
    }

    private func disablePhysicalInputs(streamCount: Int, physicalCount: Int) throws {
        guard physicalCount > 0, let ioProc else { return }
        let offset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!
        let size = offset + streamCount * MemoryLayout<UInt32>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        let usage = raw.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
        usage.pointee.mIOProc = unsafeBitCast(ioProc, to: UnsafeMutableRawPointer.self)
        usage.pointee.mNumberStreams = UInt32(streamCount)
        let flags = raw.advanced(by: offset).assumingMemoryBound(to: UInt32.self)
        for index in 0..<streamCount { flags[index] = index < physicalCount ? 0 : 1 }
        var property = HAL.address(kAudioDevicePropertyIOProcStreamUsage, scope: kAudioDevicePropertyScopeInput)
        try HAL.check(AudioObjectSetPropertyData(aggregate, &property, 0, nil, UInt32(size), raw), "Exclude microphone input from route")
    }

    private func stopOutput() {
        listeners.removeAll()
        deviceUID = nil
        // A callback surviving failed HAL teardown must produce immediate silence.
        if let dsp { StillDSPSetGain(dsp, .nan) }
        if let ioProc, aggregate != 0 {
            report(AudioDeviceStop(aggregate, ioProc), "Stop audio")
            let result = AudioDeviceDestroyIOProcID(aggregate, ioProc)
            report(result, "Remove audio callback")
            if result == noErr { self.ioProc = nil }
        }
        if aggregate != 0 {
            let result = AudioHardwareDestroyAggregateDevice(aggregate)
            report(result, "Remove output route")
            if result == noErr {
                aggregate = 0
                ioProc = nil
            }
        }
        if ioProc == nil {
            if let dsp { StillDSPDestroy(dsp) }
            dsp = nil
        }
        if aggregate != 0 || ioProc != nil {
            cleanupError = "The previous audio route couldn't be released safely. Audio processing is silenced; retry or quit Still before changing outputs."
            HAL.log.error("Retaining audio resources after failed teardown for aggregate \(self.aggregate).")
        } else {
            cleanupError = nil
        }
    }

    private func report(_ status: OSStatus, _ operation: String) {
        if status != noErr { HAL.log.error("\(operation, privacy: .public) returned \(status)") }
    }

    deinit {
        stopOutput()
        if aggregate == 0, ioProc == nil {
            if tap != 0 { report(AudioHardwareDestroyProcessTap(tap), "Release application audio") }
        } else {
            // HAL still owns the callback. Its raw DSP context and muting tap must
            // remain valid until process exit, even after this controller is gone.
            HAL.log.error("Quarantining tap \(self.tap) and aggregate \(self.aggregate) until process exit after failed teardown.")
        }
    }
}
